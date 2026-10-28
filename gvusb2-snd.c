// SPDX-License-Identifier: GPL-2.0-only OR BSD-3-Clause
/*
 * Copyright (c) 2019 Isaac Lozano <109lozanoi@gmail.com>
 *
 * This code is released using a dual license strategy: BSD/GPL
 * You can choose the licence that better fits your requirements.
 *
 * Released under the terms of 3-clause BSD License
 * Released under the terms of GNU General Public License Version 2.0
 *
 */

#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/usb.h>
#include <sound/core.h>
#include <sound/initval.h>
#include <sound/pcm.h>

#include "gvusb2.h"

#define CARD_NAME "gvusb2"

MODULE_DESCRIPTION("gvusb2 sound driver");
MODULE_AUTHOR("Isaac Lozano <109lozanoi@gmail.com>");
MODULE_LICENSE("Dual BSD/GPL");

/*
 * One entry per plugged-in GV-USB2, in plug order, same as snd-usb-audio.
 * The index default of -1 takes the first free ALSA card number. The old
 * default of 0 failed with -EBUSY whenever onboard audio held card 0.
 */
static int card_index[SNDRV_CARDS] = SNDRV_DEFAULT_IDX;
static char *card_id[SNDRV_CARDS] = SNDRV_DEFAULT_STR;
static bool card_enable[SNDRV_CARDS] = SNDRV_DEFAULT_ENABLE_PNP;

/* exposed as index=, id= and enable= like every other ALSA driver */
module_param_array_named(index, card_index, int, NULL, 0444);
MODULE_PARM_DESC(index, "Index value for " CARD_NAME " soundcard.");
module_param_array_named(id, card_id, charp, NULL, 0444);
MODULE_PARM_DESC(id, "ID string for " CARD_NAME " soundcard.");
module_param_array_named(enable, card_enable, bool, NULL, 0444);
MODULE_PARM_DESC(enable, "Enable " CARD_NAME " soundcard.");

/* which of the slots above belong to a card that still exists */
static DEFINE_MUTEX(gvusb2_snd_slots_lock);
static bool gvusb2_snd_slot_used[SNDRV_CARDS];

static const struct usb_device_id gvusb2_id_table[] = {
	{ USB_DEVICE(GVUSB2_VENDOR_ID, GVUSB2_PRODUCT_ID) },
	{ }
};
MODULE_DEVICE_TABLE(usb, gvusb2_id_table);

/* lives in snd_card->private_data, so it is freed together with the card */
struct gvusb2_snd {
	struct gvusb2_dev gv;
	struct usb_interface *intf;
	struct usb_endpoint_descriptor *ep;

	/* urb */
	struct urb *urbs[GVUSB2_NUM_URBS];

	/* alsa */
	struct snd_card *card;
	struct snd_pcm *pcm;
	int slot;		/* index into the module parameter arrays */

	/* everything below is protected by lock */
	spinlock_t lock;
	struct snd_pcm_substream *substream;
	bool running;
	unsigned int dma_offset;	/* write position, bytes */
	unsigned int period_bytes;	/* bytes since the last period */
};

static const struct snd_pcm_hardware gvusb2_snd_hw = {
	.info = (SNDRV_PCM_INFO_MMAP |
		SNDRV_PCM_INFO_INTERLEAVED |
		SNDRV_PCM_INFO_BLOCK_TRANSFER |
		SNDRV_PCM_INFO_MMAP_VALID),
	.formats = SNDRV_PCM_FMTBIT_S16_LE,
	.rates = SNDRV_PCM_RATE_48000,
	.rate_min = 48000,
	.rate_max = 48000,
	.channels_min = 2,
	.channels_max = 2,
	.buffer_bytes_max = (128 * 1024),
	/*
	 * One URB: 256 microframes of 6 frames, 4 bytes each, so 32 ms. A
	 * shorter period would just fire several times per URB. The old
	 * minimum of 0xc000 (256 ms) with one period allowed left apps a
	 * buffer smaller than two periods, and arecord's default 500 ms
	 * buffer overran at the start.
	 */
	.period_bytes_min = GVUSB2_NUM_ISOCH_PACKETS * 6 * 4,
	.period_bytes_max = (64 * 1024),
	.periods_min = 2,
	.periods_max = 32,
};

/* predefines */
static int gvusb2_snd_submit_isoc(struct gvusb2_snd *dev);
static void gvusb2_snd_cancel_isoc(struct gvusb2_snd *dev);

/*****************************************************************************
 *  Alsa Stuff
 ****************************************************************************/

/*
 * Copy one packet into the ring buffer. Called with dev->lock held and
 * only while the stream is running, which is the window in which ALSA
 * guarantees dma_area exists. Returns true when a period boundary passed.
 */
static bool gvusb2_snd_copy_pcm(struct gvusb2_snd *dev,
	struct snd_pcm_runtime *runtime, const u8 *buf, unsigned int len)
{
	unsigned int buffer_bytes = frames_to_bytes(runtime,
		runtime->buffer_size);
	unsigned int period_bytes = frames_to_bytes(runtime,
		runtime->period_size);

	while (len > 0) {
		unsigned int chunk = min(len, buffer_bytes - dev->dma_offset);

		memcpy(runtime->dma_area + dev->dma_offset, buf, chunk);
		dev->dma_offset += chunk;
		if (dev->dma_offset >= buffer_bytes)
			dev->dma_offset = 0;

		dev->period_bytes += chunk;
		buf += chunk;
		len -= chunk;
	}

	if (dev->period_bytes >= period_bytes) {
		dev->period_bytes %= period_bytes;
		return true;
	}

	return false;
}

static int gvusb2_snd_capture_open(struct snd_pcm_substream *substream)
{
	int ret;
	unsigned long flags;
	struct gvusb2_snd *dev = snd_pcm_substream_chip(substream);

	substream->runtime->hw = gvusb2_snd_hw;

	/*
	 * The buffer is always a whole number of periods, so a period
	 * boundary lands where ALSA expects one when the buffer wraps.
	 */
	ret = snd_pcm_hw_constraint_integer(substream->runtime,
		SNDRV_PCM_HW_PARAM_PERIODS);
	if (ret < 0)
		return ret;

	spin_lock_irqsave(&dev->lock, flags);
	dev->substream = substream;
	dev->running = false;
	spin_unlock_irqrestore(&dev->lock, flags);

	/*
	 * The URBs run from open to close. Data is dropped until the
	 * stream is triggered, see gvusb2_snd_process_isoc().
	 */
	ret = gvusb2_snd_submit_isoc(dev);
	if (ret < 0) {
		spin_lock_irqsave(&dev->lock, flags);
		dev->substream = NULL;
		spin_unlock_irqrestore(&dev->lock, flags);
	}

	return ret;
}

static int gvusb2_snd_capture_close(struct snd_pcm_substream *substream)
{
	unsigned long flags;
	struct gvusb2_snd *dev = snd_pcm_substream_chip(substream);

	/* stop the URBs first so no completion can see a stale substream */
	gvusb2_snd_cancel_isoc(dev);

	spin_lock_irqsave(&dev->lock, flags);
	dev->running = false;
	dev->substream = NULL;
	spin_unlock_irqrestore(&dev->lock, flags);

	return 0;
}

static int gvusb2_snd_pcm_prepare(struct snd_pcm_substream *substream)
{
	unsigned long flags;
	struct gvusb2_snd *dev = snd_pcm_substream_chip(substream);

	spin_lock_irqsave(&dev->lock, flags);
	dev->dma_offset = 0;
	dev->period_bytes = 0;
	spin_unlock_irqrestore(&dev->lock, flags);

	return 0;
}

/* NOTE: THIS IS ATOMIC */
static int gvusb2_snd_pcm_trigger(struct snd_pcm_substream *substream, int cmd)
{
	unsigned long flags;
	struct gvusb2_snd *dev = snd_pcm_substream_chip(substream);

	switch (cmd) {
	case SNDRV_PCM_TRIGGER_START:
		spin_lock_irqsave(&dev->lock, flags);
		dev->running = true;
		spin_unlock_irqrestore(&dev->lock, flags);
		return 0;
	case SNDRV_PCM_TRIGGER_STOP:
	case SNDRV_PCM_TRIGGER_SUSPEND:
		spin_lock_irqsave(&dev->lock, flags);
		dev->running = false;
		spin_unlock_irqrestore(&dev->lock, flags);
		return 0;
	default:
		return -EINVAL;
	}
}

/* NOTE: THIS IS ATOMIC */
static snd_pcm_uframes_t gvusb2_snd_pcm_pointer(
	struct snd_pcm_substream *substream)
{
	unsigned long flags;
	snd_pcm_uframes_t pos;
	struct gvusb2_snd *dev = snd_pcm_substream_chip(substream);

	spin_lock_irqsave(&dev->lock, flags);
	pos = bytes_to_frames(substream->runtime, dev->dma_offset);
	spin_unlock_irqrestore(&dev->lock, flags);

	return pos;
}

static const struct snd_pcm_ops gvusb2_snd_capture_ops = {
	.open      = gvusb2_snd_capture_open,
	.close     = gvusb2_snd_capture_close,
	.prepare   = gvusb2_snd_pcm_prepare,
	.trigger   = gvusb2_snd_pcm_trigger,
	.pointer   = gvusb2_snd_pcm_pointer,
};

static int gvusb2_snd_alsa_init(struct gvusb2_snd *dev)
{
	int ret;

	ret = snd_pcm_new(dev->card, "analog in", 0, 0, 1, &dev->pcm);
	if (ret < 0)
		return ret;

	dev->pcm->private_data = dev;

	snd_pcm_set_ops(dev->pcm, SNDRV_PCM_STREAM_CAPTURE,
		&gvusb2_snd_capture_ops);

	/* ALSA allocates and frees the vmalloc ring buffer for us */
	snd_pcm_set_managed_buffer_all(dev->pcm, SNDRV_DMA_TYPE_VMALLOC,
		NULL, 0, 0);

	strscpy(dev->card->shortname, "gvusb2", sizeof(dev->card->shortname));
	strscpy(dev->card->longname, "gvusb2", sizeof(dev->card->longname));
	strscpy(dev->card->driver, "gvusb2-snd", sizeof(dev->card->driver));

	return snd_card_register(dev->card);
}

/*****************************************************************************
 * USB Stuff
 ****************************************************************************/

/* Do not call in atomic contexts */
static void gvusb2_snd_cancel_isoc(struct gvusb2_snd *dev)
{
	int i;

	for (i = 0; i < GVUSB2_NUM_URBS; i++)
		usb_kill_urb(dev->urbs[i]);
}

static void gvusb2_snd_free_isoc(struct gvusb2_snd *dev)
{
	int i;

	for (i = 0; i < GVUSB2_NUM_URBS; i++) {
		struct urb *urb = dev->urbs[i];

		if (urb != NULL) {
			kfree(urb->transfer_buffer);
			usb_free_urb(urb);
			dev->urbs[i] = NULL;
		}
	}
}

static void gvusb2_snd_process_isoc(struct gvusb2_snd *dev, struct urb *urb)
{
	int i;
	unsigned long flags;
	bool elapsed = false;
	struct snd_pcm_substream *substream;

	spin_lock_irqsave(&dev->lock, flags);

	substream = dev->substream;
	if (substream == NULL || !dev->running) {
		spin_unlock_irqrestore(&dev->lock, flags);
		return;
	}

	for (i = 0; i < urb->number_of_packets; i++) {
		struct usb_iso_packet_descriptor *desc = &urb->iso_frame_desc[i];

		if (desc->status < 0) {
			gvusb2_dbg(&dev->intf->dev,
				"bad iso packet (%d), skipping\n", desc->status);
			continue;
		}

		if (gvusb2_snd_copy_pcm(dev, substream->runtime,
				urb->transfer_buffer + desc->offset,
				desc->actual_length))
			elapsed = true;
	}

	spin_unlock_irqrestore(&dev->lock, flags);

	/* safe outside the lock, ALSA ignores it if the stream stopped */
	if (elapsed)
		snd_pcm_period_elapsed(substream);
}

static void gvusb2_snd_isoc_irq(struct urb *urb)
{
	int i, ret;
	struct gvusb2_snd *dev = urb->context;

	switch (urb->status) {
	case 0:
		break;
	case -ECONNRESET:
	case -ENOENT:
	case -ESHUTDOWN:
		return;
	default:
		gvusb2_dbg(&dev->intf->dev, "urb error! status %d\n",
			urb->status);
		return;
	}

	gvusb2_snd_process_isoc(dev, urb);

	for (i = 0; i < urb->number_of_packets; i++) {
		urb->iso_frame_desc[i].status = 0;
		urb->iso_frame_desc[i].actual_length = 0;
	}

	ret = usb_submit_urb(urb, GFP_ATOMIC);
	if (ret)
		gvusb2_dbg(&dev->intf->dev, "urb resubmit failed (%d)\n", ret);
}

static int gvusb2_snd_submit_isoc(struct gvusb2_snd *dev)
{
	int i, ret;

	for (i = 0; i < GVUSB2_NUM_URBS; i++) {
		ret = usb_submit_urb(dev->urbs[i], GFP_KERNEL);
		if (ret < 0) {
			dev_err(&dev->intf->dev,
				"error submitting urb (%d)\n", ret);
			while (--i >= 0)
				usb_kill_urb(dev->urbs[i]);
			return ret;
		}
	}

	return 0;
}

static int gvusb2_snd_allocate_urbs(struct gvusb2_snd *dev)
{
	int i;

	for (i = 0; i < GVUSB2_NUM_URBS; i++) {
		struct urb *urb;
		int total_offset, pidx;

		urb = usb_alloc_urb(GVUSB2_NUM_ISOCH_PACKETS, GFP_KERNEL);
		if (urb == NULL)
			goto free_urbs;

		dev->urbs[i] = urb;

		urb->transfer_buffer = kzalloc(
			GVUSB2_NUM_ISOCH_PACKETS * GVUSB2_MAX_AUDIO_PACKET_SIZE,
			GFP_KERNEL);
		if (urb->transfer_buffer == NULL)
			goto free_urbs;

		urb->dev = dev->gv.udev;
		urb->pipe = usb_rcvisocpipe(dev->gv.udev, 0x04);
		urb->transfer_buffer_length =
			GVUSB2_NUM_ISOCH_PACKETS * GVUSB2_MAX_AUDIO_PACKET_SIZE;
		urb->complete = gvusb2_snd_isoc_irq;
		urb->context = dev;
		urb->interval = 1;
		urb->start_frame = 0;
		urb->number_of_packets = GVUSB2_NUM_ISOCH_PACKETS;
		urb->transfer_flags = URB_ISO_ASAP;

		total_offset = 0;
		for (pidx = 0; pidx < GVUSB2_NUM_ISOCH_PACKETS; pidx++) {
			urb->iso_frame_desc[pidx].offset = total_offset;
			urb->iso_frame_desc[pidx].length =
				GVUSB2_MAX_AUDIO_PACKET_SIZE;
			total_offset += GVUSB2_MAX_AUDIO_PACKET_SIZE;
		}
	}

	return 0;

free_urbs:
	gvusb2_snd_free_isoc(dev);
	return -ENOMEM;
}

/*****************************************************************************
 * Driver Stuff
 ****************************************************************************/

/*
 * Claim the first enabled slot that no live card holds. A slot stays
 * taken until its card is freed, which can be after the device is
 * unplugged if an app still has it open, so a quick replug never gets
 * handed an index= that is still in use.
 */
static int gvusb2_snd_claim_slot(void)
{
	int i, slot = -ENODEV;

	mutex_lock(&gvusb2_snd_slots_lock);
	for (i = 0; i < SNDRV_CARDS; i++) {
		if (card_enable[i] && !gvusb2_snd_slot_used[i]) {
			gvusb2_snd_slot_used[i] = true;
			slot = i;
			break;
		}
	}
	mutex_unlock(&gvusb2_snd_slots_lock);

	return slot;
}

static void gvusb2_snd_release_slot(int slot)
{
	mutex_lock(&gvusb2_snd_slots_lock);
	gvusb2_snd_slot_used[slot] = false;
	mutex_unlock(&gvusb2_snd_slots_lock);
}

/* runs when the card is finally freed, after the last close */
static void gvusb2_snd_card_free(struct snd_card *card)
{
	struct gvusb2_snd *dev = card->private_data;

	gvusb2_snd_free_isoc(dev);
	gvusb2_free(&dev->gv);
	gvusb2_snd_release_slot(dev->slot);
}

static int gvusb2_snd_probe(struct usb_interface *intf,
	const struct usb_device_id *id)
{
	struct usb_device *udev;
	struct snd_card *card;
	struct gvusb2_snd *dev;
	int i, ret, slot;
	struct usb_endpoint_descriptor *audio_ep = NULL;
	struct usb_host_interface *audio_alt = NULL;

	udev = interface_to_usbdev(intf);

	/*
	 * The GV-USB2 uses a proprietary audio transfer, but the chip has
	 * support for the USB audio class, so let's reject it if we see it.
	 */
	if (intf->altsetting[0].desc.bInterfaceClass == USB_CLASS_AUDIO)
		return -ENODEV;

	/* check if we're on the audio interface */
	for (i = 0; i < intf->num_altsetting; i++) {
		int ep;
		int num_endpoints = intf->altsetting[i].desc.bNumEndpoints;

		for (ep = 0; ep < num_endpoints; ep++) {
			struct usb_endpoint_descriptor *e =
				&intf->altsetting[i].endpoint[ep].desc;
			if (usb_endpoint_dir_in(e) &&
					e->bEndpointAddress == 0x84 &&
					usb_endpoint_xfer_isoc(e) &&
					le16_to_cpu(e->wMaxPacketSize) == 0x100) {
				audio_ep = e;
				audio_alt = &intf->altsetting[i];
				gvusb2_dbg(&intf->dev,
					"found audio at altsetting %d endpoint %d\n",
					i, ep);
			}
		}
	}

	/* if we don't have an audio device, we don't accept */
	if (audio_ep == NULL)
		return -ENODEV;

	slot = gvusb2_snd_claim_slot();
	if (slot < 0) {
		dev_err(&intf->dev,
			"no free " CARD_NAME " sound slot, check the enable= module parameter\n");
		return slot;
	}

	/* our state is allocated as part of the card */
	ret = snd_card_new(&intf->dev, card_index[slot], card_id[slot],
		THIS_MODULE, sizeof(*dev), &card);
	if (ret < 0) {
		gvusb2_snd_release_slot(slot);
		return ret;
	}

	dev = card->private_data;
	dev->card = card;
	dev->intf = intf;
	dev->ep = audio_ep;
	dev->slot = slot;
	spin_lock_init(&dev->lock);

	/*
	 * From here on snd_card_free() cleans up everything, slot included.
	 * gvusb2_snd_card_free() copes with the parts not set up yet.
	 */
	card->private_free = gvusb2_snd_card_free;

	/* initialize gvusb2 core stuff */
	ret = gvusb2_init(&dev->gv, udev);
	if (ret < 0)
		goto free_card;

	/* select the altsetting that carries the audio endpoint */
	ret = usb_set_interface(udev, audio_alt->desc.bInterfaceNumber,
		audio_alt->desc.bAlternateSetting);
	if (ret < 0)
		goto free_card;

	/* reset the adc */
	ret = gvusb2_snd_reset_adc(&dev->gv);
	if (ret < 0)
		goto free_card;

	/* allocate URBs */
	ret = gvusb2_snd_allocate_urbs(dev);
	if (ret < 0)
		goto free_card;

	/* initialize sound stuff */
	ret = gvusb2_snd_alsa_init(dev);
	if (ret < 0)
		goto free_card;

	/* attach our data to the interface */
	usb_set_intfdata(intf, dev);

	return 0;

free_card:
	/* runs gvusb2_snd_card_free() */
	snd_card_free(card);

	return ret;
}

static void gvusb2_snd_disconnect(struct usb_interface *intf)
{
	struct gvusb2_snd *dev;

	/* remove our data from the interface */
	dev = usb_get_intfdata(intf);
	usb_set_intfdata(intf, NULL);
	if (dev == NULL)
		return;

	/* stop running streams and refuse new opens */
	snd_card_disconnect(dev->card);

	/* make sure no completion handler is still touching the card */
	gvusb2_snd_cancel_isoc(dev);

	/*
	 * dev lives inside the card. It and the URBs are freed by
	 * gvusb2_snd_card_free() once the last open file is closed.
	 */
	snd_card_free_when_closed(dev->card);
}

static struct usb_driver gvusb2_snd_usb_driver = {
	.name = "gvusb2-snd",
	.probe = gvusb2_snd_probe,
	.disconnect = gvusb2_snd_disconnect,
	.id_table = gvusb2_id_table,
};

module_usb_driver(gvusb2_snd_usb_driver);
