# Licensing

`ally-x20-steamos` is licensed under **GPL-2.0-only** (see [`LICENSE`](LICENSE)).
The kernel patches under `patches/kernel/` are derivative works of GPL-2.0 code,
so the repository as a whole uses the same license as the Linux kernel. Every
source and script file carries an SPDX header:

```
# SPDX-License-Identifier: GPL-2.0-only
```

## Per-file exceptions

The files below are kept **verbatim under their original license**. They are
listed in [`scripts/spdx-exceptions.txt`](scripts/spdx-exceptions.txt) so the
SPDX header check skips them.

| Path | License | Origin |
|---|---|---|
| `overlay/ucm2/sof-soundwire/tas2783.conf` | BSD-3-Clause | [alsa-project/alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) |
| `overlay/ucm2/codecs/tas2783/init.conf` | BSD-3-Clause | [alsa-project/alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf) (pinned commit and license text in `overlay/ucm2/UPSTREAM.md` and `overlay/ucm2/LICENSE.alsa-ucm-conf`) |
| `patches/inputplumber/*` (fallback path only) | GPL-3.0-or-later | [ShadowBlip/InputPlumber](https://github.com/ShadowBlip/InputPlumber) |
| `patches/gamescope/*` | BSD-2-Clause | [ValveSoftware/gamescope](https://github.com/ValveSoftware/gamescope) (PR #2493); license text in `patches/gamescope/LICENSE` |
| `patches/libdisplay-info/*` | MIT | [emersion/libdisplay-info](https://gitlab.freedesktop.org/emersion/libdisplay-info) (DisplayID 2 backport onto 0.3.0); license text in `patches/libdisplay-info/LICENSE` |
| `overlay/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua` | BSD-2-Clause | gamescope `scripts/00-gamescope/displays/asus.rogallyx20.oled.lua` (PR #2493), unchanged except for a provenance header and a guard that skips it when stock gamescope already defines the profile |
| `overlay/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml` | GPL-3.0-or-later | InputPlumber upstream device profile (PR #756) |
| `overlay/inputplumber/devices.d/50-rog_xbox_ally_x20.stock.yaml` | GPL-3.0-or-later | the same profile adapted for older InputPlumber daemons (changes listed in its header) |
| `overlay/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml` | GPL-3.0-or-later | InputPlumber upstream `ally_type2.yaml` capability map (v0.83.0), renamed id |
| `overlay/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml` | MIT | [holo/steamos-manager](https://gitlab.steamos.cloud/holo/steamos-manager) `data/devices/rog-ally-series.toml` RC74XA entry (commit `bfbb261ed6b2`), rewritten in the 26.4.1 schema (header in the file) |

## Things we deliberately do not commit

- **TAS2783 amplifier tuning firmware**: downloaded at install time from
  [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)
  under the redistribution terms in its `WHENCE` file. Pinned commit and
  SHA-256 sums live in `firmware/tas2783.lock`.
- **HRTF (SOFA) data sets** for the headphone virtual-surround chain: downloaded
  at install time; each set's license and source URL are recorded in
  `overlay/home/hrtf/hrtf.lock`.
- **Prebuilt kernel modules** (`*.ko`): never in git. CI may attach prebuilt
  artifacts to releases together with SHA-256 sums and the exact source commit.

## HRTF data sets (downloaded, never committed)

The headphone virtual surround (`components/audio_dsp.sh`) downloads these
SOFA files from the [SOFA conventions database](https://sofacoustics.org/data/database/)
into `~/.config/ally-x20-steamos/hrtf/` and verifies them against
`overlay/home/hrtf/hrtf.lock`. They keep their original terms; none of them
is part of the GPL-2.0 code.

| Set (`hrtf.lock` name) | License | Source | Attribution |
|---|---|---|---|
| `mit-kemar` (default) | No usage restrictions; citation requested (`LicenseRef-MIT-KEMAR`) | [mit_kemar_normal_pinna.sofa](https://sofacoustics.org/data/database/mit/mit_kemar_normal_pinna.sofa) | B. Gardner and K. Martin, "HRTF Measurements of a KEMAR", J. Acoust. Soc. Am. 97(6), 1995; MIT Media Lab. SOFA conversion by ARI. |
| `hutubs-pp1` | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | [pp1_HRIRs_measured.sofa](https://sofacoustics.org/data/database/hutubs/pp1_HRIRs_measured.sofa) | HUTUBS database, TU Berlin Audio Communication Group, HUAWEI Munich Research Center, Sennheiser; F. Brinkmann et al., J. Audio Eng. Soc. 67(9), 2019. |
| `cipic-003` | CIPIC terms: any purpose, keep the copyright notice (`LicenseRef-CIPIC`) | [subject_003.sofa](https://sofacoustics.org/data/database/cipic/subject_003.sofa) | Copyright (c) 2001 The Regents of the University of California, CIPIC Interface Laboratory; V. R. Algazi et al., "The CIPIC HRTF Database", IEEE WASPAA 2001. |

## libmysofa (fallback build only, never committed)

`build/build-libmysofa.sh` builds [libmysofa](https://github.com/hoene/libmysofa)
(BSD-3-Clause, Copyright (c) 2016-2017 Symonics GmbH, Christian Hoene) from a
pinned tag, only for systems whose PipeWire has the sofa plugin but lacks the
library. Its license file is installed next to the library.
