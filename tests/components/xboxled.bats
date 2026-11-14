#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/xboxled.sh and overlay/bin/xbox-led-restore against fixture
# roots: the helper, the udev rule and the resume unit are installed under
# /etc, the helper reads /etc/ally-x20-steamos/xbox-led.conf and sends the
# breathe and brightness reports to the hidraw node of the interface that
# owns the ring LED, at boot through the udev rule and after a suspend/resume
# cycle through the unit (issue #63).
load '../test_helper'

HELPER=/etc/ally-x20-steamos/xbox-led-restore
RULE=/etc/udev/rules.d/70-ally-x20-steamos-xbox-led.rules
UNIT=/etc/systemd/system/ally-x20-steamos-xbox-led-resume.service
CONF=/etc/ally-x20-steamos/xbox-led.conf
OVL="$REPO_ROOT/overlay"
SLEEP_TARGETS="suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"

setup() {
    make_root >/dev/null
    source_libs
    unset AX20_XBOX_LED_SYSTEM_STEPS
    component_load xboxled
}

# ring_led_with_hidraw [xbox_button_light] : the ring LED whose HID device
# has hidraw5; the optional argument is what the driver's attribute reads.
ring_led_with_hidraw() {
    local hid="$AX20_ROOT/sys/devices/pci0000:00/usb1/1-4/1-4:1.2/0003:0B05:1B4C.0003"
    mkdir -p "$hid/hidraw/hidraw5" "$AX20_ROOT/sys/class/leds" "$AX20_ROOT/dev"
    mkdir -p "$hid/leds/go_s:rgb:joystick_rings"
    ln -s "$hid/leds/go_s:rgb:joystick_rings" "$AX20_ROOT/sys/class/leds/go_s:rgb:joystick_rings"
    ln -s "$hid" "$hid/leds/go_s:rgb:joystick_rings/device"
    : >"$AX20_ROOT/dev/hidraw5"
    [ -z "${1:-}" ] || printf '%s\n' "$1" >"$hid/leds/go_s:rgb:joystick_rings/xbox_button_light"
}

# stubs <dir> : systemctl that records its calls.
stubs() {
    mkdir -p "$1"
    printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\nexit 0\n' "$1" >"$1/systemctl"
    chmod +x "$1/systemctl"
    : >"$1/calls"
}

tree_listing() { (cd "$AX20_ROOT" && find . -path ./var/lib/ally-x20-steamos -prune -o -print | sort); }

@test "files: helper under /etc/ally-x20-steamos, rule under /etc/udev/rules.d, unit under /etc/systemd/system" {
    run component_files xboxled
    assert_success
    [ "$output" = "$(printf 'bin/xbox-led-restore\t%s\t0755\nudev/rules.d/70-ally-x20-steamos-xbox-led.rules\t%s\t0644\nsystemd/ally-x20-steamos-xbox-led-resume.service\t%s\t0644' "$HELPER" "$RULE" "$UNIT")" ]
}

@test "probe: always needed (stock has no control for the light)" {
    run component_probe xboxled
    [ "$status" -eq 1 ]
}

@test "apply installs the files and the sleep-target links, records them, and skips udevadm/systemctl on a fixture root" {
    stubs "$BATS_TEST_TMPDIR/stub"
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" run component_apply xboxled
    assert_success
    [ -x "$AX20_ROOT$HELPER" ]
    [ -f "$AX20_ROOT$RULE" ]
    [ -f "$AX20_ROOT$UNIT" ]
    manifest_has "$HELPER"
    manifest_has "$RULE"
    manifest_has "$UNIT"
    for t in $SLEEP_TARGETS; do
        link="/etc/systemd/system/$t.wants/ally-x20-steamos-xbox-led-resume.service"
        [ -L "$AX20_ROOT$link" ]
        [ "$(readlink "$AX20_ROOT$link")" = "../ally-x20-steamos-xbox-led-resume.service" ]
        manifest_has "$link"
    done
    [ ! -s "$BATS_TEST_TMPDIR/stub/calls" ]
    [ "$(component_status xboxled)" = active ]
}

@test "apply is idempotent" {
    component_apply xboxled
    run component_apply xboxled
    assert_success
    [ -z "$(manifest_paths xboxled | sort | uniq -d)" ]
}

@test "system steps: daemon-reload so the unit is known before the next sleep" {
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    PATH="$stub:$PATH" AX20_XBOX_LED_SYSTEM_STEPS=always run component_apply xboxled
    assert_success
    grep -qx 'systemctl daemon-reload' "$stub/calls"
}

@test "uninstall --component xboxled removes everything it added and restores the tree" {
    before=$(tree_listing)
    "$CLI" --root "$AX20_ROOT" apply --only xboxled 2>/dev/null
    [ -e "$AX20_ROOT$UNIT" ]
    run "$CLI" --root "$AX20_ROOT" uninstall --component xboxled --keep-state
    assert_success
    # only the protected /etc/systemd{,/system} and /etc/udev dirs
    # (fixture-only: a real system always has them) stay recorded
    [ -z "$(manifest_paths xboxled | grep -vx -e /etc/systemd -e /etc/systemd/system -e /etc/udev)" ]
    rmdir "$AX20_ROOT/etc/systemd/system" "$AX20_ROOT/etc/systemd" "$AX20_ROOT/etc/udev"
    [ "$(tree_listing)" = "$before" ]
}

@test "rule: on add of the ring LED, only when settings exist, detached through systemd-run" {
    r="$OVL/udev/rules.d/70-ally-x20-steamos-xbox-led.rules"
    grep -q 'ACTION=="add", SUBSYSTEM=="leds", KERNEL=="go_s:rgb:joystick_rings|ally:rgb:joystick_rings"' "$r"
    grep -q 'TEST=="/etc/ally-x20-steamos/xbox-led.conf"' "$r"
    grep -q 'RUN+="/usr/bin/systemd-run --no-block --collect --unit=ally-x20-steamos-xbox-led-restore /etc/ally-x20-steamos/xbox-led-restore"' "$r"
}

@test "unit: a oneshot after every sleep target that runs the helper in resume mode" {
    u="$OVL/systemd/ally-x20-steamos-xbox-led-resume.service"
    grep -qx 'Type=oneshot' "$u"
    grep -qx "ExecStart=$HELPER resume" "$u"
    grep -qx "ConditionPathExists=$HELPER" "$u"
    grep -qx "After=$SLEEP_TARGETS" "$u"
    grep -qx "After=ally-x20-steamos-inputplumber-resume.service" "$u"
    grep -qx "WantedBy=$SLEEP_TARGETS" "$u"
    # nothing is ordered after it, so it must never block the sleep
    run grep -E '^(Before|RemainAfterExit)=' "$u"
    assert_failure
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

@test "helper resume: sends the recorded settings like the boot path" {
    ring_led_with_hidraw 1
    fixture_file "$CONF" 'brightness=2
breathe=on
'
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore" resume
    assert_success
    [ "${lines[0]}" = "$AX20_ROOT/dev/hidraw5 feature <- 5a d1 21 02 01 08" ]
    [ "${lines[1]}" = "$AX20_ROOT/dev/hidraw5 output <- 5d d1 20 01 02" ]
}

@test "helper resume: light on but no brightness recorded sends the power-on default (3)" {
    ring_led_with_hidraw 1
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore" resume
    assert_success
    [ "$output" = "$AX20_ROOT/dev/hidraw5 output <- 5d d1 20 01 03" ]
    # a recorded breathe setting alone still gets the default level
    fixture_file "$CONF" 'breathe=off
'
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore" resume
    assert_success
    [ "${lines[0]}" = "$AX20_ROOT/dev/hidraw5 feature <- 5a d1 21 02 00 08" ]
    [ "${lines[1]}" = "$AX20_ROOT/dev/hidraw5 output <- 5d d1 20 01 03" ]
}

@test "helper resume: light off (or no attribute) and nothing recorded sends nothing" {
    ring_led_with_hidraw 0
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore" resume
    assert_success
    [ -z "$output" ]
    rm "$AX20_ROOT/sys/class/leds/go_s:rgb:joystick_rings/xbox_button_light"
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore" resume
    assert_success
    [ -z "$output" ]
}

@test "helper resume: no ring LED device, logs and exits 0 (the dry run does not wait)" {
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore" resume
    assert_success
    assert_output_contains 'no ring LED device'
}

@test "helper: an unknown argument prints usage and exits 0" {
    ring_led_with_hidraw 1
    AX20_ROOT="$AX20_ROOT" XBOX_LED_DRY_RUN=1 run "$OVL/bin/xbox-led-restore" bogus
    assert_success
    assert_output_contains 'usage:'
}
