# SPDX-License-Identifier: GPL-2.0-only
"""Offline checks of a 14-channel HRIR candidate. No audio hardware.

Each check returns a Result with status PASS, WARN or FAIL:
  routing    every loudspeaker is louder (and not later) in the ear on its
             own side, the centre is equal in both: catches a wrong channel
             order
  headroom   peak level after the level trim for a full-scale sine in one
             channel, with the absolute bounds for one channel and for all
             eight at once, next to the same figures for raw
  symmetry   left/right mirror pairs have the same spectrum
  centre     the centre channel's frequency response against raw (flat):
             heavy colouration is flagged
"""

import collections

from . import dsp, level
from .layout import EARS, INPUTS, MIRROR, OTHER_EAR, RAW_DOWNMIX, RATE, SIDE, SPEAKERS, pairs

Result = collections.namedtuple("Result", "name status value detail")

PASS, WARN, FAIL = "PASS", "WARN", "FAIL"

# Routing: minimum broadband level difference, own-side ear over far ear.
ROUTING_MIN_ILD_DB = 1.0
# Routing: the centre may differ this much between the ears.
ROUTING_CENTRE_DB = 2.0
# Headroom: a full-scale sine in one channel coming out above this level is
# a warning (the conf's ceiling clips it); above HEADROOM_HIGH_DB the
# warning says so. Never a failure: raw clips on full-scale material too.
HEADROOM_WARN_DB = 0.0
HEADROOM_HIGH_DB = 6.0
# Symmetry: mean absolute band difference between mirror pairs.
SYMMETRY_WARN_DB = 2.0
SYMMETRY_FAIL_DB = 6.0
# Centre colouration: spread (max - min) of the third-octave band levels of
# the centre channel between 200 Hz and 8 kHz. Raw is flat (0 dB).
CENTRE_BANDS = dsp.third_octaves(190.0, 8100.0)
CENTRE_MODERATE_DB = 6.0
CENTRE_HEAVY_DB = 10.0
LFE_GAIN = 0.5


def _band_db(h, rate):
    return [dsp.db(p) for p in dsp.band_powers(h, CENTRE_BANDS, rate)]


def check_routing(table, rate=RATE):
    problems = []
    worst = None
    for c in SPEAKERS:
        left = dsp.energy(table[(c, "L")])
        right = dsp.energy(table[(c, "R")])
        if left <= 0.0 and right <= 0.0:
            problems.append("%s is silent" % c)
            continue
        diff = dsp.db(left) - dsp.db(right)
        side = SIDE[c]
        if side is None:
            if abs(diff) > ROUTING_CENTRE_DB:
                problems.append("%s differs %.1f dB between the ears" % (c, diff))
            continue
        ild = diff if side == "L" else -diff
        worst = ild if worst is None else min(worst, ild)
        if ild < ROUTING_MIN_ILD_DB:
            problems.append("%s is %.1f dB louder in the far ear" % (c, -ild))
        near = dsp.arrival(table[(c, side)])
        far = dsp.arrival(table[(c, OTHER_EAR[side])])
        if near is not None and far is not None and near > far:
            problems.append("%s arrives %d samples earlier in the far ear" % (c, near - far))
    if problems:
        return Result("routing", FAIL, worst, "; ".join(problems))
    return Result("routing", PASS, worst, "smallest own-side advantage %.1f dB" % worst)


_SINE_GRID = [20.0 * 2.0 ** (k / 12.0) for k in range(120)]


def _l1(h):
    return sum(abs(v) for v in h)


def _sine_gain(h, rate):
    """(largest gain for a steady sine, its frequency), 20 Hz to 20 kHz in
    twelfth octaves."""
    h = dsp.trim_tail(h)
    power, freq = max((dsp.power_at(h, f, rate), f) for f in _SINE_GRID if f < rate * 0.49)
    return power ** 0.5, freq


def check_headroom(table, trim_db=0.0, rate=RATE, lfe_gain=LFE_GAIN):
    """Peak level after the level trim. "sine" is the largest gain for a
    full-scale sine in one channel (the figure the status is based on);
    "bound" is the sum of absolute samples, which no signal can exceed, for
    one channel and for all eight at once."""
    gain = dsp.from_db(trim_db)
    sine = 0.0
    sine_freq = 0.0
    single = 0.0
    total = {"L": 0.0, "R": 0.0}
    for c in INPUTS:
        src = "FC" if c == "LFE" else c
        scale = gain * (lfe_gain if c == "LFE" else 1.0)
        for ear in EARS:
            h = table[(src, ear)]
            v = _l1(h) * scale
            single = max(single, v)
            total[ear] += v
            if c != "LFE" and dsp.energy(h) > 0.0:
                g, f = _sine_gain(h, rate)
                if g * scale > sine:
                    sine, sine_freq = g * scale, f
    every = max(total.values())
    raw_every = max(sum(RAW_DOWNMIX[c][i] for c in INPUTS) for i in range(2))
    sine_db = dsp.amp_db(sine)
    detail = ("one channel: sine %+.1f dBFS near %d Hz, bound %+.1f dBFS; all eight: bound "
              "%+.1f dBFS (raw: +0.0, +0.0 and %+.1f)") % (
        sine_db, round(sine_freq), dsp.amp_db(single), dsp.amp_db(every), dsp.amp_db(raw_every))
    status = PASS
    if sine_db > HEADROOM_HIGH_DB:
        status = WARN
        detail = "HIGH, the ceiling clips loud passages: " + detail
    elif sine_db > HEADROOM_WARN_DB:
        status = WARN
    return Result("headroom", status, sine_db, detail)


def check_symmetry(table, rate=RATE):
    worst = 0.0
    where = ""
    seen = set()
    for c in SPEAKERS:
        for ear in EARS:
            other = (MIRROR[c], OTHER_EAR[ear])
            if (c, ear) == other or other in seen:
                continue
            seen.add((c, ear))
            a, b = table[(c, ear)], table[other]
            if dsp.energy(a) <= 0.0 and dsp.energy(b) <= 0.0:
                continue
            if dsp.energy(a) <= 0.0 or dsp.energy(b) <= 0.0:
                return Result("symmetry", FAIL, None,
                              "%s->%s is silent but its mirror is not" % (c, ear))
            da, dbb = _band_db(a, rate), _band_db(b, rate)
            diff = sum(abs(x - y) for x, y in zip(da, dbb)) / len(da)
            if diff > worst:
                worst, where = diff, "%s->%s vs %s->%s" % (c, ear, other[0], other[1])
    status = PASS
    if worst > SYMMETRY_FAIL_DB:
        status = FAIL
    elif worst > SYMMETRY_WARN_DB:
        status = WARN
    detail = "largest mean band difference %.1f dB (%s)" % (worst, where or "all pairs equal")
    return Result("symmetry", status, worst, detail)


def check_centre(table, rate=RATE):
    spread = 0.0
    lines = []
    for ear in EARS:
        levels = _band_db(table[("FC", ear)], rate)
        hi, lo = max(levels), min(levels)
        spread = max(spread, hi - lo)
        lines.append("%s ear %.1f dB (peak near %d Hz, dip near %d Hz)" % (
            ear, hi - lo, round(CENTRE_BANDS[levels.index(hi)]),
            round(CENTRE_BANDS[levels.index(lo)])))
    if spread > CENTRE_HEAVY_DB:
        status, word = WARN, "HEAVY colouration"
    elif spread > CENTRE_MODERATE_DB:
        status, word = WARN, "moderate colouration"
    else:
        status, word = PASS, "close to raw"
    return Result("centre", status, spread,
                  "%s: band spread 200 Hz-8 kHz, raw is 0 dB: %s" % (word, "; ".join(lines)))


def run_all(channels, rate=RATE, trim_db=None):
    """Run every check. Returns (trim_db, [Result, ...])."""
    table = pairs(channels)
    if trim_db is None:
        trim_db = level.trim_db(channels, rate)
    results = [
        check_routing(table, rate),
        check_headroom(table, trim_db, rate),
        check_symmetry(table, rate),
        check_centre(table, rate),
    ]
    return trim_db, results


def worst_status(results):
    order = {PASS: 0, WARN: 1, FAIL: 2}
    return max((r.status for r in results), key=lambda s: order[s], default=PASS)
