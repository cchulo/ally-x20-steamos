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

## Patches taken from upstream

Kernel patches backported from other trees keep their original `From:`
author, date and trailers: `0003`-`0006` (Matthew Schwartz, Valve
`7.2.10-valve1`) and `0020` (Derek J. Clark, mainline `148794d9f0d2`). They
are GPL-2.0, like the rest of `patches/kernel/`. The gamescope and
libdisplay-info patches likewise keep their upstream authors and stay under
the licenses in the table above. The full list of projects and people this
repository builds on is in the [README's Credits section](README.md#credits).

## Things we deliberately do not commit

- **TAS2783 amplifier tuning firmware**: downloaded at install time from
  [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)
  under the redistribution terms in its `WHENCE` file. Pinned commit and
  SHA-256 sums live in `firmware/tas2783.lock`.
- **Prebuilt kernel modules** (`*.ko`): never in git. CI may attach prebuilt
  artifacts to releases together with SHA-256 sums and the exact source commit.
