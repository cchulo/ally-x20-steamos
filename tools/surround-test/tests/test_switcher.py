# SPDX-License-Identifier: GPL-2.0-only
"""The switcher against a fake PipeWire: volume handling, blind labels,
scoring, logging and restoring. The real-PipeWire run is
tests/tools/surround-test-device.bats (headless, where available)."""

import io
import json
import os
import re

import pytest

from x20surround import manifest, scoring, signals, switcher, wav
from x20surround.layout import RATE, SINK_HEADPHONES, SINK_SPEAKERS, SPEAKERS
from x20surround.pw import PwError, nodes_from, parse_metadata, parse_volume


class FakeProc:
    count = 100

    def __init__(self, on_exit=None):
        FakeProc.count += 1
        self.pid = FakeProc.count
        self.done = False
        self.on_exit = on_exit

    def poll(self):
        return 0 if self.done else None

    def _finish(self):
        if not self.done:
            self.done = True
            if self.on_exit:
                self.on_exit()

    def wait(self, timeout=None):
        self._finish()
        return 0

    terminate = kill = _finish

    def send_signal(self, _sig):
        self._finish()


class FakePw:
    """Enough of x20surround.pw.Pw: sinks with volumes, the configured
    default, filters that appear as nodes, and a record of every change."""

    def __init__(self, hw_volume=0.55, configured=None, stream_channels=8):
        self.table = {}
        self.vol = {}
        self.next_id = 40
        self.configured = configured
        self.stream_channels = stream_channels
        self.events = []
        self.played = []
        self.playing = False
        for name in (SINK_SPEAKERS, SINK_HEADPHONES):
            self.add(name)
        self.vol[self.table[SINK_HEADPHONES]["id"]] = [hw_volume, False]

    def add(self, name, cls="Audio/Sink", channels=2):
        self.next_id += 1
        self.table[name] = {"id": self.next_id, "class": cls, "channels": channels, "props": {}}
        self.vol[self.next_id] = [1.0, False]
        return self.next_id

    def name_of(self, node_id):
        found = [n for n, v in self.table.items() if v["id"] == node_id]
        if not found:
            raise PwError("wpctl: no node %s" % node_id)  # what wpctl does for a stale id
        return found[0]

    def nodes(self):
        out = dict(self.table)
        if self.playing:
            out["x20test-stream"] = {"id": 999, "class": "Stream/Output/Audio",
                                     "channels": self.stream_channels, "props": {}}
        return out

    def node(self, name):
        return self.nodes().get(name)

    def wait_node(self, name, timeout=10.0, proc=None):
        return self.node(name)

    def volume(self, node_id):
        return tuple(self.vol[node_id])

    def set_volume(self, node_id, value):
        name = self.name_of(node_id)
        self.vol[node_id][0] = value
        self.events.append(("volume", name, round(value, 4)))
        self.check_safe()

    def set_mute(self, node_id, muted):
        self.vol[node_id][1] = muted
        self.events.append(("mute", self.name_of(node_id), muted))

    def configured_default(self):
        return self.configured

    def default_sink(self):
        return self.configured or SINK_HEADPHONES

    def set_configured_default(self, name):
        self.configured = name
        self.events.append(("default", name))
        self.check_safe()

    def check_safe(self):
        """The invariant of the rig: while the hardware sink is the default
        it is never above the session volume during a session."""
        hw = self.table[SINK_HEADPHONES]["id"]
        if getattr(self, "session_volume", None) is not None and self.configured == SINK_HEADPHONES:
            assert self.vol[hw][0] <= self.session_volume + 1e-9, self.events[-5:]

    def play(self, path, target=None, name="x20test-stream"):
        self.played.append((os.path.basename(path), target))
        self.playing = True
        return FakeProc(on_exit=lambda: setattr(self, "playing", False))

    def start_filter(self, conf_path, log=None):
        text = open(conf_path).read()
        node = re.search(r'node.name\s+= "(x20test-[a-z])"', text).group(1)
        self.add(node, channels=8)
        self.table[node]["conf"] = text
        return FakeProc(on_exit=lambda: self.table.pop(node, None))

    def version(self, tool):
        return "1.6.8"


@pytest.fixture
def rig(tmp_path, channels):
    """An installed rig with three candidates and a fake PipeWire."""
    share, state = tmp_path / "share", tmp_path / "state"
    (share / "hrir").mkdir(parents=True)
    data = manifest.empty()
    for cid, device in (("syn-full", None), ("syn-dry", None), ("syn-xtc", "speakers")):
        path = str(share / "hrir" / (cid + ".wav"))
        wav.write(path, RATE, channels)
        manifest.add(data, manifest.describe(path, cid, device=device), str(share))
    manifest.save(str(share / "manifest.json"), data)
    env = {"HOME": str(tmp_path), "X20_SURROUND_HOME": str(share),
           "X20_SURROUND_STATE": str(state), "XDG_RUNTIME_DIR": str(tmp_path / "run")}
    return switcher.Paths(env), FakePw()


def run(rig, argv, answers=""):
    paths, pw = rig
    out = io.StringIO()
    rc = switcher.main(argv, pw=pw, io=switcher.IO(io.StringIO(answers), out), paths=paths)
    return rc, out.getvalue()


def log(rig):
    return switcher.read_log(rig[0].log)


# ------------------------------------------------------------- parsing ----
def test_parse_wpctl_volume():
    assert parse_volume("Volume: 0.55\n") == (0.55, False)
    assert parse_volume("Volume: 0.30 [MUTED]\n") == (0.3, True)
    with pytest.raises(PwError):
        parse_volume("nothing")


def test_parse_metadata():
    text = ("Found \"default\" metadata 37\nupdate: id:0 key:'default.configured.audio.sink' "
            "value:'{\"name\":\"x20test-a\"}' type:'Spa:String:JSON'\n")
    assert parse_metadata(text, "default.configured.audio.sink") == "x20test-a"
    assert parse_metadata('Found "default" metadata 37\n', "default.configured.audio.sink") is None


def test_nodes_from_pw_dump():
    objs = [
        {"id": 5, "type": "PipeWire:Interface:Node", "info": {
            "props": {"node.name": "a", "media.class": "Stream/Output/Audio"},
            "params": {"Format": [{"channels": 8}]}}},
        {"id": 6, "type": "PipeWire:Interface:Node", "info": {"props": {"node.name": "b"}}},
        {"id": 7, "type": "PipeWire:Interface:Port", "info": {"props": {"node.name": "c"}}},
    ]
    got = nodes_from(objs)
    assert set(got) == {"a", "b"}
    assert got["a"] == {"id": 5, "class": "Stream/Output/Audio", "channels": 8,
                        "props": objs[0]["info"]["props"]}
    assert got["b"]["channels"] is None


# ------------------------------------------------------------- signals ----
def test_callout_is_one_channel_of_eight_at_the_set_level(tmp_path):
    path = str(tmp_path / "c.wav")
    signals.callout(path, "RL")
    rate, chans = wav.read(path)
    assert rate == RATE and len(chans) == 8
    active = [i for i, c in enumerate(chans) if any(c)]
    assert active == [4]  # FL FR FC LFE RL ...
    assert max(abs(v) for v in chans[4]) < 0.5  # well below full scale
    assert not any(chans[4][:int(0.25 * RATE)])  # lead-in for a sleeping sink
    other = str(tmp_path / "d.wav")
    signals.callout(other, "FL")
    assert wav.read(other)[1][0] == chans[4]  # same noise, other direction


def test_noise_has_seven_channels_and_no_lfe(tmp_path):
    path = str(tmp_path / "n.wav")
    signals.noise(path, seconds=0.5)
    _, chans = wav.read(path)
    assert [bool(any(c)) for c in chans] == [True, True, True, False, True, True, True, True]
    assert chans[0] != chans[1]  # uncorrelated


def test_loudness_follows_gain_and_silence_is_none(tmp_path):
    path = str(tmp_path / "n.wav")
    signals.noise(path, seconds=0.5)
    _, chans = wav.read(path)
    a = signals.loudness_db(chans[0], chans[1])
    b = signals.loudness_db([v * 0.5 for v in chans[0]], [v * 0.5 for v in chans[1]])
    assert a - b == pytest.approx(6.02, abs=0.01)
    assert signals.loudness_db([0.0] * 100, [0.0] * 100) is None


def test_impulses_roundtrip_recovers_a_downmix(tmp_path):
    from x20surround.layout import INPUTS, RAW_DOWNMIX
    path = str(tmp_path / "i.wav")
    signals.impulses(path)
    _, chans = wav.read(path)
    n = len(chans[0])
    left = [0.0] * 500 + [sum(chans[k][i] * RAW_DOWNMIX[c][0] for k, c in enumerate(INPUTS))
                          for i in range(n)]
    right = [0.0] * 500 + [sum(chans[k][i] * RAW_DOWNMIX[c][1] for k, c in enumerate(INPUTS))
                           for i in range(n)]
    got = signals.read_impulses(left, right)
    for c in INPUTS:
        assert got[c] == pytest.approx(RAW_DOWNMIX[c], abs=1e-6)
    assert signals.read_impulses([0.0] * 10, [0.0] * 10) is None


# ------------------------------------------------------------- scoring ----
def test_score_counts_hits_and_confusions():
    s = scoring.score([("FL", "FL"), ("FL", "RL"), ("RR", "FR"), ("SL", "SR"), ("FC", "RL"),
                       ("SL", "RL")])
    assert s["hits"] == 1 and s["trials"] == 6
    assert s["front_back"] == 3  # FL->RL, RR->FR, FC->RL
    assert s["left_right"] == 1  # SL->SR
    assert s["by_channel"]["FL"] == [1, 2] and s["by_channel"]["FR"] == [0, 0]
    assert scoring.score([])["hit_rate"] == 0.0
    assert set(scoring.ANSWERS.values()) == set(SPEAKERS)


def rec(test, date, conds, complete=True, device="headphones"):
    return {"test": test, "time": date + "T20:00:00", "complete": complete, "device": device,
            "conditions": conds}


def loc(cid, hits, n=14):
    return {"id": cid, "hits": hits, "trials": n}


def tone(cid, cand, raw):
    return {"id": cid, "candidate": cand, "raw": raw, "none": 0}


def test_pass_rule_needs_two_different_days_with_both_tests():
    day1 = [rec("localise", "2026-11-19", [loc("raw", 5), loc("a", 9)]),
            rec("tone", "2026-11-19", [tone("a", 2, 1)])]
    v = scoring.verdicts(day1)[("headphones", "a")]
    assert v["days"] == {"2026-11-19": True} and not v["passed"]
    # a second session on the SAME day does not help
    assert not scoring.verdicts(day1 + day1)[("headphones", "a")]["passed"]
    day2 = [rec("localise", "2026-11-20", [loc("raw", 6), loc("a", 8)]),
            rec("tone", "2026-11-20", [tone("a", 1, 1)])]  # a tie is "not lose"
    assert scoring.verdicts(day1 + day2)[("headphones", "a")]["passed"]


def test_pass_rule_rejects_ties_on_localisation_losses_on_tone_and_missing_tests():
    def one(loc_c, loc_raw, tone_c, tone_raw, date="2026-11-19"):
        return [rec("localise", date, [loc("raw", loc_raw), loc("a", loc_c)]),
                rec("tone", date, [tone("a", tone_c, tone_raw)])]
    key = ("headphones", "a")
    assert scoring.verdicts(one(7, 7, 3, 0))[key]["days"] == {"2026-11-19": False}
    assert scoring.verdicts(one(9, 5, 1, 2))[key]["days"] == {"2026-11-19": False}
    only_loc = [rec("localise", "2026-11-19", [loc("raw", 5), loc("a", 9)])]
    assert scoring.verdicts(only_loc)[key]["days"] == {"2026-11-19": False}
    incomplete = one(9, 5, 2, 0)
    incomplete[0]["complete"] = False
    assert scoring.verdicts(incomplete)[key]["days"] == {"2026-11-19": False}
    # speakers and headphones are judged separately
    mixed = one(9, 5, 2, 0) + [rec("tone", "2026-11-20", [tone("a", 2, 0)], device="speakers")]
    assert set(scoring.verdicts(mixed)) == {key, ("speakers", "a")}


# ------------------------------------------------------------ switcher ----
def answers_for(rig, trials_answer):
    """Enter, then one answer per call-out."""
    return "\n" + "".join(a + "\n" for a in trials_answer)


def test_localise_blind_run_scores_logs_and_restores(rig):
    paths, pw = rig
    pw.session_volume = switcher.START_VOLUME
    n = 3 * 7 * 1  # raw + 2 headphone candidates, 7 directions, 1 repeat
    rc, out = run(rig, ["localise", "--repeats", "1", "--seed", "5"], "\n" + "1\n" * n)
    assert rc == 0, out
    # blind: no candidate name before the reveal
    before, after = out.split("The labels were:")
    assert "syn-full" not in before and "syn-dry" not in before
    assert "syn-full" in after and "raw" in after
    assert "syn-xtc" not in out  # a speaker candidate is not in a headphone session
    (record,) = log(rig)
    assert record["complete"] and record["test"] == "localise" and record["blind"]
    assert record["device"] == "headphones" and record["target"] == SINK_HEADPHONES
    assert record["stream_channels"] == 8
    assert sorted(c["id"] for c in record["conditions"]) == ["raw", "syn-dry", "syn-full"]
    for c in record["conditions"]:
        assert c["trials"] == 7 and c["hits"] == 1  # always answering front-left
    assert len(record["trials"]) == n and len(set(record["labels"].values())) == 3
    assert re.match(r"\d{8}T\d{6}-[0-9a-f]{4}$", record["session"])
    # every call-out went to the condition's own node, one channel at a time
    targets = {t for _, t in pw.played}
    assert SINK_HEADPHONES in targets and len(targets) == 3
    assert {f for f, _ in pw.played} == {"callout-%s.wav" % c for c in SPEAKERS}
    # restored: volume, mute, default sink; filters gone; no restore file left
    hw = pw.table[SINK_HEADPHONES]["id"]
    assert pw.vol[hw] == [0.55, False] and pw.configured is None
    assert not [n for n in pw.table if n.startswith("x20test-")]
    assert not os.path.exists(paths.restore)


def test_hardware_is_at_100_percent_only_under_a_candidate(rig):
    paths, pw = rig
    pw.session_volume = switcher.START_VOLUME
    run(rig, ["localise", "--repeats", "1", "--seed", "1"], "\n" + "2\n" * 21)
    hw_full = [i for i, e in enumerate(pw.events) if e == ("volume", SINK_HEADPHONES, 1.0)]
    assert hw_full
    for i in hw_full:
        # the candidate was made the default (at the session volume) first
        kind, name = pw.events[i - 1]
        assert kind == "default" and name.startswith("x20test-")
        assert pw.events[i - 2] == ("volume", name, switcher.START_VOLUME)
    # going back to raw lowers the hardware before it becomes the default
    for i, e in enumerate(pw.events):
        if e == ("default", SINK_HEADPHONES):
            assert pw.events[i - 1] == ("volume", SINK_HEADPHONES, switcher.START_VOLUME)


def test_candidate_confs_are_pinned_to_the_device_and_level_matched(rig):
    paths, pw = rig
    seen = {}
    real = pw.start_filter

    def spy(conf_path, log=None):
        seen[conf_path] = open(conf_path).read()
        return real(conf_path, log=log)
    pw.start_filter = spy
    run(rig, ["localise", "--repeats", "1", "--device", "speakers", "--seed", "2"],
        "\n" + "1\n" * 14)
    (text,) = seen.values()
    assert 'target.object      = "%s"' % SINK_SPEAKERS in text
    assert "node.dont-fallback = true" in text
    # blind: what PipeWire shows (names, descriptions) carries the label only
    shown = [ln for ln in text.splitlines() if "description" in ln or "node.name" in ln
             or "media.name" in ln or "# candidate" in ln]
    assert shown and not any("syn-xtc" in ln for ln in shown)
    entry = manifest.find(manifest.load(paths.manifest), "syn-xtc")
    gain = 10 ** (entry["trim_db"] / 20.0)
    assert '"Gain 1" = %.6f' % gain in text
    (record,) = log(rig)
    assert record["device"] == "speakers" and record["level_matched"] == {"syn-xtc": False}


def test_replay_volume_keys_and_quit(rig):
    paths, pw = rig
    rc, out = run(rig, ["localise", "--repeats", "1", "--seed", "5", "--candidates", "syn-full"],
                  "\nr\n+\nx\n1\nq\n")
    assert rc == 1
    assert "volume 0.40" in out and "1-7, r, +, - or q" in out
    assert "Incomplete, not counted" in out
    (record,) = log(rig)
    assert not record["complete"] and record["volume"] == 0.4
    assert sum(c["trials"] for c in record["conditions"]) == 1
    assert len(pw.played) == 4  # first call-out, replay, replay after +, second call-out
    hw = pw.table[SINK_HEADPHONES]["id"]
    assert pw.vol[hw] == [0.55, False]


def test_volume_is_capped(rig):
    rc, out = run(rig, ["localise", "--repeats", "1", "--volume", "3", "--candidates", "syn-full"],
                  "\n" + "+\n" * 3 + "q\n")
    assert "Starting volume 0.80" in out and out.count("volume 0.80") >= 3
    assert "volume 0.85" not in out


def test_stops_when_the_test_stream_is_not_8_channels(rig):
    paths, pw = rig
    pw.stream_channels = 2
    rc, out = run(rig, ["localise", "--repeats", "1"], "\n1\n")
    assert rc == 1 and "has 2 channels, not 8" in out
    assert pw.vol[pw.table[SINK_HEADPHONES]["id"]] == [0.55, False]


def test_input_ending_or_a_dead_filter_still_restores(rig):
    paths, pw = rig
    rc, out = run(rig, ["localise", "--repeats", "1"], "\n1\n")  # input ends early
    assert rc == 1 and "input ended" in out
    assert pw.vol[pw.table[SINK_HEADPHONES]["id"]] == [0.55, False] and pw.configured is None
    real = pw.play

    def dying(path, target=None, name="x20test-stream"):
        for n in [n for n in pw.table if n.startswith("x20test-")]:
            pw.table.pop(n)
        return real(path, target, name)
    pw.play = dying
    rc, out = run(rig, ["localise", "--repeats", "1", "--seed", "3"], "\n" + "1\n" * 21)
    assert rc == 1 and ("disappeared" in out or "no node" in out)
    assert pw.vol[pw.table[SINK_HEADPHONES]["id"]] == [0.55, False] and pw.configured is None


def test_a_user_picked_default_and_mute_are_put_back(rig):
    paths, _ = rig
    pw = FakePw(hw_volume=0.2, configured=SINK_SPEAKERS)
    hw = pw.table[SINK_HEADPHONES]["id"]
    pw.vol[hw][1] = True
    run((paths, pw), ["localise", "--repeats", "1", "--candidates", "syn-full"],
        "\n" + "1\n" * 14)
    assert pw.vol[hw] == [0.2, True] and pw.configured == SINK_SPEAKERS
    assert ("mute", SINK_HEADPHONES, False) in pw.events  # audible during the test


def test_missing_sink_and_unfinished_session_are_refused(rig):
    paths, pw = rig
    rc, out = run(rig, ["localise", "--target", "bluez_output.nope"], "\n")
    assert rc == 1 and "not found" in out and not log(rig)
    os.makedirs(paths.state, exist_ok=True)
    open(paths.restore, "w").write("{}")
    rc, out = run(rig, ["localise"], "\n")
    assert rc == 1 and "surround-test restore" in out


def test_restore_command_after_a_crash(rig):
    paths, pw = rig
    hw = pw.table[SINK_HEADPHONES]["id"]
    pw.vol[hw] = [1.0, False]
    pw.configured = "x20test-a"
    switcher.save_json(paths.restore, {"target": SINK_HEADPHONES, "volume": 0.4, "muted": False,
                                       "configured": None, "pids": []})
    rc, out = run(rig, ["restore"])
    assert rc == 0 and "restored" in out and "automatic" in out
    assert pw.vol[hw] == [0.4, False] and pw.configured is None
    assert not os.path.exists(paths.restore)
    rc, out = run(rig, ["restore"])
    assert rc == 0 and "nothing to restore" in out


def test_tone_blind_ab_counts_preferences(rig):
    paths, pw = rig
    pw.session_volume = switcher.START_VOLUME
    material = os.path.join(str(paths.share), "song.wav")
    wav.write(material, RATE, [[0.0] * 10] * 2)
    # one candidate, three rounds: switch a few times, then prefer 1, 2, none
    rc, out = run(rig, ["tone", "--file", material, "--candidates", "syn-full", "--seed", "9"],
                  "\n2\n1\np1\n2\np2\np0\n")
    assert rc == 0, out
    assert "syn-full" not in out.split("Preferences:")[0]
    (record,) = log(rig)
    (c,) = record["conditions"]
    assert record["test"] == "tone" and record["material"] == "song.wav" and record["complete"]
    assert c["candidate"] + c["raw"] == 2 and c["none"] == 1
    assert ("song.wav", None) in pw.played  # on the default sink, so it follows the switch
    # switching really changed the default sink between raw and the candidate
    defaults = [e[1] for e in pw.events if e[0] == "default"]
    assert SINK_HEADPHONES in defaults and any(str(d).startswith("x20test-") for d in defaults)
    assert pw.configured is None


def test_tone_needs_material(rig):
    rc, out = run(rig, ["tone"], "")
    assert rc == 1 and "--file FILE or --live" in out
    rc, out = run(rig, ["tone", "--file", "/nonexistent.flac"], "")
    assert rc == 1 and "no such file" in out


def test_results_applies_the_pass_rule(rig):
    paths, _ = rig
    for r in (rec("localise", "2026-11-19", [loc("raw", 5), loc("a", 9)]),
              rec("tone", "2026-11-19", [tone("a", 2, 1)]),
              rec("localise", "2026-11-20", [loc("raw", 6), loc("a", 8)]),
              rec("tone", "2026-11-20", [tone("a", 1, 1)]),
              rec("localise", "2026-11-20", [loc("raw", 6), loc("b", 6)])):
        switcher.append_log(paths.log, r)
    rc, out = run(rig, ["results"])
    assert rc == 0
    assert "must beat raw on localisation and not lose on tone" in out
    assert "a on headphones: PASS (2 of 2 day(s) needed)" in out
    assert "b on headphones: not passed (0 of 2 day(s) needed)" in out
    assert "localisation 9/14 against raw 5/14; tone 2 for it, 1 for raw  -> counts" in out


def test_add_user_checks_and_registers_a_local_file(rig, tmp_path, channels):
    paths, _ = rig
    src = str(tmp_path / "atmos.wav")
    wav.write(src, RATE, channels)
    rc, out = run(rig, ["add-user", src])
    assert rc == 0 and "routing   PASS" in out
    entry = manifest.find(manifest.load(paths.manifest), "user")
    assert entry["file"] == "hrir/user.wav" and "not redistributable" in entry["licence"]
    assert os.path.isfile(os.path.join(paths.share, "hrir", "user.wav"))
    bad = str(tmp_path / "stereo.wav")
    wav.write(bad, RATE, [[1.0], [1.0]])
    rc, out = run(rig, ["add-user", bad, "--id", "other"])
    assert rc == 1 and "2 channels" in out
    assert not os.path.exists(os.path.join(paths.share, "hrir", "other.wav"))


def test_doctor_and_list(rig):
    rc, out = run(rig, ["doctor"])
    assert rc == 0, out
    assert "headphones   %s  present" % SINK_HEADPHONES in out
    assert "3 candidate(s)" in out and "syn-xtc" in out and "speakers" in out
    rc, out = run(rig, ["list"])
    assert rc == 0 and "syn-full" in out and "routing" in out


def test_pick_candidates_skips_failed_ones_unless_asked(rig):
    paths, _ = rig
    data = manifest.load(paths.manifest)
    data["candidates"][0]["status"] = "FAIL"
    assert [c["id"] for c in switcher.pick_candidates(data, "headphones")] == ["syn-dry"]
    assert [c["id"] for c in switcher.pick_candidates(data, "speakers")] == ["syn-xtc"]
    assert [c["id"] for c in switcher.pick_candidates(data, "headphones", ["syn-full"])] == [
        "syn-full"]
    with pytest.raises(switcher.Abort):
        switcher.pick_candidates(data, "headphones", ["nope"])


def test_labels_are_random_letters():
    import random
    got = switcher.labels(5, random.Random(1))
    assert len(set(got)) == 5 and all(len(x) == 1 and x.isupper() for x in got)
    assert got != switcher.labels(5, random.Random(2))
    with pytest.raises(switcher.Abort):
        switcher.labels(27, random.Random(1))
