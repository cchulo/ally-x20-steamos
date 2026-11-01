# Uninstall and audit

`ally-x20-steamos` promises a byte-identical system after removal. This page
describes how that is achieved, what the guarantees are, and how to run the
uninstaller from any state, including without the git checkout.

## Quick reference

```sh
sudo ally-x20-steamos.sh uninstall --dry-run     # show every action, change nothing
sudo ally-x20-steamos.sh uninstall               # remove everything, prompt first
sudo ally-x20-steamos.sh uninstall --superseded  # only components stock SteamOS now provides
sudo ally-x20-steamos.sh uninstall --component hdr
sudo ally-x20-steamos.sh audit                   # manifest vs filesystem; exit 1 on drift

# Without the checkout (recovery media, other slot, broken install):
sudo sh /var/lib/ally-x20-steamos/uninstall.sh --yes
sudo sh /var/lib/ally-x20-steamos/uninstall.sh --root /mnt/other-slot --yes
```

## Two layers

1. **`cmd/uninstall.sh`** (needs the checkout): decides *which* components to
   remove (`--superseded` runs every probe and selects those reporting
   `superseded`), runs each component's `_remove` hook (stop services, drop
   caches), then calls the standalone script.
2. **`uninstall/uninstall.sh`**, copied to `/var/lib/ally-x20-steamos/uninstall.sh`
   at install time: POSIX `sh`, depends only on coreutils, awk, sed, grep,
   find and a sha256 tool. It parses the manifest itself, so it keeps working
   when the checkout is deleted, when `jq`/`python3` are unavailable, and from
   SteamOS recovery media. It parses its whole body before running (`main` at
   the end), so deleting its own file mid-run is safe.

## What the standalone uninstaller does, in order

0. **Drop the `power` bind mount** (live root only, when `power` is
   selected or everything is removed): stop
   `ally-x20-steamos-power-devices.service` and unmount every layer on
   `/usr/share/steamos-manager/devices` whose source is under
   `/ally-x20-steamos/` (our copy in `/run`). Anyone else's mount there is
   left alone. Nothing under `/usr` is written either way; see
   [power.md](power.md).
1. **Restore saved originals** from `/var/lib/ally-x20-steamos/backup/<id>/`
   (the two documented exceptions: boot entries and the RAUC
   `system.conf` block). Each backup has `original` and `meta`
   (`path=`, `sha256=` of the original, `type=file|block`, optional
   `component=`).
   - `type=file`: restored byte-for-byte, only if `original` still hashes to
     the recorded sha256. A corrupt or missing backup is reported, never
     guessed.
   - `type=block`: the `# >>> ally-x20-steamos` … `# <<< ally-x20-steamos`
     block is stripped from the live file. If the result equals the saved
     original, the file is back to stock; if not (Valve changed it since),
     the stripped file is kept and a warning says so.
   - Backups pointing under `/usr`, `/dev`, `/proc`, `/sys`, `/run` or at a
     relative path are refused.
2. **Walk the manifest newest-first** and remove files and symlinks:
   - a file is removed only if its sha256 still equals what we wrote;
     otherwise it is skipped (reported) unless `--force`;
   - a symlink is removed only if its target still matches; the target is
     never followed;
   - a path that is missing is fine ("already gone"), so a partial manifest
     from an interrupted install is handled.
3. **Remove directories** we created, deepest first, only while empty.
   Top-level and system directories are never removed even if a manifest
   claims we created them.
4. **Update the manifest**: entries of handled components are dropped unless
   the file still exists (skipped), so a re-run is a no-op and `audit` stays
   truthful.
5. **Remove the state directory** `/var/lib/ally-x20-steamos` (and
   `/opt/ally-x20-steamos`) on a full run, unless `--keep-state` or anything
   was skipped (then it is kept so the skipped items stay inspectable).
6. On the live root: `depmod -a`, `ldconfig`, `systemd-hwdb update`,
   `systemctl daemon-reload`; reboot only with `--reboot`.

Exit codes: `0` everything removed, `1` finished with skipped items (the
messages say why), `2` usage error or fatal condition.

## Deny-list (applied even to manifest entries)

A manifest can be corrupted or crafted. Regardless of what it says, the
uninstaller refuses to touch:

- anything under `/usr`, `/boot`, `/dev`, `/proc`, `/sys`, `/run`;
- `/etc/fstab`, `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/hostname`,
  `/etc/machine-id`;
- `/etc/rauc/**` (only the delimited block restore may change
  `system.conf`);
- Steam data (`~/.steam`, `~/.local/share/Steam`);
- the ESP (`/efi`, `/esp`) except files whose name contains
  `ally-x20-steamos`;
- stock systemd `.wants`/`.target` wiring;
- relative paths, paths containing `..`;
- **any path that does not contain `ally-x20-steamos` or `x20`** in its
  name. Every file this project installs carries that marker (drop-ins are
  prefixed; the InputPlumber profile is `50-rog_xbox_ally_x20.yaml`; the
  PipeWire files are `50-x20-*`; the ESP initrd is
  `ally-x20-steamos-acpi.img`). A component that installs a file without the
  marker is a bug: `tests/uninstall` will refuse to remove it.

Refused entries are printed as `REFUSED <path>: <reason>` and counted as
skipped.

## Audit

`ally-x20-steamos.sh audit [--json]` prints one line per problem:

| state | meaning |
|---|---|
| `modified` | file content differs from what we wrote (user edit, or another tool) |
| `missing` | manifest entry whose file is gone (boot service will re-apply) |
| `unexpected` | a file named like ours in a drop-in directory or `~/.config` that is not in the manifest |

Clean audits print a one-line summary and exit 0; any problem exits 1.

## Tests

`tests/uninstall/standalone.bats` covers the broken states from the plan
(§5.2 rule 6): partial manifest, modified files, mid-update, running from the
state-dir copy with the checkout gone, foreign symlink targets, crafted
manifests against the deny-list, corrupt/missing backups, block stripping
with and without upstream changes, byte-identical before/after snapshots and
idempotent re-runs. `tests/uninstall/cmd.bats` covers `--superseded`,
component hooks, `--dry-run`, the read-only-root refusal and `audit`.
