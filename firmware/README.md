# BCM43602 calibration (NVRAM) template

`brcmfmac43602-pcie.txt.in` is the NVRAM text that `mbp132-setup.sh` installs as
`/usr/lib/firmware/brcm/brcmfmac43602-pcie.Apple Inc.-MacBookPro13,2.txt`.
The script fills in three values:

- `macaddr`: the address given with `--wifi-mac` (the Mac's real one), otherwise a
  stable locally administered address derived from `/etc/machine-id`.
  The firmware crashes without a `macaddr` line.
- `ccode` / `regrev`: the country and its revision in the firmware's built-in
  regulatory table (`--wifi-country CC[/REV]`, default: the system's regulatory
  country). The revision matters: for Turkey, `TR/0` leaves channels 100-140 off and
  52-64 passive (joining a router there fails at once), `TR/1` allows 52-140 as
  normal radar channels. `X3/245`, the value in the chip's own SROM, is not in the
  Linux firmware's table, so the firmware would fall back.

License: unknown. If you hold rights to this data and want it removed, open an issue.

Origin: attachment 290569 on kernel bugzilla 193121 (calibration captured from a
MacBookPro14,3 by Andy Holst), with the `swctrlmap_2g` fix from comment 97. It is
not this board's own calibration; decoding the chip's SROM (signature 0x9999,
rev 12) still crashes the firmware.

Measured on a MacBookPro13,2 (kernel 7.3.1, firmware 7.35.177.61): without an
NVRAM file only 2.4 GHz works, 1.4-2.0 MB/s. With this file and TR/1:
5 GHz on ch 40 and on the radar channel 56, 80 MHz, 802.11ac, link rate up to
702 Mbit/s, about 40 MB/s (320 Mbit/s) download from one server.
