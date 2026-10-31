# /etc survival across SteamOS updates

Which of our `/etc` drop-ins does a SteamOS A/B update carry to the new
slot on its own, and which does our RAUC post-install hook or boot service
have to restore (plan §4.1, §5.1b, §6 check 4)? This page holds the
**measured** answer. Nothing here may be filled in from assumptions.

## How to measure

In the VM (see [`docs/vm-testing.md`](vm-testing.md)), on a clean snapshot:

```sh
sudo vm/guest/measure-etc-survival.sh before        # plants markers, records sha256 of /etc
sudo steamos-select-branch beta && sudo steamos-update && sudo reboot
sudo vm/guest/measure-etc-survival.sh after > etc-survival-run.md
sudo vm/guest/measure-etc-survival.sh cleanup
```

Run it twice: once with nothing of ours installed (what SteamOS does by
itself) and once after `ally-x20-steamos.sh install`, passing
`--restored <file>` with the paths the hook/service logged as re-applied.
Paste the marker rows into the table below and record the builds.

## Results

Measured from: _BUILD_ID before_ → _BUILD_ID after_, kernel _before_ → _after_, date _YYYY-MM-DD_.

| path | survives update? | restored by hook/service? | notes |
|---|---|---|---|
| `/etc/ally-x20-steamos-probe.d/marker-plain` | TODO(vm) | | plain file in a new directory |
| `/etc/ally-x20-steamos-probe.d/subdir/marker-nested` | TODO(vm) | | nested directory |
| `/etc/ally-x20-steamos-probe.d/marker-mode600` | TODO(vm) | | mode preserved? |
| `/etc/ally-x20-steamos-probe.d/marker-symlink` | TODO(vm) | | symlink |
| `/etc/modprobe.d/ally-x20-steamos-probe.conf` | TODO(vm) | | modules component |
| `/etc/environment.d/99-ally-x20-steamos-probe.conf` | TODO(vm) | | audio UCM env |
| `/etc/ld.so.conf.d/99-ally-x20-steamos-probe.conf` | TODO(vm) | | HDR libdisplay-info overlay |
| `/etc/udev/rules.d/99-ally-x20-steamos-probe.rules` | TODO(vm) | | udev rules |
| `/etc/udev/hwdb.d/99-ally-x20-steamos-probe.hwdb` | TODO(vm) | | InputPlumber autostart hwdb |
| `/etc/systemd/system/ally-x20-steamos-probe.marker` | TODO(vm) | | our units |
| `/etc/inputplumber/devices.d/ally-x20-steamos-probe.marker` | TODO(vm) | | InputPlumber profile |
| `/etc/rauc/ally-x20-steamos-probe.marker` | TODO(vm) | | RAUC hook / system.conf block |
| `/etc/atomic-update.conf.d/ally-x20-steamos-probe.marker` | TODO(vm) | | keep-list directory itself |

Stock `/etc` changes reported by the same run (counts and lists from the
`after` output): TODO(vm).

## Conclusions

TODO(vm): which paths the post-install hook must copy, and whether a keep
list in `/etc/atomic-update.conf.d/` would make that unnecessary.

## Expectation from the slots/RAUC analysis (to be confirmed by the measurement above)

Template to fill in from the VM (plan §6 check 4). Expectation from the stock
RAUC post-install handler: the whole `/etc` overlay upper dir
(`/var/lib/overlays/etc/upper`) is rsynced into the new slot's `var`,
except `os-release`, `rauc/` and `pacman.d/gnupg`. Measure it; do not
assume it.

## How to measure

1. Fresh VM snapshot, install ally-x20-steamos, note the SteamOS build:
   `cat /etc/os-release | grep BUILD_ID`, `steamos-bootconf this-image`.
2. Record before: `ally-x20-steamos.sh apply --verify-only`,
   `sha256sum` of every path below, `ls -la /var/lib/overlays/etc/upper`.
3. For a "SteamOS alone" run, temporarily take our block out of RAUC's
   config (`sudo cp /var/lib/ally-x20-steamos/backup/rauc/system.conf
   /etc/rauc/system.conf && sudo systemctl try-restart rauc`), then update
   with `steamos-update` and reboot.
4. Record after, on the new slot, before `ally-x20-steamos.service` runs
   (boot with `systemd.mask=ally-x20-steamos.service`):
   present? same sha256?
5. Repeat with our handlers registered and note which paths the
   post-install handler or the boot service had to restore
   (`journalctl -u ally-x20-steamos -b`, `state/status.json` → `reapplied`).

## Results

SteamOS build before → after: `TODO(vm)` → `TODO(vm)`; date: `TODO(vm)`.

| path | owner component | survives on its own? | restored by | notes |
|---|---|---|---|---|
| `/etc/rauc/system.conf` (our block) | update | expected **no** (rsync excludes `etc/upper/rauc`) | post-install (new slot) / boot service | TODO(vm) |
| `/etc/systemd/system/ally-x20-steamos.service` | update | expected yes | | TODO(vm) |
| `/etc/systemd/system/multi-user.target.wants/ally-x20-steamos.service` | update | expected yes | | TODO(vm) |
| `/etc/systemd/user/ally-x20-steamos-notify.service` | update | expected yes | | TODO(vm) |
| `/etc/systemd/user/default.target.wants/ally-x20-steamos-notify.service` | update | expected yes | | TODO(vm) |
| `/etc/modprobe.d/ally-x20-steamos.conf` | audio / modules | expected yes | | TODO(vm) |
| `/etc/environment.d/90-ally-x20-steamos.conf` | audio | expected yes | | TODO(vm) |
| `/etc/ld.so.conf.d/00-ally-x20-steamos.conf` | hdr | expected yes; `.updated` whiteout forces an `ldconfig` | | TODO(vm) |
| `/etc/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml` | inputplumber | expected yes | | TODO(vm) |
| `/etc/udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb` | inputplumber | expected yes; hwdb rebuilt on the new slot? | | TODO(vm) |
| `/etc/systemd/system/inputplumber.service.d/50-ally-x20-steamos.conf` | inputplumber (fallback) | expected yes | | TODO(vm) |

Other locations, same run:

| path | survives? | notes |
|---|---|---|
| `/var/lib/ally-x20-steamos/**` | expected yes (copied by the rsync, only as of that moment) | TODO(vm) |
| `/var/lib/ally-x20-steamos/backup/<slot>/` | expected yes, but describes the *old* slot's entry | TODO(vm) |
| `/opt/ally-x20-steamos/**` | expected yes (`/opt` bind-mounted from `/home/.steamos/offload/opt`) | TODO(vm) |
| `/home/**` | yes (shared partition) | TODO(vm) |
| `/efi/EFI/steamos/ally-x20-steamos-acpi.img` | expected **no** on the new slot (per-slot `efi`) | restored by `apply --slot` in post-install; TODO(vm) |
| `/efi/EFI/steamos/grub.cfg` change | expected **no** (regenerated by `steamos-finalize-install`) | restored by post-install / boot service; TODO(vm) |

Also record: the size of `var-A`/`var-B` on the X20 image
(`lsblk -o NAME,PARTLABEL,SIZE`) and how much of it we use
(`du -sh /var/lib/ally-x20-steamos`).
