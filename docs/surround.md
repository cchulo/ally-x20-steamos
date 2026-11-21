# Virtual 7.1 surround for the built-in outputs (component `surround`)

Stock SteamOS offers the X20's headphone jack and speakers as stereo
outputs, so a game sends a stereo mix. This component puts an 8-channel
output in front of the built-in output in use. A game then sends 7.1, and a
filter turns it into two channels that carry direction cues.

- **Headphones:** on by default, with the profile `sadie-d2-dry`.
- **Speakers:** on by default, with the profile `sadie-d2-dry` and crosstalk
  cancellation (delay 60 µs, strength 50 %).
- Each output has its own profile. The two defaults use the same head; they
  are still two settings, and changing one leaves the other alone.
- **Other outputs** (Bluetooth, USB, HDMI) are not touched.

Status: the generated PipeWire setup, the default-output behaviour and the
hand-over between two filters are checked on a private PipeWire 1.6.11 and
WirePlumber 0.5.19 without hardware (`tests/surround/headless.py`). The
speaker settings were chosen by ear on the X20 with the test rig of pull
request #70, not with this component. The component itself has not run on
the X20 yet; the open points are in
[Needs the device](#needs-the-device-todohw).

## Profiles

| Profile | What it is |
|---|---|
| `stereo` | no filter: the output as stock SteamOS has it |
| `sadie-d2-dry`, `sadie-d2-full` | KEMAR mannequin, SADIE II database (`-dry` is the default for the headphones and for the speakers) |
| `hutubs-pp1-dry`, `hutubs-pp1-full` | FABIAN head and torso simulator, HUTUBS database, subject pp1 |
| `mit-kemar-dry`, `mit-kemar-full` | KEMAR mannequin with normal ears, MIT |
| `mit-kemar-large-dry`, `mit-kemar-large-full` | the same mannequin with large ears |
| `user` | your own file (below) |

Each shipped profile is a set of head-related impulse responses: how sound
from seven directions reaches the two ears of one head. All four heads are
acoustic mannequins, not people. Ears differ, so try them; the one that
comes closest to your ears places sounds best.

Every head comes in two forms:

| Form | Front left, front right, centre | Sides and rears | In the listening tests (headphones) |
|---|---|---|---|
| `-dry` | unfiltered, as in plain stereo | filtered | preferred over stereo in games; sounds a little easier to place than in stereo |
| `-full` | filtered, like speakers in front of you | filtered | sounds far easier to place; stereo was preferred for its tone |

With `-dry`, stereo material, which uses only the front channels, sounds as
it does without the component. With `-full`, everything is coloured by the
filter.

> **Recommendation: use a `-dry` profile, on both outputs.** Both defaults
> are `-dry`.
>
> - **Speakers:** `-full` is not recommended. To the owner's ear it makes
>   the front channels sound quieter on the X20's speakers.
> - **Headphones:** `-full` may suit those who want sharper positioning.
>   The default is `-dry` all the same.
>
> This is what the owner heard on his X20. Nothing was measured for it.

Sources, licences and what was changed: `overlay/surround/NOTICE.md`
(installed next to the files).

## Choosing a profile

```sh
ally-x20-steamos surround status                       # per output: profile, what runs
ally-x20-steamos surround list                         # the profiles
ally-x20-steamos surround set headphones hutubs-pp1-dry
ally-x20-steamos surround set speakers stereo
```

- `set` always names the output: `set headphones <profile>` or
  `set speakers <profile>`. Without the output it is an error; nothing is
  guessed from the output in use, and no command sets both.
  (`set <profile> --device <output>`, the spelling of earlier versions of
  this pull request, is still accepted.)
- Run it as your user, without `sudo`.
- The change takes effect within a few seconds, while a game is running.
- The choices are kept in `~/.config/ally-x20-steamos/surround.conf`
  (`headphones=`, `speakers=`, `speakers_xtc=`), so they survive reboots and
  SteamOS updates.
- Plugging headphones in or out moves the filter to the other output, which
  plays its own profile.

A game picks its channel count when it starts. Going from `stereo` to a
surround profile therefore needs a restart of the game; switching between
surround profiles does not.

### Your own file

Copy a `.wav` file into `~/.config/ally-x20-steamos/surround-user/` and
select `user` for the output you want it on:

```sh
mkdir -p ~/.config/ally-x20-steamos/surround-user
cp my-hrir.wav ~/.config/ally-x20-steamos/surround-user/
ally-x20-steamos surround set headphones user
ally-x20-steamos surround set speakers user
ally-x20-steamos surround prepare          # speakers: generate and check the xtc settings (below)
```

- The file name does not matter. With several files the first in lexical
  order is used.
- This is how to use a Dolby Atmos for Headphones profile, or any other
  HeSuVi impulse response: such files are not shipped because they are not
  ours to redistribute. The owner's Atmos file came from the HRIR collection
  at <https://airtable.com/appayGNkn3nSuXkaz/shruimhjdSakUPg2m/tbloLjoZKWJDnLtTc>
  (the 14-channel 48 kHz `.wav` of the Atmos entry) and was used as it is.
  In the headphone listening tests it was preferred over stereo in both game
  comparisons it was part of. On the speakers, with crosstalk cancellation,
  it was the owner's personal favourite.
- It must be a 14-channel, 48 kHz impulse response set in the HeSuVi channel
  order (PCM 16/24/32-bit or 32-bit float), at most one second long.
- With no file, or a file that is not usable, the output's default profile
  is used instead (`sadie-d2-dry`), and `surround status` says why.
- Its loudness is matched to stereo by calculation
  (`x20dsp.level.trim_db`: pink noise in the seven full-range channels,
  K-weighted, limited to -24..+3 dB), not by measurement. The result is
  kept in `~/.cache/ally-x20-steamos/surround/user-trim.json` and worked
  out again when the file's path, modification time or size changes. The
  first time takes a second or two on the X20 for a file of about 5000
  samples, and longer for a longer one.
- On the speakers the crosstalk setting applies to it like to any profile.
  Run `surround prepare` after putting the file in place: it shows which
  settings are usable with your file.

## Crosstalk cancellation on the speakers (`xtc`)

Surround profiles are made for headphones: the left signal is meant for the
left ear only. From two speakers, each ear also hears the other speaker, a
little later and a little quieter. That leak is the crosstalk, and it blurs
the direction cues. Crosstalk cancellation adds to each speaker a delayed,
inverted, quieter copy of the other speaker's signal, so that the leak is
partly cancelled at the ear.

It has two numbers:

| Number | Meaning | Allowed | Tested by ear |
|---|---|---|---|
| delay | how much later the other speaker's sound reaches the ear | 20 to 300 µs | 60, 80, 100, 120 µs |
| strength | how loud that leak is taken to be, relative to the direct sound | 5 to 95 % | 30, 50, 70 % |

```sh
ally-x20-steamos surround xtc 60 50       # delay 60 µs, strength 50 % (the default)
ally-x20-steamos surround xtc off
ally-x20-steamos surround prepare         # table of the twelve tested settings
```

- It applies to the **speakers only**, whatever their profile is, except
  `stereo`. Headphones never get it: there is no crosstalk to cancel.
- It acts on the side and rear channels only, between about 250 Hz and
  5 kHz. The front channels and the centre are only delayed by the same
  0.33 ms as everything else.
- The right numbers depend on the speaker spacing and the listening
  distance. They were not derived from a measurement; the tested grid
  exists because the right values are not known. Try them.

### How the speaker file is made

The filter stays the same; what changes is the file it reads. Because the
canceller is linear, it can be folded into the 14-channel file. The helper
does that on the device, with the `x20dsp` package installed next to it
(python3, standard library only):

1. `x20dsp.xtc.apply` makes the variant of the speakers' profile file for
   the chosen delay and strength.
2. `x20dsp.checks` checks the variant: every side and rear channel must
   still be at least 1 dB louder in the ear on its own side (routing), and
   left and right must still mirror each other (symmetry).
3. `x20dsp.level.trim_db` works out the variant's level trim, so that it is
   as loud as plain stereo.
4. The variant and a small `.json` file with its trim and check result go
   to `~/.cache/ally-x20-steamos/surround/`, named after the SHA-256 of the
   source file's content plus delay and strength. It is made once. A
   changed source file has another checksum and gets its own variants.

**A variant that fails a check is never played.** The speakers then play
the profile without crosstalk cancellation, and `surround status`, the
`xtc` command and the journal say why. Of the shipped files with the twelve
tested settings (96 combinations, checked on a development machine), 12
fail the routing check: the four MIT files at strength 70 % with 60, 80 and
100 µs. Example: `mit-kemar-dry` with `xtc 60 70`.

The service makes a missing variant on first use, while the sound that is
playing keeps playing. `surround prepare` makes the twelve tested settings
for the speakers' current profile up front and prints them:

```
speakers: sadie-d2-dry (sadie-d2-dry.wav, trim -1.10 dB without xtc)
  xtc            trim       check
  60 us / 30 %    -1.30 dB  usable
* 60 us / 50 %    -1.60 dB  usable
  60 us / 70 %    -2.15 dB  usable
  ...
* the current setting. Files: /home/deck/.cache/ally-x20-steamos/surround
```

How long it takes, in plain Python:

| File | Where | Time |
|---|---|---|
| shipped sets (256 to 558 samples) | a desktop | well under a second per variant |
| a 5147-sample file (the owner's Atmos file) | the X20, with the test rig | about 2 s per variant; 26 s for 13 variants |

The cache can be deleted at any time; what is needed is made again.

## How it works

The user unit `ally-x20-steamos-surround.service` runs
`/etc/ally-x20-steamos/surround/x20-surround run` (python3, standard library
only). Every two seconds it reads PipeWire's state (`pw-dump`, about 10 ms
on the X20) and decides:

1. **Which built-in output is in use.** The headphones when the sound card's
   route `[Out] Headphones` is reported as available (the jack), otherwise
   the speakers.
2. **What that output plays**, from the settings file: its profile and, for
   the speakers, the crosstalk setting.
3. **What should run.** For `stereo`, nothing. Otherwise one
   `pipewire -c <generated config>` process.

The generated config is PipeWire 1.6.8's own 7.1 HeSuVi virtual-surround
graph (copy nodes, 16 convolvers reading the 14-channel file, two mixers)
with three additions that were measured with the test rig of pull request
#70:

- a level trim, so a profile is as loud as stereo. The shipped profiles use
  values from a table (within 0.5 dB on the X20's headphone output,
  2026-11-20). Speaker variants and the user's file use the calculated
  value. For speaker variants that calculation was compared with a
  measurement through PipeWire on the X20 (2026-11-20, with the rig): within
  0.14 dB for the `sadie-d2` variants, within 0.34 dB for the Atmos file's;
- a hard ceiling at -1 dBFS on each output channel;
- the output pinned to the one hardware sink (`target.object`,
  `node.dont-fallback`, `node.linger`), so the sound never ends up on
  another output.

**No default is forced.** The surround sink gets a session priority one or
two above its hardware sink (1001 or 1002 for the headphones, 713 or 714
for the speakers on the X20). WirePlumber therefore makes it the default
exactly when it would have picked that hardware output. An output chosen by
hand in Steam (Bluetooth, HDMI, or the plain built-in one) still wins, and
choosing the plain built-in output there is a way to bypass the filter.

### Switching

A change of profile, of the crosstalk setting, of the user's file or of the
output (the jack) does not stop the running filter first. Each output has
two sink names, `ally_x20_surround_<output>_a` and `..._b`:

1. The new filter starts under the name that is not in use. Name `_a` has
   the hardware sink's priority plus one, `_b` plus two, so the priority
   alternates and never grows.
2. The helper looks at PipeWire every 0.2 s until the new sink is there (at
   most 10 s), then waits another 0.5 s.
3. It stops the old filter. The streams move to the new sink.

At no point is the hardware sink the only one, so a game's 8-channel stream
is not moved to the stereo output and back. If the new sink does not appear
within 10 s, the helper falls back to stopping the old filter and starting
the new one, as it also does after a filter process dies.

What was checked, and what was not: in the container, across five changes
(profile in both directions, three crosstalk changes), `pw-metadata -m`
never reported the hardware sink as the default, an 8-channel test stream
was never seen linked to the hardware sink, and one filter process remained
each time. The test stream is silence and the link check is sampled, so
this does not show that a switch is inaudible. Moving a stream from one
sink to the next may still be heard as a click or a short dropout; that
needs the device. Both sinks have the same description, so for a second
Steam's output list may show the entry twice.

Nothing is written under `~/.config/pipewire` or `/usr`.

## Why these profiles

**Headphones.** Blind listening tests on the X20's headphone output with the
test rig (pull request #70, 2026-11-20, one listener):

| Form | Locating a single sound | Preferred over stereo in a game |
|---|---|---|
| every channel filtered ("full") | much better than stereo (up to 19 of 21 against 13 of 35) | 1 of 12 comparisons |
| fronts unfiltered ("dry") | a little better (54 to 62 %) | 10 of 12 comparisons |

The full forms located sounds best but changed the tone of everything, and
lost against stereo on music 0 to 3. The dry forms were preferred, so a dry
form is the default; the full forms ship as an option. `sadie-d2-dry` is the
owner's pick. The project's pass rule for the rig (better than stereo at
locating sounds and not worse in tone, on two different days) was not
completed; this is a choice by ear.

**Speakers.** Chosen by ear on the owner's X20 on 2026-11-20, with the test
rig, one listener, in a game that sends 8 channels (NieR:Automata). The
session was not blind, and no blind test was run on the speakers.

- Of the shipped sets, `sadie-d2-dry` with crosstalk cancellation at 60 µs
  and 50 % sounded best. That is the speaker default.
- The owner's own Atmos file with crosstalk cancellation was his personal
  favourite. It is not shipped; see [Your own file](#your-own-file).
- `-full` profiles made the front channels sound quieter on the speakers,
  so `-dry` is recommended there (an impression by ear, not a measurement).

**Per-output profiles.** Each output keeps its own profile and `set` always
names the output. That is the owner's decision. The two defaults use the
same head because it was the pick on each output, not because the setting
is shared.

## Checking and debugging

```sh
ally-x20-steamos surround status
systemctl --user status ally-x20-steamos-surround.service
journalctl --user -u ally-x20-steamos-surround.service -b
wpctl status            # the surround sink is listed and marked as default
cat "$XDG_RUNTIME_DIR"/ally-x20-steamos-surround/*.conf   # <output>-a.conf, <output>-b.conf
ls ~/.cache/ally-x20-steamos/surround/                    # generated speaker variants
```

The journal has one line per change, for example
`speakers: sadie-d2-dry + xtc 60 us / 50 % (abbfc8cb54b5294b-d060-s50.wav, trim -1.60 dB) on alsa_output… as ally_x20_surround_speakers_a`,
and a line when a variant is generated or not usable.

To check that a game sends 7.1, look at its stream while it plays:
`pw-dump | grep -A3 '"audio.channels"'` or `pw-top` (8 channels).

To switch everything off: `ally-x20-steamos surround set headphones stereo`
and `ally-x20-steamos surround set speakers stereo`, or
`systemctl --user stop ally-x20-steamos-surround.service`.

`tests/surround/headless.py` runs the helper against a private PipeWire and
WirePlumber with a null sink in place of the speakers (no sound, no
hardware; Linux only, not part of `make test`).

## Needs the device (`TODO(hw)`)

Nothing below has run on the X20 as part of this component.

- The unit starts in Game Mode and in Desktop Mode after login, and after
  PipeWire restarts.
- The jack: plugging and unplugging headphones moves the filter between the
  outputs within a few seconds, and the default output follows.
- What Steam's output list shows. The surround sink appears as "Headphones
  (7.1 surround)" or "Speakers (7.1 surround)" next to the plain outputs;
  hiding the plain ones is not attempted. During a switch two entries with
  the same name exist for about a second.
- A game opens an 8-channel stream on the surround sink.
- Volume keys and Steam's volume slider act on the surround sink as on the
  plain one, and the level after a switch is sensible. A switch creates a
  new sink (`_a`, then `_b`); whether the volume set on the old one carries
  over to the new one is not known.
- Resume from sleep.
- The speaker path of the component as a whole: the default
  (`sadie-d2-dry`, `xtc 60 50`) playing after `apply`, the variant being
  generated by the service on first use, `surround prepare` and
  `surround xtc` on the device (python3 3.14), and the time they take
  there. The settings themselves were listened to with the test rig, which
  uses the same `x20dsp` code, not with this component.
- Switching while a game plays: that a change of profile or of the
  crosstalk setting is heard without a gap, click or level jump, in both
  directions (`_a` to `_b` and back). The container check shows only that
  the hardware sink never becomes the default.
- An explicit choice in Steam: when the surround sink was picked by hand
  in Steam's output list, what Steam shows and plays on after a switch has
  replaced that sink with its twin.
- The owner's impression that `-full` makes the fronts quieter on the
  speakers: not measured.
