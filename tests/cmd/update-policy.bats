#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# cmd/update-policy.sh (plan §4.6).
load '../test_helper'
load '../update_helper'

setup() {
    make_root >/dev/null
    STATE="$AX20_ROOT/var/lib/ally-x20-steamos/state"
}

@test "default policy is block" {
    run "$CLI" --root "$AX20_ROOT" update-policy
    assert_success
    [ "$output" = block ]
    run "$CLI" --root "$AX20_ROOT" update-policy effective
    [ "$output" = block ]
}

@test "degrade is persisted; block switches back" {
    run "$CLI" --root "$AX20_ROOT" update-policy degrade
    assert_success
    [ "$(cat "$STATE/update-policy")" = degrade ]
    run "$CLI" --root "$AX20_ROOT" update-policy show
    [ "$output" = degrade ]
    "$CLI" --root "$AX20_ROOT" update-policy block 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" update-policy show
    [ "$output" = block ]
}

@test "degrade --once applies to the next update only" {
    "$CLI" --root "$AX20_ROOT" update-policy degrade --once 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" update-policy show
    [ "$output" = "block (next update: degrade once)" ]
    run "$CLI" --root "$AX20_ROOT" update-policy effective
    [ "$output" = degrade ]
    # peeking does not consume
    [ -f "$STATE/update-policy-once" ]
    run "$CLI" --root "$AX20_ROOT" update-policy effective --consume
    [ "$output" = degrade ]
    [ ! -e "$STATE/update-policy-once" ]
    run "$CLI" --root "$AX20_ROOT" update-policy effective
    [ "$output" = block ]
}

@test "block clears a pending --once" {
    "$CLI" --root "$AX20_ROOT" update-policy degrade --once 2>/dev/null
    "$CLI" --root "$AX20_ROOT" update-policy block 2>/dev/null
    [ ! -e "$STATE/update-policy-once" ]
}

@test "garbage in the state file falls back to block" {
    mkdir -p "$STATE"
    printf 'yolo\n' >"$STATE/update-policy"
    run "$CLI" --root "$AX20_ROOT" update-policy
    [ "$output" = block ]
}

@test "bad arguments exit 2" {
    run "$CLI" --root "$AX20_ROOT" update-policy maybe
    assert_failure 2
    run "$CLI" --root "$AX20_ROOT" update-policy block --once
    assert_failure 2
    run "$CLI" --root "$AX20_ROOT" update-policy degrade --forever
    assert_failure 2
}

@test "idempotent: setting the same policy twice is a no-op" {
    "$CLI" --root "$AX20_ROOT" update-policy degrade 2>/dev/null
    d1=$(tree_digest "$AX20_ROOT")
    "$CLI" --root "$AX20_ROOT" update-policy degrade 2>/dev/null
    [ "$(tree_digest "$AX20_ROOT")" = "$d1" ]
}

@test "dry-run writes nothing" {
    before=$(tree_digest "$AX20_ROOT")
    run "$CLI" --root "$AX20_ROOT" --dry-run update-policy degrade
    assert_success
    run "$CLI" --root "$AX20_ROOT" --dry-run update-policy degrade --once
    assert_success
    [ "$(tree_digest "$AX20_ROOT")" = "$before" ]
}
