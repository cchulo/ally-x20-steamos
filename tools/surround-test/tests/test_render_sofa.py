# SPDX-License-Identifier: GPL-2.0-only
"""render_sofa.py against a synthetic SOFA file. Skipped where numpy, scipy
or h5py are missing (the device and plain CI images)."""

import os
import sys

import pytest

np = pytest.importorskip("numpy")
h5py = pytest.importorskip("h5py")
pytest.importorskip("scipy")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import render_sofa  # noqa: E402
from synthetic import write_sofa  # noqa: E402
from x20surround import checks, wav  # noqa: E402
from x20surround.layout import AZIMUTH, HESUVI_INDEX  # noqa: E402


def marker_azimuth(channel, gain):
    return channel[60] / gain * 3600.0


@pytest.mark.parametrize("cartesian", [False, True])
def test_picks_the_horizontal_measurement_at_each_angle(tmp_path, cartesian):
    sofa = render_sofa.load(write_sofa(str(tmp_path / "s.sofa"), cartesian=cartesian))
    channels, report = render_sofa.render(sofa)
    assert len(channels) == 14
    for speaker, azimuth in AZIMUTH.items():
        assert report["directions"][speaker]["error_deg"] == pytest.approx(0.0, abs=1e-3)
        for ear in "LR":
            got = marker_azimuth(channels[HESUVI_INDEX[(speaker, ear)]], report["gain"])
            assert got == pytest.approx(azimuth % 360.0, abs=1e-3)
    assert max(max(abs(v) for v in c) for c in channels) == pytest.approx(0.5)
    # left loudspeakers are louder and earlier in the left ear
    _, results = checks.run_all(channels)
    assert {r.name: r.status for r in results}["routing"] == checks.PASS


def test_nearest_neighbour_and_its_error_are_reported(tmp_path):
    sofa = render_sofa.load(write_sofa(str(tmp_path / "s.sofa"), step=20))
    _, report = render_sofa.render(sofa)
    # 30 degrees is not on a 20 degree grid: 20 or 40, 10 degrees away
    assert report["directions"]["FL"]["error_deg"] == pytest.approx(10.0, abs=1e-3)
    assert report["directions"]["FC"]["error_deg"] == pytest.approx(0.0, abs=1e-3)


def test_refuses_a_set_without_a_nearby_direction(tmp_path):
    sofa = render_sofa.load(write_sofa(str(tmp_path / "s.sofa"), step=45))
    with pytest.raises(ValueError, match="no measurement within"):
        render_sofa.render(sofa)


def test_resamples_44100_to_48000(tmp_path):
    sofa = render_sofa.load(write_sofa(str(tmp_path / "s.sofa"), rate=44100.0))
    channels, report = render_sofa.render(sofa)
    assert report["source_rate"] == 44100.0
    assert len(channels[0]) == 70  # ceil(64 * 160 / 147)
    # the FC impulse at sample 20 moves to 20 * 48000 / 44100 = 21.8
    fc = channels[HESUVI_INDEX[("FC", "L")]]
    assert max(range(40), key=lambda i: abs(fc[i])) == 22


def test_data_delay_is_applied(tmp_path):
    delay = np.array([[0.0, 7.0]])
    sofa = render_sofa.load(write_sofa(str(tmp_path / "s.sofa"), delay=delay))
    channels, _ = render_sofa.render(sofa)
    left = channels[HESUVI_INDEX[("FC", "L")]]
    right = channels[HESUVI_INDEX[("FC", "R")]]
    assert max(range(40), key=lambda i: abs(left[i])) == 20
    assert max(range(40), key=lambda i: abs(right[i])) == 27


def test_command_line_writes_wav_and_json(tmp_path):
    src = write_sofa(str(tmp_path / "s.sofa"))
    out, side = str(tmp_path / "o.wav"), str(tmp_path / "o.json")
    assert render_sofa.main(["--json", side, src, out]) == 0
    rate, channels = wav.read(out)
    assert rate == 48000 and len(channels) == 14
    import json
    report = json.load(open(side))
    assert len(report["sofa_sha256"]) == 64
    assert report["attributes"]["License"].startswith("CC0-1.0")
    assert render_sofa.main([str(tmp_path / "missing.sofa"), out]) == 1
