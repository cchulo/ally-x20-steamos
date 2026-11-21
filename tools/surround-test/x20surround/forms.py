# SPDX-License-Identifier: GPL-2.0-only
"""Derive the "dry fronts" form of a 14-channel HRIR set.

FL, FR and FC become plain delayed impulses (FL to the left ear only, FR to
the right ear only, FC to both, 3 dB down per ear); the sides and rears keep
their HRIRs. Encoding the dry paths as impulses in the WAV keeps one
PipeWire graph for every candidate.

The impulses sit at the onset of the original front HRIRs so the fronts
stay time-aligned with the surrounds, and their gain makes the dry FL as
loud (K-weighted, both ears) as the HRTF FL was, so the front/surround
balance of the set is kept.
"""

import math

from . import dsp, level
from .layout import pairs, unpairs

DRY = ("FL", "FR", "FC")


def dry_fronts(channels, rate=level.RATE):
    table = dict(pairs(channels))
    length = max(len(h) for h in channels)
    onsets = [dsp.arrival(table[(c, e)]) for c in ("FL", "FR") for e in ("L", "R")]
    onsets = [o for o in onsets if o is not None]
    at = min(onsets) if onsets else 0
    front = sum(
        level.weighted_power(table[(c, e)], rate) for c in ("FL", "FR") for e in ("L", "R")
    ) / 2.0
    unit = level.weighted_power([1.0], rate)
    gain = math.sqrt(front / unit) if front > 0.0 else 1.0
    half = gain * math.sqrt(0.5)
    silent = [0.0] * length
    table[("FL", "L")] = dsp.impulse(gain, at, length)
    table[("FL", "R")] = list(silent)
    table[("FR", "R")] = dsp.impulse(gain, at, length)
    table[("FR", "L")] = list(silent)
    table[("FC", "L")] = dsp.impulse(half, at, length)
    table[("FC", "R")] = dsp.impulse(half, at, length)
    return unpairs(table)
