#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/fake-leds.sh — fake joystick-ring LEDs for tests (plan §6 check 6).
#
# Usage:
#   vm/fake-leds.sh tree <root> [--name <led>] [--layout patched|stock]
#       Create a sysfs-shaped fixture <root>/sys/class/leds/<led>/ with
#       brightness, max_brightness, multi_index, multi_intensity, trigger.
#       Default name ally:rgb:joystick_rings (stock hid-asus-ally). For unit
#       tests of the rgb component's probe/status against fixture roots.
#   vm/fake-leds.sh build [--kdir <dir>]
#       Build vm/test-led-module against <dir> (default running kernel).
#   vm/fake-leds.sh load [--ko <file>]     (inside the VM, root)
#       insmod the test module and check go_s:rgb:joystick_rings appeared.
#   vm/fake-leds.sh unload                 (inside the VM, root)
#   vm/fake-leds.sh status
set -eu

FL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FL_STEAM_NAME="go_s:rgb:joystick_rings"
FL_SYS_LEDS=${AX20_FAKE_LEDS_SYSFS:-/sys/class/leds}

die() {
    printf 'fake-leds: error: %s\n' "$*" >&2
    exit 2
}

# fl_tree <root> <name> <layout>
fl_tree() {
    local root=$1 name=$2 layout=$3 d idx inten
    d="$root/sys/class/leds/$name"
    mkdir -p "$d"
    case "$layout" in
        patched)
            idx="red green blue"
            inten="255 255 255"
            ;;
        stock)
            # TODO(hw): stock hid-asus-ally layout on the X20 (plan §1.3 says
            # 12 x RGB subleds before our patch); confirm with cat multi_index.
            idx="" inten=""
            for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
                idx="${idx:+$idx }rgb"
                inten="${inten:+$inten }16777215"
            done
            ;;
        *) die "--layout must be patched or stock" ;;
    esac
    printf '0\n' >"$d/brightness"
    printf '255\n' >"$d/max_brightness"
    printf '%s\n' "$idx" >"$d/multi_index"
    printf '%s\n' "$inten" >"$d/multi_intensity"
    printf '[none] kbd-scrolllock\n' >"$d/trigger"
    printf '%s\n' "$d"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
    tree)
        [ $# -ge 1 ] || die "tree needs a root directory"
        root=$1
        shift
        name="ally:rgb:joystick_rings" layout=stock
        while [ $# -gt 0 ]; do
            case "$1" in
                --name)
                    name=$2
                    shift
                    ;;
                --layout)
                    layout=$2
                    shift
                    ;;
                *) die "unknown option: $1" ;;
            esac
            shift
        done
        fl_tree "$root" "$name" "$layout"
        ;;
    build)
        kdir=
        if [ "${1:-}" = --kdir ]; then kdir=${2:-}; fi
        if [ -n "$kdir" ]; then
            make -C "$FL_DIR/test-led-module" KDIR="$kdir"
        else
            make -C "$FL_DIR/test-led-module"
        fi
        ;;
    load)
        ko="$FL_DIR/test-led-module/ax20_test_led.ko"
        if [ "${1:-}" = --ko ]; then ko=${2:-}; fi
        [ -f "$ko" ] || die "module not found: $ko (vm/fake-leds.sh build)"
        if [ ! -e "$FL_SYS_LEDS/$FL_STEAM_NAME" ]; then
            modprobe led-class-multicolor 2>/dev/null || true
            insmod "$ko"
        fi
        [ -e "$FL_SYS_LEDS/$FL_STEAM_NAME" ] || die "$FL_STEAM_NAME did not appear under $FL_SYS_LEDS"
        printf 'loaded: %s\n' "$FL_SYS_LEDS/$FL_STEAM_NAME"
        ;;
    unload)
        rmmod ax20_test_led 2>/dev/null || true
        [ ! -e "$FL_SYS_LEDS/$FL_STEAM_NAME" ] || die "$FL_STEAM_NAME still present"
        printf 'unloaded\n'
        ;;
    status)
        if [ -e "$FL_SYS_LEDS/$FL_STEAM_NAME" ]; then
            printf '%s present\n' "$FL_STEAM_NAME"
            for f in multi_index multi_intensity brightness; do
                printf '  %s: %s\n' "$f" "$(cat "$FL_SYS_LEDS/$FL_STEAM_NAME/$f" 2>/dev/null || echo '?')"
            done
        else
            printf '%s absent\n' "$FL_STEAM_NAME"
        fi
        ;;
    -h | --help | '') sed -n '3,/^set -eu/p' "$0" | sed -e '/^set -eu/d' -e 's/^# \{0,1\}//' ;;
    *) die "unknown command: $cmd" ;;
esac
