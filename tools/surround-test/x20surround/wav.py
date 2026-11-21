# SPDX-License-Identifier: GPL-2.0-only
"""Minimal RIFF/WAVE reader and writer.

The standard library's wave module does not read IEEE-float files, which is
what HeSuVi HRIR sets and this rig's own files are, so this module reads
PCM 16/24/32 and float 32/64 (plain and WAVE_FORMAT_EXTENSIBLE) and writes
32-bit float WAVE_FORMAT_EXTENSIBLE, the form libsndfile (PipeWire's
convolver, pw-cat) accepts for any channel count.
"""

import array
import struct
import sys

_PCM = 1
_FLOAT = 3
_EXTENSIBLE = 0xFFFE
# Tail of the KSDATAFORMAT_SUBTYPE_* GUIDs after the 2-byte format code.
_GUID_TAIL = bytes.fromhex("000000001000800000aa00389b71")


class WavError(ValueError):
    pass


def _chunks(data):
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise WavError("not a RIFF/WAVE file")
    pos = 12
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        yield cid, data[pos + 8:pos + 8 + size]
        pos += 8 + size + (size & 1)


def read(path):
    """Return (rate, channels) with channels a list of lists of floats."""
    with open(path, "rb") as f:
        data = f.read()
    fmt = None
    body = None
    for cid, chunk in _chunks(data):
        if cid == b"fmt ":
            fmt = chunk
        elif cid == b"data":
            body = chunk
    if fmt is None or body is None or len(fmt) < 16:
        raise WavError("%s: missing fmt or data chunk" % path)
    tag, nch, rate, _, align, bits = struct.unpack_from("<HHIIHH", fmt, 0)
    if tag == _EXTENSIBLE:
        if len(fmt) < 40:
            raise WavError("%s: short extensible fmt chunk" % path)
        tag = struct.unpack_from("<H", fmt, 24)[0]
    if nch < 1 or align != nch * bits // 8:
        raise WavError("%s: inconsistent fmt chunk" % path)
    frames = len(body) // align
    body = body[:frames * align]
    if tag == _FLOAT and bits in (32, 64):
        flat = array.array("f" if bits == 32 else "d")
        flat.frombytes(body)
        if sys.byteorder == "big":
            flat.byteswap()
        scale = 1.0
    elif tag == _PCM and bits in (16, 32):
        flat = array.array("h" if bits == 16 else "i")
        flat.frombytes(body)
        if sys.byteorder == "big":
            flat.byteswap()
        scale = 1.0 / float(1 << (bits - 1))
    elif tag == _PCM and bits == 24:
        flat = [
            int.from_bytes(body[i:i + 3], "little", signed=True)
            for i in range(0, len(body), 3)
        ]
        scale = 1.0 / float(1 << 23)
    else:
        raise WavError("%s: unsupported format (tag %d, %d bits)" % (path, tag, bits))
    channels = [[v * scale for v in flat[c::nch]] for c in range(nch)]
    return rate, channels


def write(path, rate, channels, mask=0):
    """Write 32-bit float WAVE_FORMAT_EXTENSIBLE. Channels may differ in
    length; shorter ones are zero-padded."""
    nch = len(channels)
    if nch < 1:
        raise WavError("no channels")
    frames = max(len(c) for c in channels)
    flat = array.array("f", bytes(4 * nch * frames))
    for c, samples in enumerate(channels):
        flat[c:c + nch * len(samples):nch] = array.array("f", samples)
    if sys.byteorder == "big":
        flat.byteswap()
    body = flat.tobytes()
    fmt = struct.pack(
        "<HHIIHHHHIH", _EXTENSIBLE, nch, rate, rate * nch * 4, nch * 4, 32, 22, 32, mask, _FLOAT
    ) + _GUID_TAIL
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(body)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt)
        f.write(b"data" + struct.pack("<I", len(body)) + body)


def info(path):
    """Return (rate, channel count, frames) without decoding the samples."""
    with open(path, "rb") as f:
        data = f.read()
    fmt = None
    size = 0
    for cid, chunk in _chunks(data):
        if cid == b"fmt ":
            fmt = chunk
        elif cid == b"data":
            size = len(chunk)
    if fmt is None or len(fmt) < 16:
        raise WavError("%s: missing fmt chunk" % path)
    _, nch, rate, _, align, _ = struct.unpack_from("<HHIIHH", fmt, 0)
    return rate, nch, (size // align if align else 0)
