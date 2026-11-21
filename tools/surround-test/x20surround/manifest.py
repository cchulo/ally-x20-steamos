# SPDX-License-Identifier: GPL-2.0-only
"""The candidate manifest: one JSON file listing every HRIR candidate with
its file, hash, level trim and offline check results. Written on the
development machine, read (and extended with the local-only user file) by
the on-device switcher."""

import hashlib
import json
import os

from . import checks, wav
from .layout import HESUVI, RATE

VERSION = 1


class CandidateError(ValueError):
    pass


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_hrir(path):
    """Read a candidate file and insist on 14 channels at 48 kHz."""
    try:
        rate, channels = wav.read(path)
    except (OSError, wav.WavError) as e:
        raise CandidateError(str(e))
    if len(channels) != len(HESUVI):
        raise CandidateError("%s: %d channels, a HeSuVi HRIR file has %d"
                             % (path, len(channels), len(HESUVI)))
    if rate != RATE:
        raise CandidateError("%s: %d Hz, the rig needs the %d Hz file" % (path, rate, RATE))
    return channels


def describe(path, cid, **meta):
    """Run the checks on a file and return its manifest entry."""
    channels = read_hrir(path)
    trim, results = checks.run_all(channels)
    entry = {
        "id": cid,
        "file": path,
        "sha256": sha256(path),
        "samples": len(channels[0]),
        "trim_db": round(trim, 3),
        "status": checks.worst_status(results),
        "checks": [{"name": r.name, "status": r.status, "detail": r.detail} for r in results],
    }
    entry.update({k: v for k, v in meta.items() if v})
    return entry


def empty():
    return {"version": VERSION, "rate": RATE, "candidates": []}


def load(path):
    with open(path) as f:
        data = json.load(f)
    if data.get("version") != VERSION:
        raise CandidateError("%s: unsupported manifest version %r" % (path, data.get("version")))
    return data


def save(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def add(data, entry, base=None):
    """Insert or replace an entry; store the file path relative to `base`
    (the manifest's directory) when it is inside it."""
    entry = dict(entry)
    if base:
        full = os.path.abspath(entry["file"])
        root = os.path.abspath(base)
        if full.startswith(root + os.sep):
            entry["file"] = os.path.relpath(full, root)
        else:
            entry["file"] = full
    data["candidates"] = [c for c in data["candidates"] if c["id"] != entry["id"]] + [entry]
    return entry


def find(data, cid):
    for c in data["candidates"]:
        if c["id"] == cid:
            return c
    raise CandidateError("no candidate %r in the manifest" % cid)


def resolve(entry, base):
    """Absolute path of an entry's file."""
    path = entry["file"]
    return path if os.path.isabs(path) else os.path.join(base, path)


def report(data):
    """A text table of every candidate's check results."""
    names = ("routing", "headroom", "symmetry", "centre")
    lines = ["%-26s %9s  %-8s %-8s %-8s %-8s" % (("candidate", "trim") + names)]
    for c in data["candidates"]:
        status = {r["name"]: r["status"] for r in c["checks"]}
        lines.append("%-26s %+6.2f dB  %-8s %-8s %-8s %-8s" % (
            (c["id"], c["trim_db"]) + tuple(status.get(n, "-") for n in names)))
    lines.append("")
    for c in data["candidates"]:
        lines.append("%s (%s)" % (c["id"], c.get("licence", "licence not recorded")))
        for r in c["checks"]:
            lines.append("  %-9s %-4s %s" % (r["name"], r["status"], r["detail"]))
    return "\n".join(lines) + "\n"
