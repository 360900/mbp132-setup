#!/usr/bin/env bash
# mbp132-setup.sh: graphical installer for 2016-2017 MacBook Pros on Arch-based
# distributions. It runs mbp132-setup-cli.sh, which also works without a desktop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUI="$SCRIPT_DIR/gui/mbp132_setup_gui.py"
DEPS=(python python-gobject python-cairo gtk4 libadwaita polkit)

die() { printf 'xx  %s\n' "$*" >&2; exit 1; }

(( $# == 0 )) || die "Options go to the command-line script: sudo ./mbp132-setup-cli.sh $*"
[[ $EUID -ne 0 ]] || die "Run this as your normal user, without sudo. It asks for your password when it installs."
[[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]] || die "No desktop session found. Use ./mbp132-setup-cli.sh instead."
[[ -f $GUI ]] || die "Missing $GUI. Run this from a clone of the repository."
command -v pacman >/dev/null || die "This script supports Arch-based distributions (pacman) only."

missing=()
for pkg in "${DEPS[@]}"; do
    pacman -Q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if (( ${#missing[@]} )); then
    printf '==> The installer window needs: %s\n' "${missing[*]}"
    sudo pacman -S --needed --noconfirm "${missing[@]}"
fi

exec python3 -I "$GUI"
