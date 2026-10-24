#!/usr/bin/env bash
#
# update.sh: fetch new driver code, show you what changed, and only after
# you say yes, fast-forward this checkout and rebuild and reinstall it with
# install.sh.
#
# Why the review step? Because install.sh builds this code into your kernel
# and installs it as root. Whoever can push to the GitHub repo can put code
# in your kernel. Seeing the diff first is the cheap defense.
#
# The modules are built against kernel headers, so they need a rebuild after
# every kernel update even when the driver code hasn't changed. With no
# options this rebuilds for every installed kernel that has headers, which
# covers a kernel that was just installed but isn't booted yet.
#
# Options are passed through to install.sh (see install.sh -h), plus:
#   -y   install new commits without asking (for unattended runs)

set -euo pipefail
export LC_ALL=C

if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
	{ [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
	printf 'ERROR: this script needs bash 4.4 or newer, this is %s\n' "$BASH_VERSION" >&2
	exit 1
fi

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
Usage: ${0##*/} [-y] [install.sh options]

Fetch new commits for this checkout, show them, and after you confirm,
fast-forward to them and rebuild and reinstall the driver.

  -y   install new commits without asking
  -h   show this help

Everything else goes to install.sh: -k VER, -a, -n, -l, -d, -K FILE,
-C FILE, -u. With neither -k nor -a, it builds for every installed kernel
that has headers. -s, -r and -b don't apply, since this script always
updates the checkout it lives in.
EOF
}

# Never as root: git would run as root on a checkout you own, and
# install.sh refuses root anyway. This comes before any git command.
if [ "$(id -u)" -eq 0 ]; then
	die "don't run this as root or with sudo. Run it as your normal user: install.sh calls sudo or doas itself for the steps that need root."
fi

missing=()
for c in git dirname grep tr awk cut sh wc id; do
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
if [ ! -f "$repo/scripts/install.sh" ]; then
	die "$repo/scripts/install.sh is missing"
fi

# --- options ----------------------------------------------------------------

assume_yes=0
pick_kernels=1
uninstall=0
pass=()

while getopts ':k:anldK:C:uhys:r:b:' opt; do
	case $opt in
	y) assume_yes=1 ;;
	h)
		usage
		exit 0
		;;
	s | r | b) die "-$opt doesn't apply to ${0##*/}, it updates the checkout at $repo" ;;
	k)
		pick_kernels=0
		pass+=(-k "$OPTARG")
		;;
	K | C) pass+=("-$opt" "$OPTARG") ;;
	a)
		pick_kernels=0
		pass+=(-a)
		;;
	u)
		uninstall=1
		pass+=(-u)
		;;
	n | l | d) pass+=("-$opt") ;;
	:) die "option -$OPTARG needs a value (see -h)" ;;
	*) die "unknown option -$OPTARG (see -h)" ;;
	esac
done
shift $((OPTIND - 1))
if [ "$#" -gt 0 ]; then
	die "unexpected argument: $1 (see -h)"
fi

# Run install.sh with the same bash, so a lost executable bit (GitHub's
# web uploader drops it) doesn't stop the update.
run_install() {
	if [ "$pick_kernels" -eq 1 ] && [ "$uninstall" -eq 0 ]; then
		exec "$BASH" "$repo/scripts/install.sh" -a "${pass[@]}"
	fi
	exec "$BASH" "$repo/scripts/install.sh" "${pass[@]}"
}

# Uninstalling doesn't need new code.
if [ "$uninstall" -eq 1 ]; then
	run_install
fi

# --- fetch ------------------------------------------------------------------

# A dirty tree would make the merge refuse halfway, or worse, build
# something that isn't on GitHub. Untracked files (build output) don't
# matter, and neither do mode changes, so a local chmod +x on the
# scripts doesn't block updates.
if [ -n "$(git -C "$repo" -c core.fileMode=false status --porcelain --untracked-files=no)" ]; then
	die "$repo has local changes. Commit or stash them first."
fi

if ! upstream=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
	die "the current branch in $repo doesn't track a remote branch, so there is nothing to update from"
fi
remote=${upstream%%/*}

info "fetching from $remote"
git -C "$repo" fetch --quiet "$remote"

old=$(git -C "$repo" rev-parse HEAD)
new=$(git -C "$repo" rev-parse '@{u}')

if [ "$old" = "$new" ]; then
	info "no new commits, rebuilding anyway in case the kernel changed"
	run_install
fi

if git -C "$repo" merge-base --is-ancestor "$new" "$old"; then
	info "your checkout is ahead of $upstream, nothing new to fetch. Rebuilding what you have."
	run_install
fi

if ! git -C "$repo" merge-base --is-ancestor "$old" "$new"; then
	warn "your checkout and $upstream have diverged. Either you have local commits, or the history on $upstream was rewritten (force-pushed), which is unusual for this repo. Nothing from $upstream gets installed. To see what happened: git -C $repo log --graph HEAD $upstream. Only move to it after reading the whole difference (git -C $repo diff HEAD $upstream), since once your checkout points at it, the next run builds it without asking."
	info "rebuilding what you already have"
	run_install
fi

# --- review -----------------------------------------------------------------

# Commit messages, author names and file contents come from whoever pushed.
# Everything shown here goes through clean(): control characters are
# dropped (escape sequences could hide or rewrite text on your terminal)
# and every non-ASCII byte becomes "?" (right-to-left overrides and
# look-alike letters can make code read differently than it runs). This
# repo is plain ASCII, so a "?" in the view is worth a close look.
clean() {
	tr -d '\000-\010\013-\037\177' | tr '\200-\377' '?'
}

# --text: a NUL byte, or a .gitattributes line, would otherwise make git
# print "Binary files differ" and hide the file's contents from you.
# --no-renames: a rename shows as delete plus add, so moving a .c file to
# a .md name still lists the .c file as changed code.
show_diff() {
	git -C "$repo" --no-pager diff --no-color --no-ext-diff --no-textconv \
		--text --no-renames "$old" "$new"
}

printf '\n'
info "new commits on $upstream (author names are whatever the pusher typed):"
git -C "$repo" --no-pager log --no-color --reverse \
	--format='  %h  %ad  %an%n        %s' --date=short "$old..$new" | clean

printf '\n'
info "files changed:"
git -C "$repo" --no-pager diff --no-color --no-renames --stat=100 "$old" "$new" | clean

# git's numstat prints "-" counts for files it considers binary. The diff
# view below forces text, so name them here and say so.
binary=$(git -C "$repo" diff --numstat --no-renames "$old" "$new" |
	awk -F '\t' '$1 == "-" && $2 == "-" { print $3 }' | clean)
if [ -n "$binary" ]; then
	printf '\n'
	warn "git treats these changed files as binary (\"Bin\" above). This repo has no binary files, so that usually means a NUL byte or similar in source. The diff view shows them as text anyway:"
	printf '%s\n' "$binary" | while IFS= read -r f; do
		printf '    %s\n' "$f"
	done
fi

# Everything except the docs ends up in the kernel or runs as root. A
# symlink could make a "doc" feed the build, and .gitattributes or
# .gitmodules change how git treats files, so if the repo has any of
# those (it normally has none), every change counts.
odd_files=$({ git -C "$repo" ls-tree -r "$new" | awk '$1 == "120000"' | cut -f 2-
	git -C "$repo" ls-tree -r --name-only "$new" |
		grep -E '(^|/)\.git(attributes|modules)$' || true; } | clean)
changed=$(git -C "$repo" diff --name-only --no-renames "$old" "$new" | clean)
if [ -n "$odd_files" ]; then
	printf '\n'
	warn "the repo contains symlinks, .gitattributes or .gitmodules, which it normally doesn't. Treating every changed file as code:"
	printf '%s\n' "$odd_files" | while IFS= read -r f; do
		printf '    %s\n' "$f"
	done
	risky=$changed
else
	risky=$(printf '%s\n' "$changed" |
		grep -v -E -e '\.md$' -e '^LICENSE\.(bsd|gpl)$' -e '^\.gitignore$' -e '^$' || true)
fi

printf '\n'
if [ -n "$risky" ]; then
	warn "these changes become kernel code or run as root during install:"
	printf '%s\n' "$risky" | while IFS= read -r f; do
		printf '    %s\n' "$f"
	done
else
	info "only documentation changed"
fi

# Count every byte that isn't tab, newline or printable ASCII: NUL, CR,
# vertical tab, form feed, escapes and all non-ASCII. wc reads everything,
# so git never dies of SIGPIPE under pipefail.
odd=$({ show_diff; git -C "$repo" --no-pager log --format='%an%n%B' "$old..$new"; } |
	tr -d '\011\012\040-\176' | wc -c)
if [ "${odd:-0}" -gt 0 ]; then
	printf '\n'
	warn "the new commits contain non-ASCII or control characters. This repo is plain ASCII. In this view control characters are removed and non-ASCII bytes show as ?, but the real characters are in the code, so read the diff closely."
fi
printf '\n'

if [ "$assume_yes" -eq 0 ]; then
	if [ ! -t 0 ]; then
		warn "new commits need a review before they are installed, so they were left out. Run this from a terminal to review them, or pass -y to skip the review."
		info "rebuilding what you already have (${old:0:12}), in case the kernel changed"
		run_install
	fi
	pager=$(git -C "$repo" var GIT_PAGER)
	while :; do
		printf 'Install these changes? [y]es, [n]o, [d]iff: '
		if ! IFS= read -r answer; then
			printf '\n'
			die "no answer, nothing changed"
		fi
		case $answer in
		y | Y | yes)
			break
			;;
		n | N | no | '')
			info "new commits left out, $repo is still at ${old:0:12}. Rebuilding what you already have, in case the kernel changed."
			run_install
			;;
		d | D | diff)
			# sanitized, then through less or whichever pager git uses.
			# The pager command comes from your own git config.
			show_diff | clean | LESS=${LESS-FRX} sh -c "$pager" || true
			;;
		*)
			printf 'Type y, n or d.\n'
			;;
		esac
	done
fi

# --- apply ------------------------------------------------------------------

# Move to exactly the commit that was shown, not whatever the remote
# has by now, so nothing pushed during the review slips in.
git -C "$repo" -c core.fileMode=false merge --ff-only --quiet "$new"
info "updated $repo to ${new:0:12}"

# The merge swapped the files on disk, so this runs the reviewed install.sh
run_install
