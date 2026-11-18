# SPDX-License-Identifier: GPL-2.0-only
"""Shared fixtures: synthetic HRIR sets, no audio files in the repository."""

import math
import os
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from x20surround.layout import AZIMUTH, EARS, RATE, SPEAKERS, unpairs  # noqa: E402


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


@pytest.fixture
def table():
    return synthetic_table()


@pytest.fixture
def channels(table):
    return unpairs(table)


@pytest.fixture
def hrir_file(tmp_path, channels):
    from x20surround import wav
    path = tmp_path / "set.wav"
    wav.write(str(path), RATE, channels)
    return str(path)
