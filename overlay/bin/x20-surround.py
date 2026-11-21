#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""x20-surround: virtual 7.1 surround for the ROG Xbox Ally X20's built-in
headphone jack and speakers (component surround, docs/surround.md).

usage: x20-surround COMMAND

  run                       the user service: keep the right filter running
  status                    settings, the output in use, what is running
  list                      the profiles
  set PROFILE [--device headphones|speakers]
                            choose a profile for an output (default: the
                            output in use); takes effect within a second
  conf PROFILE --device D   print the PipeWire config a profile would use

A profile is "stereo" (no filter: the hardware output as it is), one of the
shipped head-related impulse response sets (each as "-dry" and "-full"), or
"user": the first .wav file,
in lexical order, in ~/.config/ally-x20-steamos/surround-user/. A "user"
profile without a usable file falls back to the output's default.

How it works. `run` looks at PipeWire every few seconds. For the built-in
output in use (the headphones when the jack reports them plugged in, the
speakers otherwise) it runs one `pipewire -c <generated config>` process: a
filter-chain sink with 8 channels that convolves each channel with the
profile's 14-channel HeSuVi file and plays the result on that output. The
sink's session priority is one above the hardware sink's, so WirePlumber
makes it the default exactly when it would have picked that hardware sink,
and a game that opens its stream on the default output sends 7.1. Nothing is
written to ~/.config/pipewire and no default is forced: an output picked by
hand in Steam (Bluetooth, HDMI, or the plain built-in one) still wins.

Standard library only; the device has no numpy.
"""

import argparse
import json
import math
import os
import signal
import struct
import subprocess
import sys
import time

NAME = "ally-x20-steamos"
DEVICES = ("headphones", "speakers")
STEREO = "stereo"
USER = "user"
# id -> (file, level trim in dB, description). The trims make a profile as
# loud as the plain stereo downmix: the offline estimate of
# tools/surround-test plus the correction measured on an X20 on 2026-11-20.
BUILTIN = {
    "sadie-d2-dry": ("sadie-d2-dry.wav", -1.10, "KEMAR mannequin, SADIE II (University of York)"),
    "hutubs-pp1-dry": ("hutubs-pp1-dry.wav", -1.69, "FABIAN mannequin, HUTUBS subject pp1 (TU Berlin)"),
    "mit-kemar-dry": ("mit-kemar-dry.wav", -5.03, "KEMAR mannequin, normal ears (MIT)"),
    "mit-kemar-large-dry": ("mit-kemar-large-dry.wav", -6.70, "KEMAR mannequin, large ears (MIT)"),
    "sadie-d2-full": ("sadie-d2-full.wav", -0.85, "KEMAR mannequin, SADIE II (University of York)"),
    "hutubs-pp1-full": ("hutubs-pp1-full.wav", -1.52, "FABIAN mannequin, HUTUBS subject pp1 (TU Berlin)"),
    "mit-kemar-full": ("mit-kemar-full.wav", -4.67, "KEMAR mannequin, normal ears (MIT)"),
    "mit-kemar-large-full": ("mit-kemar-large-full.wav", -6.42, "KEMAR mannequin, large ears (MIT)"),
}
# "-dry": front left, front right and centre pass through unfiltered, only
# the sides and rears are processed. "-full": every channel is processed.
PROFILES = (STEREO,
            "sadie-d2-dry", "hutubs-pp1-dry", "mit-kemar-dry", "mit-kemar-large-dry",
            "sadie-d2-full", "hutubs-pp1-full", "mit-kemar-full", "mit-kemar-large-full",
            USER)
DEFAULT = {"headphones": "sadie-d2-dry", "speakers": STEREO}

# The sink's channel order, and the HeSuVi order of the 14 channels in the
# file: (input channel, ear). Checked against PipeWire 1.6.8's
# sink-virtual-surround-7.1-hesuvi.conf.
INPUTS = ("FL", "FR", "FC", "LFE", "RL", "RR", "SL", "SR")
HESUVI = (("FL", "L"), ("FL", "R"), ("SL", "L"), ("SL", "R"), ("RL", "L"), ("RL", "R"),
          ("FC", "L"), ("FR", "R"), ("FR", "L"), ("SR", "R"), ("SR", "L"), ("RR", "R"),
          ("RR", "L"), ("FC", "R"))
RATE = 48000
CEILING = 0.891  # -1 dBFS
LFE_GAIN = 0.5
# node.name of the hardware sinks ends with these (the PCI address in front
# is not assumed), and the card's route names for the jack.
SINK_SUFFIX = {"headphones": "HiFi__Headphones__sink", "speakers": "HiFi__Speaker__sink"}
CARD_HINT = "amd_sdw"
HEADPHONE_ROUTE = "[Out] Headphones"
NODE = {"headphones": "ally_x20_surround_headphones", "speakers": "ally_x20_surround_speakers"}
DESCRIPTION = {"headphones": "Headphones (7.1 surround)", "speakers": "Speakers (7.1 surround)"}
USER_TRIM_RANGE = (-12.0, 3.0)
POLL = 2.0
MAX_TAPS = RATE  # a longer file is not an impulse response set


class Problem(Exception):
    """Something the user has to hear about; never a traceback."""


# -- paths -------------------------------------------------------------------
class Paths:
    def __init__(self, env=None):
        env = os.environ if env is None else env
        home = env.get("HOME") or os.path.expanduser("~")
        config = env.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
        self.config_dir = os.path.join(config, NAME)
        self.settings = os.path.join(self.config_dir, "surround.conf")
        self.user_dir = os.path.join(self.config_dir, "surround-user")
        runtime = env.get("XDG_RUNTIME_DIR") or os.path.join("/run/user", str(os.getuid()))
        self.runtime = os.path.join(runtime, NAME + "-surround")
        here = os.path.dirname(os.path.abspath(__file__))
        hrir = os.path.join(here, "hrir")  # installed: next to the helper
        if not os.path.isdir(hrir):  # run from a checkout (overlay/bin)
            hrir = os.path.join(here, os.pardir, "surround", "hrir")
        self.hrir = env.get("X20_SURROUND_HRIR") or os.path.normpath(hrir)


# -- settings ----------------------------------------------------------------
def read_settings(path):
    """{device: profile}; a missing file or a bad value gives the default."""
    chosen = dict(DEFAULT)
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return chosen
    for line in lines:
        key, sep, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if sep and key in DEVICES and value in PROFILES:
            chosen[key] = value
    return chosen


def write_settings(path, chosen):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("# Written by '%s surround set'. One profile per built-in output:\n" % NAME)
        f.write("# %s\n" % " | ".join(PROFILES))
        for device in DEVICES:
            f.write("%s=%s\n" % (device, chosen[device]))
    os.replace(tmp, path)


# -- the user's file ---------------------------------------------------------
def wav_info(path):
    """(channels, rate, frames, sample format, data offset) of a RIFF WAVE
    file, PCM 16/24/32-bit or 32-bit float, plain or WAVE_FORMAT_EXTENSIBLE."""
    with open(path, "rb") as f:
        head = f.read(12)
        if len(head) < 12 or head[:4] != b"RIFF" or head[8:12] != b"WAVE":
            raise Problem("not a WAV file")
        fmt = None
        while True:
            chunk = f.read(8)
            if len(chunk) < 8:
                raise Problem("no audio data in the file")
            tag, size = chunk[:4], struct.unpack("<I", chunk[4:])[0]
            if tag == b"fmt ":
                body = f.read(size)
                if len(body) < 16:
                    raise Problem("damaged WAV header")
                code, channels, rate, _, align, bits = struct.unpack("<HHIIHH", body[:16])
                if code == 0xFFFE and len(body) >= 26:
                    code = struct.unpack("<H", body[24:26])[0]
                fmt = (code, channels, rate, align, bits)
            elif tag == b"data":
                if fmt is None:
                    raise Problem("damaged WAV header")
                code, channels, rate, align, bits = fmt
                if code == 1 and bits in (16, 24, 32):
                    sample = "i%d" % bits
                elif code == 3 and bits == 32:
                    sample = "f32"
                else:
                    raise Problem("unsupported sample format (PCM 16/24/32-bit or 32-bit float)")
                if channels == 0 or align != channels * bits // 8:
                    raise Problem("damaged WAV header")
                return channels, rate, size // align, sample, f.tell()
            else:
                f.seek(size, os.SEEK_CUR)
            if size % 2:
                f.seek(1, os.SEEK_CUR)


def check_hrir(path):
    """Raise Problem unless `path` is a 14-channel 48 kHz impulse response
    set; return (frames, sample format, data offset)."""
    channels, rate, frames, sample, offset = wav_info(path)
    if channels != len(HESUVI):
        raise Problem("%d channel(s); a HeSuVi set has %d" % (channels, len(HESUVI)))
    if rate != RATE:
        raise Problem("%d Hz; the filter runs at %d Hz" % (rate, RATE))
    if not 0 < frames <= MAX_TAPS:
        raise Problem("%d sample(s) per channel; expected 1 to %d" % (frames, MAX_TAPS))
    return frames, sample, offset


def channel_energy(path, wanted):
    """Sum of squared samples of the given channels."""
    frames, sample, offset = check_hrir(path)
    width = {"i16": 2, "i24": 3, "i32": 4, "f32": 4}[sample]
    total = 0.0
    with open(path, "rb") as f:
        f.seek(offset)
        data = f.read(frames * width * len(HESUVI))
    for frame in range(frames):
        base = frame * width * len(HESUVI)
        for ch in wanted:
            raw = data[base + ch * width: base + (ch + 1) * width]
            if len(raw) < width:
                continue
            if sample == "f32":
                v = struct.unpack("<f", raw)[0]
            elif sample == "i24":
                v = int.from_bytes(raw, "little", signed=True) / 8388608.0
            else:
                v = int.from_bytes(raw, "little", signed=True) / float(1 << (width * 8 - 1))
            total += v * v
    return total


def user_trim_db(path):
    """A level trim for a file nobody measured: bring the energy a front
    channel puts into both ears to that of the plain stereo path (one ear,
    gain 1). Coarse (not frequency weighted) and limited to a sane range."""
    energy = channel_energy(path, (0, 1))  # FL -> left ear, FL -> right ear
    if not energy > 0.0 or not math.isfinite(energy):
        raise Problem("the front-left channels are silent")
    low, high = USER_TRIM_RANGE
    return min(max(-10.0 * math.log10(energy), low), high)


def user_file(paths):
    """The first .wav in lexical order in the user's directory, or None."""
    try:
        names = sorted(n for n in os.listdir(paths.user_dir) if n.lower().endswith(".wav"))
    except OSError:
        return None
    return os.path.join(paths.user_dir, names[0]) if names else None


def resolve(paths, device, profile):
    """What really plays for a chosen profile.

    Returns (effective profile, wav path or None, trim dB, note). `note`
    explains a fall-back and is None otherwise.
    """
    note = None
    if profile == USER:
        path = user_file(paths)
        if path is None:
            note = "no .wav file in %s" % paths.user_dir
        else:
            try:
                return USER, path, user_trim_db(path), None
            except (Problem, OSError) as e:
                note = "%s: %s" % (os.path.basename(path), e)
        profile = DEFAULT[device]
        note += "; using %s" % profile
    if profile == STEREO:
        return STEREO, None, 0.0, note
    name, trim, _ = BUILTIN[profile]
    path = os.path.join(paths.hrir, name)
    if not os.path.isfile(path):
        extra = "%s is missing; using %s" % (path, STEREO)
        return STEREO, None, 0.0, extra if note is None else note + "; " + extra
    return profile, path, trim, note


# -- the PipeWire config -----------------------------------------------------
def _plain(text):
    if any(ch in text for ch in '"\\\n'):
        raise Problem("unsupported character in %r" % text)
    return text


def render(device, profile, wav, target, trim_db, priority):
    """A complete config for `pipewire -c`: PipeWire 1.6.8's 7.1 HeSuVi
    virtual-surround graph plus a level trim, a hard ceiling on the output
    and the output pinned to one hardware sink (node.dont-fallback, so the
    sound never ends up on another sink; node.linger, because WirePlumber
    0.5 destroys a filter whose target is missing)."""
    for value in (profile, wav, target):
        _plain(value)
    gain = 10.0 ** (trim_db / 20.0)
    nodes = ["{ type = builtin label = copy name = copy%s }" % c for c in INPUTS]
    convs = [("conv%s_%s" % (c, ear), c, ear, i) for i, (c, ear) in enumerate(HESUVI)]
    for ear in ("L", "R"):  # the LFE through the centre pair
        convs.append(("convLFE_%s" % ear, "LFE", ear, HESUVI.index(("FC", ear))))
    for name, _, _, channel in convs:
        nodes.append('{ type = builtin label = convolver name = %s config = '
                     '{ filename = "%s" channel = %d } }' % (name, wav, channel))
    slot = {"L": 0, "R": 0}
    gains = {"L": [], "R": []}
    links = []
    for name, c, ear, _ in convs:
        slot[ear] += 1
        links.append('{ output = "copy%s:Out" input = "%s:In" }' % (c, name))
        links.append('{ output = "%s:Out" input = "mix%s:In %d" }' % (name, ear, slot[ear]))
        gains[ear].append('"Gain %d" = %.6f' % (slot[ear], gain * (LFE_GAIN if c == "LFE" else 1.0)))
    for ear in ("L", "R"):
        nodes.append("{ type = builtin label = mixer name = mix%s control = { %s } }"
                     % (ear, " ".join(gains[ear])))
        nodes.append('{ type = builtin label = clamp name = lim%s control = '
                     '{ "Min" = %.4f "Max" = %.4f } }' % (ear, -CEILING, CEILING))
        links.append('{ output = "mix%s:Out" input = "lim%s:In" }' % (ear, ear))
    pad = " " * 20
    description = DESCRIPTION[device]
    return "".join([
        "# Generated by %s (component surround); do not edit.\n" % NAME,
        "# output: %s  profile: %s\n# hrir: %s\n# target: %s\n" % (device, profile, wav, target),
        "context.properties = {\n    log.level = 2\n}\n",
        "context.spa-libs = {\n",
        "    audio.convert.* = audioconvert/libspa-audioconvert\n",
        "    support.*       = support/libspa-support\n}\n",
        "context.modules = [\n",
        "    { name = libpipewire-module-rt\n        args = { }\n",
        "        flags = [ ifexists nofail ]\n    }\n",
        "    { name = libpipewire-module-protocol-native }\n",
        "    { name = libpipewire-module-client-node }\n",
        "    { name = libpipewire-module-adapter }\n",
        "    { name = libpipewire-module-filter-chain\n        args = {\n",
        '            node.description = "%s"\n' % description,
        '            media.name       = "%s"\n' % description,
        "            filter.graph = {\n                nodes = [\n",
        "".join(pad + line + "\n" for line in nodes),
        "                ]\n                links = [\n",
        "".join(pad + line + "\n" for line in links),
        "                ]\n",
        "                inputs  = [ %s ]\n" % " ".join('"copy%s:In"' % c for c in INPUTS),
        '                outputs = [ "limL:Out" "limR:Out" ]\n            }\n',
        "            capture.props = {\n",
        '                node.name        = "%s"\n' % NODE[device],
        '                node.description = "%s"\n' % description,
        "                media.class      = Audio/Sink\n",
        "                audio.channels   = %d\n" % len(INPUTS),
        "                audio.position   = [ %s ]\n" % " ".join(INPUTS),
        "                priority.session = %d\n" % priority,
        "                priority.driver  = %d\n" % priority,
        "            }\n            playback.props = {\n",
        '                node.name          = "%s.output"\n' % NODE[device],
        '                node.description   = "%s output"\n' % description,
        "                node.passive       = true\n",
        "                audio.channels     = 2\n",
        "                audio.position     = [ FL FR ]\n",
        '                target.object      = "%s"\n' % target,
        "                node.dont-fallback = true\n",
        "                node.linger        = true\n",
        "            }\n        }\n    }\n]\n",
    ])


# -- PipeWire's state --------------------------------------------------------
def pw_dump():
    """The objects `pw-dump` prints, or None when PipeWire cannot be asked."""
    try:
        out = subprocess.run(["pw-dump"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    try:
        data = json.loads(out.stdout.decode("utf-8", "replace"))
    except ValueError:
        return None
    return data if isinstance(data, list) else None


def look(objects):
    """What matters in a pw-dump: {"sinks": {device: (node.name, priority)},
    "headphones_plugged": bool, "running": set of our sink names}."""
    sinks, running = {}, set()
    plugged = False
    for o in objects or ():
        kind = str(o.get("type", ""))
        info = o.get("info") or {}
        props = info.get("props") or {}
        if kind.endswith(":Node"):
            name = str(props.get("node.name") or "")
            if props.get("media.class") == "Audio/Sink":
                for device, suffix in SINK_SUFFIX.items():
                    if name.endswith(suffix) and CARD_HINT in name:
                        try:
                            priority = int(props.get("priority.session") or 0)
                        except (TypeError, ValueError):
                            priority = 0
                        sinks[device] = (name, priority)
                if name in NODE.values():
                    running.add(name)
        elif kind.endswith(":Device") and CARD_HINT in str(props.get("device.name") or ""):
            for route in (info.get("params") or {}).get("EnumRoute") or ():
                if route.get("name") == HEADPHONE_ROUTE and route.get("available") == "yes":
                    plugged = True
    return {"sinks": sinks, "headphones_plugged": plugged, "running": running}


def active_device(state):
    """The built-in output in use: headphones when the jack reports them and
    their sink exists, else the speakers when their sink exists, else None."""
    if state["headphones_plugged"] and "headphones" in state["sinks"]:
        return "headphones"
    if "speakers" in state["sinks"]:
        return "speakers"
    return None


def plan(paths, state):
    """What should run now: None, or (device, effective profile, wav, trim,
    target node.name, priority, wav mtime). Also returns the note of a
    fall-back."""
    device = active_device(state)
    if device is None:
        return None, None
    chosen = read_settings(paths.settings)[device]
    profile, wav, trim, note = resolve(paths, device, chosen)
    if profile == STEREO:
        return None, note
    target, priority = state["sinks"][device]
    try:
        stamp = os.path.getmtime(wav)  # a replaced file restarts the filter
    except OSError:
        stamp = 0.0
    return (device, profile, wav, round(trim, 2), target, priority + 1, stamp), note


# -- the service -------------------------------------------------------------
def say(text):
    print("%s-surround: %s" % (NAME, text), file=sys.stderr, flush=True)


class Runner:
    """Keeps at most one filter process: the one `plan` asks for."""

    def __init__(self, paths, spawn=None, dump=pw_dump):
        self.paths = paths
        self.spawn = spawn or self._spawn
        self.dump = dump
        self.proc = None
        self.want = None
        self.last_note = None
        self.started_at = 0.0
        self.failures = 0

    def _spawn(self, conf_path):
        return subprocess.Popen(["pipewire", "-c", conf_path], stdin=subprocess.DEVNULL)

    def stop(self):
        proc, self.proc = self.proc, None
        if proc is None:
            return
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    def step(self, now=None):
        """One look at PipeWire and one correction. Returns the plan."""
        now = time.time() if now is None else now
        objects = self.dump()
        if objects is None:
            # PipeWire is not there (yet, or restarting): a filter that is
            # still running belongs to the old instance.
            if self.proc is not None:
                say("PipeWire does not answer; stopping the filter")
                self.stop()
                self.want = None
            return None
        want, note = plan(self.paths, look(objects))
        if note != self.last_note:
            if note:
                say(note)
            self.last_note = note
        died = self.proc is not None and self.proc.poll() is not None
        if died:
            self.proc = None
            self.failures += 1
            say("the filter process ended (%d time(s))" % self.failures)
        if want == self.want and self.proc is not None:
            if now - self.started_at > 30:
                self.failures = 0
            return want
        if want != self.want:
            self.failures = 0
        self.stop()
        self.want = want
        if want is None:
            return None
        # A filter that keeps dying is retried ever more slowly, never in a
        # tight loop.
        if self.failures and now - self.started_at < min(60, 2 ** self.failures):
            return want
        device, profile, wav, trim, target, priority, _ = want
        os.makedirs(self.paths.runtime, exist_ok=True)
        conf_path = os.path.join(self.paths.runtime, "%s.conf" % device)
        with open(conf_path, "w") as f:
            f.write(render(device, profile, wav, target, trim, priority))
        self.proc = self.spawn(conf_path)
        self.started_at = now
        say("%s: %s (%s, trim %+.2f dB) on %s" % (device, profile, os.path.basename(wav),
                                                 trim, target))
        return want


class _Stop(Exception):
    pass


def _raise_stop(_signum, _frame):
    raise _Stop()


def cmd_run(args, paths):
    runner = Runner(paths)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, _raise_stop)
    say("started; settings in %s" % paths.settings)
    try:
        while True:
            try:
                runner.step()
            except (Problem, OSError) as e:
                say(str(e))
            time.sleep(POLL)
    except _Stop:
        pass
    finally:
        runner.stop()
    return 0


# -- commands ----------------------------------------------------------------
def describe(profile):
    if profile == STEREO:
        return "no filter: the output as it is"
    if profile == USER:
        return "your own 14-channel 48 kHz HeSuVi file"
    form = "fronts unfiltered" if profile.endswith("-dry") else "every channel filtered"
    return "%s; %s" % (BUILTIN[profile][2], form)


def cmd_list(args, paths):
    for profile in PROFILES:
        marks = [d for d in DEVICES if DEFAULT[d] == profile]
        print("%-21s %s%s" % (profile, describe(profile),
                              "  (default for %s)" % " and ".join(marks) if marks else ""))
    print("")
    print("-dry: stereo material sounds as without the filter. -full: sounds are easier")
    print("to place, and everything is coloured by the filter.")
    print("user: the first .wav in lexical order in %s" % paths.user_dir)
    return 0


def cmd_status(args, paths):
    chosen = read_settings(paths.settings)
    objects = pw_dump()
    state = look(objects) if objects is not None else None
    active = active_device(state) if state else None
    for device in DEVICES:
        profile, wav, trim, note = resolve(paths, device, chosen[device])
        line = "%-10s %s" % (device, chosen[device])
        if profile != chosen[device]:
            line += " -> %s" % profile
        if wav:
            line += "  (%s, trim %+.2f dB)" % (os.path.basename(wav), trim)
        if device == active:
            line += "  [in use]"
        print(line)
        if note:
            print("           note: %s" % note)
    if state is None:
        print("PipeWire does not answer; cannot tell which output is in use")
        return 0
    if active is None:
        print("no built-in output found in PipeWire")
    for device in DEVICES:
        if NODE[device] in state["running"]:
            print("running: %s" % DESCRIPTION[device])
    if not state["running"]:
        print("running: no filter (plain stereo)")
    path = user_file(paths)
    print("user file: %s" % (path or "none in %s" % paths.user_dir))
    return 0


def cmd_set(args, paths):
    device = args.device
    if device is None:
        objects = pw_dump()
        device = active_device(look(objects)) if objects is not None else None
        if device is None:
            raise Problem("cannot tell which output is in use; add --device headphones|speakers")
    chosen = read_settings(paths.settings)
    chosen[device] = args.profile
    write_settings(paths.settings, chosen)
    profile, wav, trim, note = resolve(paths, device, args.profile)
    print("%s: %s%s" % (device, args.profile,
                         "" if profile == args.profile else " -> %s" % profile))
    if note:
        print("note: %s" % note)
    print("Takes effect within a few seconds while the surround service runs. A game")
    print("that is already running keeps its stream: restart it to go from stereo to 7.1.")
    return 0


def cmd_conf(args, paths):
    profile, wav, trim, note = resolve(paths, args.device, args.profile)
    if profile == STEREO:
        raise Problem("%s needs no filter%s" % (STEREO, " (%s)" % note if note else ""))
    sys.stdout.write(render(args.device, profile, wav, args.target, trim, args.priority))
    return 0


def parser():
    ap = argparse.ArgumentParser(prog="x20-surround", description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True
    sub.add_parser("run").set_defaults(fn=cmd_run)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    p = sub.add_parser("set")
    p.add_argument("profile", choices=PROFILES)
    p.add_argument("--device", choices=DEVICES)
    p.set_defaults(fn=cmd_set)
    p = sub.add_parser("conf")
    p.add_argument("profile", choices=PROFILES)
    p.add_argument("--device", choices=DEVICES, required=True)
    p.add_argument("--target", default="TARGET")
    p.add_argument("--priority", type=int, default=1)
    p.set_defaults(fn=cmd_conf)
    return ap


def main(argv=None, paths=None):
    args = parser().parse_args(argv)
    if os.geteuid() == 0 and not os.environ.get("X20_SURROUND_ALLOW_ROOT"):
        print("x20-surround: run this as your own user, not with sudo: the settings and"
              " PipeWire belong to the user", file=sys.stderr)
        return 1
    try:
        return args.fn(args, paths or Paths())
    except Problem as e:
        print("x20-surround: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
