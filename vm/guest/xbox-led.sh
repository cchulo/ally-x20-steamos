#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/guest/xbox-led.sh — drive the ROG Xbox Ally X20's Xbox-button light.
#
# Usage: sudo xbox-led.sh [--zone N] [--hidraw /dev/hidrawN] [--dry-run]
#                         on | off | brightness <0-100> | color <r> <g> <b>
#
# 1. If a driver exposes an LED class device for the button
#    (/sys/class/leds/*xbox_button*), the script writes to it.
# 2. Otherwise it sends raw reports to the N-KEY configuration interface
#    (0b05:1b4c, the hidraw node whose descriptor has report ID 0x5a).
#
# EXPERIMENTAL, TODO(hw): no public source (hhd, kndclark/ally_module,
# g-helper, asusctl, InputPlumber) documents a command for the Xbox-button
# light. The fallback assumes the button is one more Aura zone of the same
# MCU and sends the Aura static effect to that zone, then latches it with
# "set" only (no "apply", so nothing is written to MCU flash):
#     5a b3 <zone> 00 <r> <g> <b> 00 00     (64-byte feature report)
#     5a b5                                 (64-byte feature report)
# The default zone is 5, the Aura "logo" zone in asusctl's AuraZone and
# ally_module's asus_aura_zone. Zones 1-4 are the ring halves and 0 is
# "all", so --zone 0-4 recolours the rings: try 5, 6, 7 and 8. If no zone
# lights the button, the light is driven by something else (see
# patches/kernel/README-hid.md, "Xbox button light").
#
# "brightness" scales the last colour sent (default green, 0 255 0, as on
# Windows); the colour is remembered in /run/xbox-led.rgb.
set -eu

die() {
    printf 'xbox-led: error: %s\n' "$*" >&2
    exit 2
}

usage() {
    sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

ZONE=5
HIDRAW=""
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --zone)
            [ $# -ge 2 ] || die "--zone needs a number"
            ZONE=$2
            shift
            ;;
        --hidraw)
            [ $# -ge 2 ] || die "--hidraw needs a device"
            HIDRAW=$2
            shift
            ;;
        --dry-run) DRY=1 ;;
        -h | --help) usage 0 ;;
        --*) die "unknown option: $1" ;;
        *) break ;;
    esac
    shift
done
[ $# -ge 1 ] || usage 2

byte() {
    case "$1" in '' | *[!0-9]*) die "not a number: $1" ;; esac
    [ "$1" -le "$2" ] || die "$1 is out of range (0-$2)"
}
byte "$ZONE" 255

STATE=/run/xbox-led.rgb
last_rgb() {
    if [ -r "$STATE" ]; then cat "$STATE"; else echo "0 255 0"; fi
}

cmd=$1
shift
case "$cmd" in
    on)
        [ $# -eq 0 ] || usage 2
        read -r R G B <<<"$(last_rgb)"
        [ "$R$G$B" != "000" ] || { R=0 G=255 B=0; }
        PCT=100
        ;;
    off)
        [ $# -eq 0 ] || usage 2
        read -r R G B <<<"$(last_rgb)"
        PCT=0
        ;;
    brightness)
        [ $# -eq 1 ] || usage 2
        byte "$1" 100
        read -r R G B <<<"$(last_rgb)"
        PCT=$1
        ;;
    color | colour)
        [ $# -eq 3 ] || usage 2
        byte "$1" 255
        byte "$2" 255
        byte "$3" 255
        R=$1 G=$2 B=$3
        PCT=100
        ;;
    *) usage 2 ;;
esac

[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 ...)"

# remember the full colour so brightness/on can scale it later
if [ "$cmd" = color ] || [ "$cmd" = colour ]; then
    [ "$DRY" -eq 1 ] || printf '%s %s %s\n' "$R" "$G" "$B" >"$STATE"
fi

# 1. a driver-provided LED class device
led=""
for d in /sys/class/leds/*xbox_button*; do
    [ -d "$d" ] && led=$d && break
done
if [ -n "$led" ]; then
    max=$(cat "$led/max_brightness")
    level=$((max * PCT / 100))
    printf 'sysfs: %s\n' "$led"
    if [ -e "$led/multi_intensity" ]; then
        printf '  multi_intensity <- %s %s %s\n' "$R" "$G" "$B"
        [ "$DRY" -eq 1 ] || printf '%s %s %s\n' "$R" "$G" "$B" >"$led/multi_intensity"
    elif [ "$cmd" = color ] || [ "$cmd" = colour ]; then
        printf '  (single-colour LED, colour ignored)\n'
    fi
    printf '  brightness      <- %s\n' "$level"
    [ "$DRY" -eq 1 ] || printf '%s\n' "$level" >"$led/brightness"
    exit 0
fi

# 2. raw reports to the N-KEY configuration interface
R=$((R * PCT / 100))
G=$((G * PCT / 100))
B=$((B * PCT / 100))
command -v python3 >/dev/null 2>&1 || die "no LED class device and no python3 for the raw fallback"
printf 'no xbox_button LED in /sys/class/leds, sending raw reports (EXPERIMENTAL, zone %s)\n' "$ZONE"

python3 -I - "$HIDRAW" "$DRY" "$ZONE" "$R" "$G" "$B" <<'PY'
import fcntl, glob, os, sys

hidraw, dry, zone, r, g, b = sys.argv[1], sys.argv[2] == "1", *map(int, sys.argv[3:])
REPORT_LEN = 64

def find_node():
    # 0b05:1b4c, and a report descriptor that declares report ID 0x5a (85 5a)
    for sysdir in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(os.path.join(sysdir, "device/uevent")) as f:
                if "HID_ID=0003:00000B05:00001B4C" not in f.read().upper():
                    continue
            with open(os.path.join(sysdir, "device/report_descriptor"), "rb") as f:
                if b"\x85\x5a" not in f.read():
                    continue
        except OSError:
            continue
        return "/dev/" + os.path.basename(sysdir)
    return None

def report(*data):
    buf = bytearray(REPORT_LEN)
    buf[: len(data)] = bytes(data)
    return bytes(buf)

reports = [
    ("effect", report(0x5A, 0xB3, zone, 0x00, r, g, b, 0x00, 0x00)),
    ("set", report(0x5A, 0xB5)),
]

node = hidraw or find_node()
if node is None and not dry:
    sys.exit("xbox-led: error: no 0b05:1b4c hidraw node with report ID 0x5a; pass --hidraw")
print(f"hidraw: {node or '(none, dry run)'}")

# HIDIOCSFEATURE(len) = _IOC(_IOC_WRITE | _IOC_READ, 'H', 0x06, len)
HIDIOCSFEATURE = (3 << 30) | (REPORT_LEN << 16) | (ord("H") << 8) | 0x06

fd = None if dry else os.open(node, os.O_RDWR)
try:
    for name, buf in reports:
        print(f"  {name:6} {buf[:16].hex(' ')} ... ({len(buf)} bytes)")
        if fd is not None:
            fcntl.ioctl(fd, HIDIOCSFEATURE, buf)
finally:
    if fd is not None:
        os.close(fd)
print("sent" if not dry else "dry run, nothing sent")
PY
