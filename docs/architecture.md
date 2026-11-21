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
| `<name>_status` | no | override the default `active / stock / superseded / n/a` computation (`modules` adds `partial`: some kernel modules patched, others stock, see [kernel-modules.md](kernel-modules.md)) |
| `<name>_remove` | no | extra cleanup before the manifest-driven file removal |

`lib/component.sh` drives them: `component_apply` first checks the whole
file list (every source exists, no destination holds a file we did not
write), then copies every listed file through `manifest_install_file`, then
calls `<name>_apply`.
`component_status` runs the probe first (superseded wins), then verifies every
manifest entry for the component (all good = `active`, drift or partial =
`stock`, which the boot service treats as "re-apply").

### When a component fails

`apply`, `install` and the boot service never stop at a component that
fails. `cmd/apply.sh` runs each `component_apply` in a subshell; if it
returns non-zero (or dies), that component is skipped and the next one is
applied. What this means in detail:

- **Files.** The file list is checked before anything is written, so a
  component that cannot be installed (missing overlay file, a foreign file
  in the way) leaves no file behind. If its `<name>_apply` step fails
  later, the files already copied stay where they are. They are in the
  manifest, so `status` shows the component as not active, `uninstall
  --component <name>` removes them, and the next `apply` or boot run tries
  again. Nothing is rolled back automatically: undoing half of a component
  (for example its RAUC registration but not its handler files) could
  leave a worse state than either end.
- **Summary and exit code.** `apply` ends with one line per outcome and one
  line per failed component with its reason. Exit codes: `0` everything
  applied, `1` an error before the run could start, `2` usage error, `4`
  the run finished but at least one component failed and was skipped
  (`AX20_EXIT_PARTIAL` in `lib/common.sh`). `install` carries on after a
  `4` (stages the kernel modules, prints the status) and returns `4`
  itself; `self-update` does the same. Any other apply error still stops
  them.
- **Boot.** `ally-x20-steamos.sh boot` always returns 0: a failing
  component is recorded and shown in the notification, and boot continues.
  The unit also has `TimeoutStartSec=15s` and nothing requires it.
- **Record.** The outcome goes to `state/last-apply.json`, described next.

### `state/last-apply.json`

Written by `apply` and by the boot service when it re-applied something
(`lib/lastapply.sh`). `apply --slot`, which the SteamOS update hook runs on
the *other* slot, writes `state/last-apply-slot.json` with the same schema
instead, so it does not replace the record of the running system.

```json
{
  "schema": 1,
  "name": "ally-x20-steamos",
  "when": "2026-11-20T10:15:00Z",
  "command": "apply",
  "result": "failed",
  "exit_code": 4,
  "version": "0.1.11",
  "commit": "1134bae",
  "kernel": "7.3.1-valve3-1-neptune-73-g6fbfd992c8fe",
  "steamos": { "version": "3.10.1", "build": "20261110.100", "branch": "preview", "supported": false },
  "components": [
    { "name": "audio", "outcome": "applied", "when": "2026-11-20T10:14:58Z", "command": "apply" },
    { "name": "hdr", "outcome": "failed", "when": "2026-11-20T10:14:58Z", "command": "apply", "reason": "cannot create directory /etc/ld.so.conf.d", "errors": ["applying component: hdr", "cannot create directory /etc/ld.so.conf.d"] },
    { "name": "inputplumber", "outcome": "skipped", "when": "2026-11-20T10:14:58Z", "command": "apply", "reason": "stock SteamOS provides this" },
    { "name": "modules", "outcome": "unchanged", "when": "2026-11-20T10:14:58Z", "command": "apply" }
  ]
}
```

| Field | Meaning |
|---|---|
| `schema` | `1`. Raised when a field changes meaning; new fields may be added without raising it |
| `when`, `command` | when the last run finished and what it was: `apply`, `apply --only <c>`, `apply --missing-only`, `apply --slot`, `boot` |
| `result` | `failed` if a component failed in that run, else `ok` |
| `exit_code` | what the command returned (`boot` always `0`) |
| `version`, `commit` | the checkout that ran |
| `kernel` | the running kernel (`uname -r`); for `apply --slot`, that slot's kernel |
| `steamos.version`, `.build` | `VERSION_ID` and `BUILD_ID` from `os-release` (empty if absent) |
| `steamos.branch` | the update branch from `/var/lib/steamos-branch` or `/etc/steamos-branch`; if neither exists, on a live system outside the boot service `steamos-select-branch -c` is asked (3 s limit). Empty when unknown. TODO(hw): confirm on the X20 which of these SteamOS 3.8+ provides |
| `steamos.supported` | `true` for `rel`/`stable`, `false` for any other branch, `null` when the branch is unknown |
| `components[].outcome` | `applied`: files and steps were (re)applied. `unchanged`: apply ran and the component's recorded files were already in place with the same content. `failed`: its apply stopped with an error and it was skipped. `skipped`: not attempted (`reason` says why) |
| `components[].when`, `.command` | the run this entry is from. A run that does not touch a component (`apply --only <other>`; the boot service finding nothing to re-apply) keeps the component's previous entry, so every component shows its outcome in the last run that touched it |
| `components[].reason` | for `failed`: the last line the component reported as an error (or its last line of output). For `skipped`: why |
| `components[].errors` | for `failed`: the last 5 non-empty lines the component wrote to stderr, each cut to 300 characters |

Components this version no longer ships are dropped from the list. The file
is small (one line per component) and replaced atomically. `status` shows
the outcome per component in the `LAST APPLY` column, lists failures with
their reason and names the file; `status --json` has `last_apply` (file,
when, command, result) and, per component, `last_apply` and
`last_apply_reason`.

Planned components and the plan sections they implement:

| component | plan | what it owns |
|---|---|---|
| `audio` | §1.1 | ACPI override initrd on the ESP + boot-entry request, UCM overlay (symlink tree), environment.d, TAS2783 firmware fetch keyed on `SPEAKER_ID`, modprobe hook for `firmware_class.path` ([docs/audio.md](audio.md)) |
| `modules` | §1.3, §3 | version-gated kernel module substitution (`load-or-fallback`, generated modprobe.d), staging of built `.ko.zst`, lockdown detection; covers the RGB and Quick Access fixes, which are kernel-only, and the `asus-armoury` power limits ([docs/kernel-modules.md](kernel-modules.md), [docs/rgb.md](rgb.md)) |
| `inputplumber` | §1.2 | upstream X20 `devices.d` profile (verbatim or adapted to the stock 0.78 daemon), hwdb autostart, opt-in ExecStart fallback ([docs/inputplumber.md](inputplumber.md)) |
| `hdr` | §1.4 | libdisplay-info 0.3.0 + DisplayID 2 backport via ld.so.conf.d (Desktop Mode), gamescope Lua display profile for the X20 panel (Game Mode on stock gamescope), opt-in custom gamescope behind a stock-fallback wrapper ([docs/hdr.md](hdr.md)) |
| `power` | §1.6 | steamos-manager RC74XA device entry under `/etc/ally-x20-steamos/steamos-manager/` (rendered: power profiles, no TDP slider unless `power tdp-slider on`, setting in `/etc/ally-x20-steamos/power.conf`), the bind-mount shim (`steamos-manager-devices-shim` + `ally-x20-steamos-power-devices.service`, copy in `/run`), status of the asus-armoury limits; the `asus-armoury` module itself is built and loaded by `modules` ([docs/power.md](power.md)) |
| `sdexpress` | — | udev rule `/etc/udev/rules.d/99-ally-x20-steamos-sdexpress.rules` (rendered from `overlay/udev/rules.d/*.rules.in` with the slot's PCIe root port, default `0000:00:02.2`, override in `/etc/ally-x20-steamos/sdexpress.conf`) that feeds the SD Express card's partitions to stock `block-device-event.sh`/`holo-automount.sh`; `cmd/sdexpress.sh` formats the card with the stock `format-device.sh` sequence, since that script rejects nvme nodes ([docs/sdexpress.md](sdexpress.md)) |
| `update` | §4 | RAUC pre/post-install handlers, `system.conf` delimited block, boot service, user notifier, boot-entry reconcile ([docs/update-survival.md](update-survival.md)) |

Shared libraries behind them: `lib/slots.sh` (A/B slots, boot-entry
save/edit/restore, other-slot mount), `lib/rauc.sh` (handler registration),
`lib/modules.sh` (module staging/resolution), `lib/selfupdate.sh` and
`lib/notify.sh` (release verification, notification queue), `lib/status.sh`
(the single `status.json` writer), `lib/lastapply.sh` (the record of what
the last apply did per component), `lib/retired.sh` (removal of components
this version no longer ships: `audio_dsp`, removed 2026-11-01, see
[audio-dsp-history.md](audio-dsp-history.md); `apply` and the boot service
prune their manifest entries with the uninstaller's rules).

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
apply     = for each component: install files via manifest, run _apply (a failing one is skipped);
            write status.json and last-apply.json; exit 4 if any failed
boot      = ally-x20-steamos.service: verify manifest, re-apply missing, ensure modules for uname -r, run probes
update    = RAUC pre-install: self-update, make sure modules exist for the incoming kernel (policy block|degrade)
            RAUC post-install: apply --slot <new slot>, set its boot entry, stage modules
uninstall = reverse manifest, restore saved boot entry + rauc block, depmod/ldconfig, reboot
reset     = ally-x20-steamos-reset-cleanup.service stop with a factory reset pending:
            efi-cleanup.sh --all-slots restores both grub.cfg from the marker, deletes the ACPI image
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
