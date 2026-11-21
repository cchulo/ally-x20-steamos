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
| `asus-armoury` | X20 (`RC74XA`) PPT power limits for Steam's TDP slider, which is off because BIOS `RC74XA.303` ignores PPT writes; kept for a later BIOS ([power.md](power.md)) | `make M=drivers/platform/x86 asus-armoury.ko` |

Nothing else in the kernel is touched. The rest of the system keeps
Valve's stock modules.

## Supported kernels

**Only the SteamOS stable channel is supported.** The patches are written
for the kernels SteamOS stable ships, and CI builds a complete set of
modules for each kernel listed in `build/kernels.txt`, attached to every
release.
Those builds are strict: if one patch does not apply, the build fails and
no artifact is published.

On the beta, preview and main channels the kernel is newer and changes
without notice. Patches may stop applying there. Nothing prevents you from
using those channels, but:

- there is usually no release artifact for their kernels, so the modules
  are built on the device, and that build may be [partial](#partial-builds):
  the modules whose patches still apply are built, the others stay stock;
- other components may fail to apply and are then skipped (see
  [architecture.md](architecture.md), "When a component fails");
- **no support is provided** for anything other than SteamOS stable. A
  problem report from another channel is welcome as information, but a fix
  for it is not promised.

## Where it lives

| Path | What |
|---|---|
| `/etc/ally-x20-steamos/modules/<uname -r>/<module>.ko.zst` | patched modules for one kernel |
| `/etc/ally-x20-steamos/modules/<uname -r>/BUILD-INFO` | how they were built: kernel, vermagic, header source, source commit, patch hashes, and what happened to every patch and module ([keys](#build-info)) |
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

A staged or cached build is used only if its BUILD-INFO lists exactly the
patches the installed checkout ships, with matching hashes. Otherwise it is
refused and the next source is tried: the release matching the checkout's
`VERSION`, then the latest release, then a container build. `self-update`
runs this staging step itself after switching releases, so a release that
changes only a patch gets its new module without any manual step. Before
v0.1.8 only the kernel version was compared, and such a release kept the
previous build until `rebuild --force --source release`.

A release artifact is never partial: a tarball whose BUILD-INFO says
`partial=1` is refused. A container build on the device may be partial
(next section). A staged partial build counts as the build for that kernel,
so it is made once and not again on every boot. It is built again when the
checkout's patches change, when the options in the module lists change
(BUILD-INFO records `lists_sha256` for that), or with `rebuild --force`.

## Partial builds

Up to and including v0.1.11 the build stopped at the first patch that did
not apply. On a newer kernel one stale audio patch therefore also blocked
the unrelated joystick-ring fix (issue #68). Now a **local** build degrades
per module instead. The rules, in the order the build script applies them
(`build/build-modules.sh --partial`, which is what `rebuild` uses for a
container build):

1. **Patches are tried in file-name order on one source tree.** A patch
   that is already in Valve's tree is skipped (`already-upstream`). A patch
   that applies is applied. A patch that does not apply is recorded as
   `failed` and left out; the tree is unchanged by it.
2. **A later patch is checked against the tree as it is then.** So a patch
   that changes lines introduced by a missing patch does not apply either
   and is `failed` too: `git apply` accepts no fuzz, the context must match
   exactly. A patch that needs a missing patch for its *behaviour* without
   touching its lines says so in the list with `needs=<patch>`; it is then
   `skipped` without being tried.
3. **Per module, each patch is `required` (the default) or `optional`**
   (fourth field of a `modules*.list` line). If a required patch is not in
   the build, the module is not built and stays **stock**. If only optional
   patches are missing, the module is built without them. If nothing is
   left to apply for a module (the rest is upstream, the optional ones
   failed), it stays stock too: a rebuilt copy would be the stock module.
4. **Modules that share patched code are built together or not at all.**
   For every file an applied patch changes, the modules listed for the
   applied patches touching that file form a set. If one of them stays
   stock, the others stay stock as well: they would be built against a
   changed header or exported function that the stock module does not have.
   The headers of a patch nobody uses are not put in front of the kernel's.
5. **A module that fails to compile, or fails the vermagic or symbol
   check,** with the patches that did apply stays stock (and so do the
   modules tied to it by rule 4).
6. The modules that were built are staged as usual. BUILD-INFO gets
   `partial=1` and one entry per patch and per module. `load-or-fallback`
   loads the stock module for every module without a `.ko.zst`, as it
   always did.

What the lists say today (`patches/kernel/modules*.list`):

| Module | Required | Optional |
|---|---|---|
| `hid-asus-ally` | `0010`, `0011` (the ring LED fix and the effect attributes Steam uses) | `0012` (X20 top-right key), `0013` (unbind fix), `0014` (rumble scale), `0015` (key hold; `needs=0012`), `0016` (Xbox-button light; `needs=0011`) |
| every audio module, `asus-armoury` | all of their patches | none |

The audio and power modules have no optional patches: each is built with
all of its patches or left stock. Independent audio modules are not tied to
each other beyond rule 4, so on an unsupported kernel one audio module can
be patched while another is stock; whether the speakers then work is not
known for any such combination.

What was checked, and what was not: the rules are covered by the tests in
`tests/build/build-modules.bats` with made-up sources and patches. The
patch step of the build script was additionally run, in partial mode and
without compiling anything, on the real files the patches touch, fetched
from Valve's public mirror on 2026-11-20:

| Source tag | Result |
|---|---|
| `7.2.7-valve2` (`hid-asus-ally.c` only) | all seven HID patches apply. With `0012` made to fail: `0013` fails on context, `0015` is skipped (`needs=0012`), and `0010`, `0011`, `0014`, `0016` apply |
| `7.3.1-valve3` (issue #68; every patch) | `0001`, `0003`–`0008` and `0020` are already upstream. `0002` does not apply: that tree has the `RC74XA` entry already, written differently. `0010`, `0011`, `0016` apply; `0012`, `0013`, `0014` do not; `0015` is skipped. Plan: `hid-asus-ally` patched (ring fix, effect attributes, Xbox-button light), `snd-acp-config` stock, the other six modules superseded |

The reporter of issue #68 built `0010`, `0011`, `0014`, `0016` by hand on
`7.3.1-valve3` and found the ring fix working; here `0014` did not apply to
that tag (the tree already has its own rumble limit,
`ALLY_X_FF_MAX_INTENSITY`), and the difference was not investigated. No
partial build has been compiled or loaded by the project itself. TODO(hw):
build and boot a partial set on a device.

`status` shows a partial build as it is (an example, not captured from a
device):

```
  modules staged for it:   partial (1 patched, 1 stock, 6 already in this kernel)
...
modules          partial     applied     patched kernel modules ...

Kernel modules for 7.3.1-valve3-1-neptune-73-g6fbfd992c8fe:
  hid-asus-ally                patched (without 0012-... 0013-... 0015-...)
  snd-acp-config               stock: 0002-...patch does not apply to the 7.3.1-... source
  snd-soc-acpi-amd-match       stock (already fixed in this kernel)
```

The component status is `partial` when at least one module is patched and
at least one stays stock, `stock` when the build could not patch any.

`rebuild --strict` makes a local build fail on the first patch that does
not apply, like CI does.

### The update gate and partial builds

Under update policy `block` (the default), a SteamOS update is held back
when the incoming kernel cannot get patched modules. A partial build does
not satisfy that gate: `block` exists so that an update does not silently
cost you the speakers. With `update-policy degrade` (or `degrade --once`)
the update goes through and the partial build is used. On the beta, preview
and main channels you will therefore want `degrade`.

### BUILD-INFO

`key=value` lines. Besides the provenance keys (`kver`, `vermagic`,
`header_*`, `source_*`, `ax20_commit`, `build_date`, `container_*`):

| Key | Value |
|---|---|
| `format` | `2` since partial builds; `1` before (no `partial`, `lists_sha256`, `.reason`, `.without`, `=stock`) |
| `partial` | `1` if a patch was left out or a module stays stock, else `0` |
| `lists_sha256` | digest of the normalised `modules*.list` lines, options included |
| `patch.<file>` | sha256 of the patch file the build read (recorded for every listed patch, whatever its status) |
| `patch.<file>.status` | `applied`, `already-upstream`, `failed` (does not apply) or `skipped` (`needs=` not met) |
| `patch.<file>.reason` | for `failed` and `skipped`: why |
| `module.<name>` | sha256 of `<name>.ko.zst`, or `superseded` (every patch is already in Valve's tree), or `stock` (not built) |
| `module.<name>.reason` | for `stock`: why |
| `module.<name>.without` | for a built module: the optional patches it lacks |

### Podman storage

`rebuild` runs as root, so the container build uses root's podman storage,
`/var/lib/containers`. On SteamOS `/var` is a small per-slot partition
(256 MiB on the Deck layout), and the build image does not fit: the user
who reported issue #68 got `no space left on device` on SteamOS 3.10.1
until podman was pointed at `/home`. This is that user's report; the
project has not reproduced it (TODO(hw): check where `/var/lib/containers`
lives on the X20 and how much room the image needs). To move the storage,
write a storage configuration and name it in the environment of the
command:

```sh
sudo mkdir -p /home/.ally-x20-steamos-containers
printf '[storage]\ndriver = "overlay"\ngraphroot = "/home/.ally-x20-steamos-containers/storage"\nrunroot = "/run/containers/storage"\n' \
  | sudo tee /home/.ally-x20-steamos-containers/storage.conf >/dev/null
sudo CONTAINERS_STORAGE_CONF=/home/.ally-x20-steamos-containers/storage.conf \
  ./ally-x20-steamos.sh rebuild --source container
```

`CONTAINERS_STORAGE_CONF` is podman's own variable. The directory is yours:
`uninstall` does not remove it. The boot service's detached rebuild does
not see the variable; on a device that needs it, run `rebuild` by hand
after a kernel change.

## What happens on a new SteamOS kernel

After an update that changes the kernel, the speakers and RGB use stock
behaviour until modules for the new kernel exist. If the device is online,
they are fetched or built in the background and a notification asks for
one more reboot. Offline, they wait for a connection or a manual rebuild.
`ally-x20-steamos status` shows `modules: stock` with "pending rebuild"
meanwhile. If no release has modules for that kernel and some patches do
not apply to it, the background build is [partial](#partial-builds).

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
sudo ally-x20-steamos rebuild --strict                 # fail instead of making a partial build
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
