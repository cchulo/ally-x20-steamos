# Virtual-surround blind-test rig

A throwaway rig that answers one question by listening: does any
virtual-surround filter beat the raw hardware sinks of the ROG Xbox Ally
X20, first on headphones, then on the built-in speakers?

It is not a component. Nothing here is installed by `ally-x20-steamos`, and
nothing in `components/`, `lib/`, `cmd/`, `overlay/` or the installer knows
about it. The previous attempt and why it was removed:
[docs/audio-dsp-history.md](../../docs/audio-dsp-history.md).

## Pass rule

Fixed before any listening, and applied by `surround-test results`:

> A candidate must beat raw on localisation and not lose on tone, in two
> sessions on different days.

- **Beat raw on localisation**: a higher hit rate than raw in the
  localisation tests of that day.
- **Not lose on tone**: in the tone tests of that day, the candidate is
  preferred at least as often as raw.
- **Two sessions on different days**: both conditions hold on two different
  dates, for the same output (headphones and speakers are judged
  separately). A second session on the same day does not count.

If no candidate passes, raw stays, and nothing is built.

## What is tested

| Candidate | What it is |
|---|---|
| `raw` | the hardware sink as it is; an 8-channel stream is downmixed to stereo by PipeWire. Always included |
| `<set>-full` | 7.1 through the HRTF of one SOFA set |
| `<set>-dry` | FL, FR and FC dry; sides and rears through the HRTF |
| `user` | a 14-channel 48 kHz HRIR file you supply by path (HeSuVi format). Never fetched, never committed |
| `<winner>-speakers`, `<winner>-xtc-dNNN-sNN` | speakers only: the headphone winner as it is, and with side/rear crosstalk cancellation at delay NNN µs and strength 0.NN |

The SOFA sets are in [hrtf.lock](hrtf.lock), pinned by SHA-256, with the
licence read from each file:

| Set | Subject | Licence |
|---|---|---|
| `mit-kemar` | KEMAR mannequin, normal pinna | no usage restrictions, cite Gardner and Martin (1995) |
| `mit-kemar-large` | KEMAR mannequin, large pinna | same |
| `hutubs-pp1` | HUTUBS subject pp1 | CC BY 4.0 |
| `cipic-003` | CIPIC subject 003 | any use, keep the copyright notice |
| `sadie-d1` | SADIE II, Neumann KU100 dummy head | Apache 2.0 |
| `sadie-d2` | SADIE II, KEMAR mannequin | Apache 2.0 |

No `.sofa` or `.wav` file is ever committed; `out/`, `*.sofa` and `*.wav`
are ignored here.

### The local-only candidate (for example Dolby Atmos for Headphones)

The HeSuVi HRIR collection has captures of commercial virtualizers. They
cannot be hosted in this repository. To try one:

1. Open the [HRTF Database](https://airtable.com/appayGNkn3nSuXkaz/shruimhjdSakUPg2m/tbloLjoZKWJDnLtTc)
   table, find the row (for example `atmos` under "Popular") and use the
   **Download WAV** button in the **HeSuVi** column.
2. The download folder holds `atmos.wav` (48 kHz) and a `44/` folder (the
   same at 44.1 kHz). Take the 48 kHz file; the rig refuses the other one.
3. Give its path to `build.sh --user-wav FILE` on the development machine,
   or to `surround-test add-user FILE` on the device.

Test the SOFA candidates first, then this one. If it wins, the result is an
instruction for where to get the file, not a file.

## How it works

- **Mechanism**: PipeWire's filter-chain with the builtin `convolver`
  reading one 14-channel WAV, the layout of PipeWire 1.6.8's
  `sink-virtual-surround-7.1-hesuvi.conf`. The channel order was checked
  against that file (`x20surround/layout.py`, `tests/test_layout.py`) and
  measured end to end (below).
- **Dry fronts** are encoded in the WAV as delayed impulses, and the
  speaker crosstalk stage is folded into the WAV as well, so every candidate
  uses the same graph.
- **Each candidate is its own `pipewire -c <conf>` process** next to your
  PipeWire. Nothing is written to `~/.config/pipewire` or WirePlumber, and
  a candidate is gone when its process stops.
- **Pinned output**: `target.object` = the hardware sink, with
  `node.dont-fallback` and `node.linger`, so a candidate never plays into
  another sink.
- **Levels**: every candidate carries a gain that matches it to raw. The
  first estimate is computed from the filters (K-weighted pink noise in the
  seven full-range channels); `surround-test calibrate` then measures raw and
  each candidate on the hardware sink's monitor and corrects the rest. The
  tolerance is 0.5 dB.
- **Volume**: one session volume, starting at 0.35 and capped at 0.80. With
  raw it is the hardware sink's volume. With a candidate it is the
  candidate's volume and the hardware sink is held at 100 % underneath
  (the stacking lesson of the history page). The hardware sink is never at
  100 % while it is the default sink itself. The previous volume, mute state
  and default sink are restored on exit, on Ctrl-C, on a dropped SSH
  connection, and by `surround-test restore`.
- **Ceiling**: each candidate ends in a hard ceiling at -1 dBFS (the builtin
  `clamp`). PipeWire has no builtin limiter, so this is a clipper, not a
  limiter; together with the volume cap and test signals at -23 dBFS it is
  the safety net.

## Phase 1: render and check (development machine)

Needs `python3` with numpy, scipy and h5py. To avoid installing anything on
the host, use the image in [Containerfile](Containerfile) (podman or docker):

```sh
podman build -t x20-surround-dev -f tools/surround-test/Containerfile .
podman run --rm -v "$PWD":/r x20-surround-dev \
    /r/tools/surround-test/build.sh --user-wav /r/path/to/atmos.wav
```

`build.sh` downloads the SOFA sets (hash-checked), renders both forms of
each, adds the user file when given, runs the offline checks and writes
`out/manifest.json` and `out/report.txt`.

The offline checks need no audio hardware (`hrir_tool.py check FILE` runs
them on any file):

| Check | What it catches |
|---|---|
| routing | every loudspeaker must be louder and not later in the ear on its own side, the centre equal in both: a wrong channel order fails |
| headroom | peak level after the level trim for a full-scale sine in one channel, with the absolute bounds for one and for all eight channels, next to raw |
| symmetry | left/right mirror pairs must have the same spectrum |
| centre | the centre channel's response against raw (flat) between 200 Hz and 8 kHz; a spread above 6 dB is "moderate", above 10 dB "HEAVY colouration" |

Results on 2026-11-18 (trim = gain that matches the candidate to raw):

| Candidate | Trim | Routing | Symmetry | Centre spread, 200 Hz to 8 kHz |
|---|---|---|---|---|
| `mit-kemar-full` | -5.16 dB | pass | 0.0 dB | 22.0 dB, heavy |
| `mit-kemar-large-full` | -6.84 dB | pass | 0.0 dB | 20.9 dB, heavy |
| `hutubs-pp1-full` | -1.68 dB | pass | 0.7 dB | 21.2 dB, heavy |
| `cipic-003-full` | +0.44 dB | pass | 1.4 dB | 20.2 dB, heavy |
| `sadie-d1-full` | -0.98 dB | pass | 1.3 dB | 11.2 dB, heavy |
| `sadie-d2-full` | -0.97 dB | pass | 1.3 dB | 7.2 dB, moderate |
| every `-dry` form | -6.91 to +0.24 dB | pass | as above | 0.0 dB (the centre is dry) |
| `user` (Atmos HeSuVi file) | -2.30 dB | pass | 0.5 dB | 2.5 dB, close to raw |

Every candidate gets a headroom warning: a full-scale sine in one channel
comes out between +4 and +9 dBFS at the filter's strongest frequency, so the
ceiling clips such a signal. Raw has no such gain. CIPIC has no measurement
beyond 80 degrees to the side, so its side channels are rendered 10 degrees
too far forward.

### Validation of the renderer and of the graph

`pw-harness.sh` starts a private PipeWire and WirePlumber with null sinks
(no sound, no hardware) and measures impulse responses:

| Command | Compares | Result (PipeWire 1.6.11, WirePlumber 0.5.19) |
|---|---|---|
| `pw-harness.sh sofa SET.sofa RENDERED.wav` | PipeWire's own `sofa` spatializer for the same set and angles, against `render_sofa.py` | `mit-kemar`: largest third-octave difference 0.01 dB; residual -51 dB after one common gain (PipeWire's output is 2.61 dB higher, which the level trim absorbs) |
| `pw-harness.sh candidate HRIR.wav` | a generated conf, against the file: routing, gains, LFE path | residual -136 dB |
| `pw-harness.sh raw` | the 7.1 to stereo downmix of a stereo sink, against `layout.RAW_DOWNMIX` | exact: FL/FR 1.0, FC and the surrounds 0.707, LFE 0.354 |
| `pw-harness.sh pin HRIR.wav` | pinning: target absent and a better-ranked decoy sink present | nothing reaches the decoy; the output links when the target appears |
| `pw-harness.sh ceiling` | the clamp stage | a 1.8 peak comes out at 0.891 |

The small residual against the spatializer is the resampler (the set is
44.1 kHz; libmysofa and scipy resample differently).

## Phase 2: headphones (on the device)

Copy the rig and the rendered candidates and install them, as the `deck`
user, without sudo:

```sh
tools/surround-test/deploy.sh deck@<device>
```

That runs `install.sh` on the device. It creates
`~/.local/share/x20-surround-test/`, `~/.local/state/x20-surround-test/` and
the symlink `~/.local/bin/surround-test`, nothing else.

The tests ask questions on a terminal, so run them over SSH from another
machine, or in Desktop mode with a keyboard. Plug the headphones into the
jack first. For a USB or Bluetooth headset add `--target <node.name>`.

```sh
surround-test doctor --measure   # tools, sinks, candidates; silent check of the raw downmix
surround-test calibrate          # silent: measures every candidate against raw
surround-test localise           # blind localisation test
surround-test tone --file ~/Music/track.flac    # blind A/B against raw
surround-test tone --live        # the same on a running game
surround-test results            # the log, with the pass rule applied
```

- **`doctor --measure` and `calibrate` are silent**: the hardware sink is
  muted and only its monitor is recorded. If you hear anything, stop and
  report it.
- **`localise`**: single-channel call-outs (three short noise bursts) in
  random order over raw and the candidates. You answer with a number:

  ```
  1 front-left    2 centre    3 front-right
  4 side-left                 5 side-right
  6 rear-left                 7 rear-right
  ```

  `r` replays, `+` and `-` change the volume, `q` stops early (an early stop
  is logged but not counted). It scores the hit rate and the front/back and
  left/right confusions per condition. It refuses to continue if its own
  test stream is not 8 channels.
- **`tone`**: per candidate, a few rounds where "1" and "2" are raw and the
  candidate in random order. `1`/`2` switch, `p1`/`p2` state a preference,
  `p0` is no preference. It prints how many channels each playing stream
  has.
- **Blind**: conditions get random letters and nothing on screen names
  them until the test ends. `--open` shows the names.
- **Results** are appended to
  `~/.local/state/x20-surround-test/results.jsonl`, one JSON record per test
  with the date, a session id, the output, the volume and every answer.

Twelve SOFA candidates and raw are 13 conditions, 182 call-outs at the
default two per direction. A workable order:

1. Screen the SOFA candidates once with `surround-test localise --repeats 1`
   (91 call-outs).
2. Keep the three or four best and run full sessions with
   `--candidates id,id,...`, localisation and tone, on two days.
3. Then the same for `user`.

### Game check

Resident Evil 2 and Resident Evil 9, the same save point each time.

1. Run `surround-test tone --live --candidates <id>`. While it waits for
   you, a candidate (7.1) is the default output.
2. **First launch with the headphones off your ears**: some games play a
   full-volume tone on a 7.1 output.
3. Start the game with its audio output on "Default" and load the save
   point, then press Enter in the terminal. The rig prints the stream's
   channel count: it must say 8. A game opens its stream once; if it says 2,
   quit the game and start it again while the rig is waiting.
4. Switch with `1` and `2` and judge.

In this mode "raw" is the game's 8-channel stream downmixed by PipeWire, not
the game's own stereo mix. Comparing against the game's stereo mix needs a
second launch with the rig stopped.

## Phase 3: speakers

Unplug the headphones. Make the speaker candidates from the headphone
winner, then test as before with `--device speakers`:

```sh
surround-test speakers-from <winner-id>
surround-test calibrate --device speakers
surround-test localise --device speakers --candidates <winner-id>-speakers,<winner-id>-xtc-d090-s50,...
surround-test tone --device speakers --live --candidates ...
```

`speakers-from` writes the winner as it is (`<winner-id>-speakers`) and a
sweep of crosstalk cancellation: delays 60, 80, 100 and 120 µs, strengths
0.3, 0.5 and 0.7 (12 variants). The canceller acts on the side and rear
channels only, between 250 Hz and 5 kHz, as a three-term truncated
recursion (`x20surround/xtc.py`). It is simulated: nothing was measured on
the device, and the delay and strength that fit the X20's speaker spacing
are unknown, which is what the sweep is for.

## Removing it

```sh
~/.local/share/x20-surround-test/uninstall.sh [--keep-results]
```

It restores the volumes and the default sink if a session was left open,
then removes the two folders, the symlink and the runtime files.
`--keep-results` moves the log to `~/x20-surround-test-results.jsonl` first.

## Not verified on hardware

The X20 was powered off while this was written. Everything above was run
against PipeWire 1.6.11 and WirePlumber 0.5.19 with null sinks named like
the X20's; the device has PipeWire 1.6.8. Open points, marked `TODO(hw)` in
the code:

- The raw downmix matrix on the device (`surround-test doctor --measure`
  checks it).
- Whether the monitor of a muted ALSA sink still carries the signal, which
  the silent calibration relies on. `calibrate` says so if it does not.
- Pinning to the real sinks, the wake-up time of a suspended sink (the
  call-outs start with 0.3 s of silence), and CPU load of thirteen idle
  candidates.
- How Steam and a game react to the default sink changing during
  `tone --live`.
- The crosstalk parameters.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `hrtf.lock`, `fetch-sofa.sh` | dev | SOFA sets, pinned; format and script reused from commit 899ba9b |
| `render_sofa.py` | dev | SOFA to 14-channel 48 kHz WAV (numpy, scipy, h5py) |
| `build.sh` | dev | fetch, render, check, write the manifest |
| `pw_harness.py`, `pw-harness.sh` | dev (Linux) | headless PipeWire measurements |
| `deploy.sh` | dev | copy to the device and install |
| `hrir_tool.py` | both | dry form, checks, manifest, speaker candidates, conf (standard library) |
| `x20surround/` | both | the shared package (standard library) |
| `surround-test.sh`, `install.sh`, `uninstall.sh` | device | switcher wrapper, install, removal |
| `tests/` | dev | pytest suite; `tests/headless.sh` starts the private PipeWire |

## Tests

```sh
make test          # bats (tests/tools/surround-test-*.bats) and pytest (tools/surround-test/tests)
```

Tests that need numpy, scipy and h5py, or PipeWire and WirePlumber, skip
where those are missing (macOS, the device). The container image has all of
them, including the run of the whole flow against a real PipeWire:

```sh
podman run --rm --user deck -v "$PWD":/r:ro x20-surround-dev \
    bash -c 'cd /r && python3 -m pytest -q -p no:cacheprovider tools/surround-test/tests && bats tests/tools'
```
