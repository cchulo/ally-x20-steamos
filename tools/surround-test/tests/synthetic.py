# SPDX-License-Identifier: GPL-2.0-only
"""Synthetic test data, made on the spot so no audio file is in the
repository. Plain module (no pytest) so the bats suites can use it too."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from x20surround.layout import AZIMUTH, EARS, SPEAKERS  # noqa: E402


def synthetic_table(length=128):
    """A crude but well-formed binaural set: for each loudspeaker a delayed
    impulse per ear, the far ear later and quieter (and duller) the further
    the source is to the side. Left/right symmetric."""
    table = {}
    for c in SPEAKERS:
        lateral = math.sin(math.radians(AZIMUTH[c]))  # +1 = fully left
        for ear in EARS:
            toward = lateral if ear == "L" else -lateral
            delay = int(round(20 - 14 * toward))
            gain = 0.5 * (1.0 + 0.6 * toward)
            h = [0.0] * length
            h[delay] = gain
            if toward < 0:  # head shadow: a little low-pass on the far ear
                h[delay + 1] = gain * 0.5 * -toward
            table[(c, ear)] = h
    return table


def write_sofa(path, rate=48000.0, step=5, cartesian=False, delay=None):
    """A small SOFA file (needs numpy and h5py): a horizontal ring every
    `step` degrees plus one elevated decoy per direction. Each ear gets an
    impulse, and a marker sample that encodes the azimuth, so a test can
    tell which measurement was picked."""
    import h5py
    import numpy as np

    az = np.arange(0, 360, step, dtype=float)
    pos = [(a, 0.0, 1.5) for a in az] + [(a, 40.0, 1.5) for a in az]
    ir = np.zeros((len(pos), 2, 64))
    for m, (a, el, _) in enumerate(pos):
        lateral = np.sin(np.radians(a))
        for ear, toward in ((0, lateral), (1, -lateral)):
            at = int(round(20 - 10 * toward)) + (5 if el else 0)
            ir[m, ear, at] = (0.6 + 0.4 * toward) * (0.1 if el else 1.0)
            ir[m, ear, 60] = a / 3600.0  # azimuth marker, far behind the response
    with h5py.File(path, "w") as f:
        f.attrs["SOFAConventions"] = np.bytes_("SimpleFreeFieldHRIR")
        f.attrs["License"] = np.bytes_("CC0-1.0 (synthetic test data)")
        f.create_dataset("Data.IR", data=ir)
        f.create_dataset("Data.SamplingRate", data=np.array([rate]))
        f.create_dataset("Data.Delay", data=np.zeros((1, 2)) if delay is None else delay)
        p = np.array(pos)
        if cartesian:
            a, e, r = np.radians(p[:, 0]), np.radians(p[:, 1]), p[:, 2]
            p = np.stack([r * np.cos(e) * np.cos(a), r * np.cos(e) * np.sin(a), r * np.sin(e)], 1)
        d = f.create_dataset("SourcePosition", data=p)
        d.attrs["Type"] = np.bytes_("cartesian" if cartesian else "spherical")
    return path
