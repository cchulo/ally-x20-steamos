# HDR on the X20 OLED (AMS740LS02)

Component: `hdr` ([`components/hdr.sh`](../components/hdr.sh)), plan §1.4.
Userspace only, no kernel work.

## The problem

The X20's OLED keeps its HDR static metadata (PQ, 1405 nits peak, 800 nits
frame average) and its BT.2020 colorimetry in a CTA-861 data block inside a
**DisplayID 2** extension of the EDID. There is no plain CTA-861 extension.

- **Desktop Mode (KWin)** reads HDR capability through libdisplay-info's
  `di_info_*` accessors. SteamOS 3.9 ships libdisplay-info **0.3.0**, which
  does not look inside DisplayID 2, so KDE reports `HDR: incapable`.
- **Game Mode (gamescope)** walks the EDID's CTA extension by hand and has no
  display profile for the X20, so it also sees no HDR, and the frame limiter
  only gets the two EDID modes (60 and 120 Hz).

## What we install

| Piece | Path | Fixes | When |
|---|---|---|---|
| ld.so.conf.d drop-in | `/etc/ld.so.conf.d/00-ally-x20-steamos.conf` → `/var/lib/ally-x20-steamos/lib` | Desktop Mode | always |
| libdisplay-info 0.3.0 + DisplayID 2 backport (soname `libdisplay-info.so.3`), with its `BUILD-INFO`, `di-edid-decode` and license | `/var/lib/ally-x20-steamos/lib/`, `/var/lib/ally-x20-steamos/libdisplay-info/` | Desktop Mode | downloaded from the release by `apply`; see [The Desktop Mode library](#the-desktop-mode-library) |
| gamescope X20 display profile (Lua, from PR #2493) | `/etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua` | Game Mode: HDR, 30–120 Hz, software backlight | stock gamescope lacks the profile and has the Lua helpers it calls |
| gamescope wrapper | `/var/lib/ally-x20-steamos/bin/gamescope` | runs our gamescope build, falls back to stock | only when our build exists in `/opt/ally-x20-steamos/gamescope` |
| gamescope-session user unit drop-in | `/etc/systemd/user/gamescope-session.service.d/50-ally-x20-steamos.conf` | puts the wrapper first on `PATH` for that unit only | with the wrapper |

All of these are recorded in the manifest. Nothing under `/usr` is touched.

In short: **Game Mode HDR works after a normal install** and needs nothing
else (Steam → Settings → Display → Enable HDR, then in the game). **Desktop
Mode HDR** needs the library in the second row, which the installer now
downloads for you.

Desktop Mode HDR with this library is confirmed on the owner's X20 (SteamOS
3.9.5, 2026-11-22), built by hand in the container: with the library in
place the desktop starts normally and HDR can be switched on; with it moved
aside HDR is unavailable again. `TODO(hw)`: the copy CI builds, the
automatic download and install, and the `hdr` command have not been run on
the device yet.

## The Desktop Mode library

### How it gets onto the device

It works like the kernel modules ([kernel-modules.md](kernel-modules.md)),
except that it does not depend on the kernel. It depends on the
libdisplay-info version SteamOS ships and that it replaces: 0.3.0, soname
`libdisplay-info.so.3`, pinned in [`build/hdr.lock`](../build/hdr.lock).

1. **CI builds it.** The `hdr` job of the `build-modules` workflow runs
   `build/build-hdr.sh --only libdisplay-info` in the Arch build container
   and uploads `hdr-libdisplay-info-0.3.0.tar.zst` and its `.sha256`. On a
   `v*` tag the release job attaches both to the GitHub release, next to
   the module artifacts. The tarball holds one directory,
   `libdisplay-info-0.3.0/`, with `libdisplay-info.so.0.3.0`,
   `di-edid-decode`, `BUILD-INFO` and `LICENSE`.
2. **The device fetches it.** `apply` (and so `install` and `self-update`)
   installs it when it is missing or was built from other pins or patches
   than the checkout has. Order:
   1. **cache**: the installed copy is current, or a tarball downloaded
      earlier is in `/var/lib/ally-x20-steamos/cache/artifacts/`;
   2. **release**: the release of this checkout's `VERSION`, then the
      latest release.
   The boot service does not download during boot. When the library is
   missing or from another build it starts `hdr fetch --auto` in the
   background (`systemd-run`), so a device that was offline at install
   time gets the library on a later boot.
3. **A local build is never started for you.** It downloads a build image of
   about 1 GB. Ask for it with `hdr build`.

Offline, or when the release has no such asset (every release up to v0.2.0),
nothing fails: `apply` prints one notice, Desktop Mode HDR stays off, and
everything else works.

```
ally-x20-steamos: warning: hdr: Game Mode HDR already works; this is only about Desktop Mode. The Desktop Mode library (libdisplay-info.so.3) could not be downloaded now (offline, or this release has no prebuilt copy yet). Get it with 'sudo ally-x20-steamos hdr fetch', or build it on the device with 'sudo ally-x20-steamos hdr build'. Desktop Mode HDR stays off until then
```

### The `hdr` command

```sh
ally-x20-steamos hdr status        # both modes, the library's build id and origin, what SteamOS ships
sudo ally-x20-steamos hdr fetch    # get the prebuilt library now (cache, then release)
sudo ally-x20-steamos hdr build    # build it here in a container (podman), then install it
sudo ally-x20-steamos hdr remove   # take our library out again
```

- `fetch --force` installs again even when the installed copy is current.
- `build` needs the network (the build image and the libdisplay-info
  sources) and a few minutes the first time. When run with `sudo`, podman's
  storage is put under `/var/lib/ally-x20-steamos/cache/podman`, which is on
  `/home`. Podman's default for root, `/var/lib/containers`, is on SteamOS's
  per-slot `/var` partition (about 230 MB); measured on the X20, pulling the
  Arch image there fails with "no space left on device".
  `rebuild --source container` for the kernel modules still uses podman's
  default storage and can fail the same way; it was not changed here.
- After `fetch` or `build`, log out of Desktop Mode and back in (or reboot):
  KWin loads the library when it starts.

### If Desktop Mode does not start: `hdr remove`

The library is selected system-wide, so a broken copy could keep KWin from
starting. Recovery:

1. Press **Ctrl+Alt+F3** for a text console and log in (or connect over
   SSH). Game Mode is not affected, so you can also switch back to it.
2. Run:

   ```sh
   sudo /var/lib/ally-x20-steamos/src/ally-x20-steamos.sh hdr remove
   ```

3. Switch back with Ctrl+Alt+F1 (or reboot) and start Desktop Mode.

`hdr remove` deletes our library files, runs `ldconfig`, and records the
choice: `apply`, `self-update` and the boot service leave the library out
until you run `hdr fetch` or `hdr build` again. The Game Mode profile and
the `ld.so.conf.d` drop-in stay; the drop-in then points at a directory
without libraries, which the loader ignores.

If the command itself cannot run, the same by hand:

```sh
sudo rm /etc/ld.so.conf.d/00-ally-x20-steamos.conf && sudo ldconfig
```

### What is checked before a library is installed

A file is installed only when all of this holds; otherwise the system stays
as it was:

- SteamOS ships exactly the libdisplay-info version the build replaces
  (0.3.0 with `libdisplay-info.so.3`). On another version nothing is
  installed. On 0.4.0 or later, which reads DisplayID 2 itself, nothing is
  installed either: our library is not needed.
- A downloaded tarball matches its `.sha256` and contains nothing outside
  `libdisplay-info-0.3.0/`.
- `BUILD-INFO` in it names this checkout's version, soname, commit, patch
  hashes and `build_id`. A build for another libdisplay-info version, or
  from other patches, is refused.
- The library file has the sha256 recorded in `BUILD-INFO`.
- The running system's loader can load the file, and the build's
  `di-edid-decode`, linked against it, reads the panel's EDID without
  crashing or missing a symbol.
- At build time (CI and `hdr build`): the tag still resolves to the pinned
  commit, every patch applies, the soname is `libdisplay-info.so.3`, and no
  symbol exported by an unpatched 0.3.0 is missing. A build that fails any
  of these produces no artifact.

The files are installed through the manifest (component `hdr`), so
`uninstall` removes them and `status` verifies them. A copy installed by
hand earlier (a `build-hdr.sh --destdir` run onto the state directory) is
replaced by the checked one, and its headers and pkg-config file are
removed.

### Why two Game Mode paths

The Lua profile is enough on its own. When a known-display profile gives
`hdr.supported` and all three luminance values, gamescope does not read HDR
data from the EDID at all (`DRMBackend.cpp`: the EDID branch only runs when
`!bHasKnownHDRInfo || !ofScriptMaxCLL || ...`). Stock gamescope 3.16.30.1
already understands every field and helper the profile uses
(`software_backlight`, `zero_index`, `gamescope.modegen.adjust_front_porch`,
`calc_vrefresh`; the stock Legion Go 2 OLED profile uses the same ones) and
loads `/etc/gamescope/scripts` after its own scripts. So stock gamescope plus
the drop-in profile gets HDR and the 30–120 Hz range with no rebuild.

The custom gamescope build (stock 3.16.30.1 + PR #2493, or upstream 3.17.0) is
the plan's original route and is kept as an opt-in: it additionally reads the
HDR block from the EDID through `di_info` (useful if a future panel revision
reports different values than the profile hardcodes). It is never needed for
the X20 as long as the profile loads, and it is not built by `apply`.

The profile carries a guard: if stock gamescope already defined
`rogallyx20_oled` (Valve shipped it), our copy returns immediately.

## Research notes (2026-10-30)

| Fact | Source |
|---|---|
| libdisplay-info **0.4.0** (tag 2026-07-23, commit `c67a3e9bedb05ab61c7443704a1a107e76254595`) is the first release with DisplayID 2 CTA blocks: `7324cca displayid2: add support for CTA-861 data blocks`, `73ec53d info: search CTA blocks in DisplayID v2 extensions`. 0.3.0 is `47a5590e9c4eb35d67651b8c05a55f1a48259329` (2025-08-12). | <https://gitlab.freedesktop.org/emersion/libdisplay-info/-/tags> |
| The soname is the minor version (`soversion: version_minor` in `meson.build`): 0.3.0 → `libdisplay-info.so.3`, 0.4.0 → `.so.4`. | libdisplay-info `meson.build` |
| SteamOS 3.9 ships `libdisplay-info-0.3.0-1` (files `libdisplay-info.so.0.3.0`, `.so.3`, `.so`, `pkgconfig/libdisplay-info.pc`). | `steamdeck-packages.steamos.cloud/archlinux-mirror/holo-3.9/os/x86_64/` and `extra-3.9` |
| SteamOS 3.9 ships gamescope **3.16.30.1-2** (jupiter-3.9, 2026-10-21); `jupiter-main` has **3.17.0-1** (2026-10-23). | `.../archlinux-mirror/jupiter-3.9/os/x86_64/`, `.../jupiter-main/os/x86_64/` |
| gamescope tag `3.16.30.1` = `d93118d95c786702e588973f7c4a400356897f1d` (2026-10-18); `3.17.0` = `e6674a98118ca7b098b98a3874b8f195ae1bf750` (2026-10-23) and contains the PR #2493 merge `74a06ff`. | <https://github.com/ValveSoftware/gamescope/tags> |
| PR #2493 (merged 2026-10-18) has three commits: `03f38b0` DRMBackend reads HDR/colorimetry with `di_info_get_hdr_static_metadata` / `di_info_get_supported_signal_colorimetry` and raises the libdisplay-info minimum to 0.2.0; `e93f8df` adds `scripts/00-gamescope/displays/asus.rogallyx20.oled.lua` (matches EDID vendor `SDC`, product `0x4501`; 30–120 Hz VFP table; content-driven PQ; 1405/800/0 nits); `9c179af` sets `software_backlight`. All three apply unchanged to 3.16.30.1. | <https://github.com/ValveSoftware/gamescope/pull/2493> |
| The string `AMS740LS02` appears only in commit messages, not in code. The probe therefore looks for the Lua profile, and accepts the panel name in the binary only as a fallback signal. | same |
| Stock gamescope links libdisplay-info **statically** from its own submodule (pinned at 0.4.0 `c67a3e9b` in both 3.16.30.1 and 3.17.0). The package has no libdisplay-info dependency and the binary's `NEEDED` list does not include it. So `ld.so.conf.d` never affects stock gamescope; stock 3.16.30.1 already contains a DisplayID-capable parser but its `DRMBackend` only walks the CTA extension. | `gamescope-3.16.30.1-2-x86_64.pkg.tar.zst` (`.PKGINFO`, `strings usr/bin/gamescope`) |
| `gamescope-session.service` (user unit, from the `gamescope` package) runs `ExecStart=/usr/lib/steamos/gamescope-session`, a bash script ending in `exec gamescope --generate-drm-mode fixed --xwayland-count 2 -w 1280 -h 800 --default-touch-mode 4 --hide-cursor-delay 3000 --max-scale 2 --fade-out-duration 200 -e -R "$socket" -T "$stats" -O '*',eDP-1`. It resolves `gamescope` through `PATH`; there is no `$GAMESCOPECMD` and no config file it sources. It does not set `GAMESCOPE_SCRIPT_PATH`. | same package, `usr/lib/steamos/gamescope-session` |
| `gamescope --help` (3.16.30.1) does not list `--fade-out-duration`, which the session passes. The wrapper therefore uses the union of `--help` and the option table extracted from `src/main.cpp` at build time. | gamescope `src/main.cpp` |
| NicoWayne95/anatase-x20-hdr-fix v0.1.0 (updated 2026-10-24): builds libdisplay-info 0.3.0 + the same eight upstream commits, checks the soname stays `.so.3` and no exported symbol disappears, installs to `/var/lib/x20-hdr-backport` and selects it with `/etc/ld.so.conf.d/00-x20-hdr-backport.conf`. Reports KDE going from `HDR: incapable` to `disabled` (enable-able). Does not touch gamescope. | <https://github.com/NicoWayne95/anatase-x20-hdr-fix> |
| 60plus/SteamOS_Nvidia_Installer: custom gamescope under its own prefix, selected by a `gamescope-session.service` drop-in with `Environment="PATH=<ours>:/usr/local/sbin:/usr/local/bin:/usr/bin"` only when the build accepts the session's flags (checked with `--help`); otherwise stock, with the choice recorded in `status.txt`. | <https://github.com/60plus/SteamOS_Nvidia_Installer/wiki/How-it-works> |

### Why libdisplay-info 0.3.0 + backport and not 0.4.0

An `ld.so.conf.d` entry only changes which file satisfies a soname. KWin on
SteamOS 3.9 needs `libdisplay-info.so.3`; a 0.4.0 build provides `.so.4`, so
installing 0.4.0 would be a silent no-op for every stock binary. The backport
keeps `.so.3` and is ABI-compatible (only additions to the public headers;
`build-hdr.sh` builds an unpatched 0.3.0 next to it and fails if any exported
symbol disappeared). The probe still uses 0.4.0 as the "SteamOS caught up"
threshold, because a stock 0.4.0 comes with KWin rebuilt against it.

If you ever need a different soname (e.g. SteamOS moves to `.so.4` before
reaching 0.4.0 features, or you want to test 0.4.0 itself), the override
cannot go through `ld.so.conf.d`. The alternative is to scope it to the Plasma
session only with `LD_LIBRARY_PATH` in a user `environment.d` drop-in such as
`~/.config/environment.d/90-ally-x20-steamos-hdr.conf`
(`LD_LIBRARY_PATH=/var/lib/ally-x20-steamos/lib`). That is not installed by
default: it leaks into every process of the user session, Game Mode included.

### Risk of the ld.so.conf.d override

It is system-wide: every dynamically linked process that loads
`libdisplay-info.so.3` gets our build. That is KWin, `kscreen`/`libkscreen`
helpers and anything else from the Plasma stack; it is **not** stock gamescope
(static). An ABI break would show up as KWin failing to start in Desktop Mode.
Mitigations: same soname and exported-symbol superset checked at build time,
patches are upstream commits only, the checks listed under
[What is checked before a library is installed](#what-is-checked-before-a-library-is-installed),
and recovery is one command from a TTY (Ctrl+Alt+F3) or over SSH:
`sudo ally-x20-steamos hdr remove`
([details](#if-desktop-mode-does-not-start-hdr-remove)).

## Building

You do not need this for the library: CI builds it, and `hdr build` runs
the same build on the device. For reference, and for the gamescope build:

`build/build-hdr.sh` runs inside the Arch build container, never on the
SteamOS host. The image from [`build/Containerfile`](../build/Containerfile)
has no meson or ninja. For the library,
[`build/Containerfile.hdr`](../build/Containerfile.hdr) adds them and
`hwdata` on top of that image and makes `build-hdr.sh` the entrypoint; this
is what CI and `hdr build` use:

```sh
podman build -t localhost/ally-x20-steamos-build -f build/Containerfile build
podman build -t localhost/ally-x20-steamos-build-hdr -f build/Containerfile.hdr build
podman run --rm --userns=keep-id -v "$PWD:/src:ro" -v "$PWD/build/hdr-out:/out" -e HOME=/tmp \
    localhost/ally-x20-steamos-build-hdr \
    --only libdisplay-info --destdir /out/stage --artifact-dir /out/artifact
```

`--artifact-dir` collects what the device installs into
`artifact/libdisplay-info-0.3.0/`. The gamescope build needs the full
package list in [`build/hdr-deps.txt`](../build/hdr-deps.txt) (about 110 MB)
installed in the container as well.

```sh
build/build-hdr.sh --destdir /out                    # both, gamescope 3.16.30.1 + PR #2493
build/build-hdr.sh --destdir /out --only libdisplay-info
build/build-hdr.sh --destdir /out --gamescope-mode upstream   # gamescope 3.17.0, no patches
build/build-hdr.sh --destdir /out --verify-edid edid-eDP-1.bin
```

Pins are in [`build/hdr.lock`](../build/hdr.lock); patches in
`patches/libdisplay-info/` (MIT) and `patches/gamescope/` (BSD-2-Clause).
The script verifies that each tag still resolves to the pinned commit.
Outputs, relative to `--destdir`:

```
var/lib/ally-x20-steamos/lib/libdisplay-info.so.{0.3.0,3}
var/lib/ally-x20-steamos/libdisplay-info/{bin/di-edid-decode,BUILD-INFO}
opt/ally-x20-steamos/gamescope/{bin/gamescope,share/gamescope/scripts,BUILD-INFO,LICENSE}
opt/ally-x20-steamos/gamescope/share/ally-x20-steamos/accepted-flags
```

`BUILD-INFO` records pins, patch sha256s, a `build_id` derived from all
inputs, the output sha256 and the container image. For the gamescope build,
bind-mount the host's `/opt/ally-x20-steamos` under `/out`, or copy the
staged tree, then run `ally-x20-steamos.sh apply` (which installs the
wrapper when the gamescope build is present). Do not copy the library in by
hand any more: `hdr build` installs it through the manifest and checks it
first.

`TODO(vm)`: confirm `/opt` is writable and survives an A/B update on SteamOS;
otherwise set `HDR_GAMESCOPE_PREFIX` (build script and component) and
`AX20_GAMESCOPE_PREFIX` default (wrapper) to a path under
`/var/lib/ally-x20-steamos`.

## The gamescope wrapper

On every Game Mode start, with our build present:

1. If stock gamescope ships the X20 profile, run stock (we are superseded).
2. If `/opt/ally-x20-steamos/gamescope/bin/gamescope` or its `BUILD-INFO` is
   missing, run stock.
3. Load the accepted-flag cache for this `build_id`
   (`/var/lib/ally-x20-steamos/state/gamescope-flags.cache`, written by
   `apply`; else `$XDG_RUNTIME_DIR/ally-x20-steamos/`). If it is missing or
   from another build, run our build's `--help` once (10 s timeout) and
   rebuild it. If `--help` fails, run stock.
4. Every option the session passed (up to `--`) must be in the set; one
   unknown flag means Valve changed the session and we run stock.
5. Otherwise exec our build. `LD_LIBRARY_PATH` is set to our lib dir only if
   the build links libdisplay-info dynamically
   (`gamescope_libdisplay_info=shared` in `BUILD-INFO`); the default build
   bundles it statically like Valve's package, so nothing leaks into Steam
   and the games it starts.

Any error inside the wrapper (an ERR trap) also ends in stock gamescope. Our
own directory is removed from `PATH` before either exec. The decision is
written to `/var/lib/ally-x20-steamos/state/gamescope-status.txt`
(`selection=ours|stock`, `reason=...`, `build_id=...`, `args=...`); the file is
pre-created world-writable by `apply` because the wrapper runs as the session
user. `ally-x20-steamos.sh status` prints the reason when the last start fell
back. `AX20_GAMESCOPE_DISABLE=1` forces stock for debugging.

`TODO(vm)`: the drop-in's `PATH` copies systemd's default user `PATH`
(`Environment=` cannot expand `$PATH`); compare with
`systemctl --user show-environment`. The drop-in takes effect the next time
the user manager starts (reboot or re-login).

## How to verify

Desktop Mode:

```sh
ally-x20-steamos hdr status                     # "our library: installed", build id, "ld.so.cache lists our copy"
ldconfig -p | grep 'libdisplay-info.so.3 '      # our /var/lib/ally-x20-steamos/lib copy listed first (TODO(vm))
/var/lib/ally-x20-steamos/libdisplay-info/bin/di-edid-decode < /sys/class/drm/card*-eDP-1/edid \
    | grep -A6 'HDR Static Metadata'            # block found inside the DisplayID 2 extension
kscreen-doctor -o | grep -iE 'HDR:|Wide Color Gamut:'   # "disabled" (capable) instead of "incapable"
```

Then System Settings > Display & Monitor: the HDR and Wide Color Gamut toggles
are available for the internal display.

Game Mode (`journalctl --user -b -u gamescope-session`):

```
[script] Running script file '/etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua'
[drm] Got known display: rogallyx20_oled (ASUS ROG Xbox Ally X20 OLED)
```

Steam's Display settings then offer HDR, and the frame limiter slider covers
30–120 Hz. With the custom build, also check
`cat /var/lib/ally-x20-steamos/state/gamescope-status.txt` for
`selection=ours`.

In the VM (plan §6 check 8): feed the dumped X20 EDID
(`drm.edid_firmware=edid/x20.bin` or QEMU's custom EDID), run the commands
above, and start the wrapper with an extra unknown flag to see the stock
fallback and its status line. `TODO(hw)`: the EDID dump and the `SDC`/`0x4501`
match on a real panel.

## Removing it

Only the Desktop Mode library: `sudo ally-x20-steamos hdr remove`
([above](#if-desktop-mode-does-not-start-hdr-remove)).

`ally-x20-steamos.sh uninstall` removes every file above (manifest-driven),
the library included, the wrapper's status/cache files, and runs
`ldconfig`. By hand:

```sh
sudo rm /etc/ld.so.conf.d/00-ally-x20-steamos.conf && sudo ldconfig
sudo rm /etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua
sudo rm /etc/systemd/user/gamescope-session.service.d/50-ally-x20-steamos.conf
```

What is left in `/var/lib/ally-x20-steamos/lib`,
`/var/lib/ally-x20-steamos/libdisplay-info` and `/opt/ally-x20-steamos/gamescope`
is inert once those files are gone.

`status` reports `superseded` once stock SteamOS has libdisplay-info ≥ 0.4.0
**and** a gamescope with the X20 profile (`jupiter-main` already has the
latter); `uninstall --superseded` then removes the drop-ins.

## Out of scope

- **ITM / "auto HDR"** (inverse tone mapping of SDR games). gamescope's ITM and
  KWin's SDR-in-HDR rendering are separate features; this component only makes
  the panel report HDR capability.
- **Brightness differences** between Game Mode and Desktop Mode, or versus
  Windows. The profile enables gamescope's software backlight in PQ mode (the
  panel ignores the hardware backlight there), as upstream does; tuning the
  curve is not covered.
- Calibration values. KDE's HDR calibration should be done by the user; the
  EDID's 1405 nits is the panel's claim, not a measurement.
