# SPDX-License-Identifier: GPL-2.0-only
import json
import os
import re
import subprocess
import sys

import pytest

from x20surround import conf, manifest, wav
from x20surround.layout import HESUVI, INPUTS, RATE, SINK_HEADPHONES

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "hrir_tool.py")


def render(**kw):
    args = dict(label="mit-kemar-full", node="x20test-a", description="Surround test A",
                wav="/home/deck/hrir/a.wav", target=SINK_HEADPHONES, gain=0.5)
    args.update(kw)
    return conf.render(**args)


def test_convolver_channels_follow_the_hesuvi_layout():
    text = render()
    found = re.findall(r'name = conv(\w+)_([LR]) config = \{ filename = "([^"]+)" channel = (\d+) \}',
                       text)
    assert len(found) == 16
    for speaker, ear, path, channel in found:
        assert path == "/home/deck/hrir/a.wav"
        src = "FC" if speaker == "LFE" else speaker
        assert HESUVI[int(channel)] == (src, ear)


def test_every_convolver_is_fed_by_its_input_and_reaches_its_ear():
    text = render()
    for c in INPUTS:
        for ear in "LR":
            assert '{ output = "copy%s:Out" input = "conv%s_%s:In" }' % (c, c, ear) in text
            assert re.search(r'\{ output = "conv%s_%s:Out" input = "mix%s:In \d" \}' % (c, ear, ear),
                             text)
    # each mixer input is used exactly once
    for ear in "LR":
        slots = re.findall(r'input = "mix%s:In (\d)"' % ear, text)
        assert sorted(slots) == [str(i) for i in range(1, 9)]
    assert 'inputs  = [ "copyFL:In" "copyFR:In" "copyFC:In" "copyLFE:In" "copyRL:In" "copyRR:In" ' \
           '"copySL:In" "copySR:In" ]' in text


def test_gains_carry_the_trim_and_the_lfe_is_6_db_lower():
    text = render(gain=0.5)
    for ear in "LR":
        line = [ln for ln in text.splitlines() if "name = mix%s " % ear in ln][0]
        gains = dict(re.findall(r'"Gain (\d)" = ([0-9.]+)', line))
        assert len(gains) == 8
        slot = re.search(r'"convLFE_%s:Out" input = "mix%s:In (\d)"' % (ear, ear), text).group(1)
        for k, v in gains.items():
            assert float(v) == (0.25 if k == slot else 0.5)


def test_output_is_pinned_and_never_the_default():
    text = render()
    playback = text[text.index("playback.props"):]
    assert 'target.object      = "%s"' % SINK_HEADPHONES in playback
    assert "node.dont-fallback = true" in playback
    assert "node.linger        = true" in playback
    assert "node.passive       = true" in playback
    capture = text[text.index("capture.props"):text.index("playback.props")]
    assert 'node.name        = "x20test-a"' in capture
    assert "media.class      = Audio/Sink" in capture
    assert "audio.position   = [ FL FR FC LFE RL RR SL SR ]" in capture
    assert "priority.session = 1" in capture


def test_ceiling_stage_is_last():
    text = render(ceiling=0.5)
    assert text.count("label = clamp") == 2
    assert '"Min" = -0.5000 "Max" = 0.5000' in text
    assert 'outputs = [ "limL:Out" "limR:Out" ]' in text
    for ear in "LR":
        assert '{ output = "mix%s:Out" input = "lim%s:In" }' % (ear, ear) in text


def test_is_a_complete_config_with_balanced_brackets():
    text = render()
    for opener, closer in ("{}", "[]"):
        assert text.count(opener) == text.count(closer)
    for module in ("protocol-native", "client-node", "adapter", "filter-chain"):
        assert "libpipewire-module-%s" % module in text


def test_rejects_bad_input():
    with pytest.raises(ValueError):
        render(wav="relative/a.wav")
    with pytest.raises(ValueError):
        render(description='say "hi"')
    with pytest.raises(ValueError):
        render(ceiling=1.5)


def test_manifest_describe_add_find_report(tmp_path, hrir_file):
    entry = manifest.describe(hrir_file, "syn-full", set="syn", form="full", licence="CC0-1.0")
    assert entry["sha256"] == manifest.sha256(hrir_file)
    assert entry["status"] in ("PASS", "WARN")
    assert [c["name"] for c in entry["checks"]] == ["routing", "headroom", "symmetry", "centre"]
    data = manifest.empty()
    stored = manifest.add(data, entry, str(tmp_path))
    assert stored["file"] == "set.wav"  # relative to the manifest
    manifest.add(data, dict(entry, trim_db=1.0), str(tmp_path))  # replace, not duplicate
    assert len(data["candidates"]) == 1 and manifest.find(data, "syn-full")["trim_db"] == 1.0
    assert manifest.resolve(stored, str(tmp_path)) == hrir_file
    path = str(tmp_path / "manifest.json")
    manifest.save(path, data)
    assert manifest.load(path) == data
    text = manifest.report(data)
    assert "syn-full" in text and "CC0-1.0" in text and "routing" in text
    with pytest.raises(manifest.CandidateError):
        manifest.find(data, "nope")


def test_candidate_must_be_14_channels_at_48k(tmp_path):
    p = str(tmp_path / "stereo.wav")
    wav.write(p, RATE, [[1.0], [1.0]])
    with pytest.raises(manifest.CandidateError, match="2 channels"):
        manifest.read_hrir(p)
    p = str(tmp_path / "44.wav")
    wav.write(p, 44100, [[1.0]] * 14)
    with pytest.raises(manifest.CandidateError, match="44100 Hz"):
        manifest.read_hrir(p)
    with pytest.raises(manifest.CandidateError):
        manifest.read_hrir(str(tmp_path / "missing.wav"))


def run_tool(*args):
    return subprocess.run([sys.executable, TOOL] + list(args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True)


def test_tool_dry_check_add_report_conf(tmp_path, hrir_file):
    dry = str(tmp_path / "dry.wav")
    assert run_tool("dry", hrir_file, dry).returncode == 0
    r = run_tool("check", hrir_file, dry)
    assert r.returncode == 0 and "routing   PASS" in r.stdout
    man = str(tmp_path / "manifest.json")
    assert run_tool("add", "--manifest", man, "--id", "syn-full", "--set", "syn", "--form",
                    "full", "--licence", "CC0-1.0", hrir_file).returncode == 0
    assert run_tool("add", "--manifest", man, "--id", "syn-dry", dry).returncode == 0
    assert [c["id"] for c in json.load(open(man))["candidates"]] == ["syn-full", "syn-dry"]
    assert "syn-dry" in run_tool("report", "--manifest", man).stdout
    r = run_tool("conf", "--manifest", man, "--id", "syn-full", "--target", "hw", "--node",
                 "x20test-b", "--description", "Surround test B")
    assert r.returncode == 0 and 'filename = "%s"' % hrir_file in r.stdout
    assert 'target.object      = "hw"' in r.stdout


def test_tool_reports_failures(tmp_path, channels):
    bad = str(tmp_path / "bad.wav")
    wav.write(bad, RATE, channels[:7] + channels[8:] + [channels[7]])
    r = run_tool("check", bad)
    assert r.returncode == 1 and "routing   FAIL" in r.stdout
    r = run_tool("check", str(tmp_path / "missing.wav"))
    assert r.returncode == 2 and "hrir_tool:" in r.stderr


def test_tool_speakers_sweep(tmp_path, hrir_file):
    man = str(tmp_path / "manifest.json")
    assert run_tool("add", "--manifest", man, "--id", "win", hrir_file).returncode == 0
    r = run_tool("speakers", "--manifest", man, "--id", "win", "--delays", "60,90",
                 "--strengths", "0.3")
    assert r.returncode == 0, r.stderr
    assert [ln.split()[0] for ln in r.stdout.splitlines()] == [
        "win-speakers", "win-xtc-d060-s30", "win-xtc-d090-s30"]
    cands = {c["id"]: c for c in json.load(open(man))["candidates"]}
    assert cands["win-xtc-d090-s30"]["device"] == "speakers"
    assert "device" not in cands["win"]
    assert os.path.isfile(str(tmp_path / "win-xtc-d090-s30.wav"))
    r = run_tool("speakers", "--manifest", man, "--id", "win", "--delays", "abc")
    assert r.returncode == 2 and "not a list of numbers" in r.stderr
