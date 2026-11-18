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
from x20surround import checks, wav  # noqa: E402
from x20surround.layout import AZIMUTH, HESUVI_INDEX  # noqa: E402


def write_sofa(path, rate=48000.0, step=5, cartesian=False, delay=None):
    """Horizontal ring every `step` degrees (plus one elevated decoy per
    direction): an impulse per ear whose position encodes the azimuth, so a
    test can tell which measurement was picked."""
    az = np.arange(0, 360, step, dtype=float)
    pos = [(a, 0.0, 1.5) for a in az] + [(a, 40.0, 1.5) for a in az]
    ir = np.zeros((len(pos), 2, 64))
    for m, (a, el, _) in enumerate(pos):
        lateral = np.sin(np.radians(a))
        for ear, toward in ((0, lateral), (1, -lateral)):
            at = int(round(20 - 10 * toward)) + (5 if el else 0)
            ir[m, ear, at] = (0.6 + 0.4 * toward) * (0.1 if el else 1.0)
            ir[m, ear, 60] = a / 3600.0  # azimuth marker, far behind the response
    with h5py.File(path, "w") as f:
        f.attrs["SOFAConventions"] = np.bytes_("SimpleFreeFieldHRIR")
        f.attrs["License"] = np.bytes_("CC0-1.0 (synthetic test data)")
        f.create_dataset("Data.IR", data=ir)
        f.create_dataset("Data.SamplingRate", data=np.array([rate]))
        f.create_dataset("Data.Delay", data=np.zeros((1, 2)) if delay is None else delay)
        p = np.array(pos)
        if cartesian:
            a, e, r = np.radians(p[:, 0]), np.radians(p[:, 1]), p[:, 2]
            p = np.stack([r * np.cos(e) * np.cos(a), r * np.cos(e) * np.sin(a), r * np.sin(e)], 1)
        d = f.create_dataset("SourcePosition", data=p)
        d.attrs["Type"] = np.bytes_("cartesian" if cartesian else "spherical")
    return path


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
