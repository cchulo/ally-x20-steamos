#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# cmd/xbox-led.sh: node discovery from a fixture /sys/class/hidraw tree and
# the exact reports each sub-command sends (dry-run; docs/xbox-led-capture.md).
load '../test_helper'

setup() {
    make_root >/dev/null
    export AX20_HIDRAW_SYS="$BATS_TEST_TMPDIR/hidraw"
    export AX20_LEDS_SYS="$BATS_TEST_TMPDIR/leds"
    mkdir -p "$AX20_HIDRAW_SYS" "$AX20_LEDS_SYS"
}

# ring_led [with-attr] [sleep] : the ring LED device; with-attr adds the
# patch-0016 xbox_button_light attribute.
ring_led() {
    local d="$AX20_LEDS_SYS/go_s:rgb:joystick_rings"
    mkdir -p "$d"
    printf '%s\n' "${2:-0}" >"$d/sleep_animation"
    [ "${1:-}" != with-attr ] || printf '0\n' >"$d/xbox_button_light"
}

# hidraw <n> <HID_ID> <descriptor hex> : one fake node.
hidraw() {
    mkdir -p "$AX20_HIDRAW_SYS/hidraw$1/device"
    printf 'DRIVER=hid-asus-ally\nHID_ID=%s\n' "$2" >"$AX20_HIDRAW_SYS/hidraw$1/device/uevent"
    printf '%s' "$3" | xxd -r -p >"$AX20_HIDRAW_SYS/hidraw$1/device/report_descriptor"
}

# The X20 as measured: gamepad interface (0x0d rumble only), the N-KEY
# interface (0x5a, 0x5d, 0x5e) and an unrelated Steam virtual device.
x20_nodes() {
    hidraw 0 0003:00000B05:00001B4C '05010905a101850d0901a10075081000'
    hidraw 5 0003:00000B05:00001B4C '0600ff0901a101855a09a1150026ff007508955fb102855d7508953fb102855eb102c0'
    hidraw 7 0003:000028DE:000012F0 '05010906a10185010901c0'
}

@test "no sub-command prints usage and exits 2" {
    run "$CLI" xbox-led
    assert_failure 2
    assert_output_contains 'usage:'
}

@test "help lists the command with its summary" {
    run "$CLI" help
    assert_success
    assert_output_contains 'xbox-led'
}

@test "node: finds the N-KEY interface (0b05:1b4c with report ID 0x5a), not the gamepad one" {
    x20_nodes
    run "$CLI" xbox-led node
    assert_success
    assert_equal "$output" "/dev/hidraw5"
}

@test "node: fails cleanly when there is no X20 controller" {
    hidraw 7 0003:000028DE:000012F0 '05010906a10185010901c0'
    run "$CLI" xbox-led node
    assert_failure 1
    assert_output_contains 'no 0b05:1b4c hidraw node'
}

@test "--hidraw overrides discovery" {
    run "$CLI" xbox-led --hidraw /dev/hidraw9 node
    assert_success
    assert_equal "$output" "/dev/hidraw9"
}

@test "on/off with the driver attribute (patch 0016): writes it and a modprobe.d option, no raw mask" {
    x20_nodes
    ring_led with-attr
    run "$CLI" --dry-run xbox-led on
    assert_success
    assert_output_contains "xbox_button_light <- 1"
    assert_output_contains "/etc/modprobe.d/ally-x20-steamos-xbox-led.conf <- xbox_button_light=1"
    assert_output_contains "kept across reboots"
    [[ "$output" != *"5a d1 09"* ]]
    run "$CLI" --dry-run xbox-led off
    assert_success
    assert_output_contains "xbox_button_light <- 0"
    assert_output_contains "xbox_button_light=0"
}

@test "on with the attribute, for real: attribute written, modprobe.d option recorded in the manifest" {
    x20_nodes
    ring_led with-attr
    run "$CLI" xbox-led on
    assert_success
    [ "$(cat "$AX20_LEDS_SYS/go_s:rgb:joystick_rings/xbox_button_light")" = 1 ]
    grep -q '^options hid-asus-ally xbox_button_light=1$' "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos-xbox-led.conf"
    source_libs
    manifest_has /etc/modprobe.d/ally-x20-steamos-xbox-led.conf
}

@test "on without the attribute: one mask write with the driver's default bits (0x0b) plus the Xbox bit" {
    x20_nodes
    ring_led
    run "$CLI" --dry-run xbox-led on
    assert_success
    assert_output_contains '[dry-run] /dev/hidraw5 feature <- 5a d1 09 01 1b'
    assert_output_contains 'until the next reboot'
}

@test "on/off without the attribute keeps the driver's sleep_animation bit" {
    x20_nodes
    ring_led '' 1
    run "$CLI" --dry-run xbox-led on
    assert_success
    assert_output_contains '[dry-run] /dev/hidraw5 feature <- 5a d1 09 01 1f'
    run "$CLI" --dry-run xbox-led off
    assert_success
    assert_output_contains '[dry-run] /dev/hidraw5 feature <- 5a d1 09 01 0f'
}

@test "off without the attribute and without a ring LED device: 0x0b" {
    x20_nodes
    run "$CLI" --dry-run xbox-led off
    assert_success
    assert_output_contains '[dry-run] /dev/hidraw5 feature <- 5a d1 09 01 0b'
}

@test "brightness 0-3 is an output report 5d d1 20 01 <level>" {
    x20_nodes
    for l in 0 1 2 3; do
        run "$CLI" --dry-run xbox-led brightness "$l"
        assert_success
        assert_output_contains "[dry-run] /dev/hidraw5 output <- 5d d1 20 01 0$l"
    done
}

@test "brightness rejects values outside 0-3" {
    x20_nodes
    run "$CLI" --dry-run xbox-led brightness 4
    assert_failure 2
    run "$CLI" --dry-run xbox-led brightness 100
    assert_failure 2
    run "$CLI" --dry-run xbox-led brightness
    assert_failure 2
}

@test "breathe on/off is 5a d1 21 02 <mode> 08" {
    x20_nodes
    run "$CLI" --dry-run xbox-led breathe on
    assert_success
    assert_output_contains '[dry-run] /dev/hidraw5 feature <- 5a d1 21 02 01 08'
    run "$CLI" --dry-run xbox-led breathe off
    assert_success
    assert_output_contains '[dry-run] /dev/hidraw5 feature <- 5a d1 21 02 00 08'
    run "$CLI" --dry-run xbox-led breathe
    assert_failure 2
}

@test "unknown sub-command exits 2" {
    x20_nodes
    run "$CLI" --dry-run xbox-led color 0 255 0
    assert_failure 2
    assert_output_contains 'unknown xbox-led command'
}

@test "without root and without a fixture root, a real send is refused" {
    [ "$(id -u)" -ne 0 ] || skip "running as root"
    x20_nodes
    unset AX20_ROOT
    run "$CLI" xbox-led --hidraw /dev/null on
    assert_failure 1
    assert_output_contains 'must run as root'
}
