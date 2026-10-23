#!/usr/bin/env bash
#
# update.sh: pull the latest driver code into this checkout, then rebuild
# and reinstall it with install.sh.
#
# The modules are built against kernel headers, so they need a rebuild after
# every kernel update even when the driver code hasn't changed. With no
# options this rebuilds for every installed kernel that has headers, which
# covers a kernel that was just installed but isn't booted yet.
#
# Any options are passed straight to install.sh (see install.sh -h).

set -euo pipefail
export LC_ALL=C

if [ -t 1 ]; then
	C_INFO=$'\033[1;34m'
	C_ERR=$'\033[1;31m'
	C_OFF=$'\033[0m'
else
	C_INFO=''
	C_ERR=''
	C_OFF=''
fi

info() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
die() {
	printf '%sERROR:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2
	exit 1
}

missing=()
for c in git dirname; do
	if ! command -v "$c" >/dev/null 2>&1; then
		missing+=("$c")
	fi
done
if [ "${#missing[@]}" -gt 0 ]; then
	die "missing required commands: ${missing[*]}"
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=${script_dir%/*}

if [ ! -d "$repo/.git" ]; then
	die "$repo isn't a git checkout. Clone the repo, or run install.sh on its own and it clones for you."
fi
if [ ! -x "$repo/scripts/install.sh" ]; then
	die "$repo/scripts/install.sh is missing or not executable"
fi

# Only look at the option letters install.sh knows, to see whether the
# caller already picked kernels or asked for something other than a build.
pick_kernels=1
while getopts ':s:r:b:k:anldK:C:uh' opt; do
	case $opt in
	k | a | u | h) pick_kernels=0 ;;
	*) ;;
	esac
done

# A dirty tree would make pull refuse halfway, or worse, build something
# that isn't on GitHub. Untracked files (build output) don't matter.
if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
	die "$repo has local changes. Commit or stash them first."
fi

old=$(git -C "$repo" rev-parse HEAD)
info "pulling into $repo"
git -C "$repo" pull --ff-only
new=$(git -C "$repo" rev-parse HEAD)

if [ "$old" = "$new" ]; then
	info "already up to date, rebuilding anyway in case the kernel changed"
else
	info "new commits:"
	git -C "$repo" --no-pager log --oneline "$old..$new"
fi

# git pull swapped the files on disk, so this runs the new install.sh
if [ "$pick_kernels" -eq 1 ]; then
	exec "$repo/scripts/install.sh" -a "$@"
fi
exec "$repo/scripts/install.sh" "$@"
