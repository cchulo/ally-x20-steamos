#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/xboxled.sh and overlay/bin/xbox-led-restore against fixture
# roots: the helper and udev rule are installed under /etc, the helper reads
# /etc/ally-x20-steamos/xbox-led.conf and sends the breathe and brightness
# reports to the hidraw node of the interface that owns the ring LED.
load '../test_helper'

HELPER=/etc/ally-x20-steamos/xbox-led-restore
RULE=/etc/udev/rules.d/70-ally-x20-steamos-xbox-led.rules
CONF=/etc/ally-x20-steamos/xbox-led.conf
OVL="$REPO_ROOT/overlay"

setup() {
    make_root >/dev/null
    source_libs
    unset AX20_XBOX_LED_SYSTEM_STEPS
    component_load xboxled
}

# ring_led_with_hidraw : the ring LED whose HID device has hidraw5.
ring_led_with_hidraw() {
    local hid="$AX20_ROOT/sys/devices/pci0000:00/usb1/1-4/1-4:1.2/0003:0B05:1B4C.0003"
    mkdir -p "$hid/hidraw/hidraw5" "$AX20_ROOT/sys/class/leds" "$AX20_ROOT/dev"
    mkdir -p "$hid/leds/go_s:rgb:joystick_rings"
    ln -s "$hid/leds/go_s:rgb:joystick_rings" "$AX20_ROOT/sys/class/leds/go_s:rgb:joystick_rings"
    ln -s "$hid" "$hid/leds/go_s:rgb:joystick_rings/device"
    : >"$AX20_ROOT/dev/hidraw5"
}

@test "files: helper under /etc/ally-x20-steamos, rule under /etc/udev/rules.d" {
    run component_files xboxled
    assert_success
    [ "$output" = "$(printf 'bin/xbox-led-restore\t%s\t0755\nudev/rules.d/70-ally-x20-steamos-xbox-led.rules\t%s\t0644' "$HELPER" "$RULE")" ]
}

@test "probe: always needed (stock has no control for the light)" {
    run component_probe xboxled
    [ "$status" -eq 1 ]
}

@test "apply installs both files, records them, and skips udevadm on a fixture root" {
    run component_apply xboxled
    assert_success
    [ -x "$AX20_ROOT$HELPER" ]
    [ -f "$AX20_ROOT$RULE" ]
    manifest_has "$HELPER"
    manifest_has "$RULE"
    [ "$(component_status xboxled)" = active ]
}

@test "rule: on add of the ring LED, only when settings exist, detached through systemd-run" {
    r="$OVL/udev/rules.d/70-ally-x20-steamos-xbox-led.rules"
    grep -q 'ACTION=="add", SUBSYSTEM=="leds", KERNEL=="go_s:rgb:joystick_rings|ally:rgb:joystick_rings"' "$r"
    grep -q 'TEST=="/etc/ally-x20-steamos/xbox-led.conf"' "$r"
    grep -q 'RUN+="/usr/bin/systemd-run --no-block --collect --unit=ally-x20-steamos-xbox-led-restore /etc/ally-x20-steamos/xbox-led-restore"' "$r"
}

@test "helper: no settings file, nothing sent, exit 0" {
    ring_led_with_hidraw
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore"
    assert_success
    [ -z "$output" ]
}

@test "helper: sends breathe then brightness to the hidraw node of the LED's interface" {
    ring_led_with_hidraw
    fixture_file "$CONF" 'brightness=1
breathe=on
'
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore"
    assert_success
    [ "${lines[0]}" = "$AX20_ROOT/dev/hidraw5 feature <- 5a d1 21 02 01 08" ]
    [ "${lines[1]}" = "$AX20_ROOT/dev/hidraw5 output <- 5d d1 20 01 01" ]
}

@test "helper: only the keys present are sent; junk values are ignored" {
    ring_led_with_hidraw
    fixture_file "$CONF" 'brightness=9
breathe=off
'
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore"
    assert_success
    [ "$output" = "$AX20_ROOT/dev/hidraw5 feature <- 5a d1 21 02 00 08" ]
}

@test "helper: no ring LED device, logs and exits 0" {
    fixture_file "$CONF" 'brightness=2
'
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore"
    assert_success
    assert_output_contains 'no ring LED device'
}
