#!/usr/bin/env bash
#
# install.sh: fetch, build and install the GV-USB2 kernel modules
# (gvusb2-core, gvusb2-video, gvusb2-sound) against your kernel headers.
#
# Run it as a normal user. The steps that need root go through sudo or doas.
# Run with -h for the options.

set -euo pipefail
export LC_ALL=C

REPO_URL_DEFAULT='https://github.com/NullAngst/GV-USB2-Driver.git'
SRC_DIR_DEFAULT="${HOME}/.local/src/GV-USB2-Driver"
INSTALL_SUBDIR='updates/gvusb2'
MODULES=(gvusb2-core gvusb2-video gvusb2-sound)

# Kernel options the driver links against. Without them the build or the
# module load fails, so check up front instead of after a long compile.
REQUIRED_CONFIG=(MODULES USB I2C VIDEO_DEV VIDEOBUF2_VMALLOC SND_PCM)

if [ -t 1 ]; then
	C_INFO=$'\033[1;34m'
	C_WARN=$'\033[1;33m'
	C_ERR=$'\033[1;31m'
	C_OFF=$'\033[0m'
else
	C_INFO=''
	C_WARN=''
	C_ERR=''
	C_OFF=''
fi

info() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die() {
	printf '%sERROR:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

Fetch, build and install the GV-USB2 driver modules for your kernel.

Run from inside a checkout, it builds that checkout as-is.
Run on its own, it clones the repo (or pulls it if already cloned) into
  $SRC_DIR_DEFAULT

Options:
  -s DIR    source checkout to use or create
  -r URL    git URL to clone (default: $REPO_URL_DEFAULT)
  -b NAME   branch to clone or switch to
  -k VER    build for this kernel version instead of the running one
            (repeat for several kernels)
  -a        build for every installed kernel that has headers
  -n        build only, do not install
  -l        install, but do not reload the modules
  -d        install a compiler and the kernel headers with your package
            manager first
  -K FILE   private key for module signing (Secure Boot)
  -C FILE   certificate (DER) matching -K
  -u        uninstall the modules instead of building
  -h        show this help
EOF
}

# --- options ----------------------------------------------------------------

src_dir=''
repo_url=$REPO_URL_DEFAULT
branch=''
kernels=()
all_kernels=0
do_install=1
do_load=1
install_deps=0
sign_key=''
sign_cert=''
uninstall=0

while getopts ':s:r:b:k:anldK:C:uh' opt; do
	case $opt in
	s) src_dir=$OPTARG ;;
	r) repo_url=$OPTARG ;;
	b) branch=$OPTARG ;;
	k) kernels+=("$OPTARG") ;;
	a) all_kernels=1 ;;
	n) do_install=0 ;;
	l) do_load=0 ;;
	d) install_deps=1 ;;
	K) sign_key=$OPTARG ;;
	C) sign_cert=$OPTARG ;;
	u) uninstall=1 ;;
	h)
		usage
		exit 0
		;;
	:) die "option -$OPTARG needs a value (see -h)" ;;
	*) die "unknown option -$OPTARG (see -h)" ;;
	esac
done
shift $((OPTIND - 1))
if [ "$#" -gt 0 ]; then
	die "unexpected argument: $1 (see -h)"
fi

if [ -n "$sign_key" ] || [ -n "$sign_cert" ]; then
	if [ -z "$sign_key" ] || [ -z "$sign_cert" ]; then
		die "-K and -C go together: the key and its certificate"
	fi
fi

if [ "$(id -u)" -eq 0 ]; then
	root_cmd=()
elif command -v sudo >/dev/null 2>&1; then
	root_cmd=(sudo)
elif command -v doas >/dev/null 2>&1; then
	root_cmd=(doas)
else
	root_cmd=()
fi

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		"${root_cmd[@]}" "$@"
	fi
}

# Modules live in /lib/modules on most systems, /usr/lib/modules on a few.
moddir=/lib/modules
if [ ! -d "$moddir" ]; then
	moddir=/usr/lib/modules
fi

# --- where the source lives ---------------------------------------------------

# ${BASH_SOURCE[0]} is empty when the script is piped into bash.
script_path=${BASH_SOURCE[0]:-$0}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$script_path")" && pwd -P)
repo_root=${script_dir%/*}

in_repo=0
if [ -z "$src_dir" ] && [ -f "$repo_root/gvusb2-vid.c" ] &&
	[ -f "$repo_root/Makefile" ]; then
	src_dir=$repo_root
	in_repo=1
fi
if [ -z "$src_dir" ]; then
	src_dir=$SRC_DIR_DEFAULT
fi

# --- command check --------------------------------------------------------------

need=(uname id find sed grep head tail cut mkdir rmdir cp chmod rm mktemp dirname od)
if [ "$uninstall" -eq 1 ]; then
	need+=(depmod modprobe)
else
	need+=(make)
	if [ "$in_repo" -eq 0 ]; then
		need+=(git)
	fi
	if [ "$do_install" -eq 1 ]; then
		need+=(depmod)
		if [ "$do_load" -eq 1 ]; then
			need+=(modprobe)
		fi
	fi
fi

missing=()
for c in "${need[@]}"; do
	if ! command -v "$c" >/dev/null 2>&1; then
		missing+=("$c")
	fi
done
if [ "$(id -u)" -ne 0 ] && [ "${#root_cmd[@]}" -eq 0 ] &&
	{ [ "$do_install" -eq 1 ] || [ "$uninstall" -eq 1 ] ||
		[ "$install_deps" -eq 1 ]; }; then
	missing+=("sudo or doas")
fi
if [ "${#missing[@]}" -gt 0 ]; then
	die "missing required commands: ${missing[*]}"
fi

# --- helpers --------------------------------------------------------------------

# cfg_val FILE OPTION: print the value of CONFIG_OPTION, quotes stripped.
cfg_val() {
	local v
	v=$(sed -n "s/^CONFIG_$2=//p" "$1" | head -n 1)
	v=${v#\"}
	v=${v%\"}
	printf '%s' "$v"
}

kernel_config() {
	local kdir=$moddir/$1/build
	if [ -f "$kdir/.config" ]; then
		printf '%s' "$kdir/.config"
	elif [ -f "$kdir/include/config/auto.conf" ]; then
		printf '%s' "$kdir/include/config/auto.conf"
	fi
}

detect_pm() {
	local pm
	for pm in apt-get dnf zypper pacman apk xbps-install emerge; do
		if command -v "$pm" >/dev/null 2>&1; then
			printf '%s' "$pm"
			return 0
		fi
	done
	return 1
}

install_build_deps() {
	local pm k flavor base mm
	local pkgs=()

	pm=$(detect_pm) || die "no supported package manager found. Install your kernel headers and a C compiler by hand, then rerun without -d."

	case $pm in
	apt-get)
		pkgs=(gcc make git kmod)
		for k in "${kernels[@]}"; do
			pkgs+=("linux-headers-$k")
		done
		as_root apt-get update
		as_root apt-get install -y "${pkgs[@]}"
		;;
	dnf)
		pkgs=(gcc make git kmod)
		for k in "${kernels[@]}"; do
			pkgs+=("kernel-devel-$k")
		done
		as_root dnf install -y "${pkgs[@]}"
		;;
	zypper)
		# openSUSE names the devel package after the flavor (-default)
		pkgs=(gcc make git kmod)
		for k in "${kernels[@]}"; do
			flavor=${k##*-}
			pkgs+=("kernel-$flavor-devel")
		done
		as_root zypper --non-interactive install "${pkgs[@]}"
		warn "zypper installs the newest kernel-*-devel. If it doesn't match a kernel you are still running, reboot into the new kernel and rerun."
		;;
	pacman)
		# Arch records the kernel package name next to the modules
		pkgs=(gcc make git kmod)
		for k in "${kernels[@]}"; do
			base=linux
			if [ -r "$moddir/$k/pkgbase" ]; then
				base=$(head -n 1 "$moddir/$k/pkgbase")
			fi
			pkgs+=("$base-headers")
		done
		as_root pacman -S --needed --noconfirm "${pkgs[@]}"
		;;
	apk)
		pkgs=(gcc make git musl-dev kmod)
		for k in "${kernels[@]}"; do
			flavor=${k##*-}
			pkgs+=("linux-$flavor-dev")
		done
		as_root apk add "${pkgs[@]}"
		;;
	xbps-install)
		pkgs=(gcc make git kmod)
		for k in "${kernels[@]}"; do
			mm=$(printf '%s' "$k" | cut -d. -f1-2)
			pkgs+=("linux$mm-headers")
		done
		as_root xbps-install -Sy "${pkgs[@]}"
		;;
	emerge)
		die "on Gentoo the headers come from your kernel sources (gentoo-kernel, gentoo-sources or whichever). Make sure /lib/modules/<version>/build points at a configured tree, then rerun without -d."
		;;
	esac
}

secure_boot_on() {
	local efivar val
	if command -v mokutil >/dev/null 2>&1; then
		if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
			return 0
		fi
		return 1
	fi
	# efivarfs: 4 bytes of attributes, then the value byte
	for efivar in /sys/firmware/efi/efivars/SecureBoot-*; do
		if [ -r "$efivar" ]; then
			val=$(od -An -t u1 -j 4 -N 1 "$efivar" | sed 's/[^0-9]//g')
			if [ "$val" = 1 ]; then
				return 0
			fi
		fi
	done
	return 1
}

signatures_enforced() {
	if [ -r /sys/module/module/parameters/sig_enforce ] &&
		grep -q Y /sys/module/module/parameters/sig_enforce; then
		return 0
	fi
	if [ -r /sys/kernel/security/lockdown ] &&
		grep -q '\[integrity\]\|\[confidentiality\]' /sys/kernel/security/lockdown; then
		return 0
	fi
	secure_boot_on
}

# Use -K/-C if given, else a key some other tool already set up and
# probably enrolled: Ubuntu's shim-signed MOK first, then DKMS's own.
find_sign_key() {
	if [ -n "$sign_key" ]; then
		return 0
	fi
	if as_root test -r /var/lib/shim-signed/mok/MOK.priv &&
		[ -r /var/lib/shim-signed/mok/MOK.der ]; then
		sign_key=/var/lib/shim-signed/mok/MOK.priv
		sign_cert=/var/lib/shim-signed/mok/MOK.der
		return 0
	fi
	if as_root test -r /var/lib/dkms/mok.key &&
		[ -r /var/lib/dkms/mok.pub ]; then
		sign_key=/var/lib/dkms/mok.key
		sign_cert=/var/lib/dkms/mok.pub
		return 0
	fi
	return 1
}

# --- preflight: every target kernel checked before anything is built -----------

if [ "${#kernels[@]}" -eq 0 ]; then
	if [ "$all_kernels" -eq 1 ] || [ "$uninstall" -eq 1 ]; then
		for d in "$moddir"/*/; do
			k=${d%/}
			k=${k##*/}
			if [ "$uninstall" -eq 1 ] || [ -f "$moddir/$k/build/Makefile" ]; then
				kernels+=("$k")
			fi
		done
		if [ "${#kernels[@]}" -eq 0 ]; then
			if [ "$uninstall" -eq 1 ]; then
				die "no kernels found under $moddir"
			fi
			kernels=("$(uname -r)")
		fi
	else
		kernels=("$(uname -r)")
	fi
fi

# --- uninstall ------------------------------------------------------------------

if [ "$uninstall" -eq 1 ]; then
	for k in "${kernels[@]}"; do
		removed=0
		while IFS= read -r f; do
			as_root rm -f -- "$f"
			removed=1
		done < <(find "$moddir/$k" -type f -name 'gvusb2-*.ko*' 2>/dev/null)
		if [ "$removed" -eq 1 ]; then
			# drop the directory we created, if it is empty now
			as_root rmdir -- "$moddir/$k/$INSTALL_SUBDIR" 2>/dev/null || true
			as_root depmod -a "$k"
			info "removed the gvusb2 modules for $k"
		fi
	done
	if [ -d /sys/module/gvusb2_video ] || [ -d /sys/module/gvusb2_sound ] ||
		[ -d /sys/module/gvusb2_core ]; then
		if ! as_root modprobe -r gvusb2_video gvusb2_sound gvusb2_core; then
			warn "the modules are still loaded and in use. Close any capture app and unplug the GV-USB2, or reboot."
		fi
	fi
	info "uninstall done. The source checkout in $src_dir was left alone."
	exit 0
fi

if [ "$install_deps" -eq 1 ]; then
	info "installing a compiler and kernel headers"
	install_build_deps
fi

declare -A make_cc
problems=()
missing=()
for k in "${kernels[@]}"; do
	kdir=$moddir/$k/build
	if [ ! -f "$kdir/Makefile" ]; then
		problems+=("$k: no kernel headers at $kdir (install them, or rerun with -d)")
		continue
	fi

	cfg=$(kernel_config "$k")
	if [ -z "$cfg" ]; then
		problems+=("$k: no .config in $kdir, the headers look incomplete")
		continue
	fi

	for opt in "${REQUIRED_CONFIG[@]}"; do
		case $(cfg_val "$cfg" "$opt") in
		y | m) ;;
		*) problems+=("$k: CONFIG_$opt is not enabled in this kernel") ;;
		esac
	done

	case $(cfg_val "$cfg" VIDEO_TW9910) in
	y | m) ;;
	*) warn "$k: CONFIG_VIDEO_TW9910 is off. The driver still loads, but S_STD and stream start/stop never reach the decoder chip, so PAL won't switch over." ;;
	esac

	# Build with the compiler the kernel was built with. A different
	# one can reject flags the kernel's Makefile passes.
	if [ "$(cfg_val "$cfg" CC_IS_CLANG)" = y ]; then
		for c in clang ld.lld; do
			if ! command -v "$c" >/dev/null 2>&1; then
				missing+=("$c")
			fi
		done
		make_cc[$k]='LLVM=1'
	else
		cc_text=$(cfg_val "$cfg" CC_VERSION_TEXT)
		cc_name=${cc_text%% *}
		if [ -n "$cc_name" ] && command -v "$cc_name" >/dev/null 2>&1; then
			make_cc[$k]="CC=$cc_name"
		elif command -v gcc >/dev/null 2>&1; then
			warn "$k was built with '$cc_name', which isn't installed. Falling back to gcc; if the build fails, install that compiler (on Debian or Ubuntu, the gcc-N package matching the number in its name)."
			make_cc[$k]='CC=gcc'
		else
			missing+=("${cc_name:-gcc}")
		fi
	fi
done

if [ "${#missing[@]}" -gt 0 ]; then
	die "missing required commands: ${missing[*]}"
fi
if [ "${#problems[@]}" -gt 0 ]; then
	for p in "${problems[@]}"; do
		printf '  %s\n' "$p" >&2
	done
	die "can't build for the kernel(s) above"
fi

# --- fetch ------------------------------------------------------------------------

if [ "$in_repo" -eq 1 ]; then
	info "using the checkout at $src_dir"
elif [ -d "$src_dir/.git" ]; then
	info "pulling the latest code into $src_dir"
	if [ -n "$branch" ]; then
		git -C "$src_dir" checkout "$branch"
	fi
	git -C "$src_dir" pull --ff-only
elif [ -f "$src_dir/gvusb2-vid.c" ]; then
	info "using the source at $src_dir (not a git checkout, nothing to pull)"
elif [ -e "$src_dir" ]; then
	die "$src_dir exists but isn't a GV-USB2-Driver checkout. Move it or pick another directory with -s."
else
	info "cloning $repo_url into $src_dir"
	mkdir -p -- "$(dirname -- "$src_dir")"
	clone_args=(clone)
	if [ -n "$branch" ]; then
		clone_args+=(--branch "$branch")
	fi
	git "${clone_args[@]}" -- "$repo_url" "$src_dir"
fi

# --- signing decision ---------------------------------------------------------------

log=$(mktemp "${TMPDIR:-/tmp}/gvusb2-build.XXXXXX")
trap 'rm -f -- "$log"' EXIT

enforced=0
if [ "$do_install" -eq 1 ] && signatures_enforced; then
	enforced=1
fi

have_key=0
if [ "$do_install" -eq 1 ] && find_sign_key; then
	have_key=1
	for f in "$sign_key" "$sign_cert"; do
		if ! as_root test -r "$f"; then
			die "can't read $f"
		fi
	done
fi

if [ "$enforced" -eq 1 ] && [ "$have_key" -eq 0 ]; then
	cat >&2 <<EOF
${C_ERR}ERROR:${C_OFF} this kernel only loads signed modules (Secure Boot or lockdown is on),
and no signing key was found.

Make a key once, enroll it, then rerun with -K and -C:

  openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \\
    -subj "/CN=GV-USB2 module signing/" -outform DER \\
    -keyout MOK.priv -out MOK.der
  sudo mokutil --import MOK.der      # pick a one-time password
  # reboot, choose "Enroll MOK" on the blue screen, enter that password
  ${0##*/} -K MOK.priv -C MOK.der

KEEP MOK.priv PRIVATE. Anyone with it can sign modules your machine will trust.
EOF
	exit 1
fi

# --- build and install, one kernel at a time ------------------------------------------

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
running=$(uname -r)
installed_running=0

for k in "${kernels[@]}"; do
	kdir=$moddir/$k/build
	cfg=$(kernel_config "$k")

	info "building for $k (${make_cc[$k]})"
	if ! make -C "$kdir" M="$src_dir" "${make_cc[$k]}" clean >"$log" 2>&1 ||
		! make -C "$kdir" M="$src_dir" "${make_cc[$k]}" -j"$jobs" modules >>"$log" 2>&1; then
		tail -n 40 -- "$log" >&2
		die "build failed for $k. The last 40 lines are above."
	fi
	for m in "${MODULES[@]}"; do
		if [ ! -f "$src_dir/$m.ko" ]; then
			die "build for $k finished but $m.ko is missing"
		fi
	done

	if [ "$do_install" -eq 0 ]; then
		info "built for $k, modules are in $src_dir (not installed)"
		continue
	fi

	dest=$moddir/$k/$INSTALL_SUBDIR
	info "installing to $dest"

	# Clear out every older copy first, wherever an earlier manual
	# install or another script put it, compressed or not.
	while IFS= read -r f; do
		as_root rm -f -- "$f"
	done < <(find "$moddir/$k" -type f -name 'gvusb2-*.ko*' 2>/dev/null)

	as_root mkdir -p -- "$dest"
	for m in "${MODULES[@]}"; do
		as_root cp -- "$src_dir/$m.ko" "$dest/$m.ko"
		as_root chmod 0644 -- "$dest/$m.ko"
	done

	if [ "$(cfg_val "$cfg" MODULE_SIG)" = y ]; then
		if [ "$have_key" -eq 1 ]; then
			signer=$kdir/scripts/sign-file
			if [ ! -x "$signer" ]; then
				die "$signer is missing, the headers for $k can't sign modules"
			fi
			hash=$(cfg_val "$cfg" MODULE_SIG_HASH)
			hash=${hash:-sha256}
			for m in "${MODULES[@]}"; do
				as_root "$signer" "$hash" "$sign_key" "$sign_cert" "$dest/$m.ko"
			done
			info "signed with $sign_cert"
		else
			warn "modules for $k are unsigned. They load, but the kernel marks itself tainted."
		fi
	fi

	as_root depmod -a "$k"

	if [ "$k" = "$running" ]; then
		installed_running=1
	fi
done

if [ "$do_install" -eq 0 ]; then
	exit 0
fi

# --- load ----------------------------------------------------------------------------

if [ "$do_load" -eq 1 ] && [ "$installed_running" -eq 1 ]; then
	if [ -d /sys/module/gvusb2_video ] || [ -d /sys/module/gvusb2_sound ] ||
		[ -d /sys/module/gvusb2_core ]; then
		info "unloading the old modules"
		if ! as_root modprobe -r gvusb2_video gvusb2_sound gvusb2_core; then
			warn "the old modules are in use, so they stay loaded. Close any capture app and replug the GV-USB2, or reboot, to pick up the new build."
			do_load=0
		fi
	fi
fi

if [ "$do_load" -eq 1 ] && [ "$installed_running" -eq 1 ]; then
	info "loading the modules"
	if ! as_root modprobe gvusb2-video || ! as_root modprobe gvusb2-sound; then
		cat >&2 <<EOF
${C_ERR}ERROR:${C_OFF} modprobe failed. Check 'sudo dmesg | tail'.
"Key was rejected by service" means the signing certificate isn't enrolled:
  sudo mokutil --import ${sign_cert:-<your certificate>}
then reboot and pick "Enroll MOK".
EOF
		exit 1
	fi
	info "Now the GV-USB2 driver is installed for $running and loaded. Plug the device in and it shows up as a /dev/video node and an ALSA card named gvusb2."
elif [ "$installed_running" -eq 1 ]; then
	info "Now the GV-USB2 driver is installed for $running. It loads the next time the device is plugged in."
else
	info "Now the GV-USB2 driver is installed for: ${kernels[*]}. It loads once you boot one of those kernels."
fi
