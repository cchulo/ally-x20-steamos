# Architecture

This document describes how the code is organised so that independent pieces
(audio, controller, RGB, HDR, audio DSP, power, update survival) can be developed and
tested separately, and how they fit together at install, boot, update and
uninstall time. The *why* behind every decision is in
[`X20-STEAMOS-PLAN.md`](../X20-STEAMOS-PLAN.md).

## 1. One CLI, many commands

`ally-x20-steamos.sh` is a thin dispatcher. It parses global options
(`--root`, `--dry-run`, `--verbose`, `--yes`, `--i-know`), sources
`lib/common.sh`, then sources `cmd/<command>.sh` and calls
`cmd_<command>` (dashes become underscores). Adding a command means adding a
file; nothing else changes. The second line of each command file is
`# summary: ...`, which `help` prints.

## 2. The fixture-root contract

Every path the tool touches is built with `ax20_path /absolute/path`, which
prefixes `AX20_ROOT`. On a live system `AX20_ROOT` is empty. In tests it is a
temporary directory; for the RAUC post-install hook it is the freshly staged
slot's mount point (`apply --slot <mount>`). Consequences:

- Code that hard-codes `/etc/...` or `/var/lib/...` without `ax20_path` is a
  bug. Tests build fixture trees with `make_root` and `fixture_file`.
- "Is this SteamOS?" questions are answered from files under the root, never
  from the running system, so probes can be unit-tested with fixture trees
  representing "stock lacks X" and "stock has X".
- Privilege checks (`require_root`) are skipped when `AX20_ROOT` is set.
- The kernel version comes from `probe_running_kver`, which honours
  `AX20_KVER` for fixtures.

## 3. Components

A component is one self-contained fix. Each is a file `components/<name>.sh`
defining:

| symbol | required | role |
|---|---|---|
| `COMPONENT_DESCRIPTION` | yes | one line for `status`/`components` |
| `<name>_files` | yes | prints `src<TAB>dest<TAB>mode[<TAB>slot]` lines; `src` is relative to `overlay/`, `dest` is absolute without root prefix |
| `<name>_probe` | yes | exit 0 if stock SteamOS now provides this (superseded), 1 if still needed, 2 unknown |
| `<name>_apply` | no | extra idempotent steps after files are copied (depmod, ldconfig, `systemctl enable`, downloads into the state dir) |
| `<name>_status` | no | override the default `active / stock / superseded / n/a` computation |
| `<name>_remove` | no | extra cleanup before the manifest-driven file removal |

`lib/component.sh` drives them: `component_apply` copies every listed file
through `manifest_install_file`, then calls `<name>_apply`.
`component_status` runs the probe first (superseded wins), then verifies every
manifest entry for the component (all good = `active`, drift or partial =
`stock`, which the boot service treats as "re-apply").

Planned components and the plan sections they implement:

| component | plan | what it owns |
|---|---|---|
| `audio` | §1.1 | ACPI override initrd on the ESP + boot-entry request, UCM overlay (symlink tree), environment.d, TAS2783 firmware fetch keyed on `SPEAKER_ID`, modprobe hook for `firmware_class.path` ([docs/audio.md](audio.md)) |
| `modules` | §1.3, §3 | version-gated kernel module substitution (`load-or-fallback`, generated modprobe.d), staging of built `.ko.zst`, lockdown detection; covers the RGB and Quick Access fixes, which are kernel-only, and the `asus-armoury` power limits ([docs/kernel-modules.md](kernel-modules.md), [docs/rgb.md](rgb.md)) |
| `inputplumber` | §1.2 | upstream X20 `devices.d` profile (verbatim or adapted to the stock 0.78 daemon), hwdb autostart, opt-in ExecStart fallback ([docs/inputplumber.md](inputplumber.md)) |
| `hdr` | §1.4 | libdisplay-info 0.3.0 + DisplayID 2 backport via ld.so.conf.d (Desktop Mode), gamescope Lua display profile for the X20 panel (Game Mode on stock gamescope), opt-in custom gamescope behind a stock-fallback wrapper ([docs/hdr.md](hdr.md)) |
| `audio_dsp` | §1.5 | per-user PipeWire `filter-chain` sinks (speaker chain `x20-speakers` as the automatic default on the speakers, 7.1 headphone sink `x20-headphones`, HRTF on rears and sides, fronts dry), no-upmix, WirePlumber hooks for the automatic default sink, the headphone surround output and the hardware volume rule (sinks under our default at 100 %), HRTF sets ([docs/audio-dsp.md](audio-dsp.md)) |
| `power` | §1.6 | steamos-manager RC74XA device entry under `/etc/ally-x20-steamos/steamos-manager/`, the bind-mount shim (`steamos-manager-devices-shim` + `ally-x20-steamos-power-devices.service`, copy in `/run`), status of the asus-armoury limits; the `asus-armoury` module itself is built and loaded by `modules` ([docs/power.md](power.md)) |
| `update` | §4 | RAUC pre/post-install handlers, `system.conf` delimited block, boot service, user notifier, boot-entry reconcile ([docs/update-survival.md](update-survival.md)) |

Shared libraries behind them: `lib/slots.sh` (A/B slots, boot-entry
save/edit/restore, other-slot mount), `lib/rauc.sh` (handler registration),
`lib/modules.sh` (module staging/resolution), `lib/selfupdate.sh` and
`lib/notify.sh` (release verification, notification queue), `lib/status.sh`
(the single `status.json` writer).

## 4. State directory and manifest

Everything persistent lives under `/var/lib/ally-x20-steamos` (`AX20_STATE_REL`,
the canonical path used everywhere). On SteamOS that path is a **relative
symlink to `/home/.ally-x20-steamos`**: `var-A`/`var-B` are separate 256 MiB
partitions that RAUC rsyncs across on update, while `/home` is shared and
large. `install` creates the symlink, `apply --slot` re-creates it in a
freshly staged slot, and the standalone uninstaller removes both the target
and the link (`ax20_state_dir_ensure` in `lib/common.sh`). Fixture roots in
tests keep a plain directory.

Files that the kernel needs before `/var` and `/home` are mounted (the
modprobe helper, staged modules, amp firmware) live under
`/etc/ally-x20-steamos/` (`AX20_EARLY_REL`) instead; see
[kernel-modules.md](kernel-modules.md).

`/var/lib/ally-x20-steamos/manifest` is JSON lines, one object per path we
created: `path`, `component`, `kind` (`file|symlink|dir`), `sha256`, `slot`,
`created_dir`, `ts`. `lib/manifest.sh` is the only writer. Rules enforced
there:

- `manifest_install_file` refuses to overwrite a path that exists but is not
  in the manifest. Since every path we own has an `ally-x20-steamos` prefix
  and lives in a drop-in directory, this can only fire on operator error.
- Parent directories we had to create are recorded as `dir` entries so
  uninstall can remove them if they end up empty.
- `manifest_verify` compares the current content with what we wrote; this is
  what `audit`, `status` and the boot service use to detect drift.
- Dry-run mode (`--dry-run`) performs no writes anywhere, including the
  manifest.

`uninstall` consumes the manifest newest-first, removes only entries whose
digest still matches (or `--force`), and hard-refuses a deny-list of paths
regardless of what the manifest says (plan §5.2). The uninstaller is shipped
as a self-contained POSIX script at `/var/lib/ally-x20-steamos/uninstall.sh`
so it keeps working when the git checkout is gone.

## 5. Probes

`lib/probes.sh` has the generic building blocks (`probe_file_exists`,
`probe_file_contains`, `probe_stock_module_contains`, `probe_soname_version`,
`probe_version_ge`). Each component's `<name>_probe` composes them following
the table in plan §5. Probes never remove anything: a positive probe only
flips the status to `superseded` and triggers a notification; the user runs
`uninstall --superseded`.

## 6. Install, boot, update, uninstall flows

```
install   = bootstrap clone -> apply (this slot) -> enable boot service -> register RAUC handlers
apply     = for each component: install files via manifest, run _apply; write status.json
boot      = ally-x20-steamos.service: verify manifest, re-apply missing, ensure modules for uname -r, run probes
update    = RAUC pre-install: self-update, make sure modules exist for the incoming kernel (policy block|degrade)
            RAUC post-install: apply --slot <new slot>, set its boot entry, stage modules
uninstall = reverse manifest, restore saved boot entry + rauc block, depmod/ldconfig, reboot
```

## 7. Conventions

- Bash 3.2 compatible shell (macOS dev hosts) and POSIX `sh` for anything
  that must run from recovery media (the standalone uninstaller).
- `set -eu` in executables; libraries never call `exit` except through `die`.
- Tests: bats under `tests/<area>/*.bats`, pytest under `acpi/tests/`.
  `make check` runs lint and all tests; CI runs the same on Ubuntu and under
  macOS bash 3.2.
- Policy tests in `tests/policy/hardening.bats` fail the build on
  `steamos-readonly disable|enable`, writes under `/usr`, host `pacman`,
  tracked binaries, missing SPDX headers, and bash-4-only constructs.
