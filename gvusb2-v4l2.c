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

#include <linux/kernel.h>
#include <linux/usb.h>
#include <linux/version.h>
#include <linux/videodev2.h>
#include <media/v4l2-dev.h>
#include <media/v4l2-event.h>
#include <media/v4l2-ioctl.h>
#include <media/videobuf2-v4l2.h>
#include <media/videobuf2-core.h>
#include <media/videobuf2-vmalloc.h>
#include <media/i2c/tw9910.h>

#include "gvusb2-vid.h"

/*****************************************************************************
 * Helper functions
 ****************************************************************************/

struct i2c_regval {
	u8 reg;
	u8 val;
};

void get_resolution(struct gvusb2_vid *dev, int *width, int *height)
{
	/*
	 * Match on the line count, not one exact standard. S_STD hands us
	 * masks like V4L2_STD_PAL, which never equaled V4L2_STD_PAL_B and
	 * so used to fall through to 480 lines.
	 */
	if (width != NULL)
		*width = 720;
	if (height != NULL)
		*height = (dev->standard & V4L2_STD_625_50) ? 576 : 480;
}

static bool gvusb2_is_625_50(struct gvusb2_vid *dev)
{
	return (dev->standard & V4L2_STD_625_50) != 0;
}

/*
 * Capture window in the STK1150. Start values come from the custom
 * controls, the end is start plus one field (vertical) or one line of
 * UYVY bytes (horizontal). For NTSC this writes the same values the
 * driver always wrote.
 */
static int gvusb2_set_vstart(struct gvusb2_vid *dev, s32 vstart)
{
	int height, ret;
	u16 end;

	get_resolution(dev, NULL, &height);
	end = vstart + height / 2;

	ret = gvusb2_write_reg(&dev->gv, 0x0112, vstart & 0xff);
	if (!ret)
		ret = gvusb2_write_reg(&dev->gv, 0x0113, (vstart >> 8) & 0xff);
	if (!ret)
		ret = gvusb2_write_reg(&dev->gv, 0x0116, end & 0xff);
	if (!ret)
		ret = gvusb2_write_reg(&dev->gv, 0x0117, end >> 8);

	return ret;
}

static int gvusb2_set_hstart(struct gvusb2_vid *dev, s32 hstart)
{
	int width, ret;
	u16 end;

	get_resolution(dev, &width, NULL);
	end = hstart + width * 2;

	ret = gvusb2_write_reg(&dev->gv, 0x0110, hstart & 0xff);
	if (!ret)
		ret = gvusb2_write_reg(&dev->gv, 0x0111, (hstart >> 8) & 0xff);
	if (!ret)
		ret = gvusb2_write_reg(&dev->gv, 0x0114, end & 0xff);
	if (!ret)
		ret = gvusb2_write_reg(&dev->gv, 0x0115, end >> 8);

	return ret;
}

/*
 * TW9910 cropping (regs 0x07-0x0b). The NTSC numbers are the hand-tuned
 * ones from the "fixed tw9910 cropping" commit. The 625-line numbers
 * apply the same offsets to the tw9910 driver's PAL defaults and have
 * not been checked on real PAL hardware.
 */
static int gvusb2_tw9910_set_crop(struct gvusb2_vid *dev)
{
	s32 reg_07;
	u8 crop_hi, vdelay_lo, vactive_lo;
	int ret;

	reg_07 = i2c_smbus_read_byte_data(&dev->i2c_client, 0x07);
	if (reg_07 < 0)
		return reg_07;

	if (gvusb2_is_625_50(dev)) {
		/* vdelay 25, vactive 292 */
		crop_hi = (reg_07 & 0x0f) | 0x10;
		vdelay_lo = 0x19;
		vactive_lo = 0x24;
	} else {
		/* vdelay 19, vactive 244 */
		crop_hi = reg_07 & 0x0f;
		vdelay_lo = 0x13;
		vactive_lo = 0xf4;
	}

	ret = i2c_smbus_write_byte_data(&dev->i2c_client, 0x07, crop_hi);
	if (!ret)
		ret = i2c_smbus_write_byte_data(&dev->i2c_client, 0x08,
			vdelay_lo);
	if (!ret)
		ret = i2c_smbus_write_byte_data(&dev->i2c_client, 0x09,
			vactive_lo);
	/* hdelay 18, hactive 722 */
	if (!ret)
		ret = i2c_smbus_write_byte_data(&dev->i2c_client, 0x0a, 0x12);
	if (!ret)
		ret = i2c_smbus_write_byte_data(&dev->i2c_client, 0x0b, 0xd2);

	return ret;
}

void gvusb2_vid_clear_queue(struct gvusb2_vid *dev,
	enum vb2_buffer_state state)
{
	struct gvusb2_vb *buf;
	unsigned long flags;

	spin_lock_irqsave(&dev->buf_list_lock, flags);
	while (!list_empty(&dev->buf_list)) {
		buf = list_first_entry(&dev->buf_list,
			struct gvusb2_vb, list);
		list_del(&buf->list);
		vb2_buffer_done(&buf->vb.vb2_buf, state);
	}

	if (dev->current_buf) {
		vb2_buffer_done(&dev->current_buf->vb.vb2_buf, state);
		dev->current_buf = NULL;
	}
	spin_unlock_irqrestore(&dev->buf_list_lock, flags);
}

/*****************************************************************************
 * Videobuf2 functions
 ****************************************************************************/

static int gvusb2_vb2_queue_setup(struct vb2_queue *vb2q,
	unsigned int *nbuffers,
	unsigned int *nplanes,
	unsigned int sizes[],
	struct device *alloc_devs[])
{
	struct gvusb2_vid *dev = vb2_get_drv_priv(vb2q);
	int width, height;
	unsigned long size;

	/* Size in bytes of a single frame */
	/* 2 pixels is 4 bytes */
	get_resolution(dev, &width, &height);
	size = width * height * 2;

	/* CREATE_BUFS: the program picked the size, check it fits a frame */
	if (*nplanes) {
		if (*nplanes != 1 || sizes[0] < size)
			return -EINVAL;
		return 0;
	}

	/* REQBUFS: ask for at least 4 buffers and one frame per buffer */
	if (*nbuffers < 4)
		*nbuffers = 4;
	*nplanes = 1;
	sizes[0] = size;

	return 0;
}

/*
 * S_STD runs under v4l2_lock and REQBUFS under vb2q_lock, so a standard
 * change can slip in while buffers are being allocated for the old one.
 * Checking every buffer against the current frame size when it is queued
 * turns that into a clean -EINVAL instead of truncated frames.
 */
static int gvusb2_vb2_buf_prepare(struct vb2_buffer *vb)
{
	struct gvusb2_vid *dev = vb2_get_drv_priv(vb->vb2_queue);
	int width, height;

	get_resolution(dev, &width, &height);
	if (vb2_plane_size(vb, 0) < (unsigned long)width * height * 2)
		return -EINVAL;

	return 0;
}

static void gvusb2_vb2_buf_queue(struct vb2_buffer *vb)
{
	unsigned long flags;
	struct gvusb2_vid *dev = vb2_get_drv_priv(vb->vb2_queue);
	struct vb2_v4l2_buffer *vbuf = to_vb2_v4l2_buffer(vb);
	struct gvusb2_vb *gvusb2_vbuf =
		container_of(vbuf, struct gvusb2_vb, vb);

	spin_lock_irqsave(&dev->buf_list_lock, flags);

	gvusb2_vbuf->buf_pos = 0;
	gvusb2_vbuf->line_pos = 0;
	gvusb2_vbuf->field = 0;
	list_add_tail(&gvusb2_vbuf->list, &dev->buf_list);

	spin_unlock_irqrestore(&dev->buf_list_lock, flags);
}

static int gvusb2_vb2_start_streaming(struct vb2_queue *vb2q,
					unsigned int count)
{
	int ret;
	struct gvusb2_vid *dev = vb2_get_drv_priv(vb2q);

	mutex_lock(&dev->v4l2_lock);

	/* set seq to 0 */
	dev->sequence = 0;

	/* set cropping in the decoder and the capture window in the bridge */
	ret = gvusb2_tw9910_set_crop(dev);
	if (ret < 0)
		goto err;
	ret = gvusb2_set_vstart(dev, v4l2_ctrl_g_ctrl(dev->ctrl_vstart));
	if (ret < 0)
		goto err;
	ret = gvusb2_set_hstart(dev, v4l2_ctrl_g_ctrl(dev->ctrl_hstart));
	if (ret < 0)
		goto err;

	/* start tw9910 */
	v4l2_device_call_all(&dev->v4l2_dev, 0, video, s_stream, 1);

	/* start gvusb2 */
	ret = gvusb2_write_reg(&dev->gv, 0x0100, 0xb3);
	if (ret < 0)
		goto err_stop_tw9910;
	/* probably don't need to set no VBI */
	gvusb2_write_reg(&dev->gv, 0x0103, 0x00);

	/* submit urbs */
	ret = gvusb2_vid_submit_urbs(dev);
	if (ret < 0)
		goto err_stop_bridge;

	mutex_unlock(&dev->v4l2_lock);

	return 0;

err_stop_bridge:
	gvusb2_write_reg(&dev->gv, 0x0100, 0x33);
err_stop_tw9910:
	v4l2_device_call_all(&dev->v4l2_dev, 0, video, s_stream, 0);
err:
	/* vb2 requires failed start_streaming to give buffers back queued */
	gvusb2_vid_clear_queue(dev, VB2_BUF_STATE_QUEUED);
	mutex_unlock(&dev->v4l2_lock);

	return ret;
}

static void gvusb2_vb2_stop_streaming(struct vb2_queue *vb2q)
{
	struct gvusb2_vid *dev = vb2_get_drv_priv(vb2q);

	/*
	 * Not interruptible: bailing out here would leave URBs writing
	 * into buffers vb2 is about to free.
	 */
	mutex_lock(&dev->v4l2_lock);

	/* cancel urbs */
	gvusb2_vid_cancel_urbs(dev);

	/* after an unplug there is nothing left to talk to */
	if (dev->gv.udev->state != USB_STATE_NOTATTACHED) {
		/* stop gvusb2 */
		gvusb2_write_reg(&dev->gv, 0x0100, 0x33);
		/* probably don't need to set no VBI */
		gvusb2_write_reg(&dev->gv, 0x0103, 0x00);

		/* stop tw9910 */
		v4l2_device_call_all(&dev->v4l2_dev, 0, video, s_stream, 0);
	}

	/* clear queue */
	gvusb2_vid_clear_queue(dev, VB2_BUF_STATE_ERROR);

	mutex_unlock(&dev->v4l2_lock);
}

static const struct vb2_ops gvusb2_vb2_ops = {
	.queue_setup     = gvusb2_vb2_queue_setup,
	.buf_prepare     = gvusb2_vb2_buf_prepare,
	.buf_queue       = gvusb2_vb2_buf_queue,
	.start_streaming = gvusb2_vb2_start_streaming,
	.stop_streaming  = gvusb2_vb2_stop_streaming,
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 13, 0)
	/*
	 * 6.13 and later drop vq->lock around blocking waits on their own,
	 * and 7.0 removed these two ops entirely.
	 */
	.wait_prepare    = vb2_ops_wait_prepare,
	.wait_finish     = vb2_ops_wait_finish,
#endif
};

int gvusb2_vb2_setup(struct gvusb2_vid *dev)
{
	int ret;
	struct vb2_queue *vb2q;

	/* init our vb2 lock */
	mutex_init(&dev->vb2q_lock);

	vb2q = &dev->vb2q;
	vb2q->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	vb2q->io_modes = VB2_MMAP | VB2_READ | VB2_USERPTR;
	vb2q->drv_priv = dev;
	vb2q->buf_struct_size = sizeof(struct gvusb2_vb);
	vb2q->ops = &gvusb2_vb2_ops;
	vb2q->mem_ops = &vb2_vmalloc_memops;
	vb2q->lock = &dev->vb2q_lock;
	/* buffers are stamped with ktime_get_ns(), a monotonic clock */
	vb2q->timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC;

	INIT_LIST_HEAD(&dev->buf_list);
	spin_lock_init(&dev->buf_list_lock);

	ret = vb2_queue_init(vb2q);
	if (ret < 0) {
		mutex_destroy(&dev->vb2q_lock);
		return ret;
	}

	return 0;
}

/*****************************************************************************
 * V4L2 Control Functions
 ****************************************************************************/

static int gvusb2_s_ctrl(struct v4l2_ctrl *ctrl)
{
	struct gvusb2_vid *dev = container_of(ctrl->handler,
		struct gvusb2_vid, ctrl_handler);
	struct i2c_client *client = &dev->i2c_client;
	int ret = 0;

	switch (ctrl->id) {
	case V4L2_CID_BRIGHTNESS:
		ret = i2c_smbus_write_byte_data(client, 0x10,
			(ctrl->val + 0x80) & 0xff);
		break;
	case V4L2_CID_CONTRAST:
		ret = i2c_smbus_write_byte_data(client, 0x11, ctrl->val);
		break;
	case V4L2_CID_SATURATION:
		ret = i2c_smbus_write_byte_data(client, 0x13, ctrl->val);
		if (!ret)
			ret = i2c_smbus_write_byte_data(client, 0x14,
				ctrl->val);
		break;
	case V4L2_CID_HUE:
		ret = i2c_smbus_write_byte_data(client, 0x15,
			(ctrl->val + 0x80) & 0xff);
		break;
	case V4L2_CID_SHARPNESS:
		ret = i2c_smbus_write_byte_data(client, 0x12,
			(ctrl->val & 0x0f) | 0x50);
		break;
	case GVUSB2_CID_VERTICAL_START:
		ret = gvusb2_set_vstart(dev, ctrl->val);
		break;
	case GVUSB2_CID_HORIZONTAL_START:
		ret = gvusb2_set_hstart(dev, ctrl->val);
		break;
	default:
		ret = -EINVAL;
		break;
	}

	return ret < 0 ? ret : 0;
}

static const struct v4l2_ctrl_ops gvusb2_ctrl_ops = {
	.s_ctrl = gvusb2_s_ctrl,
};

static const struct v4l2_ctrl_config gvusb2_ctrl_vertical = {
	.ops = &gvusb2_ctrl_ops,
	.id = GVUSB2_CID_VERTICAL_START,
	.name = "Vertical Start",
	.type = V4L2_CTRL_TYPE_INTEGER,
	.flags = V4L2_CTRL_FLAG_SLIDER,
	.min = 1,
	.max = 4,
	.step = 1,
	.def = 2,
};

static const struct v4l2_ctrl_config gvusb2_ctrl_horizontal = {
	.ops = &gvusb2_ctrl_ops,
	.id = GVUSB2_CID_HORIZONTAL_START,
	.name = "Horizontal Start",
	.type = V4L2_CTRL_TYPE_INTEGER,
	.flags = V4L2_CTRL_FLAG_SLIDER,
	.min = 0,
	.max = 8,
	.step = 4,
	.def = 4,
};

/*****************************************************************************
 * Video4Linux2 functions
 ****************************************************************************/

static int gvusb2_vidioc_querycap(struct file *file, void *priv,
	struct v4l2_capability *cap)
{
	struct gvusb2_vid *dev = video_drvdata(file);

	strscpy(cap->driver, "gvusb2", sizeof(cap->driver));
	strscpy(cap->card, "gvusb2", sizeof(cap->card));
	usb_make_path(dev->gv.udev, cap->bus_info, sizeof(cap->bus_info));

	return 0;
}

static int gvusb2_vidioc_enum_input(struct file *file, void *priv,
	struct v4l2_input *i)
{
	struct gvusb2_vid *dev = video_drvdata(file);

	switch (i->index) {
	case GVUSB2_INPUT_COMPOSITE:
		strscpy(i->name, "Composite", sizeof(i->name));
		break;
	case GVUSB2_INPUT_SVIDEO:
		strscpy(i->name, "S-Video", sizeof(i->name));
		break;
	default:
		return -EINVAL;
	}

	i->type = V4L2_INPUT_TYPE_CAMERA;
	i->capabilities = V4L2_IN_CAP_STD;
	i->std = dev->vdev.tvnorms;

	return 0;
}

static int gvusb2_vidioc_g_input(struct file *file, void *priv, unsigned int *i)
{
	struct gvusb2_vid *dev = video_drvdata(file);

	*i = dev->input_num;

	return 0;
}

static int gvusb2_vidioc_s_input(struct file *file, void *priv, unsigned int i)
{
	struct gvusb2_vid *dev = video_drvdata(file);
	u8 val;
	s32 reg;

	switch (i) {
	case GVUSB2_INPUT_COMPOSITE:
		/* set Composite and Mux 0 */
		val = 0x00;
		break;
	case GVUSB2_INPUT_SVIDEO:
		/* set S-Video and Mux 1 */
		val = 0x14;
		break;
	default:
		return -EINVAL;
	}

	reg = i2c_smbus_read_byte_data(&dev->i2c_client, 0x02);
	if (reg < 0)
		return reg;

	reg = i2c_smbus_write_byte_data(&dev->i2c_client, 0x02,
		(reg & 0xc3) | val);
	if (reg < 0)
		return reg;

	dev->input_num = i;

	return 0;
}

static int gvusb2_vidioc_querystd(struct file *file, void *priv,
	v4l2_std_id *std)
{
	struct gvusb2_vid *dev = video_drvdata(file);

	/* we can't querystd with the current tw9910 driver */
	*std = dev->vdev.tvnorms;

	return 0;
}

static int gvusb2_vidioc_g_std(struct file *file, void *priv, v4l2_std_id *std)
{
	struct gvusb2_vid *dev = video_drvdata(file);

	*std = dev->standard;

	return 0;
}

static int gvusb2_vidioc_s_std(struct file *file, void *priv, v4l2_std_id std)
{
	struct gvusb2_vid *dev = video_drvdata(file);
	struct vb2_queue *vb2q = &dev->vb2q;

	if (std == dev->standard)
		return 0;

	if (vb2_is_busy(vb2q))
		return -EBUSY;

	/*
	 * The tw9910 subdev only accepts NTSC and PAL and its result is
	 * ignored, as before: the decoder auto-detects, the standard here
	 * mostly picks the frame height. New window values land at the next
	 * STREAMON.
	 */
	dev->standard = std;
	v4l2_device_call_all(&dev->v4l2_dev, 0, video, s_std, std);

	return 0;
}

static int gvusb2_vidioc_enum_fmt_vid_cap(struct file *file, void *priv,
	struct v4l2_fmtdesc *f)
{
	if (f->index != 0)
		return -EINVAL;

	f->pixelformat = V4L2_PIX_FMT_UYVY;

	return 0;
}

static void gvusb2_fill_pix_format(struct gvusb2_vid *dev,
	struct v4l2_pix_format *pix)
{
	int width, height;

	get_resolution(dev, &width, &height);
	pix->width = width;
	pix->height = height;
	pix->field = V4L2_FIELD_INTERLACED;
	pix->pixelformat = V4L2_PIX_FMT_UYVY;
	pix->bytesperline = width * 2;
	pix->sizeimage = height * width * 2;
	pix->colorspace = gvusb2_is_625_50(dev) ?
		V4L2_COLORSPACE_470_SYSTEM_BG : V4L2_COLORSPACE_SMPTE170M;
}

static int gvusb2_vidioc_g_fmt_vid_cap(struct file *file, void *priv,
	struct v4l2_format *f)
{
	struct gvusb2_vid *dev = video_drvdata(file);

	gvusb2_fill_pix_format(dev, &f->fmt.pix);

	return 0;
}

static int gvusb2_vidioc_s_fmt_vid_cap(struct file *file, void *priv,
	struct v4l2_format *f)
{
	struct gvusb2_vid *dev = video_drvdata(file);

	if (vb2_is_busy(&dev->vb2q))
		return -EBUSY;

	gvusb2_fill_pix_format(dev, &f->fmt.pix);

	return 0;
}

static int gvusb2_vidioc_try_fmt_vid_cap(struct file *file, void *priv,
	struct v4l2_format *f)
{
	struct gvusb2_vid *dev = video_drvdata(file);

	gvusb2_fill_pix_format(dev, &f->fmt.pix);

	return 0;
}

static const struct v4l2_ioctl_ops gvusb2_v4l2_ioctl_ops = {
	.vidioc_querycap          = gvusb2_vidioc_querycap,
	.vidioc_enum_input        = gvusb2_vidioc_enum_input,
	.vidioc_g_input           = gvusb2_vidioc_g_input,
	.vidioc_s_input           = gvusb2_vidioc_s_input,
	.vidioc_querystd          = gvusb2_vidioc_querystd,
	.vidioc_g_std             = gvusb2_vidioc_g_std,
	.vidioc_s_std             = gvusb2_vidioc_s_std,
	.vidioc_enum_fmt_vid_cap  = gvusb2_vidioc_enum_fmt_vid_cap,
	.vidioc_g_fmt_vid_cap     = gvusb2_vidioc_g_fmt_vid_cap,
	.vidioc_s_fmt_vid_cap     = gvusb2_vidioc_s_fmt_vid_cap,
	.vidioc_try_fmt_vid_cap   = gvusb2_vidioc_try_fmt_vid_cap,

	.vidioc_reqbufs           = vb2_ioctl_reqbufs,
	.vidioc_querybuf          = vb2_ioctl_querybuf,
	.vidioc_qbuf              = vb2_ioctl_qbuf,
	.vidioc_dqbuf             = vb2_ioctl_dqbuf,
	.vidioc_create_bufs       = vb2_ioctl_create_bufs,
	.vidioc_streamon          = vb2_ioctl_streamon,
	.vidioc_streamoff         = vb2_ioctl_streamoff,
	.vidioc_expbuf            = vb2_ioctl_expbuf,

	.vidioc_log_status        = v4l2_ctrl_log_status,
	.vidioc_subscribe_event   = v4l2_ctrl_subscribe_event,
	.vidioc_unsubscribe_event = v4l2_event_unsubscribe,
};

static struct tw9910_video_info gvusb2_tw9910_video_info = {
	.buswidth = 8,
	.mpout = TW9910_MPO_FIELD,
};

static struct i2c_board_info gvusb2_tw9910_i2c_board_info = {
	.type = "tw9910",
	.addr = 0x44,
	.platform_data = &gvusb2_tw9910_video_info,
};

int gvusb2_v4l2_register(struct gvusb2_vid *dev)
{
	int i;
	int ret;

	static const struct i2c_regval phase6[] = {
			{0x06, 0x00},
			{0x03, 0xa2},
			{0x05, 0x01},
			{0x19, 0xde},
			{0x1a, 0x0f},
			{0x1b, 0x00},
			{0x6e, 0x28},
			{0x06, 0x80},
			{0xff, 0xff}
	};

	/* init our v4l2 lock */
	mutex_init(&dev->v4l2_lock);

	/* make our ctrl handler */
	ret = v4l2_ctrl_handler_init(&dev->ctrl_handler, 7);
	if (ret < 0)
		goto destroy_lock;

	dev->v4l2_dev.release = gvusb2_release;
	dev->v4l2_dev.ctrl_handler = &dev->ctrl_handler;

	/* register controls */
	v4l2_ctrl_new_std(&dev->ctrl_handler, &gvusb2_ctrl_ops,
		V4L2_CID_BRIGHTNESS, 0, 255, 1, 128);
	v4l2_ctrl_new_std(&dev->ctrl_handler, &gvusb2_ctrl_ops,
		V4L2_CID_CONTRAST, 0, 255, 1, 128);
	v4l2_ctrl_new_std(&dev->ctrl_handler, &gvusb2_ctrl_ops,
		V4L2_CID_SATURATION, 0, 255, 1, 128);
	v4l2_ctrl_new_std(&dev->ctrl_handler, &gvusb2_ctrl_ops,
		V4L2_CID_HUE, 0, 255, 1, 128);
	v4l2_ctrl_new_std(&dev->ctrl_handler, &gvusb2_ctrl_ops,
		V4L2_CID_SHARPNESS, 0, 15, 1, 0);
	dev->ctrl_vstart = v4l2_ctrl_new_custom(&dev->ctrl_handler,
		&gvusb2_ctrl_vertical, NULL);
	dev->ctrl_hstart = v4l2_ctrl_new_custom(&dev->ctrl_handler,
		&gvusb2_ctrl_horizontal, NULL);

	if (dev->ctrl_handler.error) {
		ret = dev->ctrl_handler.error;
		goto free_ctrl_handler;
	}

	ret = v4l2_device_register(&dev->intf->dev, &dev->v4l2_dev);
	if (ret < 0)
		goto free_ctrl_handler;

	/* load tw9910 driver */
	dev->sd_tw9910 = v4l2_i2c_new_subdev_board(&dev->v4l2_dev, &dev->adap,
		&gvusb2_tw9910_i2c_board_info, NULL);
	if (dev->sd_tw9910 == NULL)
		dev_warn(&dev->intf->dev,
			"tw9910 subdevice not available, is the tw9910 module built for this kernel? Streaming start/stop and S_STD will not reach the decoder\n");

	/* init tw9910 */
	for (i = 0; phase6[i].reg != 0xff; i++) {
		ret = i2c_smbus_write_byte_data(&dev->i2c_client,
			phase6[i].reg, phase6[i].val);
		if (ret < 0)
			goto unregister_v4l2;
	}

	/* set STK1150 to always double word */
	/* not quite sure the importance */
	ret = gvusb2_set_reg_mask(&dev->gv, 0x05f0, 0x08, 0x08);
	if (ret < 0)
		goto unregister_v4l2;

	/*
	 * Push control defaults to the hardware last, so the decoder init
	 * above can't leave the chip out of step with what the controls
	 * report.
	 */
	ret = v4l2_ctrl_handler_setup(&dev->ctrl_handler);
	if (ret < 0)
		goto unregister_v4l2;

	return 0;

unregister_v4l2:
	v4l2_device_unregister(&dev->v4l2_dev);
free_ctrl_handler:
	v4l2_ctrl_handler_free(&dev->ctrl_handler);
destroy_lock:
	mutex_destroy(&dev->v4l2_lock);

	return ret;
}

void gvusb2_v4l2_unregister(struct gvusb2_vid *dev)
{
	v4l2_device_unregister(&dev->v4l2_dev);
	v4l2_ctrl_handler_free(&dev->ctrl_handler);
	mutex_destroy(&dev->v4l2_lock);
}

static const struct v4l2_file_operations gvusb2_v4l2_fops = {
	.owner = THIS_MODULE,
	.open = v4l2_fh_open,
	.release = vb2_fop_release,
	.read = vb2_fop_read,
	.poll = vb2_fop_poll,
	.mmap = vb2_fop_mmap,
	.unlocked_ioctl = video_ioctl2,
};

static const struct video_device gvusb2_video_device_template = {
	.name = "gvusb2",
	.device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING |
		V4L2_CAP_READWRITE,
	.tvnorms = V4L2_STD_525_60 | V4L2_STD_625_50,
	.vfl_dir = VFL_DIR_RX,
	.fops = &gvusb2_v4l2_fops,
	.ioctl_ops = &gvusb2_v4l2_ioctl_ops,
	.release = video_device_release_empty,
};

int gvusb2_video_register(struct gvusb2_vid *dev)
{
	int ret;

	/* init vdev data */
	dev->vdev = gvusb2_video_device_template;

	dev->vdev.v4l2_dev = &dev->v4l2_dev;
	dev->vdev.queue = &dev->vb2q;
	dev->vdev.lock = &dev->v4l2_lock;

	/* set standard for device */
	dev->standard = V4L2_STD_NTSC_M;

	/* set standard for sub-devices */
	v4l2_device_call_all(&dev->v4l2_dev, 0, video, s_std,
		dev->standard);

	video_set_drvdata(&dev->vdev, dev);
	ret = video_register_device(&dev->vdev, VFL_TYPE_VIDEO, -1);
	if (ret < 0)
		return ret;

	return 0;
}
