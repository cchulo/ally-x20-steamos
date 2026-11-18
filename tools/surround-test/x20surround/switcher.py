# SPDX-License-Identifier: GPL-2.0-only
"""surround-test: the on-device switcher for the blind listening tests.

usage: surround-test COMMAND [options]

  doctor [--measure]    show tools, sinks and candidates; --measure plays
                        impulses into the MUTED hardware sink (silent) and
                        compares the raw 7.1 downmix with the expected one
  list                  list the candidates
  add-user FILE         add a local 14-channel 48 kHz HRIR file as candidate
                        "user" (checked like the others; never uploaded)
  speakers-from ID      make the speaker candidates from one headphone
                        candidate (the winner): the set as it is plus a
                        sweep of side/rear crosstalk cancellation
  calibrate             measure every candidate against raw on the muted
                        hardware sink (silent) and store the correction
  localise              blind localisation test (single-channel call-outs)
  tone (--file F|--live)
                        blind A/B preference against raw
  results               summarise the log and apply the pass rule
  restore               put volumes and the default sink back after a crash

common options:
  --device headphones|speakers   which hardware sink (default headphones)
  --target NODE                  another sink by node.name (USB, Bluetooth)
  --candidates ID[,ID...]        only these (default: all for the device)
  --volume V                     starting volume 0..0.8 (default 0.35)
  --open                         not blind: show the candidate names
  --repeats N                    localise: call-outs per direction (default 2)
  --rounds N                     tone: rounds per candidate (default 3)
  --seed N                       fixed random order (tests)

While a test runs the hardware sink is held at 100 % under whichever
candidate is playing, every candidate is level-matched to raw, and the
previous volume, mute state and default sink are restored on exit. Standard
library only.
"""

import argparse
import datetime
import json
import os
import random
import signal
import sys
import time

from . import conf, dsp, manifest, scoring, signals, wav, xtc
from .layout import INPUTS, RAW_DOWNMIX, SINK_HEADPHONES, SINK_SPEAKERS, SPEAKERS
from .pw import TOOLS, Pw, PwError

START_VOLUME = 0.35
MAX_VOLUME = 0.8
VOLUME_STEP = 0.05
MATCH_TOLERANCE_DB = 0.5
NODE_PREFIX = "x20test-"
RAW = scoring.RAW
DEVICES = {"headphones": SINK_HEADPHONES, "speakers": SINK_SPEAKERS}


class Abort(Exception):
    pass


class Paths:
    def __init__(self, env=None):
        env = os.environ if env is None else env
        home = env.get("HOME", os.path.expanduser("~"))
        self.share = env.get("X20_SURROUND_HOME") or os.path.join(
            env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share"), "x20-surround-test")
        self.state = env.get("X20_SURROUND_STATE") or os.path.join(
            env.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state"),
            "x20-surround-test")
        self.runtime = os.path.join(env.get("XDG_RUNTIME_DIR") or "/tmp", "x20-surround-test")
        self.manifest = os.path.join(self.share, "manifest.json")
        self.hrir = os.path.join(self.share, "hrir")
        self.log = os.path.join(self.state, "results.jsonl")
        self.restore = os.path.join(self.state, "restore.json")
        self.calibration = os.path.join(self.state, "calibration.json")


class IO:
    """Line-based prompts, so the tests work over SSH and can be scripted."""

    def __init__(self, stdin=None, stdout=None):
        self.stdin = stdin or sys.stdin
        self.stdout = stdout or sys.stdout

    def say(self, text=""):
        self.stdout.write(text + "\n")
        self.stdout.flush()

    def ask(self, prompt):
        self.stdout.write(prompt)
        self.stdout.flush()
        line = self.stdin.readline()
        if not line:
            raise Abort("input ended")
        return line.strip().lower()


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def append_log(path, record):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(record, sort_keys=True) + "\n")


def read_log(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def labels(count, rng):
    """Random single-letter labels."""
    letters = [chr(ord("A") + i) for i in range(26)]
    if count > len(letters):
        raise Abort("too many candidates for one session (%d)" % count)
    rng.shuffle(letters)
    return letters[:count]


def pick_candidates(data, device, wanted=None):
    """Candidates for a device, in manifest order. An entry without a
    "device" field is a headphone candidate; FAILed ones are left out
    unless asked for by id."""
    chosen = []
    for c in data["candidates"]:
        if wanted is not None:
            if c["id"] in wanted:
                chosen.append(c)
        elif c.get("device", "headphones") == device and c.get("status") != "FAIL":
            chosen.append(c)
    if wanted is not None:
        missing = [w for w in wanted if w not in [c["id"] for c in chosen]]
        if missing:
            raise Abort("no such candidate: %s" % ", ".join(missing))
    return chosen


class Session:
    """Candidate filters running next to the user's PipeWire, the hardware
    sink held at 100 % under them, and everything put back on stop()."""

    def __init__(self, paths, pw, io, target, device, candidates, volume=START_VOLUME,
                 blind=True, rng=None):
        self.paths, self.pw, self.io = paths, pw, io
        self.target, self.device = target, device
        self.candidates = candidates
        self.volume = min(max(volume, 0.0), MAX_VOLUME)
        self.blind = blind
        self.rng = rng or random.Random()
        self.id = "%s-%04x" % (datetime.datetime.now().strftime("%Y%m%dT%H%M%S"),
                               self.rng.randrange(0x10000))
        self.procs = {}
        self.nodes = {}
        self.ids = {}
        names = labels(len(candidates) + 1, self.rng)
        self.label = {RAW: names[0]}
        for cand, letter in zip(candidates, names[1:]):
            self.label[cand["id"]] = letter
        self.current = None
        self.started = False
        self.calibration = load_json(paths.calibration, {}).get(target, {})

    # -- set-up and tear-down ----------------------------------------------
    def extra_db(self, cand):
        entry = self.calibration.get(cand["id"])
        if entry and entry.get("sha256") == cand.get("sha256"):
            return entry.get("extra_db", 0.0)
        return 0.0

    def calibrated(self, cand):
        entry = self.calibration.get(cand["id"])
        return bool(entry and entry.get("sha256") == cand.get("sha256")
                    and abs(entry.get("residual_db", 99.0)) <= MATCH_TOLERANCE_DB)

    def start(self, mute_hardware=False):
        hw = self.pw.node(self.target)
        if not hw:
            raise Abort("sink %s not found (wrong --device, or nothing plugged in?)" % self.target)
        if os.path.exists(self.paths.restore):
            raise Abort("an earlier session did not finish: run `surround-test restore` first")
        self.ids[RAW] = hw["id"]
        vol, muted = self.pw.volume(hw["id"])
        os.makedirs(self.paths.runtime, exist_ok=True)
        save_json(self.paths.restore, {"target": self.target, "volume": vol, "muted": muted,
                                       "configured": self.pw.configured_default(), "pids": []})
        self.started = True
        for cand in self.candidates:
            self.start_candidate(cand)
        if mute_hardware:
            self.pw.set_mute(hw["id"], True)
        else:
            self.pw.set_mute(hw["id"], False)
        self.select(RAW)

    def start_candidate(self, cand, extra_db=None):
        cid = cand["id"]
        letter = self.label[cid]
        node = NODE_PREFIX + letter.lower()
        gain = dsp.from_db(cand["trim_db"] + (self.extra_db(cand) if extra_db is None
                                              else extra_db))
        path = manifest.resolve(cand, self.paths.share)
        text = conf.render(letter if self.blind else cid, node, "Surround test %s" % letter,
                           path, self.target, gain=gain)
        conf_path = os.path.join(self.paths.runtime, "%s.conf" % node)
        with open(conf_path, "w") as f:
            f.write(text)
        log = open(os.path.join(self.paths.runtime, "%s.log" % node), "w")
        proc = self.pw.start_filter(conf_path, log=log)
        self.procs[cid] = proc
        self.nodes[cid] = node
        state = load_json(self.paths.restore, {})
        state.setdefault("pids", []).append(proc.pid)
        save_json(self.paths.restore, state)
        found = self.pw.wait_node(node, proc=proc)
        if not found:
            raise Abort("candidate %s did not start (see %s)" % (
                letter if self.blind else cid, log.name))
        self.ids[cid] = found["id"]

    def stop_candidate(self, cid):
        proc = self.procs.pop(cid, None)
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:  # noqa: BLE001 - subprocess.TimeoutExpired
                proc.kill()

    def stop(self):
        if not self.started:
            return
        self.started = False
        restore(self.paths, self.pw, quiet=True)
        for cid in list(self.procs):
            self.stop_candidate(cid)

    # -- switching ----------------------------------------------------------
    def check_alive(self, cid):
        if cid != RAW and self.procs[cid].poll() is not None:
            raise Abort("a candidate filter stopped; ending the session")

    def select(self, cid):
        """Make `cid` the playing condition. The hardware sink is never at
        100 % while it is the default itself: the quiet step comes first."""
        self.check_alive(cid)
        hw = self.ids[RAW]
        if cid == RAW:
            self.pw.set_volume(hw, self.volume)
            self.pw.set_configured_default(self.target)
        else:
            self.pw.set_volume(self.ids[cid], self.volume)
            self.pw.set_configured_default(self.nodes[cid])
            self.pw.set_volume(hw, 1.0)
        self.current = cid

    def play_target(self, cid):
        return self.target if cid == RAW else self.nodes[cid]

    def nudge(self, sign):
        self.volume = min(max(self.volume + sign * VOLUME_STEP, 0.05), MAX_VOLUME)
        self.pw.set_volume(self.ids[self.current], self.volume)
        self.io.say("volume %.2f" % self.volume)

    def name(self, cid):
        """What the listener may see."""
        return self.label[cid] if self.blind else "%s (%s)" % (self.label[cid], cid)

    def play_blocking(self, path, cid, verify_channels=False):
        target = self.play_target(cid)
        self.check_alive(cid)
        if not self.pw.node(target):
            # pw-cat would fall back to the default sink without a word.
            raise Abort("sink %s disappeared; ending the session" % target)
        proc = self.pw.play(path, target=target)
        channels = None
        if verify_channels:
            deadline = time.time() + 3.0
            while time.time() < deadline and proc.poll() is None and channels is None:
                node = self.pw.node("x20test-stream")
                channels = node["channels"] if node else None
                if channels is None:
                    time.sleep(0.1)
        rc = proc.wait()
        if rc != 0:
            raise Abort("pw-cat could not play to %s (status %d)" % (self.play_target(cid), rc))
        return channels


def restore(paths, pw, quiet=False, io=None):
    """Put the hardware volume, mute state and default sink back and stop
    left-over candidate filters. Safe to run at any time."""
    state = load_json(paths.restore, None)
    if not state:
        if not quiet and io:
            io.say("nothing to restore")
        return False
    problems = []
    try:
        pw.set_configured_default(state.get("configured"))
    except PwError as e:
        problems.append(str(e))
    try:
        hw = pw.node(state["target"])
        if hw:
            pw.set_volume(hw["id"], state["volume"])
            pw.set_mute(hw["id"], bool(state.get("muted")))
        else:
            problems.append("sink %s is gone; its volume was not restored" % state["target"])
    except PwError as e:
        problems.append(str(e))
    for pid in state.get("pids", []):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    if problems:
        if io:
            io.say("restore: " + "; ".join(problems))
        return False
    os.remove(paths.restore)
    if not quiet and io:
        io.say("restored: %s volume %.2f%s, default sink %s" % (
            state["target"], state["volume"], " (muted)" if state.get("muted") else "",
            state.get("configured") or "automatic"))
    return True


# ---------------------------------------------------------------- commands --
def make_session(args, paths, pw, io):
    data = manifest.load(paths.manifest)
    target = args.target or DEVICES[args.device]
    wanted = args.candidates.split(",") if args.candidates else None
    cands = pick_candidates(data, args.device, wanted)
    if not cands:
        raise Abort("no candidates for %s in %s" % (args.device, paths.manifest))
    rng = random.Random(args.seed) if args.seed is not None else random.Random()
    return Session(paths, pw, io, target, args.device, cands, volume=args.volume,
                   blind=not args.open, rng=rng)


def base_record(session, test):
    return {"time": datetime.datetime.now().isoformat(timespec="seconds"), "session": session.id,
            "test": test, "device": session.device, "target": session.target,
            "blind": session.blind, "volume": round(session.volume, 2),
            "labels": dict(session.label),
            "level_matched": {c["id"]: session.calibrated(c) for c in session.candidates}}


def warn_uncalibrated(session, io):
    missing = [c["id"] for c in session.candidates if not session.calibrated(c)]
    if missing:
        io.say("NOTE: %d candidate(s) are level-matched by the offline estimate only; run"
               " `surround-test calibrate` first for the measured 0.5 dB match." % len(missing))


def cmd_localise(args, paths, pw, io):
    session = make_session(args, paths, pw, io)
    warn_uncalibrated(session, io)
    conds = [RAW] + [c["id"] for c in session.candidates]
    trials = [(cid, ch) for cid in conds for ch in SPEAKERS for _ in range(args.repeats)]
    session.rng.shuffle(trials)
    io.say("Localisation: %d call-outs over %d conditions (raw included, order random)."
           % (len(trials), len(conds)))
    io.say("After each call-out type where it came from:")
    io.say("    1 front-left    2 centre    3 front-right")
    io.say("    4 side-left                 5 side-right")
    io.say("    6 rear-left                 7 rear-right")
    io.say("r = replay, + / - = volume, q = stop early. Starting volume %.2f." % session.volume)
    answers = {cid: [] for cid in conds}
    record = base_record(session, "localise")
    complete = False
    try:
        session.start()
        files = {}
        for ch in SPEAKERS:
            files[ch] = os.path.join(paths.runtime, "callout-%s.wav" % ch)
            signals.callout(files[ch], ch)
        io.ask("Press Enter for the first call-out. ")
        stream_channels = None
        for n, (cid, ch) in enumerate(trials, 1):
            session.select(cid)
            got = session.play_blocking(files[ch], cid, verify_channels=stream_channels is None)
            if stream_channels is None:
                stream_channels = got
                if got != len(INPUTS):
                    raise Abort("the test stream has %s channels, not 8; stopping" % got)
            while True:
                prefix = "" if session.blind else "[%s] " % session.name(cid)
                ans = io.ask("%s%d/%d where? " % (prefix, n, len(trials)))
                if ans in scoring.ANSWERS:
                    answers[cid].append((ch, scoring.ANSWERS[ans]))
                    break
                if ans == "r":
                    session.play_blocking(files[ch], cid)
                elif ans in ("+", "-"):
                    session.nudge(1 if ans == "+" else -1)
                    session.play_blocking(files[ch], cid)
                elif ans == "q":
                    raise Abort("stopped by the listener")
                else:
                    io.say("1-7, r, +, - or q")
        complete = True
        record["stream_channels"] = stream_channels
    except (Abort, PwError) as e:
        io.say("localise: %s" % e)
    finally:
        session.stop()
    record["complete"] = complete
    record["volume"] = round(session.volume, 2)
    record["conditions"] = []
    for cid in conds:
        s = scoring.score(answers[cid])
        s.update({"id": cid, "label": session.label.get(cid, "?")})
        record["conditions"].append(s)
    record["trials"] = [[cid, p, a] for cid in conds for p, a in answers[cid]]
    if not record["trials"]:
        return 1  # nothing was heard: nothing to log
    append_log(paths.log, record)
    io.say("")
    io.say("%s. The labels were:" % ("Done" if complete else "Incomplete, not counted"))
    io.say("  label  condition                  hits   front/back  left/right")
    for c in sorted(record["conditions"], key=lambda c: c["label"]):
        io.say("  %-5s  %-25s %2d/%-2d  %5d      %5d" % (
            c["label"], c["id"], c["hits"], c["trials"], c["front_back"], c["left_right"]))
    io.say("Logged to %s (session %s)." % (paths.log, session.id))
    return 0 if complete else 1


class Looper:
    """Plays a file over and over on the default sink until stopped."""

    def __init__(self, pw, path):
        self.pw, self.path = pw, path
        self.proc = None

    def tick(self):
        if self.proc is None or self.proc.poll() is not None:
            self.proc = self.pw.play(self.path, name="x20test-material")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait()


def playing_streams(pw, wait=3.0):
    """[(node.name, channel count)] of the playback streams in the graph,
    the rig's own filter outputs left out. Waits a moment for a stream that
    is still starting."""
    end = time.time() + wait
    while True:
        found = [(name, n["channels"]) for name, n in sorted(pw.nodes().items())
                 if n["class"] == "Stream/Output/Audio" and not name.endswith(".output")]
        if (found and all(ch is not None for _, ch in found)) or time.time() >= end:
            return found
        time.sleep(0.2)


def cmd_tone(args, paths, pw, io):
    if not args.live and not args.file:
        raise Abort("tone needs --file FILE or --live")
    if args.file and not os.path.isfile(args.file):
        raise Abort("no such file: %s" % args.file)
    session = make_session(args, paths, pw, io)
    warn_uncalibrated(session, io)
    order = [c["id"] for c in session.candidates]
    session.rng.shuffle(order)
    io.say("Tone: %d pair(s), %d round(s) each. In every round \"1\" and \"2\" are raw and one"
           % (len(order), args.rounds))
    io.say("candidate in random order. Type 1 or 2 to switch, p1 / p2 for the one you prefer,")
    io.say("p0 for no preference, + / - for volume, q to stop early. Starting volume %.2f."
           % session.volume)
    if args.live:
        io.say("Live material: start the game (or player) now, on the DEFAULT output, and")
        io.say("keep it running; see the README for the game check.")
    rounds = {cid: [] for cid in order}
    record = base_record(session, "tone")
    record["material"] = "live" if args.live else os.path.basename(args.file)
    looper = None
    complete = False
    try:
        session.start()
        if args.file:
            looper = Looper(pw, args.file)
            looper.tick()
        io.ask("Press Enter when the material is playing. ")
        record["streams"] = playing_streams(pw)
        for name, channels in record["streams"]:
            io.say("stream %s: %s channel(s)" % (name, channels))
        if not any(ch == len(INPUTS) for _, ch in record["streams"]):
            io.say("NOTE: no 8-channel stream is playing; this compares tone on %s material."
                   % "/".join(sorted({str(ch) for _, ch in record["streams"]}) or ["no"]))
        for k, cid in enumerate(order, 1):
            for r in range(1, args.rounds + 1):
                pair = [RAW, cid]
                session.rng.shuffle(pair)
                at = 0
                session.select(pair[at])
                while True:
                    if looper:
                        looper.tick()
                    shown = "" if session.blind else " [%s]" % pair[at]
                    ans = io.ask("pair %d/%d round %d/%d, playing %d%s: "
                                 % (k, len(order), r, args.rounds, at + 1, shown))
                    if ans in ("1", "2"):
                        at = int(ans) - 1
                        session.select(pair[at])
                    elif ans in ("p1", "p2"):
                        picked = pair[int(ans[1]) - 1]
                        rounds[cid].append("raw" if picked == RAW else "candidate")
                        break
                    elif ans == "p0":
                        rounds[cid].append("none")
                        break
                    elif ans in ("+", "-"):
                        session.nudge(1 if ans == "+" else -1)
                    elif ans == "q":
                        raise Abort("stopped by the listener")
                    else:
                        io.say("1, 2, p1, p2, p0, +, - or q")
        complete = True
    except (Abort, PwError) as e:
        io.say("tone: %s" % e)
    finally:
        if looper:
            looper.stop()
        session.stop()
    record["complete"] = complete
    record["volume"] = round(session.volume, 2)
    record["conditions"] = []
    for cid in order:
        t = scoring.tone_tally(rounds[cid])
        t.update({"id": cid, "label": session.label.get(cid, "?")})
        record["conditions"].append(t)
    if not any(rounds.values()):
        return 1  # no round was judged: nothing to log
    append_log(paths.log, record)
    io.say("")
    io.say("%s. Preferences:" % ("Done" if complete else "Incomplete, not counted"))
    io.say("  candidate                  candidate  raw  no preference")
    for c in record["conditions"]:
        io.say("  %-25s  %5d   %5d  %5d" % (c["id"], c["candidate"], c["raw"], c["none"]))
    io.say("Logged to %s (session %s)." % (paths.log, session.id))
    return 0 if complete else 1


def measure(session, path, cid, tag):
    """Play `path` as condition `cid` and return the stereo recording of
    the hardware sink's monitor."""
    out = os.path.join(session.paths.runtime, "measure-%s.wav" % tag)
    rec = session.pw.record_monitor(session.target, out)
    time.sleep(0.8)
    try:
        session.play_blocking(path, cid)
        time.sleep(0.5)
    finally:
        rec.send_signal(signal.SIGINT)
        rec.wait()
    try:
        _, channels = wav.read(out)
    except (OSError, wav.WavError) as e:
        raise Abort("no recording from the monitor of %s: %s" % (session.target, e))
    if len(channels) < 2:
        raise Abort("the monitor recording is not stereo")
    return channels[0], channels[1]


def cmd_calibrate(args, paths, pw, io):
    args.open = True
    session = make_session(args, paths, pw, io)
    io.say("Calibration: noise through raw and every candidate into the MUTED sink %s;"
           % session.target)
    io.say("its monitor is recorded, nothing should be audible.")
    result = {}
    try:
        session.start(mute_hardware=True)
        noise = os.path.join(paths.runtime, "noise.wav")
        signals.noise(noise)
        session.select(RAW)
        raw = signals.loudness_db(*measure(session, noise, RAW, "raw"))
        if raw is None:
            raise Abort("the monitor of the muted sink is silent: this PipeWire applies mute "
                        "to the monitor, so the silent calibration cannot work here")
        io.say("raw: %.2f dB" % raw)
        for cand in session.candidates:
            cid = cand["id"]
            session.select(cid)
            session.pw.set_volume(session.ids[cid], 1.0)
            before = signals.loudness_db(*measure(session, noise, cid, "a"))
            if before is None:
                io.say("%-26s no signal reached the sink; skipped" % cid)
                continue
            extra = session.extra_db(cand) + (raw - before)
            session.select(RAW)
            session.stop_candidate(cid)
            session.start_candidate(cand, extra_db=extra)
            session.select(cid)
            session.pw.set_volume(session.ids[cid], 1.0)
            after = signals.loudness_db(*measure(session, noise, cid, "b"))
            residual = (after - raw) if after is not None else 99.0
            ok = abs(residual) <= MATCH_TOLERANCE_DB
            result[cid] = {"extra_db": round(extra, 3), "residual_db": round(residual, 3),
                           "sha256": cand.get("sha256"),
                           "time": datetime.datetime.now().isoformat(timespec="seconds")}
            io.say("%-26s was %+.2f dB against raw, correction %+.2f dB, now %+.2f dB  %s"
                   % (cid, before - raw, extra, residual, "ok" if ok else "NOT MATCHED"))
            session.select(RAW)
    except (Abort, PwError) as e:
        io.say("calibrate: %s" % e)
        return 1
    finally:
        session.stop()
    everything = load_json(paths.calibration, {})
    everything.setdefault(session.target, {}).update(result)
    save_json(paths.calibration, everything)
    bad = [cid for cid, r in result.items() if abs(r["residual_db"]) > MATCH_TOLERANCE_DB]
    io.say("Stored in %s." % paths.calibration)
    return 1 if bad or len(result) < len(session.candidates) else 0


def cmd_doctor(args, paths, pw, io):
    ok = True
    for tool in TOOLS:
        v = pw.version(tool)
        io.say("%-12s %s" % (tool, v or "MISSING"))
        ok = ok and v is not None
    io.say("python3      %d.%d.%d" % sys.version_info[:3])
    try:
        nodes = pw.nodes()
    except PwError as e:
        io.say("PipeWire is not reachable: %s" % e)
        return 1
    for device, name in sorted(DEVICES.items()):
        io.say("%-12s %s  %s" % (device, name, "present" if name in nodes else "NOT FOUND"))
    io.say("default sink %s (picked by hand: %s)" % (pw.default_sink(),
                                                     pw.configured_default() or "no, automatic"))
    stale = [n for n in nodes if n.startswith(NODE_PREFIX)]
    if stale or os.path.exists(paths.restore):
        io.say("left over from an earlier session: %s; run `surround-test restore`"
               % (", ".join(stale) or paths.restore))
        ok = False
    try:
        data = manifest.load(paths.manifest)
    except (OSError, ValueError) as e:
        io.say("manifest: %s" % e)
        return 1
    calibration = load_json(paths.calibration, {})
    io.say("%d candidate(s) in %s:" % (len(data["candidates"]), paths.manifest))
    for c in data["candidates"]:
        exists = os.path.isfile(manifest.resolve(c, paths.share))
        done = [t for t, entries in calibration.items() if c["id"] in entries]
        io.say("  %-26s %-10s %-4s trim %+6.2f dB  %s%s" % (
            c["id"], c.get("device", "headphones"), c.get("status", "?"), c["trim_db"],
            "calibrated" if done else "not calibrated", "" if exists else "  FILE MISSING"))
        ok = ok and exists
    if args.measure:
        ok = measure_raw(args, paths, pw, io) and ok
    return 0 if ok else 1


def measure_raw(args, paths, pw, io):
    """Silent check of layout.RAW_DOWNMIX on this machine."""
    target = args.target or DEVICES[args.device]
    session = Session(paths, pw, io, target, args.device, [], volume=args.volume)
    try:
        session.start(mute_hardware=True)
        path = os.path.join(paths.runtime, "impulses.wav")
        signals.impulses(path)
        got = signals.read_impulses(*measure(session, path, RAW, "raw"))
    except Abort as e:
        io.say("measure: %s" % e)
        return False
    finally:
        session.stop()
    if got is None:
        io.say("measure: nothing was recorded from the monitor of %s" % target)
        return False
    worst = 0.0
    io.say("raw 7.1 -> stereo downmix on %s (measured / expected):" % target)
    for c in INPUTS:
        want = RAW_DOWNMIX[c]
        worst = max(worst, abs(got[c][0] - want[0]), abs(got[c][1] - want[1]))
        io.say("  %-3s L %.3f / %.3f   R %.3f / %.3f" % (c, got[c][0], want[0], got[c][1], want[1]))
    io.say("largest difference %.3f: %s" % (worst, "matches" if worst < 0.01 else "DIFFERS"))
    return worst < 0.01


def cmd_list(args, paths, pw, io):
    io.say(manifest.report(manifest.load(paths.manifest)).rstrip("\n"))
    return 0


def cmd_add_user(args, paths, pw, io):
    data = manifest.load(paths.manifest) if os.path.exists(paths.manifest) else manifest.empty()
    os.makedirs(paths.hrir, exist_ok=True)
    channels = manifest.read_hrir(args.file)  # refuse before copying anything
    dest = os.path.join(paths.hrir, "%s.wav" % args.id)
    wav.write(dest, 48000, channels)
    entry = manifest.describe(dest, args.id, set=args.id, form="as-given",
                              licence="local file, not redistributable", source="user supplied")
    manifest.add(data, entry, paths.share)
    manifest.save(paths.manifest, data)
    io.say("%s: %s, level trim %+.2f dB" % (args.id, entry["status"], entry["trim_db"]))
    for r in entry["checks"]:
        io.say("  %-9s %-4s %s" % (r["name"], r["status"], r["detail"]))
    return 1 if entry["status"] == "FAIL" else 0


def cmd_speakers_from(args, paths, pw, io):
    data = manifest.load(paths.manifest)
    made = xtc.add_speaker_candidates(data, paths.share, args.id)
    manifest.save(paths.manifest, data)
    for entry in made:
        io.say("%-34s %s, level trim %+.2f dB" % (entry["id"], entry["status"], entry["trim_db"]))
    io.say("%d speaker candidate(s); test them with --device speakers (%d conditions with raw:"
           " pick a few with --candidates)." % (len(made), len(made) + 1))
    return 1 if any(e["status"] == "FAIL" for e in made) else 0


def cmd_results(args, paths, pw, io):
    records = read_log(paths.log)
    if not records:
        io.say("no results yet in %s" % paths.log)
        return 0
    io.say("Pass rule: a candidate must beat raw on localisation and not lose on tone, in "
           "two sessions on different days.")
    io.say("%d log record(s), %d complete." % (len(records),
                                               sum(1 for r in records if r.get("complete"))))
    verdicts = scoring.verdicts(records)
    for (device, cid) in sorted(verdicts):
        v = verdicts[(device, cid)]
        io.say("")
        io.say("%s on %s: %s (%d of %d day(s) needed)" % (
            cid, device, "PASS" if v["passed"] else "not passed",
            sum(v["days"].values()), scoring.REQUIRED_DAYS))
        for date in sorted(v["detail"]):
            day = v["detail"][date]
            loc, tone = day.get("localise"), day.get("tone")
            parts = []
            if loc:
                parts.append("localisation %d/%d against raw %d/%d" % loc)
            else:
                parts.append("no localisation test")
            if tone:
                parts.append("tone %d for it, %d for raw" % tone)
            else:
                parts.append("no tone test")
            io.say("  %s  %s  -> %s" % (date, "; ".join(parts),
                                         "counts" if v["days"][date] else "does not count"))
    return 0


def cmd_restore(args, paths, pw, io):
    return 0 if restore(paths, pw, io=io) or not os.path.exists(paths.restore) else 1


def parser():
    ap = argparse.ArgumentParser(prog="surround-test", description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True

    def common(p):
        p.add_argument("--device", choices=sorted(DEVICES), default="headphones")
        p.add_argument("--target")
        p.add_argument("--candidates")
        p.add_argument("--volume", type=float, default=START_VOLUME)
        p.add_argument("--open", action="store_true")
        p.add_argument("--seed", type=int)
        return p

    p = common(sub.add_parser("doctor"))
    p.add_argument("--measure", action="store_true")
    p.set_defaults(fn=cmd_doctor)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    p = sub.add_parser("add-user")
    p.add_argument("file")
    p.add_argument("--id", default="user")
    p.set_defaults(fn=cmd_add_user)
    p = sub.add_parser("speakers-from")
    p.add_argument("id")
    p.set_defaults(fn=cmd_speakers_from)
    common(sub.add_parser("calibrate")).set_defaults(fn=cmd_calibrate)
    p = common(sub.add_parser("localise"))
    p.add_argument("--repeats", type=int, default=2)
    p.set_defaults(fn=cmd_localise)
    p = common(sub.add_parser("tone"))
    p.add_argument("--file")
    p.add_argument("--live", action="store_true")
    p.add_argument("--rounds", type=int, default=3)
    p.set_defaults(fn=cmd_tone)
    sub.add_parser("results").set_defaults(fn=cmd_results)
    sub.add_parser("restore").set_defaults(fn=cmd_restore)
    return ap


def _raise_abort(signum, _frame):
    raise Abort("signal %d" % signum)


def main(argv=None, pw=None, io=None, paths=None):
    args = parser().parse_args(argv)
    paths = paths or Paths()
    pw = pw or Pw()
    io = io or IO()
    # A dropped SSH connection or a kill must still restore the volumes.
    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, _raise_abort)
        except (ValueError, OSError):
            pass
    try:
        return args.fn(args, paths, pw, io)
    except KeyboardInterrupt:
        io.say("interrupted")
        restore(paths, pw, quiet=True)
        return 130
    except (Abort, PwError, manifest.CandidateError, OSError, ValueError) as e:
        io.say("surround-test: %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
