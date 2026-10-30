#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Clear the ``acp-audio-config-flag`` _DSD property in an ACPI DSDT/SSDT.

The ROG Xbox Ally X20 (board RC74XA) BIOS publishes, under the AMD ACP
device, a device-properties ``_DSD`` entry::

    Package () { "acp-audio-config-flag", 0x10 }   // 0x10 = DMIC only

which makes the Linux ``snd_acp*``/SOF machine drivers skip SoundWire, so
the TAS2783 speaker amplifiers are never probed. Windows ignores the flag.

This tool rewrites that integer directly in the compiled AML, without
iasl, and packages the result as a Linux "ACPI table upgrade" early initrd
(an uncompressed newc cpio holding ``kernel/firmware/acpi/DSDT.aml``, see
the kernel's Documentation/admin-guide/acpi/initrd_table_override.rst).

Only bytes that already encode the integer are touched; the table length
never changes, so no AML PkgLength has to be re-encoded. The OEM revision
is bumped so the kernel prefers our table over the firmware's, and the
header checksum is recomputed.

Subcommands: inspect, patch, verify, diff, mkinitrd, list. Run with
``--help`` for details. Exit codes (all subcommands):

    0   success
    1   verify: flag present but not at the expected value;
        diff: the inputs differ (or differ outside the expected regions
        with --check-expected)
    2   invalid table (bad signature, length, checksum) or invalid cpio
    3   flag not found, ambiguous, non-constant, or value not encodable
    4   I/O error (missing file, unwritable output)
    64  usage error

Python 3.9+, standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import struct
import sys
from dataclasses import dataclass
from typing import Dict, Iterable, List, NoReturn, Optional, Sequence, Tuple

__version__ = "0.1.0"

PROPERTY_NAME = "acp-audio-config-flag"

EXIT_OK = 0
EXIT_MISMATCH = 1
EXIT_INVALID = 2
EXIT_FLAG = 3
EXIT_IO = 4
EXIT_USAGE = 64

HEADER_LEN = 36
CHECKSUM_OFFSET = 9
OEM_REVISION_OFFSET = 24
PATCHABLE_SIGNATURES = (b"DSDT", b"SSDT")

# AML integer opcodes (ACPI 6.5, section 20.2.3 "Data Objects Encoding").
ZERO_OP = 0x00
ONE_OP = 0x01
BYTE_PREFIX = 0x0A
WORD_PREFIX = 0x0B
DWORD_PREFIX = 0x0C
STRING_PREFIX = 0x0D
QWORD_PREFIX = 0x0E
ONES_OP = 0xFF
PACKAGE_OP = 0x12

# opcode -> (encoding name, number of payload bytes)
INTEGER_ENCODINGS: Dict[int, Tuple[str, int]] = {
    ZERO_OP: ("ZeroOp", 0),
    ONE_OP: ("OneOp", 0),
    BYTE_PREFIX: ("ByteConst", 1),
    WORD_PREFIX: ("WordConst", 2),
    DWORD_PREFIX: ("DWordConst", 4),
    QWORD_PREFIX: ("QWordConst", 8),
}

# Where the kernel looks for upgrade tables inside the early initrd cpio.
INITRD_DIRS = ("kernel", "kernel/firmware", "kernel/firmware/acpi")
INITRD_TABLE_DIR = "kernel/firmware/acpi"
INITRD_DSDT_PATH = INITRD_TABLE_DIR + "/DSDT.aml"


class ToolError(Exception):
    """An error that maps to a documented exit code."""

    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


# --------------------------------------------------------------- SDT header --


@dataclass
class TableHeader:
    """The 36-byte ACPI System Description Table header."""

    signature: bytes
    length: int
    revision: int
    checksum: int
    oem_id: bytes
    oem_table_id: bytes
    oem_revision: int
    creator_id: bytes
    creator_revision: int

    @classmethod
    def parse(cls, data: bytes) -> "TableHeader":
        if len(data) < HEADER_LEN:
            raise ToolError(
                "file is %d bytes, shorter than an ACPI table header (%d)"
                % (len(data), HEADER_LEN),
                EXIT_INVALID,
            )
        fields = struct.unpack_from("<4sIBB6s8sI4sI", data, 0)
        return cls(*fields)

    def as_dict(self) -> Dict[str, object]:
        return {
            "signature": _ascii(self.signature),
            "length": self.length,
            "revision": self.revision,
            "checksum": self.checksum,
            "oem_id": _ascii(self.oem_id),
            "oem_table_id": _ascii(self.oem_table_id),
            "oem_revision": self.oem_revision,
            "creator_id": _ascii(self.creator_id),
            "creator_revision": self.creator_revision,
        }


def _ascii(raw: bytes) -> str:
    return raw.decode("ascii", errors="replace").rstrip("\x00")


def table_sum(data: bytes) -> int:
    """8-bit sum of every byte; a valid ACPI table sums to 0."""
    return sum(data) & 0xFF


def compute_checksum(data: bytes) -> int:
    """Return the checksum byte that makes ``data`` sum to 0 mod 256.

    The current content of the checksum byte is ignored.
    """
    rest = (sum(data) - data[CHECKSUM_OFFSET]) & 0xFF
    return (-rest) & 0xFF


def check_table(data: bytes, require_patchable: bool = False) -> TableHeader:
    """Validate header length and checksum; raise ToolError if invalid."""
    hdr = TableHeader.parse(data)
    if hdr.length != len(data):
        raise ToolError(
            "header length %d does not match file size %d (not a single raw "
            "table? use the .aml/.dat written by 'acpidump -b')"
            % (hdr.length, len(data)),
            EXIT_INVALID,
        )
    if require_patchable and hdr.signature not in PATCHABLE_SIGNATURES:
        raise ToolError(
            "signature %r is not DSDT or SSDT; refusing to patch"
            % _ascii(hdr.signature),
            EXIT_INVALID,
        )
    if table_sum(data) != 0:
        raise ToolError(
            "table checksum is invalid (sum = 0x%02x, expected 0x00)" % table_sum(data),
            EXIT_INVALID,
        )
    return hdr


# ------------------------------------------------------------ flag location --


@dataclass
class FlagSite:
    """One occurrence of the property name and the integer that follows it."""

    name_offset: int  # offset of the StringPrefix (0x0D) byte
    value_offset: int  # offset of the integer opcode byte
    opcode: int
    encoding: Optional[str]  # None when the next object is not an integer
    width: int  # payload bytes (0 for ZeroOp/OneOp, -1 if unknown)
    value: Optional[int]
    in_package_pair: bool  # preceded by "Package (2) {" (0x12 len 0x02)
    near_dsd: bool  # a _DSD NameSeg appears shortly before

    @property
    def payload_offset(self) -> int:
        return self.value_offset + 1

    @property
    def patch_range(self) -> Tuple[int, int]:
        """Half-open byte range that patching may rewrite."""
        if self.width <= 0:
            return (self.value_offset, self.value_offset + 1)
        return (self.payload_offset, self.payload_offset + self.width)

    def as_dict(self) -> Dict[str, object]:
        return {
            "name_offset": self.name_offset,
            "value_offset": self.value_offset,
            "opcode": self.opcode,
            "encoding": self.encoding,
            "width": self.width,
            "value": self.value,
            "in_package_pair": self.in_package_pair,
            "near_dsd": self.near_dsd,
        }


def _name_pattern(name: str) -> bytes:
    return bytes([STRING_PREFIX]) + name.encode("ascii") + b"\x00"


def _looks_like_package_pair(data: bytes, name_offset: int) -> bool:
    """True if the string is the first element of ``Package (2) {...}``.

    Checks the short (1..4 byte) PkgLength forms that precede NumElements.
    """
    if name_offset < 3 or data[name_offset - 1] != 0x02:
        return False
    for pkg_len_bytes in (1, 2, 3, 4):
        op_at = name_offset - 2 - pkg_len_bytes
        if op_at < 0:
            break
        lead = data[op_at + 1]
        if data[op_at] == PACKAGE_OP and ((lead >> 6) + 1) == pkg_len_bytes:
            return True
    return False


def find_flag_sites(
    data: bytes, name: str = PROPERTY_NAME, dsd_window: int = 512
) -> List[FlagSite]:
    """Locate every AML String equal to ``name`` and decode the next object."""
    pattern = _name_pattern(name)
    sites: List[FlagSite] = []
    start = HEADER_LEN
    while True:
        at = data.find(pattern, start)
        if at < 0:
            break
        start = at + 1
        vo = at + len(pattern)
        if vo >= len(data):
            sites.append(
                FlagSite(at, vo, -1, None, -1, None, False, False)
            )
            continue
        opcode = data[vo]
        encoding: Optional[str] = None
        width = -1
        value: Optional[int] = None
        if opcode in INTEGER_ENCODINGS:
            encoding, width = INTEGER_ENCODINGS[opcode]
            if opcode == ZERO_OP:
                value = 0
            elif opcode == ONE_OP:
                value = 1
            elif vo + 1 + width <= len(data):
                value = int.from_bytes(data[vo + 1 : vo + 1 + width], "little")
            else:
                encoding, width = None, -1
        elif opcode == ONES_OP:
            encoding, width = "OnesOp", -1  # value depends on table revision
        window = data[max(HEADER_LEN, at - dsd_window) : at]
        sites.append(
            FlagSite(
                name_offset=at,
                value_offset=vo,
                opcode=opcode,
                encoding=encoding,
                width=width,
                value=value,
                in_package_pair=_looks_like_package_pair(data, at),
                near_dsd=b"_DSD" in window,
            )
        )
    return sites


def encode_value(site: FlagSite, value: int) -> bytes:
    """Bytes replacing ``site.patch_range`` so that it encodes ``value``.

    Keeps the encoding width; ZeroOp/OneOp may swap with each other.
    """
    if value < 0:
        raise ToolError("value must be non-negative", EXIT_FLAG)
    if site.value is None or site.encoding is None or site.encoding == "OnesOp":
        raise ToolError(
            "object after %r at offset 0x%x is not an integer constant "
            "(opcode 0x%02x); patch the ASL with iasl instead"
            % (PROPERTY_NAME, site.value_offset, site.opcode & 0xFF),
            EXIT_FLAG,
        )
    if site.width == 0:
        if value == 0:
            return bytes([ZERO_OP])
        if value == 1:
            return bytes([ONE_OP])
        raise ToolError(
            "value %d does not fit the 1-byte %s encoding at offset 0x%x"
            % (value, site.encoding, site.value_offset),
            EXIT_FLAG,
        )
    if value >= 1 << (8 * site.width):
        raise ToolError(
            "value %d does not fit the %d-byte %s at offset 0x%x"
            % (value, site.width, site.encoding, site.value_offset),
            EXIT_FLAG,
        )
    return value.to_bytes(site.width, "little")


# -------------------------------------------------------------------- patch --


@dataclass
class PatchResult:
    data: bytes
    sites_before: List[FlagSite]
    changed_values: bool
    oem_revision_before: int
    oem_revision_after: int


def _select_sites(sites: List[FlagSite], allow_all: bool) -> List[FlagSite]:
    if not sites:
        raise ToolError("%r not found in table" % PROPERTY_NAME, EXIT_FLAG)
    if len(sites) > 1 and not allow_all:
        raise ToolError(
            "%r found %d times (offsets %s); pass --all to patch every one"
            % (
                PROPERTY_NAME,
                len(sites),
                ", ".join("0x%x" % s.name_offset for s in sites),
            ),
            EXIT_FLAG,
        )
    return sites


def patch_table(
    data: bytes, value: int = 0, oem_rev_bump: int = 1, allow_all: bool = False
) -> PatchResult:
    """Return a patched copy of ``data``. Raises ToolError on refusal."""
    hdr = check_table(data, require_patchable=True)
    sites = _select_sites(find_flag_sites(data), allow_all)
    if oem_rev_bump < 0:
        raise ToolError("--oem-rev-bump must be >= 0", EXIT_USAGE)
    new_rev = hdr.oem_revision + oem_rev_bump
    if new_rev > 0xFFFFFFFF:
        raise ToolError(
            "OEM revision 0x%08x + %d overflows 32 bits" % (hdr.oem_revision, oem_rev_bump),
            EXIT_INVALID,
        )
    out = bytearray(data)
    changed = False
    for site in sites:
        lo, hi = site.patch_range
        new = encode_value(site, value)
        if bytes(out[lo:hi]) != new:
            out[lo:hi] = new
            changed = True
    struct.pack_into("<I", out, OEM_REVISION_OFFSET, new_rev)
    out[CHECKSUM_OFFSET] = compute_checksum(bytes(out))
    if len(out) != len(data):  # cannot happen; we only overwrite in place
        raise ToolError("internal error: patched length changed", EXIT_INVALID)
    check_table(bytes(out), require_patchable=True)
    return PatchResult(bytes(out), sites, changed, hdr.oem_revision, new_rev)


def expected_regions(data: bytes) -> List[Tuple[int, int, str]]:
    """Byte ranges a patch is allowed to change, with a label each."""
    regions = [
        (CHECKSUM_OFFSET, CHECKSUM_OFFSET + 1, "header checksum"),
        (OEM_REVISION_OFFSET, OEM_REVISION_OFFSET + 4, "OEM revision"),
    ]
    for site in find_flag_sites(data):
        lo, hi = site.patch_range
        regions.append((lo, hi, "%s value" % PROPERTY_NAME))
    return regions


def label_offset(offset: int, regions: Iterable[Tuple[int, int, str]]) -> Optional[str]:
    for lo, hi, label in regions:
        if lo <= offset < hi:
            return label
    return None


# --------------------------------------------------------------------- cpio --

NEWC_MAGIC = b"070701"
NEWC_HEADER_LEN = 110
CPIO_TRAILER = "TRAILER!!!"


@dataclass
class CpioEntry:
    name: str
    mode: int
    data: bytes = b""
    ino: int = 0
    uid: int = 0
    gid: int = 0
    nlink: int = 1
    mtime: int = 0


def _pad4(n: int) -> int:
    return (4 - n % 4) % 4


def write_newc(entries: Sequence[CpioEntry]) -> bytes:
    """Serialise ``entries`` as an SVR4 "newc" cpio archive with trailer."""
    buf = io.BytesIO()
    for e in list(entries) + [CpioEntry(CPIO_TRAILER, 0, b"", 0, 0, 0, 1, 0)]:
        name = e.name.encode("ascii") + b"\x00"
        fields = (
            e.ino, e.mode, e.uid, e.gid, e.nlink, e.mtime, len(e.data),
            0, 0, 0, 0, len(name), 0,
        )
        header = NEWC_MAGIC + b"".join(b"%08X" % f for f in fields)
        assert len(header) == NEWC_HEADER_LEN
        buf.write(header)
        buf.write(name)
        buf.write(b"\x00" * _pad4(NEWC_HEADER_LEN + len(name)))
        buf.write(e.data)
        buf.write(b"\x00" * _pad4(len(e.data)))
    return buf.getvalue()


def read_newc(blob: bytes) -> List[CpioEntry]:
    """Parse a newc cpio archive (up to the trailer). Raises ToolError."""
    entries: List[CpioEntry] = []
    pos = 0
    while True:
        if pos + NEWC_HEADER_LEN > len(blob):
            raise ToolError("cpio truncated: no TRAILER!!! entry", EXIT_INVALID)
        hdr = blob[pos : pos + NEWC_HEADER_LEN]
        if hdr[:6] != NEWC_MAGIC:
            raise ToolError(
                "bad cpio magic %r at offset %d (need uncompressed newc 070701)"
                % (hdr[:6], pos),
                EXIT_INVALID,
            )
        try:
            f = [int(hdr[6 + 8 * i : 14 + 8 * i], 16) for i in range(13)]
        except ValueError:
            raise ToolError("bad cpio header at offset %d" % pos, EXIT_INVALID)
        ino, mode, uid, gid, nlink, mtime, size = f[:7]
        namesize = f[11]
        pos += NEWC_HEADER_LEN
        name_raw = blob[pos : pos + namesize]
        if len(name_raw) != namesize or not name_raw.endswith(b"\x00"):
            raise ToolError("bad cpio entry name at offset %d" % pos, EXIT_INVALID)
        name = name_raw[:-1].decode("ascii", errors="replace")
        pos += namesize + _pad4(NEWC_HEADER_LEN + namesize)
        data = blob[pos : pos + size]
        if len(data) != size:
            raise ToolError("cpio entry %r truncated" % name, EXIT_INVALID)
        pos += size + _pad4(size)
        if name == CPIO_TRAILER:
            return entries
        entries.append(CpioEntry(name, mode, data, ino, uid, gid, nlink, mtime))


def initrd_member(table: bytes) -> str:
    """Path of ``table`` inside the initrd: ``kernel/firmware/acpi/<SIG>.aml``.

    The kernel ignores the file name and matches on the table header; the
    name only documents what is inside.
    """
    return "%s/%s.aml" % (INITRD_TABLE_DIR, _ascii(table[:4]))


def build_initrd(table: bytes, mtime: int = 0) -> bytes:
    """Early-initrd cpio with ``kernel/firmware/acpi/DSDT.aml`` (mode 0644).

    Directory entries are included (mode 0755), every entry is owned by
    root with the given mtime, so the output is reproducible.
    """
    entries = []
    ino = 1
    for d in INITRD_DIRS:
        entries.append(CpioEntry(d, 0o040755, b"", ino, 0, 0, 2, mtime))
        ino += 1
    entries.append(CpioEntry(initrd_member(table), 0o100644, table, ino, 0, 0, 1, mtime))
    return write_newc(entries)


def _mode_string(mode: int) -> str:
    kind = {0o040000: "d", 0o100000: "-", 0o120000: "l"}.get(mode & 0o170000, "?")
    perms = ""
    for shift in (6, 3, 0):
        bits = (mode >> shift) & 7
        perms += ("r" if bits & 4 else "-") + ("w" if bits & 2 else "-")
        perms += "x" if bits & 1 else "-"
    return kind + perms


# ----------------------------------------------------------------- file I/O --


def read_file(path: str) -> bytes:
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError as exc:
        raise ToolError("cannot read %s: %s" % (path, exc.strerror), EXIT_IO)


def write_file(path: str, data: bytes) -> None:
    """Write atomically (temp file + rename) with mode 0644."""
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise ToolError("cannot write %s: %s" % (path, exc.strerror), EXIT_IO)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --------------------------------------------------------------- subcommands --


def _out(msg: str = "") -> None:
    sys.stdout.write(msg + "\n")


def _warn(msg: str) -> None:
    sys.stderr.write("patch-acp-flag: %s\n" % msg)


def _describe_site(site: FlagSite) -> str:
    if site.value is None:
        what = "non-constant object (opcode 0x%02x)" % (site.opcode & 0xFF)
        if site.encoding == "OnesOp":
            what = "OnesOp (all ones; not patchable in place)"
    else:
        what = "%s = 0x%x (%d)" % (site.encoding, site.value, site.value)
    ctx = []
    ctx.append("in Package(2) pair" if site.in_package_pair else "NOT in a Package(2) pair")
    ctx.append("_DSD nearby" if site.near_dsd else "no _DSD nearby")
    return "name@0x%04x value@0x%04x: %s [%s]" % (
        site.name_offset, site.value_offset, what, ", ".join(ctx))


def cmd_inspect(args: argparse.Namespace) -> int:
    data = read_file(args.table)
    hdr = TableHeader.parse(data)
    sites = find_flag_sites(data)
    ok_len = hdr.length == len(data)
    ok_sum = table_sum(data) == 0
    if args.json:
        report = {
            "file": args.table,
            "sha256": sha256(data),
            "file_size": len(data),
            "header": hdr.as_dict(),
            "length_matches": ok_len,
            "checksum_valid": ok_sum,
            "property": PROPERTY_NAME,
            "sites": [s.as_dict() for s in sites],
            "tool_version": __version__,
        }
        _out(json.dumps(report, indent=2, sort_keys=True))
    else:
        _out("file:             %s (%d bytes, sha256 %s)" % (args.table, len(data), sha256(data)))
        _out("signature:        %s" % _ascii(hdr.signature))
        _out("length:           %d%s" % (hdr.length, "" if ok_len else "  (MISMATCH with file size)"))
        _out("revision:         %d" % hdr.revision)
        _out("checksum:         0x%02x (%s)" % (hdr.checksum, "valid" if ok_sum else "INVALID"))
        _out("OEM ID:           %r" % _ascii(hdr.oem_id))
        _out("OEM table ID:     %r" % _ascii(hdr.oem_table_id))
        _out("OEM revision:     0x%08x" % hdr.oem_revision)
        _out("creator:          %r rev 0x%08x" % (_ascii(hdr.creator_id), hdr.creator_revision))
        _out("%s: %d occurrence(s)" % (PROPERTY_NAME, len(sites)))
        for s in sites:
            _out("  " + _describe_site(s))
    if not ok_len or not ok_sum:
        return EXIT_INVALID
    return EXIT_OK if sites else EXIT_FLAG


def cmd_patch(args: argparse.Namespace) -> int:
    data = read_file(args.table)
    check_table(data, require_patchable=True)
    sites = _select_sites(find_flag_sites(data), args.all)
    for s in sites:
        encode_value(s, args.value)  # refuse early on unpatchable sites
    if args.if_needed and all(s.value == args.value for s in sites):
        _out("already patched: %s = %d at %d site(s); nothing written"
             % (PROPERTY_NAME, args.value, len(sites)))
        return EXIT_OK
    res = patch_table(data, args.value, args.oem_rev_bump, args.all)
    if len(res.data) != len(data):
        raise ToolError("output length changed", EXIT_INVALID)
    write_file(args.output, res.data)
    before = ", ".join("0x%x" % (s.value or 0) for s in res.sites_before)
    if not res.changed_values:
        _warn("flag already %d; only the OEM revision and checksum changed" % args.value)
    _out("patched %s: %s %s -> %d at %d site(s); OEM revision 0x%08x -> 0x%08x; "
         "checksum 0x%02x; sha256 %s"
         % (args.output, PROPERTY_NAME, before, args.value, len(res.sites_before),
            res.oem_revision_before, res.oem_revision_after,
            res.data[CHECKSUM_OFFSET], sha256(res.data)))
    return EXIT_OK


def cmd_verify(args: argparse.Namespace) -> int:
    data = read_file(args.table)
    check_table(data)
    sites = find_flag_sites(data)
    if not sites:
        raise ToolError("%r not found in table" % PROPERTY_NAME, EXIT_FLAG)
    bad = [s for s in sites if s.value != args.value]
    for s in sites:
        _out(_describe_site(s))
    if bad:
        _out("FAIL: %d of %d site(s) not equal to %d" % (len(bad), len(sites), args.value))
        return EXIT_MISMATCH
    _out("OK: checksum valid, %s = %d at %d site(s)" % (PROPERTY_NAME, args.value, len(sites)))
    return EXIT_OK


def cmd_diff(args: argparse.Namespace) -> int:
    a = read_file(args.a)
    b = read_file(args.b)
    regions = expected_regions(a)
    diffs = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
    unexpected = 0
    for i in diffs:
        label = label_offset(i, regions)
        if label is None:
            unexpected += 1
        _out("0x%06x: %02x -> %02x  %s" % (i, a[i], b[i], label or "UNEXPECTED"))
    if len(a) != len(b):
        unexpected += 1
        _out("length differs: %d -> %d" % (len(a), len(b)))
    _out("%d differing byte(s), %d outside the expected patch regions"
         % (len(diffs), unexpected))
    if args.check_expected:
        return EXIT_MISMATCH if unexpected else EXIT_OK
    return EXIT_MISMATCH if (diffs or len(a) != len(b)) else EXIT_OK


def cmd_mkinitrd(args: argparse.Namespace) -> int:
    table = read_file(args.table)
    check_table(table, require_patchable=True)
    if not args.force:
        sites = find_flag_sites(table)
        if not sites or any(s.value != 0 for s in sites):
            raise ToolError(
                "table does not have %s = 0 (run 'patch' first or pass --force)"
                % PROPERTY_NAME,
                EXIT_MISMATCH,
            )
    blob = build_initrd(table, mtime=args.mtime)
    write_file(args.output, blob)
    _out("wrote %s (%d bytes, sha256 %s) containing %s"
         % (args.output, len(blob), sha256(blob), initrd_member(table)))
    return EXIT_OK


def cmd_list(args: argparse.Namespace) -> int:
    entries = read_newc(read_file(args.image))
    for e in entries:
        digest = sha256(e.data)[:16] if e.mode & 0o170000 == 0o100000 else "-"
        _out("%s %3d %5d %5d %8d %-16s %s"
             % (_mode_string(e.mode), e.nlink, e.uid, e.gid, len(e.data), digest, e.name))
    return EXIT_OK


# ---------------------------------------------------------------------- CLI --


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        self.exit(EXIT_USAGE, "%s: error: %s\n" % (self.prog, message))


def _int(text: str) -> int:
    try:
        return int(text, 0)
    except ValueError:
        raise argparse.ArgumentTypeError("not an integer: %r" % text)


def build_parser() -> argparse.ArgumentParser:
    p = _Parser(
        prog="patch-acp-flag.py",
        description="Inspect and clear the %s _DSD property in ACPI AML, and "
        "build the early-initrd table upgrade." % PROPERTY_NAME,
        epilog="exit codes: 0 ok, 1 mismatch, 2 invalid table/cpio, 3 flag "
        "not found/ambiguous/unpatchable, 4 I/O error, 64 usage",
    )
    p.add_argument("--version", action="version", version="%(prog)s " + __version__)
    sub = p.add_subparsers(dest="command", metavar="COMMAND", parser_class=_Parser)
    sub.required = True

    s = sub.add_parser("inspect", help="print header fields and flag occurrences")
    s.add_argument("table", help="raw ACPI table (.aml / .dat)")
    s.add_argument("--json", action="store_true", help="machine-readable output")
    s.set_defaults(func=cmd_inspect)

    s = sub.add_parser("patch", help="rewrite the flag, bump OEM revision, fix checksum")
    s.add_argument("table")
    s.add_argument("-o", "--output", required=True, help="output .aml path")
    s.add_argument("--value", type=_int, default=0, help="new flag value (default 0)")
    s.add_argument("--oem-rev-bump", type=_int, default=1, metavar="N",
                   help="add N to the OEM revision (default 1)")
    s.add_argument("--all", action="store_true", help="patch every occurrence")
    s.add_argument("--if-needed", action="store_true",
                   help="exit 0 without writing if the flag already has --value")
    s.set_defaults(func=cmd_patch)

    s = sub.add_parser("verify", help="check checksum and that the flag is 0")
    s.add_argument("table")
    s.add_argument("--value", type=_int, default=0, help="expected value (default 0)")
    s.set_defaults(func=cmd_verify)

    s = sub.add_parser("diff", help="list differing byte offsets between two tables")
    s.add_argument("a")
    s.add_argument("b")
    s.add_argument("--check-expected", action="store_true",
                   help="exit 0 if every difference is in the checksum, OEM "
                   "revision or flag value bytes")
    s.set_defaults(func=cmd_diff)

    s = sub.add_parser("mkinitrd", help="build the uncompressed newc early-initrd cpio")
    s.add_argument("table", help="patched DSDT (an SSDT is accepted for VM tests)")
    s.add_argument("-o", "--output", required=True, help="output .img path")
    s.add_argument("--mtime", type=_int,
                   default=int(os.environ.get("SOURCE_DATE_EPOCH", "0") or 0),
                   help="mtime for all entries (default $SOURCE_DATE_EPOCH or 0)")
    s.add_argument("--force", action="store_true",
                   help="package even if the flag is not 0")
    s.set_defaults(func=cmd_mkinitrd)

    s = sub.add_parser("list", help="list the contents of a newc cpio (lsinitrd-style)")
    s.add_argument("image")
    s.set_defaults(func=cmd_list)
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except ToolError as exc:
        _warn(str(exc))
        return exc.code


if __name__ == "__main__":
    sys.exit(main())
