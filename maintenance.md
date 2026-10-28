Maintenance
===========

A checklist for reviewing this driver every six months, so it keeps building on new kernels and keeps working on real hardware.

Why bother? Because out-of-tree modules rot. The kernel's internal API has no stability promise, and this code went from 2020 to 2026 without a commit. By then it no longer built on Ubuntu's 7.0 kernel, mainline had dropped `strncpy` which it also used, and an i2c callback it relied on was deprecated. Small regular checks are cheaper than one big rescue.

Schedule: April and October, a few weeks after the Ubuntu release, since that's when a new distro kernel lands for most people.

- Last review: 2026-10-24
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
7. Audio: `arecord -D hw:CARD=gvusb2 -f S16_LE -r 48000 -c 2 -d 10 test.wav`, then play it back. Run it twice in a row. No `overrun!!!` lines. `arecord -v` should show a buffer_size that is a whole multiple of period_size.
8. Audio and video together: `ffmpeg -f v4l2 -i /dev/video0 -f alsa -i hw:CARD=gvusb2 -t 30 av.mkv`. Check sync at the end of the clip.
9. If you have a PAL source: `v4l2-ctl -d /dev/video0 --set-standard=pal`, capture, check the frame is 720x576 and the bottom isn't garbage. The PAL crop values are untested guesses until someone does this.
9.4. Set Horizontal Start to 8 (`v4l2-ctl -d /dev/video0 -c horizontal_start=8`), capture 10 seconds, and check the right edge is clean and the stream doesn't stall. Then set it back to 4.
9.3. Signal status. Start a capture in one terminal (`ffmpeg -f v4l2 -i /dev/video0 -t 60 -f null -`) and in another run `v4l2-ctl -d /dev/video0 --get-input --get-detected-standard` three times: tape playing (expect `ok` and NTSC), S-Video cable pulled (expect `no signal` and an unknown standard; a stopped VCR's blue screen is a real locked signal, so it reads `ok`), and fast-forward (expect lock flags coming and going). Also on a black and white source: `no color`.
9.5. Check the field order against the picture, on a source with motion: `ffmpeg -i composite.mkv -vf idet -an -f null - 2>&1 | grep "Multi frame"`. TFF should have nearly all the frames. If BFF wins, the field assembly in `gvusb2-vid.c` changed and `GVUSB2_FIELD_ORDER` in `gvusb2-vid.h` no longer matches it. Do it for PAL too if you have a source.
10. Unplug the device in the middle of a capture. ffmpeg should error out, the kernel should not. Check `dmesg` for `WARNING`, `BUG` or `Oops`.
11. With the device plugged in and idle, `sudo modprobe -r gvusb2_video gvusb2_sound gvusb2_core` then `sudo modprobe gvusb2-video gvusb2-sound`. Both should work cleanly.
12. Close everything and check `dmesg` one last time.

If you want to go further, run steps 4 to 11 on a kernel built with `CONFIG_KASAN` and `CONFIG_PROVE_LOCKING`. That catches use-after-free and lock ordering bugs that a normal kernel lets slide.

## 5. Scripts

1. `shellcheck scripts/*.sh`, no warnings
1.5. Check the scripts' security rules still hold. These came out of the October 2026 security review and are easy to break by accident:
   - Kernel versions from `-k` and from `/lib/modules` go through `valid_kver` before they touch a path.
   - Every kernel's module directory passes `moddir_ok` before anything is deleted or installed, for all kernels up front. A kernel that then fails to build is skipped, untouched, and the rest carry on; the run lists it and exits non-zero.
   - The checkout and every kernel header tree pass `mine_only` before git or make touch them: owned by the user or root, writable by nobody else, no ACLs. The checkout is only taken from the script's location when the script really sits in a checkout's `scripts/` folder.
   - Every ownership check also runs `acl_write`, since `find -perm` can't see ACLs. It only refuses entries that give someone else write access (after the ACL mask). Read-only entries are normal, since desktop setups add them to home directories, and refusing those broke installs for anyone with one. It decides on awk's output, never the pipeline's exit status, so it can't fail open.
   - Files deleted as root go through `remove_old_modules` (`find ... -exec rm`), never a `while read` loop over `find` output, since newlines in file names turn into extra paths.
   - New modules are staged as `.staged-<name>.ko`, checked, signed, and only then swapped in, so a failure leaves the old install working. The exit trap removes staged files on any exit, Ctrl-C included, and `remove_old_modules` (so `-u`) also removes stale ones.
   - Both scripts refuse to run as root, before any git command, so git and `make` only ever run as the user. Nothing from a kernel build tree runs as root unless it passes `trusted_root_path`, and today that's only `sign-file`.
   - Root never opens a path in the user's checkout. Built modules are streamed in through the user's shell (`< file` into `as_root sh -c 'cat > ...'`), never `as_root cp`, and each staged copy must report the target kernel's vermagic before it's signed. A plain `as_root cp` there leaks the signing key, which the third review reproduced.
   - Swaps rename each staged module over its old copy first, and only then delete old copies elsewhere.
   - New code reaches the kernel only through `update.sh`'s review, a first clone, or commits you made locally. `install.sh` refuses `-b` on an existing clone and sends new upstream commits to `update.sh`.
   - `update.sh` sends everything it shows through `clean()`, never raw `git log` or `git diff` output to the terminal. Diffs use `--text --no-renames --no-ext-diff --no-textconv`, file lists use `--no-renames`, and symlinks, `.gitattributes` or `.gitmodules` anywhere in the tree make every change count as code.
   - `scripts/*.sh` are mode 100755 in git: `git ls-files -s scripts`. Commit from the command line, since the web uploader drops it.
   - Both scripts need bash 4.4 or newer and check for it.
2. Test `install.sh` on a distro or two that isn't yours. A container works for the build step, since it only needs headers. The script refuses to run as root, so the container makes a user and builds from a copy that user owns:

   ```
   podman run --rm -v "$PWD":/src:ro,Z docker.io/library/fedora:latest bash -c \
     'dnf install -y kernel-devel gcc make git kmod findutils && k=$(ls /usr/src/kernels | head -n 1) && mkdir -p /lib/modules/$k && ln -s /usr/src/kernels/$k /lib/modules/$k/build && useradd -m b && cp -r /src /home/b/src && chown -R b:b /home/b/src && su b -c "/home/b/src/scripts/install.sh -k $k -n"'
   ```

   The symlink is there since `kernel-devel` alone doesn't create `/lib/modules/<version>/build`, the kernel package does. On Ubuntu, `apt-get install -y linux-headers-generic` creates it for you, so use `ls /lib/modules` to get the version. Same idea for whichever distro you want to check. Docker works the same.

3. Check the header package names in `install_build_deps()` still exist on each distro
4. Check the Secure Boot key paths (`/var/lib/shim-signed/mok/`, `/var/lib/dkms/`) haven't moved

## 6. Upstream and forks

Look at the original GV-USB2-Driver this was forked from (Isaac Lozano's) and any active forks for fixes worth pulling in. Check the issue tracker for bug reports while you're at it.

Forks already reviewed, so you only need to look at commits newer than these:

- jkl1337/GV-USB2-Driver, up to 7423642 (2026-05-08). Its vb2 wait-op removal was already covered here with a version guard. Its per-device ALSA `index`/`id`/`enable` arrays were ported in a reworked form, since the original never advanced its device counter.
- Open pull requests on Isaac-Lozano/GV-USB2-Driver, reviewed 2026-10-28:
  - #9 (96dcd80), ALSA index arrays: already covered by the jkl1337 port. Not taken: its card counter is read uninitialized and never advances, and it swaps `snd_card_free_when_closed` for `snd_card_free`, which frees the card under an app that still has it open.
  - #13 (2e06d86, 71a4507), vb2 wait ops and an install script: the wait ops are covered, with a version guard so kernels before 6.13 keep them (without them vb2 holds the queue lock while it blocks). Its script force-unloads modules with `rmmod -f` and writes into `kernel/drivers/` as root; `scripts/install.sh` replaces it.
  - #15 (c5bbc50 to 129171d), unplug and suspend fixes plus DKMS: every driver fix is already here in some form. The usb_device reference, card-owned sound teardown with `snd_card_disconnect` first, killing URBs before freeing them, the start_streaming unlock on error, the ratelimited overflow warning, and the default card index. One difference: it tears down the v4l2 device and the i2c adapter in disconnect, this driver does it in release, unregistering the v4l2 device before the adapter, which is the ordering bug #15 fixes. DKMS not taken: `scripts/update.sh` already rebuilds for every installed kernel, and DKMS would be a second install path to keep in step with it.
  - #16 (0d0bf08, cf677c9), PAL support and 7.0 build fixes: the build fixes are covered. Taken: hactive 724 instead of 722, so Horizontal Start 8 stays inside the decoder's line. Not taken: its `standard` module parameter (the parser falls through and always picks NTSC), resetting both start controls on every S_STD (overwrites what the user set), and its PAL vdelay of 22. This driver uses 25 (the kernel tw9910 driver's 24, plus the 1 the NTSC value adds to its 18). Neither has been checked on PAL hardware; if a PAL capture shows the wrong lines at the top, try 22 from #16 first.

## 6.5. Independent review

Whoever writes a change shouldn't be the only one checking it. So once a year, or after any big change, have someone or something that didn't write the code do a security pass. Hand them only the repo URL, not my notes, so they can't inherit my assumptions. The October 2026 pass is summarized in the log below.

## 7. Close out

1. Update "Last review" and "Next review due" at the top
2. Update the tested kernels line in the README
3. Add a line to the log below
4. Commit

## Review log

| Date | Kernels built | Hardware tested | Notes |
|---|---|---|---|
| 2026-10-23 | 6.8, 6.14, 6.17, 7.0 (Ubuntu), mainline 7.4 merge window | No | Fixed build on 7.0+ (vb2 wait ops, strncpy), i2c busy-wait hang on unplug, ALSA crashes around open, close and unplug, ALSA index default, PAL frame size, unchecked errors throughout. Split shared code into gvusb2-core. Added install and update scripts. |
| 2026-10-23 | same | No | Reviewed jkl1337's fork. Ported per-device ALSA `index`/`id`/`enable` module parameters, with slot tracking. |
| 2026-10-24 | same | No | Independent security review: nothing malicious, nothing hidden. Fixed what it found. Scripts: `-k` path traversal plus a newline injection in a root `rm` (reproduced, then fixed), `sign-file` run as root from a user-writable tree, a missing `--` on git checkout. Added a review-and-confirm step to `update.sh`, and `install.sh` now sends new commits through it. Driver: S_STD racing REQBUFS (now caught in buf_prepare), unlocked GPIO read-modify-write shared by both drivers, i2c wait now bounded by time instead of attempts, CREATE_BUFS no longer bumped to 4 buffers. |
| 2026-10-24 | same | No | Second independent review, of those fixes: all nine confirmed fixed. Fixed the follow-ups it found: signing refusal killed installs with Secure Boot off and could leave old modules deleted (now warns and installs unsigned, and installs are staged), review screen spoofable with escape sequences and Unicode (output cleaned), a symlink could make code look like docs, running as root let a user-owned tree run build tools as root (now refused), a narrow race could trip a vb2 WARN (payload clamped), `-b` could build an unreviewed branch, diverged history blocked kernel rebuilds, one bad kernel aborted multi-kernel runs midway, docs overstated what the scripts guarantee. |
| 2026-10-24 | same | No | Third independent review, of the follow-ups. Fixed: the signing key could be copied world-readable into /lib/modules by a symlink swap in the checkout (root used `cp` on a user path; reproduced), git ran as root before the root check, a NUL byte or `.gitattributes` could hide a file from the review as "binary", a rename to `.md` was labeled docs, CR/VT/FF didn't trigger the warning. The root-mode tree check had several bypasses (symlink parents, sticky directories, `make O=` builds), so root runs are now refused instead. Documented that any tool signing modules built in your account can be fed a swapped module by code running as you. |
| 2026-10-24 | same | No | Fourth independent review, of the whole patch: no path to root from upstream or a USB device, key-leak fix holds, review screen held. Fixed: `install.sh` built whatever directory sat above it with no ownership check, so files another user left in `/tmp` got built and installed (reproduced); ACLs got past the root-only checks; one kernel failing to build stopped later kernels; staged files left behind by an interrupted install got indexed by depmod; declining an update skipped the rebuild of what was already installed; header trees weren't checked before make ran them. Docs corrected. |
| 2026-10-24 | same | No | Hotfix: the ACL check refused any ACL at all, so a home directory with a read-only ACL entry (common on desktops) blocked every install. Now only entries granting write access to someone else are refused, and the error names the exact path and entry. |
| 2026-10-28 | not rebuilt here | Yes, NTSC S-Video | Fixed field order: frames were reported as `V4L2_FIELD_INTERLACED`, which means bottom field first for NTSC, but the device sends top field first (idet on a real capture agreed, and bob deinterlacing juddered until the tag was flipped). Now `V4L2_FIELD_INTERLACED_TB`, from one define in `gvusb2-vid.h`. Added the idet check to the hardware test. Reviewed upstream PRs #9, #13, #15 and #16 (see section 6): took hactive 724 from #16, everything else was covered or not wanted. Added the Horizontal Start 8 check to the hardware test. First hardware run of the whole test on NTSC S-Video: compliance 84/84, two sessions in a row, unplug mid-capture, module reload (with PipeWire stopped, since it holds the card) and Horizontal Start 8 all passed; idet TFF 300/300. It found one bug: arecord's default buffer (24000 frames) was smaller than two of the forced 256 ms periods (12288) and overran at the start. Fixed with a 32 ms minimum period, at least two periods, and whole periods per buffer. Added signal status to ENUMINPUT and a real QUERYSTD from the TW9910 status registers, while streaming. |
