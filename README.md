# ally-x20-steamos

Out-of-tree support for the **ASUS ROG Xbox Ally X20** (board `RC74XA`) on
**stock SteamOS**. No custom distribution, no Anatase, no HHD. Everything is
built from source, survives SteamOS A/B updates, is fully reversible, and is
testable in a VM before it ever touches the device.

> **Status: pre-release.** Every piece below is implemented and unit-tested
> against fixture roots, but nothing has yet run on an X20 or in the SteamOS
> VM. [`docs/hardware-data.md`](docs/hardware-data.md) lists every fact that
> still needs a real device, and each component's doc has a "needs the VM"
> section. The design is in [`X20-STEAMOS-PLAN.md`](X20-STEAMOS-PLAN.md).

## What it fixes

| Gap on stock SteamOS | Fix | Component / docs |
|---|---|---|
| **Speakers silent.** Two TI TAS2783 amps on AMD SoundWire; the BIOS flags the machine as DMIC-only, the kernel has no link layout, the driver asks for a firmware name linux-firmware does not ship, and there is no UCM profile. | ACPI table override as an early initrd (pure-Python tool, no `iasl`), a rebuilt `snd-soc-acpi-amd-match` (plus the amp driver and SoundWire helpers with four fixes backported from Valve 7.2.10), firmware download keyed on the `SPEAKER_ID` UEFI variable, UCM overlay | `audio`, `modules` · [docs/audio.md](docs/audio.md) |
| **Controller not matched** by the bundled InputPlumber 0.78; top-right (capture) button dead. | Upstream X20 profile as a `devices.d` drop-in (adapted to the stock daemon's schema) with an X20 button map (Armoury Crate → Quick Access, capture → screenshot) + hwdb autostart; `0xa0` → `KEY_PROG2` in the rebuilt `hid-asus-ally` | `inputplumber`, `modules` · [docs/inputplumber.md](docs/inputplumber.md) |
| **Joystick ring RGB** missing from Steam's Customization menu. | `hid-asus-ally` registers the LED under a name Steam knows, with a fixed R/G/B channel layout and effect/speed attributes | `modules` · [docs/rgb.md](docs/rgb.md) |
| **HDR not detected** (panel metadata lives in a DisplayID 2 block). | libdisplay-info 0.3.0 + DisplayID 2 backport via `ld.so.conf.d` (Desktop Mode); gamescope Lua display profile for the panel, loaded by stock gamescope (Game Mode); optional custom gamescope behind a stock-fallback wrapper | `hdr` · [docs/hdr.md](docs/hdr.md) |
| **No headphone virtual surround / speaker DSP.** | PipeWire `filter-chain` sinks: on Steam's "Default" output the speakers play through the X20 speaker DSP and any headphones (jack, USB, Bluetooth) through 7.1 HRTF virtual surround, switching on plug/unplug; speaker virtual surround with crosstalk cancellation; manual picks in Steam always win; all in `~/.config` | `audio_dsp` · [docs/audio-dsp.md](docs/audio-dsp.md) |
| **SteamOS updates wipe out-of-tree changes.** | RAUC pre/post-install handlers, boot service, user notifier; `block`/`degrade` policy when modules cannot be built for an incoming kernel | `update` · [docs/update-survival.md](docs/update-survival.md) |

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

## Install (once v0.1 is tagged; untested on hardware so far)

```sh
# Desktop Mode terminal on the X20
git clone https://github.com/cchulo/ally-x20-steamos.git
cd ally-x20-steamos
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
| `status [--json] [--verbose]` | per component `active` / `stock` / `superseded` / `n/a`, kernel, policy, DSP state |
| `probe [--notify]` | "has SteamOS caught up?" per component |
| `rebuild [--kver <v>]` | fetch or build the patched kernel modules (cache → release asset → container build) |
| `self-update [--channel stable\|beta] [--check] [--rollback]` | signed-tag update of the checkout, migrations, re-apply |
| `audio-dsp on\|off\|status\|hrtf <set>\|speakers-precedence on\|off\|headphones-virtual-surround on\|off\|stereo-surround on\|off\|xtc\|lfe\|master-gain\|test` | the PipeWire chains |
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
ally-x20-steamos.sh   CLI dispatcher            lib/          common, manifest, probes, component, slots, rauc, modules, selfupdate, status, notify
cmd/                  one file per command      components/   audio, audio_dsp, hdr, inputplumber, modules, update
overlay/              files installed on the device (manifest-tracked)   uninstall/   standalone POSIX uninstaller
patches/kernel/       0001-0002 ASoC (audio), 0010-0013 hid-asus-ally     patches/{gamescope,libdisplay-info}/
build/                Containerfile, build-modules.sh, build-hdr.sh, build-inputplumber.sh, build-libmysofa.sh, kernel-sources.md
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

Milestones 1 to 8 of the plan exist as code; what remains is validation:
first the SteamOS VM (install/uninstall round-trip, update survival, module
build), then the first boot on an X20 to collect the hardware facts, adjust
what the dumps disagree with, and tag v0.1 with CI-built module artifacts.
Milestone 9 and the optional Decky plugin come after that.

## License

GPL-2.0-only, with per-file exceptions listed in [`LICENSE.md`](LICENSE.md).
