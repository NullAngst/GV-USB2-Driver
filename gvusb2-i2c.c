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

#include <linux/i2c.h>
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <linux/usb.h>
#include <linux/version.h>

#include "gvusb2.h"
#include "gvusb2-vid.h"

/*
 * An i2c byte at our clock divider takes well under a millisecond. The old
 * 100-poll loop gave up after roughly 12 to 100 ms depending on the host,
 * so this keeps the same upper end.
 */
#define GVUSB2_I2C_TIMEOUT_MS 100

static int gvusb2_i2c_busy_wait(struct gvusb2_vid *dev, u8 wait_mask)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(GVUSB2_I2C_TIMEOUT_MS);
	int ret;
	u8 flag;

	/*
	 * Bound the wait by time, not by attempts. Each poll is a USB control
	 * transfer, and a device that answers slowly could otherwise stretch
	 * 100 attempts out to 100 seconds. Now the worst case is the deadline
	 * plus one control timeout.
	 */
	for (;;) {
		ret = gvusb2_read_reg(&dev->gv, 0x0201, &flag);
		if (ret < 0)
			return ret;
		if (flag & wait_mask)
			return 0;
		if (time_after(jiffies, deadline))
			return -ETIMEDOUT;
	}
}

static int gvusb2_i2c_read_reg(struct gvusb2_vid *dev, u8 addr, u8 reg,
	u8 *value)
{
	int ret;

	/* set i2c address */
	ret = gvusb2_write_reg(&dev->gv, 0x0203, (addr << 1) | 1);
	if (ret < 0)
		return ret;

	/* set i2c sub-address */
	ret = gvusb2_write_reg(&dev->gv, 0x0208, reg);
	if (ret < 0)
		return ret;

	/* start read */
	ret = gvusb2_write_reg(&dev->gv, 0x0200, 0x60);
	if (ret < 0)
		return ret;

	/* wait for read to go through */
	ret = gvusb2_i2c_busy_wait(dev, 0x01);
	if (ret < 0)
		return ret;

	ret = gvusb2_read_reg(&dev->gv, 0x0209, value);
	if (ret < 0)
		return ret;

	return 0;
}

static int gvusb2_i2c_write_reg(struct gvusb2_vid *dev, u8 addr, u8 reg,
	u8 value)
{
	int ret;

	/* set i2c address */
	ret = gvusb2_write_reg(&dev->gv, 0x0203, addr << 1);
	if (ret < 0)
		return ret;

	/* set i2c sub-address */
	ret = gvusb2_write_reg(&dev->gv, 0x0204, reg);
	if (ret < 0)
		return ret;

	/* set register value */
	ret = gvusb2_write_reg(&dev->gv, 0x0205, value);
	if (ret < 0)
		return ret;

	/* start write */
	ret = gvusb2_write_reg(&dev->gv, 0x0200, 0x05);
	if (ret < 0)
		return ret;

	/* wait for write to go through */
	ret = gvusb2_i2c_busy_wait(dev, 0x04);
	if (ret < 0)
		return ret;

	return 0;
}

static int gvusb2_i2c_xfer(struct i2c_adapter *i2c_adap, struct i2c_msg msgs[],
	int num)
{
	struct gvusb2_vid *dev = i2c_adap->algo_data;
	int ret, i;

	for (i = 0; i < num; i++) {
		dev_dbg(&dev->intf->dev,
			"gvusb2-i2c: addr=%02x", msgs[i].addr);

		if (i + 1 < num && msgs[i].len == 1 &&
		   ((msgs[i].flags & I2C_M_RD) == 0) &&
		   (msgs[i + 1].flags & I2C_M_RD) &&
		   msgs[i + 1].len == 1 &&
		   msgs[i].addr == msgs[i + 1].addr) {
			dev_dbg(&dev->intf->dev,
				" subaddr=%02x", msgs[i].buf[0]);

			ret = gvusb2_i2c_read_reg(dev, msgs[i].addr,
				msgs[i].buf[0], msgs[i + 1].buf);
			if (ret < 0) {
				dev_dbg(&dev->intf->dev, " ERR (%d)\n", ret);
				return ret;
			}

			dev_dbg(&dev->intf->dev,
				" read=%02x\n", msgs[i + 1].buf[0]);

			i++;
		} else if (msgs[i].len == 2 &&
			   (msgs[i].flags & I2C_M_RD) == 0) {
			dev_dbg(&dev->intf->dev, " subaddr=%02x write=%02x\n",
				msgs[i].buf[0], msgs[i].buf[1]);

			ret = gvusb2_i2c_write_reg(dev, msgs[i].addr,
				msgs[i].buf[0], msgs[i].buf[1]);
			if (ret < 0) {
				dev_dbg(&dev->intf->dev, " ERR (%d)\n", ret);
				return ret;
			}
		} else {
			dev_dbg(&dev->intf->dev, " EOPNOTSUPP\n");
			return -EOPNOTSUPP;
		}
	}

	return num;
}

static u32 gvusb2_i2c_functionality(struct i2c_adapter *adap)
{
	return I2C_FUNC_SMBUS_BYTE_DATA;
}

static const struct i2c_algorithm gvusb2_i2c_algo = {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 11, 0)
	/* master_xfer is deprecated since 6.11 and slated for removal */
	.xfer = gvusb2_i2c_xfer,
#else
	.master_xfer = gvusb2_i2c_xfer,
#endif
	.functionality = gvusb2_i2c_functionality,
};

int gvusb2_i2c_register(struct gvusb2_vid *dev)
{
	int ret;
	struct i2c_adapter *adap = &dev->adap;
	struct i2c_client *client = &dev->i2c_client;

	adap->owner = THIS_MODULE;
	adap->algo = &gvusb2_i2c_algo;
	adap->dev.parent = &dev->intf->dev;
	strscpy(adap->name, "gvusb2", sizeof(adap->name));
	/* maybe set this to just dev? */
	adap->algo_data = dev;

	ret = i2c_add_adapter(adap);
	if (ret < 0)
		return ret;

	/* for debugging */
	strscpy(client->name, "gvusb2 internal", sizeof(client->name));
	client->adapter = adap;
	client->addr = 0x44;

	/* set i2c clock divider */
	ret = gvusb2_write_reg(&dev->gv, 0x0202, 0x08);
	if (ret < 0)
		goto del_adapter;

	/* disable alternate i2c */
	ret = gvusb2_write_reg(&dev->gv, 0x02ff, 0x00);
	if (ret < 0)
		goto del_adapter;

	return 0;

del_adapter:
	i2c_del_adapter(adap);
	return ret;
}

int gvusb2_i2c_unregister(struct gvusb2_vid *dev)
{
	i2c_del_adapter(&dev->adap);
	return 0;
}
