# Patched kernel modules

Component: `modules` (plan §3, §4.2, §4.3).

## What gets rebuilt

Only the kernel modules that the patches in `patches/kernel/` change, as
listed in `patches/kernel/modules*.list`. Today that is:

| Module | Fixes | Built with |
|---|---|---|
| `snd-soc-acpi-amd-match` | X20 (`RC74XA`) speaker link layout | `make M=sound/soc/amd/acp` |
| `snd-acp-config` | ACP config quirk (alternative to the ACPI override) | `make M=sound/soc/amd` |
| `hid-asus-ally` | joystick ring LEDs visible to Steam, effects, X20 top-right (capture) key `0xa0` | `make M=drivers/hid` |

Nothing else in the kernel is touched. The rest of the system keeps
Valve's stock modules.

## Where it lives

| Path | What |
|---|---|
| `/etc/ally-x20-steamos/modules/<uname -r>/<module>.ko.zst` | patched modules for one kernel |
| `/etc/ally-x20-steamos/modules/<uname -r>/BUILD-INFO` | how they were built: kernel, vermagic, header source, source commit, patch hashes |
| `/etc/ally-x20-steamos/load-or-fallback` | the loader used by the modprobe hooks |
| `/etc/modprobe.d/ally-x20-steamos-modules.conf` | one `install <module> ... load-or-fallback <module>` line per module, generated from the lists |
| `/var/lib/ally-x20-steamos/cache/` | downloaded release artifacts and build caches |

Nothing is written under `/usr`, and `depmod` is not run (it would write
under the read-only `/usr/lib/modules`). The hooks need neither.

## How loading works

When the kernel or udev asks for one of these modules, modprobe runs
`load-or-fallback <module>`. It loads the patched module only when
`/etc/ally-x20-steamos/modules/$(uname -r)/<module>.ko.zst` exists and
its vermagic matches the running kernel. In every other case (no build for
this kernel, mismatch, load failure) it loads Valve's module with
`modprobe --ignore-install`. An unknown kernel therefore always boots with
stock behaviour. Each decision is logged: `journalctl -t ally-x20-steamos`.

The patched modules are unsigned. SteamOS kernels have `CONFIG_MODULE_SIG`
on but not enforced, so they load and the kernel is marked tainted (`E`).

## When modules are fetched or built

For a kernel version, the sources are tried in this order:

1. **cache**: a build already staged, or a downloaded release artifact;
2. **release**: `modules-<uname -r>.tar.zst` from the project's GitHub
   release, checked against its `.sha256`;
3. **container**: a local build in the Arch container with podman
   (needs a network connection; takes a few minutes).

This runs from the RAUC post-install hook for the new slot's kernel, and
from the boot service when the running kernel has no build. Failures are
logged and never block an update or a boot.

## What happens on a new SteamOS kernel

After an update that changes the kernel, the speakers and RGB use stock
behaviour until modules for the new kernel exist. If the device is online,
they are fetched or built in the background and a notification asks for
one more reboot. Offline, they wait for a connection or a manual rebuild.
`ally-x20-steamos status` shows `modules: stock` with "pending rebuild"
meanwhile.

If Valve's new kernel already contains a patch, the build detects it,
skips that patch, and marks the module `superseded` in `BUILD-INFO`. Once
every module is superseded, or the stock modules contain the fixes, the
status becomes `superseded` and you can remove the component with
`ally-x20-steamos uninstall --superseded`.

## Forcing a rebuild

```sh
sudo ally-x20-steamos rebuild                          # running kernel
sudo ally-x20-steamos rebuild --kver <uname -r>        # another kernel, e.g. the other slot
sudo ally-x20-steamos rebuild --source container       # skip cache and release
sudo ally-x20-steamos rebuild --channel jupiter-staging
```

`rebuild` runs `self-update` first when available and online, so a fix
for a new kernel published in this repository is picked up. It prints
`BUILD-INFO` on success. Reboot to use the new modules. Build details:
[`build/kernel-sources.md`](../build/kernel-sources.md).

## Kernel lockdown

If kernel lockdown is in `integrity` or `confidentiality` mode
(`/sys/kernel/security/lockdown`), for example with Secure Boot enforcing,
unsigned modules cannot load. The status then reports `stock` with a
lockdown explanation and the stock modules stay in use; there is no
retry loop. Valve's 7.2 kernel is built with `LOCK_DOWN_KERNEL_FORCE_NONE`,
so this is not expected on the X20.

## Known limitations

- **Modules loaded from the initramfs** never see the modprobe.d hook,
  which is read from the root filesystem. If `snd-acp-config` (or another
  listed module) is in SteamOS's initramfs, the stock one is already loaded
  before `/var` is mounted, and the helper does nothing because the module
  is present. TODO(hw): check `lsinitcpio` on the X20. For that reason the
  ACPI initrd override stays the default fix for the ACP config flag, and
  patch 0002 is the alternative.
- Dependencies of a patched module are loaded through modprobe first; a
  stock module that *depends on* a patched one (for example the SOF/ACP
  drivers that use the match tables) pulls it in through the same hook.
  TODO(vm): confirm kmod runs install hooks for dependencies on SteamOS.
- The modules must be built for the exact `uname -r`, including Valve's
  `-g<commit>` suffix.

## Why the boot-time files live under `/etc/ally-x20-steamos`

Measured on the X20: udev loads `hid-asus-ally` and `snd-acp-config` before
`/var` and `/home` are mounted. The state directory
(`/var/lib/ally-x20-steamos`, a symlink into `/home`) therefore does not
exist yet, and a hook pointing there failed with exit 127, which left the
device with **no** driver at all. The modprobe helper, the staged
`<kver>/*.ko.zst` and the amplifier firmware are therefore installed under
`/etc/ally-x20-steamos/`, which the initramfs sets up before systemd starts
and whose upper directory is rsynced to the other slot on every update. In
addition, every generated `install` line falls back to
`modprobe --ignore-install` on its own if the helper is missing or fails.
