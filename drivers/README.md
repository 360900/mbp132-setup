# Vendored drivers

The drivers are vendored with `git subtree --squash`, pinned to the commits
that were debugged on a MacBookPro13,2. Nothing is cloned from the network at
install time. Both upstream trees are GPL-2.0; their `LICENSE` files are kept
in place.

## apple-ibridge (Touch Bar)

- Upstream: https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver
  (from the roadrunner2 / marc-git / cb22 line), branch
  `touchbar-driver-hid-driver`
- Pinned commit: `ecfadc37538d1995ddd2383dd83a1be82fdfdf23` (2025-09-02)
- License: GPL-2.0 (`LICENSE`)
- Local changes:
  - `struct tb_touch` is now defined before `struct appletb_device`
    (`apple-ib-tb.c`). Kernels 6.15+ fail to build the original layout with
    "field has incomplete type". Applied from
    `patches/0001-apple-ib-tb-define-struct-tb_touch-before-struct-app.patch`.
  - `apple-ibridge.c` binds as a `platform_driver` (ACPI match `APP7777`)
    instead of an `acpi_driver`. Linux 7.3 removed `struct acpi_driver`, so
    the original fails to build there. Applied from
    `patches/0002-apple-ibridge-bind-as-a-platform-driver-for-Linux-7.3.patch`.
  - `dkms.conf`: `PACKAGE_VERSION` bumped from `0.1` to `0.1.2` to mark our
    fork (0.1.1: tb_touch fix; 0.1.2: platform driver), so the setup script
    can replace older copies cleanly.

## snd_hda_macbookpro (Cirrus CS8409 audio)

- Upstream: https://github.com/davidjo/snd_hda_macbookpro, branch `master`
- Pinned commit: `89b22ff90b86468b186706861dd18663562defa7` (2026-09-06)
- License: GPL-2.0 (`LICENSE`)
- Local changes:
  - The resume handler (`patch_cirrus/cirrus_apple.h`) runs the full Apple
    codec, CS42L83 and speaker-amp setup again after a system sleep, and
    restores the subsystem id and pin configs the Mac's firmware wrote at
    boot. Upstream only re-ran the generic HDA init, so the speakers stayed
    silent after suspend until reboot. Two fields (`pm_nb`, `system_slept`)
    are added to `struct cs8409_spec` in `patch_cs8409.h.diff`. Applied from
    `patches/0003-snd_hda_macbookpro-set-up-codec-and-amps-again-after-sleep.patch`.

## Updating a driver

1. Pull the newer upstream code with
   `git subtree pull --prefix=drivers/<driver> <upstream-url> <branch> --squash`
   and re-pin `drivers/README.md` to the new commit.
2. Re-check that our local changes are still applied (for `apple-ibridge`:
   the `struct tb_touch` placement and `PACKAGE_VERSION`; for
   `snd_hda_macbookpro`: the resume setup in `cirrus_apple.h`).
3. If `drivers/apple-ibridge` changed, bump `PACKAGE_VERSION` in its
   `dkms.conf` again.
4. Add a CHANGELOG entry.
5. Run `TESTING.md` on hardware before merging.
