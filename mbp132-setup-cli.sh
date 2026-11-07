#!/usr/bin/env bash
# mbp132-setup-cli.sh: command-line version of the one-shot Linux setup for the MacBook Pro 13" 2016 with Touch Bar
# (model identifier MacBookPro13,2) on Arch-based distributions. The other
# 2016-2017 MacBook Pros (13,1 13,3 14,1 14,2 14,3) are supported but untested;
# the Touch Bar and Wi-Fi parts are installed only where that hardware exists.
#
# What it sets up:
#   - Audio:      Cirrus CS8409 driver (davidjo/snd_hda_macbookpro), via DKMS,
#                 set up again after sleep; volume slider with even steps
#                 that stay audible at low settings
#   - Touch Bar:  iBridge / Touch Bar / ambient light sensor driver, via DKMS,
#                 with the fixes needed on 6.15+ / 7.x kernels
#   - Sleep:      reliable suspend (deep / S3); hibernation is hidden; USB-C
#                 devices stay connected across sleep (MacBookPro13,2, via DKMS)
#   - Keyboard:   optional ISO layout fix, Fn <-> left Ctrl swap and
#                 Windows-style modifier keys with a working AltGr (KDE)
#   - iPhone:     usbmuxd (USB tethering), without it turning the Touch Bar off
#   - Wi-Fi:      BCM43602 calibration file (MacBookPro13,2): 2.4 GHz and all
#                 5 GHz channels allowed in your country (radar channels
#                 included), 80 MHz 802.11ac; power saving off; driver reloaded
#                 around sleep and 5 GHz restored after it. Other BCM43602
#                 models: no calibration file, 2.4 GHz only.
#   - Boot menu:  a macOS entry in GRUB, if GRUB is the boot loader and the
#                 firmware has an entry for macOS
#
# Tested on: MacBookPro13,2, CachyOS, kernel 7.3.1 (GRUB, mkinitcpio, systemd).
#
# The script runs from a clone of this repository: it installs the drivers
# vendored under drivers/ instead of cloning anything at install time.
#
# Usage: sudo ./mbp132-setup-cli.sh [options]
#   --iso            fix swapped keys on ISO (non-US) keyboards (applespi iso_layout=1)
#   --fn-ctrl-swap   swap Fn and left Ctrl (applespi fnremap=1)
#   --windows-keys   KDE: swap left Option/Command (Windows order Ctrl-Win-Alt)
#                    and make right Command + right Option act as AltGr;
#                    applied to the invoking user and as default for new users
#   --reset-keyboard remove the keyboard settings of earlier runs first; the
#                    three options above then apply on top
#   --no-audio     skip the audio driver
#   --no-touchbar    skip the Touch Bar driver
#   --no-sleep       skip the suspend fixes
#   --no-wifi        skip the Wi-Fi settings
#   --wifi-mac MAC   the Mac's real Wi-Fi MAC address (macOS: ifconfig en0);
#                    without it a stable made-up address is used
#   --wifi-country CC[/REV]
#                    Wi-Fi country, e.g. TR (default: the system's regulatory
#                    country); REV picks a firmware table revision
#   --force          run on a model that is not a 2016-2017 MacBook Pro
#   --uninstall      remove everything this script installed
#   --report         write a hardware/driver report for bug reports (any
#                    model, changes nothing; run with sudo for kernel logs)
#   -h, --help       show this help

set -euo pipefail

# The graphical installer runs this through pkexec, which sets PKEXEC_UID
# instead of SUDO_USER. The per-user steps need the real user either way.
if [[ -z ${SUDO_USER:-} && -n ${PKEXEC_UID:-} ]]; then
    SUDO_USER=$(id -nu "$PKEXEC_UID")
fi

# ---------------------------------------------------------------- settings --
# The script runs from a clone of this repository; the drivers it installs
# are vendored under drivers/ (nothing is cloned from the network at install
# time; see README.md).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVERS_DIR="$SCRIPT_DIR/drivers"

SRC_DIR=/usr/local/src/mbp132-setup
AUDIO_SYS_DIR="$SRC_DIR/snd_hda_macbookpro"
AUDIO_REV="$SRC_DIR/snd_hda_macbookpro.rev"
TB_NAME=appleibridge
SXFP_NAME=apple-tb-sxfp
# Models where apple-tb-sxfp (drivers/apple-tb-sxfp) has been tested.
SXFP_MODELS=" MacBookPro13,2 "

# Support status per model. What gets installed depends on the hardware found
# (Touch Bar, Wi-Fi chip), not on this table.
declare -A MODEL_STATUS=(
    [MacBookPro13,1]=untested [MacBookPro13,2]=tested [MacBookPro13,3]=untested
    [MacBookPro14,1]=untested [MacBookPro14,2]=untested [MacBookPro14,3]=untested
)

F_TB_MODPROBE=/etc/modprobe.d/mbp132-touchbar.conf
F_TB_LOAD=/etc/modules-load.d/mbp132-touchbar.conf
F_IBRIDGE_UDEV=/etc/udev/rules.d/40-mbp132-ibridge.rules
T1_BACKUP=/var/lib/mbp132-setup/t1-firmware
F_KBD_MODPROBE=/etc/modprobe.d/mbp132-applespi.conf
F_UDEV=/etc/udev/rules.d/99-mbp132-sleep.rules
F_HOOK=/usr/lib/systemd/system-sleep/mbp132-sleep-fix
F_SXFP_MODPROBE=/etc/modprobe.d/mbp132-thunderbolt.conf
F_SLEEPCONF=/etc/systemd/sleep.conf.d/mbp132-no-hibernate.conf
F_SLEEP_MODE=/etc/systemd/sleep.conf.d/mbp132-s2idle.conf # older versions only
F_KXKB_DEFAULT=/etc/xdg/kxkbrc
F_WIFI_DISPATCH=/etc/NetworkManager/dispatcher.d/99-mbp132-wifi-powersave
F_WIFI_NMCONF=/etc/NetworkManager/conf.d/mbp132-wifi.conf
F_WIFI_RELOAD=/usr/lib/systemd/system-sleep/mbp132-wifi-reload
F_WIFI_FEM=/usr/local/libexec/mbp132-wifi-femctrl
FW_BRCM_DIR=/usr/lib/firmware/brcm
WIFI_BACKUP=/var/lib/mbp132-setup/nvram-backup
WIFI_NVRAM_TEMPLATE="$SCRIPT_DIR/firmware/brcmfmac43602-pcie.txt.in"
F_WP_VOLUME=/etc/wireplumber/wireplumber.conf.d/50-mbp132-volume.conf # older versions only
ALSA_VOLUME_NAME=50-mbp132-volume.conf   # in /var/lib/alsa/cardN.conf.d/
F_VOLUME_HELPER=/usr/local/libexec/mbp132-volume
F_VOLUME_SERVICE=/etc/systemd/system/mbp132-volume.service
F_VOLUME_UDEV=/etc/udev/rules.d/90-mbp132-volume.rules
VOLUME_PROFILE_SET=/run/mbp132-setup/acp-default.conf
# Models whose BCM43602 calibration file (firmware/) has been tested.
WIFI_NVRAM_MODELS=" MacBookPro13,2 "
# Firmware country revisions that open more 5 GHz channels than revision 0.
declare -A WIFI_COUNTRY_REV=([TR]=1)
XKB_OPTIONS="altwin:swap_lalt_lwin,lv3:rwin_switch"
MARKER="# Installed by mbp132-setup.sh"
F_GRUB_DEFAULT=/etc/default/grub
GRUB_BEGIN="# BEGIN mbp132-setup.sh"
GRUB_END="# END mbp132-setup.sh"
EFIVARS=/sys/firmware/efi/efivars
V_LOADER_INFO=LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
V_APPLE_BOOT_DEVICE=efi-boot-device-7c436110-ab2a-4bbb-a880-fe41995c9f82

DO_AUDIO=1 DO_TB=1 DO_SLEEP=1 DO_WIFI=1 OPT_ISO=0 OPT_FNSWAP=0 OPT_WINKEYS=0 OPT_RESET_KBD=0 FORCE=0 UNINSTALL=0 REPORT=0
WIFI_MAC="" WIFI_COUNTRY=""
HAS_T1=0 T1_RECOVERY=0 HAS_BCM43602=0 HAS_GRUB=0

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
    case "${MODEL_STATUS[$model]:-}" in
        tested)   ;;
        untested) warn "$model is supported but untested. Please run --report afterwards and open a test report." ;;
        *)        (( FORCE )) || die "Model '$model' is not supported. Use --force to run anyway, or --report to send hardware info."
                  warn "Model '$model' is not supported. Continuing because of --force." ;;
    esac
}

# ---------------------------------------------------------------- hardware --
has_usb() { # has_usb <vendor> <product>
    local d
    for d in /sys/bus/usb/devices/*; do
        [[ "$(cat "$d/idVendor" 2>/dev/null)" == "$1" && "$(cat "$d/idProduct" 2>/dev/null)" == "$2" ]] && return 0
    done
    return 1
}

has_pci() { # has_pci <vendor> <device>
    local d
    for d in /sys/bus/pci/devices/*; do
        [[ "$(cat "$d/vendor")" == "0x$1" && "$(cat "$d/device")" == "0x$2" ]] && return 0
    done
    return 1
}

# Touch Bar models have the T1 chip, which shows up as the iBridge USB device
# (05ac:8600), or as 05ac:1281 in recovery mode when its firmware is missing.
detect_hardware() {
    if has_usb 05ac 8600; then
        HAS_T1=1
    elif has_usb 05ac 1281; then
        HAS_T1=1 T1_RECOVERY=1
    fi
    has_pci 14e4 43ba && HAS_BCM43602=1
    return 0
}

# Vendored drivers: the script must run from a clone of this repository.
# This covers someone who downloaded only the script.
check_vendored_drivers() {
    local f
    for f in "$DRIVERS_DIR/apple-ibridge/dkms.conf" "$DRIVERS_DIR/apple-tb-sxfp/dkms.conf" \
             "$DRIVERS_DIR/snd_hda_macbookpro/install.cirrus.driver.sh"; do
        [[ -f $f ]] || die "Missing $f. Run this script from a clone of the repository (see README.md)."
    done
}

install_deps() {
    local pkgs=(dkms base-devel wget patch) k
    (( DO_WIFI )) && pkgs+=(iw python)
    (( HAS_GRUB )) && pkgs+=(efibootmgr)
    # usbmuxd (iPhone tethering and file access). On T1 models it is safe only
    # together with the iBridge udev rule that install_touchbar writes.
    (( DO_TB || !HAS_T1 )) && pkgs+=(usbmuxd)
    for k in $(installed_kernels); do
        pkgs+=("$(cat "/usr/lib/modules/$k/pkgbase")-headers")
    done
    log "Installing dependencies: ${pkgs[*]}"
    pacman -S --needed --noconfirm "${pkgs[@]}"
    # --needed skips a dkms that came in as a dependency of another package, and
    # removing that package with -Rns would then remove dkms too. Without dkms
    # the drivers stop rebuilding on kernel updates.
    pacman -D --asexplicit dkms >/dev/null
}

# The audio build needs wget (kernel source from cdn.kernel.org) and patch.

# ------------------------------------------------------------------- audio --
drivers_fingerprint() { # fingerprint of a tree: sha256sum over the sorted file list and contents
    (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1
}

install_audio() {
    log "Audio: CS8409 driver"
    local vendored="$DRIVERS_DIR/snd_hda_macbookpro" fp k
    fp="$(drivers_fingerprint "$vendored")"

    # davidjo's dkms.sh symlinks /usr/src/snd_hda_macbookpro-0.1 to the
    # directory it runs from, and DKMS rebuilds from there on every kernel
    # update, so it must run from a stable system copy, never from the
    # user's clone. Skip only when the copy matches the vendored tree and
    # the module is installed for the running kernel.
    if [[ -f "$AUDIO_REV" ]] && [[ "$(cat "$AUDIO_REV")" == "$fp" ]] \
        && grep -q "^snd_hda_macbookpro.*$(uname -r).*installed" <<< "$(dkms status 2>/dev/null)"; then
        log "Audio driver already installed for $(uname -r) and unchanged; skipping."
    else
        if [[ -x "$AUDIO_SYS_DIR/install.cirrus.driver.sh" ]]; then
            (cd "$AUDIO_SYS_DIR" && ./install.cirrus.driver.sh -r) || true
        fi
        mkdir -p "$SRC_DIR"
        rm -rf "$AUDIO_SYS_DIR"
        # The code here is built and run by root later; keep the invoking
        # user's ownership off it.
        cp -r "$vendored" "$AUDIO_SYS_DIR"
        chown -R root:root "$AUDIO_SYS_DIR"
        printf '%s\n' "$fp" > "$AUDIO_REV"

        # davidjo's dkms.sh only creates its /usr/src symlink when it does not
        # exist. A manual install leaves a link into the user's old clone, and
        # DKMS would then keep building from there. Replace a stale link/copy.
        local link="/usr/src/snd_hda_macbookpro-0.1" old
        if [[ -e $link || -L $link ]] && [[ "$(readlink -f "$link")" != "$AUDIO_SYS_DIR" ]]; then
            # readlink -f fails if the target's parent is gone; show the
            # bare target then, or '?' if even that fails.
            old="$(readlink -f "$link" 2>/dev/null || readlink "$link" 2>/dev/null || echo '?')"
            warn "Removing stale $link (points at $old)"
            dkms remove snd_hda_macbookpro/0.1 --all || true
            rm -rf "$link" # if it is a symlink, only the link itself is removed
        fi

        (cd "$AUDIO_SYS_DIR" && ./install.cirrus.driver.sh -i)
    fi

    # The -i step builds only for the running kernel; make sure the driver
    # is built and installed for every other installed kernel as well.
    for k in $(installed_kernels); do
        if ! grep -q "installed" <<< "$(dkms status -m snd_hda_macbookpro -k "$k" 2>/dev/null)"; then
            dkms install snd_hda_macbookpro/0.1 -k "$k" \
                || warn "Audio driver failed to build for kernel $k"
        fi
    done

    install_volume
}

# Volume: the driver has no hardware volume, so the slider drives alsa-lib's
# "PCM" software volume (-51..0 dB) through PipeWire's cubic curve, which puts
# everything below ~20% under -42 dB: inaudible on these speakers.
#  - The software volume gets a -40..0 dB range (per-card alsa-lib config).
#  - PipeWire is told the control spans -80..0 dB (an ACP DecibelFix in a
#    profile set for this card only). That halves the dB of its cubic curve:
#    10% = -30 dB, 20% = -21 dB, 50% = -9 dB; even loudness steps, 0% silent.
# alsactl (alsa-restore.service) empties /var/lib/alsa/cardN.conf.d at boot,
# so a boot service writes both files after it, then lets udev point the
# card at the profile set. If that fails, the card keeps the stock behavior.
install_volume() {
    write_file "$F_VOLUME_HELPER" 755 <<EOF
#!/bin/sh
$MARKER: volume range and curve for the Intel HDA card (README, "Audio").
card=""
for f in /proc/asound/card*/id; do
    [ "\$(cat "\$f")" = PCH ] && card=\$(basename "\$(dirname "\$f")")
done
[ -n "\$card" ] || exit 0
dir=/var/lib/alsa/\${card}.conf.d
mkdir -p "\$dir"
cat > "\$dir/$ALSA_VOLUME_NAME" <<'ALSA'
$MARKER: analog output volume -40..0 dB (default -51..0 dB)
pcm.front.!0 {
	@args [ CARD ]
	@args.CARD { type string }
	type asym
	playback.pcm {
		type softvol
		slave.pcm { type hw card \$CARD subdevice 0 }
		control { name "PCM Playback Volume" card \$CARD }
		min_dB -40.0
	}
	capture.pcm { type hw card \$CARD }
}
ALSA
mkdir -p "$(dirname "$VOLUME_PROFILE_SET")"
{ cat /usr/share/alsa-card-profile/mixer/profile-sets/default.conf
  printf '\n; %s\n; The PCM software volume spans -40..0 dB; reporting -80..0 dB halves\n; the dB of the cubic volume curve, for even loudness steps.\n[DecibelFix PCM]\ndb-values = 0:-80 255:0\n' "$MARKER"
} > "$VOLUME_PROFILE_SET.tmp" && mv "$VOLUME_PROFILE_SET.tmp" "$VOLUME_PROFILE_SET"
udevadm trigger --action=change "/sys/class/sound/\$card"
EOF
    write_file "$F_VOLUME_SERVICE" 644 <<EOF
$MARKER
[Unit]
Description=MacBook Pro speakers: volume range and curve
After=alsa-restore.service alsa-state.service
Before=systemd-user-sessions.service display-manager.service

[Service]
Type=oneshot
ExecStart=$F_VOLUME_HELPER

[Install]
WantedBy=sound.target
EOF
    write_file "$F_VOLUME_UDEV" 644 <<EOF
$MARKER
# Built-in sound card: profile set with the volume curve fix (written at boot
# by mbp132-volume.service; without it the card keeps the stock profile set).
SUBSYSTEM=="sound", KERNEL=="card*", ATTR{id}=="PCH", TEST=="$VOLUME_PROFILE_SET", ENV{ACP_PROFILE_SET}="$VOLUME_PROFILE_SET"
EOF
    rm -f "$F_WP_VOLUME" # older versions mapped the slider with ignore-dB instead
    udevadm control --reload || true
    systemctl daemon-reload
    systemctl enable mbp132-volume.service >/dev/null 2>&1 || warn "Could not enable mbp132-volume.service."
    systemctl restart mbp132-volume.service || warn "mbp132-volume.service failed; see: journalctl -u mbp132-volume"
}

# --------------------------------------------------------------- touch bar --
tb_dkms_versions() { # all versions of the Touch Bar module known to DKMS
    # Match "name/version, kernel: state" and "name/version: added".
    dkms status -m "$TB_NAME" 2>/dev/null | sed -n "s/^${TB_NAME}\/\([^,:]*\)[,:].*/\1/p" | sort -u
}

install_touchbar() {
    log "Touch Bar: iBridge driver"
    local vendored="$DRIVERS_DIR/apple-ibridge" ver tb_dkms_src v
    ver="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$vendored/dkms.conf")"
    [[ -n "$ver" ]] || die "Cannot read PACKAGE_VERSION from $vendored/dkms.conf"
    tb_dkms_src="/usr/src/${TB_NAME}-${ver}"

    # Remove every installed DKMS version and stale /usr/src copies, so that
    # e.g. version 0.1 from older script versions is replaced cleanly.
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        dkms remove -m "$TB_NAME" -v "$v" --all || true
    done < <(tb_dkms_versions)
    rm -rf "/usr/src/${TB_NAME}-"*

    cp -r "$vendored" "$tb_dkms_src"
    chown -R root:root "$tb_dkms_src"
    dkms add -m "$TB_NAME" -v "$ver"
    local k
    for k in $(installed_kernels); do
        dkms install -m "$TB_NAME" -v "$ver" -k "$k" \
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

    # Fix 4: usbmuxd up to 1.1.1 (39-usbmuxd.rules) puts the iBridge into USB
    # configuration 0, which turns off the Touch Bar, camera and light sensor.
    # Fixed upstream in 2023 (61b99ab) but not released; set it back to 1.
    write_file "$F_IBRIDGE_UDEV" 644 <<'EOF'
# Installed by mbp132-setup.sh
# usbmuxd <= 1.1.1 unconfigures the iBridge (T1); put it back in configuration 1
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{PRODUCT}=="5ac/8600/*", ACTION=="add", ATTR{bConfigurationValue}!="1", ATTR{bConfigurationValue}="1"
EOF
    udevadm control --reload || true
}

# The T1 has no firmware in ROM: at every power-on the Mac's boot firmware
# loads it from EFI/APPLE/EMBEDDEDOS/ on the EFI partition. Without it the
# Touch Bar, camera, Touch ID and light sensor are gone (the T1 shows up as
# 05ac:1281, recovery mode), and only reinstalling macOS writes it again.
find_t1_firmware() {
    local esp
    for esp in /efi /boot /boot/efi "$(bootctl --print-esp-path 2>/dev/null)"; do
        [[ -n "$esp" && -d "$esp/EFI/APPLE/EMBEDDEDOS" ]] && { echo "$esp/EFI/APPLE/EMBEDDEDOS"; return 0; }
    done
    return 1
}

# Linux often has its own EFI partition, with the macOS one left unmounted.
# Mount each unmounted one read-only on $1 until the firmware turns up.
mount_t1_esp() {
    local dev type mnt
    while read -r dev type mnt; do
        [[ ${type,,} == c12a7328-f81f-11d2-ba4b-00a0c93ec93b && -z $mnt ]] || continue
        mount -t vfat -o ro,noatime,nosuid,nodev,noexec "$dev" "$1" 2>/dev/null || continue
        [[ -d "$1/EFI/APPLE/EMBEDDEDOS" ]] && return 0
        umount "$1" || return 1
    done < <(lsblk -rno PATH,PARTTYPE,MOUNTPOINT)
    return 1
}

check_t1() {
    local src tmp="" hint="reinstall macOS, or copy the folder back from a backup"
    if (( T1_RECOVERY )); then
        [[ -d "$T1_BACKUP" ]] && hint+=" such as $T1_BACKUP"
        warn "The T1 chip is in recovery mode (USB 05ac:1281): its firmware is missing from the EFI partition."
        warn "Touch Bar, camera, Touch ID and light sensor cannot work until EFI/APPLE/EMBEDDEDOS/ is restored"
        warn "($hint). Skipping the Touch Bar driver."
        DO_TB=0
        return 0
    fi
    if ! src="$(find_t1_firmware)"; then
        tmp="$(mktemp -d)"
        if mount_t1_esp "$tmp"; then
            src="$tmp/EFI/APPLE/EMBEDDEDOS"
        else
            rmdir "$tmp" 2>/dev/null || true
            warn "EFI/APPLE/EMBEDDEDOS/ not found on any EFI partition, so it was not backed up."
            warn "Never delete or reformat the EFI partition: it holds the Touch Bar firmware."
            return 0
        fi
    fi
    if ! { [[ -d "$T1_BACKUP" ]] && diff -rq "$src" "$T1_BACKUP" >/dev/null 2>&1; }; then
        mkdir -p "$(dirname "$T1_BACKUP")"
        rm -rf "$T1_BACKUP.new"
        if [[ -z "$(ls -A "$src")" ]]; then
            warn "$src is empty, so the T1 firmware was not backed up. Restore it before rebooting."
        elif cp -r "$src" "$T1_BACKUP.new"; then
            # Only now: this may be the last good copy.
            rm -rf "$T1_BACKUP"
            mv "$T1_BACKUP.new" "$T1_BACKUP"
            log "Backed up the T1 firmware to $T1_BACKUP; keep a copy off this machine too."
        else
            warn "Could not back up $src to $T1_BACKUP; back it up yourself."
            rm -rf "$T1_BACKUP.new"
        fi
    fi
    if [[ -n $tmp ]]; then
        umount "$tmp" && rmdir "$tmp" || warn "Could not unmount $tmp; it is read-only, reboot to clear it."
    fi
    return 0
}

# ---------------------------------------------------------------- keyboard --
# True if the invoking user's KDE options are exactly the ones this script sets.
user_has_our_xkb_options() {
    local user="${SUDO_USER:-}" krc
    krc="$(command -v kreadconfig6 || command -v kreadconfig5 || true)"
    [[ -n "$user" && "$user" != root && -n "$krc" ]] || return 1
    [[ "$(sudo -u "$user" "$krc" --file kxkbrc --group Layout --key Options 2>/dev/null || true)" == "$XKB_OPTIONS" ]]
}

reset_keyboard() {
    (( OPT_RESET_KBD )) || return 0
    log "Keyboard: removing earlier settings"
    rm -f "$F_KBD_MODPROBE"
    if [[ -f "$F_KXKB_DEFAULT" ]] && grep -qF "$MARKER" "$F_KXKB_DEFAULT"; then
        rm -f "$F_KXKB_DEFAULT"
    fi
    # Options the user changed since are theirs: leave them.
    if user_has_our_xkb_options; then
        local kwc
        kwc="$(command -v kwriteconfig6 || command -v kwriteconfig5)"
        sudo -u "$SUDO_USER" "$kwc" --file kxkbrc --group Layout --key Options --delete ''
        sudo -u "$SUDO_USER" "$kwc" --file kxkbrc --group Layout --key ResetOldOptions --delete ''
        log "Cleared for user '$SUDO_USER' (takes effect after logging out and in)"
    fi
}

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
sxfp_dkms_versions() { # all versions of apple-tb-sxfp known to DKMS
    dkms status -m "$SXFP_NAME" 2>/dev/null | sed -n "s/^${SXFP_NAME}\/\([^,:]*\)[,:].*/\1/p" | sort -u
}

remove_sxfp() {
    local v
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        dkms remove -m "$SXFP_NAME" -v "$v" --all || true
    done < <(sxfp_dkms_versions)
    rm -rf "/usr/src/${SXFP_NAME}-"*
    rm -f "$F_SXFP_MODPROBE"
}

# USB-C devices across S3: the firmware cuts the Alpine Ridge controllers'
# power in S3, and a side with a device plugged in does not come back.
# apple-tb-sxfp cuts it first, as macOS does (see drivers/README.md). It must
# load before the thunderbolt driver binds.
install_sxfp() {
    local vendored="$DRIVERS_DIR/apple-tb-sxfp" ver k model
    model="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    remove_sxfp
    if [[ $SXFP_MODELS != *" $model "* ]]; then
        log "USB-C across sleep: apple-tb-sxfp is untested on $model; skipping it."
        return 0
    fi
    log "USB-C across sleep: apple-tb-sxfp driver"
    ver="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$vendored/dkms.conf")"
    [[ -n "$ver" ]] || die "Cannot read PACKAGE_VERSION from $vendored/dkms.conf"
    cp -r "$vendored" "/usr/src/${SXFP_NAME}-${ver}"
    chown -R root:root "/usr/src/${SXFP_NAME}-${ver}"
    dkms add -m "$SXFP_NAME" -v "$ver"
    for k in $(installed_kernels); do
        dkms install -m "$SXFP_NAME" -v "$ver" -k "$k" \
            || warn "apple-tb-sxfp failed to build for kernel $k; USB-C devices drop to USB 2 after sleep there."
    done
    write_file "$F_SXFP_MODPROBE" 644 <<'EOF'
# Installed by mbp132-setup.sh
# apple_tb_sxfp must be in place before the thunderbolt driver binds
softdep thunderbolt pre: apple_tb_sxfp
EOF
}

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
#!/bin/bash
# Installed by mbp132-setup.sh: runs around every sleep.
# pre:  disable ACPI wake sources that cause instant wake-ups (lid sensor, USB,
#       Wi-Fi, PCIe root ports; matched by kind because the root port names
#       differ per model, e.g. RP10 on the 13,1), keep keyboard/trackpad wake
#       (SPIT) on, keep every PCI device out of d3cold, and unload the
#       Thunderbolt driver (its suspend/resume fails and the USB-C ports
#       disappear after waking).
#       In S3 the firmware cuts power to the Thunderbolt controllers, so remove
#       their PCI trees first. A side with a mounted disk or swap stays, because
#       removing it would tear the filesystem; S3 then loses that side anyway.
# post: load the Thunderbolt driver and rescan, which builds the trees again.
# Adapted from thunderbolt-remove-rescan in omarchy PR 11570.
# With apple_tb_sxfp loaded the trees and the Thunderbolt driver stay: the
# module cuts the power before S3 as macOS does, and devices stay connected.
# post then only rebuilds a side whose devices lost their state.
STATE=/run/mbp132-tb-removed
log() { logger -t mbp132-sleep-fix -- "$*"; }

# Upstream port of each Thunderbolt controller: an Intel bridge directly below a
# chipset root port. Also finds a tree whose driver failed to bind.
tb_ports() {
    local p
    for p in /sys/devices/pci0000:00/0000:*/0000:*; do
        [[ -e $p/remove && $(cat "$p/class") == 0x0604* && $(cat "$p/vendor") == 0x8086 ]] || continue
        [[ $(cat "$(dirname "$p")/class") == 0x0604* ]] && echo "$p"
    done
}

# Is block device $1 reached through PCI device $2? Follows dm/md slaves.
under_port() {
    local p s
    p=$(readlink -f "/sys/class/block/$1" 2>/dev/null) || return 1
    [[ $p == "$2"/* ]] && return 0
    for s in "/sys/class/block/$1"/slaves/*; do
        [[ -e $s ]] && under_port "${s##*/}" "$2" && return 0
    done
    return 1
}

# Print the first mounted or swap device reached through PCI device $1, if any.
mounted_under() {
    local dev b
    while read -r dev _; do
        [[ $dev == /dev/* ]] || continue
        b=$(readlink -f "$dev" 2>/dev/null) || continue
        under_port "${b##*/}" "$1" && { echo "$dev"; return 0; }
    done < <(cat /proc/mounts /proc/swaps 2>/dev/null)
    # /proc/mounts names one member of a multi-device btrfs; sysfs lists them all.
    for b in /sys/fs/btrfs/*/devices/*; do
        [[ -e $b ]] && under_port "${b##*/}" "$1" && { echo "/dev/${b##*/}"; return 0; }
    done
    return 1
}

# The state systemd-sleep will write to /sys/power/state: the first SuspendState=
# entry the kernel supports. Only "mem" honors mem_sleep; "freeze" is s2idle.
suspend_state() {
    local want s
    want=$(systemd-analyze cat-config systemd/sleep.conf 2>/dev/null | awk '
        /^[[:space:]]*SuspendState[[:space:]]*=/ {
            v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/"/, "", v)
            if (v ~ /^[[:space:]]*$/) s = ""; else s = s " " v
        }
        END { print s }')
    for s in ${want:-mem standby freeze}; do
        [[ " $(cat /sys/power/state 2>/dev/null) " == *" $s "* ]] && { echo "$s"; return 0; }
    done
    return 1
}

remove_trees() {
    local up rp m i ok roots=
    sync
    for up in $(tb_ports); do
        rp=$(dirname "$up")
        if m=$(mounted_under "$up"); then
            log "pre: keeping $(basename "$up"): $m is in use through it"
        elif echo 1 > "$up/remove" 2>/dev/null; then
            log "pre: removed $(basename "$up")"
            roots="$roots $rp"
            # Let the empty root port power down the way the firmware expects. The
            # d3cold settings above made its first try fail, so ask it again.
            echo 1 > "$rp/d3cold_allowed"
            echo disabled > "$rp/power/wakeup"
            echo on > "$rp/power/control"
            echo auto > "$rp/power/control"
        else
            log "pre: could not remove $(basename "$up")"
        fi
    done
    for ((i = 0; i < 50; i++)); do
        ok=1
        for rp in $roots; do
            [[ $(cat "$rp/power/runtime_status" 2>/dev/null) == suspended ]] || ok=0
        done
        (( ok )) && break
        sleep 0.1
    done
    (( ok )) || log "pre: root ports did not power down in 5 s"
}

case "$1" in
pre)
    rm -f "$STATE"
    while read -r d _ state _; do
        case "$d" in
        LID*|XHC*|ARPT|RP[0-9]*) [[ $state == "*enabled" ]] && echo "$d" > /proc/acpi/wakeup ;;
        esac
    done < /proc/acpi/wakeup
    grep -q "^SPIT.*disabled" /proc/acpi/wakeup && echo SPIT > /proc/acpi/wakeup
    for f in /sys/bus/pci/devices/*/d3cold_allowed; do echo 0 > "$f"; done
    [[ -d /sys/module/apple_tb_sxfp ]] && exit 0
    if [[ $2 == suspend && $(suspend_state) == mem && $(cat /sys/power/mem_sleep) == *'[deep]'* ]]; then
        touch "$STATE"
        remove_trees
    fi
    modprobe -r thunderbolt
    ;;
post)
    if [[ -d /sys/module/apple_tb_sxfp ]]; then
        lost=0
        for up in $(tb_ports); do
            for c in $(find "$up" -name config); do
                if [[ $(od -An -N4 -tx4 "$c" 2>/dev/null) == *ffffffff* ]]; then
                    log "post: $(basename "$up") lost its devices, rebuilding it"
                    echo 1 > "$up/remove"
                    lost=1
                    break
                fi
            done
        done
        (( lost )) && echo 1 > /sys/bus/pci/rescan
        exit 0
    fi
    modprobe thunderbolt
    if [[ -e $STATE ]]; then
        rm -f "$STATE"
        echo 1 > /sys/bus/pci/rescan
        log "post: rescanned, $(ls /sys/bus/pci/drivers/xhci_hcd | grep -c '^0000') USB controllers"
    fi
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

    rm -f "$F_SLEEP_MODE" # older versions used s2idle: about 14% battery per hour
    install_sxfp
    if grep -q "mem_sleep_default=s2idle" /proc/cmdline; then
        warn "Your kernel command line forces s2idle. It drains about 14% battery per hour on the 13,2; this setup is tested with 'deep'."
    fi
    udevadm control --reload || true
}

# ------------------------------------------------------------------- wi-fi --
# Findings on MacBookPro13,2 (board 0x157, subsystem 106b:0157):
#  - With no NVRAM file the firmware falls back to its own defaults: 2.4 GHz
#    only and Broadcom's placeholder MAC 00:90:4c:0d:f4:3e, which is identical
#    on every such machine.
#  - firmware/brcmfmac43602-pcie.txt.in (bugzilla 290569, see firmware/README.md)
#    gives both bands and 80 MHz 802.11ac. Its country must be one the
#    firmware knows, with the right revision: TR/0 leaves 100-140 off and makes
#    52-64 passive (joining a router there fails at once), TR/1 allows 52-140.
#    brcmfmac keeps the file's country if it matches the system's.
#  - Other generic 43602 NVRAM files shared online make association fail.
#  - Power saving makes the link slow and laggy.
#  - The firmware does not survive sleep: it stops answering the driver after
#    waking unless brcmfmac is reloaded around it.
#  - The Mac's firmware sets chipcontrol bit 4 (FEMCTRL) at boot. S3 can clear
#    the register and nothing else sets it again: every 5 GHz join then fails
#    with status 16 until reboot, whatever the driver does. Set it after waking,
#    before the driver loads. Found by makoni and others in omarchy PR 11570.
validate_wifi_country() {
    local cc=${WIFI_COUNTRY%%/*} rev=
    [[ $WIFI_COUNTRY == */* ]] && rev=${WIFI_COUNTRY#*/}
    cc=${cc^^}
    [[ $cc =~ ^[A-Z]{2}$ ]] || die "--wifi-country: '$WIFI_COUNTRY' is not a country code (e.g. TR or TR/1)."
    [[ -z $rev || $rev =~ ^[0-9]+$ ]] || die "--wifi-country: revision '$rev' is not a number."
    WIFI_COUNTRY=$cc${rev:+/$rev}
}

# Country for the Wi-Fi firmware as CC/REV: --wifi-country, else the system's
# regulatory country (iw reg get), else DE.
wifi_country() {
    local cc=${WIFI_COUNTRY%%/*} rev=
    [[ $WIFI_COUNTRY == */* ]] && rev=${WIFI_COUNTRY#*/}
    if [[ -z $cc ]]; then
        cc="$(iw reg get 2>/dev/null | sed -n '1,/^phy/s/^country \([A-Z][A-Z]\):.*/\1/p' | head -n1)"
        if [[ -z $cc ]]; then
            cc=DE
            warn "Wi-Fi: the system has no regulatory country set; using $cc. Pass --wifi-country CC for yours."
        fi
    fi
    echo "$cc/${rev:-${WIFI_COUNTRY_REV[$cc]:-0}}"
}

# Stable, locally administered MAC from the machine id (used without --wifi-mac).
derived_wifi_mac() {
    local h
    h="$( { cat /etc/machine-id; echo mbp132-wifi; } | sha256sum | cut -c1-10)"
    printf '02:%s:%s:%s:%s:%s\n' "${h:0:2}" "${h:2:2}" "${h:4:2}" "${h:6:2}" "${h:8:2}"
}

wifi_nvram_file() { echo "$FW_BRCM_DIR/brcmfmac43602-pcie.Apple Inc.-$(cat /sys/class/dmi/id/product_name 2>/dev/null).txt"; }

install_wifi_nvram() {
    local f mac cc
    f="$(wifi_nvram_file)"
    mac=${WIFI_MAC:-$(derived_wifi_mac)}
    cc="$(wifi_country)"
    { echo "$MARKER (firmware/brcmfmac43602-pcie.txt.in)"
      sed -e "s/@MACADDR@/$mac/" -e "s/@CCODE@/${cc%/*}/" -e "s/@REGREV@/${cc#*/}/" "$WIFI_NVRAM_TEMPLATE"
    } | write_file "$f" 644
    log "Wi-Fi calibration: MAC $mac, country ${cc%/*} revision ${cc#*/}"
    [[ -z $WIFI_MAC ]] && warn "No --wifi-mac given; using the made-up address $mac (macOS shows the real one: ifconfig en0)."
    return 0
}

validate_wifi_mac() {
    local mac=${WIFI_MAC,,}
    [[ $mac =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "--wifi-mac: '$WIFI_MAC' is not a MAC address (format aa:bb:cc:dd:ee:ff)."
    [[ $mac == 00:90:4c:* ]] && die "--wifi-mac: $WIFI_MAC is Broadcom's placeholder address; use your Mac's real one (macOS: ifconfig en0 | grep ether)."
    (( 0x${mac:0:2} & 1 )) && die "--wifi-mac: $WIFI_MAC is a multicast address."
    WIFI_MAC=$mac
}

install_wifi() {
    log "Wi-Fi: BCM43602 settings"
    local f model
    model="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    shopt -s nullglob
    for f in "$FW_BRCM_DIR"/brcmfmac43602-pcie*.txt "$FW_BRCM_DIR"/brcmfmac43602-pcie*.txt.{xz,zst}; do
        grep -qsF "$MARKER" "$f" && continue # ours, rewritten below
        if pacman -Qqo "$f" >/dev/null 2>&1; then
            warn "$f belongs to package '$(pacman -Qqo "$f")'; leaving it. If Wi-Fi fails, remove that package."
            continue
        fi
        mkdir -p "$WIFI_BACKUP"
        mv -f "$f" "$WIFI_BACKUP/"
        warn "Moved $f to $WIFI_BACKUP/ (NVRAM files made for other boards break Wi-Fi on this model)."
    done
    shopt -u nullglob

    if [[ $WIFI_NVRAM_MODELS == *" $model "* ]]; then
        install_wifi_nvram
        write_file "$F_WIFI_FEM" 755 <<'EOF'
#!/usr/bin/python3 -I
# Installed by mbp132-setup.sh: set ChipCommon chipcontrol bit 4 (FEMCTRL) on the
# BCM43602. S3 can clear it, and 5 GHz joins then fail until reboot. The register
# is volatile. Only runs with the driver unbound, on this card, and restores the
# BAR0 window.
import mmap, os, struct, sys
PCI = '/sys/bus/pci/devices'; WIN = 0x80; CC = 0x18000000; REG = 0x28; BIT = 0x10
def die(m):
    print('mbp132-wifi-femctrl: ' + m); sys.exit(1)
def ids(d):
    try:
        return [open(f'{d}/{n}').read().strip() for n in ('vendor', 'device', 'subsystem_vendor', 'subsystem_device')]
    except OSError:  # a device still being added by the rescan in the other sleep hook
        return None
D = next((f'{PCI}/{n}' for n in os.listdir(PCI) if ids(f'{PCI}/{n}') == ['0x14e4', '0x43ba', '0x106b', '0x0157']), None)
if D is None: die('card not found')
if os.path.exists(D + '/driver'): die('driver is bound')
cfg = os.open(D + '/config', os.O_RDWR)
rd = lambda o, n: os.pread(cfg, n, o)
wr = lambda o, b: os.pwrite(cfg, b, o)
cmd = rd(4, 2); old = rd(WIN, 4)
wr(4, struct.pack('<H', struct.unpack('<H', cmd)[0] | 2))
try:
    wr(WIN, struct.pack('<I', CC))
    if rd(WIN, 4) != struct.pack('<I', CC): die('window did not stick')
    fd = os.open(D + '/resource0', os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, 4096)
    r32 = lambda o: struct.unpack('<I', m[o:o+4])[0]
    if r32(0) & 0xffff != 0xaa52: die('not a 43602, chipid=%#x' % r32(0))
    v = r32(REG)
    if v & BIT:
        print('chipcontrol=%#010x, bit 4 already set' % v)
    else:
        m[REG:REG+4] = struct.pack('<I', v | BIT)
        print('chipcontrol=%#010x, set bit 4: %#010x' % (v, r32(REG)))
    m.close(); os.close(fd)
finally:
    wr(WIN, old); wr(4, cmd)
EOF
        write_file "$F_WIFI_RELOAD" 755 <<EOF
#!/bin/sh
# Installed by mbp132-setup.sh: unload brcmfmac before sleep, load it after
# waking, because the firmware stops answering otherwise. Restore 5 GHz first.
case "\$1" in
    pre)  modprobe -r brcmfmac_wcc brcmfmac ;;
    post)
        $F_WIFI_FEM
        modprobe brcmfmac
        ;;
esac
exit 0
EOF
    else
        rm -f "$F_WIFI_RELOAD" "$F_WIFI_FEM"
        log "No tested Wi-Fi calibration file for $model; Wi-Fi stays 2.4 GHz only."
    fi

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

    local mac_value=stable mac_note="a stable address per network (privacy, and never the shared placeholder)"
    if [[ -n "$WIFI_MAC" ]]; then
        mac_value=$WIFI_MAC mac_note="the address given with --wifi-mac"
    fi
    write_file "$F_WIFI_NMCONF" 644 <<EOF
$MARKER
# Without a calibration file the BCM43602 reports Broadcom's placeholder MAC
# (00:90:4c:0d:f4:3e), the same on every machine. Use ${mac_note}.
[connection-mbp132-wifi]
match-device=driver:brcmfmac
wifi.cloned-mac-address=${mac_value}
EOF
    command -v nmcli >/dev/null && nmcli general reload conf >/dev/null 2>&1 || true
}

# -------------------------------------------------------------------- grub --
# A "macOS" entry in the GRUB menu. GRUB cannot read APFS, so it asks the
# firmware to start macOS once (UEFI BootNext) and reboots. The slot number
# differs per machine and the firmware keeps stale slots, so it is looked up.
# GRUB 2.16's own generator (31_efi_bootnext) stays off: it lists stale slots,
# GRUB itself and raw device paths as menu entries.
grub_cfg_path() {
    local d
    for d in /boot/grub /efi/grub /boot/efi/grub; do
        [[ -f $d/grub.cfg ]] && { echo "$d/grub.cfg"; return 0; }
    done
    return 1
}

efi_var() { # efi_var <name-guid>: a variable's text, without its attribute bytes
    { tail -c +5 "$EFIVARS/$1" | tr -d '\0'; } 2>/dev/null || true
}

# GRUB can stay installed after a switch to another boot loader. LoaderInfo is
# set by the loader running now, if it supports that; otherwise check the
# firmware entry it started from.
grub_in_use() {
    local LC_ALL=C loader out current # ${x,,} turns I into a dotless i in Turkish
    command -v grub-mkconfig >/dev/null && [[ -f $F_GRUB_DEFAULT ]] && grub_cfg_path >/dev/null || return 1
    loader="$(efi_var "$V_LOADER_INFO")"
    [[ $loader == GRUB* ]] && return 0
    [[ -z $loader ]] || return 1
    command -v efibootmgr >/dev/null || return 0
    out="$(efibootmgr -v 2>/dev/null)" || return 0
    current="$(sed -n 's/^BootCurrent: //p' <<< "$out")"
    [[ -n $current ]] || return 0
    current="$(sed -n "s/^Boot$current\*\{0,1\} //p" <<< "$out")"
    current=${current,,}
    [[ $current != *refind* && $current != *limine* && $current != *systemd* ]]
}

# The firmware slot that starts macOS: active, on a partition that still exists,
# loading Apple's boot.efi. First choice is the one macOS itself last set as the
# startup disk, then a named slot, then any; BootOrder first within each.
macos_boot_entry() {
    local LC_ALL=C out blessed line rest n named="" any="" order=()
    local re_entry='^Boot([0-9A-Fa-f]{4})\* (.*)$' re_part='HD\([0-9]+,GPT,([0-9A-Fa-f-]{36}),'
    local -A paths=() labels=()
    out="$(efibootmgr -v 2>/dev/null)" || return 1
    blessed="$(efi_var "$V_APPLE_BOOT_DEVICE" | sed -n 's|.*<key>Path</key><string>\([^<]*\)</string>.*|\1|p')"
    IFS=', ' read -r -a order <<< "$(sed -n 's/^BootOrder: //p' <<< "$out")"
    while IFS= read -r line; do
        [[ $line =~ $re_entry ]] || continue
        n=${BASH_REMATCH[1]} rest=${BASH_REMATCH[2]} # "label<tab>device path"
        [[ ${n^^} != FFFF && ${rest,,} == *'\system\library\coreservices\boot.efi'* ]] || continue
        [[ $rest =~ $re_part && -e /dev/disk/by-partuuid/${BASH_REMATCH[1],,} ]] || continue
        paths[$n]=${rest#*$'\t'}
        labels[$n]=${rest%%$'\t'*}
        order+=("$n")
    done <<< "$out"
    for n in "${order[@]}"; do
        [[ -n ${paths[$n]:-} ]] || continue
        [[ -n $blessed && ${paths[$n],,} == *"${blessed,,}"* ]] && { echo "$n"; return 0; }
        [[ -z $named && -n ${labels[$n]} ]] && named=$n
        [[ -z $any ]] && any=$n
    done
    [[ -n ${named:-$any} ]] && echo "${named:-$any}"
}

remove_macos_entry() { # remove_macos_entry <custom.cfg>
    [[ -f $1 ]] || return 0
    sed -i "/^$GRUB_BEGIN\$/,/^$GRUB_END\$/d" "$1"
    [[ -s $1 ]] || rm -f "$1"
}

install_grub() {
    log "GRUB: macOS menu entry"
    local cfg custom entry="" written=0
    cfg="$(grub_cfg_path)"
    custom="$(dirname "$cfg")/custom.cfg"

    # Also clears older or repeated lines; the last assignment would win anyway.
    sed -i -e '/^[[:space:]]*GRUB_DISABLE_BOOTNEXT=/d' -e '$a\' "$F_GRUB_DEFAULT"
    echo "GRUB_DISABLE_BOOTNEXT=true $MARKER" >> "$F_GRUB_DEFAULT"

    # Removed first so a slot that is gone cannot stay in the menu.
    remove_macos_entry "$custom"
    if [[ ! -d $EFIVARS ]]; then
        log "Not started through UEFI; no macOS entry."
    elif ! grep -qs '^bootnext:' "$(dirname "$cfg")/x86_64-efi/command.lst"; then
        if grep -qs '^bootnext:' /usr/lib/grub/x86_64-efi/command.lst; then
            warn "The installed GRUB is older than the package, so no macOS entry was added. Run grub-install, then this script again."
        else
            warn "This GRUB has no bootnext command (it needs 2.16), so no macOS entry was added."
        fi
    elif ! entry="$(macos_boot_entry)"; then
        log "No firmware entry for macOS found; no macOS entry."
    else
        [[ ! -f $custom ]] || sed -i '$a\' "$custom"
        cat >> "$custom" <<EOF
$GRUB_BEGIN
if [ "\$grub_platform" = "efi" ]; then
  menuentry 'macOS' --class macosx --class os \$menuentry_id_option 'efi-bootnext-$entry' {
    if bootnext $entry; then
      reboot
    fi
  }
fi
$GRUB_END
EOF
        chmod 644 "$custom"
        written=1
        log "Added macOS to $custom (firmware entry Boot$entry)"
    fi

    log "Regenerating $cfg"
    if ! grub-mkconfig -o "$cfg"; then
        warn "grub-mkconfig failed; the old $cfg is still in place."
    elif (( written )) && ! grep -qs 'custom\.cfg' "$cfg"; then
        warn "$cfg does not load custom.cfg, so macOS will not show up. Make /etc/grub.d/41_custom executable and run this script again."
    fi
}

uninstall_grub() {
    local cfg
    cfg="$(grub_cfg_path)" || return 0
    remove_macos_entry "$(dirname "$cfg")/custom.cfg"
    if grep -qs "^GRUB_DISABLE_BOOTNEXT=true $MARKER\$" "$F_GRUB_DEFAULT"; then
        sed -i "/^GRUB_DISABLE_BOOTNEXT=true $MARKER\$/d" "$F_GRUB_DEFAULT"
        if grub_in_use; then
            log "Regenerating $cfg"
            grub-mkconfig -o "$cfg" || warn "grub-mkconfig failed; run it yourself."
        fi
    fi
}

# ------------------------------------------------------------------ report --
# Hardware and driver state for bug reports, on any model. Read-only; root
# adds the kernel log. MAC addresses (except the vendor part), USB serial
# numbers, Wi-Fi network names, the hostname and the user name are masked
# before writing.
REPORT_PATTERN='apple|ibridge|applespi|brcm|cs8409|snd_hda|thunderbolt|xhci|nvme|i915|amdgpu|radeon|acpi.*(error|bug)|pm: |suspend|resume'

report_section() { # report_section <title> <command...>
    printf '\n## %s\n' "$1"
    shift
    if command -v "$1" >/dev/null; then
        "$@" 2>&1 || true
    else
        echo "($1 not installed)"
    fi
}

report_redact() {
    local host user
    host=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo)
    user=${SUDO_USER:-${USER:-}}
    sed -E \
        -e 's/(([0-9a-fA-F]{2}:){2}[0-9a-fA-F]{2}):([0-9a-fA-F]{2}:){2}[0-9a-fA-F]{2}/\1:xx:xx:xx/g' \
        -e 's/(SerialNumber|serial)([:=] *)[^ ]+/\1\2<masked>/Ig' \
        -e 's/^([[:space:]]*ssid ).*/\1<masked>/' \
        ${host:+-e "s/\\b${host}\\b/<host>/g"} \
        ${user:+-e "s/\\b${user}\\b/<user>/g"}
}

report_body() {
    local f
    echo "# mbp132-setup report"
    echo "script: $(git -C "$SCRIPT_DIR" describe --always --dirty 2>/dev/null || echo unknown)"
    echo "date:   $(date -u +%F)"
    echo "root:   $([[ $EUID -eq 0 ]] && echo yes || echo 'no (kernel log missing)')"

    printf '\n## Machine\n'
    for f in sys_vendor product_name product_version board_name bios_version bios_date; do
        printf '%-16s %s\n' "$f" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo -)"
    done
    printf '%-16s %s\n' kernel "$(uname -r)" \
        distro "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")" \
        cmdline "$(cat /proc/cmdline)"

    printf '\n## Detected\n'
    detect_hardware
    local t1=none
    (( HAS_T1 )) && t1="iBridge (05ac:8600)"
    (( T1_RECOVERY )) && t1="RECOVERY MODE (05ac:1281), firmware missing"
    printf '%-16s %s\n' support "${MODEL_STATUS[$(cat /sys/class/dmi/id/product_name 2>/dev/null)]:-not supported}" \
        T1 "$t1" \
        T1-firmware "$(find_t1_firmware || echo 'not found on a mounted EFI partition')" \
        BCM43602 "$( (( HAS_BCM43602 )) && echo yes || echo no)"

    report_section "PCI devices" lspci -nnk
    report_section "USB devices" lsusb
    report_section "DKMS" dkms status
    printf '\n## Relevant modules\n'
    grep -E '^(apple|applespi|brcm|snd_hda|thunderbolt|hid_sensor|industrialio|amdgpu|radeon|i915)' /proc/modules | cut -d' ' -f1 || true

    printf '\n## Sleep\n'
    echo "state:     $(cat /sys/power/state 2>/dev/null)"
    echo "mem_sleep: $(cat /sys/power/mem_sleep 2>/dev/null)"
    printf '\n## ACPI wake sources\n'
    cat /proc/acpi/wakeup 2>/dev/null || true

    printf '\n## Audio\n'
    cat /proc/asound/cards 2>/dev/null || echo "(no sound cards)"
    for f in /proc/asound/card*/codec#*; do
        [[ -e $f ]] && echo "$f: $(head -n1 "$f")"
    done

    printf '\n## Wi-Fi\n'
    ls -l "$FW_BRCM_DIR"/brcmfmac43602* "$FW_BRCM_DIR"/brcmfmac4350* 2>/dev/null || echo "(no matching firmware files)"
    ls -l "$WIFI_BACKUP" 2>/dev/null || true
    report_section "iw dev" iw dev
    report_section "iw reg get" iw reg get

    printf '\n## Files installed by this script\n'
    for f in "$F_TB_MODPROBE" "$F_TB_LOAD" "$F_IBRIDGE_UDEV" "$F_KBD_MODPROBE" "$F_UDEV" "$F_HOOK" "$F_SXFP_MODPROBE" \
             "$F_SLEEPCONF" "$F_SLEEP_MODE" "$F_WIFI_RELOAD" "$F_WIFI_FEM" "$F_WIFI_DISPATCH" "$F_WIFI_NMCONF" "$F_VOLUME_SERVICE" "$F_VOLUME_UDEV" \
             "$VOLUME_PROFILE_SET" "$(wifi_nvram_file)" "$T1_BACKUP"; do
        [[ -e $f ]] && echo "present: $f" || echo "missing: $f"
    done

    printf '\n## Kernel log (filtered, last 300 lines)\n'
    if [[ $EUID -eq 0 ]]; then
        dmesg 2>/dev/null | grep -iE "$REPORT_PATTERN" | tail -n 300 || true
        printf '\n## Previous boot kernel log (filtered, last 150 lines)\n'
        journalctl -k -b -1 --no-pager -q 2>/dev/null | grep -iE "$REPORT_PATTERN" | tail -n 150 || echo "(not available)"
    else
        echo "(run with sudo to include it)"
    fi
}

report() {
    local out
    out="$PWD/mbp132-report-$(date +%Y%m%d-%H%M%S).txt"
    report_body | report_redact > "$out"
    [[ -n "${SUDO_USER:-}" ]] && { chown "$SUDO_USER": "$out" 2>/dev/null || true; }
    log "Wrote $out"
    echo "Check it, then attach it to an issue: https://github.com/360900/mbp132-setup/issues/new/choose"
}

# --------------------------------------------------------------- uninstall --
uninstall() {
    log "Removing everything installed by this script"
    rm -f "$F_TB_MODPROBE" "$F_TB_LOAD" "$F_IBRIDGE_UDEV" "$F_KBD_MODPROBE" "$F_UDEV" "$F_HOOK" \
          "$F_SLEEPCONF" "$F_SLEEP_MODE" "$F_WIFI_RELOAD" "$F_WIFI_FEM" "$F_WIFI_DISPATCH" "$F_WIFI_NMCONF"
    systemctl disable mbp132-volume.service >/dev/null 2>&1 || true
    rm -f "$F_WP_VOLUME" "$F_VOLUME_HELPER" "$F_VOLUME_SERVICE" "$F_VOLUME_UDEV" "$VOLUME_PROFILE_SET" \
          /var/lib/alsa/card*.conf.d/"$ALSA_VOLUME_NAME"
    systemctl daemon-reload || true
    udevadm control --reload || true
    local nv
    nv="$(wifi_nvram_file)"
    grep -qsF "$MARKER" "$nv" && rm -f "$nv" && log "Removed $nv"
    [[ -d "$T1_BACKUP" ]] && log "Keeping the T1 firmware backup in $T1_BACKUP"
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
    # Remove every DKMS version of the Touch Bar driver and its /usr/src
    # copies (older script versions left version 0.1 around).
    local v
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        dkms remove -m "$TB_NAME" -v "$v" --all || true
    done < <(tb_dkms_versions)
    rm -rf "/usr/src/${TB_NAME}-"*
    remove_sxfp
    # davidjo's remove step runs a plain "dkms remove", which only covers the
    # running kernel; remove the audio driver from every kernel first.
    # (No "dkms status | grep -q" pipes in this script: with pipefail, grep -q
    # exiting early kills dkms with SIGPIPE and the test fails.)
    if [[ -n "$(dkms status -m snd_hda_macbookpro 2>/dev/null)" ]]; then
        dkms remove snd_hda_macbookpro/0.1 --all || true
    fi
    if [[ -x "$AUDIO_SYS_DIR/install.cirrus.driver.sh" ]]; then
        (cd "$AUDIO_SYS_DIR" && ./install.cirrus.driver.sh -r) || true
    fi
    # Also removes the touchbar/ clone and old audio copies that older
    # versions of this script left in /usr/local/src/mbp132-setup.
    rm -rf "$SRC_DIR"
    rebuild_initramfs
    uninstall_grub
    if user_has_our_xkb_options; then
        warn "Your KDE keyboard options are still set. Clear them in System Settings > Keyboard > Key Bindings."
    fi
    if has_usb 05ac 8600 && pacman -Q usbmuxd >/dev/null 2>&1; then
        warn "usbmuxd is still installed. Without the removed udev rule it can turn off the Touch Bar, camera and light sensor."
        warn "If nothing else needs it: sudo pacman -Rs usbmuxd"
    fi
    log "Done. Reboot to finish."
}

# -------------------------------------------------------------------- main --
while (( $# )); do
    case $1 in
        --iso)          OPT_ISO=1 ;;
        --fn-ctrl-swap) OPT_FNSWAP=1 ;;
        --windows-keys) OPT_WINKEYS=1 ;;
        --reset-keyboard) OPT_RESET_KBD=1 ;;
        --no-audio)     DO_AUDIO=0 ;;
        --no-touchbar)  DO_TB=0 ;;
        --no-sleep)     DO_SLEEP=0 ;;
        --no-wifi)      DO_WIFI=0 ;;
        --wifi-mac)     [[ $# -ge 2 ]] || die "--wifi-mac needs an address"; WIFI_MAC=$2; shift ;;
        --wifi-mac=*)   WIFI_MAC=${1#*=} ;;
        --wifi-country) [[ $# -ge 2 ]] || die "--wifi-country needs a country code"; WIFI_COUNTRY=$2; shift ;;
        --wifi-country=*) WIFI_COUNTRY=${1#*=} ;;
        --force)        FORCE=1 ;;
        --uninstall)    UNINSTALL=1 ;;
        --report)       REPORT=1 ;;
        -h|--help)      usage ;;
        *)              die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

if (( REPORT )); then report; exit 0; fi
preflight
if (( UNINSTALL )); then uninstall; exit 0; fi
[[ -n "$WIFI_MAC" ]] && validate_wifi_mac
[[ -n "$WIFI_COUNTRY" ]] && validate_wifi_country
check_vendored_drivers
[[ -f "$WIFI_NVRAM_TEMPLATE" ]] || die "Missing $WIFI_NVRAM_TEMPLATE. Run this script from a clone of the repository (see README.md)."

detect_hardware
if (( HAS_T1 )); then
    check_t1
elif (( DO_TB )); then
    log "No Touch Bar (T1) found; skipping the Touch Bar driver."
    DO_TB=0
fi
if (( DO_WIFI && !HAS_BCM43602 )); then
    log "No BCM43602 Wi-Fi found; skipping the Wi-Fi settings (other chips need none)."
    DO_WIFI=0
fi
if grub_in_use; then
    HAS_GRUB=1
else
    log "GRUB is not the boot loader here; skipping the boot menu entry."
fi

install_deps
(( DO_AUDIO )) && install_audio
(( DO_TB ))    && install_touchbar
reset_keyboard
install_keyboard
install_windows_keys
(( DO_SLEEP )) && install_sleep
(( DO_WIFI ))  && install_wifi
rebuild_initramfs
(( HAS_GRUB )) && install_grub

echo
log "All done. Reboot to apply."
cat <<'EOF'

After rebooting:
  - Touch Bar should light up; hold Fn for F1-F12.
  - Suspend: close the lid; press a key or the power button to wake (opening the lid does not).
  - AltGr (with --windows-keys): right Command or right Option, e.g. AltGr+Q = @ on Turkish Q.
  - After each kernel update, check that the drivers rebuilt:  dkms status
  - macOS gone from the GRUB menu, or it boots Linux again (after an NVRAM reset or a macOS reinstall)? Run this script again.
Tips:
  - Double or missed keystrokes: KDE System Settings > Accessibility >
    Keyboard Filters > Bounce keys (~40 ms).
  - Wi-Fi (MacBookPro13,2): 2.4 and 5 GHz incl. radar channels, 80 MHz max (the chip has no 160 MHz).
    Other BCM43602 models: 2.4 GHz only so far.
  - Never delete or reformat the EFI partition: EFI/APPLE/EMBEDDEDOS/ holds the Touch Bar firmware.
  - Something broken? Run  sudo ./mbp132-setup-cli.sh --report  and attach the file to an issue.
EOF
