# mbp132-setup

One script to make Linux usable on the **MacBook Pro 13" 2016 with Touch Bar (MacBookPro13,2)** on Arch-based distributions.

| Component | Status after running the script |
|---|---|
| Audio (speakers, mic) | ✅ via [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro) |
| Touch Bar (Esc, media keys, F1–F12 with Fn) | ✅ via a patched [iBridge driver](https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver) |
| Ambient light sensor | ✅ (apple-ib-als) |
| Suspend (lid close / idle / manual) | ✅ deep sleep, no instant wake-ups |
| USB-C ports after sleep | ✅ Thunderbolt driver is reloaded around sleep |
| Windows-style modifiers + AltGr (KDE) | ✅ optional, `--windows-keys` |
| Hibernation | ❌ hidden; it does not resume on this model |
| Wi-Fi (BCM43602), 2.4 GHz | ✅ stable link, power saving off, no shared placeholder MAC |
| Wi-Fi (BCM43602), 5 GHz | ❌ no calibration data for this board yet; use a USB adapter (e.g. MediaTek MT7921AU) |
| Touch ID | ❌ |

Tested on CachyOS, kernel 7.2.9, GRUB + mkinitcpio + systemd.

## Usage

```sh
git clone https://github.com/<you>/mbp132-setup.git
cd mbp132-setup
sudo ./mbp132-setup.sh            # add --iso for non-US keyboards
reboot
```

Options: `--iso`, `--fn-ctrl-swap`, `--windows-keys`, `--wifi-mac MAC`, `--no-audio`, `--no-touchbar`, `--no-sleep`, `--no-wifi`, `--force`, `--uninstall`. Run `--help` for details.

After every kernel update, run `dkms status` before rebooting: both drivers should show `installed` for the new kernel.

## What it fixes, and why

**Touch Bar driver**
- The build fails on 6.15+ kernels because `struct tb_touch` is used before it is defined. The script moves the definition.
- In `auto`/`display` mode the driver calls `usb_set_configuration()` inside its own probe and deadlocks, which hangs modprobe and boot. The script sets `tb_mode_param=keyboard`, which keeps the current USB configuration.
- `hid_sensor_hub` claims the second iBridge interface first, leaving the Touch Bar dark. The script blacklists it; `apple-ib-als` takes over the light sensor.

**Suspend**
- The Apple S3X NVMe and the Thunderbolt xHCI controllers fail to resume from `d3cold`, so d3cold is disabled for all PCI devices before each sleep.
- Instant wake-ups come from ACPI wake sources: the lid sensor `LID0`, the USB controllers `XHC1-3`, Wi-Fi `ARPT`, and the PCIe root ports `RP01/05/09/12`. These are disabled before each sleep; keyboard/trackpad wake (`SPIT`) stays on. Because the lid sensor can't wake it, open the lid and **press a key** to wake.
- The Thunderbolt driver's suspend/resume fails, and the USB-C ports' USB controllers vanish until reboot. The sleep hook unloads `thunderbolt` before sleep and loads it again after waking.

**Wi-Fi (BCM43602, board 0x157)**
- The `brcmfmac43602-pcie.txt` NVRAM files shared online were made for other boards (for example MacBookPro13,3, boardtype `0x61b`). On this board they make connecting fail, so the script moves any such file to `/var/lib/mbp132-setup/nvram-backup/`. Without one, the firmware uses built-in defaults: a good 2.4 GHz link and no 5 GHz band.
- Power saving makes the link slow and laggy; a NetworkManager dispatcher script turns it off.
- Without an NVRAM file the chip reports Broadcom's placeholder MAC `00:90:4c:0d:f4:3e`, identical on every machine. NetworkManager is set to use a stable per-network address instead, or the address you pass with `--wifi-mac` (macOS shows the real one with `ifconfig en0 | grep ether`).
- 5 GHz needs this board's calibration data. Apple's Boot Camp drivers don't contain it as text, and it isn't readable from the chip directly. Recording it from the Windows driver in a virtual machine is the remaining option.

**Keyboard (`--windows-keys`, KDE Plasma)**
- XKB options `altwin:swap_lalt_lwin,lv3:rwin_switch`. The left keys become Ctrl, Fn, Win, Alt (in Windows order), and right Command and right Option both act as AltGr. Swapping Alt/Win on *both* sides (`altwin:swap_alt_win`) removes AltGr, because right Option is Linux's AltGr on Mac keyboards. Ctrl+Alt as AltGr is Windows-only and not possible with XKB.
- It is applied to the user who ran `sudo`, and through `/etc/xdg/kxkbrc` as the default for other users.

## Files installed

```
/etc/modprobe.d/mbp132-touchbar.conf
/etc/modules-load.d/mbp132-touchbar.conf
/etc/modprobe.d/mbp132-applespi.conf        (only with --iso / --fn-ctrl-swap)
/etc/udev/rules.d/99-mbp132-sleep.rules
/usr/lib/systemd/system-sleep/mbp132-sleep-fix
/etc/systemd/sleep.conf.d/mbp132-no-hibernate.conf
/etc/xdg/kxkbrc                             (only with --windows-keys, if not already present)
/etc/NetworkManager/dispatcher.d/99-mbp132-wifi-powersave
/etc/NetworkManager/conf.d/mbp132-wifi.conf
/var/lib/mbp132-setup/nvram-backup/         (only if an NVRAM file had to be moved)
/usr/src/appleibridge-0.1                   (DKMS source)
/usr/local/src/mbp132-setup                 (cloned driver repositories)
```

## Credits

- Touch Bar / iBridge driver: cb22, roadrunner2, marc-git, F13-Kr1pt0n
- Audio driver: davidjo
- Background: [Dunedan/mbp-2016-linux](https://github.com/Dunedan/mbp-2016-linux), [issue #207](https://github.com/Dunedan/mbp-2016-linux/issues/207)
