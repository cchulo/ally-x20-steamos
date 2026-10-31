#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Generate synthetic DSDT fixtures for the acp-audio-config-flag tool.

The table is valid AML equivalent to this ASL (one ACP device per
``count``)::

    DefinitionBlock ("", "DSDT", 2, "AX20  ", "SYNTHDSD", 0x00000001)
    {
        Scope (\\_SB)
        {
            Device (ACP0)
            {
                Name (_ADR, 0x05)
                Name (_DSD, Package (0x02)
                {
                    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301"),
                    Package (0x02)
                    {
                        Package (0x02) { "acp-audio-config-flag", 0x10 },
                        Package (0x02) { "acp-audio-config-flag-x", 0x10 }
                    }
                })
            }
        }
    }

The second property is a decoy whose name starts with the real one; it must
never be matched. ``width`` selects the AML integer encoding of the flag
(zero, one, byte, word, dword, qword) so tests can cover each form.

Usage: make-synthetic.py [-o synthetic-dsdt.aml]   (defaults reproduce the
committed fixture byte for byte).
"""

from __future__ import annotations

import argparse
import struct
import sys
import uuid
from typing import List

PROPERTY_NAME = "acp-audio-config-flag"
DEVICE_PROPERTIES_UUID = "daffd814-6eba-4d8c-8a91-bc9bbf4aa301"
WIDTHS = ("zero", "one", "byte", "word", "dword", "qword")


def pkg_length(body_len: int) -> bytes:
    """Encode an AML PkgLength covering itself plus ``body_len`` bytes."""
    for n in (1, 2, 3, 4):
        total = body_len + n
        if n == 1 and total < 0x40:
            return bytes([total])
        if n > 1 and total < (1 << (4 + 8 * (n - 1))):
            out = [((n - 1) << 6) | (total & 0x0F)]
            rest = total >> 4
            for _ in range(n - 1):
                out.append(rest & 0xFF)
                rest >>= 8
            return bytes(out)
    raise ValueError("PkgLength too large")


def aml_string(text: str) -> bytes:
    return b"\x0d" + text.encode("ascii") + b"\x00"


def aml_integer(value: int, width: str) -> bytes:
    if width == "zero":
        assert value == 0
        return b"\x00"
    if width == "one":
        assert value == 1
        return b"\x01"
    prefix, size = {"byte": (0x0A, 1), "word": (0x0B, 2), "dword": (0x0C, 4), "qword": (0x0E, 8)}[width]
    return bytes([prefix]) + value.to_bytes(size, "little")


def aml_package(elements: List[bytes]) -> bytes:
    body = bytes([len(elements)]) + b"".join(elements)
    return b"\x12" + pkg_length(len(body)) + body


def aml_buffer(data: bytes) -> bytes:
    body = b"\x0a" + bytes([len(data)]) + data
    return b"\x11" + pkg_length(len(body)) + body


def aml_name(nameseg: bytes, obj: bytes) -> bytes:
    return b"\x08" + nameseg + obj


def aml_device(nameseg: bytes, body: bytes) -> bytes:
    inner = nameseg + body
    return b"\x5b\x82" + pkg_length(len(inner)) + inner


def aml_scope(namestring: bytes, body: bytes) -> bytes:
    inner = namestring + body
    return b"\x10" + pkg_length(len(inner)) + inner


def acp_device(index: int, value: int, width: str) -> bytes:
    dsd = aml_package(
        [
            aml_buffer(uuid.UUID(DEVICE_PROPERTIES_UUID).bytes_le),
            aml_package(
                [
                    aml_package([aml_string(PROPERTY_NAME), aml_integer(value, width)]),
                    aml_package([aml_string(PROPERTY_NAME + "-x"), aml_integer(0x10, "byte")]),
                ]
            ),
        ]
    )
    body = aml_name(b"_ADR", aml_integer(5, "byte")) + aml_name(b"_DSD", dsd)
    return aml_device(("ACP%d" % index).encode("ascii"), body)


def build_dsdt(
    value: int = 0x10,
    width: str = "byte",
    count: int = 1,
    signature: bytes = b"DSDT",
    oem_id: bytes = b"AX20  ",
    oem_table_id: bytes = b"SYNTHDSD",
    oem_revision: int = 1,
) -> bytes:
    """Return a complete, checksummed ACPI table."""
    if width not in WIDTHS:
        raise ValueError("width must be one of %s" % ", ".join(WIDTHS))
    devices = b"".join(acp_device(i, value, width) for i in range(count))
    body = aml_scope(b"\\_SB_", devices)
    length = 36 + len(body)
    header = struct.pack(
        "<4sIBB6s8sI4sI",
        signature,
        length,
        2,
        0,
        oem_id,
        oem_table_id,
        oem_revision,
        b"INTL",
        0x20250404,
    )
    table = bytearray(header + body)
    table[9] = (-sum(table)) & 0xFF
    return bytes(table)


def main(argv: List[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("-o", "--output", default="synthetic-dsdt.aml")
    p.add_argument("--value", type=lambda s: int(s, 0), default=0x10)
    p.add_argument("--width", choices=WIDTHS, default="byte")
    p.add_argument("--count", type=int, default=1)
    p.add_argument("--signature", choices=("DSDT", "SSDT"), default="DSDT")
    a = p.parse_args(argv)
    data = build_dsdt(a.value, a.width, a.count, a.signature.encode("ascii"))
    with open(a.output, "wb") as fh:
        fh.write(data)
    print("wrote %s (%d bytes)" % (a.output, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
