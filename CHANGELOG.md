# Changelog

What each release of ally-x20-steamos changes, newest first.

This file is the source of the release notes on GitHub: when a `v*` tag is
pushed, the release job takes that version's section from here
(`scripts/release-notes.sh`). A version without a section here cannot be
released: the tests fail for the `VERSION` file, and the release job fails
for the tag. How to add an entry: [docs/contributing.md](docs/contributing.md#release-notes).

## Unreleased

- **SD Express is marked as not fully supported** (#89): a card can be missing after a long sleep, cards cannot be swapped reliably while the device is on, and a restart has hung. The cause may be the device's firmware or missing kernel support; it is not known yet. The README, the user guide and the component's documentation now say so and point to the issue. Also documented: give each card its own `--label`, since two cards with the same label are taken for one library.

## v0.2.1 (2026-11-21)

- **HDR in Desktop Mode without a manual build** (component `hdr`). Desktop Mode (KDE) needs a rebuilt libdisplay-info that nothing built or installed until now; `apply` only pointed at a script that cannot be run on the device. Game Mode HDR is unchanged and already worked.
  - The library is built by CI and attached to each release (`hdr-libdisplay-info-0.3.0.tar.zst`). `install`, `apply` and `self-update` download it, check it (sha256, built from this version's pins and patches, loadable on this system) and install it; a device that was offline gets it on a later boot. Offline or without a prebuilt copy nothing fails: Desktop Mode HDR stays off and one notice says how to get it.
  - New command `hdr status|fetch|build|remove`: what is installed for both modes, download the library now, build it on the device with podman, or take it out again.
  - If Desktop Mode ever fails to start with the library: Ctrl+Alt+F3, log in, `sudo /var/lib/ally-x20-steamos/src/ally-x20-steamos.sh hdr remove`. The library then stays out until `hdr fetch`.
  - Nothing is installed when SteamOS ships another libdisplay-info than 0.3.0; from 0.4.0 on SteamOS reads the panel's HDR data itself.

Tested on the device: Desktop Mode HDR with this library, built by hand in the container, is confirmed on the owner's X20 (SteamOS 3.9.5, 2026-11-22); with the library moved aside HDR is unavailable again. Not tested on the device: the copy CI builds, the automatic download and install, and the `hdr` command.

## v0.2.0 (2026-11-21)

- **Virtual 7.1 surround** for the built-in speakers and headphones (component `surround`; #76, #80, #81). Games can send 7.1 and you hear it as virtual surround.
  - Profiles per output: four heads, each as `-dry` (recommended, the default) and `-full`, plus `stereo` and `user`, your own HeSuVi file (for example Dolby Atmos for Headphones). `surround set headphones|speakers <profile>` switches while a game runs.
  - Speakers: crosstalk cancellation, on by default at delay 60 µs, strength 50 % (`surround xtc`, `surround prepare`).
  - Steam's output list shows one entry with a readable name, for example "Speakers (Surround - SADIE D2 Dry)"; the plain outputs are hidden (`surround plain shown` brings them back) and `stereo` shows as "Speakers (Stereo)".
  - The volume keys keep their full range, and the volume follows a profile switch.
- **Charging to 100 %** (component `chargelimit`; #72, issue #73). With Steam's charge limit off, Steam writes `0`, which this firmware treats as a limit of about 80 %. The `0` is now replaced by 100. A limit set in Steam is respected and kept across reboots; `charge-limit <20-100>` is a last resort.
- **Button layout** (#77, issue #68): the action button (top right) opens Quick Access, Armoury Crate (top left) is a second Steam button, a screenshot is Xbox + R1. `buttons layout legacy` restores the earlier layout. Existing installs switch to the new layout at this update.
- The surround test rig used to choose the profiles is in `tools/surround-test/` (#70). It is not installed on the device.
- User guide: everyday sound and power settings, and how to use your own Atmos file (#82).

No kernel patch changed since v0.1.11.

Tested on the device: the charge limit, surround on the speakers (default profile and the owner's own file), the volume range. Not tested on the device: headphones through the surround component, plugging headphones in and out, and the new button layout.

## v0.1.11 (2026-11-20)

- **Controller after resume** (#69): the controller's mode settings are re-sent after every resume instead of restarting InputPlumber, so the sticks work at once and Steam shows no controller disconnect. The Xbox button light no longer waits for that step and is back about 3 s after a wake.
- **Speakers silent after resume** (#71): two kernel fixes backported from Valve's 7.2.10 (patches 0007 and 0008). Confirmed on the device over repeated sleep and wake.
- Docs: the SD Express card must not be mounted through `/etc/fstab` (#74).

## v0.1.10 (2026-11-14)

- **SD Express slot** (component `sdexpress`): the card is automounted through the stock holo-automount scripts like a microSD card, matched by the slot's PCIe root port because the card and the SSD swap `nvmeN` names between boots. `sdexpress format` runs the stock format sequence, since Steam's Format button rejects NVMe devices. Not yet verified on hardware.
- **Resume fixes** (#63): the Xbox button light settings are re-sent and InputPlumber is restarted after suspend, so the light and the gamepad come back.
- README: install/update section and FAQ reorganised.

## v0.1.9 (2026-11-04)

- Xbox button light brightness and breathe are recorded in `/etc/ally-x20-steamos/xbox-led.conf` and re-sent by a udev rule when the controller appears, so they survive a cold boot (component `xboxled`).

## v0.1.8 (2026-11-04)

- `self-update` stages the kernel modules itself, so a release that changes the patches actually reaches devices (the v0.1.7 `hid-asus-ally` change did not before this).
- Module builds from a different patch set are refused instead of loaded.

## v0.1.7 (2026-11-04)

- `hid-asus-ally` patch 0016: Aura state applied only on effect changes; the Xbox button light is owned by the driver (`xbox_button_light` attribute), so `xbox-led on|off` is kept across reboots.
- `power status` shows the battery `charge_limit`.

## v0.1.6 (2026-11-04)

- New `xbox-led` command: the Xbox button light on/off, brightness 0-3 and breathing, using the reports Armoury Crate sends (captured on Windows, verified on the X20). Closes #47.

## v0.1.5 (2026-11-04)

- Release module build fetches Valve kernel headers by package name when the Arch repo database has moved on (fixes failed release builds).

## v0.1.4 (2026-11-04)

- The release signing key is shipped in `keys/`; placeholder pins are replaced on the first `self-update`.

No GitHub release was made for this tag.

## v0.1.3 (2026-11-04)

- One `[handlers]` section in `/etc/rauc/system.conf`, so `steamos-update` works again.
- The steamos-manager device name is back to upstream's.

No GitHub release was made for this tag.

## v0.1.2 (2026-10-31)

- `install` stages the patched kernel modules itself instead of waiting for the boot service.
- Boot service: fixed the staged-directory check.

## v0.1.1 (2026-10-31)

- **EFI clean-up fail-safe** and a factory-reset shutdown hook that restores both slots' `grub.cfg` and removes the ACPI image.
- `status`: the staged-modules check reads the `/etc` early directory.
- README: use-at-your-own-discretion notice.

## v0.1.0 (2026-10-31)

First public release.

ROG Xbox Ally X20 on stock SteamOS 3.9.5 (kernel 7.2.7-valve2). Tested on one device, BIOS RC74XA.303.

- **Speakers:** ACPI table override as an early initrd, rebuilt SoundWire/TAS2783 modules, amp firmware fetched by `SPEAKER_ID`, UCM overlay.
- **Controller:** InputPlumber X20 profile (Armoury Crate → Quick Access, capture → screenshot), rebuilt `hid-asus-ally` with full-range rumble.
- **Joystick ring RGB** in Steam's Customization menu.
- **HDR and 30-120 Hz** in Game Mode (gamescope display profile), libdisplay-info DisplayID 2 backport for Desktop Mode.
- **Power profiles** (Low power / Balanced / Performance) through a steamos-manager device entry bind-mounted over `/usr/share/steamos-manager/devices`; no TDP slider because the firmware ignores PPT writes.
- **Update survival:** RAUC pre/post-install handlers, boot service, user notifier, `block`/`degrade` policy for kernels the modules cannot be built for.
- Manifest-driven install and uninstall; nothing written under `/usr`, `steamos-readonly` never toggled.
