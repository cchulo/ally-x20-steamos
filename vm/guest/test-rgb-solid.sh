#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/guest/test-rgb-solid.sh — on a real ROG Xbox Ally X20 running the patched
# hid-asus-ally, replay the writes Steam's Customization page makes for
# Effect = Solid, once per rgb_static_mode, so the owner can report which
# mode keeps BOTH joystick rings lit. See patches/kernel/README-hid.md,
# "Solid dropout".
#
# Usage: sudo test-rgb-solid.sh [--modes "0 1 2 3"] [--wait SECONDS]
#                               [--led NAME] [--reload]
#   --modes   rgb_static_mode values to try, in order (default: "0 1 2 3")
#             0 Aura static zone 0 (default)   1 Aura static per zone 1-4
#             2 0xd1 0x08 per-zone only         3 old behaviour (the bug)
#   --wait    seconds to wait after each step (default: 3)
#   --led     LED class name (default: go_s:rgb:joystick_rings, falls back
#             to ally:rgb:joystick_rings)
#   --reload  if the parameter is not writable, reload the module with
#             rgb_static_mode=N instead of stopping (the gamepad drops out
#             for a moment)
#
# The LED state and the parameter are restored on exit. Interactive runs ask
# after each step whether both rings are lit and print a summary at the end.
set -eu

die() {
    printf 'test-rgb-solid: error: %s\n' "$*" >&2
    exit 2
}

MODES="0 1 2 3"
WAIT=3
LED_NAME=""
RELOAD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --modes)
            [ $# -ge 2 ] || die "--modes needs a list"
            MODES=$2
            shift
            ;;
        --wait)
            [ $# -ge 2 ] || die "--wait needs seconds"
            WAIT=$2
            shift
            ;;
        --led)
            [ $# -ge 2 ] || die "--led needs a name"
            LED_NAME=$2
            shift
            ;;
        --reload) RELOAD=1 ;;
        -h | --help)
            sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"
case "$WAIT" in '' | *[!0-9]*) die "--wait must be a whole number" ;; esac
for m in $MODES; do
    case "$m" in 0 | 1 | 2 | 3) ;; *) die "unknown mode: $m (0-3)" ;; esac
done

if [ -z "$LED_NAME" ]; then
    for n in go_s:rgb:joystick_rings ally:rgb:joystick_rings; do
        if [ -d "/sys/class/leds/$n" ]; then
            LED_NAME=$n
            break
        fi
    done
fi
[ -n "$LED_NAME" ] || die "no joystick ring LED in /sys/class/leds"
L=/sys/class/leds/$LED_NAME
[ -e "$L/effect" ] || die "$L/effect is missing: the patched hid-asus-ally (0011) is not loaded"

PARAM=/sys/module/hid_asus_ally/parameters/rgb_static_mode
[ -e "$PARAM" ] || die "$PARAM is missing: this hid-asus-ally build predates rgb_static_mode"

orig_mode=$(cat "$PARAM")
orig_effect=$(cat "$L/effect")
orig_color=$(cat "$L/multi_intensity")
orig_brightness=$(cat "$L/brightness")

put() {
    printf '  %-40s <- %s\n' "${1#"$L"/}" "$2"
    printf '%s\n' "$2" >"$1"
}

set_mode() {
    if printf '%s\n' "$1" >"$PARAM" 2>/dev/null; then
        printf 'rgb_static_mode = %s\n' "$(cat "$PARAM")"
        return 0
    fi
    if [ "$RELOAD" -eq 0 ]; then
        printf 'cannot write %s. Reload the module by hand:\n' "$PARAM" >&2
        printf '  modprobe -r hid_asus_ally && modprobe hid_asus_ally rgb_static_mode=%s\n' "$1" >&2
        printf 'then run this script again with --modes %s, or pass --reload.\n' "$1" >&2
        exit 1
    fi
    modprobe -r hid_asus_ally
    modprobe hid_asus_ally "rgb_static_mode=$1"
    # the LED is re-registered after the MCU init (about 1.5 s)
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -e "$L/effect" ] && break
        sleep 1
    done
    [ -e "$L/effect" ] || die "$L did not come back after reloading"
    printf 'rgb_static_mode = %s (module reloaded)\n' "$(cat "$PARAM")"
}

restore() {
    printf '\nrestoring: rgb_static_mode=%s effect=%s colour="%s" brightness=%s\n' \
        "$orig_mode" "$orig_effect" "$orig_color" "$orig_brightness"
    printf '%s\n' "$orig_mode" >"$PARAM" 2>/dev/null || true
    printf '%s\n' "$orig_color" >"$L/multi_intensity" 2>/dev/null || true
    printf '%s\n' "$orig_brightness" >"$L/brightness" 2>/dev/null || true
    printf '%s\n' "$orig_effect" >"$L/effect" 2>/dev/null || true
}
trap restore EXIT

RESULTS=""
# observe <mode> <step> : wait, say what to look at, ask when interactive
observe() {
    sleep "$WAIT"
    printf '  LOOK: are BOTH rings lit in the colour above, and still lit now (%ss later)?\n' "$WAIT"
    if [ -t 0 ]; then
        printf '  both rings lit? [y/n/l=left only/r=right only] '
        read -r ans || ans="?"
    else
        ans="-"
    fi
    RESULTS="$RESULTS$1	$2	$ans
"
}

printf 'LED: %s\n' "$L"
printf 'modes: %s, %ss per step\n' "$MODES" "$WAIT"
for m in $MODES; do
    printf '\n=== rgb_static_mode %s ===\n' "$m"
    set_mode "$m"

    printf 'step 1: start from an animated effect (breathe, blue)\n'
    put "$L/multi_intensity" "0 0 255"
    put "$L/brightness" 255
    put "$L/effect" breathe
    sleep "$WAIT"

    printf 'step 2: Steam switches to Solid red (effect, colour, brightness)\n'
    put "$L/effect" monocolor
    put "$L/multi_intensity" "255 0 0"
    put "$L/brightness" 255
    observe "$m" "2 solid red from breathe"

    printf 'step 3: Steam changes the Solid colour to green, half brightness\n'
    put "$L/multi_intensity" "0 255 0"
    put "$L/brightness" 128
    observe "$m" "3 colour+brightness only"

    printf 'step 4: other write order (brightness, colour, effect), white\n'
    put "$L/effect" breathe
    sleep 1
    put "$L/brightness" 255
    put "$L/multi_intensity" "255 255 255"
    put "$L/effect" monocolor
    observe "$m" "4 reversed order, white"
done

printf '\n=== summary (mode, step, answer) ===\n'
printf '%s' "$RESULTS"
printf '\nReport the mode(s) where every step answered "y". Mode 3 is the old\n'
printf 'behaviour and is expected to show "l" (right ring dark).\n'
