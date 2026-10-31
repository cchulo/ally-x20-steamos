# SPDX-License-Identifier: GPL-2.0-only
"""Tests for acpi/patch-acp-flag.py, acpi/fixtures/make-synthetic.py and
acpi/build-override.sh. Fixtures are built in code; no real firmware needed."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path
from types import ModuleType
from typing import Dict, List

import pytest

ACPI_DIR = Path(__file__).resolve().parent.parent
TOOL_PATH = ACPI_DIR / "patch-acp-flag.py"
SYNTH_PATH = ACPI_DIR / "fixtures" / "make-synthetic.py"
COMMITTED_FIXTURE = ACPI_DIR / "fixtures" / "synthetic-dsdt.aml"
BUILD_OVERRIDE = ACPI_DIR / "build-override.sh"


def _load(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, str(path))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod  # dataclasses need the module registered
    spec.loader.exec_module(mod)
    return mod


tool = _load("patch_acp_flag", TOOL_PATH)
synth = _load("make_synthetic", SYNTH_PATH)

WIDTH_SIZES = {"byte": 1, "word": 2, "dword": 4, "qword": 8}


def write(tmp_path: Path, name: str, data: bytes) -> Path:
    p = tmp_path / name
    p.write_bytes(data)
    return p


def run(argv: List[str], capsys: pytest.CaptureFixture) -> "tuple[int, str, str]":
    rc = tool.main(argv)
    out, err = capsys.readouterr()
    return rc, out, err


def diff_offsets(a: bytes, b: bytes) -> List[int]:
    assert len(a) == len(b)
    return [i for i in range(len(a)) if a[i] != b[i]]


# ------------------------------------------------------------ fixtures ------


def test_committed_fixture_is_reproducible() -> None:
    assert COMMITTED_FIXTURE.read_bytes() == synth.build_dsdt()


def test_fixture_generator_cli(tmp_path: Path) -> None:
    out = tmp_path / "f.aml"
    subprocess.run([sys.executable, str(SYNTH_PATH), "-o", str(out)], check=True,
                   capture_output=True)
    assert out.read_bytes() == COMMITTED_FIXTURE.read_bytes()


@pytest.mark.parametrize("width", synth.WIDTHS)
def test_synthetic_tables_are_valid(width: str) -> None:
    value = {"zero": 0, "one": 1}.get(width, 0x10)
    data = synth.build_dsdt(value=value, width=width)
    hdr = tool.check_table(data, require_patchable=True)
    assert hdr.signature == b"DSDT"
    assert hdr.length == len(data)


def test_pkg_length_encodings() -> None:
    assert synth.pkg_length(0x3E) == bytes([0x3F])
    # 2-byte form: total = body + 2; low nibble in lead byte, rest in next
    enc = synth.pkg_length(0x40)
    assert enc[0] >> 6 == 1
    assert (enc[0] & 0x0F) | (enc[1] << 4) == 0x42


# ------------------------------------------------------------ checksum ------


def test_checksum_math() -> None:
    data = bytearray(synth.build_dsdt())
    assert tool.table_sum(bytes(data)) == 0
    data[50] ^= 0xFF
    assert tool.table_sum(bytes(data)) != 0
    data[tool.CHECKSUM_OFFSET] = tool.compute_checksum(bytes(data))
    assert tool.table_sum(bytes(data)) == 0


def test_compute_checksum_ignores_current_checksum_byte() -> None:
    data = bytearray(synth.build_dsdt())
    good = data[tool.CHECKSUM_OFFSET]
    data[tool.CHECKSUM_OFFSET] = 0xAA
    assert tool.compute_checksum(bytes(data)) == good


def test_header_parse() -> None:
    hdr = tool.TableHeader.parse(synth.build_dsdt(oem_revision=0x1234))
    d = hdr.as_dict()
    assert d["signature"] == "DSDT"
    assert d["oem_id"] == "AX20  "
    assert d["oem_table_id"] == "SYNTHDSD"
    assert d["oem_revision"] == 0x1234
    assert d["revision"] == 2


# ------------------------------------------------------------- locating -----


@pytest.mark.parametrize("width", synth.WIDTHS)
def test_find_flag_each_width(width: str) -> None:
    value = {"zero": 0, "one": 1, "byte": 0x10, "word": 0x1234,
             "dword": 0x12345678, "qword": 0x1122334455667788}[width]
    data = synth.build_dsdt(value=value, width=width)
    sites = tool.find_flag_sites(data)
    assert len(sites) == 1, "decoy property must not match"
    s = sites[0]
    assert s.value == value
    assert s.width == {"zero": 0, "one": 0}.get(width, WIDTH_SIZES.get(width))
    assert s.in_package_pair and s.near_dsd


def test_find_flag_multiple_and_absent() -> None:
    assert len(tool.find_flag_sites(synth.build_dsdt(count=3))) == 3
    blank = synth.build_dsdt().replace(b"acp-audio-config-flag\x00", b"acp-audio-config-flaZ\x00")
    assert tool.find_flag_sites(blank) == []


def test_non_integer_value_is_reported_not_patched(tmp_path: Path, capsys) -> None:
    data = bytearray(synth.build_dsdt())
    site = tool.find_flag_sites(bytes(data))[0]
    # Turn "ByteConst 0x10" into a NameSeg-ish reference "\x5c" + ... ; keep
    # length: replace opcode with RootChar so it is not an integer.
    data[site.value_offset] = 0x5C
    data[tool.CHECKSUM_OFFSET] = tool.compute_checksum(bytes(data))
    src = write(tmp_path, "nonint.aml", bytes(data))
    rc, out, _ = run(["inspect", str(src)], capsys)
    assert rc == 0 and "non-constant" in out
    rc, _, err = run(["patch", str(src), "-o", str(tmp_path / "o.aml")], capsys)
    assert rc == tool.EXIT_FLAG and "not an integer constant" in err
    assert not (tmp_path / "o.aml").exists()


# --------------------------------------------------------------- inspect ----


def test_inspect_text(tmp_path: Path, capsys) -> None:
    rc, out, _ = run(["inspect", str(COMMITTED_FIXTURE)], capsys)
    assert rc == 0
    assert "signature:        DSDT" in out
    assert "(valid)" in out
    assert "ByteConst = 0x10 (16)" in out
    assert "1 occurrence(s)" in out


def test_inspect_json(capsys) -> None:
    rc, out, _ = run(["inspect", "--json", str(COMMITTED_FIXTURE)], capsys)
    assert rc == 0
    r = json.loads(out)
    assert r["checksum_valid"] and r["length_matches"]
    assert r["header"]["oem_revision"] == 1
    assert [s["value"] for s in r["sites"]] == [0x10]


def test_inspect_bad_checksum_exit_2(tmp_path: Path, capsys) -> None:
    data = bytearray(synth.build_dsdt())
    data[tool.CHECKSUM_OFFSET] ^= 1
    rc, out, _ = run(["inspect", str(write(tmp_path, "b.aml", bytes(data)))], capsys)
    assert rc == tool.EXIT_INVALID and "INVALID" in out


def test_inspect_not_found_exit_3(tmp_path: Path, capsys) -> None:
    data = synth.build_dsdt().replace(b"acp-audio-config-flag\x00", b"acp-audio-config-flaZ\x00")
    data = bytearray(data)
    data[tool.CHECKSUM_OFFSET] = tool.compute_checksum(bytes(data))
    rc, _, _ = run(["inspect", str(write(tmp_path, "n.aml", bytes(data)))], capsys)
    assert rc == tool.EXIT_FLAG


def test_missing_file_exit_4(tmp_path: Path, capsys) -> None:
    rc, _, err = run(["inspect", str(tmp_path / "nope.aml")], capsys)
    assert rc == tool.EXIT_IO and "cannot read" in err


def test_usage_error_exit_64(capsys) -> None:
    with pytest.raises(SystemExit) as exc:
        tool.main(["patch"])
    assert exc.value.code == tool.EXIT_USAGE
    with pytest.raises(SystemExit) as exc:
        tool.main([])
    assert exc.value.code == tool.EXIT_USAGE


# ----------------------------------------------------------------- patch ----


@pytest.mark.parametrize("width", ["one", "byte", "word", "dword", "qword"])
def test_patch_each_width_changes_only_expected_bytes(tmp_path: Path, capsys, width: str) -> None:
    value = 1 if width == "one" else 0x10
    src_data = synth.build_dsdt(value=value, width=width)
    src = write(tmp_path, "in.aml", src_data)
    dst = tmp_path / "out.aml"
    rc, out, _ = run(["patch", str(src), "-o", str(dst)], capsys)
    assert rc == 0, out
    new = dst.read_bytes()
    assert len(new) == len(src_data)
    site = tool.find_flag_sites(src_data)[0]
    lo, hi = site.patch_range
    allowed = {tool.CHECKSUM_OFFSET, 24, 25, 26, 27, 28, 29, 30, 31} | set(range(lo, hi))
    changed = set(diff_offsets(src_data, new))
    assert changed <= allowed
    assert tool.CHECKSUM_OFFSET in changed or tool.table_sum(new) == 0
    assert 24 in changed  # OEM revision low byte 1 -> 2
    assert tool.table_sum(new) == 0
    nsite = tool.find_flag_sites(new)[0]
    assert nsite.value == 0
    assert nsite.width == site.width
    if width == "one":
        assert new[site.value_offset] == tool.ZERO_OP
    else:
        assert new[site.value_offset] == src_data[site.value_offset]  # prefix kept
    assert struct.unpack_from("<I", new, 24)[0] == 2


def test_patch_exact_offsets_on_committed_fixture(tmp_path: Path, capsys) -> None:
    src = COMMITTED_FIXTURE.read_bytes()
    site = tool.find_flag_sites(src)[0]
    res = tool.patch_table(src)
    assert diff_offsets(src, res.data) == sorted([tool.CHECKSUM_OFFSET, 24, 28, 29, 30, 31, site.payload_offset])
    assert res.data[site.payload_offset] == 0
    # checksum moves by exactly the bytes we changed: -1 (rev) +0x10 (flag)
    # and the creator-id marker ("INTL" -> "AX20").
    marker_delta = sum(src[28:32]) - sum(b"AX20")
    assert res.data[9] == (src[9] - 1 + 0x10 + marker_delta) & 0xFF
    assert sum(res.data) & 0xFF == 0


def test_patch_custom_value_and_bump(tmp_path: Path, capsys) -> None:
    src = write(tmp_path, "in.aml", synth.build_dsdt(value=0x10, width="word", oem_revision=7))
    dst = tmp_path / "o.aml"
    rc, _, _ = run(["patch", str(src), "-o", str(dst), "--value", "0x20", "--oem-rev-bump", "5"], capsys)
    assert rc == 0
    new = dst.read_bytes()
    assert tool.find_flag_sites(new)[0].value == 0x20
    assert tool.TableHeader.parse(new).oem_revision == 12


def test_patch_value_too_wide_refused(tmp_path: Path, capsys) -> None:
    src = write(tmp_path, "in.aml", synth.build_dsdt())
    rc, _, err = run(["patch", str(src), "-o", str(tmp_path / "o"), "--value", "0x100"], capsys)
    assert rc == tool.EXIT_FLAG and "does not fit" in err
    src1 = write(tmp_path, "one.aml", synth.build_dsdt(value=1, width="one"))
    rc, _, _ = run(["patch", str(src1), "-o", str(tmp_path / "o"), "--value", "2"], capsys)
    assert rc == tool.EXIT_FLAG
    assert not (tmp_path / "o").exists()


def test_patch_oem_revision_overflow_refused() -> None:
    with pytest.raises(tool.ToolError) as exc:
        tool.patch_table(synth.build_dsdt(oem_revision=0xFFFFFFFF))
    assert exc.value.code == tool.EXIT_INVALID


@pytest.mark.parametrize("sig", [b"FACP", b"APIC", b"XSDT"])
def test_patch_refuses_other_signatures(tmp_path: Path, capsys, sig: bytes) -> None:
    src = write(tmp_path, "t.aml", synth.build_dsdt(signature=sig))
    rc, _, err = run(["patch", str(src), "-o", str(tmp_path / "o")], capsys)
    assert rc == tool.EXIT_INVALID and "not DSDT or SSDT" in err


def test_patch_accepts_ssdt(tmp_path: Path, capsys) -> None:
    src = write(tmp_path, "s.aml", synth.build_dsdt(signature=b"SSDT"))
    rc, _, _ = run(["patch", str(src), "-o", str(tmp_path / "o")], capsys)
    assert rc == 0


def test_patch_refuses_bad_checksum_and_length(tmp_path: Path, capsys) -> None:
    data = bytearray(synth.build_dsdt())
    data[9] ^= 0x55
    rc, _, err = run(["patch", str(write(tmp_path, "c.aml", bytes(data))), "-o", str(tmp_path / "o")], capsys)
    assert rc == tool.EXIT_INVALID and "checksum" in err
    trunc = synth.build_dsdt()[:-4]
    rc, _, err = run(["patch", str(write(tmp_path, "t.aml", trunc)), "-o", str(tmp_path / "o")], capsys)
    assert rc == tool.EXIT_INVALID and "length" in err
    rc, _, _ = run(["patch", str(write(tmp_path, "s.aml", b"DSDT")), "-o", str(tmp_path / "o")], capsys)
    assert rc == tool.EXIT_INVALID
    assert not (tmp_path / "o").exists()


def test_patch_refuses_not_found(tmp_path: Path, capsys) -> None:
    data = bytearray(synth.build_dsdt().replace(b"config-flag\x00", b"config-flaZ\x00"))
    data[9] = tool.compute_checksum(bytes(data))
    rc, _, err = run(["patch", str(write(tmp_path, "n.aml", bytes(data))), "-o", str(tmp_path / "o")], capsys)
    assert rc == tool.EXIT_FLAG and "not found" in err


def test_patch_multiple_needs_all(tmp_path: Path, capsys) -> None:
    src_data = synth.build_dsdt(count=2)
    src = write(tmp_path, "m.aml", src_data)
    dst = tmp_path / "o.aml"
    rc, _, err = run(["patch", str(src), "-o", str(dst)], capsys)
    assert rc == tool.EXIT_FLAG and "--all" in err
    assert not dst.exists()
    rc, _, _ = run(["patch", "--all", str(src), "-o", str(dst)], capsys)
    assert rc == 0
    assert [s.value for s in tool.find_flag_sites(dst.read_bytes())] == [0, 0]
    assert len(diff_offsets(src_data, dst.read_bytes())) == 8  # 2 flags + rev + checksum + 4 marker bytes


def test_patch_is_idempotent(tmp_path: Path, capsys) -> None:
    src = write(tmp_path, "in.aml", synth.build_dsdt())
    p1, p2 = tmp_path / "p1.aml", tmp_path / "p2.aml"
    assert run(["patch", str(src), "-o", str(p1)], capsys)[0] == 0
    # --if-needed: already patched -> exit 0, nothing written
    rc, out, _ = run(["patch", "--if-needed", str(p1), "-o", str(p2)], capsys)
    assert rc == 0 and "already patched" in out
    assert not p2.exists()
    # without --if-needed: values untouched, only OEM revision + checksum move
    rc, _, err = run(["patch", str(p1), "-o", str(p2)], capsys)
    assert rc == 0 and "only the OEM revision" in err
    a, b = p1.read_bytes(), p2.read_bytes()
    assert set(diff_offsets(a, b)) <= {9, 24, 25, 26, 27, 28, 29, 30, 31}
    assert tool.TableHeader.parse(b).oem_revision == 3
    # --oem-rev-bump 0 on an already-patched table is a byte-identical copy
    p3 = tmp_path / "p3.aml"
    assert run(["patch", "--oem-rev-bump", "0", str(p1), "-o", str(p3)], capsys)[0] == 0
    assert p3.read_bytes() == a


def test_patch_if_needed_still_patches_when_needed(tmp_path: Path, capsys) -> None:
    src = write(tmp_path, "in.aml", synth.build_dsdt())
    dst = tmp_path / "o.aml"
    assert run(["patch", "--if-needed", str(src), "-o", str(dst)], capsys)[0] == 0
    assert tool.find_flag_sites(dst.read_bytes())[0].value == 0


def test_patch_zero_encoded_flag_is_already_patched(tmp_path: Path, capsys) -> None:
    src = write(tmp_path, "z.aml", synth.build_dsdt(value=0, width="zero"))
    rc, out, _ = run(["patch", "--if-needed", str(src), "-o", str(tmp_path / "o")], capsys)
    assert rc == 0 and "already patched" in out


# ---------------------------------------------------------------- verify ----


def test_verify_exit_codes(tmp_path: Path, capsys) -> None:
    src = write(tmp_path, "in.aml", synth.build_dsdt())
    assert run(["verify", str(src)], capsys)[0] == tool.EXIT_MISMATCH
    assert run(["verify", "--value", "0x10", str(src)], capsys)[0] == tool.EXIT_OK
    p = tmp_path / "p.aml"
    run(["patch", str(src), "-o", str(p)], capsys)
    rc, out, _ = run(["verify", str(p)], capsys)
    assert rc == tool.EXIT_OK and out.strip().endswith("1 site(s)")
    bad = bytearray(p.read_bytes())
    bad[9] ^= 1
    assert run(["verify", str(write(tmp_path, "bad.aml", bytes(bad)))], capsys)[0] == tool.EXIT_INVALID


# ------------------------------------------------------------------ diff ----


def test_diff_reports_only_expected(tmp_path: Path, capsys) -> None:
    src = write(tmp_path, "a.aml", synth.build_dsdt())
    p = tmp_path / "b.aml"
    run(["patch", str(src), "-o", str(p)], capsys)
    rc, out, _ = run(["diff", str(src), str(p)], capsys)
    assert rc == tool.EXIT_MISMATCH  # they differ
    assert "header checksum" in out and "OEM revision" in out and "value" in out
    assert "7 differing byte(s), 0 outside" in out  # checksum, OEM rev, 4 marker bytes, flag
    assert run(["diff", "--check-expected", str(src), str(p)], capsys)[0] == 0
    assert run(["diff", str(src), str(src)], capsys)[0] == 0


def test_diff_flags_unexpected_changes(tmp_path: Path, capsys) -> None:
    a = synth.build_dsdt()
    b = bytearray(a)
    b[40] ^= 1  # inside the AML body, not a patch region
    rc, out, _ = run(["diff", "--check-expected", str(write(tmp_path, "a", a)),
                      str(write(tmp_path, "b", bytes(b)))], capsys)
    assert rc == tool.EXIT_MISMATCH and "UNEXPECTED" in out
    rc, out, _ = run(["diff", "--check-expected", str(tmp_path / "a"),
                      str(write(tmp_path, "c", a + b"\x00"))], capsys)
    assert rc == tool.EXIT_MISMATCH and "length differs" in out


# ------------------------------------------------------------------ cpio ----


def _patched(tmp_path: Path, capsys) -> Path:
    src = write(tmp_path, "in.aml", synth.build_dsdt())
    p = tmp_path / "p.aml"
    assert run(["patch", str(src), "-o", str(p)], capsys)[0] == 0
    return p


def test_mkinitrd_layout(tmp_path: Path, capsys) -> None:
    p = _patched(tmp_path, capsys)
    img = tmp_path / "x.img"
    assert run(["mkinitrd", str(p), "-o", str(img)], capsys)[0] == 0
    blob = img.read_bytes()
    assert blob[:6] == b"070701"
    assert len(blob) % 4 == 0
    entries = tool.read_newc(blob)
    assert [e.name for e in entries] == [
        "kernel", "kernel/firmware", "kernel/firmware/acpi", "kernel/firmware/acpi/DSDT.aml"]
    for e in entries[:3]:
        assert e.mode == 0o040755 and e.data == b"" and e.nlink == 2
    f = entries[3]
    assert f.mode == 0o100644 and f.data == p.read_bytes()
    assert {e.uid for e in entries} == {0} and {e.mtime for e in entries} == {0}
    assert len({e.ino for e in entries}) == 4
    assert b"TRAILER!!!\x00" in blob


def test_mkinitrd_is_reproducible_and_honours_mtime(tmp_path: Path, capsys) -> None:
    p = _patched(tmp_path, capsys)
    a, b, c = tmp_path / "a.img", tmp_path / "b.img", tmp_path / "c.img"
    run(["mkinitrd", str(p), "-o", str(a)], capsys)
    run(["mkinitrd", str(p), "-o", str(b)], capsys)
    assert a.read_bytes() == b.read_bytes()
    run(["mkinitrd", "--mtime", "1700000000", str(p), "-o", str(c)], capsys)
    assert {e.mtime for e in tool.read_newc(c.read_bytes())} == {1700000000}


def test_mkinitrd_refuses_unpatched_or_other_tables(tmp_path: Path, capsys) -> None:
    src = write(tmp_path, "in.aml", synth.build_dsdt())
    rc, _, err = run(["mkinitrd", str(src), "-o", str(tmp_path / "x.img")], capsys)
    assert rc == tool.EXIT_MISMATCH and "patch" in err
    assert not (tmp_path / "x.img").exists()
    assert run(["mkinitrd", "--force", str(src), "-o", str(tmp_path / "x.img")], capsys)[0] == 0
    facp = write(tmp_path, "f.aml", synth.build_dsdt(signature=b"FACP", value=0, width="zero"))
    assert run(["mkinitrd", str(facp), "-o", str(tmp_path / "y.img")], capsys)[0] == tool.EXIT_INVALID
    bad = bytearray(synth.build_dsdt(value=0, width="zero"))
    bad[9] ^= 1
    rc, _, _ = run(["mkinitrd", str(write(tmp_path, "b.aml", bytes(bad))), "-o", str(tmp_path / "z.img")], capsys)
    assert rc == tool.EXIT_INVALID


def test_mkinitrd_ssdt_for_vm_tests(tmp_path: Path, capsys) -> None:
    ssdt = write(tmp_path, "s.aml", synth.build_dsdt(signature=b"SSDT", value=0, width="zero"))
    img = tmp_path / "s.img"
    assert run(["mkinitrd", str(ssdt), "-o", str(img)], capsys)[0] == 0
    assert tool.read_newc(img.read_bytes())[-1].name == "kernel/firmware/acpi/SSDT.aml"


def test_newc_roundtrip_and_padding() -> None:
    entries = [tool.CpioEntry("a", 0o100644, b"x" * n, i + 1) for i, n in enumerate(range(6))]
    for e in entries:
        e.name = "f%d" % len(e.data)
    back = tool.read_newc(tool.write_newc(entries))
    assert [(e.name, e.data) for e in back] == [(e.name, e.data) for e in entries]


@pytest.mark.parametrize("blob", [b"", b"070702" + b"0" * 104, b"garbage" * 20])
def test_read_newc_rejects_bad_input(blob: bytes) -> None:
    with pytest.raises(tool.ToolError) as exc:
        tool.read_newc(blob)
    assert exc.value.code == tool.EXIT_INVALID


def test_read_newc_rejects_missing_trailer(tmp_path: Path, capsys) -> None:
    blob = tool.write_newc([tool.CpioEntry("f", 0o100644, b"abc", 1)])
    cut = blob[: blob.index(b"070701", 10)]
    with pytest.raises(tool.ToolError):
        tool.read_newc(cut)


def test_list_subcommand(tmp_path: Path, capsys) -> None:
    p = _patched(tmp_path, capsys)
    img = tmp_path / "x.img"
    run(["mkinitrd", str(p), "-o", str(img)], capsys)
    rc, out, _ = run(["list", str(img)], capsys)
    assert rc == 0
    lines = out.strip().splitlines()
    assert len(lines) == 4
    assert lines[0].startswith("drwxr-xr-x")
    assert lines[3].startswith("-rw-r--r--") and lines[3].endswith("kernel/firmware/acpi/DSDT.aml")
    assert " %d " % len(p.read_bytes()) in lines[3]
    assert run(["list", str(p)], capsys)[0] == tool.EXIT_INVALID


@pytest.mark.skipif(shutil.which("cpio") is None, reason="system cpio not installed")
def test_system_cpio_extracts_image(tmp_path: Path, capsys) -> None:
    p = _patched(tmp_path, capsys)
    img = tmp_path / "x.img"
    run(["mkinitrd", str(p), "-o", str(img)], capsys)
    dest = tmp_path / "extract"
    dest.mkdir()
    with open(str(img), "rb") as fh:
        subprocess.run(["cpio", "-id", "--quiet"], stdin=fh, cwd=str(dest), check=True,
                       capture_output=True)
    extracted = dest / "kernel" / "firmware" / "acpi" / "DSDT.aml"
    assert extracted.read_bytes() == p.read_bytes()
    with open(str(img), "rb") as fh:
        listing = subprocess.run(["cpio", "-t", "--quiet"], stdin=fh, check=True,
                                 capture_output=True).stdout.decode().split()
    assert listing == ["kernel", "kernel/firmware", "kernel/firmware/acpi",
                       "kernel/firmware/acpi/DSDT.aml"]


# -------------------------------------------------------- build-override ----

needs_bash = pytest.mark.skipif(shutil.which("bash") is None, reason="bash not installed")


def _fake_root(tmp_path: Path, dsdt: bytes, bios: str = "RC74XA.301") -> Path:
    root = tmp_path / "root"
    tables = root / "sys" / "firmware" / "acpi" / "tables"
    tables.mkdir(parents=True)
    (tables / "DSDT").write_bytes(dsdt)
    dmi = root / "sys" / "class" / "dmi" / "id"
    dmi.mkdir(parents=True)
    (dmi / "bios_version").write_text(bios + "\n")
    return root


def _bo(args: List[str], root: "Path | None" = None) -> subprocess.CompletedProcess:
    env: Dict[str, str] = dict(os.environ)
    env["PYTHON"] = sys.executable
    env.pop("AX20_ROOT", None)
    if root is not None:
        env["AX20_ROOT"] = str(root)
    return subprocess.run(["bash", str(BUILD_OVERRIDE)] + args, env=env,
                          capture_output=True, text=True)


def _info(out: Path) -> Dict[str, str]:
    d = {}
    for line in (out / "BUILD-INFO").read_text().splitlines():
        k, _, v = line.partition("=")
        d[k] = v
    return d


@needs_bash
def test_build_override_from_file(tmp_path: Path) -> None:
    out = tmp_path / "out"
    r = _bo(["--out", str(out), "--table", str(COMMITTED_FIXTURE)])
    assert r.returncode == 0, r.stderr
    img = out / "ally-x20-steamos-acpi.img"
    for name in ("ally-x20-steamos-acpi.img", "TABLE.patched.aml", "TABLE.orig.aml", "BUILD-INFO"):
        assert (out / name).is_file()
    info = _info(out)
    assert info["flag_value_before"] == "0x10" and info["flag_value_after"] == "0x0"
    assert info["input_sha256"] == tool.sha256(COMMITTED_FIXTURE.read_bytes())
    assert info["output_sha256"] == tool.sha256(img.read_bytes())
    assert info["tool_version"] == tool.__version__
    assert info["oem_revision_after"] == "0x00000002"
    last = r.stdout.strip().splitlines()[-1]
    assert last == "%s  %s" % (info["output_sha256"], img)
    entries = tool.read_newc(img.read_bytes())
    assert entries[-1].data == (out / "TABLE.patched.aml").read_bytes()
    assert (out / "TABLE.orig.aml").read_bytes() == COMMITTED_FIXTURE.read_bytes()
    assert not [p for p in out.iterdir() if p.name.startswith(".build-override")]


@needs_bash
def test_build_override_usage(tmp_path: Path) -> None:
    assert _bo([]).returncode == 64
    assert _bo(["--out"]).returncode == 64
    assert _bo(["--bogus"]).returncode == 64
    assert _bo(["--out", str(tmp_path / "o"), "--dsdt", str(tmp_path / "missing")]).returncode == 4


@needs_bash
def test_build_override_already_zero_exit_3(tmp_path: Path) -> None:
    z = write(tmp_path, "z.aml", synth.build_dsdt(value=0, width="byte"))
    r = _bo(["--out", str(tmp_path / "o"), "--dsdt", str(z)])
    assert r.returncode == 3 and "no override needed" in r.stderr
    assert not (tmp_path / "o" / "ally-x20-steamos-acpi.img").exists()


@needs_bash
def test_build_override_invalid_and_ambiguous(tmp_path: Path) -> None:
    bad = bytearray(synth.build_dsdt())
    bad[9] ^= 1
    assert _bo(["--out", str(tmp_path / "o"), "--dsdt",
                str(write(tmp_path, "b.aml", bytes(bad)))]).returncode == 2
    two = write(tmp_path, "two.aml", synth.build_dsdt(count=2))
    assert _bo(["--out", str(tmp_path / "o"), "--dsdt", str(two)]).returncode == 3
    assert _bo(["--out", str(tmp_path / "o"), "--dsdt", str(two), "--all"]).returncode == 0


@needs_bash
def test_build_override_dumps_from_sysfs_and_survives_active_override(tmp_path: Path) -> None:
    firmware = synth.build_dsdt()
    root = _fake_root(tmp_path, firmware)
    out = tmp_path / "out"
    r = _bo(["--out", str(out)], root=root)
    assert r.returncode == 0, r.stderr
    first = _info(out)
    assert first["bios_version"] == "RC74XA.301"
    assert first["input"].endswith("/sys/firmware/acpi/tables/DSDT")
    assert first["table_signature"] == "DSDT" and first["table_source"] == "DSDT"
    img1 = (out / "ally-x20-steamos-acpi.img").read_bytes()

    # Reboot with the override active: sysfs now shows our patched table.
    sysfs = root / "sys" / "firmware" / "acpi" / "tables" / "DSDT"
    sysfs.write_bytes((out / "TABLE.patched.aml").read_bytes())
    r = _bo(["--out", str(out)], root=root)
    assert r.returncode == 0, r.stderr
    assert "override active" in r.stderr
    assert (out / "ally-x20-steamos-acpi.img").read_bytes() == img1
    assert _info(out)["input_sha256"] == tool.sha256(firmware)

    # BIOS update while the override is active: refuse to reuse the old dump.
    (root / "sys" / "class" / "dmi" / "id" / "bios_version").write_text("RC74XA.302\n")
    r = _bo(["--out", str(out)], root=root)
    assert r.returncode == 5 and "BIOS changed" in r.stderr


@needs_bash
def test_build_override_firmware_already_fixed(tmp_path: Path) -> None:
    root = _fake_root(tmp_path, synth.build_dsdt(value=0, width="zero"))
    r = _bo(["--out", str(tmp_path / "out")], root=root)
    assert r.returncode == 3


@needs_bash
def test_build_override_unreadable_sysfs(tmp_path: Path) -> None:
    root = tmp_path / "empty"
    root.mkdir()
    r = _bo(["--out", str(tmp_path / "out")], root=root)
    assert r.returncode == 4 and "cannot read" in r.stderr


@needs_bash
def test_build_override_finds_flag_in_an_ssdt(tmp_path: Path) -> None:
    """Real X20: the DSDT carries no flag; SSDT8 (AMD/OEMACP) does."""
    dsdt_without = synth.build_dsdt().replace(b"acp-audio-config-flag\x00", b"acp-audio-config-flaZ\x00")
    root = _fake_root(tmp_path, dsdt_without)
    tables = root / "sys" / "firmware" / "acpi" / "tables"
    (tables / "SSDT1").write_bytes(synth.build_dsdt(signature=b"SSDT").replace(
        b"acp-audio-config-flag\x00", b"acp-audio-config-flaZ\x00"))
    (tables / "SSDT8").write_bytes(synth.build_dsdt(signature=b"SSDT", value=0x10))
    out = tmp_path / "out"
    r = _bo(["--out", str(out)], root=root)
    assert r.returncode == 0, r.stderr
    assert "lives in SSDT8" in r.stderr
    info = _info(out)
    assert info["table_signature"] == "SSDT" and info["table_source"] == "SSDT8"
    assert info["flag_value_before"] == "0x10" and info["flag_value_after"] == "0x0"
    entries = tool.read_newc((out / "ally-x20-steamos-acpi.img").read_bytes())
    assert entries[-1].name == "kernel/firmware/acpi/SSDT.aml"
    # Override active: sysfs SSDT8 is now our table -> rebuilt from the saved original.
    (tables / "SSDT8").write_bytes((out / "TABLE.patched.aml").read_bytes())
    r = _bo(["--out", str(out)], root=root)
    assert r.returncode == 0 and "override active" in r.stderr


@needs_bash
def test_build_override_no_table_carries_flag(tmp_path: Path) -> None:
    root = _fake_root(tmp_path, synth.build_dsdt().replace(b"acp-audio-config-flag\x00", b"acp-audio-config-flaZ\x00"))
    r = _bo(["--out", str(tmp_path / "out")], root=root)
    assert r.returncode == 3 and "not found in any table" in r.stderr


def test_patch_sets_creator_marker_and_inspect_reports_it(capsys) -> None:
    src = synth.build_dsdt()
    assert not tool.is_our_override(src)
    out = tool.patch_table(src).data
    assert tool.is_our_override(out)
    assert out[tool.CREATOR_ID_OFFSET:tool.CREATOR_ID_OFFSET + 4] == b"AX20"
    # Patching an already-patched table keeps the marker and changes nothing else but the OEM rev.
    again = tool.patch_table(out).data
    assert tool.is_our_override(again)
    assert set(diff_offsets(out, again)) <= {9, 24, 25, 26, 27}


@needs_bash
def test_build_override_reuses_live_override_without_saved_original(tmp_path: Path) -> None:
    """Fresh install after an uninstall: sysfs shows our patched table and no
    original is saved. The wrapper must package the live table instead of
    reporting 'no override needed'."""
    patched = tool.patch_table(synth.build_dsdt(signature=b"SSDT")).data
    root = _fake_root(tmp_path, synth.build_dsdt().replace(b"acp-audio-config-flag\x00", b"acp-audio-config-flaZ\x00"))
    (root / "sys" / "firmware" / "acpi" / "tables" / "SSDT8").write_bytes(patched)
    out = tmp_path / "out"
    r = _bo(["--out", str(out)], root=root)
    assert r.returncode == 0, r.stderr
    assert "reusing the live table" in r.stderr
    info = _info(out)
    assert info["prepatched"] == "1" and info["table_source"] == "SSDT8"
    assert (out / "TABLE.patched.aml").read_bytes() == patched
    entries = tool.read_newc((out / "ally-x20-steamos-acpi.img").read_bytes())
    assert entries[-1].data == patched
    # A table whose flag is 0 WITHOUT the marker is a real BIOS fix: exit 3.
    (root / "sys" / "firmware" / "acpi" / "tables" / "SSDT8").write_bytes(synth.build_dsdt(signature=b"SSDT", value=0, width="zero"))
    r = _bo(["--out", str(tmp_path / "out2")], root=root)
    assert r.returncode == 3
