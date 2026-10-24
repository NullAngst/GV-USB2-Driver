#!/usr/bin/env bash
#
# install.sh: fetch, build and install the GV-USB2 kernel modules
# (gvusb2-core, gvusb2-video, gvusb2-sound) against your kernel headers.
#
# Run it as a normal user. The steps that need root go through sudo or doas.
# Run with -h for the options.

set -euo pipefail
export LC_ALL=C

if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
	{ [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
	printf 'ERROR: this script needs bash 4.4 or newer, this is %s\n' "$BASH_VERSION" >&2
	exit 1
fi

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

# Refuse to run as root. Running as yourself, git and make (which run the
# driver's Makefile and the kernel tree's build tools) only ever have your
# own rights, and sudo or doas wraps just the handful of install commands
# that need root. Run as root, every one of those would be root too, and
# a checkout or header tree anyone else can write to becomes root code
# execution. This check comes before any git command for the same reason.
if [ "$(id -u)" -eq 0 ]; then
	die "don't run this as root or with sudo. Run it as your normal user: it calls sudo or doas itself for the steps that need root."
fi

usage() {
	cat <<EOF
Usage: ${0##*/} [options]

Fetch, build and install the GV-USB2 driver modules for your kernel.

Run from inside a checkout, it builds that checkout as-is.
Run on its own, it clones the repo into
  $SRC_DIR_DEFAULT
and on later runs builds that clone. If the clone has new commits upstream
it stops and points you at scripts/update.sh, which shows them first.

Options:
  -s DIR    source checkout to use or create
  -r URL    git URL to clone (default: $REPO_URL_DEFAULT)
  -b NAME   branch to clone (first clone only)
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

# A kernel version ends up in paths that root deletes from and writes to,
# so allow only what real version strings use. That rules out "..", "/"
# and anything starting with a dot or a dash.
valid_kver() {
	[[ $1 =~ ^[A-Za-z0-9_+][A-Za-z0-9._+-]*$ ]]
}

for k in "${kernels[@]}"; do
	if ! valid_kver "$k"; then
		die "'$k' doesn't look like a kernel version (expected something like $(uname -r))"
	fi
done

# A branch name starting with a dash would be read as a git option.
if [ -n "$branch" ]; then
	case $branch in
	-*) die "branch name can't start with a dash: $branch" ;;
	esac
fi

if command -v sudo >/dev/null 2>&1; then
	root_cmd=(sudo)
elif command -v doas >/dev/null 2>&1; then
	root_cmd=(doas)
else
	root_cmd=()
fi

as_root() {
	"${root_cmd[@]}" "$@"
}

# Modules live in /lib/modules on most systems, /usr/lib/modules on a few.
moddir=/lib/modules
if [ ! -d "$moddir" ]; then
	moddir=/usr/lib/modules
fi

# --- where the source lives ---------------------------------------------------

# Use the checkout this script sits in only when it really sits in one:
# run from a file named install.sh inside a scripts/ directory next to the
# driver sources. Piped into bash, or copied somewhere like /tmp, it falls
# back to its own clone instead of building whatever happens to be in the
# parent directory. (${BASH_SOURCE[0]} is empty when piped.)
in_repo=0
script_path=${BASH_SOURCE[0]:-}
if [ -n "$script_path" ] && [ -f "$script_path" ]; then
	script_dir=$(CDPATH='' cd -- "$(dirname -- "$script_path")" && pwd -P)
	repo_root=${script_dir%/*}
	if [ -z "$src_dir" ] && [ "${script_dir##*/}" = scripts ] &&
		[ "${script_path##*/}" = install.sh ] &&
		[ -f "$repo_root/gvusb2-vid.c" ] && [ -f "$repo_root/Makefile" ]; then
		src_dir=$repo_root
		in_repo=1
	fi
fi
if [ -z "$src_dir" ]; then
	src_dir=$SRC_DIR_DEFAULT
fi

# --- command check --------------------------------------------------------------

need=(uname id find sed grep head tail cut mkdir rmdir chmod rm mv cat mktemp dirname od tr sh)
if [ "$uninstall" -eq 1 ]; then
	need+=(depmod modprobe)
else
	need+=(make)
	if [ "$in_repo" -eq 0 ]; then
		need+=(git)
	fi
	if [ "$do_install" -eq 1 ]; then
		need+=(depmod modinfo)
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
if [ "${#root_cmd[@]}" -eq 0 ] &&
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

# find tests matching anything a non-root user could change: not owned
# by root, world-writable, or group-writable by a group other than root.
# Directories with the sticky bit (like /tmp) are exempt from the
# writable tests, since other users can't rename or delete entries in
# them that they don't own.
NOT_ROOT_ONLY=(\( ! -user 0
	-o \( -perm -0002 ! \( -type d -perm -1000 \) \)
	-o \( -perm -0020 ! -group 0 ! \( -type d -perm -1000 \) \) \))

# The same, without the sticky exemption, for checking inside a tree:
# sticky stops other users renaming or deleting entries they don't own,
# but not creating new ones, and a new file in a module directory is a
# module.
NOT_ROOT_ONLY_STRICT=(\( ! -user 0 -o -perm -0002
	-o \( -perm -0020 ! -group 0 \) \))

# has_acl [-R] PATH...: succeed if any PATH (with -R, anything under it)
# carries an extended ACL. Mode bits can't show those, and one can give a
# named user write access. getfacl ships in the same package as setfacl,
# so where it's missing, no ACL was likely ever set.
has_acl() {
	local opts=(-s -p)

	if [ "$1" = -R ]; then
		opts+=(-R -P)
		shift
	fi
	command -v getfacl >/dev/null 2>&1 || return 1
	[ -n "$(getfacl "${opts[@]}" -- "$@" 2>/dev/null)" ]
}

# root_only PATH: succeed if PATH exists and only root can change it.
root_only() {
	[ -e "$1" ] &&
		[ -z "$(find "$1" -prune "${NOT_ROOT_ONLY[@]}" -print 2>/dev/null)" ]
}

# trusted_root_path PATH: succeed only if PATH and every directory above
# it are root-only. Anything less and a non-root user could swap the file
# between this check and its use as root.
trusted_root_path() {
	local dir
	local chain=("$1")

	if [ -L "$1" ] || ! root_only "$1"; then
		return 1
	fi

	# walk the real (symlink-resolved) directory chain up to /
	dir=$(CDPATH='' cd -P -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
	while :; do
		if ! root_only "$dir"; then
			return 1
		fi
		chain+=("$dir")
		if [ "$dir" = / ]; then
			break
		fi
		dir=$(dirname -- "$dir")
	done
	! has_acl "${chain[@]}"
}

# mine_only DIR: succeed if DIR, every directory above it, and everything
# inside it can only be changed by you or root. Group write is allowed for
# your own primary group, since most distros give each user a private one.
# Directories above DIR may be sticky and world-writable, like /tmp. On
# failure, prints the first offending path.
mine_only() {
	local dir uid gid bad
	local chain=()

	uid=$(id -u)
	gid=$(id -g)
	dir=$(CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P) || {
		printf '%s' "$1"
		return 1
	}
	bad=$(find "$dir" ! -type l \( \( ! -user 0 ! -user "$uid" \) -o -perm -0002 \
		-o \( -perm -0020 ! -group 0 ! -group "$gid" \) \) -print 2>/dev/null | head -n 1)
	if [ -n "$bad" ]; then
		printf '%s' "$bad"
		return 1
	fi
	if has_acl -R "$dir"; then
		printf '%s (has an ACL)' "$dir"
		return 1
	fi
	while [ "$dir" != / ]; do
		dir=$(dirname -- "$dir")
		bad=$(find "$dir" -prune \( \( ! -user 0 ! -user "$uid" \) \
			-o \( -perm -0002 ! -perm -1000 \) \
			-o \( -perm -0020 ! -group 0 ! -group "$gid" ! -perm -1000 \) \) -print 2>/dev/null)
		if [ -n "$bad" ]; then
			printf '%s' "$bad"
			return 1
		fi
		chain+=("$dir")
	done
	if has_acl "${chain[@]}"; then
		printf 'a directory above %s (has an ACL)' "$1"
		return 1
	fi
	return 0
}

# moddir_ok KERNEL: the kernel's module directory is safe to delete from
# and write to as root.
moddir_ok() {
	local dir=$moddir/$1

	if [ ! -d "$dir" ]; then
		return 0
	fi
	trusted_root_path "$dir" &&
		[ -z "$(find "$dir" -type d "${NOT_ROOT_ONLY_STRICT[@]}" -print 2>/dev/null)" ] &&
		! has_acl -R "$dir"
}

# remove_old_modules KERNEL [KEEP_DIR]: delete every gvusb2 module file
# for KERNEL, wherever it sits under that kernel's module directory, except
# our three files in KEEP_DIR. Sets removed_any=1 if anything was deleted.
#
# find runs as root, so it also sees directories you can't read, and
# hands the paths to rm directly with -exec, so odd characters in file
# names (newlines included) can't turn into extra paths. find doesn't
# follow symlinks by default, so the build/ and source/ links into the
# header tree are not searched. Callers check moddir_ok first, for every
# kernel, before changing anything.
removed_any=0
remove_old_modules() {
	local dir=$moddir/$1 m out
	local keep=()

	removed_any=0
	if [ ! -d "$dir" ]; then
		return 0
	fi
	if [ "$#" -ge 2 ]; then
		# k is validated and moddir is fixed, so no glob characters here
		for m in "${MODULES[@]}"; do
			keep+=(! -path "$2/$m.ko")
		done
	fi
	# .staged-gvusb2-*.ko: leftovers from an install that was cut short
	out=$(as_root find "$dir" -type f \( -name 'gvusb2-*.ko*' -o -name '.staged-gvusb2-*.ko' \) \
		"${keep[@]}" -print -exec rm -f -- {} +)
	if [ -n "$out" ]; then
		removed_any=1
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
			if ! valid_kver "$k"; then
				continue
			fi
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
		if ! moddir_ok "$k"; then
			die "$moddir/$k, or a directory inside it, is not owned by root or is writable by other users. Refusing to delete from it as root. Nothing was removed."
		fi
	done
	for k in "${kernels[@]}"; do
		remove_old_modules "$k"
		if [ "$removed_any" -eq 1 ]; then
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
	# make runs this tree's build tools as you, so only you or root may
	# be able to change it
	if ! bad=$(mine_only "$kdir"); then
		problems+=("$k: $bad can be changed by someone other than you or root, so building with these headers would run their code as you")
	fi
	if [ "$do_install" -eq 1 ] && ! moddir_ok "$k"; then
		problems+=("$k: $moddir/$k, or a directory inside it, is owned or writable by a non-root user, so installing into it as root isn't safe")
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

# An existing checkout gets git commands run on it, and git honors config
# inside the repo, so check who can change it before touching it.
if [ -e "$src_dir" ] && ! bad=$(mine_only "$src_dir"); then
	die "$bad can be changed by someone other than you or root, so using $src_dir would run their code as you. Clone the repo somewhere you own, like your home directory."
fi

if [ "$in_repo" -eq 1 ]; then
	info "using the checkout at $src_dir"
elif [ -d "$src_dir/.git" ]; then
	# New code in an existing clone goes through update.sh, which shows
	# the changes and asks before anything is built and installed as root.
	if [ -n "$branch" ] &&
		[ "$(git -C "$src_dir" rev-parse --abbrev-ref HEAD)" != "$branch" ]; then
		die "-b only applies to a fresh clone. To switch $src_dir to $branch, check it out yourself and read what you're switching to, then run this again."
	fi
	info "checking $src_dir for new commits"
	if git -C "$src_dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
		git -C "$src_dir" fetch --quiet
		if [ -n "$(git -C "$src_dir" rev-list 'HEAD..@{u}')" ]; then
			die "there are new commits for $src_dir. Review and install them with: bash $src_dir/scripts/update.sh"
		fi
	else
		warn "$src_dir doesn't track a remote branch, building it as it is"
	fi
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

# The checkout's Makefile runs as you during the build, so only you (or
# root) may be able to change it. This catches a checkout somewhere
# shared, like files another user left in /tmp.
if ! bad=$(mine_only "$src_dir"); then
	die "$bad can be changed by someone other than you or root, so building $src_dir would run their code as you and install the result. Clone the repo somewhere you own, like your home directory."
fi

log=$(mktemp "${TMPDIR:-/tmp}/gvusb2-build.XXXXXX")

# On any exit, Ctrl-C included, drop the log and any staged modules a cut
# short install left behind.
staging_dest=''
# called from the trap below, which shellcheck can't see
# shellcheck disable=SC2317
cleanup() {
	local m

	rm -f -- "$log"
	if [ -n "$staging_dest" ]; then
		for m in "${MODULES[@]}"; do
			as_root rm -f -- "$staging_dest/.staged-$m.ko" 2>/dev/null || true
		done
	fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

# --- signing preflight: decide per kernel before touching anything ----------------------

declare -A signer_for
for k in "${kernels[@]}"; do
	signer_for[$k]=''
	if [ "$do_install" -eq 0 ] || [ "$have_key" -eq 0 ]; then
		continue
	fi
	if [ "$(cfg_val "$(kernel_config "$k")" MODULE_SIG)" != y ]; then
		continue
	fi
	signer=$moddir/$k/build/scripts/sign-file
	if [ -x "$signer" ]; then
		signer_dir=$(CDPATH='' cd -P -- "$(dirname -- "$signer")" && pwd -P)
		# sign-file runs as root with your private key, so it has to come
		# from a tree only root can change. Distro header packages are.
		# A kernel tree you own (a self-built kernel, say) is not.
		if trusted_root_path "$signer_dir/sign-file"; then
			signer_for[$k]=$signer_dir/sign-file
			continue
		fi
		why="$signer, or a directory above it, can be changed by a non-root user, so running it as root with your key isn't safe"
	else
		why="$signer is missing"
	fi
	if [ "$enforced" -eq 1 ]; then
		die "can't sign for $k: $why. This kernel only loads signed modules, so nothing was changed. Two ways out: move the kernel tree somewhere root-owned like /usr/src, chown -R root:root it, and point $moddir/$k/build at the new place. Or build with -n, sign the three .ko files in $src_dir yourself with a sign-file you trust, copy them into $moddir/$k/$INSTALL_SUBDIR/, and run sudo depmod -a $k."
	fi
	warn "$k: not signing, $why. Secure Boot is off, so the modules load unsigned and the kernel marks itself tainted."
done

# --- build and install, one kernel at a time ------------------------------------------

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
running=$(uname -r)
installed_running=0
done_kernels=()
failed_kernels=()

for k in "${kernels[@]}"; do
	kdir=$moddir/$k/build
	cfg=$(kernel_config "$k")

	info "building for $k (${make_cc[$k]})"
	# A kernel that won't build (old headers, a compiler that's gone)
	# shouldn't stop the others, a new kernel's above all, so note it and
	# carry on. Nothing for this kernel has been touched yet.
	if ! make -C "$kdir" M="$src_dir" "${make_cc[$k]}" clean >"$log" 2>&1 ||
		! make -C "$kdir" M="$src_dir" "${make_cc[$k]}" -j"$jobs" modules >>"$log" 2>&1; then
		# compiler output quotes the source, so drop control characters
		tail -n 40 -- "$log" | tr -d '\000-\010\013-\037\177' >&2
		warn "build failed for $k (last 40 lines above). Skipping it, its installed modules are unchanged."
		failed_kernels+=("$k")
		continue
	fi
	missing_ko=0
	for m in "${MODULES[@]}"; do
		if [ ! -f "$src_dir/$m.ko" ]; then
			missing_ko=1
		fi
	done
	if [ "$missing_ko" -eq 1 ]; then
		warn "build for $k finished but a .ko is missing. Skipping it, its installed modules are unchanged."
		failed_kernels+=("$k")
		continue
	fi

	if [ "$do_install" -eq 0 ]; then
		info "built for $k, modules are in $src_dir (not installed)"
		continue
	fi

	dest=$moddir/$k/$INSTALL_SUBDIR
	info "installing to $dest"

	# Copy and sign into a staging name first, so a failure here leaves
	# the old modules in place. The .staged-*.ko names don't match the
	# gvusb2-*.ko* pattern, so remove_old_modules leaves them alone, and
	# they end in .ko so modinfo reads them as files.
	#
	# The file is opened by this shell, running as you, and streamed to a
	# root process that only writes. Root never opens a path in your
	# checkout, so swapping a built module for a symlink to something only
	# root can read (the signing key, say) gets "permission denied" here
	# instead of a copy of it in /lib/modules.
	as_root mkdir -p -- "$dest"
	staging_dest=$dest
	for m in "${MODULES[@]}"; do
		as_root rm -f -- "$dest/.staged-$m.ko"
	done
	for m in "${MODULES[@]}"; do
		if [ -L "$src_dir/$m.ko" ] || [ ! -f "$src_dir/$m.ko" ]; then
			die "$src_dir/$m.ko isn't a regular file, refusing to install it"
		fi
		# $1 is expanded by the root sh, on purpose
		# shellcheck disable=SC2016
		as_root sh -c 'umask 022 && cat > "$1"' sh "$dest/.staged-$m.ko" <"$src_dir/$m.ko"
		as_root chmod 0644 -- "$dest/.staged-$m.ko"
		# root-owned now, so this checks exactly what gets signed
		vermagic=$(modinfo -F vermagic "$dest/.staged-$m.ko" 2>/dev/null || true)
		case $vermagic in
		"$k "*) ;;
		*)
			for s in "${MODULES[@]}"; do
				as_root rm -f -- "$dest/.staged-$s.ko"
			done
			die "$m.ko isn't a kernel module built for $k, refusing to install it. The modules that were installed before are still in place."
			;;
		esac
	done

	if [ -n "${signer_for[$k]}" ]; then
		hash=$(cfg_val "$cfg" MODULE_SIG_HASH)
		hash=${hash:-sha256}
		for m in "${MODULES[@]}"; do
			if ! as_root "${signer_for[$k]}" "$hash" "$sign_key" "$sign_cert" "$dest/.staged-$m.ko"; then
				for s in "${MODULES[@]}"; do
					as_root rm -f -- "$dest/.staged-$s.ko"
				done
				die "signing failed for $k. The modules that were installed before are still in place."
			fi
		done
		info "signed with $sign_cert"
	elif [ "$(cfg_val "$cfg" MODULE_SIG)" = y ] && [ "$have_key" -eq 0 ]; then
		warn "modules for $k are unsigned. They load, but the kernel marks itself tainted."
	fi

	# Now swap. Each move is a rename over the old file in the same
	# directory, so every module is always either the old or the new one,
	# never missing. Only then clear out older copies anywhere else
	# (an earlier manual install, compressed copies from another tool).
	for m in "${MODULES[@]}"; do
		as_root mv -f -- "$dest/.staged-$m.ko" "$dest/$m.ko"
	done
	staging_dest=''
	remove_old_modules "$k" "$dest"

	as_root depmod -a "$k"

	done_kernels+=("$k")
	if [ "$k" = "$running" ]; then
		installed_running=1
	fi
done

status=0
if [ "${#failed_kernels[@]}" -gt 0 ]; then
	status=1
	if [ "${#done_kernels[@]}" -gt 0 ]; then
		warn "updated: ${done_kernels[*]}"
	fi
	warn "failed, left as they were: ${failed_kernels[*]}. If those are kernels you no longer use, remove their headers, or pick kernels with -k."
fi

if [ "$do_install" -eq 0 ]; then
	exit "$status"
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
elif [ "${#done_kernels[@]}" -gt 0 ]; then
	info "Now the GV-USB2 driver is installed for: ${done_kernels[*]}. It loads once you boot one of those kernels."
fi

exit "$status"
