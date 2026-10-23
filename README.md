GV-USB2 Linux Driver
====================

A Linux kernel driver for the I-O DATA GV-USB2 SD capture device (USB ID 04bb:0532), for anyone who wants composite or S-Video capture from it on Linux.

It builds three modules: `gvusb2-video` gives you a `/dev/videoN` V4L2 node (720x480 or 720x576 UYVY, interlaced), `gvusb2-sound` gives you an ALSA capture card named `gvusb2` (48 kHz stereo, S16_LE), and `gvusb2-core` holds the register code both of them share.

These are out-of-tree modules, so they're built against your kernel's headers and have to be rebuilt every time the kernel changes. The scripts in `scripts/` handle that.

## Prerequisites

- bash 4.4 or newer, git, make
- The C compiler your kernel was built with (the script tells you which one if it's missing)
- Headers for your kernel. I'm on Kubuntu, so in my case that's `linux-headers-$(uname -r)`. On Fedora it's `kernel-devel`, on Arch `linux-headers` (or whichever matches your kernel package), on openSUSE `kernel-default-devel`. `install.sh -d` installs the right one for you.
- Your kernel needs `CONFIG_VIDEO_TW9910` built, since the GV-USB2 has a TW9910 decoder chip. Ubuntu's kernels build it as a module. I haven't checked every distro, so the script checks your kernel config and warns if it's off.
- sudo or doas, for the install step

## Install

1. Clone the repo: `git clone https://github.com/NullAngst/GV-USB2-Driver.git`
2. Go into it: `cd GV-USB2-Driver`
3. Build, install and load: `scripts/install.sh`

   If you don't have headers or a compiler yet, run `scripts/install.sh -d` instead, since that installs them with your package manager first.

3.5. If you'd rather not clone by hand, grab only `scripts/install.sh` and run it. It clones the repo into `~/.local/src/GV-USB2-Driver` and builds from there.

4. Plug in the GV-USB2 and check it showed up: `v4l2-ctl --list-devices` and `arecord -l`

The modules go into `/lib/modules/<kernel>/updates/gvusb2/` and udev loads them whenever the device is plugged in.

## Updating

Run `scripts/update.sh` from the checkout. It pulls the latest code with `git pull --ff-only` and rebuilds for every installed kernel that has headers, since a kernel update breaks out-of-tree modules even when the driver code hasn't changed.

Run it after every kernel update. If you only installed a new kernel and haven't rebooted yet, run it anyway: it builds for the new kernel too, as long as that kernel's headers are installed.

It refuses to run if you have uncommitted changes to tracked files, so it never builds something that isn't on GitHub.

## Secure Boot

With Secure Boot on, the kernel only loads signed modules. The script looks for a key some other tool already made: Ubuntu's `/var/lib/shim-signed/mok/MOK.priv`, then DKMS's `/var/lib/dkms/mok.key`. If one exists, it signs with that. If you've installed a DKMS driver with Secure Boot on before, that key is most likely enrolled already. If modprobe then says "Key was rejected by service", it isn't: enroll the matching certificate with `sudo mokutil --import` and reboot.

If neither exists, the script stops and prints the commands to make and enroll a key. After enrolling, pass it in with `scripts/install.sh -K MOK.priv -C MOK.der`.

KEEP THE PRIVATE KEY PRIVATE. Anything signed with it gets loaded by your kernel.

## Options

`scripts/install.sh -h` has the full list. The useful ones:

- `-a` builds for every installed kernel with headers
- `-k VER` builds for one specific kernel, repeat it for more
- `-n` builds without installing, handy for checking a new kernel compiles
- `-l` installs without reloading the modules
- `-u` uninstalls from every kernel

`scripts/update.sh` takes the same options and passes them through. Give it `-k` or `-a` and it uses yours instead of building for all kernels.

## Capturing

Pick the input and standard first, since composite and NTSC are the defaults:

```
v4l2-ctl -d /dev/video0 --set-input=1        # 0 = Composite, 1 = S-Video
v4l2-ctl -d /dev/video0 --set-standard=ntsc  # or pal
```

Then capture with whatever you like. With ffmpeg:

```
ffmpeg -f v4l2 -i /dev/video0 -f alsa -i hw:CARD=gvusb2 -c:v ffv1 -c:a flac capture.mkv
```

Could be `/dev/video2` or something else on your machine, `v4l2-ctl --list-devices` tells you.

There are two extra controls, "Vertical Start" and "Horizontal Start", that shift the capture window if the picture is cut off at an edge.

## Troubleshooting

- `modprobe: ERROR: could not insert 'gvusb2_core': Key was rejected by service`: the module is signed with a key that isn't enrolled. See Secure Boot above.
- The build fails right after a kernel update: run `scripts/update.sh`. If it still fails, the kernel API moved, see `maintenance.md`.
- Debug output is off by default. Turn it on with `echo 'module gvusb2_video +p' | sudo tee /sys/kernel/debug/dynamic_debug/control` and watch `dmesg -w`.

## Status

Build-tested against Ubuntu's 6.8, 6.14, 6.17 and 7.0 kernels and mainline from the 7.4 merge window, all with `W=1` and no warnings. The October 2026 fixes haven't been run on hardware yet, and PAL has never been tested on a real PAL signal. `maintenance.md` has the six-month review checklist.

Now the driver is installed, rebuilds with one command after a kernel update, and the GV-USB2 shows up as a normal V4L2 device and ALSA card. Tinker with the capture window controls as you see fit.

## License

Dual licensed, GPL-2.0-only or BSD-3-Clause. See `LICENSE.gpl` and `LICENSE.bsd`.
