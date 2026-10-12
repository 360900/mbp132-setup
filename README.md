# mbp132-setup

One script to make Linux usable on the **MacBook Pro 13" 2016 with Touch Bar (MacBookPro13,2)** on Arch-based distributions.

| Component | Status after running the script |
|---|---|
| Audio (speakers, mic) | ✅ via [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro) |
| Touch Bar (Esc, media keys, F1–F12 with Fn) | ✅ via a patched [iBridge driver](https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver) |
| Ambient light sensor | ✅ (apple-ib-als) |
| Suspend (lid close / idle / manual) | ✅ deep sleep, no instant wake-ups |
| Hibernation | ❌ hidden; I could not get it to work (though I didn't work on it too much since I got suspend to work |
| Wi-Fi (BCM43602) | ❌ there's no working linux driver. I'm working on one |
| Touch ID | ❌ I didn't work on it |

Tested on CachyOS, kernel 7.2.9, GRUB + mkinitcpio + systemd.

## Usage

```sh
git clone https://github.com/360900/mbp132-setup.git
cd mbp132-setup
sudo ./mbp132-setup.sh            # add --iso for non-US keyboards. necessary.
reboot
```

Options: `--iso`, `--fn-ctrl-swap`, `--no-audio`, `--no-touchbar`, `--no-sleep`, `--force`, `--uninstall`. Run `--help` for details.

After every kernel update, run `dkms status` before rebooting: both drivers should show `installed` for the new kernel.

## It fixes the following:

**Touch Bar driver**
- The build fails on 6.15+ kernels because `struct tb_touch` is used before it is defined. The script moves the definition.
- In `auto`/`display` mode the driver calls `usb_set_configuration()` inside its own probe and deadlocks, which hangs modprobe and boot. The script sets `tb_mode_param=keyboard`, which keeps the current USB configuration.
- `hid_sensor_hub` claims the second iBridge interface first, leaving the Touch Bar dark. The script blacklists it; `apple-ib-als` takes over the light sensor.

**Suspend**
- The Apple S3X NVMe and the Thunderbolt xHCI controllers fail to resume from `d3cold`, so d3cold is disabled for all PCI devices before each sleep.
- Instant wake-ups come from ACPI wake sources: the lid sensor `LID0`, the USB controllers `XHC1-3`, Wi-Fi `ARPT`, and the PCIe root ports `RP01/05/09/12`. These are disabled before each sleep; keyboard/trackpad wake (`SPIT`) stays on. Because the lid sensor can't wake it, open the lid and **press a key** to wake.

## Files installed

```
/etc/modprobe.d/mbp132-touchbar.conf
/etc/modules-load.d/mbp132-touchbar.conf
/etc/modprobe.d/mbp132-applespi.conf        (only with --iso / --fn-ctrl-swap)
/etc/udev/rules.d/99-mbp132-sleep.rules
/usr/lib/systemd/system-sleep/mbp132-sleep-fix
/etc/systemd/sleep.conf.d/mbp132-no-hibernate.conf
/usr/src/appleibridge-0.1                   (DKMS source)
/usr/local/src/mbp132-setup                 (cloned driver repositories)
```

## Credits

- Touch Bar / iBridge driver: cb22, roadrunner2, marc-git, F13-Kr1pt0n
- Audio driver: davidjo
- Background: [Dunedan/mbp-2016-linux](https://github.com/Dunedan/mbp-2016-linux), [issue #207](https://github.com/Dunedan/mbp-2016-linux/issues/207)
