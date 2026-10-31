# TAS2783 amplifier tuning firmware

The X20's two TI TAS2783 smart amps need a per-model tuning file each. TI
publishes them in [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/ti/audio/tas2783).
We never commit them: `fetch-tas2783.sh` downloads them at install time from a
pinned commit and checks their SHA-256 (`tas2783.lock`).

## Which files, and why the names do not match

The X20's audio PCI subsystem id is `1043:1954`. The amps sit on SoundWire
link 0 with unique ids `0x8` (left) and `0xB` (right).

| Kernel | Name requested (at the firmware root) | Source |
|---|---|---|
| v7.2.7 (SteamOS `7.2.7-valve2`) | `1954-0-0x8.bin`, `1954-0-0xB.bin`; on failure `1954-0-8.bin`, `1954-0-B.bin` | `sound/soc/codecs/tas2783-sdw.c`, `tas_generate_fw_name()`: `"%04X-%1X-%s%1X.bin"` (subsystem device, link id, `0x` prefix unless falling back, unique id) |
| with "ASoC: tas2783-sdw: use the BIOS speaker ID in the firmware name" (Valve `7.2.10-valve1`, commit `8ba654cb1c44`) | `1954-<SPEAKER_ID>-0-0x8.bin`, `1954-<SPEAKER_ID>-0-0xB.bin` first, then the three-field names | same function, `"%04X-%X-%1X-0x%1X.bin"` |

linux-firmware (pinned commit `a2dcb924f0897368b0b4f305cbf9808cdda90ce0`)
ships only four-field files, `ti/audio/tas2783/1954-<speaker id>-<link>-0x<uid>.bin`,
plus `WHENCE` `Link:` entries with the same four-field names at the firmware
root. Nothing provides the three-field name v7.2.7 asks for, so the stock
driver finds no tuning and the speakers stay silent.

The speaker id is the speaker supplier. The BIOS stores it in the UEFI
variable `SPEAKER_ID-aa61eaaf-6e83-7523-b0d0-7df74bb24a81` (GUID confirmed by
both hungarianhc's installer and the `TAS2783_SPKID_GUID` in the kernel commit
above). efivarfs prepends a 4-byte attribute word; the value follows as a
little-endian integer.

| SPEAKER_ID | Supplier | Files |
|---|---|---|
| 0 | JGX | `1954-0-0-0x8.bin`, `1954-0-0-0xB.bin` |
| 1 | LS | `1954-1-0-0x8.bin`, `1954-1-0-0xB.bin` |

`TODO(hw)`: the value-to-supplier names come from
[hungarianhc/rog-ally-x20-steamos-speakers](https://github.com/hungarianhc/rog-ally-x20-steamos-speakers)
only (`speaker-id.map`). [stoneharborent/aquarius-os PR #40](https://github.com/stoneharborent/aquarius-os/pull/40)
uses the value directly as the file's supplier digit (the part that matters)
and reports only value 1 as bench-proven. The SHA-256 sums in `tas2783.lock`
were computed from the pinned commit and match hungarianhc's installer.

## What gets installed

Everything goes under `/etc/ally-x20-steamos/firmware/` (shared by both
A/B slots) and is recorded in the manifest:

```
ti/audio/tas2783/1954-<id>-0-0x8.bin    verified copy from linux-firmware
ti/audio/tas2783/1954-<id>-0-0xB.bin
1954-<id>-0-0x8.bin -> ti/audio/...      four-field name (newer kernels)
1954-<id>-0-0xB.bin -> ti/audio/...
1954-0-0x8.bin      -> ti/audio/tas2783/1954-<chosen>-0-0x8.bin   bare name (v7.2.7)
1954-0-0xB.bin      -> ti/audio/tas2783/1954-<chosen>-0-0xB.bin
supplier                                 only after an explicit --supplier
```

Supplier choice, first match wins: `--supplier JGX|LS` (or
`AX20_SPEAKER_SUPPLIER`), a saved earlier override (`supplier`), the
`SPEAKER_ID` variable through `speaker-id.map`.

**Unknown supplier**: both pairs are downloaded and get their four-field links
(unambiguous, enough for newer kernels), but the bare v7.2.7 names are **not**
created. Both suppliers share those names, and loading another supplier's
tuning means wrong speaker-protection limits, so we refuse to guess. Run
`sudo firmware/fetch-tas2783.sh --supplier JGX|LS` (the choice is remembered
for later applies).

## How the kernel finds files outside /usr/lib/firmware

The firmware loader searches `firmware_class.path` first, then
`/lib/firmware/updates/<kver>`, `/lib/firmware/updates`,
`/lib/firmware/<kver>`, `/lib/firmware` (`drivers/base/firmware_loader/main.c`,
`fw_path[]`). Only one extra directory can be configured. We set it to
`/etc/ally-x20-steamos/firmware` in three ways:

1. **modprobe hook** (`/etc/modprobe.d/ally-x20-steamos-audio.conf`): an
   `install snd_soc_tas2783_sdw` line writes
   `/sys/module/firmware_class/parameters/path` right before the amp driver
   loads, unless the path is already set. Works on every boot without
   touching the boot entry.
2. **sysfs at apply time** (`audio_apply`, live root only): same write, so the
   current boot can pick the files up if the driver probes again.
3. **Kernel command line** for the boot-entry step: `audio_kernel_cmdline`
   prints `firmware_class.path=/etc/ally-x20-steamos/firmware`. The
   slots/boot-entry code may append it to the active slot's entry; it then
   wins over the hook (which never overrides a set path).

If something else already set `firmware_class.path`, we leave it alone and
`apply` warns.

## Redistribution terms

From linux-firmware `WHENCE` at the pinned commit, entry
`Driver: ti-tas2783 - tas2783 firmware`:

> Licence: Redistributable. LICENCE.ti-tspa for details. Marked:
> SPDX-License-Identifier: LicenseRef-LICENCE.ti-tspa
> Copyright (C) 2026 Texas Instruments

Full text: [`LICENCE.ti-tspa`](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/LICENCE.ti-tspa?id=a2dcb924f0897368b0b4f305cbf9808cdda90ce0).
We do not redistribute the files; each device downloads them from
linux-firmware directly.

## Updating the pin

1. Pick a linux-firmware commit, download the files with
   `?id=<commit>`, compute `sha256sum`.
2. Update `commit` and the `file` lines in `tas2783.lock` in one commit.
3. `make check` (the lock parser test reads the real lock).

Download sources, tried in order: `git.kernel.org/.../linux-firmware.git/plain/<path>?id=<commit>`,
then the upstream GitLab mirror `gitlab.com/kernel-firmware/linux-firmware/-/raw/<commit>/<path>`.
`AX20_FIRMWARE_SOURCE_DIR=<linux-firmware checkout>` copies from a local tree
instead (offline installs, tests); the digest is checked either way.
