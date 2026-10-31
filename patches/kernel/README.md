# Kernel patches

Kernel patches for the ROG Xbox Ally X20 (board `RC74XA`) on stock SteamOS.
Each file is in `git format-patch` format and applies with `git apply` or
`patch -p1` from the top of a kernel tree. They are derivative works of
GPL-2.0 kernel code and are licensed GPL-2.0-only (see `LICENSE.md`).

This file documents the two speaker-audio patches (plan §1.1, problems 1
and 2), listed in `modules.list`. The `hid-asus-ally` patches (`0010`–`0012`,
joystick-ring RGB in Steam, Aura effects, Quick Access `0xa0`) are documented
in [`README-hid.md`](README-hid.md) and listed in `modules-hid.list`. The
build script reads every `modules*.list` file. Note the difference in source
trees: the audio patches apply to linux-stable `v7.2.7` and Valve's tree
alike, while `hid-asus-ally.c` exists only in Valve's tree.

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
still works on that kernel is `TODO(hw)`.

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
`sound/soc/amd/acp-config.c` by `sound/soc/amd/Makefile`. Note that
`make M=sound/soc/amd` also descends into every configured subdirectory
(`acp/`, `ps/`, `yc/`, …), so it builds more than this one module. Install only
the `.ko` listed in `modules.list`.

**Load order caveat:** `snd_pci_ps` calls `snd_amd_acp_find_config()`, so the
patched `snd-acp-config` must be the one loaded when `snd_pci_ps` probes. If
the stock module is in the initramfs and loads early, the stock flag wins.
`TODO(hw)`: check `lsinitcpio` / dracut contents on SteamOS.

## `modules.list`

One line per patch, tab-separated, no header or comments:

```
<patch file>	<make M= directory, relative to the kernel tree>	<resulting .ko file name>
```

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
