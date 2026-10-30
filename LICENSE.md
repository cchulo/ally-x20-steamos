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
| `patches/gamescope/*` | BSD-2-Clause | [ValveSoftware/gamescope](https://github.com/ValveSoftware/gamescope) |
| `patches/libdisplay-info/*` | MIT | [emersion/libdisplay-info](https://gitlab.freedesktop.org/emersion/libdisplay-info) |
| `overlay/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml` | GPL-3.0-or-later | InputPlumber upstream device profile (PR #756) |
| `overlay/inputplumber/devices.d/50-rog_xbox_ally_x20.stock.yaml` | GPL-3.0-or-later | the same profile adapted for older InputPlumber daemons (changes listed in its header) |
| `overlay/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml` | GPL-3.0-or-later | InputPlumber upstream `ally_type2.yaml` capability map (v0.83.0), renamed id |

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
