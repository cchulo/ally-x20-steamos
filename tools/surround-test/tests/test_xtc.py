# SPDX-License-Identifier: GPL-2.0-only
import io
import math
import os

import pytest

from x20surround import checks, dsp, manifest, switcher, wav, xtc
from x20surround.layout import EARS, MIRROR, OTHER_EAR, RATE, SPEAKERS, pairs, unpairs


def hard_left():
    """A set whose side-left reaches the left ear only (like dry stereo)."""
    table = {(c, e): [0.0] * 8 for c in SPEAKERS for e in EARS}
    for c, ear in (("FL", "L"), ("FR", "R"), ("SL", "L"), ("SR", "R"), ("RL", "L"), ("RR", "R")):
        table[(c, ear)] = [1.0] + [0.0] * 7
    table[("FC", "L")] = table[("FC", "R")] = [0.7] + [0.0] * 7
    return unpairs(table)


def level(h, freq):
    return dsp.db(dsp.power_at(h, freq, RATE))


def test_strength_zero_is_a_pure_delay(channels):
    out = pairs(xtc.apply(channels, 90, 0.0))
    for key, h in pairs(channels).items():
        assert out[key][:xtc.BULK] == [0.0] * xtc.BULK
        assert out[key][xtc.BULK:xtc.BULK + len(dsp.trim_tail(h))] == dsp.trim_tail(h)


def test_only_sides_and_rears_are_processed(channels):
    out = pairs(xtc.apply(channels, 90, 0.5))
    src = pairs(channels)
    for c in ("FL", "FR", "FC"):
        for ear in EARS:
            want = dsp.delayed(dsp.trim_tail(src[(c, ear)]), xtc.BULK)
            assert out[(c, ear)][:len(want)] == want
            assert not any(out[(c, ear)][len(want):])
    for c in xtc.CHANNELS:
        assert out[(c, "L")] != dsp.delayed(src[(c, "L")], xtc.BULK)
    assert len({len(h) for h in out.values()}) == 1  # one length for the WAV


@pytest.mark.parametrize("delay_us", [60, 90, 120])
def test_cancels_the_modelled_crosstalk_inside_the_band_only(delay_us):
    strength = 0.5
    plain = xtc.at_ears(xtc.apply(hard_left(), delay_us, 0.0), delay_us, strength)
    fixed = xtc.at_ears(xtc.apply(hard_left(), delay_us, strength), delay_us, strength)
    far = ("SL", "R")  # where side-left must not be heard
    # in the band: the leak (-6 dB at strength 0.5) drops by 12 dB or more
    for f in (800.0, 1000.0, 2000.0):
        assert level(plain[far], f) == pytest.approx(-6.0, abs=1.0)
        assert level(fixed[far], f) < level(plain[far], f) - 12.0
    # the wanted ear keeps its level in the band
    assert level(fixed[("SL", "L")], 1000.0) == pytest.approx(0.0, abs=1.0)
    # outside the band the canceller does next to nothing
    for f in (60.0, 16000.0):
        assert level(xtc.apply(hard_left(), delay_us, strength)[2], f) == pytest.approx(0.0, abs=0.6)


def test_higher_order_leaves_the_wanted_ear_cleaner():
    # For a source in one ear only, the first term already empties the far
    # ear; what the truncation leaves is an error X^(order+1) at the wanted
    # ear: 0.7^2 = -6 dB at order 1, 0.7^4 = -12 dB at order 3.
    def error(order):
        fixed = xtc.at_ears(xtc.apply(hard_left(), 90, 0.7, order=order), 90, 0.7)
        wanted = dsp.impulse(1.0, 2 * xtc.BULK, 2 * xtc.BULK + 1)
        return level(dsp.add(fixed[("SL", "L")], wanted, -1.0), 1000.0)
    assert error(1) == pytest.approx(-6.2, abs=1.0)
    assert error(3) == pytest.approx(-12.4, abs=1.5)
    fixed = xtc.at_ears(xtc.apply(hard_left(), 90, 0.7, order=1), 90, 0.7)
    assert level(fixed[("SL", "R")], 1000.0) < -60.0


def test_left_right_mirror_symmetry_is_kept(channels):
    out = pairs(xtc.apply(channels, 100, 0.7))
    for c in SPEAKERS:
        for ear in EARS:
            assert out[(c, ear)] == pytest.approx(out[(MIRROR[c], OTHER_EAR[ear])], abs=1e-12)
    _, results = checks.run_all(unpairs(out))
    by = {r.name: r.status for r in results}
    assert by["routing"] == checks.PASS and by["symmetry"] == checks.PASS
    assert by["centre"] == checks.PASS


def test_kernels_split_even_and_odd_terms():
    same, cross = xtc.kernels(90, 0.5, order=1)
    assert same == dsp.impulse(1.0, xtc.BULK, xtc.BULK + 1)  # no even term at order 1
    # the odd term is negative, about -6 dB in the band and delayed by 90 us more
    assert level(cross, 1000.0) == pytest.approx(-6.0, abs=0.5)
    assert sum(cross) < 0.0 or min(cross) < -0.1
    peak = max(range(len(cross)), key=lambda i: abs(cross[i]))
    assert xtc.BULK + 3 <= peak <= xtc.BULK + 7  # 4.32 samples plus the filter's rise
    same3, _ = xtc.kernels(90, 0.5, order=3)
    assert len(same3) > len(same)


def test_rejects_bad_parameters(channels):
    with pytest.raises(ValueError):
        xtc.apply(channels, 90, 1.0)
    with pytest.raises(ValueError):
        xtc.apply(channels, -1, 0.5)


def test_sweep_and_ids():
    got = xtc.sweep()
    assert len(got) == 12 and (60, 0.3) in got and (120, 0.7) in got
    assert min(d for d, _ in got) == 60 and max(d for d, _ in got) == 120
    assert xtc.variant_id("user", 90, 0.5) == "user-xtc-d090-s50"
    assert xtc.BAND == (250.0, 5000.0) and xtc.CHANNELS == ("SL", "SR", "RL", "RR")


@pytest.fixture
def installed(tmp_path, channels):
    share = tmp_path / "share"
    (share / "hrir").mkdir(parents=True)
    path = str(share / "hrir" / "win.wav")
    wav.write(path, RATE, channels)
    data = manifest.empty()
    manifest.add(data, manifest.describe(path, "win", set="syn", licence="CC0-1.0"), str(share))
    manifest.save(str(share / "manifest.json"), data)
    return share


def test_speaker_candidates_are_recorded_for_the_speakers(installed):
    data = manifest.load(str(installed / "manifest.json"))
    made = xtc.add_speaker_candidates(data, str(installed), "win", delays=(60, 120),
                                      strengths=(0.5,))
    assert [e["id"] for e in made] == ["win-speakers", "win-xtc-d060-s50", "win-xtc-d120-s50"]
    assert all(e["device"] == "speakers" and e["licence"] == "CC0-1.0" for e in made)
    assert made[0]["file"] == "hrir/win.wav" and made[0]["form"] == "no-xtc"
    assert made[1]["xtc"] == {"delay_us": 60, "strength": 0.5, "order": 3,
                              "band_hz": [250.0, 5000.0], "channels": ["SL", "SR", "RL", "RR"]}
    assert os.path.isfile(str(installed / "hrir" / "win-xtc-d120-s50.wav"))
    # the headphone winner itself stays a headphone candidate
    assert [c["id"] for c in switcher.pick_candidates(data, "headphones")] == ["win"]
    assert len(switcher.pick_candidates(data, "speakers")) == 3
    with pytest.raises(manifest.CandidateError):
        xtc.add_speaker_candidates(data, str(installed), "nope")


def test_switcher_speakers_from(installed, tmp_path):
    env = {"HOME": str(tmp_path), "X20_SURROUND_HOME": str(installed),
           "X20_SURROUND_STATE": str(tmp_path / "state"), "XDG_RUNTIME_DIR": str(tmp_path)}
    out = io.StringIO()
    rc = switcher.main(["speakers-from", "win"], pw=object(),
                       io=switcher.IO(io.StringIO(""), out), paths=switcher.Paths(env))
    assert rc == 0, out.getvalue()
    assert "13 speaker candidate(s)" in out.getvalue()
    data = manifest.load(str(installed / "manifest.json"))
    assert len(switcher.pick_candidates(data, "speakers")) == 13
    assert math.isfinite(manifest.find(data, "win-xtc-d100-s70")["trim_db"])
