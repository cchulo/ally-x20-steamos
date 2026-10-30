# Installing ally-x20-steamos

This guide covers installing on a ROG Xbox Ally X20 (DMI board `RC74XA`)
running stock SteamOS. What gets fixed and why is in
[`X20-STEAMOS-PLAN.md`](../X20-STEAMOS-PLAN.md). How to undo everything is
covered by `uninstall` (see the plan, §5).

## Prerequisites

- Stock SteamOS with read-only mode **on** (the default). The installer
  refuses to run if someone ran `steamos-readonly disable`, because stock
  files may then have been changed by other tools. It never turns read-only
  mode off itself. `--i-know` overrides the refusal; only use it if you know
  what changed.
- A password for the `deck` user, so `sudo` works. In Desktop Mode, open
  Konsole and run `passwd` once.
- Network access (to clone the repository; kernel module builds also
  download sources).
- `git`, which ships with SteamOS.

## Steps (Desktop Mode)

1. Switch to Desktop Mode (Steam button → Power → Switch to Desktop) and
   open **Konsole**.
2. Clone and read what you are about to run as root (recommended):

   ```sh
   git clone https://github.com/cchulo/ally-x20-steamos.git
   cd ally-x20-steamos
   git checkout "$(git tag -l 'v*' --sort=-version:refname | head -n1)"   # newest release
   less cmd/install.sh                                                   # inspect
   sudo ./ally-x20-steamos.sh install
   ```

   The installer re-clones the same tag or branch from the same URL into
   `/var/lib/ally-x20-steamos/src` and runs everything from there. The
   clone in your home directory can be deleted afterwards.

3. Reboot when it says so (kernel module or boot entry changes take effect
   on the next boot), then return to Game Mode.

### One-liner (discouraged)

Piping a script from the internet into a root shell means running code you
have not read. Prefer step 2. If you accept the risk:

```sh
curl -fsSL https://raw.githubusercontent.com/cchulo/ally-x20-steamos/main/bootstrap.sh | sudo sh
```

`bootstrap.sh` checks for `git`, clones the newest `v*` release tag (or the
default branch while no release exists) into a temporary directory and
runs `install` from it. To fetch something else, pass `AX20_REF` or
`AX20_REPO_URL` through sudo, e.g. `... | sudo env AX20_REF=v0.2.0 sh`.
Arguments after `sh -s --` are passed on to `install`, e.g.
`... | sudo sh -s -- --force-board` in a VM.

## Installer options

| option | effect |
|---|---|
| `--repo <url>` | clone from this URL (default: `origin` of the checkout you run it from) |
| `--ref <tag-or-branch>` | install this ref (default: the running checkout's exact tag, else its branch) |
| `--force-board` | install even though the DMI board is not `RC74XA` (VMs, testing) |
| `--repin-keys` | replace the already pinned signing keys with the checkout's `keys/` |
| `--no-apply` | only clone, pin keys and record; do not apply anything |
| `--dry-run` (global) | print every action, write nothing |

## What `install` does

1. Checks it runs as root, that read-only mode is on, and that
   `/sys/class/dmi/id/board_name` is `RC74XA`.
2. Creates the state tree under `/var/lib/ally-x20-steamos/` (shared by both
   SteamOS slots, so it survives updates).
3. Clones the repository into `/var/lib/ally-x20-steamos/src`. If that
   checkout already exists it is fetched and moved to the requested ref
   (fast-forward only; local modifications make it stop). If you are
   already running from it, nothing is cloned.
4. Pins the release signing keys from `keys/` into
   `/var/lib/ally-x20-steamos/keys` (kept on re-install unless
   `--repin-keys`); `self-update` trusts only this pinned copy. See
   [self-update.md](self-update.md).
5. Records where it came from in `state/installed-from`.
6. Copies the standalone uninstaller to `/var/lib/ally-x20-steamos/uninstall.sh`
   (it keeps working even if the checkout is deleted).
7. Runs pending `migrations/`, then `apply` (every component, every file
   recorded in the manifest), then prints `status`.

Running `install` again is safe: every step is idempotent.

## What it writes

| path | content |
|---|---|
| `/var/lib/ally-x20-steamos/src/` | the git checkout everything runs from |
| `/var/lib/ally-x20-steamos/keys/` | pinned public keys for release signatures |
| `/var/lib/ally-x20-steamos/{modules,firmware,cache,backup,log,bin}/` | built modules, downloaded firmware, caches, saved originals, logs, helper binaries |
| `/var/lib/ally-x20-steamos/state/installed-from` | `url=`, `ref=`, `commit=`, `date=`, `keys_sha256=` lines |
| `/var/lib/ally-x20-steamos/state/status.json` | last `status` result |
| `/var/lib/ally-x20-steamos/uninstall.sh` | standalone uninstaller |
| `/var/lib/ally-x20-steamos/manifest` | every file `apply` placed outside the state dir |

Files outside `/var/lib/ally-x20-steamos` are only written by `apply`, as
prefixed drop-ins recorded in the manifest. Nothing is ever written under
`/usr`.

## Checking status

```sh
ally-x20-steamos.sh status            # human-readable table
ally-x20-steamos.sh status --verbose  # plus each component's probe details
ally-x20-steamos.sh status --json     # machine-readable; also in state/status.json
ally-x20-steamos.sh probe             # has stock SteamOS caught up? (superseded|needed|unknown)
```

The header shows the version and commit, the running kernel and whether
modules are staged for it, the update policy (`block` by default), whether
a post-update reboot check is pending, the last self-update check, and
whether the audio DSP is on. Each component is `active` (installed and
intact), `stock` (not installed or drifted; the boot service re-applies),
`superseded` (stock SteamOS now provides it; remove ours with
`uninstall --superseded`), `n/a` (cannot tell on this machine) or `error`.
