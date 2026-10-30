#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

setup() {
    make_root >/dev/null
    source_libs
}

@test "ax20_path prefixes AX20_ROOT" {
    [ "$(ax20_path /etc/x)" = "$AX20_ROOT/etc/x" ]
    [ "$(ax20_path etc/x)" = "$AX20_ROOT/etc/x" ]
}

@test "ax20_path with empty root yields absolute path" {
    AX20_ROOT=""
    [ "$(ax20_path /etc/x)" = "/etc/x" ]
}

@test "ax20_version_ge compares dotted versions" {
    ax20_version_ge 0.4.0 0.4.0
    ax20_version_ge 0.4.1 0.4.0
    ax20_version_ge 1.0 0.9.9
    ! ax20_version_ge 0.3.9 0.4.0
    ax20_version_ge 7.2.7-valve2 7.2.7
}

@test "ax20_sha256 matches a known digest" {
    printf 'abc' >"$AX20_ROOT/f"
    [ "$(ax20_sha256 "$AX20_ROOT/f")" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]
}

@test "ax20_atomic_write writes via temp file with mode" {
    printf 'hello' | ax20_atomic_write "$AX20_ROOT/out" 0600
    [ "$(cat "$AX20_ROOT/out")" = hello ]
    ! ls "$AX20_ROOT"/out.?????? 2>/dev/null
}

@test "ax20_atomic_write in dry-run writes nothing" {
    AX20_DRY_RUN=1
    printf 'hello' | ax20_atomic_write "$AX20_ROOT/out" 2>/dev/null
    [ ! -e "$AX20_ROOT/out" ]
}

@test "ax20_mkdir_p reports created vs existed" {
    [ "$(ax20_mkdir_p "$AX20_ROOT/new/dir")" = created ]
    [ "$(ax20_mkdir_p "$AX20_ROOT/new/dir")" = existed ]
}

@test "ax20_mkdir_p_list prints created ancestors top-most first" {
    mkdir -p "$AX20_ROOT/a"
    run ax20_mkdir_p_list "$AX20_ROOT/a/b/c"
    assert_success
    [ "$output" = "$AX20_ROOT/a/b
$AX20_ROOT/a/b/c" ]
    [ -d "$AX20_ROOT/a/b/c" ]
    run ax20_mkdir_p_list "$AX20_ROOT/a/b/c"
    assert_success
    [ -z "$output" ]
}

@test "readonly check passes on an untouched fixture root" {
    ax20_check_readonly_root
}

@test "readonly check refuses when steamos-readonly is disabled" {
    touch "$AX20_ROOT/.ax20-readonly-disabled"
    run ax20_check_readonly_root
    assert_failure
    assert_output_contains "refuses"
}

@test "readonly check continues with --i-know" {
    touch "$AX20_ROOT/.ax20-readonly-disabled"
    AX20_I_KNOW=1
    run ax20_check_readonly_root
    assert_success
}

@test "require_root is a no-op on fixture roots" {
    require_root
}

@test "die uses the given exit code" {
    run die 7 "boom"
    [ "$status" -eq 7 ]
    assert_output_contains "boom"
}
