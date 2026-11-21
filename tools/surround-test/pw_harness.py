#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""pw_harness.py - measure filter graphs in a headless PipeWire. No sound.

usage (through pw-harness.sh, which provides the D-Bus session):
  pw_harness.py raw
  pw_harness.py candidate HRIR.wav [--gain LINEAR]
  pw_harness.py pin HRIR.wav
  pw_harness.py ceiling
  pw_harness.py sofa SET.sofa RENDERED.wav

A private PipeWire and WirePlumber are started in a temporary runtime
directory, with null sinks standing in for the hardware. An 8-channel file
with one impulse per channel is played with pw-cat and the null sink's
monitor is recorded with pw-record, so what is compared is what PipeWire
really computes:

  raw        the 7.1 -> stereo downmix a stereo sink applies, against
             x20surround.layout.RAW_DOWNMIX
  candidate  a generated candidate conf, against the HRIR file itself:
             channel routing, gains and the LFE path, end to end
  pin        target.object + node.dont-fallback: with a higher-priority
             decoy sink present and the target absent, nothing may reach
             the decoy
  ceiling    the clamp stage holds the output at the configured ceiling
  sofa       PipeWire's own `sofa` spatializer (libmysofa) for the same set
             and angles, against the file render_sofa.py produced

Needs Linux with pipewire, wireplumber, pw-cat, pw-record, pw-cli and (for
`sofa`) the filter-chain sofa plugin; numpy for the comparison. Runs on a
development machine or CI, not on the device. Exit status 0 when the
comparison is within its tolerance, 1 otherwise, 2 on a setup problem.
"""

import argparse
import os
import shutil
import signal as _signal
import subprocess
import sys
import tempfile
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from x20surround import conf, dsp, forms, wav  # noqa: E402
from x20surround.layout import (AZIMUTH, EARS, INPUTS, MASK_71, RATE,  # noqa: E402
                                RAW_DOWNMIX, pairs)

AMPLITUDE = 0.5
FIRST = 1.0  # seconds before the first impulse
SPACING = 0.5  # seconds between impulses
TAIL = 1.0
HW = "harness-hw"
DECOY = "harness-decoy"


class SetupError(RuntimeError):
    pass


class Session:
    """A private PipeWire + WirePlumber, torn down on exit."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="x20-harness.")
        self.env = dict(os.environ, XDG_RUNTIME_DIR=self.tmp, PIPEWIRE_RUNTIME_DIR=self.tmp,
                        XDG_STATE_HOME=os.path.join(self.tmp, "state"),
                        XDG_CONFIG_HOME=os.path.join(self.tmp, "config"))
        self.procs = []

    def __enter__(self):
        for tool in ("pipewire", "wireplumber", "pw-cat", "pw-record", "pw-cli", "pw-dump"):
            if not shutil.which(tool):
                raise SetupError("%s not found" % tool)
        self.spawn(["pipewire"])
        self._wait(lambda: os.path.exists(os.path.join(self.tmp, "pipewire-0")), "pipewire")
        self.spawn(["wireplumber"])
        self._wait(lambda: "WirePlumber" in self.run(["pw-cli", "ls", "Client"]).stdout,
                   "wireplumber")
        time.sleep(1.0)
        return self

    def __exit__(self, *exc):
        for p in reversed(self.procs):
            if p.poll() is None:
                p.send_signal(_signal.SIGTERM)
        for p in self.procs:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def spawn(self, argv):
        log = open(os.path.join(self.tmp, "%s.%d.log" % (os.path.basename(argv[0]),
                                                          len(self.procs))), "w")
        p = subprocess.Popen(argv, env=self.env, stdout=log, stderr=subprocess.STDOUT)
        self.procs.append(p)
        return p

    def run(self, argv, **kw):
        return subprocess.run(argv, env=self.env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, universal_newlines=True, **kw)

    def _wait(self, test, what, timeout=20.0):
        end = time.time() + timeout
        while time.time() < end:
            if test():
                return
            time.sleep(0.1)
        raise SetupError("timed out waiting for %s\n%s" % (what, self.logs()))

    def logs(self, lines=15):
        out = []
        for name in sorted(os.listdir(self.tmp)):
            if name.endswith(".log"):
                with open(os.path.join(self.tmp, name), errors="replace") as f:
                    tail = f.readlines()[-lines:]
                out.append("--- %s\n%s" % (name, "".join(tail)))
        return "\n".join(out)

    def node_names(self):
        import json
        out = subprocess.run(["pw-dump"], env=self.env, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, universal_newlines=True).stdout
        try:
            objs = json.loads(out)
        except ValueError:
            return []
        return [o["info"]["props"].get("node.name") for o in objs
                if o.get("type", "").endswith("Node") and o.get("info")]

    def wait_node(self, name):
        self._wait(lambda: name in self.node_names(), "node %s" % name)

    def null_sink(self, name, priority=None):
        props = ("factory.name=support.null-audio-sink node.name=%s node.description=%s "
                 "media.class=Audio/Sink object.linger=true audio.position=[FL FR]" % (name, name))
        if priority is not None:
            props += " priority.session=%d priority.driver=%d" % (priority, priority)
        r = self.run(["pw-cli", "create-node", "adapter", "{ %s }" % props])
        if r.returncode != 0:
            raise SetupError("creating null sink %s failed: %s" % (name, r.stdout))
        self.wait_node(name)

    def start_conf(self, text, node):
        path = os.path.join(self.tmp, "%s.conf" % node)
        with open(path, "w") as f:
            f.write(text)
        self.spawn(["pipewire", "-c", path])
        self.wait_node(node)
        time.sleep(0.5)

    def measure(self, play_to, record_from, amplitude=AMPLITUDE, channels=INPUTS):
        """Play one impulse per input channel into `play_to`; return the
        recording of `record_from`'s monitor as an (n, 2) array."""
        src = os.path.join(self.tmp, "impulses.wav")
        out = os.path.join(self.tmp, "recording.wav")
        frames = int(RATE * (FIRST + SPACING * len(INPUTS) + TAIL))
        data = [[0.0] * frames for _ in INPUTS]
        for k, c in enumerate(INPUTS):
            if c in channels:
                data[k][int(RATE * (FIRST + SPACING * k))] = amplitude
        wav.write(src, RATE, data, MASK_71)
        rec = self.spawn(["pw-record", "--target", record_from, "-P",
                          "{ stream.capture.sink=true }", "--channels", "2", "--format", "f32",
                          "--rate", str(RATE), out])
        time.sleep(1.0)
        r = self.run(["pw-cat", "-p", "--target", play_to, src], timeout=60)
        if r.returncode != 0:
            raise SetupError("pw-cat failed: %s" % r.stdout)
        time.sleep(1.0)
        rec.send_signal(_signal.SIGINT)
        rec.wait(timeout=10)
        _, got = wav.read(out)
        return np.array(got, dtype=float).T


def template(responses, amplitude=AMPLITUDE):
    """The expected recording: responses is {input: (left, right)}."""
    length = max(len(h) for pair in responses.values() for h in pair)
    step = int(RATE * SPACING)
    out = np.zeros((step * len(INPUTS) + length, 2))
    for k, c in enumerate(INPUTS):
        for e in range(2):
            h = np.asarray(responses[c][e], dtype=float)
            out[k * step:k * step + len(h), e] += amplitude * h
    return out


def align(recording, expected):
    """Lag of `expected` inside `recording` (one lag for all channels)."""
    n = len(recording) + len(expected)
    size = 1 << (n - 1).bit_length()
    acc = np.zeros(size)
    for e in range(2):
        a = np.fft.rfft(recording[:, e], size)
        b = np.fft.rfft(expected[:, e], size)
        acc += np.fft.irfft(a * np.conj(b), size)
    lag = int(np.argmax(acc[:len(recording)]))
    return lag


def compare(recording, responses, fit_gain=False):
    """Return (rows, overall error dB, gain). rows: per input channel and
    ear, the residual in dB relative to the expected response."""
    expected = template(responses)
    lag = align(recording, expected)
    got = recording[lag:lag + len(expected)]
    if len(got) < len(expected):
        got = np.vstack([got, np.zeros((len(expected) - len(got), 2))])
    gain = 1.0
    if fit_gain:
        denom = float(np.sum(expected * expected))
        gain = float(np.sum(got * expected)) / denom if denom > 0 else 1.0
        expected = expected * gain
    step = int(RATE * SPACING)
    rows = []
    for k, c in enumerate(INPUTS):
        for e, ear in enumerate(EARS):
            want = expected[k * step:(k + 1) * step, e]
            have = got[k * step:(k + 1) * step, e]
            ref = float(np.sum(want * want))
            res = float(np.sum((have - want) ** 2))
            if ref <= 0.0:
                rows.append((c, ear, None if res < 1e-12 else float("inf"), want, have))
            else:
                rows.append((c, ear, dsp.db(res / ref), want, have))
    total_ref = float(np.sum(expected * expected))
    total = dsp.db(float(np.sum((got - expected) ** 2)) / total_ref) if total_ref > 0 else 0.0
    return rows, total, gain


def print_rows(rows):
    for c, ear, err, _, _ in rows:
        if err is None:
            text = "silent, as expected"
        elif err == float("inf"):
            text = "UNEXPECTED SIGNAL"
        else:
            text = "residual %6.1f dB" % err
        print("  %-3s -> %s  %s" % (c, ear, text))


def hrir_responses(channels, gain=1.0, lfe_gain=conf.LFE_GAIN):
    table = pairs(channels)
    out = {}
    for c in INPUTS:
        src = "FC" if c == "LFE" else c
        g = gain * (lfe_gain if c == "LFE" else 1.0)
        out[c] = tuple([g * v for v in table[(src, ear)]] for ear in EARS)
    return out


def cmd_raw(_args):
    with Session() as s:
        s.null_sink(HW)
        rec = s.measure(HW, HW)
    rows, total, _ = compare(rec, {c: ([RAW_DOWNMIX[c][0]], [RAW_DOWNMIX[c][1]]) for c in INPUTS})
    print("raw 7.1 -> stereo downmix against layout.RAW_DOWNMIX:")
    print_rows(rows)
    print("overall residual %.1f dB" % total)
    return 0 if total < -60.0 and all(r[2] != float("inf") for r in rows) else 1


def cmd_candidate(args):
    _, channels = wav.read(args.hrir)
    path = os.path.abspath(args.hrir)
    with Session() as s:
        s.null_sink(HW)
        s.start_conf(conf.render("harness", "harness-cand", "harness candidate", path, HW,
                                 gain=args.gain, ceiling=1.0), "harness-cand")
        rec = s.measure("harness-cand", HW)
    rows, total, _ = compare(rec, hrir_responses(channels, args.gain))
    print("candidate conf for %s (gain %.3f) against the file:" % (args.hrir, args.gain))
    print_rows(rows)
    print("overall residual %.1f dB" % total)
    return 0 if total < -60.0 and all(r[2] != float("inf") for r in rows) else 1


def cmd_pin(args):
    path = os.path.abspath(args.hrir)
    text = conf.render("harness", "harness-cand", "harness candidate", path, HW, ceiling=1.0)
    with Session() as s:
        # 1. Target absent, a better-ranked decoy present: the candidate
        #    must stay (unlinked) and nothing may reach the decoy.
        s.null_sink(DECOY, priority=2000)
        s.start_conf(text, "harness-cand")
        time.sleep(2.0)
        alive = "harness-cand" in s.node_names()
        print("target absent: candidate sink still present: %s" % ("yes" if alive else "NO"))
        leaked = 1.0
        if alive:
            rec = s.measure("harness-cand", DECOY)
            leaked = float(np.max(np.abs(rec))) if rec.size else 0.0
            print("target absent, decoy sink with priority 2000 present: peak on the decoy %.6f"
                  % leaked)
        # 2. The target appears: the output links to it, not to the decoy.
        s.null_sink(HW, priority=10)
        time.sleep(2.0)
        on_target = 0.0
        if "harness-cand" in s.node_names():
            rec = s.measure("harness-cand", HW)
            on_target = float(np.max(np.abs(rec))) if rec.size else 0.0
        print("target appeared later: peak on the target %.6f" % on_target)
    ok = alive and leaked < 1e-6 and on_target > 1e-3
    print("pinning %s" % ("holds" if ok else "FAILED"))
    return 0 if ok else 1


def cmd_ceiling(_args):
    tmp = tempfile.mkdtemp(prefix="x20-ceiling.")
    try:
        path = os.path.join(tmp, "unit.wav")
        table = {}
        for c in ("FL", "FR", "FC", "SL", "SR", "RL", "RR"):
            for ear in EARS:
                table[(c, ear)] = [1.0, 0.0, 0.0, 0.0]
        from x20surround.layout import unpairs
        wav.write(path, RATE, unpairs(table))
        with Session() as s:
            s.null_sink(HW)
            s.start_conf(conf.render("harness", "harness-cand", "harness candidate", path, HW,
                                     gain=2.0), "harness-cand")
            rec = s.measure("harness-cand", HW, amplitude=0.9)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    top = float(np.max(np.abs(rec)))
    print("input 0.9 x gain 2.0 = 1.8 without a ceiling; measured peak %.4f (ceiling %.4f)"
          % (top, conf.CEILING))
    ok = abs(top - conf.CEILING) < 0.002
    print("ceiling %s" % ("holds" if ok else "FAILED"))
    return 0 if ok else 1


_SOFA_CONF = """\
context.properties = { log.level = 2 }
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-rt args = { } flags = [ ifexists nofail ] }
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-filter-chain
        args = {
            node.description = "harness sofa"
            filter.graph = {
                nodes = [
%(nodes)s
                    { type = builtin label = mixer name = mixL }
                    { type = builtin label = mixer name = mixR }
                ]
                links = [
%(links)s
                ]
                inputs  = [ %(inputs)s ]
                outputs = [ "mixL:Out" "mixR:Out" ]
            }
            capture.props = {
                node.name = "harness-sofa" media.class = Audio/Sink
                audio.channels = 8 audio.position = [ FL FR FC LFE RL RR SL SR ]
                priority.session = 1
            }
            playback.props = {
                node.name = "harness-sofa.output" node.passive = true
                audio.channels = 2 audio.position = [ FL FR ]
                target.object = "%(target)s" node.dont-fallback = true
            }
        }
    }
]
"""


def sofa_conf(path, target):
    nodes, links = [], []
    for k, c in enumerate(INPUTS):
        azimuth = AZIMUTH["FC" if c == "LFE" else c] % 360.0
        nodes.append('                    { type = sofa label = spatializer name = sp%s '
                     'config = { filename = "%s" gain = 1.0 } '
                     'control = { "Azimuth" = %.1f "Elevation" = 0.0 "Radius" = 3.0 } }'
                     % (c, path, azimuth))
        links.append('                    { output = "sp%s:Out L" input = "mixL:In %d" }' % (c, k + 1))
        links.append('                    { output = "sp%s:Out R" input = "mixR:In %d" }' % (c, k + 1))
    return _SOFA_CONF % {"nodes": "\n".join(nodes), "links": "\n".join(links),
                         "inputs": " ".join('"sp%s:In"' % c for c in INPUTS), "target": target}


def band_difference(want, have):
    """Largest and mean absolute third-octave level difference, 200 Hz to
    8 kHz, between two responses (levels relative, gain already fitted)."""
    bands = dsp.third_octaves(190.0, 8100.0)
    a = dsp.band_powers([float(v) for v in want], bands, RATE)
    b = dsp.band_powers([float(v) for v in have], bands, RATE)
    diffs = [abs(dsp.db(x) - dsp.db(y)) for x, y in zip(a, b)]
    return max(diffs), sum(diffs) / len(diffs)


def cmd_sofa(args):
    _, channels = wav.read(args.rendered)
    with Session() as s:
        s.null_sink(HW)
        s.start_conf(sofa_conf(os.path.abspath(args.sofa), HW), "harness-sofa")
        rec = s.measure("harness-sofa", HW)
    # The spatializer has no LFE gain: every input gets the full response.
    rows, total, gain = compare(rec, hrir_responses(channels, 1.0, 1.0), fit_gain=True)
    print("PipeWire sofa spatializer for %s against %s" % (args.sofa, args.rendered))
    print("one common gain fitted: PipeWire is %+.2f dB relative to the rendered file"
          % dsp.amp_db(abs(gain)))
    print("  channel      residual   band level difference 200 Hz-8 kHz (max / mean)")
    worst_band = 0.0
    for c, ear, err, want, have in rows:
        if c == "LFE":
            continue
        top, mean = band_difference(want, have)
        worst_band = max(worst_band, top)
        print("  %-3s -> %s   %7.1f dB   %5.2f dB / %5.2f dB" % (c, ear, err, top, mean))
    print("overall residual %.1f dB, largest band difference %.2f dB" % (total, worst_band))
    ok = worst_band <= args.band_tolerance
    print("within %.1f dB per band: %s" % (args.band_tolerance, "yes" if ok else "NO"))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True
    sub.add_parser("raw").set_defaults(fn=cmd_raw)
    p = sub.add_parser("candidate")
    p.add_argument("hrir")
    p.add_argument("--gain", type=float, default=1.0)
    p.set_defaults(fn=cmd_candidate)
    p = sub.add_parser("pin")
    p.add_argument("hrir")
    p.set_defaults(fn=cmd_pin)
    sub.add_parser("ceiling").set_defaults(fn=cmd_ceiling)
    p = sub.add_parser("sofa")
    p.add_argument("sofa")
    p.add_argument("rendered")
    p.add_argument("--band-tolerance", type=float, default=1.0)
    p.set_defaults(fn=cmd_sofa)
    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except SetupError as e:
        print("pw_harness: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
