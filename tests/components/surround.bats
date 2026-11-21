#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/surround.sh and the `surround` command against fixture roots:
# the helper, the eight impulse response sets with their notice and licence,
# and the user unit are installed under /etc; the command passes status,
# list and set to the helper, which keeps the choice in the user's
# ~/.config. The helper's own logic is in tests/surround/.
load '../test_helper'

DIR=/etc/ally-x20-steamos/surround
HELPER=$DIR/x20-surround
UNIT=/etc/systemd/user/ally-x20-steamos-surround.service
LINK=/etc/systemd/user/default.target.wants/ally-x20-steamos-surround.service
OVL="$REPO_ROOT/overlay"
SETS="sadie-d2-dry hutubs-pp1-dry mit-kemar-dry mit-kemar-large-dry sadie-d2-full hutubs-pp1-full mit-kemar-full mit-kemar-large-full"

setup() {
    make_root >/dev/null
    source_libs
    unset AX20_SURROUND_SYSTEM_STEPS
    component_load surround
    export HOME="$BATS_TEST_TMPDIR/home" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    unset XDG_CONFIG_HOME
    export X20_SURROUND_ALLOW_ROOT=1  # a root test runner (containers) is fine here
    mkdir -p "$HOME"
    # no PipeWire in the tests: pw-dump must not find a real one
    mkdir -p "$BATS_TEST_TMPDIR/nopw"
    printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/nopw/pw-dump"
    chmod +x "$BATS_TEST_TMPDIR/nopw/pw-dump"
    PATH="$BATS_TEST_TMPDIR/nopw:$PATH"
}

# stubs <dir> : systemctl and id that record / answer for a fixture user.
stubs() {
    mkdir -p "$1"
    printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\nexit 0\n' "$1" >"$1/systemctl"
    chmod +x "$1/systemctl"
    : >"$1/calls"
}

tree_listing() { (cd "$AX20_ROOT" && find . -path ./var/lib/ally-x20-steamos -prune -o -print | sort); }

@test "files: helper, eight sets, notice, licence, user unit" {
    run component_files surround
    assert_success
    assert_output_contains "$(printf 'bin/x20-surround.py\t%s\t0755' "$HELPER")"
    for s in $SETS; do
        assert_output_contains "$(printf 'surround/hrir/%s.wav\t%s/hrir/%s.wav\t0644' "$s" "$DIR" "$s")"
    done
    assert_output_contains "$(printf 'surround/NOTICE.md\t%s/NOTICE.md\t0644' "$DIR")"
    assert_output_contains "$(printf 'surround/LICENSE.Apache-2.0\t%s/LICENSE.Apache-2.0\t0644' "$DIR")"
    assert_output_contains "$(printf 'systemd/ally-x20-steamos-surround.service\t%s\t0644' "$UNIT")"
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 12 ]
}

@test "the overlay ships exactly the sets the component installs" {
    [ "$(cd "$OVL/surround/hrir" && ls | sort | tr '\n' ' ')" = "$(for s in $SETS; do echo "$s.wav"; done | sort | tr '\n' ' ')" ]
}

@test "probe: always needed (stock offers the built-in outputs as stereo only)" {
    run component_probe surround
    [ "$status" -eq 1 ]
}

@test "apply installs everything, enables the user unit by link, and skips systemctl on a fixture root" {
    stubs "$BATS_TEST_TMPDIR/stub"
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" run component_apply surround
    assert_success
    [ -x "$AX20_ROOT$HELPER" ]
    for s in $SETS; do
        cmp -s "$AX20_ROOT$DIR/hrir/$s.wav" "$OVL/surround/hrir/$s.wav"
        manifest_has "$DIR/hrir/$s.wav"
    done
    [ -f "$AX20_ROOT$DIR/NOTICE.md" ]
    [ -f "$AX20_ROOT$DIR/LICENSE.Apache-2.0" ]
    [ -f "$AX20_ROOT$UNIT" ]
    [ "$(readlink "$AX20_ROOT$LINK")" = "../ally-x20-steamos-surround.service" ]
    manifest_has "$LINK"
    [ ! -s "$BATS_TEST_TMPDIR/stub/calls" ]
    [ "$(component_status surround)" = active ]
}

@test "apply is idempotent" {
    component_apply surround
    run component_apply surround
    assert_success
    [ -z "$(manifest_paths surround | sort | uniq -d)" ]
}

@test "system steps: the user's session reloads and (re)starts the unit" {
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    me=$(id -un)
    mkdir -p "$AX20_ROOT/run/user/$(id -u)"
    PATH="$stub:$PATH" AX20_SURROUND_SYSTEM_STEPS=always AX20_SURROUND_USER="$me" run component_apply surround
    assert_success
    [ "$(cat "$stub/calls")" = "systemctl --user -M $me@ daemon-reload
systemctl --user -M $me@ restart ally-x20-steamos-surround.service" ]
}

@test "system steps: no session for the user, nothing is called" {
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    PATH="$stub:$PATH" AX20_SURROUND_SYSTEM_STEPS=always AX20_SURROUND_USER="$(id -un)" run component_apply surround
    assert_success
    [ ! -s "$stub/calls" ]
}

@test "uninstall --component surround removes everything it added; the user's choice stays" {
    before=$(tree_listing)
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    "$CLI" --root "$AX20_ROOT" surround set stereo --device headphones
    run "$CLI" --root "$AX20_ROOT" uninstall --component surround --keep-state
    assert_success
    [ -z "$(manifest_paths surround | grep -vx -e /etc/systemd -e /etc/systemd/user)" ]
    rmdir "$AX20_ROOT/etc/systemd/user" "$AX20_ROOT/etc/systemd"
    [ "$(tree_listing)" = "$before" ]
    grep -qx 'headphones=stereo' "$HOME/.config/ally-x20-steamos/surround.conf"
}

@test "unit: a user service that runs the helper and is restarted on failure" {
    u="$OVL/systemd/ally-x20-steamos-surround.service"
    grep -qx 'Type=simple' "$u"
    grep -qx "ExecStart=$HELPER run" "$u"
    grep -qx 'Restart=on-failure' "$u"
    grep -qx 'After=pipewire.service wireplumber.service' "$u"
    grep -qx "ConditionPathExists=$HELPER" "$u"
    grep -qx 'WantedBy=default.target' "$u"
}

@test "surround list and status work from the checkout, before apply" {
    run "$CLI" --root "$AX20_ROOT" surround list
    assert_success
    assert_output_contains 'sadie-d2-dry'
    assert_output_contains '(default for headphones)'
    run "$CLI" --root "$AX20_ROOT" surround status
    assert_success
    assert_output_contains 'status: stock'
    assert_output_contains 'headphones sadie-d2-dry  (sadie-d2-dry.wav, trim -1.10 dB)'
    assert_output_contains 'speakers   stereo'
}

@test "surround set: needs the component, then records the choice per output in the user's config" {
    run "$CLI" --root "$AX20_ROOT" surround set stereo --device headphones
    assert_failure
    assert_output_contains 'surround is not installed'
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" surround set hutubs-pp1-dry --device headphones
    assert_success
    assert_output_contains 'headphones: hutubs-pp1-dry'
    run "$CLI" --root "$AX20_ROOT" surround set mit-kemar-dry --device speakers
    assert_success
    conf="$HOME/.config/ally-x20-steamos/surround.conf"
    grep -qx 'headphones=hutubs-pp1-dry' "$conf"
    grep -qx 'speakers=mit-kemar-dry' "$conf"
    # nothing of it under the root: the choice is the user's
    [ -z "$(manifest_paths surround | grep surround.conf || true)" ]
}

@test "surround set user without a file: recorded, falls back to the default" {
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" surround set user --device headphones
    assert_success
    assert_output_contains 'headphones: user -> sadie-d2-dry'
    assert_output_contains 'no .wav file'
}

@test "surround set without --device and without PipeWire asks for the device" {
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" surround set stereo
    assert_failure
    assert_output_contains '--device headphones|speakers'
}

@test "surround: usage, unknown command, unknown profile, dry run" {
    run "$CLI" --root "$AX20_ROOT" surround
    [ "$status" -eq 2 ]
    assert_output_contains 'usage:'
    run "$CLI" --root "$AX20_ROOT" surround bogus
    [ "$status" -eq 2 ]
    run "$CLI" --root "$AX20_ROOT" surround --help
    assert_success
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" surround set cipic-003-full --device headphones
    assert_failure
    run "$CLI" --root "$AX20_ROOT" --dry-run surround set stereo --device headphones
    assert_success
    [ ! -e "$HOME/.config/ally-x20-steamos/surround.conf" ]
    run "$CLI" --root "$AX20_ROOT" help
    assert_output_contains 'surround'
}
