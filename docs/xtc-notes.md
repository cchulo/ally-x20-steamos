# Transaural crosstalk cancellation (XTC) for the X20 speakers

Stretch goal from plan section 1.5, item 5. It is not in v0.1. This note
records what the literature says, whether PipeWire can run it, and what we
would have to measure on the device before shipping anything.

## The problem

Binaural audio (the HRTF chain) assumes each ear hears only its own channel.
Speakers break that assumption. The left ear also hears the right speaker,
slightly later and filtered by the head (the "crosstalk" path). Crosstalk
cancellation pre-filters the two speaker feeds so that, at the two ear
positions, the crosstalk paths cancel. Each ear then receives
approximately its own binaural signal. When it works, sound can come from
outside the span of the speakers, including to the side.

## Literature in brief

- **Atal and Schroeder (1962/1966)**, and **Bauck and Cooper**, "Generalized
  transaural stereo and applications" (JAES 44(9), 1996): the 2x2 inverse
  formulation. With speaker-to-ear transfer matrix
  `H = [[H_LL, H_RL], [H_LR, H_RR]]`, the canceller is `C = H^-1`,
  usually written as a shuffler (sum/difference) structure for symmetric
  geometries.
- **Kirkeby, Nelson and Hamada**, "The 'Stereo Dipole'" (JAES 46(5), 1998):
  closely spaced speakers (about 10 deg span) make the inversion much more
  robust to head movement than the classic 60 deg stereo layout. The cost is
  a large low-frequency boost. A handheld is a stereo dipole by
  construction.
- **Takeuchi and Nelson**, "Optimal source distribution" (JASA 111, 2002):
  the ideal span depends on frequency (wide for low frequencies, narrow for
  high). It explains why a single fixed pair is badly conditioned at certain
  frequencies.
- **Choueiri**, "Optimal crosstalk cancellation for binaural audio with two
  loudspeakers" (BACCH, Princeton 3D3A Lab, 2008/2018): frequency-dependent
  regularisation (`C = (H^H H + beta(f) I)^-1 H^H`) limits the
  boost wherever `H` is ill-conditioned. This is what makes XTC listenable
  instead of harsh and boomy.
- **Gardner**, *3-D Audio Using Loudspeakers* (MIT thesis, 1997):
  practical design and head-tracking considerations. Without head tracking,
  the "sweet spot" is a few centimetres wide.
- **Parodi and Rubak** (JAES 2010/2011): objective robustness evaluation;
  channel separation of 15-20 dB is about what non-tracked systems achieve.

## Geometry of the X20 and conditioning

The handheld fixes the geometry better than any desk setup: the device is
held at roughly 30-45 cm in front of the face, centred, with the speakers
near the two ends of the chassis. TODO(hw): measure the speaker positions
and their direction (front- or down-firing).

As a rough estimate, with about 20 cm between the speakers at 40 cm, the
span is +-14 deg, a stereo dipole. With an ear spacing of about 18 cm, the
path difference between the near and far speaker to one ear is
`dr ~ 0.18 m * sin(14 deg) ~ 4.4 cm`. The 2x2 problem is:

- best conditioned near `f = c / (4 dr) ~ 1.9 kHz`;
- ill-conditioned towards DC and again near `f = c / (2 dr) ~ 3.9 kHz` (and
  its multiples), where the direct and crosstalk paths arrive in phase.

In practice that means:

- At low frequencies the canceller needs a large boost. The micro speakers
  cannot deliver it, and the speaker chain already high-passes at 150 Hz.
  XTC must be band-limited, roughly 300 Hz - 3 kHz, with regularisation
  outside that band.
- Above roughly 4 kHz the head shadow already gives natural separation. A
  fixed filter there mostly adds colouration.
- Head movement of +-2 cm shifts the 3.9 kHz notch noticeably. That favours
  strong regularisation and a modest separation target (10-15 dB) over an
  aggressive inverse.

## Feasibility in PipeWire

Feasible with builtin nodes only. The 2x2 canceller is four FIR filters and
two sums:

```
L_out = C_LL * L_in + C_RL * R_in
R_out = C_LR * L_in + C_RR * R_in
```

In a filter graph that is four `convolver` nodes (each with `config.filename`
pointing at a mono or multi-channel WAV IR and a `channel` index), two
`copy` nodes for the fan-out and two `mixer` nodes. It is the same topology
as PipeWire's `sink-virtual-surround-5.1-kemar.conf` example. At 48 kHz with
1024-4096 taps, the partitioned convolver costs a fraction of a percent of
one Zen core. For symmetric geometry the shuffler form needs only two
convolvers (sum and difference).

The chain would be: game audio -> HRTF virtual surround (already built) ->
XTC canceller -> speaker EQ. That makes it a third sink or a mode of
`x20-speakers`, with the router choosing it when the internal speakers are
active.

## What we would need to measure

1. **Four impulse responses** (each speaker to each ear) at the playing
   position. Use in-ear binaural microphones on a person, or a head and
   torso simulator, holding the X20 in normal posture. An exponential sine
   sweep, 48 kHz, several repetitions.
2. **The same at a few perturbed positions** (+-2 cm left/right and
   forward/back, slight yaw) to design for robustness instead of one exact
   point.
3. **Each speaker's on-axis response and its distortion versus level**,
   to choose the band limits and the maximum allowed boost.
4. **A listening test**: separation and localisation with and without XTC,
   checking for colouration, against plain stereo plus the widener.

Design steps would then be: compute `C(f)` with frequency-dependent
regularisation from the averaged (or minimax over positions) `H`; window and
truncate to minimum phase plus delay; export four WAV IRs. Those WAVs are
derived from our own measurements, so they could be committed as small data
files under a clear license, unlike the third-party HRTF sets. Alternatively
they can be generated at install time from a parametric model.

A no-measurement alternative is an analytic model: two point sources plus a
spherical-head model (Brown and Duda, 1998) with the measured geometry. It
is cheaper to produce but less accurate, and the expected separation is
around 6-10 dB.

## Status

Not shipped. Prerequisites: the X20 in hand, speaker positions, and the four
impulse responses described above. The speaker chain (downmix, width, EQ)
is the v0.1 behaviour on speakers.
