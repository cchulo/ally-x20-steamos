# Transaural crosstalk cancellation (XTC) for the X20 speakers

Plan section 1.5, item 5. The parametric version ships as the
`x20-speakers-surround` sink
([`52-x20-speaker-surround.conf`](../overlay/home/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf),
user guide in [`audio-dsp.md`](audio-dsp.md#speaker-virtual-surround)). This
note gives the literature, the RACE network we build from builtin
filter-graph nodes, how the X20 numbers were derived, and what measured
filters would add later.

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

## Geometry of the X20

The handheld fixes the geometry better than any desk setup: it is held
centred in front of the face, and the two speakers fire forward from the
ends of the chassis, near the grips.

| Quantity | Value | Source |
|---|---|---|
| Chassis width | 290 mm | product dimensions |
| Speaker separation `2a` | about 22 cm | speakers about 34 mm in from each end, in front of the grips. TODO(hw): measure with a ruler |
| Listening distance `D` | 35-45 cm, 40 cm nominal | normal handheld posture |
| Head width | 15 cm, so head radius `r` = 7.5 cm | assumed; the adult average is 14-16 cm |
| Speed of sound `c` | 343 m/s | 20 deg C |

Each speaker sits at `theta = atan(a / D)` from straight ahead:
13.7 deg at 45 cm, 15.4 deg at 40 cm and 17.4 deg at 35 cm. A span of about
+-15 deg makes the X20 a "stereo dipole" (Kirkeby et al.) by construction.

### Crosstalk delay

The far speaker's sound reaches the opposite ear later than the near
speaker's sound reaches the near ear. With a spherical head, Woodworth's
formula gives the extra time:

```
tau = (r / c) * (theta + sin theta)
```

| D | theta | tau (Woodworth) | tau (straight paths, no head) |
|---|---|---|---|
| 45 cm | 13.7 deg | 104 us | 103 us |
| 40 cm | 15.4 deg | 117 us | 114 us |
| 35 cm | 17.4 deg | 132 us | 129 us |

Default: **`xtc_delay_us = 117`** (40 cm).

The builtin `delay` node works in whole samples. It computes
`(uint32_t)(delay * rate)`, which truncates. At 48 kHz one sample is 20.8 us,
so the component rounds to the nearest sample and renders
`(n + 0.5) / 48000` s, a value that truncation cannot drop below `n`. The
steps you can actually hear are:

| xtc_delay_us | samples | effective delay | matches D of about |
|---|---|---|---|
| 73-93 | 4 | 83 us | 57 cm |
| 94-114 | 5 | 104 us | 45 cm |
| 115-135 | 6 | 125 us | 37 cm |
| 136-156 | 7 | 146 us | 31 cm |

So the default 117 us plays as 6 samples (125 us), matching a listener at
about 37 cm, a natural handheld distance.

### Crosstalk attenuation

The far-ear path is longer (point source, `1/r`) and shadowed by the head.
At D = 40 cm the extra distance costs 0.8 dB. For the shadow, the
single-pole-zero spherical-head model of Brown and Duda (1998), evaluated for
the near ear (74.6 deg from the source) and the far ear (105.4 deg), gives
this total far/near level difference:

| Frequency | 500 Hz | 1 kHz | 2 kHz | 3 kHz | 4 kHz | 5 kHz |
|---|---|---|---|---|---|---|
| Crosstalk attenuation | 1.2 dB | 2.2 dB | 4.1 dB | 5.4 dB | 6.1 dB | 6.6 dB |

A single broadband value must be picked. 2 kHz is the geometric centre of the
cancellation band and the region where the 2x2 problem is best conditioned
(see below). Default: **`xtc_attenuation_db = 4`**, so
`g = 10^(-4/20) = 0.631`. Errors in the safe direction are preferable. Too much
attenuation (small `g`) under-cancels and only narrows the effect. Too little
over-cancels, which sounds phasey and boosts the side signal.

## The RACE network

Glasgal's RACE (Recursive Ambiophonic Crosstalk Eliminator) models each
crosstalk path as "the other speaker, `tau` later and `g` quieter", and
cancels it with an inverted, delayed and attenuated copy of the opposite
*output*. The copy's own crosstalk is then cancelled by the next round:

```
L' = L - g * D(R')
R' = R - g * D(L')          D = delay by tau
```

PipeWire filter graphs must be acyclic, so the recursion is expanded and
truncated after N taps:

```
L' = L - g D R + g^2 D^2 L - g^3 D^3 R + g^4 D^4 L - ...
R' = R - g D L + g^2 D^2 R - g^3 D^3 L + g^4 D^4 R - ...
```

Odd taps come from the opposite channel and are negative. Even taps come from
the same channel and are positive. The first omitted term is
`g^(N+1)`: -15 dB for N = 4 at g = 0.708, and -20 dB at the default
g = 0.631. That is about the 15-20 dB of separation non-tracked systems reach
in practice (Parodi and Rubak), so more taps would not be audible.
Default: **`xtc_taps = 4`**. Taps beyond `xtc_taps` keep their nodes with a gain
of 0.

In the graph, each side has one chain of four `delay` nodes in series (each
`tau`), fed with a band-limited copy of that side's binaural signal. Tap k is
the output of delay k. The `mixer` node only accepts gains >= 0, so the odd
taps pass through `invert` nodes. Two output mixers sum: the full-band direct
signal (gain 1), taps 1-4 (`g`, `g^2`, `g^3`, `g^4`) and the LFE (0.5). That
makes 7 sofa, 8 delay, 4 invert, 4 biquad, 4 mixer and 1 copy node: a few
hundred multiply-adds per sample on top of the HRTF convolutions.

### What the network does to the sound

For a symmetric layout the canceller splits into a sum (mid) and a
difference (side) filter:

```
mid:  1 / (1 + g e^(-j w tau))      side: 1 / (1 - g e^(-j w tau))
```

At the low end of the band, where `w tau` is small, mid content (dialogue,
centred sources) drops by `1/(1+g)`, about -3.4 dB. Side content (sources off
to the side, reverb) rises by up to `1/(1-g)`. The 4-tap sum gives +7.7 dB at
g = 0.631. Towards `f = 1/(2 tau)`, about 4 kHz, the pattern reverses. This
tilt in timbre is inherent to XTC. It is why the cancellation is
band-limited, why `g` stays well below 1, and why the HRTF stage keeps -6 dB
of headroom per source.

### Band limiting

The taps see the binaural signal through a 300 Hz high-pass and a 5 kHz
low-pass (2nd order, Q 0.707). The direct path is full band, so bass and
highs pass straight through.

- Below about 300 Hz, cancelling needs a large side boost that the micro
  speakers cannot deliver. The speaker chain high-passes at 150 Hz anyway.
- Above about 5 kHz, the head shadow already separates the ears (more than
  6 dB, see the table above), and the comb filtering of a fixed canceller
  would only add colouration.
- The branch filters shift phase. Their phase delay is -24 us at 1 kHz,
  +30 us at 2 kHz and +46 us at 4 kHz: within one sample of the tap delay
  and well inside the tolerance of head position. Near 500 Hz the high-pass
  lead (-250 us) makes the cancellation partial. That works like the
  low-frequency regularisation of an optimal design (Choueiri), only cruder.

### LFE

LFE carries no direction. It skips both the HRTF and the canceller. It is
low-passed at 120 Hz (two cascaded biquads) and added to both outputs at
-6 dB, as in the headphone sinks. The speaker chain's 150 Hz high-pass then
removes most of it from the micro speakers. The XTC side boost is one reason
the chain ends in a master gain (`audio-dsp.md`, "Headroom").

### Signal chain

```
stream (5.1/7.1) -> x20-speakers-surround
    7 x sofa (7.1 angles, same as x20-virtual-surround-71) -> binaural L/R
    -> RACE (300 Hz - 5 kHz taps) + LFE
    -> x20-speakers (downmix: stereo at unity, width w = 1.4, EQ)
    -> hardware Speaker sink
```

The speaker chain's widener (`L' = 1.2 L - 0.2 R` before headroom) is a
zero-delay crosstalk tap of its own. It slightly strengthens the first RACE
tap. Reusing the chain keeps a single EQ for both speaker paths. If the image
turns phasey once the preset is retuned, lower the width first.

## Tuning by ear

`audio-dsp xtc set <delay_us> <atten_db> [taps]` re-renders the conf and
restarts PipeWire.

- **Image collapses to the speakers / no width**: under-cancellation. Lower
  `atten_db` (3, then 2.5) or fix the delay.
- **Phasey, hollow, "pressure" on the ears, centre dialogue thin**:
  over-cancellation. Raise `atten_db` (5-6) or use `taps` 2-3.
- **Delay**: move in whole samples (104, 125, 146 us). If you hold the device
  closer, use a longer delay. The right value makes FL/FR in
  `audio-dsp test` sound clearly outside the chassis, and makes SL/SR move
  towards the sides instead of staying near the speakers.

## Feasibility of measured filters (future work)

The parametric RACE is a no-measurement design: two point sources, one
broadband attenuation, one delay. Its expected separation is 6-10 dB in the
sweet spot. A measured design would replace the network with four FIR
filters and two sums:

```
L_out = C_LL * L_in + C_RL * R_in
R_out = C_LR * L_in + C_RR * R_in
```

In a filter graph that is four `convolver` nodes (each with
`config.filename` pointing at a WAV IR), two `copy` nodes and two `mixer`
nodes, or two convolvers in the symmetric shuffler form. At 48 kHz with
1024-4096 taps the partitioned convolver costs a fraction of a percent of one
Zen core. The same sink and routing would carry it unchanged.

What it would need:

1. **Four impulse responses** (each speaker to each ear) at the playing
   position. Use in-ear binaural microphones on a person, or a head and torso
   simulator, with the X20 held normally. Exponential sine sweep, 48 kHz,
   several repetitions.
2. **The same at perturbed positions** (+-2 cm left/right and forward/back,
   slight yaw), to design for robustness instead of one exact point.
3. **Each speaker's on-axis response and its distortion versus level**, to
   choose the band limits and the maximum allowed boost.
4. **A listening test** against the parametric version and the plain
   speaker chain.

Design steps: compute `C(f) = (H^H H + beta(f) I)^-1 H^H` with
frequency-dependent regularisation from the averaged (or minimax) `H`.
Window and truncate it to minimum phase plus delay, then export four WAV
IRs. They would derive from our own measurements, so they could be committed
as small data files under a clear license. A measured HRTF of the actual
listener (instead of KEMAR) improves both stages. Both remain future work,
tracked with the speaker EQ in plan section 7.
