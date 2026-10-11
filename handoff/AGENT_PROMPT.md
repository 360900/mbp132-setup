# Task: make this repository self-contained and add the latest fixes

This repository holds `mbp132-setup.sh`, a Linux setup script for the MacBook Pro 13" 2016 with Touch Bar (MacBookPro13,2) on Arch-based distributions. Today the script clones two driver repositories from other people at install time. After this task, the repository must contain everything it needs. It must also be easy to maintain: pinned upstream code, documented local changes, and CI that catches kernel breakage.

Read `handoff/NOTES.md` before anything else. It records the hardware findings; treat it as ground truth.

## Hard rules

1. **No hardware, no root.** The test laptop is away for a week.
   - Do not run `mbp132-setup.sh`, except `--help`, or without sudo to see the "Run as root" error.
   - Never use `sudo`. Do not install DKMS modules or touch `/etc`, `/usr` or `/lib` on this computer.
   - Only run the static checks listed below. Never describe anything as tested on hardware.
2. **Don't change tested behaviour.** These parts were debugged on real hardware: the Touch Bar modprobe options, the sleep hook, the udev rule, the hibernation settings, and the keyboard/XKB handling. Change them only as listed under step 5.
   - The Wi-Fi section is new; keep it exactly as provided.
   - If you think something else is wrong, report it at the end instead of changing it.
3. **No other git repository at install time.** The only network access allowed during install is:
   - `pacman`;
   - the audio driver downloading the matching kernel source from `cdn.kernel.org` when it builds. It patches the kernel's own HDA driver, and Arch ships no kernel-source package. Document this exception in the README.
4. **No personal data and no Apple/Broadcom material in commits.**
   - Personal data means: MAC addresses (except Broadcom's placeholder `00:90:4c:0d:f4:3e`, which may appear), usernames, hostnames, home-directory paths.
   - Apple/Broadcom material means: Boot Camp drivers, macOS kexts, firmware, NVRAM files, and anything extracted from them.
   - Check `git diff --cached` before every commit.
5. **Licenses.** Both vendored drivers are GPL-2.0. Keep their LICENSE files and attribution.
6. **Ask, don't guess, on these two points:**
   - If the repository's current `mbp132-setup.sh` or `README.md` differs from the versions in `handoff/` by anything other than the Wi-Fi additions, show me the diff and ask before overwriting. I may have edited the repo copy.
   - If the repository has no LICENSE file, ask me which license to use.

## What's in `handoff/`

- `mbp132-setup.sh`, `README.md`: the newest versions. Compared with the repo copies, they add Wi-Fi handling (`--no-wifi`, `--wifi-mac`).
- `NOTES.md`, `TESTING.md`: the hardware notes and the hardware test checklist. Both go to the repository root.
- `tools/bcmprobe.py`: a read-only Wi-Fi diagnostics tool. It goes to `tools/`.
- `patches/0001-apple-ib-tb-define-struct-tb_touch-before-struct-app.patch`: the Touch Bar build fix.

## Steps

Work on a new branch `self-contained`. Make small, logical commits with imperative messages that say why.

### 1. Bring in the handoff files

- Copy the handoff files into place.
- In README, replace the `<you>` placeholder in the clone URL with the real `origin` URL (from `git remote -v`).
- Commit.

### 2. Vendor the drivers with git subtree, pinned to the commits tested on hardware

```sh
git fetch https://github.com/F13-Kr1pt0n/macbook-pro-touchbar-driver.git touchbar-driver-hid-driver
git subtree add --prefix=drivers/apple-ibridge ecfadc37538d1995ddd2383dd83a1be82fdfdf23 --squash
git fetch https://github.com/davidjo/snd_hda_macbookpro.git master
git subtree add --prefix=drivers/snd_hda_macbookpro 89b22ff90b86468b186706861dd18663562defa7 --squash
```

Use exactly those commits even if upstream has newer ones.

### 3. Apply the Touch Bar fix

```sh
git apply --directory=drivers/apple-ibridge handoff/patches/0001-*.patch
```

Commit with the patch's subject and body as the commit message. Then:

- In `drivers/apple-ibridge/dkms.conf`, set `PACKAGE_VERSION="0.1.1"` (this marks our fork). Leave everything else in that file unchanged.
- Commit.

### 4. Write `drivers/README.md`

For each driver, list:

- upstream URL, branch, pinned commit and its date;
- license;
- every local change, and why.

Add a "Updating a driver" section covering:

1. `git subtree pull --prefix=... <url> <branch> --squash`.
2. Re-check that our local changes are still applied.
3. Bump `PACKAGE_VERSION` if `drivers/apple-ibridge` changed.
4. Add a CHANGELOG entry.
5. Run TESTING.md on hardware before merging.

### 5. Script changes (the only allowed ones)

a. **Remove the cloning code.** Remove `TB_REPO`, `TB_BRANCH`, `AUDIO_REPO`, `git_sync()` and `patch_touchbar_source()`; the fix now lives in the vendored source. Drop `git` from the pacman dependencies if nothing else needs it. Keep `wget` and `patch`, which the audio driver uses.

b. **Find the vendored drivers.** Add:
   - `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
   - `DRIVERS_DIR="$SCRIPT_DIR/drivers"`

   In install mode only (not `--uninstall`, not `--help`), stop with a clear message if either of these is missing. This covers someone who downloaded only the script:
   - `drivers/apple-ibridge/dkms.conf`
   - `drivers/snd_hda_macbookpro/install.cirrus.driver.sh`

c. **Touch Bar:**
   - Read the version from `PACKAGE_VERSION` in the vendored `dkms.conf` instead of the hardcoded `TB_VER`.
   - Before installing, remove every installed DKMS version of `appleibridge`, plus any `/usr/src/appleibridge-*` directories, so that 0.1 from older script versions is replaced cleanly.
   - Copy the vendored directory to `/usr/src/appleibridge-<version>` with `cp -a`.
   - Then run `dkms add` and `dkms install` for each kernel, as now.
   - Keep the modprobe and modules-load files exactly as they are.

d. **Audio.** davidjo's `dkms.sh` symlinks `/usr/src/snd_hda_macbookpro-0.1` to the directory it runs from, and DKMS rebuilds from there on every kernel update. So it must run from a stable system copy, never from the user's clone.
   - Copy the vendored directory to `/usr/local/src/mbp132-setup/snd_hda_macbookpro`.
   - Record a fingerprint of the vendored tree, e.g. `sha256sum` over the sorted file list and contents, in `/usr/local/src/mbp132-setup/snd_hda_macbookpro.rev`.
   - Skip the audio step only if the fingerprint is unchanged and `dkms status` shows the module installed for the running kernel.
   - Otherwise: if an old copy exists, run its `./install.cirrus.driver.sh -r`; then replace the copy and run `./install.cirrus.driver.sh -i` from it.

e. **Uninstall:**
   - Remove all `appleibridge` DKMS versions and `/usr/src/appleibridge-*`.
   - Run `-r` from the system audio copy if it exists.
   - Remove `/usr/local/src/mbp132-setup`. This also removes the `touchbar/` clone that older versions left there.
   - Keep everything else uninstall already does, including the Wi-Fi part.

f. **Text:** update the header comment and `--help` to say the script runs from a clone of this repository.

### 6. Documentation

- **README:**
  - usage (clone, `cd`, `sudo ./mbp132-setup.sh`);
  - a short "Vendored drivers" section linking `drivers/README.md`;
  - the `cdn.kernel.org` exception;
  - credits and licenses;
  - links to NOTES.md and TESTING.md.
- **CHANGELOG.md:** add an "Unreleased" entry listing the changes. Say they are untested on hardware until TESTING.md has been run.

### 7. CI: `.github/workflows/ci.yml`

Triggers: push, pull_request, `workflow_dispatch`, and a weekly `schedule`. The weekly run catches breakage from new kernels.

- **Job `lint`** (ubuntu-latest):
  - `shellcheck -S warning mbp132-setup.sh`;
  - `bash -n mbp132-setup.sh`;
  - `python3 -m py_compile tools/*.py`.
- **Job `build-touchbar`:** the Touch Bar driver must build on the kernels of Arch and Arch-based distributions. Use a matrix of containers and kernel-headers packages:

  | Container | Headers to install | Required to pass? |
  |---|---|---|
  | `archlinux:latest` | `linux-headers`, `linux-lts-headers`, `linux-zen-headers`, `linux-hardened-headers` | Yes |
  | `cachyos/cachyos:latest` (CachyOS's official image) | `linux-cachyos-headers`, `linux-cachyos-lts-headers` | Yes |
  | `manjarolinux/base:latest` | The two newest `linuxNNN-headers` from `pacman -Ssq '^linux[0-9]+-headers$'` | No (`continue-on-error: true`), because this image is sometimes out of date |

  In each container:
  1. `pacman -Syu --noconfirm base-devel dkms clang llvm lld <headers>`.
  2. Copy `drivers/apple-ibridge` to `/usr/src/appleibridge-<PACKAGE_VERSION>`.
  3. Run `dkms add`, then `dkms build -k <version>` for every directory in `/usr/lib/modules/*/build`.

  Use DKMS rather than a bare `make`: it matches real installs and picks `LLVM=1` on clang-built kernels, which CachyOS ships. On failure, print the DKMS `make.log` and fail the job.
- Don't add an audio build job, because it downloads a full kernel source. Note this in a comment.

### 8. Static checks before pushing

- `bash -n mbp132-setup.sh`.
- `shellcheck` if it is installed. Don't install it with sudo; CI covers it.
- `./mbp132-setup.sh --help`.
- `./mbp132-setup.sh` without root: it must refuse.
- `git grep -nE '([0-9a-f]{2}:){5}[0-9a-f]{2}'`: only the Broadcom placeholder and documentation examples like `aa:bb:cc:dd:ee:ff` may appear.

### 9. Finish

- Delete `handoff/` in a final commit; its contents now live in the repository.
- Push the branch and open a pull request with `gh pr create` if available; otherwise give me the compare URL. The PR description must say it is untested on hardware and point to TESTING.md. **Do not merge.**
- Report back with:
  - the commits;
  - anything you were unsure about;
  - anything you noticed but did not change;
  - what I need to test on the laptop.

## Later maintenance (for future sessions, not now)

- If CI's `build-touchbar` fails after a kernel release, on any distribution in the matrix:
  1. Fix the code in `drivers/apple-ibridge`.
  2. Bump `PACKAGE_VERSION`.
  3. Record the change in `drivers/README.md` and CHANGELOG.
  4. Open a PR marked "needs hardware test".
- Upstream updates go through `git subtree pull` (see `drivers/README.md`), never by cloning at install time.
