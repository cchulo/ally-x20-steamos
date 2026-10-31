#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Live button viewer for the ROG Xbox Ally X20 (and other handhelds).

Prints one line per input event (decoded key/button name, press/release) from
every /dev/input/event* device and, in parallel, every raw report from the
ASUS N-KEY HID interfaces (/dev/hidraw*), so you can see what the stock kernel
does with a button before and after our patches. Stdlib only, Python 3.9+.

    sudo python3 vm/guest/watch-buttons.py            # all devices
    sudo python3 vm/guest/watch-buttons.py --no-raw   # input events only
    sudo python3 vm/guest/watch-buttons.py --filter asus,xbox,ally

What to expect on an X20 with the patched hid-asus-ally (kernel 7.2.7-valve2)
and qam_mode=0 (InputPlumber sets it; docs/inputplumber.md section 6):
  Xbox button          -> BTN_MODE from "ASUS ROG Ally X Gamepad"
  Armoury Crate (TL)   -> raw "5a a6 ..." then "5a 00 ...", KEY_F16
  Capture (TR)         -> raw "5a a0 ..." then "5a 00 ...", KEY_PROG2
  A button             -> BTN_SOUTH
Stock driver: the top-right button gives the raw report and no input event.

InputPlumber grabs (EVIOCGRAB) the ASUS evdev nodes it uses, so they print
nothing while it runs; the device list marks them "GRABBED". hidraw reports
still reach every reader. To see what InputPlumber sends on, watch its
virtual device (in Desktop Mode an Xbox pad: QuickAccess shows as BTN_MODE
then BTN_SOUTH 160 ms later, Screenshot as KEY_RECORD), or stop the daemon
to see the kernel's keys.
Ctrl-C to quit. Needs root (input and hidraw nodes are root:input / root).
"""
from __future__ import annotations

import argparse
import fcntl
import glob
import os
import select
import struct
import sys
import time

EVENT_FMT = "llHHi"  # struct input_event on 64-bit: timeval(sec, usec), type, code, value
EVENT_SIZE = struct.calcsize(EVENT_FMT)
EV_SYN, EV_KEY, EV_ABS, EV_MSC = 0x00, 0x01, 0x03, 0x04

KEY_NAMES = {
    1: "KEY_ESC", 28: "KEY_ENTER", 29: "KEY_LEFTCTRL", 42: "KEY_LEFTSHIFT", 56: "KEY_LEFTALT",
    57: "KEY_SPACE", 102: "KEY_HOME", 103: "KEY_UP", 105: "KEY_LEFT", 106: "KEY_RIGHT",
    108: "KEY_DOWN", 113: "KEY_MUTE", 114: "KEY_VOLUMEDOWN", 115: "KEY_VOLUMEUP",
    116: "KEY_POWER", 125: "KEY_LEFTMETA", 139: "KEY_MENU", 148: "KEY_PROG1",
    149: "KEY_PROG2 (X20 capture)", 167: "KEY_RECORD", 184: "KEY_F14", 185: "KEY_F15",
    186: "KEY_F16", 187: "KEY_F17", 188: "KEY_F18", 191: "KEY_F21", 192: "KEY_F22",
    202: "KEY_PROG3", 203: "KEY_PROG4",
    224: "KEY_BRIGHTNESSDOWN", 225: "KEY_BRIGHTNESSUP", 240: "KEY_UNKNOWN",
    0x100: "BTN_0", 0x101: "BTN_1", 0x102: "BTN_2",
    0x110: "BTN_LEFT", 0x111: "BTN_RIGHT", 0x112: "BTN_MIDDLE",
    0x130: "BTN_SOUTH (A)", 0x131: "BTN_EAST (B)", 0x133: "BTN_NORTH (X)", 0x134: "BTN_WEST (Y)",
    0x136: "BTN_TL", 0x137: "BTN_TR", 0x138: "BTN_TL2", 0x139: "BTN_TR2",
    0x13a: "BTN_SELECT (View)", 0x13b: "BTN_START (Menu)", 0x13c: "BTN_MODE (Xbox)",
    0x13d: "BTN_THUMBL", 0x13e: "BTN_THUMBR",
    0x2c0: "BTN_TRIGGER_HAPPY1 (paddle)", 0x2c1: "BTN_TRIGGER_HAPPY2 (paddle)",
    0x2c2: "BTN_TRIGGER_HAPPY3", 0x2c3: "BTN_TRIGGER_HAPPY4",
}
ABS_NAMES = {0x10: "ABS_HAT0X (dpad)", 0x11: "ABS_HAT0Y (dpad)"}

ASUS_VID = 0x0B05
EVIOCGNAME = lambda length: (2 << 30) | (ord("E") << 8) | 0x06 | (length << 16)  # noqa: E731
EVIOCGRAB = (1 << 30) | (ord("E") << 8) | 0x90 | (4 << 16)  # _IOW('E', 0x90, int)


def dev_name(fd: int) -> str:
    buf = bytearray(256)
    try:
        fcntl.ioctl(fd, EVIOCGNAME(len(buf)), buf)
        return buf.split(b"\x00", 1)[0].decode(errors="replace")
    except OSError:
        return "?"


def grabbed_elsewhere(fd: int) -> bool:
    """True if another process (InputPlumber) holds EVIOCGRAB on the device.

    Tries to grab it and releases at once; EBUSY means someone else has it.
    """
    try:
        fcntl.ioctl(fd, EVIOCGRAB, 1)
    except OSError:
        return True
    try:
        fcntl.ioctl(fd, EVIOCGRAB, 0)
    except OSError:
        pass
    return False


def hidraw_info(path: str) -> tuple[str, int]:
    base = "/sys/class/hidraw/%s/device/uevent" % os.path.basename(path)
    name, vid = "?", 0
    try:
        with open(base) as fh:
            for line in fh:
                if line.startswith("HID_NAME="):
                    name = line.strip().split("=", 1)[1]
                elif line.startswith("HID_ID="):
                    vid = int(line.strip().split(":")[1], 16)
    except OSError:
        pass
    return name, vid


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-raw", action="store_true", help="do not read hidraw nodes")
    ap.add_argument("--all-raw", action="store_true", help="show raw reports from every hidraw node, not only ASUS")
    ap.add_argument("--filter", default="", help="comma-separated substrings; only input devices whose name matches")
    ap.add_argument("--show-abs", action="store_true", help="also print stick/trigger axis events (noisy)")
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(line_buffering=True)  # also readable when piped/tee'd
    except (AttributeError, ValueError):
        pass
    if os.geteuid() != 0:
        print("warning: not root; most devices will be unreadable (use sudo)", file=sys.stderr)

    fds: dict[int, tuple[str, str]] = {}  # fd -> (kind, label)
    wanted = [w.strip().lower() for w in args.filter.split(",") if w.strip()]
    for path in sorted(glob.glob("/dev/input/event*"), key=lambda p: int(p.rsplit("event", 1)[1])):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            print("skip %s: %s" % (path, exc.strerror), file=sys.stderr)
            continue
        name = dev_name(fd)
        if wanted and not any(w in name.lower() for w in wanted):
            os.close(fd)
            continue
        label = "%s %s" % (os.path.basename(path), name)
        if grabbed_elsewhere(fd):
            label += " (GRABBED by another process: prints nothing)"
        fds[fd] = ("ev", label)
    if not args.no_raw:
        for path in sorted(glob.glob("/dev/hidraw*"), key=lambda p: int(p.rsplit("hidraw", 1)[1])):
            name, vid = hidraw_info(path)
            if vid != ASUS_VID and not args.all_raw:
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError as exc:
                print("skip %s: %s" % (path, exc.strerror), file=sys.stderr)
                continue
            fds[fd] = ("raw", "%s %s" % (os.path.basename(path), name))
    if not fds:
        print("nothing to watch", file=sys.stderr)
        return 1
    print("watching %d device(s); press buttons, Ctrl-C to quit" % len(fds))
    for fd, (kind, label) in sorted(fds.items(), key=lambda kv: kv[1]):
        print("  [%s] %s" % (kind, label))
    print()
    t0 = time.monotonic()
    try:
        while True:
            ready, _, _ = select.select(list(fds), [], [], 1.0)
            for fd in ready:
                kind, label = fds[fd]
                try:
                    data = os.read(fd, 4096)
                except BlockingIOError:
                    continue
                except OSError as exc:
                    print("%8.3f  %s: read error %s (device gone?)" % (time.monotonic() - t0, label, exc.strerror))
                    os.close(fd)
                    del fds[fd]
                    continue
                ts = time.monotonic() - t0
                if kind == "raw":
                    print("%8.3f  RAW   %-28s %s" % (ts, label[:28], " ".join("%02x" % b for b in data[:16]) + (" ..." if len(data) > 16 else "")))
                    continue
                for off in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    _s, _us, etype, code, value = struct.unpack_from(EVENT_FMT, data, off)
                    if etype == EV_KEY:
                        state = {0: "release", 1: "PRESS", 2: "repeat"}.get(value, str(value))
                        print("%8.3f  KEY   %-28s %-26s %s" % (ts, label[:28], KEY_NAMES.get(code, "code 0x%x" % code), state))
                    elif etype == EV_ABS and (args.show_abs or code in ABS_NAMES):
                        print("%8.3f  ABS   %-28s %-26s %d" % (ts, label[:28], ABS_NAMES.get(code, "abs 0x%x" % code), value))
                    elif etype == EV_MSC and code == 0x04:  # MSC_SCAN: the HID usage behind a key
                        print("%8.3f  SCAN  %-28s usage 0x%x" % (ts, label[:28], value))
    except KeyboardInterrupt:
        print("\nbye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
