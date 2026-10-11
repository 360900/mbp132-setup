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
  - `dkms.conf`: `PACKAGE_VERSION` bumped from `0.1` to `0.1.1` to mark our
    fork, so the setup script can replace any `0.1` copy from older script
    versions cleanly.

## snd_hda_macbookpro (Cirrus CS8409 audio)

- Upstream: https://github.com/davidjo/snd_hda_macbookpro, branch `master`
- Pinned commit: `89b22ff90b86468b186706861dd18663562defa7` (2026-09-06)
- License: GPL-2.0 (`LICENSE`)
- Local changes: none.

## Updating a driver

1. Pull the newer upstream code with
   `git subtree pull --prefix=drivers/<driver> <upstream-url> <branch> --squash`
   and re-pin `drivers/README.md` to the new commit.
2. Re-check that our local changes are still applied (for `apple-ibridge`:
   the `struct tb_touch` placement and `PACKAGE_VERSION`).
3. If `drivers/apple-ibridge` changed, bump `PACKAGE_VERSION` in its
   `dkms.conf` again.
4. Add a CHANGELOG entry.
5. Run `TESTING.md` on hardware before merging.
