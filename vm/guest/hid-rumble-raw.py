#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Write raw rumble reports to the ASUS N-KEY MCU of the ROG Xbox Ally X20.

Bypasses the kernel force-feedback path and InputPlumber, so each candidate
report format can be tried on its own, ideally with the speakers muted, to
find which one (if any) makes the speakers hiss. Every report sent is printed
as hex. Stdlib only, Python 3.9+. Needs root (hidraw nodes are root-only).
See docs/rumble-analysis.md for what each format means.

    sudo python3 vm/guest/hid-rumble-raw.py list
    sudo python3 vm/guest/hid-rumble-raw.py send --strong 100 --weak 100
    sudo python3 vm/guest/hid-rumble-raw.py send --strong 127 --weak 127 --transport feature
    sudo python3 vm/guest/hid-rumble-raw.py send --strong 60 --rate 125 --jitter 30
    sudo python3 vm/guest/hid-rumble-raw.py send --lt 50 --rt 50          # trigger motors
    sudo python3 vm/guest/hid-rumble-raw.py send --raw "0d 0f 00 00 64 64 ff 00 eb"
    sudo python3 vm/guest/hid-rumble-raw.py sweep --values 50 90 100 101 110 127
    sudo python3 vm/guest/hid-rumble-raw.py matrix                        # guided run of all candidates
    sudo python3 vm/guest/hid-rumble-raw.py intensity 100 100             # MCU vibration intensity
    sudo python3 vm/guest/hid-rumble-raw.py usbmon --seconds 30           # watch what a game sends
    sudo python3 vm/guest/hid-rumble-raw.py off

The 0x0d rumble report (9 bytes):
    [0] 0x0d report id    [1] enable mask (0x0f = all four actuators)
    [2] left trigger      [3] right trigger
    [4] strong (left)     [5] weak (right)      magnitudes: 0..100 per spec
    [6] duration, 10 ms   [7] start delay, 10 ms   [8] loop count
Transports: "output" = write() on the hidraw node (an output report, what
InputPlumber >= 0.83 and hhd send); "feature" = HIDIOCSFEATURE (a SET_REPORT
feature request, what the kernel driver hid-asus-ally sends).

An all-off report is sent on exit, Ctrl-C included. Stop the game first; while
InputPlumber runs it may send its own reports, which is fine for these tests.
"""
from __future__ import annotations

import argparse
import fcntl
import glob
import os
import random
import select
import signal
import sys
import time

VID, PID = 0x0B05, 0x1B4C
RUMBLE_ID = 0x0D
CFG_ID, CFG_PAGE = 0x5A, 0xD1
CMD_VIBE_INTENSITY, CMD_CHECK_READY = 0x06, 0x0A
CFG_REPORT_SIZE = 64
GAMEPAD_IF, CFG_IF = 5, 2  # interface numbers on the X20 (endpoints 0x87 and 0x83)


def _ioc(direction: int, nr: int, size: int) -> int:
    return (direction << 30) | (size << 16) | (ord("H") << 8) | nr


def hidiocsfeature(length: int) -> int:
    return _ioc(3, 0x06, length)  # _IOC(_IOC_WRITE|_IOC_READ, 'H', 0x06, len)


def hidiocgfeature(length: int) -> int:
    return _ioc(3, 0x07, length)


def hexs(data: bytes) -> str:
    return " ".join("%02x" % b for b in data)


# ---------------------------------------------------------------- discovery


def read(path: str) -> str:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def nkey_nodes() -> list[dict]:
    """hidraw nodes of 0b05:1b4c with interface number and USB bus/dev."""
    out = []
    for sysdir in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        dev = os.path.realpath(os.path.join(sysdir, "device"))
        uevent = read(os.path.join(dev, "uevent"))
        hid_id = ""
        name = ""
        for line in uevent.splitlines():
            if line.startswith("HID_ID="):
                hid_id = line.split("=", 1)[1]
            elif line.startswith("HID_NAME="):
                name = line.split("=", 1)[1]
        parts = hid_id.split(":")
        if len(parts) != 3 or int(parts[1], 16) != VID or int(parts[2], 16) != PID:
            continue
        intf_dir = os.path.dirname(dev)  # .../1-3:1.5
        usb_dir = os.path.dirname(intf_dir)  # .../1-3
        ifnum = read(os.path.join(intf_dir, "bInterfaceNumber"))
        driver = os.path.basename(os.path.realpath(os.path.join(dev, "driver"))) if os.path.exists(os.path.join(dev, "driver")) else "-"
        out.append({
            "node": "/dev/" + os.path.basename(sysdir),
            "ifnum": int(ifnum, 16) if ifnum else -1,
            "driver": driver,
            "name": name,
            "busnum": read(os.path.join(usb_dir, "busnum")),
            "devnum": read(os.path.join(usb_dir, "devnum")),
        })
    return out


def evdev_ff_nodes() -> list[str]:
    """Input devices of 0b05:1b4c that advertise force feedback."""
    res = []
    for d in sorted(glob.glob("/sys/class/input/input*")):
        if read(d + "/id/vendor").lower() != "0b05" or read(d + "/id/product").lower() != "1b4c":
            continue
        ff = read(d + "/capabilities/ff")
        if ff and ff.replace(" ", "").strip("0"):
            events = [os.path.basename(e) for e in glob.glob(d + "/event*")]
            res.append("%s (%s) ff=%s %s" % (read(d + "/name"), os.path.basename(d), ff, ",".join(events)))
    return res


def pick_node(node: str | None, ifnum: int) -> str:
    if node:
        return node
    for n in nkey_nodes():
        if n["ifnum"] == ifnum:
            return n["node"]
    sys.exit("no 0b05:1b4c hidraw node with interface %d; run 'list' and pass --node" % ifnum)


# ---------------------------------------------------------------- sending


class Sender:
    def __init__(self, node: str, transport: str, quiet_repeats: bool = True):
        self.node = node
        self.transport = transport
        self.fd = os.open(node, os.O_RDWR)
        self.sent = 0
        self.errors = 0
        self.last: bytes | None = None
        self.quiet_repeats = quiet_repeats

    def send(self, report: bytes, transport: str | None = None) -> None:
        t = transport or self.transport
        try:
            if t == "output":
                os.write(self.fd, report)
            else:
                fcntl.ioctl(self.fd, hidiocsfeature(len(report)), bytearray(report))
            self.sent += 1
        except OSError as e:
            self.errors += 1
            print("  %-7s %s -> error: %s" % (t, hexs(report), e))
            return
        if not (self.quiet_repeats and report == self.last):
            print("  %-7s %s -> %s" % (t, hexs(report), self.node))
        self.last = report

    def get_feature(self, report_id: int, size: int) -> bytes:
        buf = bytearray(size)
        buf[0] = report_id
        fcntl.ioctl(self.fd, hidiocgfeature(size), buf)
        return bytes(buf)

    def close(self) -> None:
        os.close(self.fd)


def rumble_report(strong: int, weak: int, lt: int = 0, rt: int = 0, enable: int = 0x0F,
                  duration: int = 0xFF, delay: int = 0, loops: int = 0xEB) -> bytes:
    vals = [RUMBLE_ID, enable, lt, rt, strong, weak, duration, delay, loops]
    for v in vals:
        if not 0 <= v <= 255:
            sys.exit("byte value out of range: %d" % v)
    return bytes(vals)


OFF = rumble_report(0, 0)


def parse_raw(text: str) -> bytes:
    try:
        return bytes(int(t, 16) for t in text.replace(",", " ").split())
    except ValueError:
        sys.exit("--raw takes hex bytes, e.g. \"0d 0f 00 00 64 64 ff 00 eb\"")


def all_off(snd: Sender) -> None:
    # Both transports: whichever the MCU honours, the motors stop.
    for t in ("output", "feature"):
        try:
            snd.send(OFF, t)
        except Exception:  # noqa: BLE001 - best effort on exit
            pass


def play(snd: Sender, report: bytes, seconds: float, rate: float, jitter: int) -> None:
    """Send once (rate 0) or repeatedly at `rate` Hz for `seconds`."""
    end = time.monotonic() + seconds
    if rate <= 0:
        snd.send(report)
        while time.monotonic() < end:
            time.sleep(0.05)
        return
    period = 1.0 / rate
    n0 = snd.sent
    nxt = time.monotonic()
    first = True
    while time.monotonic() < end:
        r = bytearray(report)
        if jitter and not first:
            for i in (2, 3, 4, 5):
                if report[i]:
                    r[i] = max(0, min(255, report[i] + random.randint(-jitter, jitter)))
        snd.send(bytes(r))
        first = False
        nxt += period
        delay = nxt - time.monotonic()
        if delay > 0:
            time.sleep(delay)
    n = snd.sent - n0
    print("  sent %d reports in %.1fs (%.0f/s)%s" % (n, seconds, n / seconds, ", jitter +-%d" % jitter if jitter else ""))


# ---------------------------------------------------------------- commands


def cmd_list(_args) -> int:
    nodes = nkey_nodes()
    if not nodes:
        print("no 0b05:1b4c hidraw nodes found")
    for n in nodes:
        print("%-14s interface %d  driver %-14s usb %s:%s  %s" % (
            n["node"], n["ifnum"], n["driver"], n["busnum"], n["devnum"], n["name"]))
    print("\nforce-feedback input devices of 0b05:1b4c:")
    for line in evdev_ff_nodes() or ["(none)"]:
        print("  " + line)
    intensity = glob.glob("/sys/bus/hid/devices/*0B05:1B4C*/gamepad_vibration_intensity")
    for p in intensity:
        print("\n%s = %s" % (p, read(p)))
    return 0


def with_sender(args, fn) -> int:
    snd = Sender(pick_node(args.node, args.interface), args.transport)

    def stop(_sig, _frm):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    errors = 0
    try:
        fn(snd)
    except KeyboardInterrupt:
        print("\ninterrupted")
    finally:
        errors = snd.errors
        print("off:")
        all_off(snd)
        snd.close()
    return 1 if errors else 0


def cmd_send(args) -> int:
    report = parse_raw(args.raw) if args.raw else rumble_report(
        args.strong, args.weak, args.lt, args.rt, args.enable, args.duration, args.delay, args.loops)
    print("sending for %.1fs via %s:" % (args.seconds, args.transport))
    return with_sender(args, lambda s: play(s, report, args.seconds, args.rate, args.jitter))


def cmd_sweep(args) -> int:
    def run(snd: Sender) -> None:
        for v in args.values:
            strong = v if args.motor in ("both", "strong") else 0
            weak = v if args.motor in ("both", "weak") else 0
            print("magnitude %d (0x%02x):" % (v, v))
            play(snd, rumble_report(strong, weak, enable=args.enable), args.seconds, args.rate, 0)
            snd.send(OFF)
            time.sleep(args.gap)
    print("sweep via %s, %.1fs each; note the felt strength of each step" % (args.transport, args.seconds))
    return with_sender(args, run)


MATRIX = [
    # label, transport, report, rate Hz, jitter
    ("A kernel today: feature, 127/127 (= 65535/512)", "feature", rumble_report(127, 127), 0, 0),
    ("B kernel after 0014: feature, 100/100", "feature", rumble_report(100, 100), 0, 0),
    ("C InputPlumber 0.83 / hhd: output, 100/100", "output", rumble_report(100, 100), 0, 0),
    ("D output, 100/100, enable 0x03 (main motors only)", "output", rumble_report(100, 100, enable=0x03), 0, 0),
    ("E output, triggers only 100/100", "output", rumble_report(0, 0, 100, 100), 0, 0),
    ("F feature, 100/100 re-sent at 60 Hz", "feature", rumble_report(100, 100), 60, 0),
    ("G feature, 70/70 re-sent at 250 Hz, jitter +-30", "feature", rumble_report(70, 70), 250, 30),
    ("H output, 70/70 re-sent at 250 Hz, jitter +-30", "output", rumble_report(70, 70), 250, 30),
    ("I feature, 110/110 (out of range)", "feature", rumble_report(110, 110), 0, 0),
]


def cmd_matrix(args) -> int:
    results = []

    def run(snd: Sender) -> None:
        for label, transport, report, rate, jitter in MATRIX:
            if args.only and label[0] not in args.only.upper():
                continue
            if not args.yes:
                input("\n[%s] press Enter to start (speakers muted, listen closely) " % label)
            else:
                print("\n[%s]" % label)
            snd.transport = transport
            play(snd, report, args.seconds, rate, jitter)
            snd.send(OFF)
            note = ""
            if not args.yes:
                note = input("  strength 0-5 and static y/n (e.g. '4 y'): ").strip()
            results.append((label, note))
            time.sleep(1.0)

    rc = with_sender(args, run)
    print("\nsummary:")
    for label, note in results:
        print("  %-52s %s" % (label, note or "-"))
    return rc


def cmd_off(args) -> int:
    snd = Sender(pick_node(args.node, args.interface), args.transport)
    all_off(snd)
    snd.close()
    return 0


def cmd_intensity(args) -> int:
    """MCU vibration intensity (0x5a 0xd1 0x06 0x02 L R) on the config interface."""
    node = pick_node(args.node, CFG_IF)
    snd = Sender(node, "feature")
    try:
        for _ in range(3):  # check-ready, as ally_gamepad_check_ready() does
            ready = bytearray(CFG_REPORT_SIZE)
            ready[0:4] = bytes([CFG_ID, CFG_PAGE, CMD_CHECK_READY, 0x01])
            snd.send(bytes(ready))
            try:
                resp = snd.get_feature(RUMBLE_ID, CFG_REPORT_SIZE)
                print("  ready reply: %s ..." % hexs(resp[:8]))
                if resp[2] == CMD_CHECK_READY:
                    break
            except OSError as e:
                print("  ready get_feature: %s" % e)
            time.sleep(0.002)
        buf = bytearray(CFG_REPORT_SIZE)
        buf[0:6] = bytes([CFG_ID, CFG_PAGE, CMD_VIBE_INTENSITY, 0x02, args.left, args.right])
        snd.send(bytes(buf))
    finally:
        snd.close()
    print("intensity set to %d %d (the kernel's sysfs value does not follow)" % (args.left, args.right))
    return 1 if snd.errors else 0


def cmd_usbmon(args) -> int:
    """Print every 0x0d report on the wire (control SET_REPORT or interrupt OUT)."""
    nodes = nkey_nodes()
    if not nodes:
        sys.exit("N-KEY device not found")
    bus, dev = nodes[0]["busnum"], nodes[0]["devnum"]
    path = "/sys/kernel/debug/usb/usbmon/%su" % bus
    if not os.path.exists(path):
        sys.exit("%s missing: run 'sudo modprobe usbmon' (and mount debugfs on /sys/kernel/debug)" % path)
    addr = ":%s:%03d:" % (bus, int(dev))
    print("watching %s for device %s (Ctrl-C to stop) ..." % (path, addr.strip(":")))
    count = 0
    first = last_t = None
    last_data = None
    end = time.monotonic() + args.seconds if args.seconds else None
    with open(path, "rb", buffering=0) as f:
        buf = b""
        try:
            while end is None or time.monotonic() < end:
                r, _, _ = select.select([f], [], [], 0.5)
                if not r:
                    continue
                buf += os.read(f.fileno(), 65536)
                *lines, buf = buf.split(b"\n")
                for raw in lines:
                    line = raw.decode(errors="replace")
                    if addr not in line or " S " not in line or "=" not in line:
                        continue
                    data = line.split("=", 1)[1].replace(" ", "")
                    if not data.startswith("0d"):
                        continue
                    kind = "feature" if " Co:" in line and " 030d " in line else (
                        "output" if " Io:" in line else "other")
                    ts = int(line.split()[1]) / 1e6
                    first = first if first is not None else ts
                    count += 1
                    if data != last_data or args.all:
                        dt = (ts - last_t) * 1000 if last_t is not None else 0.0
                        print("%9.3fs +%7.1fms %-7s %s" % (ts - first, dt, kind,
                              " ".join(data[i:i + 2] for i in range(0, len(data), 2))))
                    last_t, last_data = ts, data
        except KeyboardInterrupt:
            pass
    if count and last_t is not None and first is not None and last_t > first:
        print("%d rumble reports, %.1f/s average" % (count, count / (last_t - first)))
    else:
        print("%d rumble reports" % count)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, transport_default="output"):
        p.add_argument("--node", help="hidraw node (default: the 0b05:1b4c node of --interface)")
        p.add_argument("--interface", type=int, default=GAMEPAD_IF, help="USB interface number (default 5)")
        p.add_argument("--transport", choices=("output", "feature"), default=transport_default)

    sub.add_parser("list", help="show N-KEY hidraw nodes and FF-capable input devices").set_defaults(fn=cmd_list)

    p = sub.add_parser("send", help="send one rumble report (optionally re-sent at a rate)")
    common(p)
    p.add_argument("--strong", type=int, default=0)
    p.add_argument("--weak", type=int, default=0)
    p.add_argument("--lt", type=int, default=0, help="left trigger motor")
    p.add_argument("--rt", type=int, default=0, help="right trigger motor")
    p.add_argument("--enable", type=lambda s: int(s, 0), default=0x0F)
    p.add_argument("--duration", type=lambda s: int(s, 0), default=0xFF)
    p.add_argument("--delay", type=lambda s: int(s, 0), default=0)
    p.add_argument("--loops", type=lambda s: int(s, 0), default=0xEB)
    p.add_argument("--raw", help="hex bytes instead of the fields above")
    p.add_argument("--seconds", type=float, default=3.0)
    p.add_argument("--rate", type=float, default=0, help="re-send at this many Hz (0 = once)")
    p.add_argument("--jitter", type=int, default=0, help="random +- change of each nonzero magnitude per re-send")
    p.set_defaults(fn=cmd_send)

    p = sub.add_parser("sweep", help="step through magnitudes (incl. > 100)")
    common(p)
    p.add_argument("--values", type=int, nargs="+", default=[25, 50, 75, 90, 100, 101, 110, 127])
    p.add_argument("--motor", choices=("both", "strong", "weak"), default="both")
    p.add_argument("--enable", type=lambda s: int(s, 0), default=0x0F)
    p.add_argument("--seconds", type=float, default=2.0)
    p.add_argument("--gap", type=float, default=1.0)
    p.add_argument("--rate", type=float, default=0)
    p.set_defaults(fn=cmd_sweep)

    p = sub.add_parser("matrix", help="guided run of the candidate formats A..I")
    common(p)
    p.add_argument("--seconds", type=float, default=4.0)
    p.add_argument("--only", help="letters to run, e.g. ACFG")
    p.add_argument("--yes", action="store_true", help="no prompts")
    p.set_defaults(fn=cmd_matrix)

    p = sub.add_parser("intensity", help="set the MCU vibration intensity, 0..100 per motor")
    p.add_argument("left", type=int)
    p.add_argument("right", type=int)
    p.add_argument("--node", help="hidraw node of the config interface (default: interface 2)")
    p.set_defaults(fn=cmd_intensity)

    p = sub.add_parser("usbmon", help="print 0x0d reports seen on the USB bus (needs usbmon)")
    p.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = until Ctrl-C)")
    p.add_argument("--all", action="store_true", help="print repeats too")
    p.set_defaults(fn=cmd_usbmon)

    p = sub.add_parser("off", help="send the all-off report on both transports")
    common(p)
    p.set_defaults(fn=cmd_off)

    args = ap.parse_args()
    if getattr(args, "seconds", 0) and args.cmd in ("send", "sweep", "matrix") and args.seconds > 30:
        sys.exit("--seconds is capped at 30")
    if args.cmd == "intensity" and not (0 <= args.left <= 100 and 0 <= args.right <= 100):
        sys.exit("intensity is 0..100")
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
