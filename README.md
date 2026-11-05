# mbp132-setup

One script to make Linux usable on the **MacBook Pro 13" 2016 with Touch Bar (MacBookPro13,2)** on Arch-based distributions.

| Component | Status after running the script |
|---|---|
| Audio (speakers, mic) | ✅ via [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro), set up again after sleep |
| Volume | ✅ even loudness steps, audible from 5% |
| Touch Bar (Esc, media keys, F1–F12 with Fn) | ✅ via a patched [iBridge driver](https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver) |
| Ambient light sensor | ✅ (apple-ib-als) |
| Suspend (lid close / idle / manual) | ✅ s2idle on the 13,2 (deep sleep breaks Wi-Fi), deep on other models |
| USB-C ports after sleep | ✅ Thunderbolt driver is reloaded around sleep |
| Windows-style modifiers + AltGr (KDE) | ✅ optional, `--windows-keys` |
| Hibernation | ❌ hidden; it does not resume on this model |
| Wi-Fi (BCM43602), 2.4 GHz | ✅ calibration file, power saving off |
| Wi-Fi (BCM43602), 5 GHz | ✅ on the 13,2: all channels your country allows, radar channels included, 80 MHz 802.11ac (the chip has no 160 MHz). Other models: not yet |
| Touch ID | ❌ |

Tested on CachyOS, kernel 7.2.9, GRUB + mkinitcpio + systemd.

## Usage

```sh
git clone https://github.com/360900/mbp132-setup.git
cd mbp132-setup
sudo ./mbp132-setup.sh            # add --iso for non-US keyboards
reboot
```

Both drivers are vendored in this repository (`drivers/`); the script installs them from the local tree and clones nothing from GitHub. See [Vendored drivers](#vendored-drivers).

Options: `--iso`, `--fn-ctrl-swap`, `--windows-keys`, `--wifi-mac MAC`, `--wifi-country CC[/REV]`, `--no-audio`, `--no-touchbar`, `--no-sleep`, `--no-wifi`, `--force`, `--uninstall`, `--report`. Run `--help` for details.

Other 2016-2017 MacBook Pros (13,1, 13,3, 14,1, 14,2, 14,3) are supported but untested. The Touch Bar and Wi-Fi parts are installed only where that hardware exists. To help, run `sudo ./mbp132-setup.sh --report` (works on any model, changes nothing) and open a [test report](https://github.com/360900/mbp132-setup/issues/new?template=test-report.yml).

After every kernel update, run `dkms status` before rebooting: both drivers should show `installed` for the new kernel.

## What it fixes, and why

**Touch Bar driver**
- The build fails on 6.15+ kernels because `struct tb_touch` is used before it is defined. The script moves the definition.
- In `auto`/`display` mode the driver calls `usb_set_configuration()` inside its own probe and deadlocks, which hangs modprobe and boot. The script sets `tb_mode_param=keyboard`, which keeps the current USB configuration.
- `hid_sensor_hub` claims the second iBridge interface first, leaving the Touch Bar dark. The script blacklists it; `apple-ib-als` takes over the light sensor.
- usbmuxd up to 1.1.1 (the version Arch ships) switches the iBridge to USB configuration 0, which turns off the Touch Bar, camera and light sensor. A udev rule switches it back to 1, so the script installs usbmuxd (needed for iPhone USB tethering) along with it.
- USB keeps power in s2idle, so waking calls the driver's `resume`, which it did not have, and the Touch Bar stayed dark. The vendored driver now has one.
- At every power-on the Mac loads the T1 chip's firmware from `EFI/APPLE/EMBEDDEDOS/` on the EFI partition. Without it the T1 shows up as `05ac:1281` (recovery mode) and the Touch Bar, camera, Touch ID and light sensor stop working; only reinstalling macOS restores it. The script backs that folder up to `/var/lib/mbp132-setup/t1-firmware/`. **Never delete or reformat the EFI partition.**

**Audio**
- After suspend to RAM the speaker amps (programmed over the codec's I2C bus) have lost their setup, and sometimes the codec has too, so the speakers stay silent until reboot. The vendored driver now runs its full codec and amp setup again on the first resume after a system sleep (a PM notifier flags the sleep; runtime power-saving resumes are left alone).
- The driver has no hardware volume, so the slider drives alsa-lib's `PCM` software volume (-51..0 dB) through PipeWire's cubic curve: everything below about 20% is under -42 dB and inaudible on these speakers. The script gives the software volume a -40..0 dB range and tells PipeWire it spans -80..0 dB (an ACP `DecibelFix` in a profile set used only for the built-in card), which halves the dB of the cubic curve: 5% is -39 dB, 10% -30 dB, 20% -21 dB, 50% -9 dB, 0% silent. Plain even dB steps (tried first) felt exponential. `alsa-restore.service` empties `/var/lib/alsa/cardN.conf.d/` at every boot, so `mbp132-volume.service` writes the files after it.

**Suspend**
- The Apple S3X NVMe and the Thunderbolt xHCI controllers fail to resume from `d3cold`, so d3cold is disabled for all PCI devices before each sleep.
- On the 13,2, deep sleep (S3) on battery leaves Wi-Fi rejecting every join until reboot, and deep sleep on the charger often ends within a second. The script sets `MemorySleepMode=s2idle` there. See [`NOTES.md`](NOTES.md#wi-fi-after-sleep).
- Instant wake-ups come from ACPI wake sources: the lid sensor `LID0`, the USB controllers `XHC*`, Wi-Fi `ARPT`, and the PCIe root ports `RP*` (`RP01/05/09/12` on the 13,2; the names differ per model). These are disabled before each sleep; keyboard/trackpad wake (`SPIT`) stays on. Opening the lid still wakes the 13,2; if it does not, press a key.
- The Thunderbolt driver's suspend/resume fails, and the USB-C ports' USB controllers vanish until reboot. The sleep hook unloads `thunderbolt` before sleep and loads it again after waking.

**Wi-Fi (BCM43602, board 0x157)**
- Without a calibration (NVRAM) file the firmware uses built-in defaults: 2.4 GHz only, and Broadcom's placeholder MAC `00:90:4c:0d:f4:3e`, identical on every machine.
- On the 13,2 the script installs [firmware/brcmfmac43602-pcie.txt.in](firmware/README.md) as `brcmfmac43602-pcie.Apple Inc.-MacBookPro13,2.txt`, with your MAC (`--wifi-mac`; macOS shows it with `ifconfig en0 | grep ether`, otherwise a stable made-up one) and your country. Measured on one 13,2: 2.4 GHz download 1.4-2.0 → 6.5-7.0 MB/s; 5 GHz 80 MHz 802.11ac, link rate up to 702 Mbit/s, ~40 MB/s download.
- The country revision decides which 5 GHz channels work. For Turkey, revision 0 leaves 100-140 off and makes 52-64 passive, so joining a router on a radar channel fails at once (NetworkManager then asks for the password again, which is fine). `TR/1` allows 52-140. The script picks the system's regulatory country and a known-better revision (`--wifi-country CC/REV` overrides). brcmfmac keeps the file's country when it matches the system's.
- Other `brcmfmac43602-pcie.txt` files shared online (made for other boards) make connecting fail, so the script moves them to `/var/lib/mbp132-setup/nvram-backup/`.
- Power saving makes the link slow and laggy; a NetworkManager dispatcher script turns it off. NetworkManager uses a stable per-network MAC, or the address given with `--wifi-mac`.

**Keyboard (`--windows-keys`, KDE Plasma)**
- XKB options `altwin:swap_lalt_lwin,lv3:rwin_switch`. The left keys become Ctrl, Fn, Win, Alt (in Windows order), and right Command and right Option both act as AltGr. Swapping Alt/Win on *both* sides (`altwin:swap_alt_win`) removes AltGr, because right Option is Linux's AltGr on Mac keyboards. Ctrl+Alt as AltGr is Windows-only and not possible with XKB.
- It is applied to the user who ran `sudo`, and through `/etc/xdg/kxkbrc` as the default for other users.

## Files installed

```
/etc/modprobe.d/mbp132-touchbar.conf
/etc/modules-load.d/mbp132-touchbar.conf
/etc/udev/rules.d/40-mbp132-ibridge.rules
/etc/modprobe.d/mbp132-applespi.conf        (only with --iso / --fn-ctrl-swap)
/etc/udev/rules.d/99-mbp132-sleep.rules
/usr/lib/systemd/system-sleep/mbp132-sleep-fix
/etc/systemd/sleep.conf.d/mbp132-no-hibernate.conf
/etc/systemd/sleep.conf.d/mbp132-s2idle.conf (13,2 only)
/etc/xdg/kxkbrc                             (only with --windows-keys, if not already present)
/etc/NetworkManager/dispatcher.d/99-mbp132-wifi-powersave
/etc/NetworkManager/conf.d/mbp132-wifi.conf
/usr/lib/firmware/brcm/brcmfmac43602-pcie.Apple Inc.-MacBookPro13,2.txt   (Wi-Fi calibration, 13,2 only)
/etc/systemd/system/mbp132-volume.service + /usr/local/libexec/mbp132-volume
                                         (writes the two files below at every boot)
/var/lib/alsa/cardN.conf.d/50-mbp132-volume.conf                         (volume range)
/run/mbp132-setup/acp-default.conf                                       (volume curve)
/etc/udev/rules.d/90-mbp132-volume.rules (points the built-in card at that curve)
/var/lib/mbp132-setup/nvram-backup/         (only if an NVRAM file had to be moved)
/var/lib/mbp132-setup/t1-firmware/          (backup of EFI/APPLE/EMBEDDEDOS/; kept on --uninstall)
/usr/src/appleibridge-0.1.3                   (DKMS source, copied from drivers/apple-ibridge)
/usr/local/src/mbp132-setup/snd_hda_macbookpro (copied from drivers/snd_hda_macbookpro)
```

## Vendored drivers

Both drivers are committed to this repository under `drivers/` (via `git subtree`), pinned to a tested upstream commit. Nothing is cloned or downloaded from GitHub during install.

| Driver | Upstream | Pinned commit | Local changes |
|---|---|---|---|
| `apple-ibridge` (Touch Bar, ALS) | [F13-Kr1pt0n/macbook-pro-touchbar-driver](https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver), branch `touchbar-driver-hid-driver` | `ecfadc3` (2025-09-02) | `struct tb_touch` build fix, platform-driver port for Linux 7.3 and s2idle resume ([`patches/`](patches)), `PACKAGE_VERSION` bumped to `0.1.3` to mark the fork |
| `snd_hda_macbookpro` (Cirrus CS8409 audio) | [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro), `master` | `89b22ff` (2026-09-06) | none |

Both are GPL-2.0 upstream; their `LICENSE` files are kept in `drivers/*/`.

One network dependency remains: building the audio driver for a **new** kernel downloads the matching kernel source from `cdn.kernel.org`, because Arch-based distributions ship no kernel-source package. The script installs `wget` and `patch` for this. The vendored Touch Bar driver builds fully offline.

Pins, local changes and the update procedure are documented in [`drivers/README.md`](drivers/README.md). The reasoning behind every fix is in [`NOTES.md`](NOTES.md); how to verify a machine after installing is in [`TESTING.md`](TESTING.md).

## Credits

- Touch Bar / iBridge driver: cb22, roadrunner2, marc-git, F13-Kr1pt0n (GPL-2.0)
- Audio driver: davidjo (GPL-2.0)
- Background: [Dunedan/mbp-2016-linux](https://github.com/Dunedan/mbp-2016-linux), [issue #207](https://github.com/Dunedan/mbp-2016-linux/issues/207)
- The setup script and documentation are GPL-3.0; see [LICENSE](LICENSE). The vendored drivers under `drivers/` keep their own GPL-2.0 licenses.
