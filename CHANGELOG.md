# Changelog

## Unreleased

**Not yet re-tested on hardware.** The self-contained rework (vendored drivers, no clone at install) has not been run on a MacBookPro13,2 since; follow [TESTING.md](TESTING.md) to verify.

### Added
- Vendored `apple-ibridge` (F13-Kr1pt0n, branch `touchbar-driver-hid-driver`, pinned `ecfadc3`, 2025-09-02) and `snd_hda_macbookpro` (davidjo, `master`, pinned `89b22ff`, 2026-09-06) under `drivers/`; installs no longer clone from GitHub.
- CI: lint (shellcheck, `bash -n`, Python compile check) and DKMS builds of the vendored Touch Bar driver against Arch, CachyOS and Manjaro kernel packages.
- `--report`: writes a hardware and driver report for bug reports on any model, with MAC addresses, serial numbers, hostname and user name masked.
- Issue template for test reports.
- Support for the other 2016-2017 MacBook Pros (13,1, 13,3, 14,1, 14,2, 14,3), untested. The Touch Bar driver and Wi-Fi settings are installed only if the T1 chip or a BCM43602 is present.
- udev rule that switches the iBridge back to USB configuration 1 after usbmuxd <= 1.1.1 sets it to 0.
- `usbmuxd` is installed as a dependency (iPhone USB tethering), except on T1 models with `--no-touchbar`, where the udev rule above is not written. Verified on the MacBookPro13,2: with usbmuxd 1.1.1-4.1 and the rule, the Touch Bar stays lit and `bConfigurationValue` is `1` after reboot (2026-11-01).
- Backup of the T1 firmware (`EFI/APPLE/EMBEDDEDOS/`) to `/var/lib/mbp132-setup/t1-firmware/`; a T1 in recovery mode (`05ac:1281`) is reported and the Touch Bar driver skipped.
- Hardware notes (`NOTES.md`), test checklist (`TESTING.md`), per-driver documentation (`drivers/README.md`) and the `bcmprobe.py` diagnostics tool.

### Changed
- `mbp132-setup.sh` installs drivers from the vendored tree: the Touch Bar driver is copied to `/usr/src/appleibridge-<version>` and rebuilt through DKMS on every run; the audio driver is copied to `/usr/local/src/mbp132-setup` with a fingerprint file so unchanged installs are skipped. The old clone-based flow was removed.
- The sleep hook disables wake sources by kind (`LID*`, `XHC*`, `ARPT`, `RP*`) instead of a fixed 13,2 list.
- Applied the `struct tb_touch` build fix to the vendored driver as a committed patch and bumped `PACKAGE_VERSION` to `0.1.1` to mark the fork.

### Fixed
- Touch Bar driver failed to build on Linux 7.3 (`struct acpi_driver` was removed). `apple-ibridge` now binds as a platform driver to the `APP7777` device the ACPI core creates; `PACKAGE_VERSION` bumped to `0.1.2`. Found on the MacBookPro13,2 with linux-cachyos 7.3.1 (2026-11-01).
- `tb_dkms_versions()` now also matches DKMS versions in the `added` (not yet built) state, so they are removed together with their stale `/usr/src` copies instead of staying registered.
- Driver copies under `/usr/src` and `/usr/local/src` are chowned to `root:root` instead of keeping the invoking user's ownership (root builds and runs that code later).
- A stale `/usr/src/snd_hda_macbookpro-0.1` symlink left by a manual install of davidjo's script is replaced before the audio install, so DKMS builds from the system copy, not the user's old clone.
- The audio driver is built and installed for every installed kernel, not only the running one.
- `--uninstall` removes the audio driver from every kernel. davidjo's remove step runs a plain `dkms remove`, which DKMS 3.4 applies to the running kernel only; the LTS module stayed in `updates/dkms` and DKMS was left with a `broken` entry once the source was deleted. Found on the MacBookPro13,2 (2026-11-01).
- `dkms status | grep -q` tests failed at random under `set -o pipefail`: `grep -q` exits at the first match, `dkms status` then dies with SIGPIPE (141) and the pipeline counts as false. This made the fix above a no-op whenever the driver was installed for two kernels, and could make the "audio unchanged; skipping" check rebuild for nothing. The tests now read the captured output instead. Found on the MacBookPro13,2 (2026-11-01).
- CI: the Manjaro job initializes the pacman keyring and package database before searching for kernel header packages, and on failure prints every DKMS `make.log`.
