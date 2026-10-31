#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Graded force-feedback (rumble) test, stdlib only.

Uploads an FF_RUMBLE effect to an evdev device and plays it at the given
strengths for a few seconds each, so the owner can hear/feel at which level a
side effect (e.g. white noise from the speakers on the ROG Xbox Ally X20)
appears.

    sudo python3 vm/guest/rumble-test.py                    # auto-pick the gamepad, 25 50 75 100 %
    sudo python3 vm/guest/rumble-test.py --levels 10 30 60 --seconds 3
    sudo python3 vm/guest/rumble-test.py --device /dev/input/event16 --motor weak

The device is chosen by name ("ASUS ROG Ally X Gamepad" first, then any
device whose name contains "X-Box"/"Xbox"/"Gamepad"). Uploading FF effects
works even while another process (InputPlumber) has the device grabbed.
"""
from __future__ import annotations

import argparse
import fcntl
import glob
import os
import struct
import sys
import time

# struct ff_effect on x86_64 is 48 bytes: type u16, id s16, direction u16,
# trigger {button u16, interval u16}, replay {length u16, delay u16} = 14 bytes,
# then 2 bytes of padding because the union (which holds a pointer in
# ff_periodic_effect) is 8-byte aligned: the union starts at offset 16.
FF_EFFECT_SIZE = 48
FF_UNION_OFFSET = 16
FF_RUMBLE = 0x50
EV_FF = 0x15
EVIOCSFF = (1 << 30) | (FF_EFFECT_SIZE << 16) | (ord("E") << 8) | 0x80  # _IOW('E', 0x80, struct ff_effect)
EVIOCRMFF = (1 << 30) | (4 << 16) | (ord("E") << 8) | 0x81              # _IOW('E', 0x81, int)
EVIOCGNAME = lambda length: (2 << 30) | (length << 16) | (ord("E") << 8) | 0x06  # noqa: E731


def dev_name(fd: int) -> str:
    buf = bytearray(256)
    try:
        fcntl.ioctl(fd, EVIOCGNAME(len(buf)), buf)
        return buf.split(b"\x00", 1)[0].decode(errors="replace")
    except OSError:
        return "?"


def pick_device(preferred: str | None) -> str:
    if preferred:
        return preferred
    candidates = []
    for path in sorted(glob.glob("/dev/input/event*"), key=lambda p: int(p.rsplit("event", 1)[1])):
        try:
            fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        except OSError:
            continue
        name = dev_name(fd)
        os.close(fd)
        if "ASUS ROG Ally" in name and "Gamepad" in name:
            return path
        if any(k in name for k in ("X-Box", "Xbox", "Gamepad", "Controller")):
            candidates.append(path)
    if not candidates:
        sys.exit("no gamepad found; pass --device /dev/input/eventN")
    return candidates[0]


def upload(fd: int, strong: int, weak: int, length_ms: int) -> int:
    # id = -1 asks the kernel to allocate; it writes the id back into the buffer.
    hdr = struct.pack("<HhHHHHH", FF_RUMBLE, -1, 0, 0, 0, length_ms, 0)
    buf = bytearray(FF_EFFECT_SIZE)
    buf[:len(hdr)] = hdr
    struct.pack_into("<HH", buf, FF_UNION_OFFSET, strong, weak)
    fcntl.ioctl(fd, EVIOCSFF, buf)
    return struct.unpack_from("<h", buf, 2)[0]


def play(fd: int, effect_id: int, on: bool) -> None:
    now = time.time()
    sec = int(now)
    usec = int((now - sec) * 1_000_000)
    os.write(fd, struct.pack("llHHi", sec, usec, EV_FF, effect_id, 1 if on else 0))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", help="evdev node (default: auto)")
    ap.add_argument("--levels", nargs="+", type=int, default=[25, 50, 75, 100], help="percent levels to play")
    ap.add_argument("--seconds", type=float, default=2.0, help="duration per level")
    ap.add_argument("--pause", type=float, default=1.5, help="silence between levels")
    ap.add_argument("--motor", choices=("both", "strong", "weak"), default="both")
    ap.add_argument("--pulse", type=float, default=0.0,
                    help="Hz: instead of a plateau, switch the effect on/off at this rate (imitates game rumble)")
    args = ap.parse_args()
    path = pick_device(args.device)
    fd = os.open(path, os.O_RDWR)
    print("device: %s (%s)" % (path, dev_name(fd)), flush=True)
    try:
        for pct in args.levels:
            mag = max(0, min(100, pct)) * 0xFFFF // 100
            strong = mag if args.motor in ("both", "strong") else 0
            weak = mag if args.motor in ("both", "weak") else 0
            eid = upload(fd, strong, weak, int(args.seconds * 1000) + 500)
            print("rumble %3d%% (strong=%5d weak=%5d) for %.1fs ... " % (pct, strong, weak, args.seconds), end="", flush=True)
            if args.pulse > 0:
                half = 0.5 / args.pulse
                end = time.time() + args.seconds
                while time.time() < end:
                    play(fd, eid, True)
                    time.sleep(half)
                    play(fd, eid, False)
                    time.sleep(half)
            else:
                play(fd, eid, True)
                time.sleep(args.seconds)
                play(fd, eid, False)
            fcntl.ioctl(fd, EVIOCRMFF, eid)
            print("done", flush=True)
            time.sleep(args.pause)
    finally:
        os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
