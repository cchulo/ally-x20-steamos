# SPDX-License-Identifier: GPL-2.0-only
import struct

import pytest

from x20surround import wav


def _file(tmp_path, fmt, body):
    data = (b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(body)) + b"WAVE"
            + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"data" + struct.pack("<I", len(body)) + body)
    path = tmp_path / "t.wav"
    path.write_bytes(data)
    return str(path)


def test_roundtrip_float_extensible(tmp_path):
    path = str(tmp_path / "a.wav")
    chans = [[0.0, 0.5, -0.25], [1.0, -1.0, 0.125], [0.0, 0.0, 0.0]]
    wav.write(path, 48000, chans, mask=0x7)
    rate, got = wav.read(path)
    assert rate == 48000 and got == chans
    assert wav.info(path) == (48000, 3, 3)
    raw = open(path, "rb").read()
    # WAVE_FORMAT_EXTENSIBLE, float sub-format GUID, the channel mask
    assert struct.unpack_from("<H", raw, 20)[0] == 0xFFFE
    assert struct.unpack_from("<I", raw, 40)[0] == 0x7
    assert raw[44:60] == bytes.fromhex("0300000000001000800000aa00389b71")


def test_write_pads_short_channels(tmp_path):
    path = str(tmp_path / "a.wav")
    wav.write(path, 48000, [[1.0], [0.5, 0.25]])
    assert wav.read(path)[1] == [[1.0, 0.0], [0.5, 0.25]]


def test_reads_plain_float32_like_hesuvi_files(tmp_path):
    fmt = struct.pack("<HHIIHH", 3, 2, 48000, 48000 * 8, 8, 32)
    path = _file(tmp_path, fmt, struct.pack("<4f", 0.5, -0.5, 0.25, 1.0))
    assert wav.read(path) == (48000, [[0.5, 0.25], [-0.5, 1.0]])


def test_reads_pcm16_and_pcm24(tmp_path):
    fmt = struct.pack("<HHIIHH", 1, 1, 44100, 44100 * 2, 2, 16)
    path = _file(tmp_path, fmt, struct.pack("<3h", 16384, -32768, 0))
    assert wav.read(path) == (44100, [[0.5, -1.0, 0.0]])
    fmt = struct.pack("<HHIIHH", 1, 1, 48000, 48000 * 3, 3, 24)
    body = (1 << 22).to_bytes(3, "little", signed=True) + (-(1 << 23)).to_bytes(3, "little", signed=True)
    path = _file(tmp_path, fmt, body)
    assert wav.read(path) == (48000, [[0.5, -1.0]])


def test_odd_sized_chunks_are_skipped(tmp_path):
    fmt = struct.pack("<HHIIHH", 3, 1, 48000, 48000 * 4, 4, 32)
    body = struct.pack("<f", 0.5)
    data = (b"RIFF" + struct.pack("<I", 0) + b"WAVE" + b"LIST" + struct.pack("<I", 3) + b"abc\0"
            + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", 4) + body)
    path = tmp_path / "t.wav"
    path.write_bytes(data)
    assert wav.read(str(path)) == (48000, [[0.5]])


def test_rejects_garbage(tmp_path):
    path = tmp_path / "t.wav"
    path.write_bytes(b"not a wav file at all")
    with pytest.raises(wav.WavError):
        wav.read(str(path))
    fmt = struct.pack("<HHIIHH", 85, 2, 48000, 0, 4, 16)  # MP3 tag
    with pytest.raises(wav.WavError):
        wav.read(_file(tmp_path, fmt, b"\0" * 8))
