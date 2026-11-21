#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""x20-surround: virtual 7.1 surround for the ROG Xbox Ally X20's built-in
headphone jack and speakers (component surround, docs/surround.md).

usage: x20-surround COMMAND

  run                       the user service: keep the right filter running
  status                    settings, the output in use, what is running
  list                      the profiles
  set headphones|speakers PROFILE
                            choose the profile of one output; the output is
                            always named. Takes effect within seconds
  xtc off | xtc DELAY_US STRENGTH_PCT
                            crosstalk cancellation for the speakers
  prepare                   generate the tested crosstalk settings for the
                            speakers' profile and print their level and check
  conf PROFILE --device D   print the PipeWire config a profile would use

A profile is "stereo" (no filter: the hardware output as it is), one of the
shipped head-related impulse response sets (each as "-dry" and "-full"), or
"user": the first .wav file,
in lexical order, in ~/.config/ally-x20-steamos/surround-user/. A "user"
profile without a usable file falls back to the output's default.

Crosstalk cancellation ("xtc") is a second setting for the speakers only: a
delay in microseconds and a strength in percent. With it the speakers play a
variant of the profile's file that this helper derives itself (the x20dsp
package next to it) and keeps in ~/.cache/ally-x20-steamos/surround/. A
variant that fails the routing or symmetry check is not used; the profile
then plays as it is.

How it works. `run` looks at PipeWire every few seconds. For the built-in
output in use (the headphones when the jack reports them plugged in, the
speakers otherwise) it runs one `pipewire -c <generated config>` process: a
filter-chain sink with 8 channels that convolves each channel with the
profile's 14-channel HeSuVi file and plays the result on that output. The
sink's session priority is one or two above the hardware sink's, so
WirePlumber makes it the default exactly when it would have picked that
hardware sink, and a game that opens its stream on the default output sends
7.1. A change of profile starts the new filter under the other of two sink
names, waits until PipeWire shows it, and only then stops the old one.
Nothing is written to ~/.config/pipewire and no default is forced: an output
picked by hand in Steam (Bluetooth, HDMI, or the plain built-in one) still
wins.

Standard library only; the device has no numpy.
"""

import argparse
import collections
import hashlib
import json
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
DEFAULT = {"headphones": "sadie-d2-dry", "speakers": "sadie-d2-dry"}
# Crosstalk cancellation, speakers only: (delay in microseconds, strength in
# percent) or None for off. The default was picked by ear on an X20
# (docs/surround.md); the grid is what was listened to there.
DEFAULT_XTC = (60, 50)
XTC_KEY = "speakers_xtc"
XTC_DELAY_RANGE = (20, 300)
XTC_STRENGTH_RANGE = (5, 95)
XTC_GRID = tuple((d, s) for d in (60, 80, 100, 120) for s in (30, 50, 70))

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
# Two sink names per output: a change starts the new filter under the other
# name before the old one stops. Slot 0 is one above the hardware sink's
# priority, slot 1 two above, so the priority never creeps.
SLOTS = ("a", "b")
DESCRIPTION = {"headphones": "Headphones (7.1 surround)", "speakers": "Speakers (7.1 surround)"}
# Limits of a calculated level trim (the user's file, a generated variant):
# generous downwards, little gain upwards.
TRIM_RANGE = (-24.0, 3.0)
POLL = 2.0
# A hand-over: how often to look for the new sink, how long to wait for it,
# and the pause between seeing it and stopping the old filter (WirePlumber
# has to have seen it too).
HANDOVER_POLL = 0.2
HANDOVER_TIMEOUT = 10.0
HANDOVER_SETTLE = 0.5
# Bump when x20dsp changes what it generates: older cache entries are then
# ignored and replaced.
CACHE_VERSION = 1
PASS, WARN, FAIL = "PASS", "WARN", "FAIL"
MAX_TAPS = RATE  # a longer file is not an impulse response set


class Problem(Exception):
    """Something the user has to hear about; never a traceback."""


def node_name(device, slot):
    return "%s_%s" % (NODE[device], SLOTS[slot])


SINK_NAMES = {node_name(d, i): d for d in DEVICES for i in range(len(SLOTS))}


def _beside(name):
    """A directory shipped with the helper: next to it when installed
    (/etc/ally-x20-steamos/surround), under overlay/surround in a checkout."""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, name)
    if not os.path.isdir(path):
        path = os.path.join(here, os.pardir, "surround", name)
    return os.path.normpath(path)


_DSP = None


def dsp():
    """The x20dsp package (crosstalk cancellation, level, checks), loaded on
    first use: `list`, `status` with built-in profiles and the plain filter
    do not need it."""
    global _DSP
    if _DSP is None:
        parent = os.path.dirname(_beside("x20dsp"))
        if parent not in sys.path:
            sys.path.insert(0, parent)
        # Never leave __pycache__ next to the package (a checkout, a fixture
        # root); the installed copy under /etc is not writable anyway.
        sys.dont_write_bytecode = True
        try:
            from x20dsp import checks, layout, level, wav, xtc
        except ImportError as e:
            raise Problem("the x20dsp package is not next to the helper (%s)" % e)
        _DSP = collections.namedtuple("Dsp", "checks layout level wav xtc")(
            checks, layout, level, wav, xtc)
    return _DSP


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
        cache = env.get("XDG_CACHE_HOME") or os.path.join(home, ".cache")
        self.cache = os.path.join(cache, NAME, "surround")
        self.hrir = env.get("X20_SURROUND_HRIR") or _beside("hrir")


# -- settings ----------------------------------------------------------------
def check_xtc(delay, strength):
    """(delay, strength) when both are in range, else Problem."""
    for value, (low, high), what, unit in ((delay, XTC_DELAY_RANGE, "delay", "microseconds"),
                                           (strength, XTC_STRENGTH_RANGE, "strength", "percent")):
        if not low <= value <= high:
            raise Problem("xtc %s %d is out of range: %d to %d %s" % (what, value, low, high, unit))
    return delay, strength


def parse_xtc(text):
    """"off" gives None, "DELAY/STRENGTH" gives (microseconds, percent)."""
    text = text.strip().lower()
    if text == "off":
        return None
    delay, sep, strength = text.partition("/")
    try:
        return check_xtc(int(delay), int(strength))
    except ValueError:
        raise Problem("xtc is 'off' or DELAY/STRENGTH in whole numbers, not %r" % text)


def format_xtc(xtc):
    return "off" if xtc is None else "%d/%d" % xtc


def xtc_words(xtc):
    return "off" if xtc is None else "%d us / %d %%" % xtc


def read_settings(path):
    """{"headphones": profile, "speakers": profile, "xtc": (delay, strength)
    or None}; a missing file or a bad value gives the default."""
    chosen = dict(DEFAULT, xtc=DEFAULT_XTC)
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
        elif sep and key == XTC_KEY:
            try:
                chosen["xtc"] = parse_xtc(value)
            except Problem:
                pass
    return chosen


def write_settings(path, chosen):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("# Written by '%s surround set' and 'surround xtc'.\n" % NAME)
        f.write("# One profile per built-in output, each on its own:\n")
        f.write("# %s\n" % " | ".join(PROFILES))
        for device in DEVICES:
            f.write("%s=%s\n" % (device, chosen[device]))
        f.write("# Crosstalk cancellation for the speakers: off, or delay in\n")
        f.write("# microseconds / strength in percent\n")
        f.write("%s=%s\n" % (XTC_KEY, format_xtc(chosen.get("xtc", DEFAULT_XTC))))
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


def _load_json(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def _stamp(path):
    st = os.stat(path)
    return st.st_mtime_ns, st.st_size


# What this process already worked out, so the service does not redo it every
# two seconds: (kind, path, mtime, size, ...) -> result.
_MEMO = {}


def read_channels(path):
    """The 14 channels of a checked file as lists of floats."""
    check_hrir(path)
    try:
        _, channels = dsp().wav.read(path)
    except ValueError as e:
        raise Problem(str(e))
    return channels


def calculated_trim(channels):
    """The level trim that makes a set as loud as the plain stereo path:
    x20dsp.level.trim_db (K-weighted pink noise in the seven full-range
    channels), limited to TRIM_RANGE."""
    if not any(any(samples) for samples in channels):
        raise Problem("the file is silent")
    low, high = TRIM_RANGE
    return min(max(dsp().level.trim_db(channels), low), high)


def user_trim_db(paths, path):
    """The level trim of the user's file. Working it out takes a second or
    two for a long file in plain Python, so the result is kept: in this
    process and in the cache directory, valid while the file's path,
    modification time and size stay the same."""
    check_hrir(path)
    key = ("trim", path) + _stamp(path)
    if key in _MEMO:
        return _MEMO[key]
    store = os.path.join(paths.cache, "user-trim.json")
    kept = _load_json(store)
    if (kept.get("version") == CACHE_VERSION and kept.get("path") == path
            and (kept.get("mtime_ns"), kept.get("size")) == key[2:]
            and isinstance(kept.get("trim_db"), (int, float))):
        trim = float(kept["trim_db"])
    else:
        trim = calculated_trim(read_channels(path))
        try:
            _write_json(store, {"version": CACHE_VERSION, "path": path, "mtime_ns": key[2],
                                "size": key[3], "trim_db": trim})
        except OSError:
            pass  # still kept in this process
    _MEMO[key] = trim
    return trim


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
                return USER, path, user_trim_db(paths, path), None
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


# -- crosstalk cancellation for the speakers ---------------------------------
def source_digest(path):
    """SHA-256 of a file's content (the cache key of its variants)."""
    key = ("sha", path) + _stamp(path)
    if key not in _MEMO:
        with open(path, "rb") as f:
            _MEMO[key] = hashlib.sha256(f.read()).hexdigest()
    return _MEMO[key]


def variant_files(paths, digest, xtc):
    base = os.path.join(paths.cache, "%s-d%03d-s%02d" % ((digest[:16],) + tuple(xtc)))
    return base + ".wav", base + ".json"


def cached_variant(paths, source, xtc):
    """The sidecar of a valid cache entry for `source` with `xtc`, plus
    "wav" (the generated file); None when there is none. Valid: written by
    this version for this content, delay and strength, and, unless the
    check failed, with the generated file in place at its recorded size."""
    digest = source_digest(source)
    wav, side = variant_files(paths, digest, xtc)
    meta = _load_json(side)
    if (meta.get("version") != CACHE_VERSION or meta.get("source_sha256") != digest
            or (meta.get("delay_us"), meta.get("strength_pct")) != tuple(xtc)
            or meta.get("status") not in (PASS, WARN, FAIL)
            or not isinstance(meta.get("trim_db"), (int, float))):
        return None
    if meta["status"] != FAIL:
        try:
            if os.path.getsize(wav) != meta.get("wav_bytes"):
                return None
        except OSError:
            return None
    meta["wav"] = wav
    return meta


def _judge(results):
    """(worst status, why) of check results, in words for the user."""
    d = dsp()
    worst = d.checks.worst_status(results)
    if worst == PASS:
        return worst, ""
    words = []
    for r in results:
        if r.status != worst:
            continue
        if r.name == "routing" and r.value is not None and r.value >= 0.0:
            words.append("routing check: a channel would be only %.1f dB louder in "
                         "the ear on its own side, at least %.1f dB is required"
                         % (r.value, d.checks.ROUTING_MIN_ILD_DB))
        else:
            words.append("%s check: %s" % (r.name, r.detail))
    return worst, "; ".join(words)


def make_variant(paths, source, xtc):
    """Generate the variant of `source` with crosstalk cancellation `xtc`,
    check it, work out its level trim and put it in the cache. A variant
    that fails a check leaves only its sidecar, so it is neither used nor
    generated again. Returns what cached_variant returns."""
    d = dsp()
    delay, strength = xtc
    digest = source_digest(source)
    wav, side = variant_files(paths, digest, xtc)
    channels = d.xtc.apply(read_channels(source), delay, strength / 100.0)
    table = d.layout.pairs(channels)
    status, detail = _judge([d.checks.check_routing(table), d.checks.check_symmetry(table)])
    meta = {"version": CACHE_VERSION, "source": source, "source_sha256": digest,
            "delay_us": delay, "strength_pct": strength, "status": status, "detail": detail,
            "trim_db": round(calculated_trim(channels), 2), "frames": len(channels[0])}
    os.makedirs(paths.cache, exist_ok=True)
    if status != FAIL:
        tmp = "%s.%d.tmp" % (wav, os.getpid())
        d.wav.write(tmp, RATE, channels)
        meta["wav_bytes"] = os.path.getsize(tmp)
        os.replace(tmp, wav)
    _write_json(side, meta)
    meta["wav"] = wav
    return meta


def variant(paths, source, xtc, generate=True, tell=None):
    """The cache entry for `source` with `xtc`; generated when missing
    unless `generate` is false (then None). A failed attempt is remembered
    by this process and not repeated while the file stays the same."""
    meta = cached_variant(paths, source, xtc)
    if meta is not None or not generate:
        return meta
    key = ("failed", source) + _stamp(source) + tuple(xtc)
    if key in _MEMO:
        raise Problem(_MEMO[key])
    if tell:
        tell("generating the speaker variant %s of %s" % (xtc_words(xtc),
                                                          os.path.basename(source)))
    try:
        return make_variant(paths, source, xtc)
    except (Problem, OSError, ValueError) as e:
        _MEMO[key] = str(e)
        raise Problem(str(e))


# What plays on an output: the effective profile, the profile's own file,
# the file the filter reads (a generated variant when xtc is not None), its
# trim, the note of a fall-back, the crosstalk setting in use, and whether a
# variant is wanted but not generated yet (only with generate=False).
Use = collections.namedtuple("Use", "profile source wav trim note xtc pending")


def effective(paths, device, chosen, generate=True, tell=None):
    """What `device` plays with the settings `chosen`: resolve() plus, for
    the speakers, crosstalk cancellation. Headphones never get it."""
    profile, source, trim, note = resolve(paths, device, chosen[device])
    xtc = chosen.get("xtc") if device == "speakers" else None
    if profile == STEREO or xtc is None:
        return Use(profile, source, source, trim, note, None, False)
    try:
        meta = variant(paths, source, xtc, generate, tell)
        if meta is None:
            return Use(profile, source, source, trim, note, None, True)
        why = None if meta["status"] != FAIL else "is not usable with %s (%s)" % (
            profile, meta.get("detail") or "a check failed")
    except (Problem, OSError) as e:
        why = "could not be generated (%s)" % e
    if why:
        extra = "crosstalk cancellation %s %s; playing %s without it" % (xtc_words(xtc), why,
                                                                        profile)
        return Use(profile, source, source, trim, extra if note is None else note + "; " + extra,
                   None, False)
    return Use(profile, source, meta["wav"], float(meta["trim_db"]), note, tuple(xtc), False)


# -- the PipeWire config -----------------------------------------------------
def _plain(text):
    if any(ch in text for ch in '"\\\n'):
        raise Problem("unsupported character in %r" % text)
    return text


def render(device, profile, wav, target, trim_db, priority, node=None):
    """A complete config for `pipewire -c`: PipeWire 1.6.8's 7.1 HeSuVi
    virtual-surround graph plus a level trim, a hard ceiling on the output
    and the output pinned to one hardware sink (node.dont-fallback, so the
    sound never ends up on another sink; node.linger, because WirePlumber
    0.5 destroys a filter whose target is missing)."""
    node = node or node_name(device, 0)
    for value in (profile, wav, target, node):
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
        '                node.name        = "%s"\n' % node,
        '                node.description = "%s"\n' % description,
        "                media.class      = Audio/Sink\n",
        "                audio.channels   = %d\n" % len(INPUTS),
        "                audio.position   = [ %s ]\n" % " ".join(INPUTS),
        "                priority.session = %d\n" % priority,
        "                priority.driver  = %d\n" % priority,
        "            }\n            playback.props = {\n",
        '                node.name          = "%s.output"\n' % node,
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
                if name in SINK_NAMES:
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


def plan(paths, state, tell=None):
    """What should run now: None, or (device, effective profile, the file
    the filter reads, trim, target node.name, the target's priority, that
    file's mtime, the crosstalk setting in use or None). Also returns the
    note of a fall-back. A missing speaker variant is generated here, while
    whatever runs keeps running."""
    device = active_device(state)
    if device is None:
        return None, None
    use = effective(paths, device, read_settings(paths.settings), tell=tell)
    if use.profile == STEREO:
        return None, use.note
    target, priority = state["sinks"][device]
    try:
        stamp = os.path.getmtime(use.wav)  # a replaced file restarts the filter
    except OSError:
        stamp = 0.0
    return (device, use.profile, use.wav, round(use.trim, 2), target, priority, stamp,
            use.xtc), use.note


# -- the service -------------------------------------------------------------
def say(text):
    print("%s-surround: %s" % (NAME, text), file=sys.stderr, flush=True)


class Runner:
    """Keeps the filter `plan` asks for running: one process, two for the
    moment of a hand-over."""

    def __init__(self, paths, spawn=None, dump=pw_dump, sleep=time.sleep):
        self.paths = paths
        self.spawn = spawn or self._spawn
        self.dump = dump
        self.sleep = sleep
        self.proc = None
        self.slot = 0
        self.want = None
        self.last_note = None
        self.started_at = 0.0
        self.failures = 0

    def _spawn(self, conf_path):
        return subprocess.Popen(["pipewire", "-c", conf_path], stdin=subprocess.DEVNULL)

    @staticmethod
    def _end(proc):
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

    def stop(self):
        proc, self.proc = self.proc, None
        if proc is not None:
            self._end(proc)

    def _start(self, want, slot):
        """Write the config for `want` in `slot` and start its process."""
        device, profile, wav, trim, target, priority, _, xtc = want
        os.makedirs(self.paths.runtime, exist_ok=True)
        conf_path = os.path.join(self.paths.runtime, "%s-%s.conf" % (device, SLOTS[slot]))
        with open(conf_path, "w") as f:
            f.write(render(device, profile, wav, target, trim, priority + 1 + slot,
                           node_name(device, slot)))
        proc = self.spawn(conf_path)
        say("%s: %s%s (%s, trim %+.2f dB) on %s as %s"
            % (device, profile, " + xtc %s" % xtc_words(xtc) if xtc else "",
               os.path.basename(wav), trim, target, node_name(device, slot)))
        return proc

    def _hand_over(self, want):
        """Replace the running filter without a moment in which no surround
        sink exists: start the one for `want` under the other sink name,
        wait until PipeWire shows that sink, give WirePlumber a moment to
        see it too, then stop the old filter. False when the new sink did
        not appear; the old filter then still runs."""
        slot = 1 - self.slot
        name = node_name(want[0], slot)
        proc = self._start(want, slot)
        seen = False
        for _ in range(int(round(HANDOVER_TIMEOUT / HANDOVER_POLL))):
            self.sleep(HANDOVER_POLL)
            if proc.poll() is not None:
                break
            objects = self.dump()
            if objects is None:
                break
            if name in look(objects)["running"]:
                seen = True
                break
        if not seen:
            self._end(proc)
            say("the new filter's sink %s did not appear" % name)
            return False
        self.sleep(HANDOVER_SETTLE)
        old, self.proc, self.slot = self.proc, proc, slot
        self._end(old)
        return True

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
        want, note = plan(self.paths, look(objects), tell=say)
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
        if want is not None and self.proc is not None:
            # Another profile, crosstalk setting, file or output while a
            # filter runs: new one first, then the old one goes.
            if self._hand_over(want):
                self.want = want
                self.started_at = now
                return want
            say("replacing the running filter instead")
        self.stop()
        self.want = want
        if want is None:
            return None
        # A filter that keeps dying is retried ever more slowly, never in a
        # tight loop.
        if self.failures and now - self.started_at < min(60, 2 ** self.failures):
            return want
        self.proc = self._start(want, self.slot)
        self.started_at = now
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
    print("Recommended: -dry, on both outputs. On the speakers -full makes the front")
    print("channels sound quieter (the owner's impression by ear, not measured); on")
    print("headphones -full is an option for sharper positioning.")
    print("user: the first .wav in lexical order in %s" % paths.user_dir)
    print("")
    print("Speakers only: crosstalk cancellation ('xtc DELAY_US STRENGTH_PCT' or 'xtc off',")
    print("default %s) is applied on top of the speakers' profile; 'prepare' shows"
          % xtc_words(DEFAULT_XTC))
    print("which of the tested settings are usable with it.")
    return 0


def _use_words(use, chosen_profile):
    """"profile[ -> effective][ + xtc ...]" for one output."""
    text = chosen_profile
    if use.profile != chosen_profile:
        text += " -> %s" % use.profile
    if use.xtc:
        text += " + xtc %s" % xtc_words(use.xtc)
    return text


def cmd_status(args, paths):
    chosen = read_settings(paths.settings)
    objects = pw_dump()
    state = look(objects) if objects is not None else None
    active = active_device(state) if state else None
    uses = {}
    for device in DEVICES:
        # status only reports: a missing speaker variant is not generated here
        use = uses[device] = effective(paths, device, chosen, generate=False)
        line = "%-10s %s" % (device, _use_words(use, chosen[device]))
        if use.wav:
            line += "  (%s, trim %+.2f dB)" % (os.path.basename(use.source), use.trim)
        if device == active:
            line += "  [in use]"
        print(line)
        if use.note:
            print("           note: %s" % use.note)
    use = uses["speakers"]
    line = "%-10s %s  (speakers only)" % ("xtc", xtc_words(chosen["xtc"]))
    if use.xtc:
        line += ": %s" % use.wav
    elif use.pending:
        line += ": not generated yet; the service does that on first use, 'prepare' up front"
    elif chosen["xtc"] and use.profile == STEREO:
        line += ": no effect with %s" % STEREO
    elif chosen["xtc"]:
        line += ": not in use, see the note"
    print(line)
    if state is None:
        print("PipeWire does not answer; cannot tell which output is in use")
        return 0
    if active is None:
        print("no built-in output found in PipeWire")
    for name in sorted(state["running"]):
        print("running: %s" % DESCRIPTION[SINK_NAMES[name]])
    if not state["running"]:
        print("running: no filter (plain stereo)")
    path = user_file(paths)
    print("user file: %s" % (path or "none in %s" % paths.user_dir))
    return 0


def _report(paths, device, chosen):
    """One line (and a note) on what `device` plays with `chosen`; a speaker
    variant that is missing is generated now, so a fall-back shows here."""
    use = effective(paths, device, chosen)
    line = "%s: %s" % (device, _use_words(use, chosen[device]))
    if use.xtc:
        line += "  (trim %+.2f dB)" % use.trim
    print(line)
    if use.note:
        print("note: %s" % use.note)
    return use


def _when():
    print("Takes effect within a few seconds while the surround service runs. A game")
    print("that is already running keeps its stream: restart it to go from stereo to 7.1.")


def cmd_set(args, paths):
    """`set DEVICE PROFILE`; the older `set PROFILE --device DEVICE` is still
    accepted. The output is always named: each has its own profile, and
    nothing is guessed from the output in use."""
    words = list(args.words)
    usage = "usage: set headphones|speakers PROFILE (profiles: %s)" % " | ".join(PROFILES)
    if args.device is not None and len(words) == 1:
        device, profile = args.device, words[0]
    elif args.device is None and len(words) == 2:
        device, profile = words
    elif args.device is None and len(words) == 1 and words[0] in PROFILES:
        raise Problem("name the output: set headphones %s, or set speakers %s (each output"
                      " has its own profile)" % (words[0], words[0]))
    else:
        raise Problem(usage)
    if device not in DEVICES:
        raise Problem("unknown output %r; %s" % (device, usage))
    if profile not in PROFILES:
        raise Problem("unknown profile %r; %s" % (profile, usage))
    chosen = read_settings(paths.settings)
    chosen[device] = profile
    write_settings(paths.settings, chosen)
    _report(paths, device, chosen)
    _when()
    return 0


def cmd_xtc(args, paths):
    values = args.values
    if len(values) == 1 and values[0].lower() == "off":
        xtc = None
    elif len(values) == 2:
        xtc = parse_xtc("%s/%s" % (values[0].strip(), values[1].strip().rstrip("%")))
    else:
        raise Problem("xtc takes 'off', or a delay in microseconds and a strength in percent"
                      " (for example: xtc %d %d)" % DEFAULT_XTC)
    chosen = read_settings(paths.settings)
    chosen["xtc"] = xtc
    write_settings(paths.settings, chosen)
    print("xtc: %s  (speakers only)" % xtc_words(xtc))
    use = _report(paths, "speakers", chosen)
    if xtc and use.profile == STEREO:
        print("note: the speakers' profile is %s; the setting applies once a surround profile"
              " is chosen" % STEREO)
    _when()
    return 0


def cmd_prepare(args, paths):
    chosen = read_settings(paths.settings)
    profile, source, trim, note = resolve(paths, "speakers", chosen["speakers"])
    if note:
        print("note: %s" % note)
    if profile == STEREO:
        raise Problem("the speakers' profile is %s: nothing to prepare; choose a profile first"
                      " ('set speakers PROFILE')" % STEREO)
    print("speakers: %s (%s, trim %+.2f dB without xtc)" % (profile, os.path.basename(source),
                                                            trim))
    settings = list(XTC_GRID)
    if chosen["xtc"] and chosen["xtc"] not in settings:
        settings.append(chosen["xtc"])
    print("  %-14s %-10s %s" % ("xtc", "trim", "check"))
    unusable = 0
    for xtc in settings:
        meta = variant(paths, source, xtc)
        if meta["status"] == FAIL:
            unusable += 1
            verdict = "not usable: %s" % meta.get("detail")
        else:
            verdict = "usable" + (" (%s)" % meta["detail"] if meta.get("detail") else "")
        print("%s %-14s %+6.2f dB  %s" % ("*" if xtc == chosen["xtc"] else " ", xtc_words(xtc),
                                         meta["trim_db"], verdict))
    print("* the current setting%s. Files: %s" % ("" if chosen["xtc"] else " (none: xtc is off)",
                                                paths.cache))
    if unusable:
        print("A setting that is not usable is never played: the profile then plays without xtc.")
    print("Choose one with: xtc DELAY_US STRENGTH_PCT")
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
    p.add_argument("words", nargs="+", metavar="headphones|speakers PROFILE")
    p.add_argument("--device", help=argparse.SUPPRESS)
    p.set_defaults(fn=cmd_set)
    p = sub.add_parser("xtc")
    p.add_argument("values", nargs="+", metavar="off | DELAY_US STRENGTH_PCT")
    p.set_defaults(fn=cmd_xtc)
    sub.add_parser("prepare").set_defaults(fn=cmd_prepare)
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
