# SPDX-License-Identifier: GPL-2.0-only
"""overlay/bin/x20-surround.py: settings, the user's file, crosstalk
cancellation for the speakers and its cache, what PipeWire's state means,
the plan and the runner with its hand-over. No PipeWire needed (see
headless.py for that)."""

import importlib.util
import io
import json
import os
import re
import shutil
import struct
from contextlib import redirect_stderr, redirect_stdout

import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir))
spec = importlib.util.spec_from_file_location(
    "x20_surround", os.path.join(REPO, "overlay", "bin", "x20-surround.py"))
sur = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sur)

x = sur.dsp()                       # the x20dsp package, as the helper finds it
xdsp = sys.modules["x20dsp.dsp"]
HRIR = os.path.join(REPO, "overlay", "surround", "hrir")

HP = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Headphones__sink"
SPK = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink"


def write_wav(path, channels=14, rate=48000, frames=64, fmt="f32", value=0.25, extensible=False):
    """A WAV with an impulse of `value` in every channel at frame 0."""
    code, bits = {"f32": (3, 32), "i16": (1, 16), "i24": (1, 24), "i32": (1, 32)}[fmt]
    width = bits // 8
    one = {"f32": struct.pack("<f", value),
           "i16": int(value * 32767).to_bytes(2, "little", signed=True),
           "i24": int(value * 8388607).to_bytes(3, "little", signed=True),
           "i32": int(value * 2147483647).to_bytes(4, "little", signed=True)}[fmt]
    data = one * channels + bytes(width * channels * (frames - 1))
    body = struct.pack("<HHIIHH", 0xFFFE if extensible else code, channels, rate,
                       rate * channels * width, channels * width, bits)
    if extensible:
        body += struct.pack("<HHI", 22, bits, 0) + struct.pack("<H", code) + bytes(14)
    out = b"WAVE" + b"fmt " + struct.pack("<I", len(body)) + body
    out += b"LIST" + struct.pack("<I", 3) + b"abc\0"  # an odd-sized chunk to skip
    out += b"data" + struct.pack("<I", len(data)) + data
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(out)) + out)
    return path


@pytest.fixture
def paths(tmp_path):
    env = {"HOME": str(tmp_path), "XDG_RUNTIME_DIR": str(tmp_path / "run"),
           "X20_SURROUND_HRIR": HRIR}
    return sur.Paths(env)


@pytest.fixture(autouse=True)
def fresh_memo():
    sur._MEMO.clear()


def settings(headphones="sadie-d2-dry", speakers="sadie-d2-dry", xtc=(60, 50), plain="shown"):
    """Settings as read_settings returns them. Most tests keep the plain
    outputs shown, where "stereo" means no filter at all; the default,
    "hidden", has tests of its own."""
    return {"headphones": headphones, "speakers": speakers, "xtc": xtc, "plain": plain}


def shipped(name):
    return x.wav.read(os.path.join(HRIR, name + ".wav"))[1]


def write_set(path, channels):
    """A 14-channel file made in the test, in a directory that may be new."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    x.wav.write(path, 48000, channels)
    return path


def count_calls(monkeypatch, name):
    """Count the calls of sur.<name> without changing what it does."""
    real, calls = getattr(sur, name), []

    def counted(*args, **kw):
        calls.append(args)
        return real(*args, **kw)
    monkeypatch.setattr(sur, name, counted)
    return calls


SHOWN = {"headphones": "Headphones (Surround - SADIE D2 Dry)",
         "speakers": "Speakers (Surround - SADIE D2 Dry)"}
NODE_ID = {}


def node_id(name):
    """A stable object id per node name, as pw-dump would give."""
    return NODE_ID.setdefault(name, 100 + len(NODE_ID))


def state(plugged=False, sinks=("headphones", "speakers"), running=(), default=None):
    objs = [{"type": "PipeWire:Interface:Device",
             "info": {"props": {"device.name": "alsa_card.pci-0000_64_00.5-platform-amd_sdw"},
                      "params": {"EnumRoute": [
                          {"name": "[Out] Speaker", "available": "unknown"},
                          {"name": "[Out] Headphones", "available": "yes" if plugged else "no"}]}}},
            {"type": "PipeWire:Interface:Device",
             "info": {"props": {"device.name": "alsa_card.pci-0000_64_00.1"},
                      "params": {"EnumRoute": [{"name": "[Out] Headphones", "available": "yes"}]}}}]
    for device, name, prio in (("headphones", HP, 1000), ("speakers", SPK, 712)):
        if device in sinks:
            objs.append({"id": node_id(name), "type": "PipeWire:Interface:Node", "info": {"props": {
                "node.name": name, "media.class": "Audio/Sink", "priority.session": prio}}})
    for name in running:
        objs.append({"id": node_id(name), "type": "PipeWire:Interface:Node", "info": {"props": {
            "node.name": name, "media.class": "Audio/Sink",
            "node.description": SHOWN["headphones" if "headphones" in name else "speakers"]}}})
    if default is not None:
        objs.append({"type": "PipeWire:Interface:Metadata", "metadata": [
            {"key": "default.audio.sink", "value": {"name": default}},
            {"key": "default.audio.source", "value": {"name": "mic"}}]})
    objs.append({"type": "PipeWire:Interface:Node", "info": {"props": {
        "node.name": "bluez_output.x.HiFi__Headphones__sink", "media.class": "Audio/Sink"}}})
    return objs


def run(argv, paths):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = sur.main(argv, paths=paths)
    return rc, out.getvalue(), err.getvalue()


# -- the shipped data ---------------------------------------------------------
def test_every_builtin_profile_ships_a_valid_file_and_is_selectable(paths):
    assert set(sur.BUILTIN) | {sur.STEREO, sur.USER} == set(sur.PROFILES)
    for name, (filename, trim, _) in sur.BUILTIN.items():
        frames, _, _ = sur.check_hrir(os.path.join(paths.hrir, filename))
        assert 0 < frames <= 1024 and -12 < trim < 3
    heads = {n.rsplit("-", 1)[0] for n in sur.BUILTIN}
    assert set(sur.BUILTIN) == {h + f for h in heads for f in ("-dry", "-full")} and len(heads) == 4


def test_defaults_one_profile_for_both_outputs_and_xtc_on_the_speakers(paths):
    assert sur.DEFAULT == {"headphones": "sadie-d2-dry", "speakers": "sadie-d2-dry"}
    assert sur.DEFAULT_XTC == (60, 50) and sur.DEFAULT_XTC in sur.XTC_GRID
    assert sur.read_settings(paths.settings) == settings(plain="hidden")
    assert sur.XTC_GRID == tuple((d, s) for d in (60, 80, 100, 120) for s in (30, 50, 70))
    assert [(d, round(s * 100)) for d, s in x.xtc.sweep()] == list(sur.XTC_GRID)


def test_notice_lists_every_shipped_file_with_its_checksum():
    import hashlib
    notice = open(os.path.join(REPO, "overlay", "surround", "NOTICE.md")).read()
    names = sorted(os.listdir(HRIR))
    assert names == sorted(f for f, _, _ in sur.BUILTIN.values())
    for name in names:
        digest = hashlib.sha256(open(os.path.join(HRIR, name), "rb").read()).hexdigest()
        assert "`%s` | `%s`" % (name, digest) in notice


def test_the_dsp_package_is_found_and_is_standard_library_only():
    assert os.path.dirname(x.xtc.__file__) == os.path.join(REPO, "overlay", "surround", "x20dsp")
    for name in sorted(os.listdir(os.path.dirname(x.xtc.__file__))):
        if name.endswith(".py"):
            text = open(os.path.join(os.path.dirname(x.xtc.__file__), name)).read()
            assert "SPDX-License-Identifier: GPL-2.0-only" in text.splitlines()[0]
            assert "manifest" not in text or name == "__init__.py"
    assert not hasattr(x.xtc, "add_speaker_candidates")


# -- settings -----------------------------------------------------------------
def test_settings_default_bad_values_and_round_trip(paths):
    os.makedirs(paths.config_dir)
    with open(paths.settings, "w") as f:
        f.write("# x\nheadphones = hutubs-pp1-dry\nspeakers=nonsense\nother=stereo\n"
                "speakers_xtc = 500/50\n")
    assert sur.read_settings(paths.settings) == settings(headphones="hutubs-pp1-dry", plain="hidden")
    with open(paths.settings, "w") as f:
        f.write("speakers_xtc=off\n")
    assert sur.read_settings(paths.settings) == settings(xtc=None, plain="hidden")
    sur.write_settings(paths.settings, settings("user", "mit-kemar-dry", (120, 30)))
    assert sur.read_settings(paths.settings) == settings("user", "mit-kemar-dry", (120, 30))
    assert "plain_outputs=shown\n" in open(paths.settings).read()
    assert "speakers_xtc=120/30\n" in open(paths.settings).read()
    sur.write_settings(paths.settings, settings(xtc=None))
    assert "speakers_xtc=off\n" in open(paths.settings).read()


@pytest.mark.parametrize("text,want", [("off", None), (" OFF ", None), ("60/50", (60, 50)),
                                       ("20/5", (20, 5)), ("300/95", (300, 95))])
def test_xtc_values_that_are_accepted(text, want):
    assert sur.parse_xtc(text) == want


@pytest.mark.parametrize("text,word", [("19/50", "delay"), ("301/50", "delay"),
                                       ("60/4", "strength"), ("60/96", "strength"),
                                       ("60", "whole numbers"), ("a/b", "whole numbers"),
                                       ("60.5/50", "whole numbers"), ("on", "whole numbers")])
def test_xtc_values_that_are_refused(text, word):
    with pytest.raises(sur.Problem, match=word):
        sur.parse_xtc(text)


# -- the user's file ----------------------------------------------------------
@pytest.mark.parametrize("fmt", ["f32", "i16", "i24", "i32"])
@pytest.mark.parametrize("extensible", [False, True])
def test_wav_formats_are_read(tmp_path, fmt, extensible):
    path = write_wav(str(tmp_path / "a.wav"), fmt=fmt, extensible=extensible)
    assert sur.wav_info(path)[:4] == (14, 48000, 64, fmt)
    channels = sur.read_channels(path)
    assert len(channels) == 14 and len(channels[0]) == 64
    assert abs(channels[0][0] - 0.25) < 1e-4 and not any(channels[0][1:])


def test_calculated_trim_is_the_level_estimate_within_limits(tmp_path):
    sadie = shipped("sadie-d2-dry")
    assert sur.calculated_trim(sadie) == pytest.approx(x.level.trim_db(sadie))
    # the table value of a built-in profile is that estimate plus what was
    # measured on the device: close to it
    assert abs(sur.calculated_trim(sadie) - sur.BUILTIN["sadie-d2-dry"][1]) < 0.3
    quiet = [[v * 0.001 for v in ch] for ch in sadie]
    assert sur.calculated_trim(quiet) == sur.TRIM_RANGE[1] == 3.0
    loud = [[v * 1000.0 for v in ch] for ch in sadie]
    assert sur.calculated_trim(loud) == sur.TRIM_RANGE[0]
    with pytest.raises(sur.Problem, match="silent"):
        sur.calculated_trim([[0.0] * 8] * 14)


@pytest.mark.parametrize("kw,word", [({"channels": 2}, "2 channel"), ({"rate": 44100}, "44100 Hz"),
                                     ({"frames": 48001}, "per channel")])
def test_unusable_files_are_refused_with_a_reason(tmp_path, kw, word):
    path = write_wav(str(tmp_path / "bad.wav"), **kw)
    with pytest.raises(sur.Problem, match=word):
        sur.check_hrir(path)


def test_not_a_wav_and_a_silent_file(paths, tmp_path):
    junk = tmp_path / "junk.wav"
    junk.write_bytes(b"hello")
    with pytest.raises(sur.Problem, match="not a WAV"):
        sur.check_hrir(str(junk))
    with pytest.raises(sur.Problem, match="silent"):
        sur.user_trim_db(paths, write_wav(str(tmp_path / "s.wav"), value=0.0))


def test_user_profile_takes_the_first_wav_in_lexical_order(paths):
    assert sur.user_file(paths) is None
    write_wav(os.path.join(paths.user_dir, "b.wav"))
    first = write_wav(os.path.join(paths.user_dir, "A-first.WAV"), value=1.0)
    open(os.path.join(paths.user_dir, "0-notes.txt"), "w").close()
    assert os.path.basename(sur.user_file(paths)) == "A-first.WAV"
    profile, wav, trim, note = sur.resolve(paths, "headphones", "user")
    assert (profile, os.path.basename(wav), note) == ("user", "A-first.WAV", None)
    assert trim == pytest.approx(x.level.trim_db(sur.read_channels(first)))


def test_user_trim_is_worked_out_once_and_kept_until_the_file_changes(paths, monkeypatch):
    path = os.path.join(paths.user_dir, "mine.wav")
    os.makedirs(paths.user_dir)
    shutil.copy(os.path.join(HRIR, "sadie-d2-dry.wav"), path)
    calls = count_calls(monkeypatch, "calculated_trim")
    trim = sur.resolve(paths, "headphones", "user")[2]
    assert trim == pytest.approx(x.level.trim_db(shipped("sadie-d2-dry"))) and len(calls) == 1
    assert sur.resolve(paths, "speakers", "user")[2] == trim and len(calls) == 1   # this process
    kept = json.load(open(os.path.join(paths.cache, "user-trim.json")))
    st = os.stat(path)
    assert (kept["path"], kept["mtime_ns"], kept["size"]) == (path, st.st_mtime_ns, st.st_size)
    sur._MEMO.clear()                               # another process: from the cache directory
    assert sur.user_trim_db(paths, path) == trim and len(calls) == 1
    os.utime(path, (1, 1))                          # another modification time
    assert sur.user_trim_db(paths, path) == trim and len(calls) == 2
    x.wav.write(path, 48000, [ch[:200] for ch in shipped("sadie-d2-dry")])   # another size
    assert sur.user_trim_db(paths, path) != trim and len(calls) == 3
    sur._MEMO.clear()
    with open(os.path.join(paths.cache, "user-trim.json"), "w") as f:
        f.write("not json")                         # a damaged cache file is worked out again
    sur.user_trim_db(paths, path)
    assert len(calls) == 4
    other = os.path.join(paths.user_dir, "other.wav")   # the same content under another path
    shutil.copy(path, other)
    sur.user_trim_db(paths, other)
    assert len(calls) == 5


def test_user_profile_without_a_usable_file_falls_back_to_the_default(paths):
    profile, wav, _, note = sur.resolve(paths, "headphones", "user")
    assert profile == "sadie-d2-dry" and wav.endswith("sadie-d2-dry.wav")
    assert "no .wav file" in note and "using sadie-d2-dry" in note
    assert sur.resolve(paths, "speakers", "user")[0] == "sadie-d2-dry"
    write_wav(os.path.join(paths.user_dir, "bad.wav"), channels=2)
    profile, _, _, note = sur.resolve(paths, "headphones", "user")
    assert profile == "sadie-d2-dry" and "bad.wav: 2 channel" in note


def test_missing_shipped_file_falls_back_to_stereo(paths):
    paths.hrir = "/nonexistent"
    profile, wav, _, note = sur.resolve(paths, "headphones", "sadie-d2-dry")
    assert (profile, wav) == ("stereo", None) and "is missing" in note
    assert sur.effective(paths, "speakers", settings())[:3] == ("stereo", None, None)


# -- crosstalk cancellation: the signal processing ----------------------------
def level_at(h, freq):
    return xdsp.db(xdsp.power_at(h, freq, 48000))


def test_xtc_delays_every_channel_and_leaves_the_fronts_otherwise_untouched():
    src = x.layout.pairs(shipped("sadie-d2-dry"))
    out = x.layout.pairs(x.xtc.apply(shipped("sadie-d2-dry"), 60, 0.5))
    bulk = x.xtc.BULK
    assert len({len(h) for h in out.values()}) == 1          # one length: a valid file
    for c in ("FL", "FR", "FC"):
        for ear in "LR":
            want = xdsp.delayed(xdsp.trim_tail(src[(c, ear)]), bulk)
            assert out[(c, ear)][:len(want)] == want and not any(out[(c, ear)][len(want):])

    def peak_at(h):
        return max(range(len(h)), key=lambda i: abs(h[i]))
    for c in x.xtc.CHANNELS:                                 # sides and rears: processed,
        for ear in "LR":
            assert out[(c, ear)][:len(src[(c, ear)]) + bulk] != xdsp.delayed(src[(c, ear)], bulk)
        near = (c, x.layout.SIDE[c])                         # and later by the same bulk delay
        assert peak_at(out[near]) == peak_at(src[near]) + bulk


@pytest.mark.parametrize("delay,strength", [(60, 0.5), (120, 0.3)])
def test_xtc_reduces_the_modelled_crosstalk_at_the_ears(delay, strength):
    """Play the set over speakers that leak into the other ear as the model
    says (xtc.at_ears): with the canceller, what arrives is far closer to
    what the set asks for than without it."""
    channels = shipped("sadie-d2-dry")
    wanted = x.layout.pairs(channels)
    plain = x.xtc.at_ears(x.xtc.apply(channels, delay, 0.0), delay, strength)
    fixed = x.xtc.at_ears(x.xtc.apply(channels, delay, strength), delay, strength)
    for c in x.xtc.CHANNELS:
        for ear in "LR":
            target = xdsp.delayed(wanted[(c, ear)], 2 * x.xtc.BULK)
            for freq in (800.0, 1000.0, 2000.0):
                error_plain = level_at(xdsp.add(plain[(c, ear)], target, -1.0), freq)
                error_fixed = level_at(xdsp.add(fixed[(c, ear)], target, -1.0), freq)
                assert error_fixed < error_plain - 10.0, (c, ear, freq)


# -- crosstalk cancellation: the cache -----------------------------------------
def sadie_path():
    return os.path.join(HRIR, "sadie-d2-dry.wav")


def test_variant_is_generated_once_then_served_from_the_cache(paths, monkeypatch):
    made = count_calls(monkeypatch, "make_variant")
    assert sur.cached_variant(paths, sadie_path(), (60, 50)) is None            # a miss
    assert sur.variant(paths, sadie_path(), (60, 50), generate=False) is None and not made
    meta = sur.variant(paths, sadie_path(), (60, 50))
    assert len(made) == 1 and meta["status"] in ("PASS", "WARN")
    digest = "abbfc8cb54b5294bfabda3d6ea5d2aaa695d2b0035c6e54c1e08f7a730e836e3"
    assert meta["wav"] == os.path.join(paths.cache, digest[:16] + "-d060-s50.wav")
    side = json.load(open(meta["wav"][:-4] + ".json"))
    assert (side["source_sha256"], side["delay_us"], side["strength_pct"]) == (digest, 60, 50)
    assert side["wav_bytes"] == os.path.getsize(meta["wav"]) and side["version"] == 1
    # the file is what x20dsp.xtc.apply gives, as 32-bit float, and its trim
    # is x20dsp.level.trim_db of it
    want = x.xtc.apply(shipped("sadie-d2-dry"), 60, 0.5)
    got = sur.read_channels(meta["wav"])
    assert len(got) == 14 and len(got[0]) == len(want[0]) == side["frames"]
    assert max(abs(a - b) for a, b in zip(got[4], want[4])) < 1e-6
    assert meta["trim_db"] == round(x.level.trim_db(want), 2) == -1.6
    for _ in range(3):                                                          # hits
        assert sur.variant(paths, sadie_path(), (60, 50))["wav"] == meta["wav"]
    sur._MEMO.clear()                                                           # another process
    assert sur.variant(paths, sadie_path(), (60, 50))["trim_db"] == meta["trim_db"]
    assert len(made) == 1
    assert not [n for n in os.listdir(paths.cache) if n.endswith(".tmp")]


def test_cache_key_is_the_content_the_delay_and_the_strength(paths, monkeypatch):
    made = count_calls(monkeypatch, "make_variant")
    a = sur.variant(paths, sadie_path(), (60, 50))["wav"]
    b = sur.variant(paths, sadie_path(), (80, 50))["wav"]
    c = sur.variant(paths, sadie_path(), (60, 30))["wav"]
    assert len({a, b, c}) == 3 and len(made) == 3
    copy = os.path.join(paths.user_dir, "copy.wav")      # the same content elsewhere: a hit
    os.makedirs(paths.user_dir)
    shutil.copy(sadie_path(), copy)
    assert sur.variant(paths, copy, (60, 50))["wav"] == a and len(made) == 3
    x.wav.write(copy, 48000, [ch[:200] for ch in shipped("sadie-d2-dry")])   # other content
    assert sur.variant(paths, copy, (60, 50))["wav"] != a and len(made) == 4


@pytest.mark.parametrize("damage", ["wav gone", "wav truncated", "sidecar gone", "sidecar junk",
                                    "older version", "other strength recorded"])
def test_an_invalid_cache_entry_is_generated_again(paths, monkeypatch, damage):
    made = count_calls(monkeypatch, "make_variant")
    meta = sur.variant(paths, sadie_path(), (60, 50))
    wav, side = meta["wav"], meta["wav"][:-4] + ".json"
    size = os.path.getsize(wav)
    if damage == "wav gone":
        os.remove(wav)
    elif damage == "wav truncated":
        with open(wav, "r+b") as f:
            f.truncate(size // 2)
    elif damage == "sidecar gone":
        os.remove(side)
    elif damage == "sidecar junk":
        with open(side, "w") as f:
            f.write("{")
    else:
        data = json.load(open(side))
        data.update({"version": 0} if damage == "older version" else {"strength_pct": 30})
        with open(side, "w") as f:
            json.dump(data, f)
    assert sur.cached_variant(paths, sadie_path(), (60, 50)) is None
    again = sur.variant(paths, sadie_path(), (60, 50))
    assert len(made) == 2 and os.path.getsize(again["wav"]) == size
    assert sur.cached_variant(paths, sadie_path(), (60, 50))["trim_db"] == meta["trim_db"]


def test_a_failed_generation_is_not_repeated_by_the_same_process(paths, monkeypatch):
    calls = []

    def broken(*args):
        calls.append(args)
        raise OSError("disk full")
    monkeypatch.setattr(sur, "make_variant", broken)
    for _ in range(3):
        use = sur.effective(paths, "speakers", settings())
        assert use.xtc is None and use.wav == sadie_path() and use.trim == -1.10
        assert "could not be generated (disk full)" in use.note
        assert "playing sadie-d2-dry without it" in use.note
    assert len(calls) == 1


# -- crosstalk cancellation: what an output plays -------------------------------
def test_speakers_play_the_generated_variant_headphones_never_do(paths):
    use = sur.effective(paths, "speakers", settings())
    assert (use.profile, use.source, use.xtc, use.note) == ("sadie-d2-dry", sadie_path(),
                                                           (60, 50), None)
    assert use.wav.startswith(paths.cache) and use.wav.endswith("-d060-s50.wav")
    assert use.trim == -1.6 and not use.pending
    phones = sur.effective(paths, "headphones", settings())
    assert (phones.wav, phones.trim, phones.xtc) == (sadie_path(), -1.10, None)
    off = sur.effective(paths, "speakers", settings(xtc=None))
    assert (off.wav, off.trim, off.xtc, off.note) == (sadie_path(), -1.10, None, None)
    assert sur.effective(paths, "speakers", settings(speakers="stereo"))[:3] == ("stereo", None,
                                                                                None)
    # the user's file gets it too; without a file, the fall-back does
    assert sur.effective(paths, "speakers", settings(speakers="user")).xtc == (60, 50)
    path = os.path.join(paths.user_dir, "mine.wav")
    write_set(path, [ch[:200] for ch in shipped("hutubs-pp1-dry")])
    use = sur.effective(paths, "speakers", settings(speakers="user", xtc=(100, 30)))
    assert (use.profile, use.source, use.xtc) == ("user", path, (100, 30))
    assert use.wav.endswith("-d100-s30.wav")
    assert use.trim == pytest.approx(x.level.trim_db(sur.read_channels(use.wav)), abs=0.006)


def test_without_generate_a_missing_variant_is_reported_as_pending(paths, monkeypatch):
    made = count_calls(monkeypatch, "make_variant")
    use = sur.effective(paths, "speakers", settings(), generate=False)
    assert use.pending and (use.wav, use.xtc, use.note) == (sadie_path(), None, None) and not made
    sur.effective(paths, "speakers", settings())
    use = sur.effective(paths, "speakers", settings(), generate=False)
    assert not use.pending and use.xtc == (60, 50) and len(made) == 1


def test_a_variant_that_fails_the_routing_check_is_not_used(paths, monkeypatch):
    """The real case: mit-kemar-dry with 60 us / 70 %. The rear channels
    would be less than 1 dB louder in the ear on their own side."""
    made = count_calls(monkeypatch, "make_variant")
    chosen = settings(speakers="mit-kemar-dry", xtc=(60, 70))
    mit = os.path.join(HRIR, "mit-kemar-dry.wav")
    for _ in range(2):
        use = sur.effective(paths, "speakers", chosen)
        assert (use.profile, use.wav, use.trim, use.xtc) == ("mit-kemar-dry", mit, -5.03, None)
        assert "crosstalk cancellation 60 us / 70 % is not usable with mit-kemar-dry" in use.note
        assert "routing check" in use.note and "0.9 dB" in use.note
        assert "playing mit-kemar-dry without it" in use.note
    assert len(made) == 1                              # the verdict is cached, not redone
    cached = sorted(os.listdir(paths.cache))
    assert cached == ["0fd292d7061f5861-d060-s70.json"]   # no file that must not be played
    assert json.load(open(os.path.join(paths.cache, cached[0])))["status"] == "FAIL"
    # the same head with the default setting is fine
    assert sur.effective(paths, "speakers", settings(speakers="mit-kemar-dry")).xtc == (60, 50)
    want, note = sur.plan(paths, sur.look(state(plugged=False)))
    assert want is not None and note is None


def test_a_variant_that_fails_the_symmetry_check_is_not_used(paths):
    """A user's file whose right side channel is 18 dB louder than the
    left one: its variant fails the symmetry check."""
    channels = shipped("sadie-d2-dry")
    lopsided = x.layout.pairs(channels)
    for ear in "LR":
        lopsided[("SR", ear)] = [v * 8.0 for v in lopsided[("SR", ear)]]
    path = os.path.join(paths.user_dir, "lopsided.wav")
    write_set(path, x.layout.unpairs(lopsided))
    made = x.layout.pairs(x.xtc.apply(x.layout.unpairs(lopsided), 60, 0.5))
    assert x.checks.check_symmetry(made).status == "FAIL"
    assert x.checks.check_routing(made).status == "PASS"
    use = sur.effective(paths, "speakers", settings(speakers="user"))
    assert (use.profile, use.wav, use.xtc) == ("user", path, None)
    assert "is not usable with user (symmetry check: largest mean band difference" in use.note
    assert use.trim == sur.user_trim_db(paths, path)
    assert sur.effective(paths, "headphones", settings(headphones="user")).note is None


# -- PipeWire's state ---------------------------------------------------------
def test_look_finds_the_internal_sinks_and_the_jack():
    seen = sur.look(state(plugged=True, running=("ally_x20_surround_headphones_a",
                                                 "ally_x20_surround_speakers_b",
                                                 "ally_x20_surround_headphones")))
    assert seen["sinks"] == {"headphones": (HP, 1000), "speakers": (SPK, 712)}
    assert seen["headphones_plugged"]
    assert seen["running"] == {"ally_x20_surround_headphones_a", "ally_x20_surround_speakers_b"}
    # another card's "Headphones" route and a Bluetooth sink do not count
    assert not sur.look(state(plugged=False))["headphones_plugged"]
    assert sur.look([]) == {"sinks": {}, "headphones_plugged": False, "running": set(),
                            "ids": {}, "default": None, "shown": {}, "clients": {}}


def test_look_knows_our_sinks_by_their_id_property_and_translates_the_default():
    shown = "Speakers (Surround - SADIE D2 Dry)"
    objs = state(plugged=False) + [
        {"id": 100, "type": "PipeWire:Interface:Node", "info": {"props": {
            "node.name": shown, "node.description": shown, "media.class": "Audio/Sink",
            sur.ID_PROP: SA}}},
        {"id": 101, "type": "PipeWire:Interface:Node", "info": {"props": {
            "node.name": shown + " ", "node.description": shown, "media.class": "Audio/Sink",
            sur.ID_PROP: SB}}},
        # somebody else's sink that merely has a similar name
        {"id": 102, "type": "PipeWire:Interface:Node", "info": {"props": {
            "node.name": "Speakers (Surround - Other)", "media.class": "Audio/Sink"}}},
        {"type": "PipeWire:Interface:Metadata", "metadata": [
            {"key": "default.audio.sink", "value": {"name": shown + " "}}]}]
    seen = sur.look(objs)
    assert seen["running"] == {SA, SB}
    assert seen["ids"][SA] == 100 and seen["ids"][SB] == 101
    assert seen["shown"] == {SA: shown, SB: shown}
    assert seen["default"] == SB                 # reported by name, known by id
    assert sur.display_name("speakers", "sadie-d2-dry", SA) == shown
    assert sur.display_name("speakers", "sadie-d2-dry", SB) == shown + " "


def test_active_device_follows_the_jack():
    assert sur.active_device(sur.look(state(plugged=True))) == "headphones"
    assert sur.active_device(sur.look(state(plugged=False))) == "speakers"
    assert sur.active_device(sur.look(state(plugged=True, sinks=("speakers",)))) == "speakers"
    assert sur.active_device(sur.look(state(sinks=()))) is None


def test_plan_follows_the_jack_the_profiles_and_the_xtc_setting(paths):
    want, note = sur.plan(paths, sur.look(state(plugged=True)))
    assert want[:2] == ("headphones", "sadie-d2-dry") and want[2] == sadie_path()
    assert want[3:6] == (-1.10, HP, 1000) and want[7] is None and note is None
    want, note = sur.plan(paths, sur.look(state(plugged=False)))      # the default speakers
    assert want[:2] == ("speakers", "sadie-d2-dry") and want[2].endswith("-d060-s50.wav")
    assert want[3:6] == (-1.6, SPK, 712) and want[7] == (60, 50) and note is None
    sur.write_settings(paths.settings, settings("stereo", "mit-kemar-dry", None))
    assert sur.plan(paths, sur.look(state(plugged=True)))[0] is None
    want, _ = sur.plan(paths, sur.look(state(plugged=False)))
    assert want[:2] == ("speakers", "mit-kemar-dry") and want[3:6] == (-5.03, SPK, 712)
    assert want[2] == os.path.join(HRIR, "mit-kemar-dry.wav") and want[7] is None
    sur.write_settings(paths.settings, settings("stereo", "stereo"))
    assert sur.plan(paths, sur.look(state(plugged=False))) == (None, None)
    assert sur.plan(paths, sur.look(state(sinks=()))) == (None, None)


# -- the config ---------------------------------------------------------------
def test_render_is_a_71_sink_pinned_to_the_target(paths):
    wav = os.path.join(paths.hrir, "sadie-d2-dry.wav")
    text = sur.render("headphones", "sadie-d2-dry", wav, HP, -1.10, 1001)
    assert text.count("label = convolver") == 16
    assert 'filename = "%s" channel = 13' % wav in text
    assert "audio.channels   = 8" in text and "audio.position   = [ FL FR FC LFE RL RR SL SR ]" in text
    # node.name is what Steam shows; the helper's own id rides in a property
    assert 'node.name        = "Headphones (Surround - SADIE D2 Dry)"' in text
    assert 'ally-x20-steamos.surround.id = "ally_x20_surround_headphones_a"' in text
    assert 'node.name          = "ally_x20_surround_headphones_a.output"' in text
    assert "priority.session = 1001" in text
    assert 'target.object      = "%s"' % HP in text
    assert "node.dont-fallback = true" in text and "node.linger        = true" in text
    assert '"Gain 1" = %.6f' % 10 ** (-1.10 / 20) in text      # the trim
    assert '"Gain 8" = %.6f' % (0.5 * 10 ** (-1.10 / 20)) in text  # the LFE at half
    assert '"Min" = -0.8910 "Max" = 0.8910' in text
    other = sur.render("speakers", "sadie-d2-dry", wav, SPK, 0.0, 714,
                       sur.node_name("speakers", 1))
    # the second slot: the same text plus a trailing space, so that two sinks
    # of one output never share a name while both exist
    assert 'node.name        = "Speakers (Surround - SADIE D2 Dry) "' in other
    assert 'node.description = "Speakers (Surround - SADIE D2 Dry)"' in other
    assert 'ally-x20-steamos.surround.id = "ally_x20_surround_speakers_b"' in other
    assert 'node.name          = "ally_x20_surround_speakers_b.output"' in other
    assert text.count("ally_x20_surround") == other.count("ally_x20_surround") == 2
    with pytest.raises(sur.Problem):
        sur.render("headphones", "x", '/a"b.wav', HP, 0.0, 1)


# -- the runner ---------------------------------------------------------------
class FakeProc:
    def __init__(self, world, node):
        self.world, self.node, self.code = world, node, None

    def poll(self):
        return self.code

    def terminate(self):
        self.world.events.append("stop " + self.node)
        self.code = 0

    def wait(self, timeout=None):
        return self.code

    def kill(self):
        self.code = -9


class World:
    """A PipeWire that shows a sink for every filter process alive, unless
    its name is in `hidden`; `stillborn` makes the next process end at once."""

    def __init__(self, plugged=True):
        self.plugged = plugged
        self.gone = False
        self.default = None     # node.name of the default sink, when a test sets it
        self.volumes = {}       # object id -> [volume, muted]
        self.volume_log = []    # ("set", name, value) in the order written
        self.hidden = set()
        self.stillborn = False
        self.spawned = []       # (config text, process)
        self.events = []        # "start <node>", "stop <node>", "sleep"
        self.slept = 0.0

    def running(self):
        return [p.node for _, p in self.spawned if p.code is None and p.node not in self.hidden]

    def dump(self):
        return None if self.gone else state(plugged=self.plugged, running=self.running(),
                                            default=self.default)

    # the wpctl side: volumes by object id
    def get(self, ident):
        got = self.volumes.get(ident)
        return (got[0], got[1]) if got else None

    def set(self, ident, volume):
        self.volumes.setdefault(ident, [1.0, False])[0] = round(float(volume), 4)
        name = next((n for n, i in NODE_ID.items() if i == ident), ident)
        self.volume_log.append(("set", name, round(float(volume), 4)))
        self.events.append("vol %s %.2f" % (name, float(volume)))
        return True

    def mute(self, ident, muted):
        self.volumes.setdefault(ident, [1.0, False])[1] = bool(muted)
        return True

    def vol(self, name):
        return self.volumes.get(node_id(name), [None, None])[0]

    def spawn(self, conf_path):
        text = open(conf_path).read()
        node = re.search(r'ally-x20-steamos\.surround\.id = "(\S+)"', text).group(1)
        assert os.path.basename(conf_path) == "%s-%s.conf" % (
            "headphones" if "headphones" in node else "speakers", node[-1])
        proc = FakeProc(self, node)
        if self.stillborn:
            proc.code, self.stillborn = 1, False
        self.spawned.append((text, proc))
        self.events.append("start " + node)
        return proc

    def sleep(self, seconds):
        self.slept += seconds
        if self.events[-1:] != ["sleep"]:
            self.events.append("sleep")

    def runner(self, paths):
        return sur.Runner(paths, spawn=self.spawn, dump=self.dump, sleep=self.sleep, vol=self)

    def alive(self):
        return [p.node for _, p in self.spawned if p.code is None]


HA, HB = "ally_x20_surround_headphones_a", "ally_x20_surround_headphones_b"
SA, SB = "ally_x20_surround_speakers_a", "ally_x20_surround_speakers_b"


def test_runner_starts_follows_the_jack_and_the_setting_and_stops(paths):
    world = World()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        assert runner.step(now=0)[:2] == ("headphones", "sadie-d2-dry")
        assert len(world.spawned) == 1 and "sadie-d2-dry.wav" in world.spawned[0][0]
        runner.step(now=2)
        assert len(world.spawned) == 1  # nothing changed: nothing restarted
        assert world.slept == 0         # and no waiting outside a hand-over

        sur.write_settings(paths.settings, settings("hutubs-pp1-dry", "stereo"))
        runner.step(now=4)
        assert "hutubs-pp1-dry.wav" in world.spawned[1][0] and world.alive() == [HB]

        world.plugged = False  # unplugged: speakers, which are stereo here
        assert runner.step(now=6) is None
        assert world.alive() == [] and len(world.spawned) == 2

        sur.write_settings(paths.settings, settings("hutubs-pp1-dry", "mit-kemar-dry", None))
        assert runner.step(now=8)[0] == "speakers"
        assert "target.object      = \"%s\"" % SPK in world.spawned[2][0]

        world.gone = True  # PipeWire went away
        assert runner.step(now=10) is None and world.alive() == []
        world.gone = False
        runner.step(now=12)
        assert len(world.spawned) == 4 and len(world.alive()) == 1
        runner.stop()
        assert world.alive() == []


def test_a_profile_change_starts_the_new_filter_before_it_stops_the_old_one(paths):
    world = World()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()) as log:
        runner.step(now=0)
        assert world.events == ["start " + HA]
        assert "priority.session = 1001" in world.spawned[0][0]

        sur.write_settings(paths.settings, settings("hutubs-pp1-dry"))
        want = runner.step(now=2)
        # new one under the other name and above the old one's priority,
        # a look at PipeWire until its sink is there, a pause, then the old one
        assert world.events == ["start " + HA, "start " + HB, "sleep", "stop " + HA]
        assert "priority.session = 1002" in world.spawned[1][0]
        assert "hutubs-pp1-dry.wav" in world.spawned[1][0]
        assert world.slept == pytest.approx(sur.HANDOVER_POLL + sur.HANDOVER_SETTLE)
        assert world.alive() == [HB] and want[1] == "hutubs-pp1-dry" and runner.want == want
        runner.step(now=4)
        assert len(world.spawned) == 2                 # settled

        sur.write_settings(paths.settings, settings("mit-kemar-full"))
        runner.step(now=6)                             # and back to the first name: no creep
        assert world.events[-3:] == ["start " + HA, "sleep", "stop " + HB]
        assert "priority.session = 1001" in world.spawned[2][0] and world.alive() == [HA]
        runner.step(now=8)
        assert len(world.spawned) == 3
    assert "as ally_x20_surround_headphones_b" in log.getvalue()


def test_an_xtc_change_and_a_jack_change_hand_over_too(paths):
    world = World(plugged=False)
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()) as log:
        runner.step(now=0)
        assert world.events == ["start " + SA] and "-d060-s50.wav" in world.spawned[0][0]
        assert "priority.session = 713" in world.spawned[0][0]

        sur.write_settings(paths.settings, settings(xtc=(100, 30)))
        runner.step(now=2)
        assert world.events[-3:] == ["start " + SB, "sleep", "stop " + SA]
        assert "-d100-s30.wav" in world.spawned[1][0]
        assert "priority.session = 714" in world.spawned[1][0]

        sur.write_settings(paths.settings, settings(xtc=None))
        runner.step(now=4)
        assert world.events[-3:] == ["start " + SA, "sleep", "stop " + SB]
        assert 'filename = "%s"' % sadie_path() in world.spawned[2][0]

        world.plugged = True                           # headphones in: another target
        runner.step(now=6)
        assert world.events[-3:] == ["start " + HB, "sleep", "stop " + SA]
        assert "target.object      = \"%s\"" % HP in world.spawned[3][0]
        assert "priority.session = 1002" in world.spawned[3][0] and world.alive() == [HB]

        world.plugged = False                          # and out again
        runner.step(now=8)
        assert world.events[-3:] == ["start " + SA, "sleep", "stop " + HB]
        assert world.alive() == [SA] and len(world.spawned) == 5
    assert "sadie-d2-dry + xtc 100 us / 30 %" in log.getvalue()


def test_the_runner_generates_a_variant_while_the_old_filter_keeps_running(paths, monkeypatch):
    world = World(plugged=False)
    runner = world.runner(paths)
    alive_while_generating = []
    real = sur.make_variant

    def watched(*args):
        alive_while_generating.append(world.alive())
        return real(*args)
    monkeypatch.setattr(sur, "make_variant", watched)
    with redirect_stderr(io.StringIO()) as log:
        runner.step(now=0)
        sur.write_settings(paths.settings, settings(xtc=(80, 50)))
        runner.step(now=2)
    assert alive_while_generating == [[], [SA]] and world.alive() == [SB]
    assert "generating the speaker variant 80 us / 50 % of sadie-d2-dry.wav" in log.getvalue()


def test_an_unusable_variant_plays_the_profile_and_the_journal_says_why(paths):
    world = World(plugged=False)
    sur.write_settings(paths.settings, settings(speakers="mit-kemar-dry", xtc=(60, 70)))
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()) as log:
        want = runner.step(now=0)
        runner.step(now=2)
    assert want[2] == os.path.join(HRIR, "mit-kemar-dry.wav") and want[7] is None
    assert len(world.spawned) == 1 and '"Gain 1" = %.6f' % 10 ** (-5.03 / 20) in world.spawned[0][0]
    assert log.getvalue().count("is not usable with mit-kemar-dry") == 1


@pytest.mark.parametrize("trouble", ["the sink never appears", "the process ends at once",
                                     "PipeWire stops answering"])
def test_a_hand_over_that_fails_falls_back_to_replacing_the_filter(paths, trouble):
    world = World()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()) as log:
        runner.step(now=0)
        sur.write_settings(paths.settings, settings("hutubs-pp1-dry"))
        if trouble == "the sink never appears":
            world.hidden = {HB}
        elif trouble == "the process ends at once":
            world.stillborn = True
        else:
            answers = iter([world.dump])    # the step's own look works, the next one does not
            runner.dump = lambda: next(answers, lambda: None)()
        want = runner.step(now=2)
    # the attempt under the other name is given up, then the old way: stop, start
    assert world.events[:2] == ["start " + HA, "start " + HB]
    assert world.events[-2:] == ["stop " + HA, "start " + HA]
    assert world.alive() == [HA] and "hutubs-pp1-dry.wav" in world.spawned[2][0]
    assert "priority.session = 1001" in world.spawned[2][0]
    assert runner.want == want and want[1] == "hutubs-pp1-dry"
    assert "did not appear" in log.getvalue()
    assert "stop " + HB in world.events or trouble == "the process ends at once"
    if trouble == "the sink never appears":
        assert world.slept == pytest.approx(sur.HANDOVER_TIMEOUT)


# -- volume: the hardware sink is held at 100 % under a filter ----------------
def volume_world(plugged=False, speakers=0.55, headphones=0.30):
    world = World(plugged=plugged)
    world.volumes[node_id(SPK)] = [speakers, False]
    world.volumes[node_id(HP)] = [headphones, False]
    return world


def held(paths):
    return sur.read_volume_state(paths.volume_state)


def test_the_surround_sink_takes_the_volume_and_the_hardware_sink_goes_to_full(paths):
    world = volume_world()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()) as log:
        runner.step(now=0)                       # the filter starts; its sink is not there yet
        assert world.volume_log == []
        runner.step(now=2)                       # now it is: the volume moves
    # the surround sink first (quiet), then the hardware sink up: never louder
    assert world.volume_log == [("set", SA, 0.55), ("set", SPK, 1.0)]
    assert world.vol(SA) == 0.55 and world.vol(SPK) == 1.0
    assert held(paths) == {SPK: {"held": True, "volume": 0.55, "muted": False}}
    assert "volume 0.55 moved to the surround sink" in log.getvalue()
    with redirect_stderr(io.StringIO()):
        runner.step(now=4)
    assert len(world.volume_log) == 2            # settled: nothing is written again


def test_a_muted_output_stays_muted_under_the_filter(paths):
    world = volume_world()
    world.volumes[node_id(SPK)] = [0.4, True]
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        runner.step(now=2)
    assert world.volumes[node_id(SA)] == [0.4, True]
    assert world.volumes[node_id(SPK)] == [1.0, False]
    assert held(paths)[SPK]["muted"] is True


def test_the_volume_set_with_the_keys_follows_a_profile_switch(paths):
    world = volume_world()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        runner.step(now=2)
        world.volumes[node_id(SA)][0] = 0.70     # the volume keys move the default sink
        runner.step(now=4)
        assert held(paths)[SPK]["volume"] == 0.70   # remembered
        sur.write_settings(paths.settings, settings(xtc=(100, 30)))
        runner.step(now=6)                       # hand-over to the other sink name
    assert world.alive() == [SB]
    assert world.vol(SB) == 0.70 and world.vol(SPK) == 1.0
    # the new sink has the volume before the old one stops
    assert world.events.index("vol %s 0.70" % SB) < world.events.index("stop " + SA)


def test_stopping_the_filter_gives_the_volume_back_first(paths):
    world = volume_world()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()) as log:
        runner.step(now=0)
        runner.step(now=2)
        world.volumes[node_id(SA)][0] = 0.62
        sur.write_settings(paths.settings, settings(speakers="stereo"))
        assert runner.step(now=4) is None
    assert world.alive() == [] and world.vol(SPK) == 0.62
    # the hardware sink comes down from 100 % before the filter goes
    assert world.events.index("vol %s 0.62" % SPK) < world.events.index("stop " + SA)
    assert held(paths)[SPK] == {"held": False, "volume": 0.62, "muted": False}
    assert "volume 0.62 back on" in log.getvalue()


def test_runner_stop_gives_the_volume_back(paths):
    world = volume_world()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        runner.step(now=2)
        runner.stop()                            # the service is stopped
    assert world.vol(SPK) == 0.55 and world.alive() == []
    assert held(paths)[SPK]["held"] is False


def test_a_filter_that_died_does_not_leave_the_hardware_sink_at_full(paths):
    world = volume_world()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        runner.step(now=2)
        world.spawned[0][1].code = 1             # the filter process is gone
        sur.write_settings(paths.settings, settings(speakers="stereo"))
        runner.step(now=4)
    assert world.vol(SPK) == 0.55                # from what was remembered


def test_the_jack_moves_the_volume_per_output(paths):
    world = volume_world()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        runner.step(now=2)
        world.volumes[node_id(SA)][0] = 0.80
        world.plugged = True                     # headphones in
        runner.step(now=4)
    assert world.alive() == [HB]
    assert world.vol(SPK) == 0.80                # the speakers got theirs back
    assert world.vol(HB) == 0.30 and world.vol(HP) == 1.0   # the headphones' own volume
    state_now = held(paths)
    assert state_now[SPK]["held"] is False and state_now[HP] == {
        "held": True, "volume": 0.30, "muted": False}
    # nothing was ever written louder than the user had it, except the held sinks
    for _, name, value in world.volume_log:
        assert value <= 0.80 or name in (SPK, HP)


def test_a_hardware_sink_left_at_full_gets_its_volume_back_before_a_filter_starts(paths):
    # the service was killed (or the machine went down) while it held the speakers
    sur.write_volume_state(paths.volume_state,
                           {SPK: {"held": True, "volume": 0.40, "muted": False}})
    world = volume_world(speakers=1.0)
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
    assert world.events[0] == "vol %s 0.40" % SPK and world.events[1] == "start " + SA
    with redirect_stderr(io.StringIO()):
        runner.step(now=2)
    assert world.vol(SA) == 0.40 and world.vol(SPK) == 1.0


def test_the_plain_output_picked_by_hand_is_not_left_at_full(paths):
    world = volume_world()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        runner.step(now=2)
        world.volumes[node_id(SA)][0] = 0.50
        world.default = SPK                      # chosen in Steam: the plain speakers
        runner.step(now=4)
        assert world.vol(SPK) == 0.50 and world.alive() == [SA]
        runner.step(now=6)
        assert world.vol(SPK) == 0.50            # and it is left alone while that lasts
        world.default = SA                       # back on the surround sink
        runner.step(now=8)
    assert world.vol(SPK) == 1.0 and world.vol(SA) == 0.50


def test_without_wpctl_nothing_is_changed(paths):
    world = World(plugged=False)                 # no volume can be read
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        runner.step(now=2)
        runner.stop()
    assert world.volume_log == [] and held(paths) == {}


def test_volume_state_file_tolerates_junk(paths):
    os.makedirs(os.path.dirname(paths.volume_state), exist_ok=True)
    with open(paths.volume_state, "w") as f:
        f.write("{not json")
    assert sur.read_volume_state(paths.volume_state) == {}
    with open(paths.volume_state, "w") as f:
        f.write('{"a": {"held": 1, "volume": 7}, "b": "x", "c": {"volume": "loud"}}')
    assert sur.read_volume_state(paths.volume_state) == {
        "a": {"held": True, "volume": 1.0, "muted": False}}


def test_wpctl_output_is_parsed(monkeypatch):
    answers = {"get-volume": "Volume: 0.55\n"}
    monkeypatch.setattr(sur.Volumes, "_run", staticmethod(lambda argv: answers.get(argv[1])))
    assert sur.Volumes().get(56) == (0.55, False)
    answers["get-volume"] = "Volume: 0.30 [MUTED]\n"
    assert sur.Volumes().get(56) == (0.30, True)
    answers["get-volume"] = "nonsense"
    assert sur.Volumes().get(56) is None
    assert sur.Volumes().set(56, 2.0) is False   # the stub knows no set-volume


# -- the plain outputs are hidden; stereo is a sink of its own ----------------
class FakePerms:
    def __init__(self):
        self.calls = []

    def set(self, client, node, perms):
        self.calls.append((client, node, perms))
        return True


def clients_world(plugged=False):
    """A world with other programs connected: Steam (through the pulse
    server), a game, WirePlumber and one of PipeWire's own processes."""
    world = volume_world(plugged=plugged)
    world.clients = {
        31: {"application.name": "WirePlumber", "wireplumber.daemon": True,
             "application.process.binary": "wireplumber"},
        99: {"application.name": "pipewire", "application.process.binary": "pipewire"},
        135: {"application.name": "Steam", "application.process.binary": "steam",
              "client.api": "pipewire-pulse"},
        140: {"application.name": "Some Game", "application.process.binary": "game.exe"},
        150: {"application.name": "pw-dump", "application.process.binary": "pw-dump"},
    }
    real = world.dump

    def dump():
        objects = real()
        if objects is not None:
            objects = objects + [{"id": ident, "type": "PipeWire:Interface:Client",
                                  "info": {"props": props}}
                                 for ident, props in world.clients.items()]
        return objects
    world.perms = FakePerms()
    world.runner = lambda paths: sur.Runner(paths, spawn=world.spawn, dump=dump,
                                            sleep=world.sleep, vol=world, perms=world.perms)
    return world


def test_the_plain_outputs_are_hidden_from_other_programs_only(paths):
    world = clients_world()                      # the default: plain outputs hidden
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        assert world.perms.calls == []           # our sink is not there yet: nothing to list
        runner.step(now=2)
    spk, hp = node_id(SPK), node_id(HP)
    # Steam and the game lose both plain sinks; WirePlumber, PipeWire's own
    # processes (our filter) and the pw-* tools keep them
    assert sorted(world.perms.calls) == sorted(
        [(135, spk, "-"), (135, hp, "-"), (140, spk, "-"), (140, hp, "-")])
    with redirect_stderr(io.StringIO()):
        runner.step(now=4)
        assert len(world.perms.calls) == 4       # once per program, not on every look
        world.clients[160] = {"application.name": "Late", "application.process.binary": "late"}
        runner.step(now=6)                       # a program that starts later
    assert sorted(world.perms.calls[4:]) == [(160, hp, "-"), (160, spk, "-")]


def test_stopping_gives_the_plain_outputs_back(paths):
    world = clients_world()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        runner.step(now=2)
        runner.stop()
    spk, hp = node_id(SPK), node_id(HP)
    assert sorted(world.perms.calls[4:]) == sorted(
        [(135, spk, "rwxm"), (135, hp, "rwxm"), (140, spk, "rwxm"), (140, hp, "rwxm")])
    assert runner.hidden == set()


def test_plain_shown_hides_nothing_and_gives_back_what_was_hidden(paths):
    world = clients_world()
    sur.write_settings(paths.settings, settings(plain="shown"))
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        runner.step(now=2)
        assert world.perms.calls == []
        sur.write_settings(paths.settings, settings(plain="hidden"))
        runner.step(now=4)
        assert len(world.perms.calls) == 4
        sur.write_settings(paths.settings, settings(plain="shown"))
        runner.step(now=6)
    assert [c[2] for c in world.perms.calls[4:]] == ["rwxm"] * 4


def test_stereo_is_a_pass_through_sink_while_the_plain_outputs_are_hidden(paths):
    world = clients_world()
    sur.write_settings(paths.settings, settings(speakers="stereo", plain="hidden"))
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()) as log:
        want = runner.step(now=0)
        runner.step(now=2)
    assert want[:3] == ("speakers", "stereo", None)
    text = world.spawned[0][0]
    assert 'node.name        = "Speakers (Stereo)"' in text
    assert "audio.channels   = 2" in text and "label = convolver" not in text
    assert text.count("label = copy") == 2
    assert 'target.object      = "%s"' % SPK in text and "priority.session = 713" in text
    assert "stereo (pass-through)" in log.getvalue()
    # it takes the volume and hides the plain sink like any other profile
    assert world.vol(SA) == 0.55 and world.vol(SPK) == 1.0
    assert (135, node_id(SPK), "-") in world.perms.calls
    # and a switch to a surround profile hands over as usual
    sur.write_settings(paths.settings, settings(speakers="sadie-d2-dry", xtc=None,
                                                plain="hidden"))
    with redirect_stderr(io.StringIO()):
        runner.step(now=4)
    assert world.alive() == [SB] and "audio.channels   = 8" in world.spawned[1][0]


def test_stereo_runs_no_filter_while_the_plain_outputs_are_shown(paths):
    world = clients_world()
    sur.write_settings(paths.settings, settings(speakers="stereo", plain="shown"))
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        assert runner.step(now=0) is None
    assert world.spawned == [] and world.perms.calls == []


def test_plain_command_and_status(paths, as_user, monkeypatch):
    monkeypatch.setattr(sur, "pw_dump", lambda: None)
    rc, out, _ = run(["status"], paths)
    assert "plain      hidden from other programs' output lists" in out
    rc, out, _ = run(["plain", "shown"], paths)
    assert rc == 0 and "plain outputs: shown" in out
    assert sur.read_settings(paths.settings)["plain"] == "shown"
    rc, out, _ = run(["status"], paths)
    assert "plain      shown next to the surround output" in out
    rc, out, _ = run(["plain", "hidden"], paths)
    assert rc == 0 and "'Speakers (Stereo)'" in out
    assert sur.read_settings(paths.settings)["plain"] == "hidden"
    assert sur.description("speakers", "stereo") == "Speakers (Stereo)"
    assert sur.description("headphones", "stereo") == "Headphones (Stereo)"


def test_which_clients_keep_the_plain_outputs():
    assert sur.sees_plain({"wireplumber.daemon": True})
    for binary in ("pipewire", "pipewire-pulse", "pw-dump", "wpctl", "pw-cli"):
        assert sur.sees_plain({"application.process.binary": binary})
    assert not sur.sees_plain({"application.process.binary": "steam"})
    assert not sur.sees_plain({})


# -- the name the output shows ------------------------------------------------
def test_output_names_are_readable(paths):
    assert sur.profile_label("sadie-d2-dry") == "SADIE D2 Dry"
    assert sur.profile_label("mit-kemar-large-full") == "MIT KEMAR Large Full"
    assert sur.profile_label("hutubs-pp1-dry") == "HUTUBS PP1 Dry"
    assert sur.profile_label("user") == "User"
    for profile in sur.PROFILES:
        if profile != sur.STEREO:
            label = sur.profile_label(profile)
            assert "-" not in label and "_" not in label and label[0].isupper()
    assert sur.description("speakers", "sadie-d2-dry") == "Speakers (Surround - SADIE D2 Dry)"
    assert sur.description("headphones", "user") == "Headphones (Surround - User)"
    text = sur.render("speakers", "mit-kemar-dry", sadie_path(), SPK, -1.0, 713)
    assert 'node.description = "Speakers (Surround - MIT KEMAR Dry)"' in text
    assert 'node.nick        = "Speakers (Surround - MIT KEMAR Dry)"' in text
    assert 'node.name        = "Speakers (Surround - MIT KEMAR Dry)"' in text
    assert 'ally-x20-steamos.surround.id = "ally_x20_surround_speakers_a"' in text


def test_runner_restarts_a_dead_filter_with_a_growing_pause(paths):
    world = World()
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        world.spawned[0][1].code = 1          # it died
        runner.step(now=1)
        assert len(world.spawned) == 1        # not yet: 2 s pause after one failure
        runner.step(now=3)
        assert len(world.spawned) == 2
        world.spawned[1][1].code = 1
        runner.step(now=4)
        runner.step(now=6)
        assert len(world.spawned) == 2        # 4 s pause after two
        runner.step(now=8)
        assert len(world.spawned) == 3
        assert [p.node for _, p in world.spawned] == [HA] * 3   # the same name: no hand-over


def test_runner_restarts_when_the_users_file_is_replaced(paths):
    world = World()
    sur.write_settings(paths.settings, settings("user", "stereo"))
    path = write_wav(os.path.join(paths.user_dir, "mine.wav"), value=1.0)
    runner = world.runner(paths)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        assert "mine.wav" in world.spawned[0][0]
        os.utime(path, (1, 1))
        runner.step(now=2)
        assert len(world.spawned) == 2 and world.alive() == [HB]
        os.remove(path)                        # gone: back to the default
        runner.step(now=4)
        assert "sadie-d2-dry.wav" in world.spawned[2][0] and world.alive() == [HA]


# -- commands -----------------------------------------------------------------
@pytest.fixture
def as_user(monkeypatch):
    monkeypatch.setattr(os, "geteuid", lambda: 1000)
    monkeypatch.setattr(sur, "pw_dump", lambda: None)   # no PipeWire needed for any of them


def test_set_names_the_output_and_changes_only_that_one(paths, as_user):
    rc, out, _ = run(["set", "speakers", "mit-kemar-dry"], paths)
    assert rc == 0 and "speakers: mit-kemar-dry + xtc 60 us / 50 %  (trim -5.23 dB)\n" in out
    assert "headphones" not in out
    assert sur.read_settings(paths.settings) == settings(speakers="mit-kemar-dry", plain="hidden")
    rc, out, _ = run(["set", "headphones", "user"], paths)
    assert rc == 0 and "headphones: user -> sadie-d2-dry" in out and "no .wav file" in out
    assert "speakers" not in out and "xtc" not in out
    assert sur.read_settings(paths.settings) == settings("user", "mit-kemar-dry", plain="hidden")
    rc, out, _ = run(["set", "hutubs-pp1-dry", "--device", "headphones"], paths)   # the old form
    assert rc == 0 and "headphones: hutubs-pp1-dry\n" in out
    assert sur.read_settings(paths.settings) == settings("hutubs-pp1-dry", "mit-kemar-dry", plain="hidden")


@pytest.mark.parametrize("argv,word", [
    (["set", "stereo"], "name the output: set headphones stereo, or set speakers stereo"),
    (["set", "speakers"], "usage: set headphones|speakers PROFILE"),
    (["set", "hdmi", "stereo"], "unknown output 'hdmi'"),
    (["set", "speakers", "cipic-003"], "unknown profile 'cipic-003'"),
    (["set", "stereo", "speakers"], "unknown output 'stereo'"),
    (["set", "speakers", "stereo", "extra"], "usage: set"),
    (["set", "stereo", "--device", "hdmi"], "unknown output 'hdmi'"),
    (["set", "speakers", "stereo", "--device", "speakers"], "usage: set"),
])
def test_set_without_a_named_output_or_with_a_bad_one_changes_nothing(paths, as_user, argv, word):
    monkeypatch_dump = sur.pw_dump     # even with an output in use, nothing is guessed
    sur.pw_dump = lambda: state(plugged=True)
    try:
        rc, out, err = run(argv, paths)
    finally:
        sur.pw_dump = monkeypatch_dump
    assert rc == 1 and word in err and out == ""
    assert not os.path.exists(paths.settings)


def test_xtc_command_sets_validates_and_reports(paths, as_user):
    rc, out, _ = run(["xtc", "100", "30"], paths)
    assert rc == 0 and "xtc: 100 us / 30 %  (speakers only)" in out
    assert "speakers: sadie-d2-dry + xtc 100 us / 30 %  (trim -1.29 dB)" in out
    assert sur.read_settings(paths.settings) == settings(xtc=(100, 30), plain="hidden")
    rc, out, _ = run(["xtc", "off"], paths)
    assert rc == 0 and "xtc: off" in out and "speakers: sadie-d2-dry\n" in out
    assert sur.read_settings(paths.settings) == settings(xtc=None, plain="hidden")
    for bad, word in ((["10", "50"], "delay 10 is out of range: 20 to 300"),
                      (["60", "99"], "strength 99 is out of range: 5 to 95"),
                      (["60"], "xtc takes"), (["60", "50", "3"], "xtc takes"),
                      (["loud", "50"], "whole numbers")):
        rc, _, err = run(["xtc"] + bad, paths)
        assert rc == 1 and word in err
    assert sur.read_settings(paths.settings) == settings(xtc=None, plain="hidden")   # nothing bad was stored
    # the headphones' profile is untouched by it, and an unusable setting is
    # stored but explained
    sur.write_settings(paths.settings, settings("hutubs-pp1-dry", "mit-kemar-dry", None))
    rc, out, _ = run(["xtc", "60", "70"], paths)
    assert rc == 0 and "speakers: mit-kemar-dry\n" in out
    assert "note: crosstalk cancellation 60 us / 70 % is not usable with mit-kemar-dry" in out
    assert sur.read_settings(paths.settings) == settings("hutubs-pp1-dry", "mit-kemar-dry",
                                                         (60, 70))
    sur.write_settings(paths.settings, settings(speakers="stereo", xtc=None))
    rc, out, _ = run(["xtc", "60", "50"], paths)
    assert rc == 0 and "the speakers' profile is stereo" in out


def test_prepare_generates_the_tested_grid_and_prints_trim_and_check(paths, as_user, monkeypatch):
    made = count_calls(monkeypatch, "make_variant")
    rc, out, _ = run(["prepare"], paths)
    assert rc == 0 and "speakers: sadie-d2-dry (sadie-d2-dry.wav, trim -1.10 dB without xtc)" in out
    rows = [line for line in out.splitlines() if " us / " in line]
    assert len(rows) == 12 == len(made) and all(row.endswith("usable") for row in rows)
    assert "* 60 us / 50 %    -1.60 dB  usable" in rows
    assert "  120 us / 70 %   -2.10 dB  usable" in rows
    assert len([n for n in os.listdir(paths.cache) if n.endswith(".wav")]) == 12
    rc, again, _ = run(["prepare"], paths)
    assert again == out and len(made) == 12            # nothing is generated twice

    # a setting outside the grid is added; unusable ones say why
    sur.write_settings(paths.settings, settings(speakers="mit-kemar-dry", xtc=(150, 40)))
    rc, out, _ = run(["prepare"], paths)
    rows = [line for line in out.splitlines() if " us / " in line]
    assert rc == 0 and len(rows) == 13 and rows[-1].startswith("* 150 us / 40 %")
    bad = [row for row in rows if "not usable: routing check" in row]
    assert [row.split(" %")[0].strip() for row in bad] == ["60 us / 70", "80 us / 70",
                                                           "100 us / 70"]
    assert "never played" in out

    sur.write_settings(paths.settings, settings(speakers="stereo"))
    rc, _, err = run(["prepare"], paths)
    assert rc == 1 and "nothing to prepare" in err


def test_status_shows_profiles_the_xtc_setting_the_file_and_its_trim(paths, monkeypatch):
    monkeypatch.setattr(os, "geteuid", lambda: 1000)
    monkeypatch.setattr(sur, "pw_dump", lambda: state(plugged=False, running=(SA,)))
    made = count_calls(monkeypatch, "make_variant")
    rc, out, _ = run(["status"], paths)
    assert rc == 0 and not made                         # status never generates
    assert "headphones sadie-d2-dry  (sadie-d2-dry.wav, trim -1.10 dB)\n" in out
    assert "speakers   sadie-d2-dry  (sadie-d2-dry.wav, trim -1.10 dB)  [in use]" in out
    assert "xtc        60 us / 50 %  (speakers only): not generated yet" in out
    assert "running: Speakers (Surround - SADIE D2 Dry)" in out

    file = sur.variant(paths, sadie_path(), (60, 50))["wav"]
    rc, out, _ = run(["status"], paths)
    assert ("speakers   sadie-d2-dry + xtc 60 us / 50 %  (sadie-d2-dry.wav, trim -1.60 dB)"
            "  [in use]") in out
    assert "xtc        60 us / 50 %%  (speakers only): %s\n" % file in out

    sur.write_settings(paths.settings, settings(speakers="mit-kemar-dry", xtc=(60, 70)))
    sur.effective(paths, "speakers", sur.read_settings(paths.settings))
    monkeypatch.setattr(sur, "pw_dump", lambda: state(plugged=True, running=(HA,)))
    rc, out, _ = run(["status"], paths)
    assert "headphones sadie-d2-dry  (sadie-d2-dry.wav, trim -1.10 dB)  [in use]" in out
    assert "speakers   mit-kemar-dry  (mit-kemar-dry.wav, trim -5.03 dB)\n" in out
    assert "           note: crosstalk cancellation 60 us / 70 % is not usable" in out
    assert "xtc        60 us / 70 %  (speakers only): not in use, see the note" in out
    assert "running: Headphones (Surround - SADIE D2 Dry)" in out

    sur.write_settings(paths.settings, settings(speakers="stereo", xtc=None))
    rc, out, _ = run(["status"], paths)
    assert "speakers   stereo\n" in out and "xtc        off  (speakers only)\n" in out


def test_list_names_the_profiles_the_defaults_and_xtc(paths, as_user):
    rc, out, _ = run(["list"], paths)
    assert [line.split()[0] for line in out.splitlines()[:10]] == list(sur.PROFILES)
    assert "sadie-d2-full" in out and "every channel filtered" in out
    assert "(default for headphones and speakers)" in out
    assert "crosstalk cancellation" in out and "default 60 us / 50 %" in out
    assert "Recommended: -dry, on both outputs." in out and "not measured" in out


def test_refuses_to_run_as_root(paths, monkeypatch):
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.delenv("X20_SURROUND_ALLOW_ROOT", raising=False)
    rc, _, err = run(["list"], paths)
    assert rc == 1 and "not with sudo" in err
