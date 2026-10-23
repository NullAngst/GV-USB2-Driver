Maintenance
===========

A checklist for reviewing this driver every six months, so it keeps building on new kernels and keeps working on real hardware.

Why bother? Because out-of-tree modules rot. The kernel's internal API has no stability promise, and this code went from 2020 to 2026 without a commit. By then it no longer built on Ubuntu's 7.0 kernel, mainline had dropped `strncpy` which it also used, and an i2c callback it relied on was deprecated. Small regular checks are cheaper than one big rescue.

Schedule: April and October, a few weeks after the Ubuntu release, since that's when a new distro kernel lands for most people.

- Last review: 2026-10-23
- Next review due: 2027-04

## What you need

- The GV-USB2, a composite or S-Video source, and ideally both an NTSC and a PAL source
- `v4l-utils` (for `v4l2-ctl` and `v4l2-compliance`), `alsa-utils`, ffmpeg
- `shellcheck`, `sparse`, git, and the build deps from the README
- About 3 GB of disk for a mainline kernel tree

## 1. Build against the kernels that matter

Three targets: the oldest kernel we support, whatever your distro runs now, and mainline.

1. Oldest supported is 6.8 (Ubuntu 24.04 GA). Install its headers and run `scripts/install.sh -k <6.8 version> -n`
2. Current distro kernel: `scripts/install.sh -n`
3. Mainline catches breakage months before a distro ships it. Get a tree ready once:

   ```
   git clone --depth 1 https://github.com/torvalds/linux.git ~/src/linux
   cd ~/src/linux
   cp /boot/config-$(uname -r) .config    # or whichever config you have
   scripts/config --disable MODVERSIONS --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
   make olddefconfig
   make -j"$(nproc)" modules_prepare
   ```

   On later reviews it's `git pull` (or a fresh shallow clone) and the last two commands again.

4. Build the driver against it with warnings on:

   ```
   make -C ~/src/linux M="$PWD" W=1 KBUILD_MODPOST_WARN=1 modules
   ```

   `KBUILD_MODPOST_WARN=1` is needed since `modules_prepare` doesn't produce a `Module.symvers`, so modpost can't resolve symbols. That's expected. Compiler errors and warnings are what you're looking for.

5. Run sparse against a kernel your sparse version understands: `make -C /lib/modules/$(uname -r)/build M="$PWD" C=2 modules`. If it prints "sparse is not available or not up to date", try older headers or a newer sparse.
6. Run checkpatch for style: `~/src/linux/scripts/checkpatch.pl --no-tree -f --terse *.c *.h`. The `LINUX_VERSION_CODE` warnings are expected in an out-of-tree driver. Ignore suggestions to use helpers that don't exist in the oldest supported kernel (like `kmalloc_obj`).

Zero warnings is the bar. A new warning today is a build failure in a year.

## 2. Kernel APIs to watch

Every one of these has already moved or is about to. Check each against current mainline:

| What | Where we use it | Status at last review |
|---|---|---|
| `vb2_ops.wait_prepare` / `wait_finish` | `gvusb2-v4l2.c` | vb2 handles `q->lock` itself since 6.13, the ops were removed by 7.0. Guarded with `< 6.13`. |
| `i2c_algorithm.master_xfer` | `gvusb2-i2c.c` | Renamed to `.xfer` in 6.11. `master_xfer` is deprecated and will be removed. Guarded with `>= 6.11`. |
| `strncpy` | (removed from our code) | Gone from mainline. Use `strscpy`. |
| `vb2_video_unregister_device` | `gvusb2-vid.c` disconnect | Stable. |
| `snd_pcm_set_managed_buffer_all` with `SNDRV_DMA_TYPE_VMALLOC` | `gvusb2-snd.c` | Stable. |
| `v4l2_i2c_new_subdev_board` | `gvusb2-v4l2.c` | Stable. |
| The `tw9910` driver itself | loaded as a subdevice | Still in mainline. Old soc-camera era code with few users, so a removal candidate. |

How to check quickly in a mainline tree:

```
grep -n 'wait_prepare\|min_queued' include/media/videobuf2-core.h
grep -n 'master_xfer\|(\*xfer)' include/linux/i2c.h
ls drivers/media/i2c/tw9910.c
grep -n 'priv->scale\s*=' drivers/media/i2c/tw9910.c
```

That last one matters. Our start_streaming calls the tw9910 `s_stream`, which refuses to run (and leaves the chip powered down and tri-stated after the previous stop) unless `priv->scale` was set. The tw9910 driver currently sets it at probe time. If that line moves out of `tw9910_video_probe`, a second capture session after the first one will get no video.

Two more tw9910 dependencies: its `s_std` writes the crop registers 0x07 to 0x0b, which our `gvusb2_tw9910_set_crop()` then overwrites at stream start, and its `s_stream(1)` sets the low bits of OPFORM (0x03) to 0. If either changes, check our numbers still win.

If tw9910 gets removed from mainline, the fix is moving the handful of register writes we need from it into `gvusb2-v4l2.c`. Don't vendor the whole driver.

When the oldest supported kernel passes 6.11 and 6.13, delete the `LINUX_VERSION_CODE` blocks and keep only the new side.

## 3. Distro check

For each distro you care about, confirm their current kernel still has what we link against. I use Kubuntu, so in my case:

```
grep -E 'CONFIG_(VIDEO_TW9910|VIDEOBUF2_VMALLOC|VIDEO_DEV|SND_PCM)=' /boot/config-$(uname -r)
```

All four should be `=m` or `=y`. On other distros the config is in `/boot` or `/proc/config.gz`, it depends on your system. `install.sh` checks this too, but it only sees the kernel you build for.

## 4. Hardware test

USE A NORMAL KERNEL, NOT ONE YOU CAN'T AFFORD TO CRASH. Some of these tests (unplug mid-capture) are exactly where a driver bug would oops.

1. Install the current build: `scripts/install.sh`
2. Plug in the GV-USB2, check `sudo dmesg | tail -20` for errors and `v4l2-ctl --list-devices` for the node
3. Run the V4L2 compliance suite, streaming included: `v4l2-compliance -d /dev/video0 -s`. Zero failures is the bar. Could be `/dev/video2` or similar, check the device list.
4. Capture 10 seconds of composite: `ffmpeg -f v4l2 -i /dev/video0 -t 10 composite.mkv`
5. Switch to S-Video and repeat: `v4l2-ctl -d /dev/video0 --set-input=1`, then the same ffmpeg command
6. Capture again straight away without replugging. This catches anything that breaks the second session (the tw9910 `s_stream` issue above).
7. Audio: `arecord -D hw:CARD=gvusb2 -f S16_LE -r 48000 -c 2 -d 10 test.wav`, then play it back. Run it twice in a row.
8. Audio and video together: `ffmpeg -f v4l2 -i /dev/video0 -f alsa -i hw:CARD=gvusb2 -t 30 av.mkv`. Check sync at the end of the clip.
9. If you have a PAL source: `v4l2-ctl -d /dev/video0 --set-standard=pal`, capture, check the frame is 720x576 and the bottom isn't garbage. The PAL crop values are untested guesses until someone does this.
10. Unplug the device in the middle of a capture. ffmpeg should error out, the kernel should not. Check `dmesg` for `WARNING`, `BUG` or `Oops`.
11. With the device plugged in and idle, `sudo modprobe -r gvusb2_video gvusb2_sound gvusb2_core` then `sudo modprobe gvusb2-video gvusb2-sound`. Both should work cleanly.
12. Close everything and check `dmesg` one last time.

If you want to go further, run steps 4 to 11 on a kernel built with `CONFIG_KASAN` and `CONFIG_PROVE_LOCKING`. That catches use-after-free and lock ordering bugs that a normal kernel lets slide.

## 5. Scripts

1. `shellcheck scripts/*.sh`, no warnings
2. Test `install.sh` on a distro or two that isn't yours. A container works for the build step, since it only needs headers:

   ```
   podman run --rm -v "$PWD":/src:Z docker.io/library/fedora:latest bash -c \
     'dnf install -y kernel-devel gcc make git kmod && k=$(ls /usr/src/kernels | head -n 1) && mkdir -p /lib/modules/$k && ln -s /usr/src/kernels/$k /lib/modules/$k/build && /src/scripts/install.sh -k "$k" -n'
   ```

   The symlink is there since `kernel-devel` alone doesn't create `/lib/modules/<version>/build`, the kernel package does. On Ubuntu, `apt-get install -y linux-headers-generic` creates it for you, so use `ls /lib/modules` to get the version. Same idea for whichever distro you want to check. Docker works the same.

3. Check the header package names in `install_build_deps()` still exist on each distro
4. Check the Secure Boot key paths (`/var/lib/shim-signed/mok/`, `/var/lib/dkms/`) haven't moved

## 6. Upstream and forks

Look at the original GV-USB2-Driver this was forked from (Isaac Lozano's) and any active forks for fixes worth pulling in. Check the issue tracker for bug reports while you're at it.

## 7. Close out

1. Update "Last review" and "Next review due" at the top
2. Update the tested kernels line in the README
3. Add a line to the log below
4. Commit

## Review log

| Date | Kernels built | Hardware tested | Notes |
|---|---|---|---|
| 2026-10-23 | 6.8, 6.14, 6.17, 7.0 (Ubuntu), mainline 7.4 merge window | No | Fixed build on 7.0+ (vb2 wait ops, strncpy), i2c busy-wait hang on unplug, ALSA crashes around open, close and unplug, ALSA index default, PAL frame size, unchecked errors throughout. Split shared code into gvusb2-core. Added install and update scripts. |
