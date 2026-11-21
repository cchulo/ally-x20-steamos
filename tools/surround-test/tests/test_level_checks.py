# SPDX-License-Identifier: GPL-2.0-only
import math

import pytest

from x20surround import checks, dsp, forms, level
from x20surround.layout import EARS, RAW_DOWNMIX, SPEAKERS, pairs, unpairs


def raw_as_hrir():
    """The raw downmix written as a 14-channel set."""
    return unpairs({(c, ear): [RAW_DOWNMIX[c][i]] for c in SPEAKERS for i, ear in enumerate(EARS)})


def test_a_set_equal_to_raw_needs_no_trim():
    assert level.trim_db(raw_as_hrir()) == pytest.approx(0.0, abs=1e-6)


def test_trim_undoes_a_gain():
    louder = [[v * 2.0 for v in h] for h in raw_as_hrir()]
    assert level.trim_db(louder) == pytest.approx(-6.02, abs=0.01)


def test_trim_is_within_half_a_db_after_applying_it(channels):
    trim = level.trim_db(channels)
    matched = [[v * dsp.from_db(trim) for v in h] for h in channels]
    assert abs(level.trim_db(matched)) < 0.5


def test_good_set_passes(channels):
    trim, results = checks.run_all(channels)
    by = {r.name: r for r in results}
    assert by["routing"].status == checks.PASS
    assert by["symmetry"].status == checks.PASS
    assert by["centre"].status == checks.PASS
    assert checks.worst_status(results) in (checks.PASS, checks.WARN)
    assert isinstance(trim, float)


def test_routing_catches_swapped_ears(table):
    table[("SL", "L")], table[("SL", "R")] = table[("SL", "R")], table[("SL", "L")]
    r = checks.check_routing(table)
    assert r.status == checks.FAIL and "SL" in r.detail


def test_routing_catches_a_wrong_channel_order(channels):
    # the "-.wav" style mistake: channels 7.. shifted by one
    wrong = channels[:7] + channels[8:] + [channels[7]]
    assert checks.check_routing(pairs(wrong)).status == checks.FAIL


def test_routing_catches_late_near_ear_and_lopsided_centre(table):
    h = table[("FL", "L")]
    table[("FL", "L")] = [0.0] * 30 + h[:-30]
    assert "earlier in the far ear" in checks.check_routing(table).detail
    table = pairs(unpairs(table))
    table[("FC", "R")] = [v * 0.5 for v in table[("FC", "R")]]
    r = checks.check_routing(table)
    assert r.status == checks.FAIL and "FC differs" in r.detail


def test_routing_catches_silence(table):
    table[("RR", "L")] = [0.0] * 8
    table[("RR", "R")] = [0.0] * 8
    assert "RR is silent" in checks.check_routing(table).detail


def test_symmetry_flags_a_coloured_side(table):
    assert checks.check_symmetry(table).value == pytest.approx(0.0, abs=1e-6)
    b, a = dsp.butter2("lowpass", 1500.0, 48000)
    table[("FR", "R")] = dsp.biquad_filter(table[("FR", "R")], b, a)
    r = checks.check_symmetry(table)
    assert r.status in (checks.WARN, checks.FAIL) and "FR" in r.detail


def test_centre_flags_heavy_colouration(table):
    assert checks.check_centre(table).status == checks.PASS
    b, a = dsp.butter2("lowpass", 800.0, 48000)
    for ear in EARS:
        table[("FC", ear)] = dsp.biquad_filter(table[("FC", ear)], b, a)
    r = checks.check_centre(table)
    assert r.status == checks.WARN and "HEAVY" in r.detail and r.value > checks.CENTRE_HEAVY_DB


def test_centre_moderate_band(table):
    for ear in EARS:
        h = table[("FC", ear)]
        at = dsp.arrival(h)
        tilt = list(h)
        tilt[at + 1] -= 0.6 * h[at]  # a treble lift of about 7 dB
        table[("FC", ear)] = tilt
    r = checks.check_centre(table)
    assert checks.CENTRE_MODERATE_DB < r.value <= checks.CENTRE_HEAVY_DB
    assert "moderate" in r.detail


def test_headroom_of_raw_is_zero_and_gain_shows_up():
    table = pairs(raw_as_hrir())
    r = checks.check_headroom(table)
    assert r.status == checks.PASS and r.value == pytest.approx(0.0, abs=0.01)
    assert "all eight: bound +10.8 dBFS" in r.detail
    r = checks.check_headroom(table, trim_db=3.0)
    assert r.status == checks.WARN and r.value == pytest.approx(3.0, abs=0.01)
    r = checks.check_headroom(table, trim_db=9.0)
    assert r.status == checks.WARN and "HIGH" in r.detail


def test_dry_fronts(channels):
    dry = pairs(forms.dry_fronts(channels))
    full = pairs(channels)
    # sides and rears untouched
    for c in ("SL", "SR", "RL", "RR"):
        for ear in EARS:
            assert dry[(c, ear)] == full[(c, ear)]
    # fronts: one impulse on the own side, silence on the other
    assert dsp.energy(dry[("FL", "R")]) == 0.0 and dsp.energy(dry[("FR", "L")]) == 0.0
    left = [v for v in dry[("FL", "L")] if v]
    assert len(left) == 1
    # centre in both ears, 3 dB below a front
    centre = [v for v in dry[("FC", "L")] if v]
    assert centre == [v for v in dry[("FC", "R")] if v]
    assert centre[0] == pytest.approx(left[0] * math.sqrt(0.5))
    # time-aligned with the earliest original front arrival
    assert dsp.arrival(dry[("FL", "L")]) == min(
        dsp.arrival(full[(c, e)]) for c in ("FL", "FR") for e in EARS)
    # the dry front is as loud as the HRTF front was
    def front(t):
        return sum(level.weighted_power(t[(c, e)]) for c in ("FL", "FR") for e in EARS)
    assert dsp.db(front(dry)) == pytest.approx(dsp.db(front(full)), abs=0.01)
    # and the result is a clean candidate
    trim, results = checks.run_all(forms.dry_fronts(channels))
    assert {r.name: r.status for r in results}["centre"] == checks.PASS
    assert {r.name: r.status for r in results}["routing"] == checks.PASS
