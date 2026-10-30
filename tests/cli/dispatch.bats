#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

@test "no args prints usage and exits 2" {
    run "$CLI"
    assert_failure 2
    assert_output_contains usage
}

@test "--version prints the VERSION file" {
    run "$CLI" --version
    assert_success
    assert_output_contains "$(cat "$REPO_ROOT/VERSION")"
}

@test "help lists commands with summaries" {
    run "$CLI" help
    assert_success
    assert_output_contains "help"
    assert_output_contains "version"
    assert_output_contains "list commands"
}

@test "unknown command exits 2" {
    run "$CLI" nope
    assert_failure 2
    assert_output_contains "unknown command"
}

@test "unknown global option exits 2" {
    run "$CLI" --bogus help
    assert_failure 2
}

@test "--root is passed through to commands" {
    cat >"$BATS_TEST_TMPDIR/echo-root.sh" <<'C'
cmd_echo_root() { printf '%s\n' "$AX20_ROOT"; }
C
    cp "$BATS_TEST_TMPDIR/echo-root.sh" "$REPO_ROOT/cmd/echo-root.sh"
    run "$CLI" --root "$BATS_TEST_TMPDIR/r/" echo-root
    rm -f "$REPO_ROOT/cmd/echo-root.sh"
    assert_success
    [ "$output" = "$BATS_TEST_TMPDIR/r" ]
}

@test "components command lists real components without error" {
    run "$CLI" components
    assert_success
}
