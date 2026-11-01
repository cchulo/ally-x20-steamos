# Crosstalk cancellation (XTC) for the X20 speakers: removed

Plan section 1.5, item 5. Historical note: from 2026-10 until it was
removed on 2026-10-31, the `audio_dsp` component shipped a speaker virtual
surround sink, `x20-speakers-surround` (conf `52-x20-speaker-surround.conf`).
The sink is gone. What follows records what it did, why it was removed and
what a better attempt would need. The full design notes (literature,
geometry, RACE maths) are in the git history of this file.

## What it was

- **Binaural render**: every channel of a 7.1 stream went through the sofa
  spatializer at its 7.1 angle, with the same HRTF set (`current.sofa`) as
  `x20-headphones`.
- **Crosstalk cancellation**: a 4-tap RACE network (Glasgal's Recursive
  Ambiophonic Crosstalk Eliminator) built from builtin `delay`, `invert` and
  `mixer` nodes. Each side got an inverted, delayed (117 us, rendered as 6
  samples at 48 kHz) and attenuated (4 dB per tap) copy of the other side,
  plus that copy's own crosstalk, truncated after 4 taps. The taps saw a
  300 Hz-5 kHz band copy; the direct path was full band.
- **Then the speaker chain**: the stereo result went into `x20-speakers`
  (downmix, width, EQ) and on to the hardware speakers.
- The numbers came from a geometric model, not a measurement: speakers
  about 22 cm apart, listener at about 40 cm, 15 cm spherical head
  (Woodworth delay, Brown-Duda head shadow at 2 kHz).

## Why it was removed

Owner decision on the device (2026-10-31): `x20-speakers-surround` "sounds
muffled, like sand in my ears", while `x20-speakers` is "much crisper and
closer to the default experience on Windows".

That matches what the network does. Every tap is a delayed copy summed with
the direct signal, so content that both speakers carry (dialogue, centred
sources, most of a game mix) goes through a comb filter: the mid signal is
cut by about 3.4 dB at the low end of the band, the side signal boosted by up
to 7.7 dB, and the pattern reverses towards 1/(2 x 125 us), about 4 kHz,
so peaks and dips alternate across the band the taps cover. A canceller tuned for one fixed head position
gives this colouration to every listener, while the cancellation itself only
works within a few centimetres of that position. On these small speakers,
the colouration won.

## What a better attempt would need

1. **Cancellation limited to below about 5 kHz**, with frequency-dependent
   regularisation (`C = (H^H H + beta(f) I)^-1 H^H`, Choueiri's BACCH
   approach) instead of fixed broadband taps, so the filter never boosts or
   notches where the 2x2 problem is badly conditioned. Above about 5 kHz the
   head already separates the ears; the signal should pass untouched.
2. **Measured head-related filters for the device geometry** instead of a
   point-source model: the four speaker-to-ear impulse responses with the
   X20 held normally (in-ear binaural microphones or a head and torso
   simulator, exponential sine sweeps at 48 kHz), repeated at perturbed
   positions (+-2 cm, slight yaw) to design for robustness, plus each
   speaker's on-axis response and distortion versus level to set the band
   limits and the largest allowed boost.
3. **The resulting filters as four FIR convolvers** (`convolver` nodes with
   WAV impulse responses) in place of the RACE network, and a level-matched
   blind A/B against `x20-speakers` before it ships, let alone becomes a
   default.

Literature: Bauck and Cooper, "Generalized transaural stereo and
applications" (JAES 1996); Kirkeby, Nelson and Hamada, "The 'Stereo Dipole'"
(JAES 1998); Choueiri, "Optimal crosstalk cancellation for binaural audio
with two loudspeakers" (Princeton 3D3A Lab); Gardner, *3-D Audio Using
Loudspeakers* (MIT, 1997); Parodi and Rubak on robustness (JAES 2010/2011).
