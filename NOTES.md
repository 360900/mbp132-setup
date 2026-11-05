# Hardware notes: MacBookPro13,2

Findings behind `mbp132-setup.sh`, from testing on one MacBook Pro 13" 2016 with Touch Bar and four Thunderbolt 3 ports (MacBookPro13,2, Core i5).

Test system: CachyOS, kernel 7.3.1 (LTS 6.18 also installed), GRUB, mkinitcpio with the systemd hook, btrfs, KDE Plasma (Wayland).

## Touch Bar (iBridge)

- Driver: `apple-ibridge`, `apple-ib-tb`, `apple-ib-als`. Source: F13-Kr1pt0n/macbook-pro-touchbar-driver, branch `touchbar-driver-hid-driver`, from the roadrunner2 / marc-git / cb22 line.
- **Build fix:** `struct appletb_device` embeds `struct tb_touch`, but `struct tb_touch` is defined further down. On 6.15+ kernels the build fails with "field has incomplete type". The fix moves the definition up.
- **Hang fix:** in `auto` and `display` modes the driver calls `usb_set_configuration()` from inside its own probe and deadlocks, which hangs `modprobe` and boot. `options apple_ibridge tb_mode_param=keyboard` keeps the current USB configuration and avoids this.
- **Dark Touch Bar fix:** `hid_sensor_hub` claims the second iBridge HID interface first, so the Touch Bar stays dark. Blacklisting it fixes this; `apple-ib-als` takes over the ambient light sensor.

## Audio (Cirrus CS8409)

- Driver: davidjo/snd_hda_macbookpro. It builds a patched `snd-hda-codec-cs8409` through DKMS.
- The DKMS `PRE_BUILD` step runs `install.cirrus.driver.sh -k <kernel> --dkms`. For each new kernel this downloads the matching kernel source from `cdn.kernel.org`, because Arch has no kernel-source package. Builds therefore need internet when the kernel updates.
- `dkms.sh` symlinks `/usr/src/snd_hda_macbookpro-0.1` to the directory it runs from. That directory must stay where it is (a system path, not a user's clone).

## Suspend / resume

- The 13,2 uses `s2idle`, because `deep` (S3) breaks Wi-Fi (see [Wi-Fi after sleep](#wi-fi-after-sleep)). Set with `MemorySleepMode=s2idle` in `sleep.conf.d`, so no boot option is needed.
- `s2idle` once broke the Touch Bar and audio. With the current drivers audio is fine, and the Touch Bar needed a `.resume` handler (`patches/0004`).
- **Instant wake-ups:** these come from the ACPI wake sources `LID0`, `XHC1`–`XHC3`, `ARPT` (Wi-Fi) and the PCIe root ports `RP01/05/09/12`. Disable them before each sleep, but keep `SPIT` (keyboard and trackpad) enabled. Opening the lid still wakes the machine with `LID0` disabled, in both sleep modes.
- **d3cold:** keep every PCI device out of `d3cold`. The Apple S3X NVMe (`106b:2003`) and the Thunderbolt xHCI controllers fail to resume from it.
- **Thunderbolt:** suspend/resume of the `thunderbolt` driver fails, and the USB-C ports' USB controllers disappear until reboot. Unload the module before sleep and load it after waking.
- **Hibernation:** resume fails with a black screen, so it is disabled with `AllowHibernation=no`, `AllowSuspendThenHibernate=no` and `AllowHybridSleep=no`.
- Reference: Dunedan/mbp-2016-linux issue #207.

## Keyboard

- `applespi iso_layout=1` fixes the swapped keys on ISO keyboards.
- `applespi fnremap=1` swaps Fn and left Ctrl.
- **Windows-style modifiers:** the XKB options `altwin:swap_lalt_lwin,lv3:rwin_switch` give Windows-order modifiers and keep AltGr. AltGr is on right Option, plus right Command.
  - `altwin:swap_alt_win` swaps both sides and removes AltGr.
  - Ctrl+Alt as AltGr is not possible with XKB.
- Double or missed keystrokes (butterfly keyboard) are fixed by KDE Accessibility > Keyboard Filters > Bounce keys at about 40 ms.

## Wi-Fi: BCM43602

- **Identity:** PCI `14e4:43ba`, subsystem `106b:0157`, boardtype `0x157`, boardrev `0x1108`, chiprev 2.
- **Firmware:** `brcmfmac43602-pcie.bin` 7.35.177.61 (2015), from linux-firmware.

| Setup | Result |
|---|---|
| No NVRAM file | Good 2.4 GHz link (1.4-2.0 MB/s), no 5 GHz band (`WLC_GET_BANDLIST`). The MAC is Broadcom's placeholder `00:90:4c:0d:f4:3e`. |
| Bugzilla 193121 attachment 290569 + comment 97, real MAC, `ccode=TR regrev=1` (shipped as `firmware/brcmfmac43602-pcie.txt.in`) | **Best result** (2026-11-01, kernel 7.3.1). 2.4 GHz: -43 dBm instead of -54, 6.5-7.0 MB/s. 5 GHz: ch 40 and radar ch 56, 80 MHz VHT, link rate up to 702 Mbit/s, ~40 MB/s from one server. |
| Same with `ccode=00` or `X3/245` (the SROM's value, not in this firmware's table) | The firmware falls back to the system country at revision 0. For TR/0: 52-64 passive, every join there fails at once (status 16, NetworkManager then asks for the password); 100-140 off. |
| Same with the SROM's own `boardflags3=0xa000005` | Firmware crash ("Dongle setup failed"). |
| Own SROM decoded (signature 0x9999, rev 12) | Firmware crash; the decoder's rev-12 layout is wrong for some fields. |
| Other NVRAM files shared online (MikeRatcliffe gist; bug 193121, comment 81) | On 13,2: association timeouts or "ssid-not-found". |
| Power saving on | Slow, laggy link. It must be off. |

- **Country:** brcmfmac pushes the system's regulatory country to the firmware at revision 0, unless the firmware already has that country (from the NVRAM `ccode`), so the NVRAM's `regrev` survives only when `ccode` matches the system's country. The firmware's table (no `clm_blob` for 43602): `TR/0`: 36-48 normal, 52-64 radar+passive, 100-165 off. `TR/1`, `DE/0`, `GB/0`, `JP/0`, `X3/0`: 52-140 radar. `US/0` adds 149-165. Read and set with brcmfmac's nl80211 vendor dcmd (`country` and `per_chan_info` iovars).
- **Width:** the chip does 80 MHz at most. With a router on 160 MHz (36-64) it joined at 40 MHz on ch 40 (TR/0) but at 80 MHz on ch 56 (TR/1).
- Do not send `WLC_DOWN`/`WLC_UP` from user space: the firmware comes back with `vhtmode=0` (802.11n only) until brcmfmac is reloaded.

Ruled-out sources for the board's own calibration data:

- **macOS `AirPortBrcmNIC`:** a host-mode (NIC) driver with no dongle firmware to reuse. Its CLM data uses a 64-bit layout the dongle firmware can't use.
- **Boot Camp:**
  - `BroadcomWirelessWin8x64.exe` is a RAR self-extracting archive. Inside, `bcmwl63a.sys` (2016) runs the chip in BMAC mode with an embedded 43602 BMAC firmware.
  - It contains no NVRAM text, only `name=%x`-style format strings. Its INF matches `DEV_43BA` without a board-specific `SUBSYS_0157106B`.
  - The six driver versions on a Boot Camp Windows install are the same in this respect.
- **On-chip:** the ChipCommon shadow window (`0x800`–`0xFFF`) is almost blank and the FullMAC firmware finds no board data (hence the placeholder MAC). The external SPROM, read indirectly, holds a valid image: signature 0x9999, 1024 words, CRC OK, sromrev 12, boardtype 0x157, the real MAC, `ccode=X3 regrev=245`. Decoding it into NVRAM text still crashes the firmware.

The shipped file is a MacBookPro14,3's calibration, not this board's. Routes to the board's own:

- Fix the SROM decoder for the 0x9999 / rev-12 layout (the dump itself is valid, CRC OK, real MAC found).
- Record the NVRAM that the Windows driver writes to the chip, using a Windows VM with the card passed through over VFIO and a QEMU MMIO-write trace (the "sonals" method).

Never commit Apple or Broadcom files, or data extracted from them, to this repository.

## Wi-Fi after sleep

Measured on one 13,2, kernel 7.3.1, firmware 7.35.177.61, 2026-11-04 and 05.

**Failure:** after a bad sleep every join fails about 100 ms after the request: firmware `SET_SSID status=1`, `ASSOC-REJECT status_code=16`, no LINK event. The router still shows up in scans. 5 GHz always fails and 2.4 GHz often does. NetworkManager then asks for the password and can give up with `no-secrets`. Only a reboot clears it. The BSSID in the reject is often zero or the last network used, so it says nothing about which radio was tried.

| Sleep, lid closed unless noted | 5 GHz broken afterwards |
|---|---|
| `deep`, charger connected throughout | 0 of 7 |
| `deep`, battery throughout | 6 of 6 (some with the test hooks below) |
| `deep`, plugged in during sleep | 1 of 1 |
| `deep`, unplugged during sleep | Inconclusive, router on a radar channel |
| `deep` that bounces, charger, lid open | 5 of 5 |
| `s2idle`, battery | 0 of 2, rejoined in 3-4 s, 0 rejects |
| Windows on this Mac, `S3`, battery | 0 of 3 |

Not tested with `s2idle`: charger, 2.4 GHz, USB-C after waking, long sleeps, battery drain. Failure cause unknown: the state seems to be outside the card, or the firmware handles something the platform does badly.

**Bounces:** on the charger, `deep` often enters and leaves S3 within about 1 ms (2-6 of 8 per run), and charger presence was the only thing that changed the rate (battery: 0 of 9). Side, hub, full versus charging, `macsmc` drivers and Linux wake settings made no difference. Wake reason not found.

**Tried in `deep`, did not help:**

- Driver reload, wpa_supplicant restart, cfg80211 reload, PCI reset, ASPM off, `mpc=0`, pre-tuning the channel, enabling Bluetooth.
- Loading the driver 30 s after waking.
- Powering the card off before sleep (`RP12.ARPT.PDEN 1` plus runtime suspend of the root port, `RP12.BMIS` 0 to 7 and `EC.APWC` 0 show it ran). The card loses its BARs at wake; after a PCI rescan the failure was still there. `PDEN` set alone never runs the path: `APPD` is not reached.
- Linux settings: comparing charger and battery awake, only audio power saving and `EC.EACP` differ.

**Why firmware can't be swapped:** 7.35.177.61 is the newest full-offload image found, and the file `brcmfmac43602-pcie.ap.bin` is older and for access points. Windows and macOS both use host-mode drivers with `pci-bmac` images, which `brcmfmac` can't drive. macOS and Windows also carry separate `43602a2` images while linux-firmware's is labelled `43602a1`; PCI rev is 02, but that link is unverified. `broadcom-wl` 6.30.223.271 has no `43602` strings and was not tried.

**Other findings:**

- Without a reload around sleep, firmware commands time out after waking and scans return -5 (2 of 2). Hence `mbp132-wifi-reload`.
- `acpi_osi=!Darwin` kills the keyboard and trackpad at boot: `SPIT._CRS` returns a different buffer and `applespi` times out. It also logs ACPI errors in Thunderbolt setup. Do not use it.
- Router channels matter for testing: on radar ch 56 even a fresh boot failed 2 of 3 joins, on ch 40 and 48 it did not. This is separate from the failure above.
- Thunderbolt: `timeout resetting host router` on every `deep` resume, even with only a charger connected. Not seen after `s2idle`.

**Open:**

- `macsmc-ac` `online` goes stale if the charger changes during sleep; `EC.EACP` stays right. Seen in `deep`.
- NetworkManager's `no-secrets` give-up after repeated rejects.

Never leave the brcmfmac debug mask on across a sleep: one such sleep ended in a reboot.

## Not working / out of scope

- Touch ID.
- Hibernation (see above).
