# SPDX-License-Identifier: GPL-2.0-only
"""Shared fixtures: synthetic HRIR sets, no audio files in the repository."""

import os
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from synthetic import synthetic_table  # noqa: E402
from x20surround.layout import RATE, unpairs  # noqa: E402


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
