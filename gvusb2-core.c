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

#include "gvusb2.h"
#include "gvusb2-regs.h"

MODULE_DESCRIPTION("gvusb2 shared register access");
MODULE_AUTHOR("Isaac Lozano <109lozanoi@gmail.com>");
MODULE_LICENSE("Dual BSD/GPL");

int gvusb2_read_reg(struct gvusb2_dev *dev, u16 reg, u8 *value)
{
	int ret;
	int pipe = usb_rcvctrlpipe(dev->udev, 0);
	u8 *buf;

	*value = 0;

	/* usb_control_msg() needs a DMA-safe buffer, so no stack memory */
	buf = kmalloc(sizeof(u8), GFP_KERNEL);
	if (buf == NULL)
		return -ENOMEM;

	ret = usb_control_msg(dev->udev, pipe, 0x00,
		USB_DIR_IN | USB_TYPE_VENDOR | USB_RECIP_DEVICE,
		0x00, reg, buf, sizeof(u8), GVUSB2_CTRL_TIMEOUT_MS);
	if (ret >= 0 && ret != sizeof(u8))
		ret = -EIO;
	if (ret < 0) {
		dev_err_ratelimited(&dev->udev->dev,
			"read failed on reg 0x%04x (%d)\n", reg, ret);
		kfree(buf);
		return ret;
	}

	*value = *buf;

	kfree(buf);

	return 0;
}
EXPORT_SYMBOL_GPL(gvusb2_read_reg);

int gvusb2_write_reg(struct gvusb2_dev *dev, u16 reg, u8 value)
{
	int ret;
	int pipe = usb_sndctrlpipe(dev->udev, 0);

	ret = usb_control_msg(dev->udev, pipe, 0x01,
		USB_DIR_OUT | USB_TYPE_VENDOR | USB_RECIP_DEVICE,
		value, reg, NULL, 0, GVUSB2_CTRL_TIMEOUT_MS);
	if (ret < 0) {
		dev_err_ratelimited(&dev->udev->dev,
			"write failed on reg 0x%04x (%d)\n", reg, ret);
		return ret;
	}

	return 0;
}
EXPORT_SYMBOL_GPL(gvusb2_write_reg);

/*
 * The video and sound drivers each have their own gvusb2_dev but share
 * registers like the GPIO block at 0x0000/0x0002. One lock in this shared
 * module keeps a read-modify-write from one driver from undoing the
 * other's bits when both probe at once.
 */
static DEFINE_MUTEX(gvusb2_rmw_lock);

int gvusb2_set_reg_mask(struct gvusb2_dev *dev, u16 reg, u8 mask, u8 value)
{
	int ret;
	u8 reg_val;

	mutex_lock(&gvusb2_rmw_lock);

	ret = gvusb2_read_reg(dev, reg, &reg_val);
	if (ret >= 0)
		ret = gvusb2_write_reg(dev, reg, (reg_val & ~mask) | value);

	mutex_unlock(&gvusb2_rmw_lock);

	return ret;
}
EXPORT_SYMBOL_GPL(gvusb2_set_reg_mask);

int gvusb2_init(struct gvusb2_dev *dev, struct usb_device *udev)
{
	/*
	 * Hold a reference so register access from a late close() after
	 * an unplug fails cleanly instead of touching freed memory.
	 */
	dev->udev = usb_get_dev(udev);
	return 0;
}
EXPORT_SYMBOL_GPL(gvusb2_init);

int gvusb2_free(struct gvusb2_dev *dev)
{
	usb_put_dev(dev->udev);
	dev->udev = NULL;
	return 0;
}
EXPORT_SYMBOL_GPL(gvusb2_free);

int gvusb2_snd_reset_adc(struct gvusb2_dev *dev)
{
	int ret;

	/* set audio GPIO pins to output */
	ret = gvusb2_set_reg_mask(dev, 0x0002, 0x30, 0x30);
	if (ret < 0)
		return ret;
	ret = gvusb2_set_reg_mask(dev, 0x0000, 0x30, 0x10);
	if (ret < 0)
		return ret;

	/* disable AC97 interface */
	ret = gvusb2_write_reg(dev, 0x0500, 0x00);
	if (ret < 0)
		return ret;

	/* enable I2S interface */
	return gvusb2_write_reg(dev, 0x050c, 0x01);
}
EXPORT_SYMBOL_GPL(gvusb2_snd_reset_adc);
