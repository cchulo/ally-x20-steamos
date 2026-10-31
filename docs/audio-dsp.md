# Audio DSP: headphone and speaker virtual surround, speaker chain

Component `audio_dsp` ([`components/audio_dsp.sh`](../components/audio_dsp.sh)),
command `ally-x20-steamos audio-dsp`, plan section 1.5. It is required and
installed by default. Everything it adds lives in the `deck` user's home, so
SteamOS updates do not touch it and the read-only root stays read-only.

It adds four sinks. Every stream plays on the default sink: the one Steam's
output setting points at, either picked by hand or "Default" (automatic,
see "Automatic output selection"). Nothing moves single streams between
sinks.

| Sink (Steam name) | `node.name` | Use | Processing | Automatic default? |
|---|---|---|---|---|
| X20 Speakers (downmix + width + EQ) | `x20-speakers` | built-in speakers, stereo | surround downmixed to stereo, stereo width, EQ, LFE low-pass, master gain | on the speakers (default) |
| X20 Speakers (virtual surround) | `x20-speakers-surround` | built-in speakers, surround | each channel through an HRTF at its 7.1 angle, crosstalk cancellation, then the `x20-speakers` chain | on the speakers with `stereo-surround on` |
| X20 headphone surround 7.1 (headphones only) | `x20-virtual-surround-71` | headphones | each channel through an HRTF at its 7.1 angle, summed to 2 ears | on any headphones (default) |
| X20 headphone surround 5.1 (headphones only) | `x20-virtual-surround-51` | headphones | same, 5.1 angles | no (manual pick only) |

Where the outputs of the sinks go:

| Output stream | Goes to | How |
|---|---|---|
| `x20-speakers.output` | the hardware speaker sink, `alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink` | pinned in the conf (`target.object`, `node.dont-fallback`) |
| `x20-speakers-surround.output` | `x20-speakers` (one EQ for both speaker paths) | pinned in the conf (`target.object`) |
| `x20-virtual-surround-71.output`, `-51.output` | the best available headphone sink: the jack while its route is available, a USB or Bluetooth headset | WirePlumber hook; stays unlinked when no headphones are available |

The hardware speaker sink name is what PipeWire's ACP calls the speaker PCM
of the UCM `HiFi` verb on this SoC: `alsa_output.` + the PCI path of the ACP
(the AMD audio coprocessor, `0000:64:00.5`) + `-platform-amd_sdw.` +
`HiFi__Speaker__sink`. The jack is
`alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Headphones__sink`.
Both measured on the X20 (SteamOS 3.9.5).

### What happened (the silent `x20-speakers` bug)

With `x20-speakers` picked as the output in Steam, nothing was audible.
`x20-speakers.output` had no target, so WirePlumber linked it like any
stream: to the default sink. The default was `x20-speakers` itself, which a
filter cannot feed (same link group). The old router, and WirePlumber's own
fallback, then took "the non-x20 sink with the highest `priority.session`".
On the X20 that is the headphone jack sink (1000, against 712 for the
speaker sink), and it stays in the graph with nothing plugged in: its route
`[Out] Headphones` is only marked `not available`. The game stream went into
the chain, and the chain played into an unplugged jack. Only the speaker
surround chain worked, because its output was already pinned.

The fix: `x20-speakers.output` is pinned to the speaker sink by name and
never falls back. The per-stream router (streams sent to one sink or
another by channel count) is gone; the default sink decides, picked by hand
in Steam or by the automatic output selection below.
The headphone surround outputs only ever go to headphones that are
available, never to the speakers and never to an x20 sink.

## Design

### Automatic output selection

With Steam's output on "Default", WirePlumber picks the default sink. Its
own rule takes the available sink with the highest `priority.session`
(measured on the X20: speaker sink 712, headphone jack sink 1000 and only
while a plug is in; USB and Bluetooth headsets 1000 or more). Our hook
`x20/select-default-sink`
([`x20-select-default-sink.lua`](../overlay/home/wireplumber/scripts/x20-select-default-sink.lua))
runs right after that choice and before it is applied, and swaps a hardware
choice for its processed counterpart, so every output gets the same
experience:

| Situation | WirePlumber's own choice | Automatic default with our hook | Processing |
|---|---|---|---|
| nothing plugged in | speaker sink (or `x20-speakers`, 750) | `x20-speakers` (`x20-speakers-surround` with `stereo-surround on`) | speaker chain (or speaker virtual surround) |
| jack plugged in | jack sink (1000) | `x20-virtual-surround-71` -> jack | 7.1 HRTF |
| USB headset/headphones | USB sink | `x20-virtual-surround-71` -> USB sink | 7.1 HRTF |
| Bluetooth headphones | `bluez_output...` sink | `x20-virtual-surround-71` -> Bluetooth sink | 7.1 HRTF |
| HDMI/DP, line out, other | that sink | unchanged | none (a receiver decodes surround itself) |
| any sink picked by hand in Steam | that sink | unchanged | whatever that sink does |

Plugging and unplugging switch automatically, like on Windows:
WirePlumber's `default-nodes/rescan-trigger` schedules a new
`select-default-node` event when sinks come and go and on device `Route`
changes (ALSA jack detection), and the hook runs again each time. The
headphone surround output follows the same way (see "Headphone surround
outputs"); both use one device classification
([`x20-sink-facts.lua`](../overlay/home/wireplumber/scripts/lib/x20-sink-facts.lua)
and `x20-route-core.lua`), so the default and the output target agree.

Bluetooth: the sink receives a plain stereo stream, and binaural rendering
is stereo, so the HRTF works there too. A Bluetooth sink that reports
`device.form-factor = speaker` is left alone.

Manual picks: a default the user chose (Steam's manual pick, stored as
`default.configured.audio.sink`) is ranked by WirePlumber above 15000
(30000 + priority, 19xxx-20000 for the history of earlier picks). The hook
never touches it. Choosing "Default" in Steam clears the pick and the
history, and the hook applies again. The 5.1 headphone sink is only a
manual pick.

Settings:

| Command | Default | Effect |
|---|---|---|
| `sudo ally-x20-steamos audio-dsp speakers-precedence on\|off` | on | off: the speakers stay on the bare hardware sink in automatic mode (no substitution, both speaker sinks at priority 50). Re-renders the confs and restarts PipeWire |
| `sudo ally-x20-steamos audio-dsp headphones-virtual-surround on\|off` | on | off: headphones stay on the bare headphone sink in automatic mode. Applied to the running session at once (`wpctl settings`) |
| `sudo ally-x20-steamos audio-dsp stereo-surround on\|off` | off | on: `x20-speakers-surround` instead of `x20-speakers` on the speakers. Restarts PipeWire (it also swaps the priorities) |

Raw hardware output: pick the hardware "Speakers" or "Headphones" in Steam
by hand, or turn the matching setting off.

Priorities: with `speakers-precedence on`, `x20-speakers` has
`priority.session` 750 and `x20-speakers-surround` 740 (swapped with
`stereo-surround on`): above the hardware speakers (712) and below every
headphone output (1000 or more). The hook alone decides between the two
speaker sinks; the priorities only help tools that look at priorities, and
keep the DSP the automatic default if the hook fails to load. They are
rendered into the PipeWire confs. The headphone surround sinks stay at 50: a
static priority cannot know whether headphones are present, so the hook
does that part.

The trade-off: on the speakers the automatic default is an 8-channel sink
(7.1, so surround keeps its channels until the downmix). Games that query
the default device's layout see 7.1 and render 7.1; the chain folds it back
to stereo (or renders it, on `x20-speakers-surround`). That costs a little
CPU in the game and in the chain, and the downmix is ours instead of the
game's. A game that offers a speaker-layout setting can be set to stereo.
Stereo streams are unaffected: they fill FL/FR only (see "Why no upmix").

### Headphone surround outputs

The two headphone sinks render binaural stereo, which only works on
headphones. Their outputs have no `target.object`; a WirePlumber 0.5 event
hook (`x20/route-by-channels`, file name historical) on the `select-target`
event picks the target:

- candidates are hardware sinks only (never an `x20-` sink);
- a sink qualifies when its `device.form-factor` is `headphone`, `headset`
  or `hands-free` (USB and Bluetooth), when it is a Bluetooth sink
  (`device.api = bluez5`) that does not report `speaker`, or when the active `Route` of its
  ALSA device is a headphone/headset route (name, description or
  `port.type`) that is not `available = no` (UCM `[Out] Headphones`, ACP
  `analog-output-headphones`). A speaker route never qualifies;
- the default sink wins if it qualifies, otherwise the highest
  `priority.session`;
- nothing qualifies: the output stays unlinked (the hook stops the event,
  like `node.dont-fallback`), so binaural audio never reaches the speakers.

Explicit targets always win: our pinned outputs, and an output the user
moved in pavucontrol or with `wpctl`/`pw-metadata`. Application streams are
not touched at all. Re-evaluation needs no extra code: WirePlumber rescans
every stream when a device's `Route` parameter changes (ALSA jack
detection) and when nodes come and go (a headset connecting).

The decision is a pure Lua function
([`x20-route-core.lua`](../overlay/home/wireplumber/scripts/lib/x20-route-core.lua))
fed with plain tables by thin glue
([`x20-route-by-channels.lua`](../overlay/home/wireplumber/scripts/x20-route-by-channels.lua)),
so it is unit-tested without WirePlumber
([`tests/lua/test_x20_route_core.lua`](../tests/lua/test_x20_route_core.lua),
cases in [`tests/fixtures/audio_dsp/routing-cases.txt`](../tests/fixtures/audio_dsp/routing-cases.txt)).

Two headphone sinks (5.1 and 7.1) instead of one 7.1 sink with a layout
switch: the surround speakers sit at different angles in the two layouts
(ITU-R BS.775: 5.1 surrounds at +-110 deg; 7.1 sides at +-90 deg and rears
at +-150 deg), and the HRTF angles are filter controls shared by every
stream on a sink. An idle sink does no processing; the HRTF data is loaded
once (`mysofa_open_cached`).

### Pinned speaker output

`x20-speakers.output` carries `target.object` (the speaker sink name above),
`node.dont-fallback = true` and `node.linger = true`. WirePlumber's
`find-defined-target` hook links it to that sink. If the sink does not exist
(card profile changed, during start-up), it waits unlinked instead of
falling back to the default sink, which could be the chain itself or the
jack. `node.linger` matters: without it WirePlumber destroys a stream whose
defined target is missing. `node.passive = true` stays, so an idle chain
does not keep the amplifiers awake.

### Why no upmix

PipeWire's channel mixer upmixes by default when a stream has fewer channels
than its sink. Stereo gets copied into the centre, LFE and surrounds, and 5.1
rears get copied into 7.1 sides. In front of an HRTF renderer that turns
stereo into a fake 7.1 field and doubles 5.1 surrounds. The two `no-upmix`
fragments set `channelmix.upmix = false` for every PulseAudio and native
client stream:

- [`pipewire-pulse.conf.d/50-x20-no-upmix.conf`](../overlay/home/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf)
- [`client.conf.d/50-x20-no-upmix.conf`](../overlay/home/pipewire/client.conf.d/50-x20-no-upmix.conf)

Downmixing (more channels into fewer) still works. A stereo stream on any of
the 8-channel x20 sinks drives only FL/FR: on `x20-speakers` it passes the
downmix at unity, on a headphone surround sink it sits at +-30 deg, the way
stereo speakers would sound in a room. `channelmix.upmix-method` (`none`, `simple`,
`psd`) only matters when upmix is on. The comments in the fragments explain
how to experiment with it.

### "Bit-identical stereo" and how to verify it

With the hardware headphone sink as the default (picked by hand in Steam, or
automatic with `headphones-virtual-surround off`), a stereo stream is linked
straight to it.
PipeWire converts the client's samples to 32-bit float
and back to the device format. That round trip is lossless for 16-bit and
24-bit integer PCM as long as nothing else touches the samples:

- stream volume and sink volume at 100% (software volume scales samples;
  hardware mixer volume does not);
- no resampling: the file or stream rate equals the graph rate (`pw-top`
  shows both; SteamOS runs at 48 kHz);
- no other stream playing at the same time (the monitor is post-mix);
- no dithering (`dither.method` is off by default).

To verify, capture the hardware sink's monitor while playing a known file,
then compare the two:

```sh
# 10 s of random 16-bit stereo noise at 48 kHz (no file shipped in git)
python3 - /tmp/x20-noise.wav <<'PY'
import os, sys, wave
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(os.urandom(48000 * 10 * 4)); w.close()
PY
SINK=$(wpctl inspect @DEFAULT_AUDIO_SINK@ | sed -n 's/.*node.name = "\(.*\)"/\1/p')
wpctl set-volume @DEFAULT_AUDIO_SINK@ 1.0
pw-record --target "$SINK" -P '{ stream.capture.sink = true }' \
    --rate 48000 --channels 2 --format s16 /tmp/x20-capture.wav &
sleep 1; pw-play /tmp/x20-noise.wav; sleep 1; kill %1
# find the played data inside the capture, extract it and compare
python3 - /tmp/x20-noise.wav /tmp/x20-capture.wav <<'PY'
import sys, wave
a = wave.open(sys.argv[1]).readframes(1 << 30)
b = wave.open(sys.argv[2]).readframes(1 << 30)
i = b.find(a[:4096])
open('/tmp/x20-a.raw', 'wb').write(a)
open('/tmp/x20-b.raw', 'wb').write(b[i:i + len(a)] if i >= 0 else b'')
print('offset', i)
PY
cmp /tmp/x20-a.raw /tmp/x20-b.raw && echo "bit-identical"
```

Run the same with an x20 sink as the default: `cmp` must then report a
difference, since the stream goes through a filter. TODO(vm): run this in the
SteamOS VM (plan section 6) and on the X20.

## Files

All entries are in the manifest with slot `home` and owned by `audio_dsp`.

| Path (in the user's home) | Source |
|---|---|
| `.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf` | rendered from [`overlay/home/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf`](../overlay/home/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf) with the absolute HRTF path and the LFE settings |
| `.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf` | rendered from [`51-x20-speaker-chain.conf`](../overlay/home/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf), or the `-lsp` variant, with the LFE, master gain and priority settings |
| `.config/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf` | rendered from [`52-x20-speaker-surround.conf`](../overlay/home/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf) with the HRTF path, the XTC parameters and the priority |
| `.config/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf` | copied |
| `.config/pipewire/client.conf.d/50-x20-no-upmix.conf` | copied |
| `.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf` | copied (loader of both hooks, settings schema) |
| `.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf` | rendered (`x20.speakers_precedence`, `x20.headphones_virtual_surround`, `x20.stereo_surround`; `x20.stereo_hrtf` and `x20.speaker_surround` for compatibility only) |
| `.local/share/wireplumber/scripts/x20-route-by-channels.lua` | copied |
| `.local/share/wireplumber/scripts/x20-select-default-sink.lua` | copied |
| `.local/share/wireplumber/scripts/lib/x20-route-core.lua` | copied |
| `.local/share/wireplumber/scripts/lib/x20-sink-facts.lua` | copied |
| `.config/ally-x20-steamos/hrtf/<set>.sofa`, `current.sofa` | downloaded and verified, symlink |
| `.config/ally-x20-steamos/audio-dsp.conf` | settings |

WirePlumber 0.5 loads scripts from `$XDG_DATA_HOME/wireplumber/scripts`
(`~/.local/share`), not from `~/.config/wireplumber/scripts` as 0.4 did. That
is why the Lua files live under `~/.local/share` even though the plan's first
draft listed `~/.config`.

The sofa plugin passes the file name straight to libmysofa, which does not
expand `~`. The surround confs are therefore rendered at install time with
the absolute path of `current.sofa`.

The file names of the per-stream router version are all kept, so an upgrade
(`apply` or `audio-dsp on`) rewrites them in place and adds the two new
files; nothing is left behind.

## Configuration knobs

| What | How |
|---|---|
| Turn everything off / on | `sudo ally-x20-steamos audio-dsp off` / `on` |
| Pick the output | Steam's output setting (or KDE, pavucontrol, `wpctl set-default`): "Default" (automatic), an X20 sink, or a hardware output |
| Pick an HRTF set | `ally-x20-steamos audio-dsp hrtf list`, `sudo ally-x20-steamos audio-dsp hrtf <name>` |
| Automatic default: X20 speaker DSP or bare speakers | `sudo ally-x20-steamos audio-dsp speakers-precedence on` (default) / `off` (re-renders the priorities, restarts PipeWire) |
| Automatic default: plain chain or speaker virtual surround | `sudo ally-x20-steamos audio-dsp stereo-surround off` (default: `x20-speakers`) / `on` (`x20-speakers-surround`); restarts PipeWire |
| Automatic default on headphones: virtual surround 7.1 or bare | `sudo ally-x20-steamos audio-dsp headphones-virtual-surround on` (default) / `off` (live, no restart) |
| `stereo-hrtf`, `speaker-surround` | recorded for compatibility, no effect: they steered the removed per-stream router. Pick the sink in Steam instead |
| Tune the crosstalk cancellation | `ally-x20-steamos audio-dsp xtc` (show), `sudo ally-x20-steamos audio-dsp xtc set <delay_us> <atten_db> [taps]`, `xtc reset` |
| LFE low-pass and level | `ally-x20-steamos audio-dsp lfe` (show), `sudo ally-x20-steamos audio-dsp lfe set <cutoff_hz> <gain_db>` |
| Output gain (headroom) | `ally-x20-steamos audio-dsp master-gain` (show the analysis), `sudo ally-x20-steamos audio-dsp master-gain [speakers] auto\|strict\|<dB>` |
| Force one stream somewhere | move it in pavucontrol, Steam or `wpctl`/`pw-metadata`. Explicit targets always win |
| Speaker EQ / width | edit a copy of the speaker chain under a new name (e.g. `52-my-speakers.conf`) and turn ours off. Hand edits to our files are reported as drift and replaced on the next apply |
| Target user | `AX20_AUDIO_USER`, `AX20_HOME` (default: `$SUDO_USER`, else `deck`) |

`~/.config/ally-x20-steamos/audio-dsp.conf` holds `enabled`, `hrtf`,
`stereo_hrtf` and `speaker_surround` (no effect), `speakers_precedence`
(default 1), `headphones_virtual_surround` (default 1), `stereo_surround`
(default 0),
`xtc_delay_us` (117), `xtc_attenuation_db` (4), `xtc_taps` (4),
`lfe_cutoff_hz` (120), `lfe_gain_db` (-6), `master_gain_db` (auto) and
`speakers_master_gain_db` (auto). The commands rewrite it. Out-of-range values fall back to the defaults. `apply` and the boot service read it,
so `off` stays off across reboots and updates.

## HRTF sets

Pinned in [`overlay/home/hrtf/hrtf.lock`](../overlay/home/hrtf/hrtf.lock) (URL,
SHA-256, size, license, attribution) and fetched by
[`fetch-hrtf.sh`](../overlay/home/hrtf/fetch-hrtf.sh). Licenses are listed in
[`LICENSE.md`](../LICENSE.md). No SOFA file is ever committed.

| Name | Data | Size | License |
|---|---|---|---|
| `mit-kemar` (default) | MIT KEMAR dummy head, normal pinna | 1.1 MB | no restrictions, citation requested |
| `hutubs-pp1` | HUTUBS subject pp1, measured | 1.6 MB | CC BY 4.0 |
| `cipic-003` | CIPIC subject 003 | 1.8 MB | CIPIC terms (any use, keep notice) |

Why KEMAR is the default: it is a mannequin built to average adult
anthropometry, which makes it the most neutral non-individual choice. It is
the reference set most binaural renderers ship (OpenAL Soft, PipeWire's own
examples). Its terms put no restriction on use, and it is the smallest file.
HRTFs are personal, though. If sources seem to sit inside the head or the
front/back image flips, try the other two sets. The two human-subject sets
have different ear shapes from KEMAR. All three were measured at 44.1 kHz;
libmysofa resamples them to the graph rate on load.

All sets are downloaded at install time (about 4.6 MB in total), so
switching sets later works offline. `AX20_SKIP_DOWNLOADS=1` together with
`AX20_HRTF_SOURCE_DIR=<dir with <name>.sofa>` installs from a local copy. The
files are still checked against the lock.

## Speaker chain

[`51-x20-speaker-chain.conf`](../overlay/home/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf),
sink `x20-speakers`, uses only builtin nodes that exist since PipeWire 1.0:

1. **Downmix**: 7.1 in, ITU-style coefficients (front 1.0, centre and
   surrounds 0.707). LFE is low-passed and folded in at -6 dB (see "LFE"
   below). Stereo content passes at unity gain.
2. **Width**: mid/side with `mixer` and `invert` nodes,
   `L' = (1+w)/2 L - (w-1)/2 R`, w = 1.4, with -3 dB of headroom.
3. **EQ**: 150 Hz high-pass (keeps unreproducible bass out of the micro
   speakers), +3 dB low shelf at 250 Hz, -2 dB at 3.5 kHz, +2 dB shelf at 8 kHz.
   **This preset is a placeholder tuned by ear**, not a measurement. It will
   be replaced after comparing against the Windows reference recording
   (plan section 7). TODO(hw).
4. **Limiter** (optional): when LSP Plugins' LV2 bundle is found in
   `/usr/lib/lv2/lsp-plugins.lv2` or `~/.lv2/lsp-plugins.lv2`, the
   `-lsp` variant is installed instead and appends
   `http://lsp-plug.in/plugins/lv2/limiter_stereo`. SteamOS 3.9 ships no
   general-purpose LV2/LADSPA plugins. `steamdeck-dsp` contains only Valve's
   Steam Deck speaker, microphone and binaural plugins, which are tuned for
   the Deck. TODO(hw): `ls /usr/lib/lv2 /usr/lib/ladspa` on the X20, and
   check the LSP port names with `lv2info`.
5. **Master gain**: `speakers_master_gain_db`, default unity (see
   "Headroom" below).

The plan lists a multiband compressor and a bass enhancer. Neither exists as a
builtin node, so they depend on the same optional-plugin mechanism and are
not in v0.1. Plain HRTF output is never sent to the speakers: each ear hears
both speakers, and that crosstalk destroys the binaural cues. The speaker
virtual surround below cancels the crosstalk first.

## Speaker virtual surround

[`52-x20-speaker-surround.conf`](../overlay/home/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf),
sink `x20-speakers-surround` ("X20 Speakers (virtual surround)" in Steam).
This is the open counterpart of the "Dolby Atmos for built-in speakers" mode
the X20 ships with on Windows. Pick it in Steam, or make it the automatic
default with `stereo-surround on`. Every stream on it goes through the
virtual surround, stereo included (FL/FR rendered at +-30 deg).

1. **Binaural render**: the same sofa spatializers, HRTF set
   (`current.sofa`) and 7.1 angles as `x20-virtual-surround-71`. A 5.1 stream
   fills RL/RR, so its surrounds are rendered at +-150 deg (not the +-110 deg of
   the 5.1 headphone sink). One speaker sink is enough, since accuracy at
   that level is beyond what a stereo dipole can show.
2. **Crosstalk cancellation (XTC)**: a 4-tap RACE network built from builtin
   `delay`, `invert` and `mixer` nodes. It sends an inverted, delayed,
   attenuated copy of each side to the other side, and its own crosstalk
   back. It only works between 300 Hz and 5 kHz. Bass and highs pass
   straight through. The math and the X20 numbers (speakers about 22 cm
   apart, listener at about 40 cm, 117 us, 4 dB) are in
   [`xtc-notes.md`](xtc-notes.md).
3. **LFE**: low-passed and added to both channels at -6 dB, after the
   canceller.
4. **Master gain**: `master_gain_db`, by default computed so that the whole
   speaker path stays at full scale (see "Headroom" below).
5. **Speaker chain**: the stereo result goes to `x20-speakers`
   (`target.object`), so the width and EQ stage exists once and is shared
   with the plain path.

Without the sofa plugin or the HRTF data the sink is absent.

### Listening test (A/B)

Sit as you play: device centred, about 35-45 cm from your face, ears level
with the speakers. The effect has a sweet spot of a few centimetres.

```sh
ally-x20-steamos audio-dsp test                       # channel sequence through the speaker surround
# play a 5.1/7.1 test (film trailer, game, or speaker-test below), then
# switch the output in Steam, or:
wpctl set-default "$(pw-dump | jq '.[] | select(.info.props["node.name"]? == "x20-speakers") | .id')"           # plain downmix (A)
wpctl set-default "$(pw-dump | jq '.[] | select(.info.props["node.name"]? == "x20-speakers-surround") | .id')"  # virtual surround (B)
speaker-test -D pipewire -c 6 -t wav                  # spoken channel names, 5.1
```

Switching the default moves streams that follow it within a second, without
a restart.

What to expect with surround on:

- FL/FR sound outside the chassis edges, not from the grilles.
- FC stays centred and slightly in front.
- SL/SR are pulled towards the sides, well outside the device. Rears are the
  weakest: expect "wide and a bit behind the sides", not true behind. The
  binaural front/back cue does not survive speakers this small at
  this distance.
- LFE sounds the same in both modes: low-passed at 120 Hz, then mostly
  removed by the 150 Hz high-pass.
- Dialogue may sound slightly thinner, and the surround path is about
  10 dB quieter than plain stereo. That is the XTC mid dip and the master
  gain that keeps the path from clipping (see "Headroom"). Match the volume before judging,
  because louder always sounds "better".
- Move your head 5 cm sideways and the effect collapses. That is the sweet
  spot, not a bug.

With surround off, everything stays between the speakers, wider than the
chassis only by the widener.

### Tuning

```sh
ally-x20-steamos audio-dsp xtc                # current values
sudo ally-x20-steamos audio-dsp xtc set 125 4 # delay (us), attenuation (dB), [taps]
sudo ally-x20-steamos audio-dsp xtc reset     # 117 us, 4 dB, 4 taps
```

`xtc set` re-renders the conf and restarts PipeWire, which interrupts audio
for a second. The delay moves in whole samples at 48 kHz (104, 125, 146 us).

- Image stuck at the speakers: lower the attenuation (3, 2.5).
- Phasey, hollow, pressure on the ears, thin dialogue: raise it (5-6), or
  use fewer taps (`xtc set 117 4 2`).
- Holding the device closer: use a longer delay (146 us at about 31 cm).
  Further away: use a shorter one (104 us at 45 cm).

Note the values that work for you. Feedback from the device decides the
defaults.

### Device pickers

All `x20-*` sinks are plain `media.class = Audio/Sink`, so they appear in
output pickers (KDE, Steam Game Mode, pavucontrol), and the picker is the
control: "X20 Speakers" for stereo on the speakers, "X20 Speakers (virtual
surround)" for surround on the speakers, "X20 headphone surround 5.1/7.1"
for surround on headphones (silent while no headphones are available), the
hardware outputs for no processing. "Default" follows "Automatic output
selection" above.

Measured on the X20 (SteamOS 3.9.5, WirePlumber 0.5.18): `Audio/Sink/Internal`
is not a usable hiding trick. WirePlumber then logs "No input node for
filter-chain-… found" and "8 of 8 PipeWire links failed to activate", no
client stream gets linked, and the device goes silent. A real hiding
mechanism (per-client permissions, or a pulse-side filter) is future work.

## LFE

Every chain treats the LFE channel the same way. It goes through two
cascaded 2nd-order low-passes (24 dB/octave, -6 dB at `lfe_cutoff_hz`,
default 120 Hz). It is then folded into both outputs at `lfe_gain_db`
(default -6 dB), without HRTF and without crosstalk cancellation.
`audio-dsp lfe set <cutoff_hz> <gain_db>` changes both settings for every
chain.

- **Why low-pass**: LFE is band-limited to 120 Hz by spec (Dolby, ITU-R
  BS.775), and a real subwoofer or bass management filters it at about
  80-120 Hz. Before this change the chains summed it full band. That is why
  KDE's LFE test clip sounded clear instead of muffled, and why anything a
  game leaves above 120 Hz in LFE ended up in the mix.
- **Speakers**: the X20 has no subwoofer, and its two micro drivers cannot
  reproduce anything below about 80 Hz. The speaker chains then high-pass
  everything at 150 Hz. On speakers LFE is therefore mostly protection: a
  60 Hz rumble at full scale used to take digital headroom (and amplifier
  excursion) without producing audible bass. Now it is filtered out before
  the sum.
- **Headphones**: headphones do reproduce low bass, so the headphone surround sinks also
  low-pass LFE at the same cutoff and keep it at -6 dB. A low-pass at
  120 Hz removes only out-of-spec content, so real LFE is unaffected.

## Headroom

PipeWire's builtin nodes have no limiter. Samples above full scale travel
through the graph as floats and are clipped only where they are converted
to the device format, at the hardware sink. Clipping makes harsh
broadband noise bursts, which matches what Resident Evil 2 produced on loud
scenes through `x20-speakers-surround`. The gain structure is the only
protection, so each speaker chain ends in a master gain stage.

`audio-dsp master-gain` prints the analysis. The component computes it at
render time (`audio_dsp_gain_numbers`):

- Model: a full-scale sinusoid on every input, swept from 20 Hz to 20 kHz.
  At each frequency the magnitudes of all input-to-output paths are added,
  and the maximum over frequency is reported.
- The paths include the downmix and width gains, the EQ, the LFE low-pass
  and the XTC taps on their band-limited copy. The biquads use PipeWire's
  RBJ formulas at 48 kHz.
- HRTF sources count at their 0.5 gain with HRIRs taken as at most 0 dB.
  libmysofa normalises the sets, and the measurement script below checks
  this assumption.

Worst case over full scale, before the master gain (defaults: 117 us, 4 dB,
4 taps, LFE 120 Hz at -6 dB):

| Path | Before this change (no LFE low-pass, no master) | Now, before master | Master (default) | Now, after master |
|---|---|---|---|---|
| `x20-speakers`, stereo (FL/FR only) | +1.9 dB | +1.9 dB | 0 dB (auto) | +1.9 dB |
| `x20-speakers`, all 8 channels coherent (a surround stream on it) | +13.1 dB | +11.8 dB | 0 dB (auto) | +11.8 dB |
| `x20-speakers-surround` -> `x20-speakers`, 7 sources uncorrelated | +10.9 dB | +9.6 dB | -9.6 dB (auto) | 0.0 dB |
| same, 7 sources coherent | +18.6 dB | +18.0 dB | -9.6 dB (auto) | +8.4 dB |

What the settings mean:

- `master_gain_db` (x20-speakers-surround):
  - `auto` (default) is safe for full-scale uncorrelated sources, a loud
    game scene. This is a deliberate soft margin: the strict worst case
    (seven identical full-scale sources) could still exceed full scale by
    up to 8.4 dB.
  - `strict` is safe even then (-18.0 dB, or -6.2 dB on top of a strict
    speakers master).
  - A number in dB is used as is.
  - The value always applies after the `x20-speakers` master, so the whole
    path is covered.
- `speakers_master_gain_db` (x20-speakers):
  - `auto` (default) is unity, so stereo keeps its level. The +1.9 dB
    theoretical worst case comes from the +2 dB air shelf at 8-20 kHz,
    where real content is never at full scale.
  - `strict` (-11.8 dB) also covers coherent full-scale 7.1 played on
    `x20-speakers`. It costs stereo the same 11.8 dB.

The master gains lower the digital level only. If the speaker volume is a
hardware control (the TAS2783 amp volume), raising it restores loudness
without bringing back digital clipping. If the volume slider is already at
100 %, the maximum loudness drops by the same amount.

If noise bursts remain with `master-gain strict`, the cause is not digital
clipping. Suspect the amplifiers' own protection or the drivers'
excursion, and use `lfe set 120 -20` or a higher speaker high-pass.

### Measuring

[`vm/guest/measure-speaker-chain.sh`](../vm/guest/measure-speaker-chain.sh)
runs as the desktop user (not root) on the X20. It generates a worst-case
7.1 file and plays it on the default sink (or `--sink NODE`). While it
plays, it records the measurement point in float32 and prints the peak
dBFS and the share of clipped samples per channel. The file has three
segments: the same sweep on all 7 channels plus 60 Hz LFE, independent
noise on every channel plus LFE, and LFE alone, all at -1 dBFS.

```sh
vm/guest/measure-speaker-chain.sh --point hw         # hardware sink monitor (what the DAC gets)
vm/guest/measure-speaker-chain.sh --point surround   # x20-speakers-surround.output
vm/guest/measure-speaker-chain.sh --point speakers   # x20-speakers.output
vm/guest/measure-speaker-chain.sh --point hw --method parec   # via the pulse monitor source
vm/guest/measure-speaker-chain.sh analyze rec.wav    # any WAV (PCM or float)
```

Recording a sink's monitor with PipeWire 1.6 needs `pw-record --target
<node.name> -P '{ stream.capture.sink = true }'`. The target must be the
node *name* (or `object.serial`), not the object id that `wpctl status`
shows. An id is not a valid target, so the recorder silently falls back to
the default source and records silence. The script prints the links it
made, and treats an all-zero recording as an error (exit 3). The hardware
monitor is taken in float before the conversion to the device format, so
values at or above 1.0 are exactly the samples that clip.

## Requirements: sofa plugin and libmysofa

`audio_dsp_probe_sofa_support` checks, under the root being configured:

1. the sofa plugin: `/usr/lib/spa-0.2/filter-graph/libspa-filter-graph-plugin-sofa.so`
   (PipeWire 1.3 and later) or `/usr/lib/pipewire-0.3/libpipewire-module-filter-chain-sofa.so`
   (1.2 and earlier). As a last resort it looks for `mysofa` imports in
   `libpipewire-module-filter-chain.so`. A plain `strings | grep sofa` is not
   enough, because every filter-chain build mentions "sofa" in its help text;
2. `libmysofa.so*` in `/usr/lib`, `/usr/lib64` or `/var/lib/ally-x20-steamos/lib`.

SteamOS 3.9 (`jupiter-3.9` repository) ships PipeWire 1.6.8. Its
`pipewire-audio` package contains the filter-graph sofa plugin and depends on
`libmysofa`, so both checks are expected to pass. TODO(hw): confirm with
`ls /usr/lib/libmysofa.so* /usr/lib/spa-0.2/filter-graph/` on the X20.

Fallbacks:

- **Plugin present, library missing**: build libmysofa v1.3.4 (BSD-3-Clause)
  with [`build/build-libmysofa.sh`](../build/build-libmysofa.sh) and stage
  it in `/var/lib/ally-x20-steamos/lib`. The hdr component's
  `/etc/ld.so.conf.d/00-ally-x20-steamos.conf` puts that directory on the
  loader path. Nothing touches `/usr`.
- **No plugin**: the virtual surround modules fail to load (`nofail`) and
  the sinks are absent; the automatic default is then `x20-speakers` on the
  speakers and the bare headphone sink on headphones.
  The speaker chain does not need libmysofa. A future fallback could
  pre-render HRIR WAV files from the SOFA data and use the builtin
  `convolver`, the way PipeWire's `sink-virtual-surround-7.1-hesuvi.conf`
  example does.

## Verifying on a running system

```sh
ally-x20-steamos audio-dsp status        # settings, probes, live x20 sinks
ally-x20-steamos audio-dsp test          # 7.1 + stereo tones, prints stream -> sink,
                                         # then 7.1 through x20-speakers-surround
wpctl status                             # sinks: X20 Speakers, X20 Speakers (virtual surround),
                                         # X20 headphone surround 5.1/7.1; "*" marks the default
wpctl inspect @DEFAULT_AUDIO_SINK@ | grep -e node.name -e priority
pw-top                                   # which nodes run, rate, xruns, DSP load
pw-dump | jq -r '.[] | select(.type == "PipeWire:Interface:Link")
  | "\(.info["output-node-id"]) -> \(.info["input-node-id"])"'
pw-link -l                               # same, by port name
journalctl --user -u wireplumber | grep 'x20:'   # headphone-output hook decisions (info level)
```

Expected links: `x20-speakers.output` -> `...HiFi__Speaker__sink`,
`x20-speakers-surround.output` -> `x20-speakers`, and a headphone surround
output -> the jack (route available) or a headset, or no link at all.

Hook decisions are logged at info level on the `s-linking.x20` topic. To
see them, run WirePlumber with `WIREPLUMBER_DEBUG=s-linking.x20:I`, or raise
the level at runtime with `wpctl set-log-level`.

Simulating a jack plug in the VM (plan section 6): change the active route
with `wpctl set-route` or pavucontrol's port selector. WirePlumber rescans:
the automatic default moves to `x20-virtual-surround-71` (output linked to
the jack) and back to `x20-speakers`. TODO(vm).

## Turning it off and removing it

- `sudo ally-x20-steamos audio-dsp off` removes every configuration file
  (filter chains, no-upmix fragments, hook scripts and loader) and restarts
  the user's PipeWire, so audio behaves exactly as stock. No virtual sinks
  remain in the output picker. HRTF data and the settings file stay, so
  `audio-dsp on` works offline. A file you edited after we installed it is
  left in place and reported.
- `ally-x20-steamos uninstall` removes everything recorded in the manifest,
  including the HRTF sets and the settings file. Restart PipeWire afterwards
  (`systemctl --user restart pipewire pipewire-pulse wireplumber`) or log
  out and back in.

`status` reports `active` when the component is enabled, every file
verifies and the selected HRTF is in place. It reports `stock` when the
component is disabled, incomplete or drifted. The probe never reports
`superseded`: Valve ships no X20 speaker processing or headphone surround.

## WirePlumber 0.4 notes (not supported)

SteamOS 3.9 ships WirePlumber 0.5.18, which is the only version this
component targets. On 0.4 the hook would need a different form: a
`~/.config/wireplumber/main.lua.d/` (or `policy.lua.d/`) loader calling
`load_script("x20-route-by-channels.lua")`, scripts in
`~/.config/wireplumber/scripts/`, and the target choice done by patching
`policy-node.lua`'s `findDefinedTarget`/`findBestTarget` logic, or by
setting `target.object` metadata from an `ObjectManager` `object-added`
callback. 0.4 has no event hooks and no settings schema. The pure decision
core would carry over unchanged.

## Open items needing the device or the VM

- Measured on the X20 (SteamOS 3.9.5): UCM routes `[Out] Headphones` and
  `[Out] Speaker`; the unplugged jack reports `not available`; priorities
  1000 (jack) and 712 (speakers).
- TODO(hw) automatic default: `x20-speakers` without headphones,
  `x20-virtual-surround-71` -> jack while plugged, back on unplug; the same
  with a USB and a Bluetooth headset; a manual pick in Steam is kept.
- TODO(hw) presence of the sofa plugin, libmysofa and any LV2/LADSPA plugins.
- TODO(hw) WirePlumber runs the `main` profile on SteamOS.
- TODO(hw) speaker EQ/width preset against the Windows reference recording.
- TODO(hw) HRTF gain (`gain = 0.5` per source) for comfortable loudness without clipping.
- TODO(hw) speaker virtual surround by ear: XTC defaults, speaker separation
  measured with a ruler.
- TODO(hw) `measure-speaker-chain.sh --point hw` with the default and the
  strict master gain; RE2 loud scenes A/B.
- TODO(vm) bit-identical stereo check and route-change rescans of the
  headphone surround outputs.
- TODO(vm) the ALSA plugin (`pipewire-alsa`) picks up `client.conf.d`.
