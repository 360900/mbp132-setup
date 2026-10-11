# Changelog

## Unreleased

**Not yet re-tested on hardware.** The self-contained rework (vendored drivers, no clone at install) has not been run on a MacBookPro13,2 since; follow [TESTING.md](TESTING.md) to verify.

### Added
- Vendored `apple-ibridge` (F13-Kr1pt0n, branch `touchbar-driver-hid-driver`, pinned `ecfadc3`, 2025-09-02) and `snd_hda_macbookpro` (davidjo, `master`, pinned `89b22ff`, 2026-09-06) under `drivers/`; installs no longer clone from GitHub.
- CI: lint (shellcheck, `bash -n`, Python compile check) and DKMS builds of the vendored Touch Bar driver against Arch, CachyOS and Manjaro kernel packages.
- Hardware notes (`NOTES.md`), test checklist (`TESTING.md`), per-driver documentation (`drivers/README.md`) and the `bcmprobe.py` diagnostics tool.

### Changed
- `mbp132-setup.sh` installs drivers from the vendored tree: the Touch Bar driver is copied to `/usr/src/appleibridge-<version>` and rebuilt through DKMS on every run; the audio driver is copied to `/usr/local/src/mbp132-setup` with a fingerprint file so unchanged installs are skipped. The old clone-based flow was removed.
- Applied the `struct tb_touch` build fix to the vendored driver as a committed patch and bumped `PACKAGE_VERSION` to `0.1.1` to mark the fork.
