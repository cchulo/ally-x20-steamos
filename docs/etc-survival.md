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
