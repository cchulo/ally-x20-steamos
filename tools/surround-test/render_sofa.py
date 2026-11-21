#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""render_sofa.py - render a SOFA HRTF set to a 14-channel 48 kHz HRIR WAV.

usage: render_sofa.py [--rate 48000] [--json FILE] SOFA OUT.wav

The output has the HeSuVi channel layout PipeWire's
sink-virtual-surround-7.1-hesuvi.conf reads (x20surround/layout.py), for the
7.1 loudspeaker angles FL/FR +-30, FC 0, SL/SR +-90, RL/RR +-150 degrees at
elevation 0.

For each angle the nearest measured direction is used as is (no
interpolation); the angular error is reported and stored in the JSON side
file. Data.Delay is applied, the responses are resampled to the output rate
when the set has another one, and one common gain puts the largest sample at
0.5. Level matching to the raw sink happens later (x20surround/level.py).

Runs on a development machine or CI, not on the device: needs numpy, scipy
and h5py. Never commit the .sofa input or the .wav output.
"""

import argparse
import hashlib
import json
import math
import os
import sys
from fractions import Fraction

import h5py
import numpy as np
from scipy import signal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from x20surround import wav  # noqa: E402
from x20surround.layout import AZIMUTH, HESUVI, RATE  # noqa: E402

# Largest accepted distance between a loudspeaker angle and the nearest
# measured direction. CIPIC has nothing beyond +-80 degrees azimuth in the
# horizontal plane, so its sides are 10 degrees off; anything further away
# is refused.
MAX_ERROR_DEG = 10.5
PEAK = 0.5


def _text(value):
    if isinstance(value, bytes):
        return value.decode("latin-1")
    if isinstance(value, np.ndarray):
        return _text(value.flat[0]) if value.size else ""
    return str(value)


def _unit(azimuth_deg, elevation_deg):
    az, el = math.radians(azimuth_deg), math.radians(elevation_deg)
    return np.array([math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)])


def load(path):
    """Return a dict with the fields of a SimpleFreeFieldHRIR file we use."""
    with h5py.File(path, "r") as f:
        ir = np.asarray(f["Data.IR"], dtype=float)
        rate = float(np.asarray(f["Data.SamplingRate"]).flat[0])
        pos = np.asarray(f["SourcePosition"], dtype=float)
        kind = _text(f["SourcePosition"].attrs.get("Type", "spherical")).strip().lower()
        delay = np.asarray(f["Data.Delay"], dtype=float) if "Data.Delay" in f else np.zeros((1, 2))
        attrs = {k: _text(f.attrs[k]) for k in ("License", "DatabaseName", "ListenerShortName",
                                                 "Organization", "SOFAConventions")
                 if k in f.attrs}
    if ir.ndim != 3 or ir.shape[1] != 2:
        raise ValueError("%s: Data.IR must be (measurements, 2 receivers, samples)" % path)
    if pos.shape[0] != ir.shape[0]:
        raise ValueError("%s: SourcePosition and Data.IR disagree" % path)
    if kind == "cartesian":
        norm = np.linalg.norm(pos, axis=1, keepdims=True)
        units = pos / np.where(norm > 0, norm, 1.0)
    else:
        az, el = np.radians(pos[:, 0]), np.radians(pos[:, 1])
        units = np.stack([np.cos(el) * np.cos(az), np.cos(el) * np.sin(az), np.sin(el)], axis=1)
    return {"ir": ir, "rate": rate, "units": units, "delay": delay, "attrs": attrs}


def nearest(units, azimuth_deg, elevation_deg=0.0):
    """(index, angular error in degrees) of the nearest measured direction."""
    cos = np.clip(units @ _unit(azimuth_deg, elevation_deg), -1.0, 1.0)
    index = int(np.argmax(cos))
    return index, math.degrees(math.acos(float(cos[index])))


def render(sofa, rate=RATE):
    """Return (channels, report): 14 lists of floats in HeSuVi order and a
    dict describing what was picked."""
    src_rate = sofa["rate"]
    ratio = Fraction(int(rate), int(round(src_rate)))
    picked = {}
    report = {"source_rate": src_rate, "rate": rate, "directions": {}}
    for name, azimuth in AZIMUTH.items():
        index, error = nearest(sofa["units"], azimuth)
        if error > MAX_ERROR_DEG:
            raise ValueError("no measurement within %.1f degrees of %s (%.0f degrees): nearest is "
                             "%.1f degrees away" % (MAX_ERROR_DEG, name, azimuth, error))
        delay = sofa["delay"][index if sofa["delay"].shape[0] > 1 else 0]
        pair = []
        for ear in (0, 1):
            h = sofa["ir"][index, ear]
            shift = int(round(float(delay[ear])))
            if shift > 0:
                h = np.concatenate([np.zeros(shift), h])
            if ratio != 1:
                h = signal.resample_poly(h, ratio.numerator, ratio.denominator)
            pair.append(h)
        picked[name] = pair
        report["directions"][name] = {"azimuth": azimuth, "measurement": index,
                                      "error_deg": round(error, 3)}
    top = max(float(np.max(np.abs(h))) for pair in picked.values() for h in pair)
    if top <= 0.0:
        raise ValueError("the set is silent")
    gain = PEAK / top
    report["gain"] = gain
    channels = [[float(v) for v in picked[c][0 if ear == "L" else 1] * gain] for c, ear in HESUVI]
    return channels, report


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("sofa")
    ap.add_argument("out")
    ap.add_argument("--rate", type=int, default=RATE)
    ap.add_argument("--json", help="write what was picked to this file")
    args = ap.parse_args(argv)
    try:
        sofa = load(args.sofa)
        channels, report = render(sofa, args.rate)
    except (OSError, KeyError, ValueError) as e:
        print("render_sofa: %s" % e, file=sys.stderr)
        return 1
    wav.write(args.out, args.rate, channels)
    report["sofa_sha256"] = sha256(args.sofa)
    report["attributes"] = sofa["attrs"]
    if args.json:
        with open(args.json, "w") as f:
            json.dump(report, f, indent=2, sort_keys=True)
            f.write("\n")
    worst = max(d["error_deg"] for d in report["directions"].values())
    print("%s: %d samples per channel at %d Hz (source %d Hz), largest angle error %.1f degrees"
          % (args.out, len(channels[0]), args.rate, round(sofa["rate"]), worst))
    return 0


if __name__ == "__main__":
    sys.exit(main())
