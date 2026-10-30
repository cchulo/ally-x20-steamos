# UCM files taken from alsa-ucm-conf

The files below are copied **verbatim** from
[alsa-project/alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf)
and stay under its BSD-3-Clause license (full text, including the copyright
notice, in [`LICENSE.alsa-ucm-conf`](LICENSE.alsa-ucm-conf)). Upstream files
carry no per-file license header, so none is added here either; they are listed
in `LICENSE.md` and `scripts/spdx-exceptions.txt` instead.

| Path here | Upstream path | sha256 |
|---|---|---|
| `sof-soundwire/tas2783.conf` | `ucm2/sof-soundwire/tas2783.conf` | `4b1e9e57c0f54194987b9b1db96de0ef5cfd1af106ecf9ac18df27a41355b163` |
| `codecs/tas2783/init.conf` | `ucm2/codecs/tas2783/init.conf` | `fe6a4518913dc2dadc1ae707179dbec7b6e77cfa5df79d961d48ff9c649b4c84` |

- Fetched from `master` at commit
  [`d260eedd1900dbf3b477047e048d5382a5f50e24`](https://github.com/alsa-project/alsa-ucm-conf/tree/d260eedd1900dbf3b477047e048d5382a5f50e24)
  (2026-10-09).
- Both files were introduced by
  [`182d0122a7d9`](https://github.com/alsa-project/alsa-ucm-conf/commit/182d0122a7d98cfa5f2d42d3cb8e9e1b8697b69a)
  "ucm2: sof-soundwire: Add tas2783 support" (2026-08-21, PR #812) and have
  not changed since.
- Raw URL pattern:
  `https://raw.githubusercontent.com/alsa-project/alsa-ucm-conf/<sha>/ucm2/<path>`

## What we deliberately did not copy

The same upstream commit also adds `tas2783` to the speaker-init filter in
`ucm2/sof-soundwire/sof-soundwire.conf`, which makes the card's BootSequence
include `codecs/tas2783/init.conf`. We do **not** ship a replacement
`sof-soundwire.conf`: it is the dispatcher for every SoundWire machine and a
newer copy can depend on alsa-lib syntax the stock SteamOS alsa-lib does not
have. Consequences:

- `sof-soundwire/tas2783.conf` (the `Speaker` device, what PipeWire needs to
  stop showing "Dummy Output") is used by the stock dispatcher, because
  `HiFi.conf` includes `/sof-soundwire/${var:SpeakerCodecFile}.conf` for any
  speaker codec the kernel reports (`spk:tas2783` in the card components).
- `codecs/tas2783/init.conf` is inert with a stock dispatcher that predates the
  filter change; it is shipped so the overlay is complete once SteamOS's
  dispatcher catches up. hungarianhc/rog-ally-x20-steamos-speakers ships only
  `tas2783.conf` and reports working speakers on SteamOS 3.9.3, so the init
  sequence does not appear to be required. `TODO(hw)`: confirm the
  `Left Spk`/`Right Spk` DAPM switches default to on.

## Refreshing

```sh
sha=$(gh api repos/alsa-project/alsa-ucm-conf/commits/master --jq .sha)
for p in sof-soundwire/tas2783.conf codecs/tas2783/init.conf; do
    curl -fsSL "https://raw.githubusercontent.com/alsa-project/alsa-ucm-conf/$sha/ucm2/$p" -o "overlay/ucm2/$p"
done
```

Update the commit and digests above in the same commit.
