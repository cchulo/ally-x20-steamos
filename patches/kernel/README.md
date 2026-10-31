# Kernel patches

Kernel patches for the ROG Xbox Ally X20 (board `RC74XA`) on stock SteamOS.
Each file is in `git format-patch` format and applies with `git apply` or
`patch -p1` from the top of a kernel tree. They are derivative works of
GPL-2.0 kernel code and are licensed GPL-2.0-only (see `LICENSE.md`).

This file documents the speaker-audio patches, listed in `modules.list`:
`0001`/`0002` (plan §1.1, problems 1 and 2) and `0003`–`0006`, four fixes
backported from Valve's `7.2.10-valve1` kernel. The `hid-asus-ally` patches (`0010`–`0013`,
joystick-ring RGB in Steam, Aura effects, Quick Access `0xa0`, unbind fixes) are documented
in [`README-hid.md`](README-hid.md) and listed in `modules-hid.list`. The
build script reads every `modules*.list` file. Note the difference in source
trees: `0001`/`0002` apply to linux-stable `v7.2.7` and Valve's tree
alike, `0003`–`0006` were checked against Valve's `7.2.7-valve2` only, and
`hid-asus-ally.c` exists only in Valve's tree.

## Target kernel

| | |
|---|---|
| SteamOS kernel | `7.2.7-valve2-1-neptune-72-g31504582a073` |
| Valve source tag | `7.2.7-valve2` (commit `31504582a073`, mirror [evlaV/linux-integration](https://github.com/evlaV/linux-integration)) |
| Upstream base | linux-stable `v7.2.7` (commit `f42acb367842`) |

Both touched files are byte-identical in linux-stable `v7.2.7` and Valve's
`7.2.7-valve2`. Git blob ids:

| File | v7.2.7 / 7.2.7-valve2 | after the patch (= Valve 7.2.10-valve1) |
|---|---|---|
| `sound/soc/amd/acp/amd-acp70-acpi-match.c` | `ccd01152c87d…` | `ee51de5f1fb3…` |
| `sound/soc/amd/acp-config.c` | `8e1563824a97…` | `45c750185184…` |

**Validation:** `git apply --check` passes for each patch against a sparse
checkout of linux-stable `v7.2.7` and against the two files from Valve's
`7.2.7-valve2` tag. The patches have not been compiled on this host or run on
hardware.

**SteamOS has caught up in 7.2.10-valve1.** Valve's `7.2.10-valve1` tag
(2026-10-22) already carries both changes as `[FOR-UPSTREAM]` commits by
Matthew Schwartz (`5f7b3941a10f`, `045b13e03d29`). There, `git apply --check
--reverse` succeeds for both patches, so a build script can use it to detect
that a kernel no longer needs them. The same kernel also carries
`a15043a1338a` "ASoC: tas2783-sdw: split a stereo stream across the two mono
amps", the change that 0001 deliberately avoids (see below). Whether stereo
still works on that kernel is `TODO(hw)`. It also carries the originals of
`0003`–`0006`; those backports do not reverse-apply there (see
[Valve backports](#00030006-valve-7210-valve1-backports)), so they carry a
`Valve-Upstream: 7.2.10-valve1` line that `build/build-modules.sh` reads
instead.

## 0001: SoundWire layout (problem 2)

`0001-ASoC-amd-acpi-add-RC74XA-link0-tas2783-layout.patch`

**What it fixes:** no entry in `snd_soc_acpi_amd_acp70_sdw_machines[]` matches
the RC74XA wiring, so `acp63_sdw_machine_select()` (`sound/soc/amd/ps/pci-ps.c`)
picks `acp70_rt721_only`. You get the headset jack and DMIC but no speakers.
The patch adds `acp70_tas2783x2_l0u8b_rt721_l1u0` ahead of that fallback:

| Link | `_ADR` | Device | Unique ID | `name_prefix` | Endpoints |
|---|---|---|---|---|---|
| 0 | `0x0000380102000001` | TI TAS2783 | `0x8` | `tas2783-1` | `spk_l_endpoint` (aggregated, group 1, pos 0) |
| 0 | `0x00003B0102000001` | TI TAS2783 | `0xB` | `tas2783-2` | `spk_r_endpoint` (aggregated, group 1, pos 1) |
| 1 | `0x000130025D072101` | Realtek RT721 | `0x0` | `rt721` | `jack_dmic_endpoints` (EP 0 jack, EP 2 DMIC) |

How the tables describe a layout: a `snd_soc_acpi_mach` entry has a
`link_mask` and a `links` array of `snd_soc_acpi_link_adr`, one per link, each
with a `mask` bit for the link and an `adr_d` array of
`snd_soc_acpi_adr_device`. Each device has a 64-bit SoundWire `_ADR` (bits
51:48 link, 47:44 SoundWire version, 43:40 unique ID, 39:24 manufacturer,
23:8 part ID, 7:0 class) and a list of `snd_soc_acpi_endpoint`s (`num`,
`aggregated`, `group_position`, `group_id`). The selector takes the first
entry for which every listed device is present on the bus.

**Stereo, not the mono split:** both amps get the standard stereo-pair
endpoints. Each amp receives the full stereo stream and picks its own side
from the BIOS SDCA init table (PPU21 = `0x01` left, `0x04` right, per
hungarianhc; `TODO(hw)`). Each amp also keeps its feedback path. The upstream
proposal to give each mono amp one channel (linux-sound thread
[17279211](https://ratatoskr.run/linux-sound/2026/07/17279211/t), carried in
Valve 7.2.10-valve1 as `a15043a1338a`) is not applied here; on this device it
was reported to silence the right amp.

**Derived from:** hungarianhc/rog-ally-x20-steamos-speakers
`patches/0001-ASoC-amd-acp70-add-TAS2783-x2-on-link-0-with-RT721-on-link-1.patch`;
Valve linux-integration `5f7b3941a10f` (identical hunk, used verbatim so the
result matches Valve's blob); anatase-org/kernel-anatase `7.2.7-an22`
`patch-2-anatase.patch`; stoneharborent/aquarius-os PR #40
`build_files/x20-audio/rc74xa-soundwire-links.patch`.

**Module:** `snd-soc-acpi-amd-match.ko` (`CONFIG_SND_SOC_ACPI_AMD_MATCH`),
built in `sound/soc/amd/acp/` from `amd-acp63-acpi-match.o` +
`amd-acp70-acpi-match.o`, plus `soc-acpi-amd-sdca-quirks.o` when
`CONFIG_SND_SOC_ACPI_AMD_SDCA_QUIRKS=y`. In that case it imports the
`SND_SOC_SDCA` namespace and depends on `snd-soc-sdca`, so modpost needs that
module's symbols in `Module.symvers`. A built module can be checked with
`strings … | grep acp70_tas2783x2_l0u8b_rt721_l1u0`.

## 0002: ignore `acp-audio-config-flag` (problem 1, optional)

`0002-ACPI-x86-quirk-ignore-acp-audio-config-flag-RC74XA.patch`

The file name follows the plan. The flag is not read in `drivers/acpi/x86/`
in v7.2.7: `snd_amd_acp_acpi_find_config()` in `sound/soc/amd/acp-config.c`
reads it with `acpi_dev_get_property(…, "acp-audio-config-flag", …)`. The
quirk therefore goes in that file's existing DMI table.

**What it fixes:** the RC74XA BIOS reports `acp-audio-config-flag = 0x10`
(`FLAG_AMD_LEGACY_ONLY_DMIC`). For ACP ≥ 7.0, `snd_amd_acp_find_config()`
returns it unless `dmi_check_system(acp70_acpi_flag_override_table)` matches.
`snd_pci_ps` returns `-ENODEV` on any non-zero flag, so SoundWire is never
scanned. The patch adds `DMI_MATCH(DMI_BOARD_VENDOR, "ASUSTeK COMPUTER INC.")` +
`DMI_MATCH(DMI_BOARD_NAME, "RC74XA")` to that table, so the flag reads as 0
and `snd_pci_ps` probes. `snd-acp-pci` and `snd-sof-amd-acp70` still back
off, because they only accept the LEGACY or SOF flag values.

This is the in-kernel alternative to the early-initrd ACPI table override
(`acpi/patch-acp-flag.py`). Use one or the other. 0002 is useless without 0001.

**Derived from:** Valve linux-integration `045b13e03d29` (identical hunk);
ovenham/rog-ally-x20-steamos-speaker-qam-fix
`upstream/acp-config-rog-xbox-ally-x20.patch` (same table; matches
`DMI_PRODUCT_NAME`); anatase-org/kernel-anatase `7.2.7-an22`;
stoneharborent/aquarius-os PR #40 `build_files/x20-audio/rc74xa-acp-config.patch`.

**Module:** `snd-acp-config.ko` (`CONFIG_SND_AMD_ACP_CONFIG`), built from
`sound/soc/amd/acp-config.c` by `sound/soc/amd/Makefile`. The build script
names the `.ko` as a kbuild single target, so `M=sound/soc/amd` no longer
descends into every configured subdirectory (`acp/`, `ps/`, `yc/`, …).

**Load order caveat:** `snd_pci_ps` calls `snd_amd_acp_find_config()`, so the
patched `snd-acp-config` must be the one loaded when `snd_pci_ps` probes. If
the stock module is in the initramfs and loads early, the stock flag wins.
`TODO(hw)`: check `lsinitcpio` / dracut contents on SteamOS.

## 0003–0006: Valve 7.2.10-valve1 backports

Valve's `7.2.10-valve1` carries four `[FOR-UPSTREAM]` fixes by Matthew
Schwartz that `7.2.7-valve2` lacks (see the
[comparison notes](../../docs/audio-comparison.md) on the
`docs/audio-comparison` branch). Each file is `git format-patch -1` of the
commit in the [evlaV/linux-integration](https://github.com/evlaV/linux-integration)
mirror, with the original author, date, subject and description. An
`ally-x20-steamos:` note at the end of the description names the source
commit, says why we carry it and lists every hunk that had to change.

**Validation:** applied in order after `0001`/`0002` with `git apply` on a
sparse checkout of `7.2.7-valve2` (`31504582a073`). Not compiled on this host
or run on hardware.

**Not reverse-applicable on 7.2.10-valve1.** None of the four, not even
Valve's unmodified `9a0dabd2637d` and `021e9da34c58`, reverse-applies by
itself on `7.2.10-valve1`: the 7.2.y stable merge there changed the context
of `0003`, and in `tas2783-sdw.c` the later commits rewrite the context of
the earlier ones. Our `0004`–`0006` also differ from Valve's text because
Valve's versions sit on seven tas2783 commits we do not carry (among them
the mono split `a15043a1338a`, see 0001). Each file therefore has a
`Valve-Upstream: 7.2.10-valve1` line in its description;
`build/build-modules.sh` treats the patch as already upstream on that tag
and later ones (all six audio modules then show as `superseded`), and still
applies it on older tags.

### 0003: honor empty DisCo port lists (no SmartAmp capture link)

`0003-ASoC-sdw_utils-honor-empty-DisCo-port-lists.patch`, from Valve
`9a0dabd2637d` "ASoC: sdw_utils: honor empty DisCo port lists when creating
DAI links" (anatase `7.2.7-an22` patch 0257).

**What it fixes:** the TAS2783 `codec_info` entry declares a capture DAI, so
`soc_sdw_utils` always adds the amp feedback link
`SDW0-PIN4-CAPTURE-SmartAmp`. The RC74XA BIOS sets
`mipi-sdw-source-port-list = 0` for both amps, so every open of that PCM
fails in `sdw_program_slave_port_params()`: a burst of
`Program transport params failed: -22` and
`ASoC error (-22) at snd_soc_link_prepare()`, and the PCM's `hw_free`
writes PDE23 = PS3 (power off) on both amps. With the patch an endpoint
keeps a direction only if the peripheral does not declare an empty port list
for it, so the capture link is not created. A missing list keeps the table
direction.

**Adjusted:** the hunk for `sound/soc/intel/boards/sof_sdw.c` (Intel machine
driver) is dropped; the X20 is AMD-only, and we do not rebuild Intel modules.
Everything else is Valve's hunk.

**Modules:** the patch adds `bool direction[2]` to `struct asoc_sdw_endpoint`
in `include/sound/soc_sdw_utils.h`. The machine driver allocates the array of
endpoints and `snd-soc-sdw-utils` fills it, so all users of the struct must
come from the same build:

| Module | `M=` | Uses the struct |
|---|---|---|
| `snd-soc-sdw-utils.ko` (`CONFIG_SND_SOC_SDW_UTILS`) | `sound/soc/sdw_utils` | `asoc_sdw_parse_sdw_endpoints()` |
| `snd-acp-sdw-legacy-mach.ko` (`CONFIG_SND_SOC_AMD_LEGACY_SDW_MACH`) | `sound/soc/amd/acp` | allocates it; the card the X20 uses (`amdsoundwire`) |
| `snd-acp-sdw-sof-mach.ko` (`CONFIG_SND_SOC_AMD_SOF_SDW_MACH`) | `sound/soc/amd/acp` | allocates it (SOF path) |

Other files that include the header but never touch the struct:
`sound/soc/amd/acp/acp-sdw-mach-common.c` (`snd-acp-sdw-mach`),
`sound/soc/sof/intel/hda.c` and the Intel `sound/soc/intel/boards/sof_sdw*.c`
(`snd-soc-sof-sdw`, which does use it but never loads on AMD hardware). They
are not rebuilt. SteamOS kernels have `CONFIG_MODVERSIONS` off, so a stock
Intel `snd-soc-sof-sdw` would not be refused by the loader next to our
`snd-soc-sdw-utils`; that only matters on Intel machines.

**Caveat:** the modprobe hooks fall back per module. If the patched
`snd-soc-sdw-utils` loads but a patched machine driver does not (or the other
way round), the old and new struct layouts meet. All three come from one
build with one vermagic, so this should not happen, but it is not guarded.

### 0004: tas2783 keeps the volume settings across resets

`0004-ASoC-tas2783-sdw-keep-the-volume-settings-across-resets.patch`, from
Valve `021e9da34c58`.

**What it fixes:** on v7.2.7 the register cache is dropped on every
uninitialized re-attach, the X20 powers the SoundWire link off when idle,
and so `Amp Volume` / `Speaker Volume` fail with `-EBUSY` while the amps are
suspended and a value you set is lost on the next idle. The driver now keeps
both settings itself, reapplies them after every init and resume, and
adopts the firmware's value until userspace sets one.

**Adjusted:** the `tas_io_init()` hunk (Valve's context has the
"Re-active AMP after resume" write from `65eadd5b0e65`, which `7.2.7-valve2`
lacks) and the `tas_sdw_probe()` hunk (no `fw_version` context line). The
added code is Valve's.

### 0005: tas2783 loads the firmware synchronously

`0005-ASoC-tas2783-sdw-load-the-firmware-synchronously.patch`, from Valve
`5ce75814c28a`.

**What it fixes:** v7.2.7 requests the tuning file asynchronously and stops
waiting after 3 s; `tas_io_init()` then skips the init writes while the
callback keeps downloading, and nothing cancels the callback on unbind. Now
`request_firmware_direct()` and the download run in `tas_io_init()` and
their result decides whether the init writes run. `request_firmware_direct()`
still honours `firmware_class.path` (how the `audio` component points the
driver at `/etc/ally-x20-steamos/firmware`), but it never falls back to the
user-mode helper.

**Adjusted:** the `struct tas2783_prv` hunk (no `fw_version` member) and the
`tas2783_fw_download()` context: `7.2.7-valve2` has no firmware-version read,
PRAM skip, download retry or `regcache_drop_region()` there. Applies on top
of 0004.

### 0006: tas2783 refuses playback when the init writes failed

`0006-ASoC-tas2783-sdw-refuse-playback-when-init-writes-failed.patch`, from
Valve `2ce1d48892f3`.

**What it fixes:** the DisCo init writes carry each amp's posture (which side
of the stereo stream it plays, see 0001). On v7.2.7 a failed init still lets
`hw_params()` start playback. Now `hw_params()` and the port pre-prepare
return `-EINVAL` with "error playback without init writes" /
"error port N prepare without init writes" until the init succeeded.

**Adjusted:** `tas_port_prep()`: `7.2.7-valve2` lacks `5c9979eb1917` (power
the Function up before preparing the port), so the patch adds the `tas_dev`
local Valve's version already had, and the check sits right before the port
prepare write. Applies on top of 0004 and 0005.

**Module (0004–0006):** `snd-soc-tas2783-sdw.ko` (`CONFIG_SND_SOC_TAS2783_SDW`),
`M=sound/soc/codecs`, built alone as a single target (the directory has
hundreds of codecs, and `rt1320-sdw.h` includes
`../../../drivers/soundwire/bus.h`, which the sparse checkout does not have).

## `modules.list`

One line per patch and module, tab-separated, no header or comments:

```
<patch file>	<make M= directory, relative to the kernel tree>	<resulting .ko file name>
```

A patch that affects several modules has one line per module (`0003`), and
a module patched by several patches has one line per patch (`0004`–`0006`);
the build script applies each patch once, in file-name order, and builds
each module once. Every file a patch touches must be under one of its `M=`
dirs; `include/` headers are the exception, because the build puts the
patched copies ahead of the kernel's headers for every `M=` build. A patch
that changes a header must therefore list every module that uses what it
changes.

`.ko` names use dashes as on disk (`snd-soc-acpi-amd-match.ko`). The loaded
module name uses underscores (`snd_soc_acpi_amd_match`). SteamOS ships them as
`.ko.zst` under `/usr/lib/modules/<kver>/kernel/sound/soc/amd/…`.

Build hint for `build/build-modules.sh`: Valve publishes a matching
`linux-neptune-72-headers` package (with `Module.symvers`) on
`steamdeck-packages.steamos.cloud/archlinux-mirror`; hungarianhc's build
uses it. `TODO(hw)`: confirm the exact package name and version for
`7.2.7-valve2-1`.

## Firmware

See [`firmware-names.md`](firmware-names.md): which `.bin` names the v7.2.7
`tas2783-sdw` driver requests, and the JGX vs LS speaker-supplier pair.

## TODO(hw)

- SoundWire IDs: amps on link 0 with unique IDs `0x8`/`0xB` and RT721 on link
  1, uid 0. Every source agrees on these, but they come from other people's
  dumps. Confirm with `journalctl -k | grep -i soundwire` /
  `/sys/bus/soundwire/devices/` on our unit.
- DMI strings: `board_vendor` = `ASUSTeK COMPUTER INC.` and `board_name` =
  `RC74XA` (`/sys/class/dmi/id/`). hungarianhc reports the product name as
  "ROG XBOX Ally X RC74XA".
- The flag value `0x10` in our BIOS version (`RC74XA.301` reported).
- Stereo channel selection by PPU21 (`0x01` left, `0x04` right): both amps
  play, and left/right are not swapped.
- `CONFIG_SND_SOC_ACPI_AMD_MATCH=m`, `CONFIG_SND_AMD_ACP_CONFIG=m` and
  `CONFIG_SND_SOC_ACPI_AMD_SDCA_QUIRKS` in `/proc/config.gz`.
- Whether `snd-acp-config` is in the SteamOS initramfs.
- Stereo behaviour on Valve 7.2.10-valve1 with the mono-split patch.
- With `0003`: no `SDW0-PIN4-CAPTURE-SmartAmp` PCM (`aplay -l`/`arecord -l`)
  and no `Program transport params failed` in the kernel log.
- With `0004`: an `amixer` change to `tas2783-1 Amp Volume` survives the
  sink suspending and resuming.
- With `0005`: `journalctl -k` shows no `fw request, wait_event timeout`, and
  the card still comes up with the tuning firmware loaded.
- That `0003`–`0006` compile against the `linux-neptune-72` headers (CI).
