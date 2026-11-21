# Virtual 7.1 surround for the built-in outputs (component `surround`)

Stock SteamOS offers the X20's headphone jack and speakers as stereo
outputs, so a game sends a stereo mix. This component puts an 8-channel
output in front of the built-in output in use. A game then sends 7.1, and a
filter turns it into two channels that carry direction cues for headphones.

- **Headphones:** on by default, with the profile `sadie-d2-dry`.
- **Speakers:** stereo by default. The same profiles can be selected, but
  they were measured for headphones and nothing was tested on the speakers.
- **Other outputs** (Bluetooth, USB, HDMI) are not touched.

Status: the generated PipeWire setup and the default-output behaviour are
checked on a private PipeWire 1.6.11 and WirePlumber 0.5.19 without
hardware (`tests/surround/headless.py`). The component has not run on the
X20 yet; the open points are in [Needs the device](#needs-the-device-todohw).

## Profiles

| Profile | What it is |
|---|---|
| `stereo` | no filter: the output as stock SteamOS has it |
| `sadie-d2-dry`, `sadie-d2-full` | KEMAR mannequin, SADIE II database (`-dry` is the default for headphones) |
| `hutubs-pp1-dry`, `hutubs-pp1-full` | FABIAN head and torso simulator, HUTUBS database, subject pp1 |
| `mit-kemar-dry`, `mit-kemar-full` | KEMAR mannequin with normal ears, MIT |
| `mit-kemar-large-dry`, `mit-kemar-large-full` | the same mannequin with large ears |
| `user` | your own file (below) |

Each shipped profile is a set of head-related impulse responses: how sound
from seven directions reaches the two ears of one head. All four heads are
acoustic mannequins, not people. Ears differ, so try them; the one that
comes closest to your ears places sounds best.

Every head comes in two forms:

| Form | Front left, front right, centre | Sides and rears | In the listening tests |
|---|---|---|---|
| `-dry` | unfiltered, as in plain stereo | filtered | preferred over stereo in games; sounds a little easier to place than in stereo |
| `-full` | filtered, like speakers in front of you | filtered | sounds far easier to place; stereo was preferred for its tone |

With `-dry`, stereo material, which uses only the front channels, sounds as
it does without the component. With `-full`, everything is coloured by the
filter. `-dry` is the default because it was the listener's preference;
`-full` is there for those who want the sharper positioning.

Sources, licences and what was changed: `overlay/surround/NOTICE.md`
(installed next to the files).

## Choosing a profile

```sh
ally-x20-steamos surround status                 # choice per output, what runs
ally-x20-steamos surround list                   # the profiles
ally-x20-steamos surround set hutubs-pp1-dry     # for the output in use
ally-x20-steamos surround set stereo --device speakers
```

Run it as your user, without `sudo`. The change takes effect within a few
seconds, while a game is running. The choice is kept per output in
`~/.config/ally-x20-steamos/surround.conf`, so it survives reboots and
SteamOS updates.

A game picks its channel count when it starts. Going from `stereo` to a
surround profile therefore needs a restart of the game; switching between
surround profiles does not.

### Your own file

Copy a `.wav` file into `~/.config/ally-x20-steamos/surround-user/` and
select `user`:

```sh
mkdir -p ~/.config/ally-x20-steamos/surround-user
cp my-hrir.wav ~/.config/ally-x20-steamos/surround-user/
ally-x20-steamos surround set user
```

- The file name does not matter. With several files the first in lexical
  order is used.
- This is how to use a Dolby Atmos for Headphones profile, or any other
  HeSuVi impulse response: such files are not shipped because they are not
  ours to redistribute. The owner's Atmos file came from the HRIR collection
  at <https://airtable.com/appayGNkn3nSuXkaz/shruimhjdSakUPg2m/tbloLjoZKWJDnLtTc>
  (the 14-channel 48 kHz `.wav` of the Atmos entry) and was used as it is.
  In the listening tests it was preferred over stereo in both game
  comparisons it was part of; nothing more was measured for it.
- It must be a 14-channel, 48 kHz impulse response set in the HeSuVi channel
  order (PCM 16/24/32-bit or 32-bit float), at most one second long.
- With no file, or a file that is not usable, the output's default is used
  instead (`sadie-d2-dry` for headphones, `stereo` for speakers), and
  `surround status` says why.
- Its loudness is matched to stereo by a coarse estimate (the energy of the
  front-left responses, limited to -12..+3 dB), not by measurement.

## How it works

The user unit `ally-x20-steamos-surround.service` runs
`/etc/ally-x20-steamos/surround/x20-surround run` (python3, standard library
only). Every two seconds it reads PipeWire's state (`pw-dump`, about 10 ms
on the X20) and decides:

1. **Which built-in output is in use.** The headphones when the sound card's
   route `[Out] Headphones` is reported as available (the jack), otherwise
   the speakers.
2. **Which profile that output has**, from the settings file.
3. **What should run.** For `stereo`, nothing. Otherwise one
   `pipewire -c <generated config>` process, replaced when the output or
   the profile changes.

The generated config is PipeWire 1.6.8's own 7.1 HeSuVi virtual-surround
graph (copy nodes, 16 convolvers reading the 14-channel file, two mixers)
with three additions that were measured with the test rig of pull request
#70:

- a level trim per profile, so a profile is as loud as stereo (within
  0.5 dB on the X20's headphone output, 2026-11-20);
- a hard ceiling at -1 dBFS on each output channel;
- the output pinned to the one hardware sink (`target.object`,
  `node.dont-fallback`, `node.linger`), so the sound never ends up on
  another output.

**No default is forced.** The surround sink gets a session priority one
above its hardware sink (1001 for the headphones, 713 for the speakers on
the X20). WirePlumber therefore makes it the default exactly when it would
have picked that hardware output. An output chosen by hand in Steam
(Bluetooth, HDMI, or the plain built-in one) still wins, and choosing the
plain built-in output there is a way to bypass the filter.

Nothing is written under `~/.config/pipewire` or `/usr`.

## Why these profiles

They come from blind listening tests on the X20's headphone output with the
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

## Checking and debugging

```sh
ally-x20-steamos surround status
systemctl --user status ally-x20-steamos-surround.service
journalctl --user -u ally-x20-steamos-surround.service -b
wpctl status            # the surround sink is listed and marked as default
cat "$XDG_RUNTIME_DIR/ally-x20-steamos-surround/headphones.conf"
```

The journal has one line per change, for example
`headphones: sadie-d2-dry (sadie-d2-dry.wav, trim -1.10 dB) on alsa_output…`.

To check that a game sends 7.1, look at its stream while it plays:
`pw-dump | grep -A3 '"audio.channels"'` or `pw-top` (8 channels).

To switch everything off: `ally-x20-steamos surround set stereo` for both
outputs, or `systemctl --user stop ally-x20-steamos-surround.service`.

## Needs the device (`TODO(hw)`)

- The unit starts in Game Mode and in Desktop Mode after login, and after
  PipeWire restarts.
- The jack: plugging and unplugging headphones moves the filter between the
  outputs within a few seconds, and the default output follows.
- What Steam's output list shows. The surround sink appears as "Headphones
  (7.1 surround)" or "Speakers (7.1 surround)" next to the plain outputs;
  hiding the plain ones is not attempted.
- A game opens an 8-channel stream on the surround sink.
- Volume keys and Steam's volume slider act on the surround sink as on the
  plain one, and the level after a switch is sensible.
- Resume from sleep.
- Any profile on the speakers.
