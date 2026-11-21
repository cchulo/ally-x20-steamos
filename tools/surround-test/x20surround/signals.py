# SPDX-License-Identifier: GPL-2.0-only
"""Test signals for the switcher, generated on the device (no audio files in
the repository): single-channel call-outs for the localisation test,
7-channel noise for the level calibration, and the impulse file that
measures the raw downmix. All are 8-channel 48 kHz files in sink order."""

import math
import random

from . import dsp, wav
from .layout import INPUTS, MASK_71, RATE, SPEAKERS

# Level of the call-out bursts and of each calibration channel, dBFS RMS.
CALLOUT_DB = -23.0
NOISE_DB = -26.0
LEAD_IN = 0.3  # seconds of silence so a suspended sink can wake up


def pink(count, rng):
    """Pink noise (Paul Kellet's economy filter), unit RMS."""
    b0 = b1 = b2 = 0.0
    out = []
    for _ in range(count):
        white = rng.uniform(-1.0, 1.0)
        b0 = 0.99765 * b0 + white * 0.0990460
        b1 = 0.96300 * b1 + white * 0.2965164
        b2 = 0.57000 * b2 + white * 1.0526913
        out.append(b0 + b1 + b2 + white * 0.1848)
    rms = math.sqrt(dsp.energy(out) / count) if count else 1.0
    return [v / rms for v in out]


def bursts(rng, count=3, on=0.2, gap=0.1, fade=0.01, level_db=CALLOUT_DB, rate=RATE):
    """`count` pink-noise bursts with raised-cosine fades."""
    n_on, n_gap, n_fade = int(on * rate), int(gap * rate), int(fade * rate)
    gain = dsp.from_db(level_db)
    out = [0.0] * int(LEAD_IN * rate)
    for _ in range(count):
        noise = pink(n_on, rng)
        for i, v in enumerate(noise):
            edge = min(i, n_on - 1 - i)
            w = 0.5 - 0.5 * math.cos(math.pi * edge / n_fade) if edge < n_fade else 1.0
            out.append(v * w * gain)
        out.extend([0.0] * n_gap)
    return out


def callout(path, channel, seed=20):
    """A call-out in one channel. The same noise for every channel, so the
    only thing that changes between call-outs is the direction."""
    signal = bursts(random.Random(seed))
    data = [signal if c == channel else [0.0] * len(signal) for c in INPUTS]
    wav.write(path, RATE, data, MASK_71)


def noise(path, seconds=3.0, seed=7):
    """Uncorrelated pink noise at equal level in the seven full-range
    channels: the reference programme of x20surround.level."""
    rng = random.Random(seed)
    count = int(seconds * RATE)
    gain = dsp.from_db(NOISE_DB)
    lead = [0.0] * int(LEAD_IN * RATE)
    data = []
    for c in INPUTS:
        if c in SPEAKERS:
            data.append(lead + [v * gain for v in pink(count, rng)])
        else:
            data.append([0.0] * (len(lead) + count))
    wav.write(path, RATE, data, MASK_71)


IMPULSE_FIRST = 1.0
IMPULSE_SPACING = 0.25
IMPULSE_LEVEL = 0.5


def impulses(path):
    """One impulse per input channel, IMPULSE_SPACING apart."""
    frames = int(RATE * (IMPULSE_FIRST + IMPULSE_SPACING * len(INPUTS) + 0.5))
    data = [[0.0] * frames for _ in INPUTS]
    for k in range(len(INPUTS)):
        data[k][int(RATE * (IMPULSE_FIRST + IMPULSE_SPACING * k))] = IMPULSE_LEVEL
    wav.write(path, RATE, data, MASK_71)


def read_impulses(left, right):
    """From a stereo recording of impulses(): {input: (gain to L, gain to
    R)}, or None when no impulse is found."""
    top = max(dsp.peak(left), dsp.peak(right))
    if top <= 0.0:
        return None
    first = next(i for i in range(len(left)) if max(abs(left[i]), abs(right[i])) > 0.25 * top)
    step = int(RATE * IMPULSE_SPACING)
    out = {}
    for k, c in enumerate(INPUTS):
        at = first + k * step
        if at >= len(left):
            return None
        out[c] = (left[at] / IMPULSE_LEVEL, right[at] / IMPULSE_LEVEL)
    return out


# BS.1770 K-weighting at 48 kHz (same filters as x20surround.level).
_K_SHELF = ((1.53512485958697, -2.69169618940638, 1.19839281085285),
            (1.0, -1.69065929318241, 0.73248077421585))
_K_HP = ((1.0, -2.0, 1.0), (1.0, -1.99004745483398, 0.99007225036621))


def loudness_db(left, right):
    """K-weighted level of the steady part of a stereo recording, or None
    when it is silent."""
    top = max(dsp.peak(left), dsp.peak(right))
    if top < 1e-6:
        return None
    limit = 0.05 * top
    idx = [i for i in range(len(left)) if abs(left[i]) > limit or abs(right[i]) > limit]
    start, end = idx[0], idx[-1] + 1
    span = end - start
    a, b = start + int(0.15 * span), end - int(0.15 * span)
    total = 0.0
    for chan in (left, right):
        x = dsp.biquad_filter(chan[start:end], *_K_SHELF)
        x = dsp.biquad_filter(x, *_K_HP)
        total += dsp.energy(x[a - start:b - start])
    return dsp.db(total / (2.0 * max(b - a, 1)))
