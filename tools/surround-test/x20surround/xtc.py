# SPDX-License-Identifier: GPL-2.0-only
"""Crosstalk cancellation for the built-in speakers, baked into an HRIR set.

Speaker candidates are the headphone winner followed by a crosstalk
canceller that acts on the side and rear channels only and only between
about 250 Hz and 5 kHz. Because the whole chain is linear, the canceller is
folded into the 14-channel file, so the same PipeWire graph plays it.

Model (simulated, nothing was measured on the device): each speaker also
reaches the opposite ear, delayed by `delay` and scaled by `strength`,
within the band. With X = strength * bandpass * delay, the speaker feeds
that put the wanted ear signals (a, b) at the ears are

    left  = (a - X b) / (1 - X^2)  =  a - X b + X^2 a - X^3 b + ...
    right = (b - X a) / (1 - X^2)  =  b - X a + X^2 b - X^3 a + ...

truncated after `order` terms (the recursion of a RACE canceller, cut
short). The band-pass is two second-order Butterworth sections (minimum
phase, so the cancellation is exact in the middle of the band and fades
towards its edges). Fractional delays need a symmetric kernel, so every
path, the untouched channels included, gets the same bulk delay of
BULK samples (0.33 ms).

TODO(hw): delay and strength depend on the real speaker spacing and
listening distance; the sweep exists because they are not known.
"""

import os

from . import dsp, manifest, wav
from .layout import EARS, RATE, SPEAKERS, pairs, unpairs

BULK = 16
BAND = (250.0, 5000.0)
CHANNELS = ("SL", "SR", "RL", "RR")
ORDER = 3
KERNEL = 384  # samples kept of the band-pass response (8 ms)
DELAYS_US = (60, 80, 100, 120)
STRENGTHS = (0.3, 0.5, 0.7)


def bandpass(passes, band=BAND, rate=RATE, length=KERNEL):
    """Impulse response of the band-pass applied `passes` times."""
    hp = dsp.butter2("highpass", band[0], rate)
    lp = dsp.butter2("lowpass", band[1], rate)
    h = dsp.impulse(1.0, 0, length)
    for _ in range(passes):
        h = dsp.biquad_filter(dsp.biquad_filter(h, *hp), *lp)
    return h


def kernels(delay_us, strength, order=ORDER, band=BAND, rate=RATE):
    """(same, cross): the FIR applied to a channel's own-ear response and to
    its other-ear response. `same` contains the bulk delay and the even
    terms, `cross` the (negative) odd terms."""
    delay = delay_us * 1e-6 * rate
    same = dsp.impulse(1.0, BULK, BULK + 1)
    cross = []
    for k in range(1, order + 1):
        term = dsp.convolve(bandpass(k, band, rate), dsp.fractional_delay(BULK + k * delay))
        gain = strength ** k
        if k % 2:
            cross = dsp.add(cross, term, -gain)
        else:
            same = dsp.add(same, term, gain)
    return same, cross


def apply(channels, delay_us, strength, order=ORDER, which=CHANNELS, band=BAND, rate=RATE):
    """Return the 14-channel set with the canceller folded into `which`."""
    if not 0.0 <= strength < 1.0:
        raise ValueError("strength must be in [0, 1)")
    if delay_us < 0:
        raise ValueError("delay must not be negative")
    table = pairs(channels)
    same, cross = kernels(delay_us, strength, order, band, rate)
    out = {}
    for c in SPEAKERS:
        left, right = dsp.trim_tail(table[(c, "L")]), dsp.trim_tail(table[(c, "R")])
        if c in which and strength > 0.0:
            out[(c, "L")] = dsp.add(dsp.convolve(left, same), dsp.convolve(right, cross))
            out[(c, "R")] = dsp.add(dsp.convolve(right, same), dsp.convolve(left, cross))
        else:
            out[(c, "L")] = dsp.delayed(left, BULK)
            out[(c, "R")] = dsp.delayed(right, BULK)
    length = max(len(h) for h in out.values())
    for key in out:
        out[key] = out[key] + [0.0] * (length - len(out[key]))
    return unpairs(out)


def variant_id(base, delay_us, strength):
    return "%s-xtc-d%03d-s%02d" % (base, round(delay_us), round(strength * 100))


def sweep(delays=DELAYS_US, strengths=STRENGTHS):
    return [(d, s) for d in delays for s in strengths]


def at_ears(channels, delay_us, strength, band=BAND, rate=RATE):
    """Simulate the modelled crosstalk on a set: what reaches each ear when
    the set is played over the speakers. For tests and for curiosity."""
    table = pairs(channels)
    delay = delay_us * 1e-6 * rate
    leak = [strength * v for v in dsp.convolve(bandpass(1, band, rate),
                                               dsp.fractional_delay(BULK + delay))]
    out = {}
    for c in SPEAKERS:
        for ear, other in zip(EARS, reversed(EARS)):
            direct = dsp.delayed(table[(c, ear)], BULK)
            out[(c, ear)] = dsp.add(direct, dsp.convolve(table[(c, other)], leak))
    return out


def add_speaker_candidates(data, base_dir, winner_id, delays=DELAYS_US, strengths=STRENGTHS,
                           order=ORDER):
    """Derive the speaker candidates from one headphone candidate: the set
    itself (id "<winner>-speakers") plus the crosstalk sweep, written next
    to the winner's file and added to the manifest `data` for the device
    "speakers". Returns the new entries."""
    winner = manifest.find(data, winner_id)
    path = manifest.resolve(winner, base_dir)
    channels = manifest.read_hrir(path)
    meta = {"set": winner.get("set"), "licence": winner.get("licence"), "device": "speakers",
            "source": "speaker candidate from %s" % winner_id}
    made = [manifest.add(data, manifest.describe(path, "%s-speakers" % winner_id, form="no-xtc",
                                                 **meta), base_dir)]
    for delay, strength in sweep(delays, strengths):
        cid = variant_id(winner_id, delay, strength)
        target = os.path.join(os.path.dirname(path), cid + ".wav")
        wav.write(target, RATE, apply(channels, delay, strength, order=order))
        entry = manifest.describe(target, cid, form="xtc", xtc={
            "delay_us": delay, "strength": strength, "order": order,
            "band_hz": list(BAND), "channels": list(CHANNELS)}, **meta)
        made.append(manifest.add(data, entry, base_dir))
    return made
