#!/usr/bin/env bash
# mbp132-setup.sh: one-shot Linux setup for the MacBook Pro 13" 2016 with Touch Bar
# (model identifier MacBookPro13,2) on Arch-based distributions.
#
# What it sets up:
#   - Audio:      Cirrus CS8409 driver (davidjo/snd_hda_macbookpro), via DKMS
#   - Touch Bar:  iBridge / Touch Bar / ambient light sensor driver, via DKMS,
#                 with the fixes needed on 6.15+ / 7.x kernels
#   - Sleep:      reliable suspend (deep / S3), USB-C ports survive sleep;
#                 hibernation is hidden
#   - Keyboard:   optional ISO layout fix, Fn <-> left Ctrl swap and
#                 Windows-style modifier keys with a working AltGr (KDE)
#   - Wi-Fi:      BCM43602 defaults that work best on this board: no NVRAM file,
#                 power saving off, no shared placeholder MAC (NetworkManager).
#                 2.4 GHz only; 5 GHz needs calibration data nobody has yet.
#
# Tested on: MacBookPro13,2, CachyOS, kernel 7.2.9 (GRUB, mkinitcpio, systemd).
#
# Usage: sudo ./mbp132-setup.sh [options]
#   --iso            fix swapped keys on ISO (non-US) keyboards (applespi iso_layout=1)
#   --fn-ctrl-swap   swap Fn and left Ctrl (applespi fnremap=1)
#   --windows-keys   KDE: swap left Option/Command (Windows order Ctrl-Win-Alt)
#                    and make right Command + right Option act as AltGr;
#                    applied to the invoking user and as default for new users
#   --no-audio      skip the audio driver
#   --no-touchbar    skip the Touch Bar driver
#   --no-sleep       skip the suspend fixes
#   --no-wifi        skip the Wi-Fi settings
#   --wifi-mac MAC   use this Wi-Fi MAC address (e.g. the one macOS shows)
#                    instead of a stable per-network address
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
F_KXKB_DEFAULT=/etc/xdg/kxkbrc
F_WIFI_DISPATCH=/etc/NetworkManager/dispatcher.d/99-mbp132-wifi-powersave
F_WIFI_NMCONF=/etc/NetworkManager/conf.d/mbp132-wifi.conf
FW_BRCM_DIR=/usr/lib/firmware/brcm
WIFI_BACKUP=/var/lib/mbp132-setup/nvram-backup
XKB_OPTIONS="altwin:swap_lalt_lwin,lv3:rwin_switch"
MARKER="# Installed by mbp132-setup.sh"

DO_AUDIO=1 DO_TB=1 DO_SLEEP=1 DO_WIFI=1 OPT_ISO=0 OPT_FNSWAP=0 OPT_WINKEYS=0 FORCE=0 UNINSTALL=0
WIFI_MAC=""

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
    (( DO_WIFI )) && pkgs+=(iw)
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

# Windows-style modifiers for KDE Plasma. Swapping only the LEFT Option and
# Command keeps the right Option key as AltGr (Linux's "3rd level" key), and
# lv3:rwin_switch also turns right Command (where Windows has AltGr) into AltGr.
# Swapping both sides (altwin:swap_alt_win) would remove AltGr entirely.
install_windows_keys() {
    (( OPT_WINKEYS )) || return 0
    log "Keyboard: Windows-style modifiers (XKB options: $XKB_OPTIONS)"

    # Default for users who have not changed their keyboard options yet.
    if [[ -f "$F_KXKB_DEFAULT" ]] && ! grep -qF "$MARKER" "$F_KXKB_DEFAULT"; then
        warn "$F_KXKB_DEFAULT exists and is not ours; not touching the system default."
    else
        write_file "$F_KXKB_DEFAULT" 644 <<EOF
$MARKER
[Layout]
Options=$XKB_OPTIONS
ResetOldOptions=true
EOF
    fi

    # The user who ran sudo: their own kxkbrc overrides the default.
    local user="${SUDO_USER:-}" kwc
    kwc="$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)"
    if [[ -n "$user" && "$user" != root && -n "$kwc" ]]; then
        sudo -u "$user" "$kwc" --file kxkbrc --group Layout --key Options "$XKB_OPTIONS"
        sudo -u "$user" "$kwc" --file kxkbrc --group Layout --key ResetOldOptions true
        log "Applied for user '$user' (takes effect after logging out and in)"
    else
        warn "Could not apply to your user (no SUDO_USER or kwriteconfig). Set it in System Settings > Keyboard > Key Bindings."
    fi
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
# Installed by mbp132-setup.sh: runs around every sleep.
# pre:  disable ACPI wake sources that cause instant wake-ups (lid sensor, USB,
#       Wi-Fi, PCIe root ports), keep keyboard/trackpad wake (SPIT) on, keep
#       every PCI device out of d3cold, and unload the Thunderbolt driver
#       (its suspend/resume fails and the USB-C ports disappear after waking).
# post: load the Thunderbolt driver again so the USB-C ports come back.
case "$1" in
pre)
    for d in LID0 XHC1 XHC2 XHC3 ARPT RP01 RP05 RP09 RP12; do
        grep -q "^$d.*enabled" /proc/acpi/wakeup && echo "$d" > /proc/acpi/wakeup
    done
    grep -q "^SPIT.*disabled" /proc/acpi/wakeup && echo SPIT > /proc/acpi/wakeup
    for f in /sys/bus/pci/devices/*/d3cold_allowed; do echo 0 > "$f"; done
    modprobe -r thunderbolt
    ;;
post)
    modprobe thunderbolt
    ;;
esac
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

# ------------------------------------------------------------------- wi-fi --
# Findings on MacBookPro13,2 (board 0x157, subsystem 106b:0157):
#  - NVRAM files shared online are for other boards (e.g. MacBookPro13,3,
#    boardtype 0x61b). On this board they make association fail.
#  - With no NVRAM file the firmware falls back to its own defaults: a good
#    2.4 GHz link, no 5 GHz band, and Broadcom's placeholder MAC
#    00:90:4c:0d:f4:3e, which is identical on every such machine.
#  - Power saving makes the link slow and laggy.
validate_wifi_mac() {
    local mac=${WIFI_MAC,,}
    [[ $mac =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "--wifi-mac: '$WIFI_MAC' is not a MAC address (format aa:bb:cc:dd:ee:ff)."
    [[ $mac == 00:90:4c:* ]] && die "--wifi-mac: $WIFI_MAC is Broadcom's placeholder address; use your Mac's real one (macOS: ifconfig en0 | grep ether)."
    (( 0x${mac:0:2} & 1 )) && die "--wifi-mac: $WIFI_MAC is a multicast address."
    WIFI_MAC=$mac
}

install_wifi() {
    log "Wi-Fi: BCM43602 settings"
    local f
    shopt -s nullglob
    for f in "$FW_BRCM_DIR"/brcmfmac43602-pcie*.txt "$FW_BRCM_DIR"/brcmfmac43602-pcie*.txt.{xz,zst}; do
        if pacman -Qqo "$f" >/dev/null 2>&1; then
            warn "$f belongs to package '$(pacman -Qqo "$f")'; leaving it. If Wi-Fi fails, remove that package."
            continue
        fi
        mkdir -p "$WIFI_BACKUP"
        mv -f "$f" "$WIFI_BACKUP/"
        warn "Moved $f to $WIFI_BACKUP/ (NVRAM files made for other boards break Wi-Fi on this model)."
    done
    shopt -u nullglob

    if [[ ! -d /etc/NetworkManager ]]; then
        warn "NetworkManager not found; skipping the power-saving and MAC settings."
        return 0
    fi

    write_file "$F_WIFI_DISPATCH" 755 <<'EOF'
#!/bin/sh
# Installed by mbp132-setup.sh: turn off Wi-Fi power saving whenever a Wi-Fi
# interface comes up (it makes the BCM43602 slow and laggy).
[ "$2" = up ] && case "$1" in wl*) iw dev "$1" set power_save off ;; esac
exit 0
EOF
    systemctl enable NetworkManager-dispatcher.service >/dev/null 2>&1 || true

    local mac_value=stable mac_note="a stable address per network instead of the shared placeholder"
    if [[ -n "$WIFI_MAC" ]]; then
        mac_value=$WIFI_MAC mac_note="the address given with --wifi-mac"
    fi
    write_file "$F_WIFI_NMCONF" 644 <<EOF
$MARKER
# Without an NVRAM file the BCM43602 reports Broadcom's placeholder MAC
# (00:90:4c:0d:f4:3e), the same on every machine. Use ${mac_note}.
[connection-mbp132-wifi]
match-device=driver:brcmfmac
wifi.cloned-mac-address=${mac_value}
EOF
    command -v nmcli >/dev/null && nmcli general reload conf >/dev/null 2>&1 || true
}

# --------------------------------------------------------------- uninstall --
uninstall() {
    log "Removing everything installed by this script"
    rm -f "$F_TB_MODPROBE" "$F_TB_LOAD" "$F_KBD_MODPROBE" "$F_UDEV" "$F_HOOK" "$F_SLEEPCONF" \
          "$F_WIFI_DISPATCH" "$F_WIFI_NMCONF"
    if [[ -d "$WIFI_BACKUP" ]]; then
        local f
        for f in "$WIFI_BACKUP"/*; do
            [[ -e "$f" ]] || continue
            mv -f "$f" "$FW_BRCM_DIR/" && log "Restored $FW_BRCM_DIR/$(basename "$f")"
        done
        rmdir "$WIFI_BACKUP" "$(dirname "$WIFI_BACKUP")" 2>/dev/null || true
    fi
    if [[ -f "$F_KXKB_DEFAULT" ]] && grep -qF "$MARKER" "$F_KXKB_DEFAULT"; then
        rm -f "$F_KXKB_DEFAULT"
    fi
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
        --windows-keys) OPT_WINKEYS=1 ;;
        --no-audio)     DO_AUDIO=0 ;;
        --no-touchbar)  DO_TB=0 ;;
        --no-sleep)     DO_SLEEP=0 ;;
        --no-wifi)      DO_WIFI=0 ;;
        --wifi-mac)     [[ $# -ge 2 ]] || die "--wifi-mac needs an address"; WIFI_MAC=$2; shift ;;
        --wifi-mac=*)   WIFI_MAC=${1#*=} ;;
        --force)        FORCE=1 ;;
        --uninstall)    UNINSTALL=1 ;;
        -h|--help)      usage ;;
        *)              die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

preflight
if (( UNINSTALL )); then uninstall; exit 0; fi
[[ -n "$WIFI_MAC" ]] && validate_wifi_mac

install_deps
(( DO_AUDIO )) && install_audio
(( DO_TB ))    && install_touchbar
install_keyboard
install_windows_keys
(( DO_SLEEP )) && install_sleep
(( DO_WIFI ))  && install_wifi
rebuild_initramfs

echo
log "All done. Reboot to apply."
cat <<'EOF'

After rebooting:
  - Touch Bar should light up; hold Fn for F1-F12.
  - Suspend: close the lid, then press a key to wake (lid-open wake is off on purpose).
  - AltGr (with --windows-keys): right Command or right Option, e.g. AltGr+Q = @ on Turkish Q.
  - After each kernel update, check that both drivers rebuilt:  dkms status
Tips:
  - Double or missed keystrokes: KDE System Settings > Accessibility >
    Keyboard Filters > Bounce keys (~40 ms).
  - Wi-Fi: 2.4 GHz only. For 5 GHz use a USB adapter (e.g. MediaTek MT7921AU).
EOF
