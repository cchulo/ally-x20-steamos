# TAS2783 firmware names on RC74XA

This file is input for `firmware/tas2783.lock`, which pins the firmware. We
never commit firmware. It is downloaded at install time from linux-firmware,
whose `WHENCE` file covers redistribution (`LICENCE.ti-tspa`).

## What the v7.2.7 driver requests

The codec is `sound/soc/codecs/tas2783-sdw.c` (module `snd-soc-tas2783-sdw.ko`).
In linux-stable `v7.2.7` and Valve `7.2.7-valve2` the file is byte-identical
(blob `4fbbf2ca5bf9`). `tas_generate_fw_name()` builds the name from the
**ACP PCI device's subsystem ID**, the **SoundWire link** and the amp's
**unique ID**:

```c
scnprintf(name, size, "%04X-%1X-%s%1X.bin",
          pci->subsystem_device, bus->link_id, fw_uid_prefix, unique_id);
/* fw_uid_prefix is "0x" on the first try and "" on the fallback try */
/* if the device has no PCI parent: "tas2783-%1X-%1X.bin" (link, uid)   */
```

It calls `request_firmware_nowait()` with that bare name: no `ti/…`
directory, so the loader looks for it at the firmware search root. On RC74XA
(ACP `1022:15e2`, subsystem `1043:1954`, amps on link 0 with uids `0x8` and
`0xB`) it requests:

| Amp | First try | Fallback |
|---|---|---|
| `tas2783-1` (uid 0x8) | `1954-0-0x8.bin` | `1954-0-8.bin` |
| `tas2783-2` (uid 0xB) | `1954-0-0xB.bin` | `1954-0-B.bin` |

Hex digits are upper case (`%X`).

## What linux-firmware ships

linux-firmware ships `ti/audio/tas2783/1954-<SPKID>-<link>-0x<uid>.bin`, with
an extra speaker-supplier field. `WHENCE` adds root-level `Link:` entries
with the same four-field names (`1954-0-0-0x8.bin -> ti/audio/tas2783/…`). No
shipped name matches what the driver requests, so the amps get no tuning. The
same mismatch is reported upstream for other boards: "tas2783-sdw: firmware
shipped for some boards cannot be requested by the driver",
<https://ratatoskr.run/linux-sound/2026/08/17413658>.

Files for RC74XA (link 0). Hashes were checked at linux-firmware
`a2dcb924f0897368b0b4f305cbf9808cdda90ce0` (the commit hungarianhc pins) and
were unchanged at `33af2bf0c14509fca10a2fd53fecd6282484a6f0` (2026-10-30).
Each file is 40746 bytes.

| Supplier | `SPEAKER_ID` | linux-firmware file | Install as | SHA-256 |
|---|---|---|---|---|
| JGX | 0 | `ti/audio/tas2783/1954-0-0-0x8.bin` | `1954-0-0x8.bin` | `e37c3efa1e92e72614175682c01cdcd4ceb7079878e8bafd3177c5a45dede434` |
| JGX | 0 | `ti/audio/tas2783/1954-0-0-0xB.bin` | `1954-0-0xB.bin` | `655eb8754afc7284850988f330b6466ad782b7ae905ab7246621375a4784a8be` |
| LS | 1 | `ti/audio/tas2783/1954-1-0-0x8.bin` | `1954-0-0x8.bin` | `677e3d033dcc8effc5247b771a5ecd08484c3740d0086b4cd333b07af06eb563` |
| LS | 1 | `ti/audio/tas2783/1954-1-0-0xB.bin` | `1954-0-0xB.bin` | `0d50eae7ae4f515304f4e8ce14832654ebf3447711c283bdbf7c175c9298de1d` |

Install exactly one pair, chosen by `SPEAKER_ID`. Both pairs map to the same
requested names, so they cannot coexist in one firmware directory. The
`1954-*-1-*` files are for link 1 (not this board's wiring) and are not used.

## Choosing the pair: `SPEAKER_ID`

- EFI variable `SPEAKER_ID-aa61eaaf-6e83-7523-b0d0-7df74bb24a81`. In efivarfs
  this is 4 bytes of attributes followed by a little-endian `u32` value.
- Value `0` means JGX and `1` means LS. This mapping comes from hungarianhc's
  `ally-audio-fix.sh`. TI's linux-firmware commit
  (`2f90f4fe5c67`, "ASoC: tas2783: Add Firmware files for tas2783A projects")
  does not name the suppliers. `TODO(hw)`: confirm the value on our unit and
  the supplier mapping.
- stoneharborent/aquarius-os PR #40 reports that only speaker ID 1 was proven
  on hardware.

## Where to install

The requested names live at the firmware root, and `/usr/lib/firmware` is
read-only on SteamOS. Prior work puts the renamed pair in a directory under
`/var/lib/...` and sets `/sys/module/firmware_class/parameters/path` to it
before `snd_soc_tas2783_sdw` loads, from a modprobe `install` hook
(hungarianhc). The custom path is searched before the built-in directories.
Plain `.bin` is fine there. The loader tries uncompressed files first.

## Newer kernels

Valve `7.2.10-valve1` adds `8ba654cb1c44` "[FOR-UPSTREAM] ASoC: tas2783-sdw:
use the BIOS speaker ID in the firmware name". That kernel reads `SPEAKER_ID`
itself and first requests the four-field name `1954-<SPKID>-0-0x<uid>.bin`.
That name matches linux-firmware's root-level links, so no renamed copy is
needed. A probe can check for this by looking for the `SPEAKER_ID` string in
`snd-soc-tas2783-sdw.ko`, or by testing whether the four-field file loads
without our copy (`TODO(hw)`).
