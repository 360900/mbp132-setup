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
3. Audio: speakers, microphone, headphone jack.
4. Suspend, three times:
   - Close the lid, wait 30 s, open it and press a key. It must not wake by itself.
   - Check with `journalctl -b -o short-unix | grep -E "PM: suspend (entry|exit)"`.
5. USB-C after sleep: a USB stick in a USB-C port is detected without replugging.
6. Wi-Fi:
   - It connects at 2.4 GHz.
   - `iw dev wlan0 get power_save` shows `off`.
   - `ip link show wlan0` does not show `00:90:4c:0d:f4:3e` (with `--wifi-mac`, it shows that address).
   - No `brcmfmac43602-pcie*.txt` remains in `/usr/lib/firmware/brcm/` unless a package owns it.
7. Keyboard (if used): with `--iso`, the keys next to left Shift and the one below Esc are correct. With `--windows-keys`, AltGr works on right Command and right Option.
8. Re-run the script: no errors and nothing duplicated.
9. Kernel update: after `pacman -Syu` installs a new kernel, both drivers rebuild for it (`dkms status`) before rebooting.
10. `sudo ./mbp132-setup.sh --uninstall`:
    - Every installed file is gone and any moved NVRAM file is restored.
    - It reboots cleanly.
    - Then reinstall.
