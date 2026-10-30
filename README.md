# ally-x20-steamos

Out-of-tree support for the **ASUS ROG Xbox Ally X20** (board `RC74XA`) on
**stock SteamOS**. No custom distribution, no Anatase, no HHD. Everything is
built from source, survives SteamOS A/B updates, is fully reversible, and is
testable in a VM before it ever touches the device.

> Status: **pre-release, under active development.** Nothing here has run on
> an X20 yet; the first milestones are validated in QEMU. See
> [`X20-STEAMOS-PLAN.md`](X20-STEAMOS-PLAN.md) for the full design and the
> [milestones](X20-STEAMOS-PLAN.md#8-milestones).

## What it fixes

| Gap on stock SteamOS | Fix | Where it lives |
|---|---|---|
| Speakers silent (two TI TAS2783 amps on AMD SoundWire; BIOS flags the machine as DMIC-only, kernel has no link layout, wrong firmware name, no UCM profile) | ACPI table override via early initrd, one rebuilt kernel module (`snd-soc-acpi-amd-match`), firmware download keyed on the `SPEAKER_ID` UEFI variable, UCM overlay | `acpi/`, `patches/kernel/0001*`, `firmware/`, `overlay/ucm2/` |
| Controller not matched by the bundled InputPlumber; Quick Access button dead | Upstream X20 device profile as a `devices.d` drop-in + hwdb entry; `0xa0` mapping in the rebuilt `hid-asus-ally` | `overlay/inputplumber/`, `patches/kernel/0012*` |
| Joystick ring RGB missing from Steam's Customization menu | `hid-asus-ally` registers the LED under a name Steam knows, with fixed channel layout and effect/speed attributes | `patches/kernel/0010*`, `0011*` |
| HDR not detected (panel metadata lives in a DisplayID 2 block) | `libdisplay-info` ≥ 0.4.0 overlay for Desktop Mode; gamescope with upstream PR #2493 behind a wrapper that falls back to stock | `build/build-hdr.sh`, `overlay/ld.so.conf.d/`, `overlay/bin/gamescope` |
| No headphone virtual surround / speaker DSP | PipeWire `filter-chain` HRTF sink chosen per stream by channel count, no-upmix, separate speaker chain; all in `~/.config` | `overlay/home/` |

## Principles

- **Only add files, never edit stock ones.** Everything goes through drop-in
  directories with an `ally-x20-steamos` prefix and is recorded in a manifest.
  Two documented exceptions (boot entry, RAUC handler registration) are
  saved and restored byte-for-byte.
- **Nothing under `/usr`, ever.** `steamos-readonly` is never toggled; a
  policy test fails the build if the string appears.
- **Survives updates.** State lives in `/var/lib/ally-x20-steamos`; a RAUC
  hook and a boot service re-derive `/etc` and boot entries for a freshly
  staged slot and rebuild kernel modules for a new kernel.
- **Never a broken boot.** Patched modules load only when the running kernel
  matches the build; otherwise stock behaviour. A custom gamescope that does
  not accept the session's flags execs the stock one.
- **Reversible from any state.** `uninstall` works from a partial manifest,
  mid-update, from the other slot, or from recovery media.

## Quick start (not yet; the installer is work in progress)

```sh
# Desktop Mode terminal on the X20, once v0.1 is tagged:
git clone https://github.com/cchulo/ally-x20-steamos.git
sudo ./ally-x20-steamos/ally-x20-steamos.sh install
```

CLI overview (`ally-x20-steamos.sh help` lists what is implemented):

| Command | Purpose |
|---|---|
| `install` | bootstrap: clone to `/var/lib/ally-x20-steamos/src`, then `apply` |
| `apply [--slot <mount>]` | (re)install every component onto a root; idempotent |
| `status` | per component: `active`, `stock`, `superseded`, `n/a` |
| `probe` | ask "has SteamOS caught up?" for each component |
| `rebuild` | rebuild kernel modules for the running (or staged) kernel |
| `self-update [--rollback]` | fetch, verify signed tag, migrate, apply |
| `audio-dsp on\|off` | toggle the PipeWire virtual-surround/speaker chain |
| `update-policy block\|degrade [--once]` | what to do when modules cannot be built for an incoming kernel |
| `audit` | compare the manifest with the filesystem |
| `uninstall [--superseded] [--dry-run]` | remove what we added, restore saved originals |

Global options: `--root <dir>` (operate on a fixture or mounted slot),
`--dry-run`, `--verbose`, `--yes`, `--i-know`.

## Repository layout

See [`docs/architecture.md`](docs/architecture.md) for the component model and
[`X20-STEAMOS-PLAN.md` §2](X20-STEAMOS-PLAN.md#2-repository-layout) for the
full tree. In short:

```
ally-x20-steamos.sh   CLI dispatcher          lib/        shell library (manifest, probes, components, slots, modules)
cmd/                  one file per command    components/ one file per fix (audio, inputplumber, hdr, rgb, audio_dsp, ...)
overlay/              files installed onto the device (tracked by the manifest)
patches/kernel/       kernel patches          build/      container build scripts for modules, InputPlumber, HDR stack
acpi/                 DSDT dump + ACP flag patch tool (Python)
firmware/             pinned linux-firmware blobs (lock file only)
vm/                   QEMU/KVM harness        tests/      bats (shell) and pytest (Python)
docs/                 user and developer documentation
```

## Developing

```sh
make check      # shellcheck + shfmt + SPDX headers, then bats + pytest
make test       # tests only
./ally-x20-steamos.sh --root /tmp/fixture status   # everything runs against a fixture root
```

Requirements on a dev host: bash (3.2 is enough; SteamOS has 5), `bats-core`,
`shellcheck`, `shfmt`, `jq`, `python3` + `pytest`. VM work needs an x86 host
with KVM (see [`vm/README.md`](vm/README.md)). Read
[`docs/contributing.md`](docs/contributing.md) before opening a PR.

## License

GPL-2.0-only, with per-file exceptions listed in [`LICENSE.md`](LICENSE.md).
