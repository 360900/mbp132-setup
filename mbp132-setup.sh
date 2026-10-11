#!/usr/bin/env bash
# mbp132-setup.sh: one-shot Linux setup for the MacBook Pro 13" 2016 with Touch Bar
# (model identifier MacBookPro13,2) on Arch-based distributions.
#
# What it sets up:
#   - Audio:      Cirrus CS8409 driver (davidjo/snd_hda_macbookpro), via DKMS
#   - Touch Bar:  iBridge / Touch Bar / ambient light sensor driver, via DKMS,
#                 with the fixes needed on 6.15+ / 7.x kernels
#   - Sleep:      reliable suspend (deep / S3); hibernation is hidden
#   - Keyboard:   optional ISO layout fix and Fn <-> left Ctrl swap
#   Wi-Fi (BCM43602) doesn't work.
#
# Tested on: MacBookPro13,2, CachyOS, kernel 7.2.9 (GRUB, mkinitcpio, systemd).
#
# Usage: sudo ./mbp132-setup.sh [options]
#   --iso            fix swapped keys on ISO (non-US) keyboards (applespi iso_layout=1)
#   --fn-ctrl-swap   swap Fn and left Ctrl (applespi fnremap=1)
#   --no-audio       skip the audio driver
#   --no-touchbar    skip the Touch Bar driver
#   --no-sleep       skip the suspend fixes
#   --force          run on a model other than MacBookPro13,2 (untested!)
#   --uninstall      remove everything this script installed
#   -h, --help       show this help

set -euo pipefail

# ---------------------------------------------------------------- settings --
TB_REPO="${TB_REPO:-https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver.git}"
TB_BRANCH="${TB_BRANCH:-touchbar-driver-hid-driver}"
AUDIO_REPO="${AUDIO_REPO:-https://github.com/davidjo/snd_hda_macbookpro.git}"

SRC_DIR=/usr/local/src/mbp132-setup
TB_NAME=appleibridge
TB_VER=0.1
TB_DKMS_SRC="/usr/src/${TB_NAME}-${TB_VER}"
EXPECTED_MODEL="MacBookPro13,2"

F_TB_MODPROBE=/etc/modprobe.d/mbp132-touchbar.conf
F_TB_LOAD=/etc/modules-load.d/mbp132-touchbar.conf
F_KBD_MODPROBE=/etc/modprobe.d/mbp132-applespi.conf
F_UDEV=/etc/udev/rules.d/99-mbp132-sleep.rules
F_HOOK=/usr/lib/systemd/system-sleep/mbp132-sleep-fix
F_SLEEPCONF=/etc/systemd/sleep.conf.d/mbp132-no-hibernate.conf

DO_AUDIO=1 DO_TB=1 DO_SLEEP=1 OPT_ISO=0 OPT_FNSWAP=0 FORCE=0 UNINSTALL=0

# ----------------------------------------------------------------- helpers --
c_ok=$'\e[32m' c_warn=$'\e[33m' c_err=$'\e[31m' c_off=$'\e[0m'
log()  { printf '%s==>%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%sxx%s  %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0; }

# Kernels installed through pacman (each has a pkgbase file).
installed_kernels() {
    local d
    for d in /usr/lib/modules/*/; do
        [[ -f "${d}pkgbase" ]] && basename "$d"
    done
}

rebuild_initramfs() {
    if command -v mkinitcpio >/dev/null; then
        log "Rebuilding initramfs (mkinitcpio -P)"
        mkinitcpio -P
    elif command -v dracut >/dev/null; then
        log "Rebuilding initramfs (dracut)"
        dracut --regenerate-all -f
    else
        warn "No mkinitcpio or dracut found; rebuild your initramfs manually."
    fi
}

write_file() { # write_file <path> <mode>  (content from stdin)
    install -D -m "$2" /dev/stdin "$1"
    log "Wrote $1"
}

# --------------------------------------------------------------- preflight --
preflight() {
    [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
    command -v pacman >/dev/null || die "This script supports Arch-based distributions (pacman) only."

    local model
    model="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
    if [[ "$model" != "$EXPECTED_MODEL" ]]; then
        if (( FORCE )); then
            warn "Model is '$model', not $EXPECTED_MODEL. Continuing because of --force."
        else
            die "Model is '$model', not $EXPECTED_MODEL. Use --force to run anyway (untested)."
        fi
    fi
}

install_deps() {
    local pkgs=(dkms git base-devel wget patch) k
    for k in $(installed_kernels); do
        pkgs+=("$(cat "/usr/lib/modules/$k/pkgbase")-headers")
    done
    log "Installing dependencies: ${pkgs[*]}"
    pacman -S --needed --noconfirm "${pkgs[@]}"
}

git_sync() { # git_sync <url> <dir> [branch]
    local url=$1 dir=$2 branch=${3:-}
    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" pull --ff-only
    else
        git clone ${branch:+--branch "$branch"} "$url" "$dir"
    fi
}

# ------------------------------------------------------------------- audio --
install_audio() {
    log "Audio: CS8409 driver"
    if dkms status 2>/dev/null | grep -q "^snd_hda_macbookpro.*$(uname -r).*installed"; then
        log "Audio driver already installed for $(uname -r); skipping."
        return
    fi
    mkdir -p "$SRC_DIR"
    git_sync "$AUDIO_REPO" "$SRC_DIR/snd_hda_macbookpro"
    (cd "$SRC_DIR/snd_hda_macbookpro" && ./install.cirrus.driver.sh -i)
}

# --------------------------------------------------------------- touch bar --
patch_touchbar_source() {
    local f="$TB_DKMS_SRC/apple-ib-tb.c" def use
    # Fix 1: 'struct tb_touch' is used inside 'struct appletb_device' before it
    # is defined, so the build fails on 6.15+. Move the definition up.
    def=$(grep -n '^struct tb_touch {' "$f" | cut -d: -f1 || true)
    use=$(grep -n '^struct appletb_device {' "$f" | cut -d: -f1 || true)
    if [[ -n "$def" && -n "$use" && "$def" -gt "$use" ]]; then
        perl -0pi -e 's/struct tb_touch \{\n\tstruct input_dev \*input;\n\tbool mt_inited;\n\};\n//; s/(struct appletb_device \{)/struct tb_touch {\n\tstruct input_dev *input;\n\tbool mt_inited;\n};\n\n$1/' "$f"
        log "Patched apple-ib-tb.c (struct tb_touch ordering)"
    fi
}

install_touchbar() {
    log "Touch Bar: iBridge driver"
    mkdir -p "$SRC_DIR"
    git_sync "$TB_REPO" "$SRC_DIR/touchbar" "$TB_BRANCH"

    if dkms status -m "$TB_NAME" -v "$TB_VER" 2>/dev/null | grep -q .; then
        dkms remove -m "$TB_NAME" -v "$TB_VER" --all || true
    fi
    rm -rf "$TB_DKMS_SRC"
    cp -r "$SRC_DIR/touchbar" "$TB_DKMS_SRC"
    rm -rf "$TB_DKMS_SRC/.git"
    patch_touchbar_source

    dkms add -m "$TB_NAME" -v "$TB_VER"
    local k
    for k in $(installed_kernels); do
        dkms install -m "$TB_NAME" -v "$TB_VER" -k "$k" \
            || warn "Touch Bar driver failed to build for kernel $k"
    done

    # Fix 2: in 'auto'/'display' mode the driver calls usb_set_configuration()
    # from inside its own probe and deadlocks (modprobe and boot hang).
    # 'keyboard' mode keeps the current USB configuration, so no switch happens.
    # Fix 3: hid_sensor_hub grabs the second iBridge interface first and the
    # Touch Bar stays dark; apple_ib_als replaces it for the light sensor.
    write_file "$F_TB_MODPROBE" 644 <<'EOF'
# Installed by mbp132-setup.sh
# keyboard mode avoids a probe-time deadlock in auto/display mode
options apple_ibridge tb_mode_param=keyboard
# hid_sensor_hub must not claim the second iBridge interface
blacklist hid_sensor_hub
EOF
    write_file "$F_TB_LOAD" 644 <<'EOF'
# Installed by mbp132-setup.sh
apple-ibridge
apple-ib-tb
apple-ib-als
EOF
}

# ---------------------------------------------------------------- keyboard --
install_keyboard() {
    (( OPT_ISO || OPT_FNSWAP )) || return 0
    local opts=""
    (( OPT_ISO ))    && opts+=" iso_layout=1"
    (( OPT_FNSWAP )) && opts+=" fnremap=1"
    if grep -rqs "options applespi" /etc/modprobe.d/ --exclude="$(basename "$F_KBD_MODPROBE")"; then
        warn "Another file in /etc/modprobe.d already sets applespi options; check for duplicates."
    fi
    write_file "$F_KBD_MODPROBE" 644 <<EOF
# Installed by mbp132-setup.sh
options applespi${opts}
EOF
}

# ------------------------------------------------------------------- sleep --
install_sleep() {
    log "Sleep: suspend fixes"
    write_file "$F_UDEV" 644 <<'EOF'
# Installed by mbp132-setup.sh
# Apple S3X NVMe: the d3cold power state breaks resume
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x106b", ATTR{device}=="0x2003", ATTR{d3cold_allowed}="0"
# USB controllers: no spurious wake-ups, no d3cold (Thunderbolt xHCI fails to resume from it)
ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x0c0330", ATTR{power/wakeup}="disabled", ATTR{d3cold_allowed}="0"
EOF

    write_file "$F_HOOK" 755 <<'EOF'
#!/bin/sh
# Installed by mbp132-setup.sh: runs before every sleep.
# Disables ACPI wake sources that cause instant wake-ups (lid sensor, USB,
# Wi-Fi, PCIe root ports), keeps keyboard/trackpad wake (SPIT) on, and keeps
# every PCI device out of d3cold.
[ "$1" = pre ] || exit 0
for d in LID0 XHC1 XHC2 XHC3 ARPT RP01 RP05 RP09 RP12; do
    grep -q "^$d.*enabled" /proc/acpi/wakeup && echo "$d" > /proc/acpi/wakeup
done
grep -q "^SPIT.*disabled" /proc/acpi/wakeup && echo SPIT > /proc/acpi/wakeup
for f in /sys/bus/pci/devices/*/d3cold_allowed; do echo 0 > "$f"; done
exit 0
EOF

    write_file "$F_SLEEPCONF" 644 <<'EOF'
# Installed by mbp132-setup.sh: hibernation does not resume on this model
[Sleep]
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOF

    if grep -q "mem_sleep_default=s2idle" /proc/cmdline; then
        warn "Your kernel command line forces s2idle. This setup is tested with 'deep' sleep only."
    fi
    udevadm control --reload || true
}

# --------------------------------------------------------------- uninstall --
uninstall() {
    log "Removing everything installed by this script"
    rm -f "$F_TB_MODPROBE" "$F_TB_LOAD" "$F_KBD_MODPROBE" "$F_UDEV" "$F_HOOK" "$F_SLEEPCONF"
    if dkms status -m "$TB_NAME" -v "$TB_VER" 2>/dev/null | grep -q .; then
        dkms remove -m "$TB_NAME" -v "$TB_VER" --all || true
    fi
    rm -rf "$TB_DKMS_SRC"
    if [[ -x "$SRC_DIR/snd_hda_macbookpro/install.cirrus.driver.sh" ]]; then
        (cd "$SRC_DIR/snd_hda_macbookpro" && ./install.cirrus.driver.sh -r) || true
    fi
    rm -rf "$SRC_DIR"
    rebuild_initramfs
    log "Done. Reboot to finish."
}

# -------------------------------------------------------------------- main --
while (( $# )); do
    case $1 in
        --iso)          OPT_ISO=1 ;;
        --fn-ctrl-swap) OPT_FNSWAP=1 ;;
        --no-audio)     DO_AUDIO=0 ;;
        --no-touchbar)  DO_TB=0 ;;
        --no-sleep)     DO_SLEEP=0 ;;
        --force)        FORCE=1 ;;
        --uninstall)    UNINSTALL=1 ;;
        -h|--help)      usage ;;
        *)              die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

preflight
if (( UNINSTALL )); then uninstall; exit 0; fi

install_deps
(( DO_AUDIO )) && install_audio
(( DO_TB ))    && install_touchbar
install_keyboard
(( DO_SLEEP )) && install_sleep
rebuild_initramfs

echo
log "All done. Reboot to apply."
cat <<'EOF'

After rebooting:
  - Touch Bar should light up; hold Fn for F1-F12.
  - Suspend: close the lid, then press a key to wake (lid-open wake is off on purpose).
  - After each kernel update, check that both drivers rebuilt:  dkms status
Tips:
  - Double or missed keystrokes: KDE System Settings > Accessibility >
    Keyboard Filters > Bounce keys (~40 ms). It's probably hardware failure as it's common in these models but I'm not sure.
  - Wi-Fi (BCM43602) is not covered; a USB Wi-Fi adapter (MediaTek MT7921AU) is the reliable fix. It kind of works for 2.4GHz networks if they are VERY close but it's painfully slow and unreliable. Get an adapter.
EOF
