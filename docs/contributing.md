# Contributing

## Ground rules (from the plan; enforced by tests where possible)

1. Commits are authored by the repository owner only. No co-author or
   AI-attribution trailers.
2. GPL-2.0-only with an SPDX header on every source/script file
   (`scripts/check-spdx.sh`). Third-party files keep their license verbatim
   and are listed in `LICENSE.md` and `scripts/spdx-exceptions.txt`.
3. Never ship binaries: no `.ko`, firmware, or SOFA files in git.
4. Never edit a stock SteamOS file; only add prefixed drop-ins, recorded in
   the manifest. Nothing under `/usr`. Never toggle `steamos-readonly`.
5. Everything path-related goes through `ax20_path` so it can run against a
   fixture root. New behaviour comes with bats (shell) or pytest (Python)
   tests that use fixture trees, not the host system.
6. Shell must work on bash 3.2 (macOS) and bash 5 (SteamOS). No associative
   arrays, `mapfile`, `${var,,}`, or `|&`.

## Workflow

- Work in a git worktree per task (`worktrees/<name>`, branch
  `<type>/<name>`), never on `main` directly.
- `make check` must pass before a PR: shellcheck, shfmt (`-i 4 -ci -bn`),
  SPDX check, bats, pytest. `make fmt` reformats.
- One PR per component or subsystem. Keep the PR description focused on what
  a reviewer must verify on hardware or in the VM, since CI cannot.
- Hardware-only facts (LED node names, `SPEAKER_ID` values, N-KEY report
  bytes) are marked `TODO(hw)` in code and tracked in
  `docs/hardware-data.md` until collected on a real X20.

## Dev host setup

macOS or Linux is fine for everything that does not need a VM: shell
libraries, the ACPI tool, overlay files, CI, docs. Needed: `bash`,
`bats-core`, `shellcheck`, `shfmt`, `jq`, `python3`, `pytest`. VM and
container builds need an x86 Linux host with KVM and podman
(`vm/setup-fedora-host.sh`).

## Layout of a new component

```
components/<name>.sh            contract: see components/README.md
overlay/<...>                   files it installs
tests/components/<name>.bats    fixture roots for "stock lacks X" / "stock has X", apply/status/uninstall round-trip
docs/<name>.md                  user-facing: what it does, how to verify, how to turn it off
```
