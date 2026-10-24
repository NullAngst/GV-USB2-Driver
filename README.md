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

   If that says "Permission denied", run `chmod +x scripts/*.sh` first, since GitHub's web uploader drops the executable bit.

   If you don't have headers or a compiler yet, run `scripts/install.sh -d` instead, since that installs them with your package manager first.

3.5. If you'd rather not clone by hand, grab only `scripts/install.sh` and run it. It clones the repo into `~/.local/src/GV-USB2-Driver` and builds from there. Run it again later and it rebuilds that clone, but if there are new commits upstream it stops and sends you to `update.sh` so you see them first. `-b BRANCH` only applies to that first clone. To switch an existing clone to another branch, check it out yourself, so you see what you're switching to.

Run the scripts as your normal user, never with sudo. They call sudo or doas themselves for the few install steps that need root, so git and the compile only ever run with your own rights. Run as root, both refuse to start, since git and make running as root on files other users can write to is a straight path to root.

The build runs the checkout's Makefile and the kernel headers' build tools as you, so `install.sh` also refuses a checkout or header tree that anyone other than you or root can change, ACLs included. Group write is fine for your own primary group, since most distros give every user a private one. That rules out building from a shared spot like `/tmp`, where another user could have left files. Keep the checkout somewhere you own, like your home directory. A copy of `install.sh` that isn't sitting in a checkout's `scripts/` folder uses its own clone in `~/.local/src`, never whatever is in the directory around it.

If one kernel fails to build (headers for an old kernel that no longer compile, say), the others still get installed. The failed one is left as it was, and the script lists it and exits non-zero.

4. Plug in the GV-USB2 and check it showed up: `v4l2-ctl --list-devices` and `arecord -l`

The modules go into `/lib/modules/<kernel>/updates/gvusb2/` and udev loads them whenever the device is plugged in.

## Updating

Run `scripts/update.sh` from the checkout. It rebuilds for every installed kernel that has headers, since a kernel update breaks out-of-tree modules even when the driver code hasn't changed.

Run it after every kernel update. If you only installed a new kernel and haven't rebooted yet, run it anyway: it builds for the new kernel too, as long as that kernel's headers are installed.

When there's new code on GitHub, it shows you before anything happens: the new commits, which files changed, and which of those end up in your kernel or run as root. Then it asks. Type `d` to read the full diff, `y` to install, `n` to leave everything as it is. Why ask? Because this code goes into your kernel and installs as root, so anyone who gets push access to the repo gets code into your kernel on your next update. Reading the diff first is the defense, so actually read it.

What the review can and can't tell you:

- Author names are whatever the person pushing typed in. They prove nothing.
- Everything shown is cleaned up first. Control characters are removed, since escape sequences can hide or rewrite text on your terminal. Non-ASCII bytes show as `?`, since right-to-left overrides and look-alike letters can make code read differently than it runs. This repo is plain ASCII, so it warns when either turns up. A `?` in the diff is worth a hard look.
- The diff is always shown as text. Git would otherwise print "Binary files differ" for a source file with a NUL byte in it and hide its contents, and it still compiles. Files git thinks are binary get their own warning.
- Renames show as a delete plus an add, so moving a `.c` file to a `.md` name still lists the `.c` file as code.
- If the repo ever contains a symlink, a `.gitattributes` or a `.gitmodules`, every changed file counts as code, since those can make a "doc" end up in the build or change how git shows files.
- It can't judge whether the code is good. That part is you.

A few more rules it follows:

- It installs exactly the commits you saw, even if something new gets pushed while you're reading.
- If your checkout and GitHub have diverged (you made local commits, or someone force-pushed), it installs nothing new and rebuilds what you already have, so kernel updates keep working. Look at what happened before you trust the remote again.
- It refuses to run with uncommitted changes to tracked files, so it never builds edits you haven't committed. A local `chmod +x` doesn't count. Local commits you haven't pushed do get built, since they're yours.
- If you answer `n`, or run it without a terminal (from your own crontab, say) and without `-y`, the new commits are left out, but it still rebuilds what you already have, so a new kernel still gets modules. `-y` installs new commits without the review, so only use it if you've accepted that trade. Unattended installs also need sudo or doas to work without a password, which is a trade of its own.

## Secure Boot

With Secure Boot on, the kernel only loads signed modules. The script looks for a key some other tool already made: Ubuntu's `/var/lib/shim-signed/mok/MOK.priv`, then DKMS's `/var/lib/dkms/mok.key`. If one exists, it signs with that. If you've installed a DKMS driver with Secure Boot on before, that key is most likely enrolled already. If modprobe then says "Key was rejected by service", it isn't: enroll the matching certificate with `sudo mokutil --import` and reboot.

If neither exists, the script stops and prints the commands to make and enroll a key. After enrolling, pass it in with `scripts/install.sh -K MOK.priv -C MOK.der`.

KEEP THE PRIVATE KEY PRIVATE. Anything signed with it gets loaded by your kernel.

The signing tool, `sign-file`, comes from your kernel headers and runs as root with that key. So the script only runs it when it and every directory above it are owned by root and writable by nobody else, ACLs included (checked with `getfacl` when it's installed). Distro header packages pass. If your kernel tree is owned by your user (a self-built kernel, say), anything running as you could replace `sign-file` and walk off with the key, so the script won't use it:

- With Secure Boot off, it installs the modules unsigned and says so. They load fine, and the kernel marks itself tainted.
- With Secure Boot on, unsigned modules won't load, so it stops before changing anything. Two ways out. Move the tree somewhere root-owned like `/usr/src`, `chown -R root:root` it, and point `/lib/modules/<kernel version>/build` at the new place (chown alone isn't enough if the tree stays under your home directory, since your home is yours). Or build with `scripts/install.sh -n`, sign the three `.ko` files in the checkout with a `sign-file` you trust, copy them into `/lib/modules/<kernel version>/updates/gvusb2/`, and run `sudo depmod -a <kernel version>`.

On a Debian system installed before 2010 and upgraded ever since, `/usr/src` may still be group-writable by the `src` group. Anyone in that group could swap `sign-file`, so the script refuses there too. `sudo chmod g-w /usr/src` fixes it.

Installs are staged: the new modules are copied and signed next to the old ones first, then each one is renamed over its old copy, so every module is always either the old or the new one. Old copies elsewhere (an earlier manual install, a compressed copy from another tool) are cleared only after that. A failed signing leaves your working install alone.

Root never opens the built modules in your checkout. They're read by your own shell and handed to root, and each copy is checked to be a module built for that kernel before it's signed. So a program running as you can't trick the install into copying the signing key somewhere readable. (Root does open the `-K` and `-C` files you name, since it has to read the key to sign. sign-file uses them and doesn't copy them anywhere.)

What it can't stop: a program running as you while you install could swap in a module of its own between the build and the copy, and it would get signed like yours. That's true of any tool that signs modules built in your account, DKMS included. The key protects your machine from code that isn't running as you. If something hostile already runs as you, signing isn't what stands in its way.

## Options

`scripts/install.sh -h` has the full list. The useful ones:

- `-a` builds for every installed kernel with headers
- `-k VER` builds for one specific kernel, repeat it for more
- `-n` builds without installing, handy for checking a new kernel compiles
- `-l` installs without reloading the modules
- `-u` uninstalls from every kernel

`scripts/update.sh` takes the same options and passes them through, plus `-y` to skip the review. Give it `-k` or `-a` and it uses yours instead of building for all kernels. `-s`, `-r` and `-b` don't apply to it, since it always updates its own checkout.

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

## More than one GV-USB2

Each device gets its own `/dev/videoN` and its own ALSA card. By default the cards are named `gvusb2`, `gvusb2_1` and so on, and get the first free card numbers, in the order they're plugged in.

To pin them, set the usual ALSA module options, one comma-separated entry per device in plug order. For example, in `/etc/modprobe.d/gvusb2.conf`:

```
options gvusb2-sound index=5,6 id=capA,capB
```

Then the first one is `hw:CARD=capA`, the second `hw:CARD=capB`. `enable=1,0` would skip the second device's audio entirely. Plug order is the only thing that decides which device is which, so if that matters, plug them in one at a time.

## Troubleshooting

- `modprobe: ERROR: could not insert 'gvusb2_core': Key was rejected by service`: the module is signed with a key that isn't enrolled. See Secure Boot above.
- The build fails right after a kernel update: run `scripts/update.sh`. If it still fails, the kernel API moved, see `maintenance.md`.
- Debug output is off by default. Turn it on with `echo 'module gvusb2_video +p' | sudo tee /sys/kernel/debug/dynamic_debug/control` and watch `dmesg -w`.

## Status

Build-tested against Ubuntu's 6.8, 6.14, 6.17 and 7.0 kernels and mainline from the 7.4 merge window, all with `W=1` and no warnings. The October 2026 fixes haven't been run on hardware yet, and PAL has never been tested on a real PAL signal. `maintenance.md` has the six-month review checklist.

Now the driver is installed, rebuilds with one command after a kernel update, and the GV-USB2 shows up as a normal V4L2 device and ALSA card. Tinker with the capture window controls as you see fit.

## License

Dual licensed, GPL-2.0-only or BSD-3-Clause. See `LICENSE.gpl` and `LICENSE.bsd`.
