# ROG Xbox Ally X20 on SteamOS — out-of-tree support plan

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
- InputPlumber ≥ v0.83.0 has native X20 support (PR #756: matches RC74XA,
  reuses Xbox Ally sources/capability map, hwdb autostart entry).
  SteamOS does not ship InputPlumber; we build and install it.
- Quick Access button sends `0xa0` on the ASUS N-KEY HID interface; stock
  `hid-asus-ally` only knows `0xa6` (older Allys) and drops it.
  Fix: add the mapping in our `hid-asus-ally` patch (we rebuild it anyway, §1.3).

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

---

## 2. Repository layout

```
x20-steamos-support/
├── README.md
├── PLAN.md                         # this file
├── patches/
│   ├── kernel/
│   │   ├── 0001-ASoC-amd-acpi-add-RC74XA-link0-tas2783-layout.patch
│   │   ├── 0002-ACPI-x86-quirk-ignore-acp-audio-config-flag-RC74XA.patch   # optional alt to initrd override
│   │   ├── 0010-hid-asus-ally-alias-LED-to-go_s-and-fix-mc_subled.patch
│   │   ├── 0011-hid-asus-ally-add-effect-speed-mode-sysfs.patch
│   │   └── 0012-hid-asus-ally-map-X20-quick-access-0xa0.patch
│   └── inputplumber/               # only if something is not yet upstream
├── build/
│   ├── Containerfile               # archlinux base; podman rootless OK on SteamOS
│   ├── build-modules.sh            # fetch sources @ exact valve version, apply patches,
│   │                               #   make M=sound/soc/amd/... and M=drivers/hid  (targeted, minutes)
│   ├── build-inputplumber.sh       # cargo build --release, pinned tag
│   ├── build-hdr.sh                # libdisplay-info ≥0.4.0 + gamescope (stock SteamOS version + PR #2493, or Valve master)
│   └── kernel-sources.md           # where sources come from (see §3)
├── overlay/                        # files copied onto the device, tracked by manifest
│   ├── modprobe.d/x20-support.conf
│   ├── environment.d/90-x20-ucm.conf
│   ├── ucm2/sof-soundwire/tas2783.conf       # BSD-3 from alsa-ucm-conf
│   ├── systemd/x20-support.service           # boot: verify, rebuild if kver mismatch, run probes
│   ├── systemd/x20-support-notify.service    # user session: notify when something is superseded
│   ├── systemd/inputplumber.service
│   ├── ld.so.conf.d/00-x20-support.conf      # selects /var/lib/x20-support/lib (libdisplay-info)
│   ├── bin/gamescope                         # wrapper: run our build if it accepts the session's flags, else stock
│   └── rauc/post-install.hook                # re-apply to freshly staged slot
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
├── x20-support.sh                  # install | status | rebuild | uninstall [--superseded] | probe
├── vm/
│   ├── README.md
│   ├── run-steamos-vm.sh           # qemu/OVMF with SMBIOS + ACPI injection (see §6)
│   └── fake-leds.sh                # tmpfs mimic of ally:rgb:joystick_rings for tests
├── tests/                          # bats for shell libs, pytest for acpi tool; run on host and in VM
└── .github/workflows/
    ├── build-modules.yml           # matrix over known valve kernel versions → release artifacts
    └── test.yml
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
- Output: `/var/lib/x20-support/modules/<kver>/{snd-soc-acpi-amd-match,hid-asus-ally}.ko.zst`
  plus a `BUILD-INFO` (source commit, patch hashes, vermagic).
- Substitution via `/etc/modprobe.d/x20-support.conf` `install` hooks:
  `install hid-asus-ally /usr/lib/x20-support/load-or-fallback hid-asus-ally`
  The helper loads the patched `.ko` **only if** `uname -r` has a matching
  build dir; otherwise `modprobe --ignore-install` the stock one. Unknown kernel
  ⇒ stock behaviour, never a broken boot.

---

## 4. Surviving SteamOS updates (A/B via RAUC)

Two independent re-apply paths:
1. **RAUC post-install hook** (icedream/steamos-permanent-mods pattern): after
   the new slot is staged, copy overlay files into it, re-apply the boot-entry
   change for that slot, attempt a module build for the new kernel (or pull a
   matching prebuilt release artifact if offline build is not possible).
2. **Boot-time service**: on every boot compare `uname -r` with built module
   dirs; if missing, rebuild from cache/source; then run probes (§5). Also
   verify `/etc` overlay files exist (SteamOS replaces `/etc` with a whitelist;
   confirm in VM which of our paths survive — adjust to whitelisted locations
   or re-copy from `/var/lib/x20-support/overlay/`).

Everything persistent lives under `/var/lib/x20-support/` (survives updates);
`/etc` and boot entries are treated as re-derivable from it.

---

## 5. Reversibility and "has SteamOS caught up?"

### Manifest
Every file written by `install` is recorded in
`/var/lib/x20-support/manifest` with a component tag. `uninstall` removes them
in reverse order, restores the saved boot entry, runs `depmod`, reboots.
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
| InputPlumber | never auto-superseded; user decision |

Special case — gamescope wrapper: on every Game Mode start the wrapper checks
that our build accepts the session's launch flags; if not (Valve changed
them), it execs stock gamescope and writes `status.txt` saying so (pattern
from 60plus/SteamOS_Nvidia_Installer). A broken custom gamescope must never
break Game Mode.

Policy: probes **never auto-remove**. A positive probe marks the component
`superseded`, logs it, and triggers a user-session notification. The user
then runs `x20-support.sh uninstall --superseded`. Optional online check:
poll the SteamOS package mirror for a new `linux-neptune` version and flag
"re-run probes after next update".

---

## 6. VM test plan (before the X20)

SteamOS installs in QEMU/KVM + OVMF from the recovery image; real OS updates
apply inside the VM (opt into beta channel).

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
   the new slot and modules rebuilt/pulled for the new kernel.
5. InputPlumber service up, D-Bus reachable, X20 profile selected via DMI.
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
for e in /sys/class/drm/*/edid; do echo $e; cat $e > "edid-$(basename $(dirname $e)).bin"; done
di-edid-decode edid-*.bin        # or edid-decode; confirm DisplayID 2 + HDR metadata block
gamescope --version; pkg-config --modversion libdisplay-info 2>/dev/null || ls /usr/lib/libdisplay-info.so*
```

---

## 8. Milestones

1. Repo skeleton, CLI with manifest + uninstall, bats tests. VM boots SteamOS
   with SMBIOS override.
2. Container build of the two modules against 7.2.7-valve2; version-gated
   substitution verified in VM.
3. Audio overlay (ACPI tool, firmware lock, UCM) + probes; VM checks 1–4.
4. InputPlumber build/install + service; `0xa0` patch; VM check 5.
5. RGB alias patch + effects sysfs; VM check 6.
6. HDR: libdisplay-info overlay (Desktop), then gamescope build + wrapper with
   stock fallback (Game Mode); VM check 8.
7. RAUC hook + boot service; A/B update survival in VM.
8. First on-device run: collect §7 data, adjust layout/LED findings, release
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