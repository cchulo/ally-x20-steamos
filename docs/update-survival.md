# Surviving SteamOS updates

This page covers how ally-x20-steamos keeps working across SteamOS A/B
updates (plan §4), the update policy, what you see, and the two documented
exceptions to the "only add drop-ins" rule (plan §5.2 rule 3). Code:
`lib/slots.sh`, `lib/rauc.sh`, `lib/status.sh`, `components/update.sh`,
`cmd/{apply,boot,boot-entry,notify,rauc-handler,update-policy}.sh`,
`overlay/rauc/*.hook`, `overlay/systemd/*.service`.

## Read this first: `/var` is per slot, not shared

The plan assumes `/var` is shared between slots. **It is not.** Stock
SteamOS has eight partitions:

| partition | mounted at | per slot? | contents |
|---|---|---|---|
| `esp` | `/esp` | shared | `steamcl.efi` chainloader, `/esp/SteamOS/conf/{A,B}.conf` (managed by `steamos-bootconf`) |
| `efi-A`, `efi-B` | `/efi` | **per slot** | stage-2 GRUB: `/efi/EFI/steamos/grubx64.efi` and `grub.cfg` (kernel cmdline + initrd list) |
| `rootfs-A`, `rootfs-B` | `/` | **per slot** | read-only image, `/boot/vmlinuz-linux-neptune`, `/boot/initramfs-linux-neptune.img` |
| `var-A`, `var-B` | `/var` | **per slot** | 256 MiB on the Deck; also holds the `/etc` overlay upper dir `/var/lib/overlays/etc/upper` |
| `home` | `/home` | shared | everything else; SteamOS bind-mounts `/opt`, `/usr/local`, `/var/lib/flatpak`, `/var/log`, … from `/home/.steamos/offload/` |

`/dev/disk/by-partsets/{A,B,self,other,shared}/<part>` are udev symlinks to
these partitions.

What saves us is RAUC's stock post-install handler
(`steamos-customizations`' `post-install.sh`): after writing the new
rootfs it reformats the other slot's `var` and **rsyncs the booted `/var`
into it** (`rsync --archive --delete --one-file-system`), excluding only
`/boot/`, `/lib/dkms/`, `/lib/modules/`, `/lib/pacman/`,
`/lib/NetworkManager/`, `/lost+found/`, and from the `/etc` overlay upper dir
`os-release`, `rauc` and `pacman.d/gnupg`. It then runs
`steamos-finalize-install --no-kernel` in the new slot, which regenerates
its GRUB config. Consequences:

- `/var/lib/ally-x20-steamos/**` **is carried over**, but only as it was
  at the moment of that rsync. Anything written to the booted `/var` after
  it (e.g. by a handler that runs later) is lost on the new slot. Our
  post-install handler therefore writes into the new slot's `var` directly.
- Our `/etc` drop-ins are carried over too (they live in the overlay upper
  dir) **except anything under `/etc/rauc/`**: the new slot boots with a
  stock `system.conf`, so the RAUC registration must be redone for every
  slot (post-install does it for the new slot, the boot service repairs it).
- The boot entry (`grub.cfg` on the new slot's `efi`) is regenerated from
  stock, so our cmdline/initrd change is gone and must be re-applied.
- `var` is only 256 MiB on the Steam Deck (TODO(vm): size on the X20 image).
  That is too small for kernel headers, build trees, a gamescope build and
  a git checkout, and every byte is copied on each update.

**Design risk and recommendation.** Keep the code's canonical path
`/var/lib/ally-x20-steamos`, but make it a symlink to
`/home/.ally-x20-steamos` (shared, large, untouched by updates; same idea
as SteamOS's own `/home/.steamos/offload`). The rsync copies the symlink as
a symlink, so both slots always see the same state, backups and modules,
and nothing has to be staged across slots. This needs a change to
`lib/common.sh`/bootstrap (not part of this package); until then the code
here works with the per-slot `/var` by writing into the new slot during
post-install. `/opt` is already on `/home` via the offload bind mount
(TODO(vm): confirm on the X20 image).

## Decision taken: the state directory lives in `/home`

Because of the above, `/var/lib/ally-x20-steamos` is a relative symlink to
`/home/.ally-x20-steamos` (the same pattern SteamOS uses for
`/home/.steamos/offload`). The canonical path in code and docs stays
`/var/lib/ally-x20-steamos`; only its storage moved. Effects:

- kernel headers, module builds, the git checkout and firmware no longer
  compete for the 256 MiB `var` partition, and are not copied on every update;
- the symlink itself is a tiny file in `var`, carried over by the stock
  rsync; `apply --slot` re-creates it in the new slot's `var` regardless;
- the standalone uninstaller removes `/home/.ally-x20-steamos` and the link.

## How an update flows

```
Steam: "update available"
  └─ steamos-atomupd → rauc install <bundle>
       ├─ pre-install  = /var/lib/ally-x20-steamos/libexec/rauc-pre-install.hook
       │    1. ally-x20-steamos.sh rauc-handler pre-install
       │         self-update (if that command exists; once, then re-exec)
       │         incoming kernel version?  ── unknown → let it through
       │         modules for it present?   ── yes → let it through
       │         rebuild --kver (if that command exists; failure cached per kver+commit)
       │         still none → update-policy:
       │              block   → exit 1, RAUC aborts, state/update-blocked
       │              degrade → exit 0, state/pending-rebuild
       │    2. chained stock pre-install handler (if system.conf had one)
       ├─ RAUC writes the new rootfs to the other slot
       └─ post-install = /var/lib/ally-x20-steamos/libexec/rauc-post-install.hook
            1. chained stock post-install handler (rsync /var, GRUB for new slot);
               if it fails we stop and return its status
            2. ally-x20-steamos.sh rauc-handler post-install
                 mount the new slot as a composite root under /run/ally-x20-steamos/slot-<X>
                   (rootfs ro, its var, /etc overlay on that var, its efi, shared esp/home/opt)
                 stage modules for its kernel into its var if missing
                 apply --slot <root>  (all components; update re-registers RAUC
                                       and re-applies the boot entry there)
                 write state/pending-reboot-check in the new slot
               failures are logged, never fail the update
reboot into the new slot
  └─ ally-x20-steamos.service  (system, before the display manager, ≤15 s)
       ally-x20-steamos.sh boot:
         apply --missing-only     re-apply drifted components (files, RAUC block, boot entry)
         modules for uname -r?    no → systemd-run a detached rebuild (next boot)
         probes → state/status.json
         summary → state/notify (consumes pending-reboot-check)
  └─ ally-x20-steamos-notify.service  (user, after login)
       one notification: updated / re-applied / pending rebuild / blocked / superseded
```

The hooks are self-contained: if the checkout is missing they still run the
chained stock handler and never block, so ally-x20-steamos cannot be the
reason an update fails except through the explicit `block` policy.

### The pre-install gate may not know the kernel version

SteamOS bundles carry `rootfs.img.caibx` (a casync index), not a mountable
image, so the incoming kernel version is probably not readable before
installation. `rauc_incoming_kver` honours `AX20_INCOMING_KVER` and looks
for a `kernel-version=`-style hint in the bundle manifest; otherwise the
gate lets the update through and post-install + the boot service handle
modules (the version-gated modprobe hook keeps the new kernel bootable on
stock modules). TODO(vm): list `$RAUC_BUNDLE_MOUNT_POINT` during a real
update and see whether the version can be derived (e.g. from the atomupd
manifest or the bundle's `[update] version` → `linux-neptune` package
version on the mirror). If not, `block` can only be enforced from
post-install, which cannot abort an update (the new slot is already
written).

## Update policy

```
ally-x20-steamos.sh update-policy              # show (default: block)
sudo ally-x20-steamos.sh update-policy degrade # never block updates
sudo ally-x20-steamos.sh update-policy block
sudo ally-x20-steamos.sh update-policy degrade --once   # let the next update through
```

Stored in `/var/lib/ally-x20-steamos/state/update-policy` and
`update-policy-once` (the one-shot marker is consumed only when it actually
lets an update through). Under `block`, a failed build is cached per kernel
version and checkout commit, so Steam's periodic retries do not rebuild
until `self-update` brings a new commit.

## What you see

- Known kernel: update as usual, reboot, one "re-applied" notification.
- New kernel: speakers/RGB/QAM on stock behaviour until the background
  build finishes, a notification, then a second reboot restores them.
- Blocked update (policy `block`, no fix yet): Steam reports the update
  failed; the notification after the next boot says why and how to
  override.
- Something superseded by SteamOS: a notification; nothing is removed
  automatically (`uninstall --superseded`).

`state/status.json` (written by `apply` and `boot`, via
`status_write_json` in `lib/status.sh`) has the same information for
scripts and the future Decky plugin.

## Exception 1: the boot entry (`lib/slots.sh`, `boot-entry` command)

The ACPI override needs an early initrd and possibly kernel args. On
SteamOS the per-slot boot entry is `/efi/EFI/steamos/grub.cfg`:

```
steamenv_boot	linux /boot/vmlinuz-linux-neptune console=tty1 ... amd_iommu=off <our args>
initrd	${cmdpath}/ally-x20-steamos-acpi.img /boot/amd-ucode.img /boot/initramfs-linux-neptune.img
```

The cpio lives on the slot's `efi` partition and is addressed through
GRUB's `$cmdpath`, because the menuentry sets `root` to the rootfs.
TODO(vm): confirm `$cmdpath` under steamcl, and that the kernel finds the
tables when our cpio precedes `amd-ucode.img` (`dmesg | grep 'Table Upgrade'`).
A systemd-boot style `/esp/loader/entries/*-<slot>.conf` is supported too,
but stock SteamOS does not use it.

Rules (plan §5.2 rule 9), all covered by `tests/lib/slots.bats`:

- The untouched entry is saved to `/var/lib/ally-x20-steamos/backup/<slot>/`
  with a `.sha256`, and refreshed whenever we find the entry unmodified
  again (SteamOS regenerated it).
- Our change only prepends `# ally-x20-steamos…` marker lines, appends args
  to kernel lines and inserts one initrd token. Before writing, the result
  is stripped in memory and must reproduce the original byte-for-byte.
- Writes are temp file + rename on the same filesystem, then `sync`.
- The initrd must exist, be non-empty and be an uncompressed newc cpio
  before the entry points at it.
- Restore uses the hash-verified backup; if it is missing, corrupt or older
  than the entry, the original is regenerated by stripping our edits (the
  standalone uninstaller does the same, also when the whole state directory
  is gone, e.g. after a factory reset; see [uninstall.md](uninstall.md)).

Components declare what they want with
`ally-x20-steamos.sh boot-entry set --arg <a> --initrd <path>` (or
`slots_desired_set`); the `update` component reconciles it on every apply,
in post-install for the new slot and at boot.

## Exception 2: `/etc/rauc/system.conf` (`lib/rauc.sh`)

RAUC reads one `system.conf` and has no `conf.d`. We append one delimited
block and leave the stock lines alone:

```
# >>> ally-x20-steamos managed block (sep=0); original saved as /var/lib/ally-x20-steamos/backup/rauc/system.conf; ...
# stock handlers are chained, see /var/lib/ally-x20-steamos/state/rauc-chain
[handlers]
pre-install=/var/lib/ally-x20-steamos/libexec/rauc-pre-install.hook
post-install=/var/lib/ally-x20-steamos/libexec/rauc-post-install.hook
# <<< ally-x20-steamos
```

RAUC parses the file with GLib's GKeyFile, which merges a repeated
`[handlers]` group and lets the last value of a key win. TODO(vm): verify
with SteamOS's RAUC (`rauc status` still works; our hooks run during an
update). The stock `post-install=` (and `pre-install=` if present) is
recorded in `state/rauc-chain` and run by our hooks. Removal restores the
saved original after checking its sha256; if the stock file changed under
our block, only the block is removed. icedream/steamos-permanent-mods
edits the same key in place instead, which is what we avoid.

## VM checklist (update survival)

1. Install, `systemctl status ally-x20-steamos.service`, `rauc status`.
2. Check the block is in `/etc/rauc/system.conf` and the boot entry carries
   the change (`ally-x20-steamos.sh boot-entry show`).
3. `steamos-update` (beta channel) and watch `journalctl -u rauc -f`: our
   pre-install and post-install lines, the chained stock handler.
4. Before rebooting: mount `/dev/disk/by-partsets/other/{var,efi}` and
   check `state/pending-reboot-check`, the new `grub.cfg`, our files.
5. Reboot, check the notification, `status.json`, `rauc status`.
6. Fill in [etc-survival.md](etc-survival.md).
7. Offline update with a new kernel under `block` and under
   `degrade --once`.
8. `uninstall`: `system.conf` and `grub.cfg` byte-identical to the saved
   originals.
