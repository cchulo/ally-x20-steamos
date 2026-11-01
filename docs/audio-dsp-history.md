# Audio DSP (removed 2026-11-01)

From 2026-10 until 2026-11-01 the `audio_dsp` component (plan §1.5) added
processed PipeWire sinks to the `deck` user's session. It is gone: the
owner prefers the raw hardware. This page records what was built, how it
was judged, why it went, and the two lessons worth keeping. The code, its
tests and the full design notes (`docs/audio-dsp.md`, `docs/xtc-notes.md`)
are in commit
[`899ba9b`](https://github.com/cchulo/ally-x20-steamos/tree/899ba9b5b2e828dd5270a280882f1960461897e1),
the last one that had them; `git checkout 899ba9b -- components/audio_dsp.sh
cmd/audio-dsp.sh overlay/home tests/lua tests/fixtures/audio_dsp` brings
them back.

## What was built

| Piece | What it did |
|---|---|
| `x20-speakers` (filter-chain sink) | built-in speakers: 7.1 downmix to stereo, stereo width, EQ (150 Hz high-pass, shelves, a 3.5 kHz dip), LFE low-pass, master gain; output pinned to the hardware Speaker sink |
| `x20-headphones` (filter-chain sink) | headphones (jack, USB, Bluetooth): 7.1 through PipeWire's `sofa` spatializer with a generic HRTF (MIT KEMAR by default, three SOFA sets downloaded and hash-checked); from 2026-10-31 a hybrid with the fronts and centre dry and only rears and sides spatialized |
| `x20-speakers-surround` | HRTF plus crosstalk cancellation (4-tap RACE) into `x20-speakers`; removed 2026-10-31, "muffled, like sand in my ears" |
| WirePlumber 0.5 hooks (Lua) | automatic default (speakers -> `x20-speakers`, headphones -> `x20-headphones`), headphone output routing, the hardware-volume rule below |
| no-upmix fragments | stereo stays stereo on the 7.1 sinks |
| `ally-x20-steamos audio-dsp ...` | on/off, HRTF set, the settings, LFE, master gain, test tones |

## How it was judged

All on the X20, by the owner, with Resident Evil 2 and 9.

| Date | Comparison | Verdict |
|---|---|---|
| 2026-10-31 | `x20-speakers-surround` vs `x20-speakers` | `x20-speakers`; the surround sink was removed |
| 2026-10-31 | `x20-speakers` vs raw speakers, hardware Speaker sink at 100 % (an earlier run had it at 55 %, 15.6 dB down) | `x20-speakers` "much better" |
| 2026-10-31 | `x20-headphones`, full HRTF | ambience "amazing", frontal sounds "sandy" (generic HRTF colouration); led to the hybrid |
| 2026-11-01 | level-matched A/B at 80 %: raw speakers vs `x20-speakers` | raw speakers |
| 2026-11-01 | level-matched A/B at 80 %: raw jack vs hybrid `x20-headphones` | raw jack |

The "much better" verdict did not hold. It came before the patched tas2783
codec driver with Valve's fixes was running, and the retest was level
matched.

## Why it was removed

Raw won both level-matched comparisons. Raw is also what everyone else
ships on this hardware: stock SteamOS, Anatase (UCM only) and Bazzite (raw
on the Ally X and the Xbox Ally; its convolver DSP exists only for the
original RC71L). The owner first made raw the default and kept the sinks as
manual picks, then dropped them: "get rid of the sinks for dsp and hybrid
headphones, pointless, I won't use them anymore".

Upgrading removes everything the component installed (see "Upgrade" below).

## Lessons worth keeping

### PipeWire volumes stack under Steam's single slider

Every PipeWire sink has its own volume, and Steam's slider (like
`wpctl set-volume @DEFAULT_AUDIO_SINK@`) moves only the default sink's. A
filter-chain sink plays into another sink, so the two volumes multiply.
Measured on the X20: `x20-speakers` at 100 % over a hardware Speaker sink at
55 % is 0.55^3 = 0.166 linear (slider percentages are cubic), about
-15.6 dB. Any A/B between a virtual sink and the raw sink is meaningless
until the sink underneath is at 100 % or the levels are matched by ear or
meter. The component solved it with a hook that held every sink under our
default at 100 % (through WirePlumber's `mixer-api`, saving and restoring
the previous volume in `~/.local/state/wireplumber/x20-hardware-volume`), so
the default sink's slider was the only volume.

### WirePlumber 0.5 default-sink and hook mechanics

- With Steam's output on "Default", WirePlumber picks the available sink
  with the highest `priority.session` (on the X20: Speaker sink 712, jack
  1000 while a plug is in, USB and Bluetooth 1000 or more). A sink the user
  picked is ranked above 15000 (30000 + priority; 19xxx-20000 for the
  history in `~/.local/state/wireplumber/default-nodes`), and choosing
  "Default" in Steam clears it.
- A Lua `SimpleEventHook` on `select-default-node`, ordered after
  `default-nodes/find-best-default-node` and before
  `default-nodes/apply-default-node`, can replace the choice;
  `default-nodes/rescan-trigger` re-runs it when sinks come and go and on
  device `Route` changes (jack detection), so plug and unplug switch.
- A hook on `select-target` picks where a filter-chain output links. Without
  a pinned `target.object` and `node.dont-fallback`, a filter output falls
  back to "the best other sink", which on the X20 is the unplugged jack (it
  stays in the graph, only its route is `available = no`): that was the
  silent `x20-speakers` bug.
- Custom settings need a `wireplumber.settings.schema` entry, are persisted
  in a `wireplumber.settings` fragment and changed live with
  `wpctl settings`; scripts live in `$XDG_DATA_HOME/wireplumber/scripts`
  and load through a `wireplumber.components` entry plus a profile
  requirement.
- Keep the policy in pure Lua functions fed with plain tables; the glue
  stays thin and the decisions can be tested without WirePlumber.

## Upgrade

`sudo ally-x20-steamos apply` (and the boot service on the next boot)
removes every file the manifest still records under `audio_dsp`, with the
uninstaller's rules: only recorded paths with an x20 marker, content checked
against the recorded digest (a hand-edited file is kept and reported;
`uninstall --component audio_dsp --force` removes it), empty directories we
created. It also removes `~/.local/state/wireplumber/x20-hardware-volume`
and the empty `~/.config/ally-x20-steamos/` (settings and HRTF data), then
restarts the user's PipeWire, PipeWire-Pulse and WirePlumber. If the volume
hook was holding a sink at 100 % when it was removed, that sink stays
there: the log says so, and the slider sets it again. The mechanism is
generic (`lib/retired.sh`) for any component removed later.
