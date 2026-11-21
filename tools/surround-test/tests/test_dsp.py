# SPDX-License-Identifier: GPL-2.0-only
import math

import pytest

from x20surround import dsp, level

RATE = 48000


def test_power_at_matches_the_definition():
    h = [1.0, 0.5, -0.25, 0.125]
    for f in (100.0, 1234.5, 10000.0):
        w = 2 * math.pi * f / RATE
        want = abs(sum(v * complex(math.cos(w * n), -math.sin(w * n)) for n, v in enumerate(h))) ** 2
        assert dsp.power_at(h, f, RATE) == pytest.approx(want, rel=1e-9)


def test_impulse_is_flat_and_delay_does_not_change_magnitude():
    bands = dsp.third_octaves(190, 8100)
    assert len(bands) == 17 and bands[0] == pytest.approx(198.4, abs=0.1)
    assert bands[-1] == pytest.approx(8000.0)
    for p in dsp.band_powers(dsp.impulse(0.5, 40, 64), bands, RATE):
        assert p == pytest.approx(0.25, rel=1e-9)


def test_arrival_ignores_pre_ringing():
    h = [0.0] * 100
    h[10] = 0.05  # pre-ringing, 26 dB down
    h[40] = 1.0
    assert dsp.arrival(h) == 40
    assert dsp.arrival([0.0] * 8) is None


def test_trim_tail_and_peak():
    assert dsp.trim_tail([0.0, 1.0, 0.0, 0.0]) == [0.0, 1.0]
    assert dsp.peak([0.1, -0.7, 0.2]) == 0.7 and dsp.peak([]) == 0.0


def test_convolve_and_add():
    assert dsp.convolve([1.0, 2.0], [1.0, -1.0]) == pytest.approx([1.0, 1.0, -2.0])
    assert dsp.convolve([], [1.0]) == []
    assert dsp.add([1.0], [1.0, 2.0], 0.5) == [1.5, 1.0]


def test_butterworth_corners_are_3_db_down():
    for kind, f in (("lowpass", 5000.0), ("highpass", 250.0)):
        b, a = dsp.butter2(kind, f, RATE)
        assert dsp.db(dsp.biquad_power(b, a, f, RATE)) == pytest.approx(-3.01, abs=0.05)
        far = f / 16 if kind == "lowpass" else f * 16
        assert dsp.db(dsp.biquad_power(b, a, far, RATE)) == pytest.approx(0.0, abs=0.1)
        # the time-domain filter agrees with the analytic response
        h = dsp.biquad_filter(dsp.impulse(1.0, 0, 4096), b, a)
        assert dsp.db(dsp.power_at(h, 1000.0, RATE)) == pytest.approx(
            dsp.db(dsp.biquad_power(b, a, 1000.0, RATE)), abs=0.01)


def test_fractional_delay_delays_by_the_requested_amount():
    for micro in (60, 90, 120):
        delay = 16 + micro * 1e-6 * RATE  # 2.88, 4.32, 5.76 samples on a bulk delay
        k = dsp.fractional_delay(delay)
        assert sum(k) == pytest.approx(1.0)
        # phase at 1 kHz corresponds to the delay
        w = 2 * math.pi * 1000.0 / RATE
        z = sum(v * complex(math.cos(w * n), -math.sin(w * n)) for n, v in enumerate(k))
        assert -math.atan2(z.imag, z.real) / w == pytest.approx(delay, abs=0.02)
        assert abs(z) == pytest.approx(1.0, abs=0.01)
        # still flat at the top of the crosstalk band
        w = 2 * math.pi * 5000.0 / RATE
        z = sum(v * complex(math.cos(w * n), -math.sin(w * n)) for n, v in enumerate(k))
        assert abs(z) == pytest.approx(1.0, abs=0.02)
    with pytest.raises(ValueError):
        dsp.fractional_delay(2.88)


def test_k_weighting_reference_points():
    # BS.1770: 0 dB near 1 kHz (by +0.7 dB), +4 dB shelf at high frequencies,
    # strong roll-off at 20 Hz.
    assert dsp.db(level.k_weight(1000.0)) == pytest.approx(0.7, abs=0.2)
    assert dsp.db(level.k_weight(10000.0)) == pytest.approx(4.0, abs=0.3)
    assert dsp.db(level.k_weight(20.0)) < -10.0
