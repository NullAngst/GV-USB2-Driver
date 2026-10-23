obj-m += gvusb2-core.o gvusb2-sound.o gvusb2-video.o

gvusb2-sound-y := gvusb2-snd.o
gvusb2-video-y := gvusb2-vid.o gvusb2-v4l2.o gvusb2-i2c.o

# Override on the command line to build for a kernel other than the
# running one, e.g. make KVER=7.0.0-38-generic
KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
