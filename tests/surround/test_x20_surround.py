# SPDX-License-Identifier: GPL-2.0-only
"""overlay/bin/x20-surround.py: settings, the user's file, what PipeWire's
state means, the plan and the runner. No PipeWire needed (see headless.py
for that)."""

import importlib.util
import io
import os
import struct
import sys
from contextlib import redirect_stderr, redirect_stdout

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir))
spec = importlib.util.spec_from_file_location(
    "x20_surround", os.path.join(REPO, "overlay", "bin", "x20-surround.py"))
sur = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sur)

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
           "X20_SURROUND_HRIR": os.path.join(REPO, "overlay", "surround", "hrir")}
    return sur.Paths(env)


def state(plugged=False, sinks=("headphones", "speakers"), running=()):
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
            objs.append({"type": "PipeWire:Interface:Node", "info": {"props": {
                "node.name": name, "media.class": "Audio/Sink", "priority.session": prio}}})
    for name in running:
        objs.append({"type": "PipeWire:Interface:Node", "info": {"props": {
            "node.name": name, "media.class": "Audio/Sink"}}})
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
    assert sur.DEFAULT == {"headphones": "sadie-d2-dry", "speakers": "stereo"}


def test_notice_lists_every_shipped_file_with_its_checksum():
    import hashlib
    notice = open(os.path.join(REPO, "overlay", "surround", "NOTICE.md")).read()
    hrir = os.path.join(REPO, "overlay", "surround", "hrir")
    names = sorted(os.listdir(hrir))
    assert names == sorted(f for f, _, _ in sur.BUILTIN.values())
    for name in names:
        digest = hashlib.sha256(open(os.path.join(hrir, name), "rb").read()).hexdigest()
        assert "`%s` | `%s`" % (name, digest) in notice


# -- settings -----------------------------------------------------------------
def test_settings_default_bad_values_and_round_trip(paths):
    assert sur.read_settings(paths.settings) == sur.DEFAULT
    os.makedirs(paths.config_dir)
    with open(paths.settings, "w") as f:
        f.write("# x\nheadphones = hutubs-pp1-dry\nspeakers=nonsense\nother=stereo\n")
    assert sur.read_settings(paths.settings) == {"headphones": "hutubs-pp1-dry",
                                                 "speakers": "stereo"}
    sur.write_settings(paths.settings, {"headphones": "user", "speakers": "mit-kemar-dry"})
    assert sur.read_settings(paths.settings) == {"headphones": "user",
                                                 "speakers": "mit-kemar-dry"}


# -- the user's file ----------------------------------------------------------
@pytest.mark.parametrize("fmt", ["f32", "i16", "i24", "i32"])
@pytest.mark.parametrize("extensible", [False, True])
def test_wav_formats_are_read(tmp_path, fmt, extensible):
    path = write_wav(str(tmp_path / "a.wav"), fmt=fmt, extensible=extensible)
    assert sur.wav_info(path)[:4] == (14, 48000, 64, fmt)
    # two impulses of 0.25 -> energy 0.125 -> +9.03 dB, limited to +3
    assert sur.user_trim_db(path) == 3.0


def test_user_trim_matches_the_stereo_path_level(tmp_path):
    loud = write_wav(str(tmp_path / "loud.wav"), value=1.0)   # energy 2 -> -3.01 dB
    assert abs(sur.user_trim_db(loud) + 3.01) < 0.01


@pytest.mark.parametrize("kw,word", [({"channels": 2}, "2 channel"), ({"rate": 44100}, "44100 Hz"),
                                     ({"frames": 48001}, "per channel")])
def test_unusable_files_are_refused_with_a_reason(tmp_path, kw, word):
    path = write_wav(str(tmp_path / "bad.wav"), **kw)
    with pytest.raises(sur.Problem, match=word):
        sur.check_hrir(path)


def test_not_a_wav_and_silent_fronts(tmp_path):
    junk = tmp_path / "junk.wav"
    junk.write_bytes(b"hello")
    with pytest.raises(sur.Problem, match="not a WAV"):
        sur.check_hrir(str(junk))
    with pytest.raises(sur.Problem, match="silent"):
        sur.user_trim_db(write_wav(str(tmp_path / "s.wav"), value=0.0))


def test_user_profile_takes_the_first_wav_in_lexical_order(paths):
    assert sur.user_file(paths) is None
    write_wav(os.path.join(paths.user_dir, "b.wav"))
    write_wav(os.path.join(paths.user_dir, "A-first.WAV"), value=1.0)
    open(os.path.join(paths.user_dir, "0-notes.txt"), "w").close()
    assert os.path.basename(sur.user_file(paths)) == "A-first.WAV"
    profile, wav, trim, note = sur.resolve(paths, "headphones", "user")
    assert (profile, os.path.basename(wav), note) == ("user", "A-first.WAV", None)
    assert abs(trim + 3.01) < 0.01


def test_user_profile_without_a_usable_file_falls_back_to_the_default(paths):
    profile, wav, _, note = sur.resolve(paths, "headphones", "user")
    assert profile == "sadie-d2-dry" and wav.endswith("sadie-d2-dry.wav")
    assert "no .wav file" in note and "using sadie-d2-dry" in note
    assert sur.resolve(paths, "speakers", "user")[0] == "stereo"
    write_wav(os.path.join(paths.user_dir, "bad.wav"), channels=2)
    profile, _, _, note = sur.resolve(paths, "headphones", "user")
    assert profile == "sadie-d2-dry" and "bad.wav: 2 channel" in note


def test_missing_shipped_file_falls_back_to_stereo(paths):
    paths.hrir = "/nonexistent"
    profile, wav, _, note = sur.resolve(paths, "headphones", "sadie-d2-dry")
    assert (profile, wav) == ("stereo", None) and "is missing" in note


# -- PipeWire's state ---------------------------------------------------------
def test_look_finds_the_internal_sinks_and_the_jack():
    seen = sur.look(state(plugged=True, running=("ally_x20_surround_headphones",)))
    assert seen["sinks"] == {"headphones": (HP, 1000), "speakers": (SPK, 712)}
    assert seen["headphones_plugged"] and seen["running"] == {"ally_x20_surround_headphones"}
    # another card's "Headphones" route and a Bluetooth sink do not count
    assert not sur.look(state(plugged=False))["headphones_plugged"]
    assert sur.look([]) == {"sinks": {}, "headphones_plugged": False, "running": set()}


def test_active_device_follows_the_jack():
    assert sur.active_device(sur.look(state(plugged=True))) == "headphones"
    assert sur.active_device(sur.look(state(plugged=False))) == "speakers"
    assert sur.active_device(sur.look(state(plugged=True, sinks=("speakers",)))) == "speakers"
    assert sur.active_device(sur.look(state(sinks=()))) is None


def test_plan_headphones_default_speakers_stereo(paths):
    want, note = sur.plan(paths, sur.look(state(plugged=True)))
    assert want[:2] == ("headphones", "sadie-d2-dry") and want[4:6] == (HP, 1001) and note is None
    assert sur.plan(paths, sur.look(state(plugged=False))) == (None, None)
    sur.write_settings(paths.settings, {"headphones": "stereo", "speakers": "mit-kemar-dry"})
    assert sur.plan(paths, sur.look(state(plugged=True)))[0] is None
    want, _ = sur.plan(paths, sur.look(state(plugged=False)))
    assert want[:2] == ("speakers", "mit-kemar-dry") and want[4:6] == (SPK, 713)


# -- the config ---------------------------------------------------------------
def test_render_is_a_71_sink_pinned_to_the_target(paths):
    wav = os.path.join(paths.hrir, "sadie-d2-dry.wav")
    text = sur.render("headphones", "sadie-d2-dry", wav, HP, -1.10, 1001)
    assert text.count("label = convolver") == 16
    assert 'filename = "%s" channel = 13' % wav in text
    assert "audio.channels   = 8" in text and "audio.position   = [ FL FR FC LFE RL RR SL SR ]" in text
    assert 'node.name        = "ally_x20_surround_headphones"' in text
    assert "priority.session = 1001" in text
    assert 'target.object      = "%s"' % HP in text
    assert "node.dont-fallback = true" in text and "node.linger        = true" in text
    assert '"Gain 1" = %.6f' % 10 ** (-1.10 / 20) in text      # the trim
    assert '"Gain 8" = %.6f' % (0.5 * 10 ** (-1.10 / 20)) in text  # the LFE at half
    assert '"Min" = -0.8910 "Max" = 0.8910' in text
    with pytest.raises(sur.Problem):
        sur.render("headphones", "x", '/a"b.wav', HP, 0.0, 1)


# -- the runner ---------------------------------------------------------------
class FakeProc:
    def __init__(self):
        self.code = None
        self.terminated = False

    def poll(self):
        return self.code

    def terminate(self):
        self.terminated = True
        self.code = 0

    def wait(self, timeout=None):
        return self.code

    def kill(self):
        self.code = -9


class World:
    def __init__(self):
        self.objects = state(plugged=True)
        self.spawned = []

    def dump(self):
        return self.objects

    def spawn(self, conf_path):
        proc = FakeProc()
        self.spawned.append((conf_path, open(conf_path).read(), proc))
        return proc


def test_runner_starts_follows_the_jack_and_the_setting_and_stops(paths):
    world = World()
    runner = sur.Runner(paths, spawn=world.spawn, dump=world.dump)
    with redirect_stderr(io.StringIO()):
        assert runner.step(now=0)[:2] == ("headphones", "sadie-d2-dry")
        assert len(world.spawned) == 1 and "sadie-d2-dry.wav" in world.spawned[0][1]
        runner.step(now=2)
        assert len(world.spawned) == 1  # nothing changed: nothing restarted

        sur.write_settings(paths.settings, {"headphones": "hutubs-pp1-dry", "speakers": "stereo"})
        runner.step(now=4)
        assert world.spawned[0][2].terminated and "hutubs-pp1-dry.wav" in world.spawned[1][1]

        world.objects = state(plugged=False)  # unplugged: speakers, which are stereo
        assert runner.step(now=6) is None
        assert world.spawned[1][2].terminated and len(world.spawned) == 2

        sur.write_settings(paths.settings, {"headphones": "hutubs-pp1-dry",
                                            "speakers": "mit-kemar-dry"})
        assert runner.step(now=8)[0] == "speakers"
        assert "target.object      = \"%s\"" % SPK in world.spawned[2][1]

        world.objects = None  # PipeWire went away
        assert runner.step(now=10) is None and world.spawned[2][2].terminated
        world.objects = state(plugged=False)
        runner.step(now=12)
        assert len(world.spawned) == 4
        runner.stop()
        assert world.spawned[3][2].terminated


def test_runner_restarts_a_dead_filter_with_a_growing_pause(paths):
    world = World()
    runner = sur.Runner(paths, spawn=world.spawn, dump=world.dump)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        world.spawned[0][2].code = 1          # it died
        runner.step(now=1)
        assert len(world.spawned) == 1        # not yet: 2 s pause after one failure
        runner.step(now=3)
        assert len(world.spawned) == 2
        world.spawned[1][2].code = 1
        runner.step(now=4)
        runner.step(now=6)
        assert len(world.spawned) == 2        # 4 s pause after two
        runner.step(now=8)
        assert len(world.spawned) == 3


def test_runner_restarts_when_the_users_file_is_replaced(paths):
    world = World()
    sur.write_settings(paths.settings, {"headphones": "user", "speakers": "stereo"})
    path = write_wav(os.path.join(paths.user_dir, "mine.wav"), value=1.0)
    runner = sur.Runner(paths, spawn=world.spawn, dump=world.dump)
    with redirect_stderr(io.StringIO()):
        runner.step(now=0)
        assert "mine.wav" in world.spawned[0][1]
        os.utime(path, (1, 1))
        runner.step(now=2)
        assert len(world.spawned) == 2
        os.remove(path)                        # gone: back to the default
        runner.step(now=4)
        assert "sadie-d2-dry.wav" in world.spawned[2][1]


# -- commands -----------------------------------------------------------------
def test_set_needs_a_device_when_pipewire_is_silent_and_records_the_choice(paths, monkeypatch):
    monkeypatch.setattr(sur, "pw_dump", lambda: None)
    monkeypatch.setattr(os, "geteuid", lambda: 1000)
    rc, _, err = run(["set", "stereo"], paths)
    assert rc == 1 and "--device headphones|speakers" in err
    rc, out, _ = run(["set", "mit-kemar-dry", "--device", "speakers"], paths)
    assert rc == 0 and "speakers: mit-kemar-dry" in out
    assert sur.read_settings(paths.settings)["speakers"] == "mit-kemar-dry"
    monkeypatch.setattr(sur, "pw_dump", lambda: state(plugged=True))
    rc, out, _ = run(["set", "user"], paths)  # the output in use: headphones
    assert rc == 0 and "headphones: user -> sadie-d2-dry" in out and "no .wav file" in out
    assert sur.read_settings(paths.settings)["headphones"] == "user"


def test_status_and_list(paths, monkeypatch):
    monkeypatch.setattr(os, "geteuid", lambda: 1000)
    monkeypatch.setattr(sur, "pw_dump",
                        lambda: state(plugged=True, running=("ally_x20_surround_headphones",)))
    rc, out, _ = run(["status"], paths)
    assert rc == 0
    assert "headphones sadie-d2-dry  (sadie-d2-dry.wav, trim -1.10 dB)  [in use]" in out
    assert "speakers   stereo" in out and "running: Headphones (7.1 surround)" in out
    rc, out, _ = run(["list"], paths)
    assert [line.split()[0] for line in out.splitlines()[:6]] == list(sur.PROFILES)
    assert "(default for headphones)" in out and "(default for speakers)" in out


def test_refuses_to_run_as_root(paths, monkeypatch):
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.delenv("X20_SURROUND_ALLOW_ROOT", raising=False)
    rc, _, err = run(["list"], paths)
    assert rc == 1 and "not with sudo" in err
