# Hardware test checklist

Run this on a MacBookPro13,2 after any change to the script or to `drivers/`.

## Before the first run on a machine set up by hand

Remove anything from earlier manual fixes (other guides or previous experiments) that does the same job. Otherwise settings get applied twice. Typical leftovers:

- `/usr/lib/systemd/system-sleep/*` sleep hooks
- `/etc/udev/rules.d/*sleep*.rules`
- `/etc/modprobe.d/*` files with `apple_ibridge`, `hid_sensor_hub` or `applespi` options
- `/etc/modules-load.d/*touchbar*`
- `/etc/systemd/sleep.conf.d/*`
- `/etc/NetworkManager/dispatcher.d/*powersave*`

Also run `dkms status` and remove old `appleibridge` versions with `sudo dkms remove appleibridge/<version> --all`.

## Install

```sh
git clone <this repo> && cd <repo>
sudo ./mbp132-setup.sh [--iso] [--windows-keys] [--wifi-mac aa:bb:cc:dd:ee:ff]
reboot
```

## Checks

1. `dkms status`: `appleibridge` and `snd_hda_macbookpro` show `installed` for every kernel, including LTS.
2. Touch Bar:
   - It lights up.
   - Esc works.
   - Holding Fn shows F1–F12.
   - The brightness, volume and keyboard-backlight keys work.
   - `/var/lib/mbp132-setup/t1-firmware/combined.memboot` exists (the T1 firmware backup).
   - With usbmuxd installed (the script installs it; check `pacman -Q usbmuxd`), after a reboot the Touch Bar still lights up and this prints `1`: `cat "$(dirname "$(grep -l 8600 /sys/bus/usb/devices/*/idProduct)")/bConfigurationValue"`.
3. Audio: speakers, microphone, headphone jack.
   - Run this with codec power saving on: `cat /sys/module/snd_hda_intel/parameters/power_save` must not be `0`. Remove any manual `snd_hda_intel power_save=0` option from `/etc/modprobe.d/` first, and reboot.
   - Play sound again after 2 minutes of silence; it must still work, without noise.
   - After a suspend, the speakers play without a reboot, and `journalctl -k -b | grep 'setting up codec and amps again'` shows one line per resume.
   - Volume: at 5-10% the speakers are quiet but audible; `amixer -c0 sget PCM` shows -38 dB at 5% and -36 dB at 10%; 0% is silent.
4. Suspend, three times:
   - Close the lid, wait 30 s, open it and press a key. It must not wake by itself.
   - Check with `journalctl -b -o short-unix | grep -E "PM: suspend (entry|exit)"`.
   - After a suspend, `grep enabled /proc/acpi/wakeup` lists no `LID*`, `XHC*`, `ARPT` or `RP*` entry, and `SPIT` is enabled.
5. USB-C after sleep: a USB stick in a USB-C port is detected without replugging.
6. Wi-Fi:
   - It connects at 2.4 GHz and at 5 GHz, on a normal channel (36-48) and on a radar channel (52-64 or 100-140).
   - At 5 GHz `iw dev wlan0 info` shows `width: 80 MHz` (if the router uses 80 MHz or more).
   - `iw phy | grep -E '\[(52|100)\]'` shows `radar detection` without `no IR` (for Turkey: `--wifi-country` default `TR/1`).
   - `iw dev wlan0 get power_save` shows `off`.
   - `ethtool -P wlan0` shows the `--wifi-mac` address (or the made-up one), not `00:90:4c:0d:f4:3e`.
   - `/usr/lib/firmware/brcm/` holds only `brcmfmac43602-pcie.Apple Inc.-MacBookPro13,2.txt` (ours) and package-owned files.
7. Keyboard (if used): with `--iso`, the keys next to left Shift and the one below Esc are correct. With `--windows-keys`, AltGr works on right Command and right Option.
8. Re-run the script: no errors and nothing duplicated.
9. Kernel update: after `pacman -Syu` installs a new kernel, both drivers rebuild for it (`dkms status`) before rebooting.
10. `sudo ./mbp132-setup.sh --uninstall`:
    - Every installed file is gone and any moved NVRAM file is restored.
    - It reboots cleanly.
    - Then reinstall.
