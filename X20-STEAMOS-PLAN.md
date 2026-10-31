# ally-x20-steamos — ROG Xbox Ally X20 on SteamOS, out-of-tree support plan

Project name: **`ally-x20-steamos`** everywhere — repo, CLI, systemd units,
drop-in file names, state dir (`/var/lib/ally-x20-steamos`). Final.

Goal: make the ROG Xbox Ally X20 (board `RC74XA`) fully usable on stock SteamOS
without Anatase, without HHD, using InputPlumber, with everything built from
source, surviving SteamOS A/B updates, fully reversible, and testable in a VM
before touching the device.

Conventions for the implementing agent:
- All git commits are authored by the repo owner only. No AI co-author or
  attribution lines in commits.
- License: **GPL-2.0-only** for the repository (same as the Linux kernel; the
  kernel patches are derivative works of GPL-2.0 code, so this is required,
  not just a preference). `LICENSE` = GPL-2.0 text; SPDX header
  `// SPDX-License-Identifier: GPL-2.0-only` / `# SPDX-License-Identifier: GPL-2.0-only`
  on every source/script file. Per-file exceptions, listed in `LICENSE.md`
  and kept under their original license verbatim:
  - `overlay/ucm2/sof-soundwire/tas2783.conf` — BSD-3-Clause (alsa-ucm-conf)
  - any patch against InputPlumber — GPL-3.0-or-later (InputPlumber's license)
  - any patch against gamescope — BSD-2-Clause (gamescope's license)
  - any patch against libdisplay-info — MIT
  Firmware blobs (TAS2783 tuning) are never committed; they are downloaded
  from linux-firmware at install time under its `WHENCE` redistribution terms.
- Never ship a prebuilt `.ko` in git. CI may attach prebuilt artifacts to
  releases with SHA-256 sums and the exact source commit they came from.
- Never edit a stock SteamOS file in place. Only add files; record every added
  file in a manifest so `uninstall` can remove them.

---

## 1. What is broken on stock SteamOS (as of 2026-10-30)

Target kernel: `7.2.7-valve2-1-neptune-72-g31504582a073` (SteamOS 3.9.x beta).
The device boots, GPU/Wi-Fi/sleep/display work. Gaps:

### 1.1 Speakers (two TI TAS2783 amps on AMD ACP SoundWire)
Four independent problems (reference: hungarianhc/rog-ally-x20-steamos-speakers,
stoneharborent/aquarius-os PR #40, anatase-org/kernel-anatase 7.2.7-an22):
1. BIOS sets `acp-audio-config-flag = 0x10` (DMIC-only) so Linux skips
   SoundWire/SOF. Windows ignores the flag.
   Fix: ACPI table override as early initrd (table upgrade) OR a DMI quirk
   patch in the kernel (ovenham repo `upstream/` has a proposed one).
2. Kernel has no SoundWire layout for amps on link 0 + RT721 codec on link 1.
   Fix: patch `sound/soc/amd/.../acp-config` / `snd-soc-acpi-amd-match` to add
   the RC74XA link-0 layout. **Only kernel module needed for audio.**
   Do NOT apply the upstream "one channel per mono amp" proposal — it silences
   the right amp on this device.
3. Amp tuning firmware: files are in linux-firmware (`ti/audio/tas2783`,
   redistributable) but the driver requests a different filename; correct pair
   depends on speaker supplier (JGX vs LS) read from the `SPEAKER_ID` UEFI var.
4. No UCM profile: SteamOS `alsa-ucm-conf` predates TAS2783 → "Dummy Output".
   Fix: overlay upstream `sof-soundwire/tas2783.conf` via `ALSA_CONFIG_UCM2`.

### 1.2 Controller / buttons
- **SteamOS already ships and enables InputPlumber** (package `inputplumber`
  in Valve's jupiter repo; `inputplumber.service` runs on factory SteamOS
  for Legion Go S / Go 2). We do NOT install our own by default.
- Upstream InputPlumber ≥ v0.83.0 (2026-10-21) has native X20 support
  (PR #756: matches DMI board `RC74XA`, reuses the Xbox Ally sources and
  capability map, correct IMU mount matrix, hwdb autostart entry). SteamOS's
  bundled version predates it, so the X20 is not matched out of the box.
- Fix, drop-in only: `/etc/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml`
  (the upstream profile from PR #756, adapted to the key names the stock
  daemon version understands) + hwdb autostart drop-in
  (`/etc/udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb`) + ensure the stock
  service is enabled. Probe at install time: `inputplumber --version` and
  the stock `devices/` dir.
- Fallback only if the stock daemon is too old for the profile: build
  upstream InputPlumber (pinned tag) into `/opt/ally-x20-steamos/inputplumber/`
  and select it with a systemd drop-in override
  (`/etc/systemd/system/inputplumber.service.d/50-ally-x20-steamos.conf`,
  `ExecStart=` replaced). No stock file edited; removing the drop-in restores
  the stock daemon.
- The top-right button (ovenham: "Quick Access"; owner: Capture) sends `0xa0`
  on the ASUS N-KEY HID interface; stock `hid-asus-ally` only knows `0xa6`
  (older Allys) and drops it.
  Fix: report it as its own key (`KEY_PROG2`) in our `hid-asus-ally` patch (we
  rebuild it anyway, §1.3) and map it in the InputPlumber capability map
  (docs/inputplumber.md §6).

### 1.3 Joystick ring RGB in Steam's native Customization menu
- Kernel side works: `hid-asus-ally` exposes
  `/sys/class/leds/ally:rgb:joystick_rings` (led-class-multicolor), and Valve's
  udev rule already makes it user-writable.
- Steam client only discovers three hardcoded LED names:
  `go:rgb:joystick_rings`, `go_s:rgb:joystick_rings`, `valve-leds`.
  Fix (kndclark/ally_module approach, SteamOS issue #2371): patch
  `hid-asus-ally.c` to register the LED as `go_s:rgb:joystick_rings`, fix the
  mc_subled channels (3 × R/G/B instead of 12 × RGB), add effect/speed sysfs
  attrs. Second rebuilt kernel module: `hid-asus-ally`.
- Verify on hardware which LED nodes the X20 exposes (rings only, or rings +
  Xbox button) — `ls /sys/class/leds/`.

### 1.4 HDR (OLED panel AMS740LS02) — userspace only
- Panel stores HDR static metadata + colorimetry in a CTA-861 data block of a
  DisplayID 2 extension (no plain CTA extension). libdisplay-info < 0.4.0 does
  not search DisplayID 2, so both KWin (Desktop) and gamescope (Game Mode)
  report the panel as not HDR-capable.
- Upstream fix, merged in ValveSoftware/gamescope PR #2493 (2026-10-18): read
  HDR/colorimetry via libdisplay-info `di_info` accessors (needs ≥ 0.2.0,
  DisplayID 2 searched from ≥ 0.4.0) + adds X20 as a known device (display
  profile: 30–120 Hz VRR range, intermediate refresh rates for frame limiter).
- Fix = two overlays, no kernel work:
  a. `libdisplay-info` ≥ 0.4.0 → fixes Desktop Mode (KWin) alone.
  b. gamescope with #2493 + (a) → fixes Game Mode HDR + refresh-rate list.
- Anatase community fix (NicoWayne95/anatase-x20-hdr-fix) = (a) only, via
  `/etc/ld.so.conf.d/`; explicitly does not patch gamescope. ITM/auto-HDR and
  brightness differences in Game Mode are separate and not covered here.

### 1.5 Virtual surround for headphones + speaker chain (PipeWire, userspace, /home only)
**Required component, installed by default** (user can disable with
`ally-x20-steamos.sh audio-dsp off`; it is not an opt-in extra).
Goal: binaural 3D audio over headphones that renders exactly what the game
outputs — stereo stays bit-identical stereo, 5.1 → virtual 5.1, 7.1 →
virtual 7.1. Decided per stream, automatically. No vendor DSP (Dolby/Nahimic)
exists on Linux; this is the open equivalent of "Atmos for Headphones".
Speakers get a separate downmix + widener + EQ chain (HRTF does not work on
speakers because of inter-aural crosstalk; transaural/XTC is a stretch goal,
see below).

Pieces (all user-session config, survive updates, trivially reversible):
1. `~/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf` —
   `filter-chain` creating a 7.1 virtual sink, each channel through the
   built-in `sofa` spatializer with an HRTF (SOFA file; ship 2–3 well-known
   ones, user picks). Distinct azimuth/elevation sets for 5.1 vs 7.1 layouts.
2. `~/.config/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf` and the
   `client.conf.d` equivalent — `channelmix.upmix = false` so a stereo stream
   is never synthesized into 7.1 before spatialization.
3. `~/.config/wireplumber/scripts/x20-route-by-channels.lua` (+ loader
   fragment) — on stream creation read `audio.channels`:
   ≥3 → target virtual-surround sink; ≤2 → target hardware sink (raw
   passthrough). Also bypass entirely when no headphones are detected on the
   jack (ALSA port availability), so speakers never receive HRTF audio.
   One-line toggle to let stereo streams also go through the HRTF if the user
   prefers the out-of-head stereo feel.
4. Speaker chain (required; separate `filter-chain` sink, speakers only, no
   EasyEffects dependency): automatic surround→stereo downmix, stereo widener
   (LSP Stereo Tools or equivalent LV2/LADSPA), EQ, multiband compressor /
   loudness, bass enhancer. Initial preset tuned by ear; refined against a
   Windows reference recording of the X20 (see §7). Selected automatically
   by the same WirePlumber script when no headphones are present.
5. Stretch goal (not required for v0.1): transaural crosstalk cancellation
   (XTC) for the built-in speakers, exploiting the handheld's fixed
   head/speaker geometry; designed or measured filter loaded as a convolver.
   Document findings even if it ends up not shipping.
Requirements: SteamOS PipeWire built with `libmysofa` (check:
`strings /usr/lib/pipewire-0.3/libpipewire-module-filter-chain.so | grep -i sofa`
and `ls /usr/lib/libmysofa.so*`). If absent, ship libmysofa under
`/var/lib/ally-x20-steamos/lib` via the same ld.so.conf.d overlay as §1.4.
Probe: none needed (never superseded by Valve); `status` just reports on/off.
VM test: fully testable — play a 7.1 test file and a stereo file, confirm
routing via `pw-top`/`pw-dump` (which sink each stream targets) and that the
stereo stream's samples pass through unchanged (loopback capture + compare).

---

## 2. Repository layout

```
ally-x20-steamos/
├── README.md
├── PLAN.md                         # this file
├── patches/
│   ├── kernel/
│   │   ├── 0001-ASoC-amd-acpi-add-RC74XA-link0-tas2783-layout.patch
│   │   ├── 0002-ACPI-x86-quirk-ignore-acp-audio-config-flag-RC74XA.patch   # optional alt to initrd override
│   │   ├── 0010-hid-asus-ally-alias-LED-to-go_s-and-fix-mc_subled.patch
│   │   ├── 0011-hid-asus-ally-add-effect-speed-mode-sysfs.patch
│   │   └── 0012-hid-asus-ally-report-X20-top-right-key-0xa0.patch
│   └── inputplumber/               # only if the stock daemon needs a source patch (fallback path)
├── build/
│   ├── Containerfile               # archlinux base; podman rootless OK on SteamOS
│   ├── build-modules.sh            # fetch sources @ exact valve version, apply patches,
│   │                               #   make M=sound/soc/amd/... and M=drivers/hid  (targeted, minutes)
│   ├── build-inputplumber.sh       # FALLBACK ONLY: cargo build --release, pinned tag (stock daemon too old)
│   ├── build-hdr.sh                # libdisplay-info ≥0.4.0 + gamescope (stock SteamOS version + PR #2493, or Valve master)
│   └── kernel-sources.md           # where sources come from (see §3)
├── overlay/                        # files copied onto the device, tracked by manifest
│   ├── modprobe.d/ally-x20-steamos.conf
│   ├── environment.d/90-x20-ucm.conf
│   ├── ucm2/sof-soundwire/tas2783.conf       # BSD-3 from alsa-ucm-conf
│   ├── systemd/ally-x20-steamos.service           # boot: verify, rebuild if kver mismatch, run probes
│   ├── systemd/ally-x20-steamos-notify.service    # user session: notify when something is superseded
│   ├── inputplumber/devices.d/50-rog_xbox_ally_x20.yaml   # upstream PR #756 profile
│   ├── udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb
│   ├── systemd/inputplumber.service.d/50-ally-x20-steamos.conf  # FALLBACK ONLY: ExecStart override
│   ├── ld.so.conf.d/00-ally-x20-steamos.conf      # selects /var/lib/ally-x20-steamos/lib (libdisplay-info)
│   ├── bin/gamescope                         # wrapper: run our build if it accepts the session's flags, else stock
│   ├── rauc/post-install.hook                # re-apply to freshly staged slot
│   └── home/                                 # per-user files installed into ~ (audio DSP, required)
│       ├── pipewire/pipewire.conf.d/50-x20-virtual-surround.conf
│       ├── pipewire/pipewire.conf.d/51-x20-speaker-chain.conf
│       ├── pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf
│       ├── pipewire/client.conf.d/50-x20-no-upmix.conf
│       ├── wireplumber/scripts/x20-route-by-channels.lua
│       └── hrtf/*.sofa                       # 2–3 HRTF sets, licenses noted in LICENSE.md
├── acpi/
│   ├── dump-dsdt.md                # how to dump from Windows (acpidump) or Linux
│   ├── patch-acp-flag.py           # clears acp-audio-config-flag, rebuilds cpio for early initrd
│   └── fixtures/                   # real X20 DSDT once dumped (used by VM + tests)
├── firmware/
│   └── tas2783.lock                # pinned linux-firmware commit + sha256 for JGX and LS pairs
├── lib/                            # shell library used by the CLI
│   ├── manifest.sh                 # add/remove/list tracked files
│   ├── slots.sh                    # active/other slot, boot-entry save/restore
│   ├── probes.sh                   # "does stock SteamOS now have X?" checks (see §5)
│   └── modules.sh                  # version-gated substitution logic
├── ally-x20-steamos.sh                       # install | apply | status | rebuild | probe | self-update | audio-dsp on|off | uninstall [--superseded]
├── vm/
│   ├── README.md
│   ├── setup-fedora-host.sh        # one-shot KVM/podman/tooling setup for the Fedora dev box
│   ├── run-steamos-vm.sh           # qemu/OVMF with SMBIOS + ACPI injection (see §6)
│   └── fake-leds.sh                # tmpfs mimic of ally:rgb:joystick_rings for tests
├── tests/                          # bats for shell libs, pytest for acpi tool; run on host and in VM
└── .github/workflows/
    ├── build-modules.yml           # matrix over known valve kernel versions → release artifacts
    ├── vm-tests.yml                # SteamOS under QEMU/KVM on the x86 runner: install → update → uninstall
    └── test.yml                    # bats/pytest unit tests
```

---

## 3. Kernel module build strategy

- SteamOS ships no headers. Valve's kernel = upstream stable at the matching
  version + Valve patches; for 7.2.7 the touched subsystems are identical to
  upstream, so build against `linux-stable` at tag `v7.2.7` with the running
  kernel's `.config` (`zcat /proc/config.gz`) and `Module.symvers` regenerated
  via `make modules_prepare`.
- Prefer Valve's own source package when available from the SteamOS package
  mirror (`linux-neptune-*` src tarball) — bit-exact, fewer surprises.
  (User to supply the mirror URL; wire it as `KERNEL_SRC_URL` in build config.)
- Build only the touched modules (`make M=...`). Target: a few minutes in a
  rootless podman container, on-device or on a PC.
- Output: `/var/lib/ally-x20-steamos/modules/<kver>/{snd-soc-acpi-amd-match,hid-asus-ally}.ko.zst`
  plus a `BUILD-INFO` (source commit, patch hashes, vermagic).
- Substitution via `/etc/modprobe.d/ally-x20-steamos.conf` `install` hooks:
  `install hid-asus-ally /usr/lib/ally-x20-steamos/load-or-fallback hid-asus-ally`
  The helper loads the patched `.ko` **only if** `uname -r` has a matching
  build dir; otherwise `modprobe --ignore-install` the stock one. Unknown kernel
  ⇒ stock behaviour, never a broken boot.

---

## 4. Surviving SteamOS updates (A/B via RAUC)

### 4.1 What a SteamOS update does to us
SteamOS keeps two root slots (A/B). An update writes a whole new root image
to the *other* slot via RAUC, switches the boot entry to it, and reboots.
Consequences for each of our pieces:

| Piece | Effect of an update | Survives? |
|---|---|---|
| `/var/lib/ally-x20-steamos/**` (modules, firmware, UCM, libs, cache, manifest) | `/var` is shared between slots | yes |
| `/home/**` (audio DSP config, HRTFs) | `/home` is shared | yes |
| `/opt/ally-x20-steamos/**` (gamescope build; InputPlumber only in fallback) | `/opt` is on `/var` on SteamOS — confirm in VM; if not, move under `/var/lib/ally-x20-steamos` and symlink | yes (to confirm) |
| `/etc/**` (modprobe.d, environment.d, ld.so.conf.d, systemd units) | new slot gets a fresh `/etc` from the image + a whitelist/overlay of the old one; which of our files survive must be measured in the VM, not assumed | partially |
| `/usr/**` (never written by us) | replaced | n/a |
| Boot entry / kernel cmdline + early-initrd ACPI override | per-slot; the new slot's entry does not have our changes | no |
| Kernel version | may change → our `.ko` no longer match | no |
| Stock gamescope/libdisplay-info/alsa-ucm/firmware versions | may change → probes may flip to "superseded" | n/a |

### 4.2 Re-apply flow (two independent paths, both idempotent)
1. **RAUC post-install hook** (icedream/steamos-permanent-mods pattern) runs
   after the new slot is written, before reboot, with the new slot mounted:
   a. copy the `/etc` overlay from `/var/lib/ally-x20-steamos/overlay/etc/` into the
      new slot's `/etc`;
   b. apply the boot-entry change (cmdline + early initrd) to the **new**
      slot's entry only, after saving the untouched original for rollback;
   c. read the new slot's kernel version from `/usr/lib/modules/*/`; if
      `/var/lib/ally-x20-steamos/modules/<kver>/` is missing, try in order:
      cached prebuilt → download matching release artifact (if online) →
      container build (if online, podman present). Any failure is logged,
      not fatal: the version-gated modprobe hook makes the new kernel boot
      with stock modules.
   d. write `/var/lib/ally-x20-steamos/state/pending-reboot-check`.
2. **Boot-time service** `ally-x20-steamos.service` (after `local-fs.target`, before
   the display manager / `gamescope-session`): verifies every manifest file
   exists on this slot and re-copies missing ones; if modules for `uname -r`
   are missing, attempts the same build/pull chain; then runs the probes
   (§5) and writes `status.json`. It never blocks boot for more than a few
   seconds — builds run detached and take effect on the *next* boot, with a
   notification.
3. **User-session notifier** (`ally-x20-steamos-notify.service`, user unit): on login
   after an update, shows one notification summarizing what was re-applied,
   what is pending rebuild, and what is superseded.

Everything persistent lives under `/var/lib/ally-x20-steamos/`; `/etc` and boot
entries are treated as re-derivable from it. The hook and the service share
one implementation (`ally-x20-steamos.sh apply --slot <path>`), so a failed hook is
simply retried by the service on first boot.

### 4.3 Expected user experience of a SteamOS update
- Known kernel (same version, or one we already have modules for): update
  as usual → reboot → everything works, one "re-applied" notification.
- New kernel, device online: update → reboot → speakers/RGB briefly on
  stock behaviour while modules build in the background → notification →
  second reboot restores them. Audio DSP, InputPlumber, HDR overlays are
  unaffected by the kernel change and keep working through this.
- New kernel, device offline: same, but the rebuild waits for connectivity;
  `ally-x20-steamos.sh rebuild` can be run manually (also from the Decky/Quick Access
  shortcut) at any time.
- Update that *removes* a gap (probe flips to superseded): notification
  tells the user, nothing is auto-removed (§5).
- Secure Boot / kernel lockdown: not expected on the X20 under SteamOS, but
  if `lockdown` is active our unsigned modules will refuse to load; the
  service detects this and reports it rather than retrying forever.

### 4.4 Updating ally-x20-steamos itself (git-based)
- ally-x20-steamos is installed **from a git checkout** at `/var/lib/ally-x20-steamos/src`
  (cloned by the bootstrap installer). Nothing is copied out of it except
  through `apply`, which records every file in the manifest.
- `ally-x20-steamos self-update [--channel stable|beta]`: `git fetch --tags`, verify
  the newest tag's signature (signed tags; the public key ships in the repo
  and is pinned at bootstrap), `git checkout` it (stable) or fast-forward the
  `beta` branch, run `migrations/` (idempotent), then `apply`. Previous
  commit is recorded for `self-update --rollback`. Any local modifications
  in the checkout abort self-update with a clear message (we never `reset
  --hard` the user's edits).
- **Self-update always runs before any rebuild**: the RAUC pre-install
  handler and `ally-x20-steamos rebuild` both call `self-update` first (best-effort,
  skipped when offline). A fix pushed for a new Valve kernel is therefore
  picked up automatically during the update that introduces that kernel.
- The boot service checks for new tags at most once a day (opt-out flag),
  notifies, never auto-installs outside the update path above.
- Decky plugin (later milestone, optional): thin UI over `status`,
  `rebuild`, `self-update`, `audio-dsp on|off`, `update-policy`, so none of
  this needs Desktop Mode.

### 4.5 Build environment and build inputs on the device
SteamOS ≥ 3.5 ships **podman and distrobox preinstalled**, rootless, no
setup needed; the version lags upstream but is sufficient for running an
Arch build container. The build container image is pinned by digest and
cached under `~/.local/share/containers` (survives updates). No
`steamos-readonly disable`, no `pacman` on the host, ever.

Kernel headers — SteamOS does not install them, but **Valve publishes
`linux-neptune-<ver>-headers` packages** on the SteamOS package mirror
(`steamdeck-packages.steamos.cloud/archlinux-mirror/<jupiter-main|jupiter-beta|jupiter-staging>/`),
alongside the `linux-neptune-<ver>` kernel package. Resolution order for a
given target kernel version string (e.g. `7.2.7-valve2-1-neptune-72`):
1. `/var/lib/ally-x20-steamos/cache/headers/<kver>/` (already fetched).
2. Download the exact `linux-neptune-<series>-headers-<ver>-<rel>` package
   from the mirror matching the device's current channel (read from
   `steamos-select-branch -l` / the atomupd manifest), verify its checksum
   against the repo database, extract into the build container.
3. If the headers package is not yet published (can happen for a fresh
   beta/preview kernel): Valve's source package
   (`.../sources/<repo>/linux-neptune-<ver>.src.tar.gz`) or the matching tag
   of `evlaV/linux-integration`, with the `.config` extracted from the
   target slot's `vmlinuz` (`scripts/extract-ikconfig`, SteamOS enables
   IKCONFIG), then `make modules_prepare` — produces headers equivalent to
   step 2.
4. Last resort: upstream `linux-stable` at the same base version. Only used
   when the touched files are byte-identical to Valve's (checked by hash
   against the cached Valve source when available); otherwise fail.
Every build records which input was used in `BUILD-INFO`. The build is
verified by `modinfo` vermagic equality and a `modprobe --dry-run` style
symbol check against the target kernel's `Module.symvers` (from headers).

### 4.6 Update gating policy (pre-install vs post-install)
RAUC semantics: a **pre-install handler** that exits non-zero aborts the
installation; a failed **post-install handler** only produces a notification
and does not change the result. We use both:

- `pre-install` (gate): self-update → determine the incoming kernel version
  from the mounted bundle image → ensure modules exist for it (cache /
  release artifact / on-device build). Then apply policy:
  - `block` (**default**): if modules cannot be produced, exit non-zero →
    SteamOS update is aborted, state is unchanged, user is notified with the
    build log. Steam will retry the update at its next check; each retry
    re-runs self-update first, so a pushed fix unblocks it automatically.
    A retry backoff avoids rebuilding on every check (cache the failure per
    kernel version + ally-x20-steamos commit).
  - `degrade`: never block; proceed and let the version-gated modprobe hook
    load stock modules on the new kernel (speakers silent, RGB menu gone,
    QAM button dead until a rebuild succeeds; audio DSP, InputPlumber, HDR
    unaffected). Set with `ally-x20-steamos update-policy degrade`.
  - Escape hatch: `ally-x20-steamos update-policy degrade --once` for "I need this
    update now regardless".
- `post-install` (apply): copy overlay into the new slot, set its boot
  entry, stage the prebuilt modules, write pending-check state. Idempotent;
  retried by the boot service if anything is missing.
- The handler paths are registered in RAUC's config. SteamOS's
  `/etc/rauc/system.conf` is a stock file and RAUC has no `conf.d`; this is
  one of the two documented exceptions to the drop-in-only rule (§5.2):
  the original is saved, a clearly delimited `# >>> ally-x20-steamos` block is added,
  and uninstall restores the saved original byte-for-byte (verifying its
  hash first). Must be verified in the VM against how icedream's
  steamos-permanent-mods registers its hook; if SteamOS already defines a
  post-install handler, chain it rather than replace it.
- Hands-off summary: the user never has to intervene for an update to
  succeed in the normal case. The only intervention points are (a) a
  blocked update under `block` policy when no fix exists yet, and (b)
  choosing to remove superseded components (§5).

---

## 5. Reversibility and "has SteamOS caught up?"

### 5.1 Manifest
Every file written by `install`/`apply` is recorded in
`/var/lib/ally-x20-steamos/manifest` (JSON lines) with: path, component, sha256 of
the content we wrote, slot it was written to, and whether we created the
parent directory. `uninstall` removes them in reverse order, restores the
saved boot entry, runs `depmod`/`ldconfig`, reboots.

### 5.1b Read-only root: we never toggle it
SteamOS mounts the root image (`/usr`, `/boot`, stock `/etc` lower layer)
read-only; `steamos-readonly disable` is the community's way to write into
`/usr`. **We never call it**, for install, update, or uninstall. Every
location we write is already writable on a stock system:

| Location | Mount | Writable? |
|---|---|---|
| `/etc/**` (drop-ins) | overlayfs over the stock `/etc` | yes |
| `/var/lib/ally-x20-steamos/**` | `/var` partition (shared across slots) | yes |
| `/home/**` | `/home` partition | yes |
| `/opt/ally-x20-steamos/**` | SteamOS places `/opt` on writable storage — confirm in VM; else use `/var/lib/ally-x20-steamos/opt` + symlink | yes (confirm) |
| `/efi/EFI/steamos/**` (early initrd with ACPI table) | per-slot EFI partition, vfat, rw | yes |
| `/esp/loader/entries/*.conf` (boot entry) | shared ESP, vfat, rw | yes |
| `/etc/rauc/system.conf` block | `/etc` overlay | yes |
| the *other* slot during a RAUC install | RAUC mounts it rw for the duration; pre/post-install handlers run with it mounted | yes, within handlers only |

Consequences: no `sudo steamos-readonly` anywhere in the codebase (a test
greps for it); the CLI refuses to run if root is detected writable because
someone disabled read-only manually, unless `--i-know` is passed, since that
state means stock files could have been altered by other tools. One open
item to measure in the VM: exactly how SteamOS carries the `/etc` overlay
upper directory to the new slot (shared upper vs. per-slot copy with a
whitelist), because it determines whether post-install must re-copy our
drop-ins or they are already there. The plan handles both (§4.2).

### 5.2 Hardening rules for what we touch (enforced by code review + tests)
1. **Only add, never modify.** We write new files only. Stock SteamOS files
   are never edited, moved, or deleted. All configuration goes through
   drop-in directories with an `ally-x20-steamos`-prefixed name:
   `/etc/modprobe.d/ally-x20-steamos.conf`, `/etc/environment.d/90-ally-x20-steamos.conf`,
   `/etc/ld.so.conf.d/00-ally-x20-steamos.conf`, `/etc/systemd/system/ally-x20-steamos*.service`,
   `/etc/udev/rules.d/90-ally-x20-steamos*.rules`, `~/.config/pipewire/*.conf.d/50-ally-x20-steamos*.conf`,
   `~/.config/wireplumber/wireplumber.conf.d/50-ally-x20-steamos*.conf`, etc.
2. **Nothing under `/usr`.** Ever. Not even with `steamos-readonly disable`.
   Binaries and libraries go to `/var/lib/ally-x20-steamos/` or `/opt/ally-x20-steamos/` and are
   selected via `PATH`/`ld.so.conf.d`/wrapper drop-ins.
3. **Exactly two documented exceptions**, each with save/verify/restore:
   a. the active slot's boot entry (cmdline + early initrd for the ACPI
      override) — original saved to `/var/lib/ally-x20-steamos/backup/<slot>/`;
   b. `/etc/rauc/system.conf` handler registration (§4.6) — delimited block,
      original saved. If a later SteamOS gains a conf.d or an official hook
      directory, migrate to it and retire the exception.
4. **Uninstall removes only what the manifest says we created**, and only if
   the file's current sha256 matches what we wrote (or `--force` is given,
   which still refuses anything outside the manifest). Directories are
   removed only if we created them *and* they are empty. Symlinks we created
   are removed; their targets are not followed.
5. **Deny-list as a last line of defense**: uninstall hard-refuses to touch
   anything under `/usr`, `/boot`'s stock entries, `/etc/fstab`,
   `/etc/rauc/` (other than the delimited block restore), the ESP outside
   our own files, the `deck` user's Steam data, or any path not prefixed
   `ally-x20-steamos`/not in the manifest — even if the manifest is corrupted.
6. **Works from a broken state.** `uninstall` must succeed when: the
   manifest is partial (interrupted install), the system is mid-update (one
   slot patched, one not), the other slot is booted, or ally-x20-steamos's own
   checkout is gone. Therefore the uninstaller is a single self-contained
   POSIX shell script copied to `/var/lib/ally-x20-steamos/uninstall.sh` at install
   time, independent of the git checkout, and accepts `--slot <mountpoint>`
   to clean a non-booted slot (usable from the other slot or SteamOS
   recovery media).
7. **Dry-run and audit**: `uninstall --dry-run` prints every action;
   `ally-x20-steamos audit` compares the manifest with the filesystem and reports
   drift (missing, modified, or unexpected `ally-x20-steamos*` files).
8. **Idempotent and re-entrant**: running install, apply, or uninstall twice
   is a no-op the second time; a crash mid-way leaves a state that the next
   run completes.
9. **Never leave the system unbootable**: boot-entry edits are written to a
   temp file and renamed atomically; the ACPI override initrd is validated
   before the entry points at it; if the saved original entry is missing at
   uninstall time, the entry is regenerated from the stock template rather
   than left pointing at a deleted initrd.
10. **Tests** (`tests/uninstall/*.bats`): fixture roots for each state in
    rule 6; assert byte-identical restoration of stock files; assert the
    deny-list triggers on crafted manifests.
`status` prints each component as `active | stock | superseded | n/a`.

### Probes (one per component, each a small testable shell function)
| Component | Probe for native support |
|---|---|
| audio link-0 layout | stock `snd-soc-acpi-amd-match.ko` contains RC74XA/link-0 entry (strings/modinfo), or a stock-module boot enumerates a `sof-soundwire` card with TAS2783 |
| ACPI flag | stock boot without override still yields a SoundWire card (kernel quirk landed) |
| UCM | `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` present in stock |
| amp firmware | requested filenames present under stock `/lib/firmware/ti/` |
| RGB in Steam UI | `strings steamui.so` contains `ally:rgb:joystick_rings`, or stock `hid-asus-ally.ko` registers a Steam-known name |
| Quick Access 0xa0 | stock `hid-asus-ally.ko` handles `0xa0` (strings on the keycode table / hidraw replay test) |
| HDR: libdisplay-info | stock `libdisplay-info.so` version ≥ 0.4.0 (`pkg-config --modversion` or soname/`strings`) |
| HDR: gamescope | stock `/usr/bin/gamescope` contains the X20 known-device entry (`AMS740LS02`) AND links libdisplay-info ≥ 0.4.0 — likely the first component to retire, since PR #2493 is already in Valve master |
| InputPlumber profile | stock `/usr/share/inputplumber/devices/` contains an `RC74XA` match → drop our devices.d profile + hwdb |
| InputPlumber daemon override (fallback only) | stock `inputplumber --version` ≥ the version our profile needs → drop the ExecStart drop-in |

Special case — gamescope wrapper: on every Game Mode start the wrapper checks
that our build accepts the session's launch flags; if not (Valve changed
them), it execs stock gamescope and writes `status.txt` saying so (pattern
from 60plus/SteamOS_Nvidia_Installer). A broken custom gamescope must never
break Game Mode.

Policy: probes **never auto-remove**. A positive probe marks the component
`superseded`, logs it, and triggers a user-session notification. The user
then runs `ally-x20-steamos.sh uninstall --superseded`. Optional online check:
poll the SteamOS package mirror for a new `linux-neptune` version and flag
"re-run probes after next update".

---

## 6. VM test plan (before the X20)

SteamOS installs in QEMU/KVM + OVMF from the recovery image; real OS updates
apply inside the VM (opt into beta channel).

### 6.0 Where the VM runs (host options)
SteamOS is x86-64 only, with its own kernel/bootloader/A-B layout, so it
needs a real x86 VM with UEFI — not an OrbStack/Lima "machine" (those boot a
distro kernel on Virtualization.framework and cannot boot the SteamOS ISO).
- **GitHub Actions (primary, automated)**: x86 `ubuntu-latest` runners expose
  `/dev/kvm`; `.github/workflows/vm-tests.yml` boots the SteamOS image under
  QEMU/KVM, runs install → probes → simulated/real update → uninstall, and
  asserts byte-identical restoration. Cache the installed SteamOS disk image
  as a workflow artifact/release asset to avoid reinstalling every run.
- **Legion Go 2 (SteamOS) as a local KVM host**: run QEMU inside a
  distrobox on it; native speed, KVM available, nothing touches the host OS.
  Use for interactive debugging. Never run ally-x20-steamos itself on the Go 2.
- **Intel Mac**: QEMU with HVF (`-accel hvf`) or UTM; near-native.
- **Apple Silicon Mac**: QEMU x86-64 under TCG only (`qemu-system-x86_64
  -accel tcg`); 10–20× slower, no usable gamescope, a full RAUC update takes
  hours. Acceptable for shell-level tests (install/uninstall/manifest/probe
  logic, bats suites) and as a last resort; not the main loop.
- **Fedora x86 box (primary local host)**: native KVM + podman. One-shot
  setup (`vm/setup-fedora-host.sh`, idempotent):
  `sudo dnf install -y qemu-kvm qemu-img edk2-ovmf virt-install libvirt
  podman git shellcheck bats python3-pytest acpica-tools swtpm`
  `sudo usermod -aG libvirt,kvm $USER` (re-login), verify `/dev/kvm` and
  `podman info` as the user. Optional: `libmysofa`/`pipewire-utils` for
  local audio-chain experiments outside the VM. Keep the SteamOS base disk
  image under `~/vms/ally-x20-steamos/` and snapshot it (`qemu-img create -b`)
  so every test starts from a known-clean install.
- Any other x86 Linux box / cloud VM with nested virt: same as above.

Division of work: Mac/Claude Code for everything that needs no VM (repo
scaffolding, shell libs + bats, ACPI tool + pytest, overlay files, CI
workflows, docs); the Fedora box for VM runs, container module builds, the
update-survival and uninstall-from-broken-state suites, and later the
on-device loop. Both push to the same repo; CI (KVM runner) is the arbiter.
`vm/run-steamos-vm.sh` auto-selects `kvm` → `hvf` → `tcg` and prints which
one it got; the test suite tags tests that are too slow for TCG so they can
be skipped locally and still run in CI.

`vm/run-steamos-vm.sh` flags:
- `-smbios type=1,manufacturer="ASUSTeK COMPUTER INC.",product=RC74XA` so DMI
  matching (InputPlumber profile, hwdb, DMI quirks) fires as on hardware.
- `-acpitable file=acpi/fixtures/x20-dsdt.aml` to load the real X20 DSDT and
  exercise the ACPI override tooling end-to-end.
- USB passthrough of a spare Xbox controller for an InputPlumber smoke test.

What the VM proves:
1. install/status/uninstall round-trip leaves the system byte-identical (diff
   manifest paths before/after).
2. Module build pipeline produces `.ko` with matching vermagic; version-gated
   substitution loads ours on the matching kernel and stock on any other.
3. ACPI early-initrd override loads (check `dmesg` for "ACPI: Table Upgrade").
4. A/B update survival: `steamos-update`, reboot, confirm overlay re-applied on
   the new slot and modules rebuilt/pulled for the new kernel. Measure which
   `/etc` paths SteamOS carries over on its own and which the hook/service had
   to restore; record in `docs/etc-survival.md`. Also test the offline case
   (block network in the VM) and `self-update` + `self-update --rollback`.
5. Stock `inputplumber.service` up, D-Bus reachable, our devices.d profile
   selected via the SMBIOS-injected `RC74XA` DMI; confirm with
   `inputplumber devices` / `busctl tree org.shadowblip.InputPlumber`.
   Also exercise the fallback path (ExecStart drop-in) once.
6. RGB alias: with `vm/fake-leds.sh` (tmpfs at
   `/sys/class/leds/go_s:rgb:joystick_rings` is not bind-mountable; instead
   test the Steam discovery path via a tiny out-of-tree test LED module that
   registers a multicolor LED under that name) → Steam Customization section
   appears.
7. Probe framework: unit tests with fixture trees representing "stock lacks X"
   and "stock has X".
8. HDR: feed the X20's dumped EDID to the VM (`drm.edid_firmware=edid/x20.bin`
   with the blob in an initrd, or QEMU's custom-EDID option) and verify
   `di-edid-decode` from our libdisplay-info reports the HDR static metadata
   block, KWin reports HDR capable, and gamescope's log selects the X20 panel
   profile with the 30–120 Hz range. Verify the wrapper falls back to stock
   gamescope when handed an unknown flag.

What only the X20 can prove: actual TAS2783 audio, SPEAKER_ID variable, N-KEY
hidraw `0xa0`, which LED nodes exist, gold-ring Aura behaviour.

---

## 7. Hardware-side data to collect on the X20 (first boot of stock SteamOS)

```
uname -r; zcat /proc/config.gz > config-$(uname -r)
sudo acpidump -b -o acpi/fixtures/   # or dump DSDT from Windows before wiping
ls /sys/class/leds/
lsusb; cat /sys/class/dmi/id/{board_name,product_name,sys_vendor}
aplay -l; cat /proc/asound/cards; journalctl -k | grep -iE 'acp|sof|soundwire|tas2783'
efivar -l | grep -i speaker   # SPEAKER_ID
ls /usr/share/alsa/ucm2/sof-soundwire/ ; ls /lib/firmware/ti/
sudo cat /proc/bus/input/devices
inputplumber --version; systemctl status inputplumber.service; ls /usr/share/inputplumber/devices/ | grep -i ally
inputplumber devices   # does the stock daemon pick up the X20 controller at all?
for e in /sys/class/drm/*/edid; do echo $e; cat $e > "edid-$(basename $(dirname $e)).bin"; done
di-edid-decode edid-*.bin        # or edid-decode; confirm DisplayID 2 + HDR metadata block
gamescope --version; pkg-config --modversion libdisplay-info 2>/dev/null || ls /usr/lib/libdisplay-info.so*
pipewire --version; ls /usr/lib/libmysofa.so*; strings /usr/lib/pipewire-0.3/libpipewire-module-filter-chain.so | grep -i sofa
ls /usr/lib/lv2 /usr/lib/ladspa 2>/dev/null       # which DSP plugins SteamOS already ships (LSP? Calf?)
```

Before wiping Windows: record a reference of the X20 speakers (pink noise +
a sine sweep + a familiar game clip) with a phone at normal playing distance,
Dolby on and off. This is the tuning target for the speaker chain.

---

## 8. Milestones

1. Repo skeleton, CLI with manifest + uninstall, bats tests. VM boots SteamOS
   with SMBIOS override.
2. Container build of the two modules against 7.2.7-valve2; version-gated
   substitution verified in VM.
3. Audio overlay (ACPI tool, firmware lock, UCM) + probes; VM checks 1–4.
4. InputPlumber devices.d profile + hwdb drop-in on the stock daemon (fallback
   build path behind a probe); `0xa0` patch; VM check 5.
5. RGB alias patch + effects sysfs; VM check 6.
6. HDR: libdisplay-info overlay (Desktop), then gamescope build + wrapper with
   stock fallback (Game Mode); VM check 8.
7. RAUC hook + boot service; A/B update survival in VM.
8. Audio DSP (§1.5, required): headphone virtual surround (filter-chain +
   no-upmix + WirePlumber channel-count routing + jack switching) and the
   speaker chain; VM-tested with 2ch/5.1/7.1 fixtures and jack-state
   simulation. Ships in v0.1.
9. First on-device run: collect §7 data, adjust layout/LED findings, release
   v0.1 with CI-built artifacts.

## References
- hungarianhc/rog-ally-x20-steamos-speakers (audio, patch source, UCM, firmware)
- ovenham/rog-ally-x20-steamos-speaker-qam-fix (QAM 0xa0, proposed ACPI quirk)
- anatase-org/kernel-anatase releases 7.2.7-an22/an23 (audio backports, sleep quirk)
- stoneharborent/aquarius-os PR #40 (clean write-up of the four audio problems)
- ShadowBlip/InputPlumber PR #756, v0.83.0 (X20 support)
- kndclark/ally_module; ValveSoftware/SteamOS issues #2260, #2371 (RGB)
- icedream/steamos-permanent-mods (RAUC hook); ryanrudolfoba vangogh_oc_fix (/etc whitelist)
- ValveSoftware/gamescope PR #2493 (X20 HDR + known device); NicoWayne95/anatase-x20-hdr-fix (libdisplay-info backport, KDE only)
- 60plus/SteamOS_Nvidia_Installer wiki (custom gamescope with stock fallback + status.txt pattern)
