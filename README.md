# ally-x20-steamos

Out-of-tree support for the **ASUS ROG Xbox Ally X20** (board `RC74XA`) on
**stock SteamOS**. No custom distribution, no Anatase, no HHD. Everything is
built from source, survives SteamOS A/B updates, is fully reversible, and is
testable in a VM before it ever touches the device.

> **AI-assisted.** The code, patches, tests and documentation in this
> repository were written with AI assistance (Claude) under the owner's
> direction, and reviewed and tested by the owner on a single ROG Xbox Ally
> X20. It ships patched kernel modules and an ACPI table override: read what
> you run, back up what matters to you, and use it at your own risk. Issues
> and reports are welcome.
>
> **Use at your own discretion.** This is a hobby project by one owner for
> one device. The owner is not responsible for a broken, bricked or
> warranty-voided Ally X20, lost data, or anything else that follows from
> using it. If you are not comfortable with patched kernel modules, boot
> entry edits and an ACPI override on your handheld, wait for official
> SteamOS support for the X20 instead, or use a distribution that already
> targets it, such as [Anatase](https://github.com/anatase-org/anatase),
> if you absolutely need Linux on it today.

**New here? Read the [user guide](docs/user-guide.md)**: what it fixes and
what not yet, how to install, check, update and remove it, and how to report
a problem.

> **Status: first release.** Tested by the owner on one X20 (BIOS
> `RC74XA.303`, SteamOS 3.9.5, kernel `7.2.7-valve2`). Other BIOS, SteamOS or
> kernel versions may behave differently.
> [`docs/hardware-data.md`](docs/hardware-data.md) lists what is still
> unconfirmed on the hardware. The design is in
> [`X20-STEAMOS-PLAN.md`](X20-STEAMOS-PLAN.md).

## What it fixes

| Gap on stock SteamOS | Fix | Component / docs |
|---|---|---|
| **Speakers silent.** Two TI TAS2783 amps on AMD SoundWire; the BIOS flags the machine as DMIC-only, the kernel has no link layout, the driver asks for a firmware name linux-firmware does not ship, and there is no UCM profile. | ACPI table override as an early initrd (pure-Python tool, no `iasl`), a rebuilt `snd-soc-acpi-amd-match` (plus the amp driver and SoundWire helpers with four fixes backported from Valve 7.2.10), firmware download keyed on the `SPEAKER_ID` UEFI variable, UCM overlay | `audio`, `modules` · [docs/audio.md](docs/audio.md) |
| **Controller not matched** by the bundled InputPlumber 0.78; top-right (capture) button dead; rumble weak at 100 % and strong rumble makes the speakers hiss. | Upstream X20 profile as a `devices.d` drop-in (adapted to the stock daemon's schema) with an X20 button map (Armoury Crate → Quick Access, capture → screenshot) + hwdb autostart; `0xa0` → `KEY_PROG2` in the rebuilt `hid-asus-ally`, which also scales rumble to the MCU's 0-100 range | `inputplumber`, `modules` · [docs/inputplumber.md](docs/inputplumber.md) |
| **Joystick ring RGB** missing from Steam's Customization menu. | `hid-asus-ally` registers the LED under a name Steam knows, with a fixed R/G/B channel layout and effect/speed attributes | `modules` · [docs/rgb.md](docs/rgb.md) |
| **HDR not detected** (panel metadata lives in a DisplayID 2 block). | libdisplay-info 0.3.0 + DisplayID 2 backport via `ld.so.conf.d` (Desktop Mode); gamescope Lua display profile for the panel, loaded by stock gamescope (Game Mode); optional custom gamescope behind a stock-fallback wrapper | `hdr` · [docs/hdr.md](docs/hdr.md) |
| **No power profiles in Steam's Performance menu.** steamos-manager 26.4.1 has no X20 device file. | The upstream steamos-manager RC74XA entry, merged into `/usr/share/steamos-manager/devices` by a boot-time bind mount of a copy in `/run` (nothing written to `/usr`, steps aside once SteamOS ships it): Low power / Balanced / Performance hold the APU at about 12 / 16-21 / 25-30 W on battery. No TDP slider on purpose: BIOS `RC74XA.303` ignores PPT writes (`power tdp-slider on` to re-test; the mainline `asus-armoury` RC74XA table is still built) | `power`, `modules` · [docs/power.md](docs/power.md) |
| **Generic handheld artwork** in Steam's controller screens: the Steam client in SteamOS 3.9.5 does not know the X20's device name. | The steamos-manager entry names the device `rog_xbox_ally_x` (same shell, screen and controls) | `power` · [docs/power.md](docs/power.md) |
| **SteamOS updates wipe out-of-tree changes.** | RAUC pre/post-install handlers, boot service, user notifier; `block`/`degrade` policy when modules cannot be built for an incoming kernel | `update` · [docs/update-survival.md](docs/update-survival.md) |

Audio plays through the hardware sinks as on stock SteamOS. The headphone
virtual surround and speaker DSP were removed on 2026-11-01 after a
level-matched A/B on the device; `apply` removes them from older installs
([docs/audio-dsp-history.md](docs/audio-dsp-history.md)).

## Principles

- **Only add files, never edit stock ones.** Everything goes through drop-in
  directories with an `ally-x20-steamos`/`x20` marker in the name and is
  recorded in a manifest. Two documented exceptions (the slot's GRUB boot
  entry and the RAUC handler registration) are saved first and restored
  byte-for-byte.
- **Nothing under `/usr`, ever.** `steamos-readonly` is never toggled; a
  policy test fails the build if the string appears.
- **Survives updates.** State lives in `/var/lib/ally-x20-steamos`, a symlink
  into the shared `/home` partition (SteamOS has a separate 256 MiB `var`
  per slot). A RAUC hook and a boot service re-derive `/etc` drop-ins, the
  boot entry and the kernel modules for a freshly staged slot.
- **Never a broken boot.** Patched modules load only when the running kernel
  matches the build; otherwise stock behaviour. A custom gamescope that does
  not accept the session's flags execs the stock one.
- **Reversible from any state.** The standalone POSIX uninstaller works from
  a partial manifest, mid-update, from the other slot, or from recovery
  media, and refuses a deny-list of paths even if the manifest is crafted.
- **Probes, never auto-removal.** When a SteamOS update ships a fix natively
  the component is reported `superseded` and you choose to run
  `uninstall --superseded`.

## Install

```sh
# Desktop Mode terminal on the X20
git clone https://github.com/cchulo/ally-x20-steamos.git
cd ally-x20-steamos
git checkout "$(git tag -l 'v*' --sort=-version:refname | head -n1)"   # newest release
sudo ./ally-x20-steamos.sh install      # clones into the state dir, pins keys, applies, prints status
```

See [docs/install.md](docs/install.md). There is also a `bootstrap.sh` for a
one-liner; the docs explain why cloning and reading first is preferred.

## CLI

```
ally-x20-steamos.sh [--root <dir>] [--dry-run] [--verbose] [--yes] [--i-know] <command>
```

| Command | Purpose |
|---|---|
| `install` | bootstrap: clone to `/var/lib/ally-x20-steamos/src`, pin keys, `apply`, `status` |
| `apply [--slot <mount>] [--only <c>] [--missing-only] [--verify-only]` | (re)install components here or into a mounted slot; idempotent |
| `status [--json] [--verbose]` | per component `active` / `stock` / `superseded` / `n/a`, kernel, policy |
| `probe [--notify]` | "has SteamOS caught up?" per component |
| `rebuild [--kver <v>]` | fetch or build the patched kernel modules (cache → release asset → container build) |
| `self-update [--channel stable\|beta] [--check] [--rollback]` | signed-tag update of the checkout, migrations, re-apply |
| `power status\|tdp-slider [on\|off]` | power profiles; the TDP slider test switch (default off) |
| `update-policy show\|block\|degrade [--once]` | what an update does if modules cannot be built |
| `boot-entry show\|set\|clear\|apply\|restore` | the boot-entry exception (early initrd, cmdline args) |
| `audit [--json]` | manifest vs filesystem: modified, missing, unexpected |
| `uninstall [--superseded] [--component <c>] [--force] [--keep-state] [--reboot]` | remove what we added, restore saved originals |
| `components`, `version`, `help` | introspection |

`boot`, `notify` and `rauc-handler` are internal entry points for the systemd
units and RAUC. Every command accepts `--root <dir>` and runs unchanged
against a fixture tree, which is how the test suite works.

## Repository layout

```
ally-x20-steamos.sh   CLI dispatcher            lib/          common, manifest, probes, component, retired, slots, rauc, modules, selfupdate, status, notify
cmd/                  one file per command      components/   audio, hdr, inputplumber, modules, power, update
overlay/              files installed on the device (manifest-tracked)   uninstall/   standalone POSIX uninstaller
patches/kernel/       0001-0006 ASoC (audio), 0010-0015 hid-asus-ally, 0020 asus-armoury   patches/{gamescope,libdisplay-info}/
build/                Containerfile, build-modules.sh, build-hdr.sh, build-inputplumber.sh, kernel-sources.md
acpi/                 patch-acp-flag.py (DSDT flag patch + early initrd), dump-dsdt.md, fixtures/, tests/
firmware/             tas2783.lock, fetch-tas2783.sh, speaker-id.map       keys/        release signing key placeholders
vm/                   run-steamos-vm.sh, setup-fedora-host.sh, guest/ scripts, test LED module, ci/
migrations/           idempotent self-update migrations                     tests/       bats suites (shell), fixtures
docs/                 user and developer documentation (index: docs/README.md)
.github/workflows/    test.yml (lint + unit, Ubuntu + macOS bash 3.2), build-modules.yml, vm-tests.yml
```

## Developing

```sh
make check      # shellcheck + shfmt + SPDX headers, then bats + pytest
make test       # tests only
./ally-x20-steamos.sh --root /tmp/fixture status   # everything runs against a fixture root
```

Requirements on a dev host: bash (3.2 is enough; SteamOS has 5), `bats-core`,
`shellcheck`, `shfmt`, `jq`, `python3` + `pytest`. Compiling kernel modules,
the HDR stack and the VM runs need an x86 Linux host with KVM and podman
(see [docs/vm-testing.md](docs/vm-testing.md) and `vm/setup-fedora-host.sh`).
Read [docs/contributing.md](docs/contributing.md) before opening a PR.

## Roadmap

Milestones 1 to 8 of the plan exist as code and run on the owner's X20;
v0.1.0 is the first release, with CI-built module artifacts attached to
the GitHub release. Still open: the `TODO(hw)` items in
[docs/hardware-data.md](docs/hardware-data.md), a real SteamOS A/B update on
the device, the VM round-trip tests, and the optional Decky plugin.

## Credits

This project stands on other people's work. Patches taken from elsewhere
keep their original author and trailers; each patch's "Derived from:"
section and the docs linked below name the exact commits.

**Kernel code**

- **Valve's SteamOS kernel**,
  [linux-integration](https://github.com/evlaV/linux-integration) (public
  mirror of `gitlab.steamos.cloud/jupiter/linux-integration`): every module
  is rebuilt from its `7.2.7-valve2` tree. Patches 0003-0006 are backported
  from `7.2.10-valve1` and keep their author, **Matthew Schwartz**
  (`9a0dabd2637d`, `021e9da34c58`, `5ce75814c28a`, `2ce1d48892f3`). Patches
  0001 and 0002 match his RC74XA commits `5f7b3941a10f` and `045b13e03d29`
  in the same release, and the firmware naming in
  [firmware/README.md](firmware/README.md) follows `8ba654cb1c44`.
- **Luke D. Jones**: the `hid-asus-ally` driver (his out-of-tree ROG Ally
  series carried in Valve's kernel), which patches 0010-0015 change.
- **Mainline Linux**: patch 0020 is `148794d9f0d2` "platform/x86:
  asus-armoury: Add XBOX ROG Ally X 20 Tunables" by **Derek J. Clark**,
  reviewed and merged by **Ilpo Järvinen** (also Valve's `cf069f36e48d`).
  The `hid-asus-ally` patches follow patterns from `hid-lenovo-go-s.c` (the
  `go_s:rgb:joystick_rings` LED ABI), `hid-playstation.c`, `hid-nintendo.c`,
  `hid-microsoft.c` and `hid-asus.c`.
- [anatase-org/kernel-anatase](https://github.com/anatase-org/kernel-anatase)
  (`7.2.7-an22`): the same audio commits backported to 7.2.7, used to
  cross-check 0001-0003.

**Userspace**

- [ShadowBlip/InputPlumber](https://github.com/ShadowBlip/InputPlumber)
  (GPL-3.0-or-later): the X20 device profile (PR #756) and the
  `ally_type2.yaml` capability map (v0.83.0) we ship, and the report and
  screenshot-chord code behind patches 0014 and 0015.
- [steamos-manager](https://gitlab.steamos.cloud/holo/steamos-manager)
  (Valve, MIT): the RC74XA device entry (`bfbb261ed6b2`) and the device file
  format.
- [ValveSoftware/gamescope](https://github.com/ValveSoftware/gamescope)
  (BSD-2-Clause): PR #2493 by **Matthew Schwartz**, the X20 display profile
  and the DisplayID 2 HDR patches ([docs/hdr.md](docs/hdr.md)).
- [libdisplay-info](https://gitlab.freedesktop.org/emersion/libdisplay-info)
  (MIT): the DisplayID 2 backport onto 0.3.0 is eight upstream commits, by
  **Simon Ser** (seven) and **Bernd Kuhls** (one).
- [alsa-project/alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf)
  (BSD-3-Clause): the TAS2783 UCM files, from `182d0122a7d9` (PR #812).
- **Texas Instruments**: the TAS2783 speaker tuning files, published in
  [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/ti/audio/tas2783)
  under `LICENCE.ti-tspa` and downloaded at install time by
  `firmware/fetch-tas2783.sh` from a pinned commit; never redistributed
  here ([firmware/README.md](firmware/README.md)).

**Findings and references**

- [hungarianhc/rog-ally-x20-steamos-speakers](https://github.com/hungarianhc/rog-ally-x20-steamos-speakers):
  the first working X20 speaker setup on SteamOS (link layout, ACP flag
  diagnosis, initrd override, `SPEAKER_ID` supplier mapping, firmware pins).
- [ovenham/rog-ally-x20-steamos-speaker-qam-fix](https://github.com/ovenham/rog-ally-x20-steamos-speaker-qam-fix):
  the X20 button codes (Armoury Crate `0xa6`, capture `0xa0`), the proposed
  ACP config quirk and speaker findings.
- [stoneharborent/aquarius-os PR #40](https://github.com/stoneharborent/aquarius-os/pull/40):
  a clear write-up of the four speaker problems and matching patches.
- [hhd-dev/hhd](https://github.com/hhd-dev/hhd): Ally button codes, RGB
  commands and rumble reports;
  [hhd-dev/adjustor](https://github.com/hhd-dev/adjustor): the TDP tables
  and PPT write order we compared against ([docs/power.md](docs/power.md)).
- [kndclark/ally_module](https://github.com/kndclark/ally_module) and
  ValveSoftware/SteamOS issues
  [#2260](https://github.com/ValveSoftware/SteamOS/issues/2260) and
  [#2371](https://github.com/ValveSoftware/SteamOS/issues/2371): the
  joystick-ring LED name, channel layout and effect reports.
- [seerge/g-helper](https://github.com/seerge/g-helper),
  [asusctl](https://gitlab.com/asus-linux/asusctl) and the
  [z13ctl protocol notes](https://dahui.github.io/z13ctl/protocol): ASUS
  Aura lighting commands.
- [anatase-org/anatase](https://github.com/anatase-org/anatase) (UCM-only
  audio setup) and [ublue-os/bazzite](https://github.com/ublue-os/bazzite)
  (audio defaults on the Ally family, the `amd_pmf` power-limit workaround):
  references for the audio and power decisions.
- [NicoWayne95/anatase-x20-hdr-fix](https://github.com/NicoWayne95/anatase-x20-hdr-fix):
  the libdisplay-info backport approach for Desktop Mode HDR.
- [60plus/SteamOS_Nvidia_Installer](https://github.com/60plus/SteamOS_Nvidia_Installer):
  the custom gamescope with stock fallback pattern.
- [icedream/steamos-permanent-mods](https://github.com/icedream/steamos-permanent-mods)
  (RAUC hook) and
  [ryanrudolfoba/vangogh_oc_fix](https://github.com/ryanrudolfoba/vangogh_oc_fix)
  (`/etc` carry-over): surviving SteamOS updates.
- [Hooandee/panel-de-control issue #1012](https://github.com/Hooandee/panel-de-control/issues/1012):
  independent confirmation that TDP changes have no effect on the X20.

Licensing of the files kept under their original license:
[LICENSE.md](LICENSE.md).

## License

GPL-2.0-only, with per-file exceptions listed in [`LICENSE.md`](LICENSE.md).
