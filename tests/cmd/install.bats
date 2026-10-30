#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'
load 'git_helper'

STATE=/var/lib/ally-x20-steamos

# A fake upstream: a stub CLI that records how it was called, stub apply and
# status commands, placeholder keys and a standalone uninstaller.
setup() {
    make_root >/dev/null
    git_isolate
    fixture_file /sys/class/dmi/id/board_name "RC74XA
"
    W="$BATS_TEST_TMPDIR/upstream"
    mkdir -p "$W/cmd" "$W/keys" "$W/uninstall"
    cat >"$W/ally-x20-steamos.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(cd "$(dirname "$0")" && pwd -P)" "$*" >>"$AX20_ROOT/calls"
STUB
    printf 'cmd_apply() { :; }\n' >"$W/cmd/apply.sh"
    printf 'cmd_status() { :; }\n' >"$W/cmd/status.sh"
    printf '# placeholder\n' >"$W/keys/allowed_signers"
    printf '#!/bin/sh\necho uninstall\n' >"$W/uninstall/uninstall.sh"
    git -C "$W" init --quiet
    commit_all "$W" "initial"
    git -C "$W" tag -a v0.1.0 -m v0.1.0
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    make_bare_origin "$W" "$ORIGIN"
    SRC="$AX20_ROOT$STATE/src"
}

@test "install clones into the state dir, creates the tree, records installed-from, applies" {
    run "$CLI" install --repo "$ORIGIN" --ref v0.1.0
    assert_success
    [ -d "$SRC/.git" ]
    [ "$(head_of "$SRC")" = "$(head_of "$W" v0.1.0)" ]
    for d in modules firmware cache backup state log bin; do
        [ -d "$AX20_ROOT$STATE/$d" ]
    done
    grep -qx "url=$ORIGIN" "$AX20_ROOT$STATE/state/installed-from"
    grep -qx "ref=v0.1.0" "$AX20_ROOT$STATE/state/installed-from"
    grep -qx "commit=$(head_of "$W" v0.1.0)" "$AX20_ROOT$STATE/state/installed-from"
    grep -q '^date=20' "$AX20_ROOT$STATE/state/installed-from"
    [ -f "$AX20_ROOT$STATE/keys/allowed_signers" ]
    [ -x "$AX20_ROOT$STATE/uninstall.sh" ]
    # apply then status, both from the installed checkout.
    src_real=$(cd "$SRC" && pwd -P)
    [ "$(sed -n 1p "$AX20_ROOT/calls")" = "$src_real apply" ]
    [ "$(sed -n 2p "$AX20_ROOT/calls")" = "$src_real status" ]
}

@test "install refuses a board that is not RC74XA" {
    fixture_file /sys/class/dmi/id/board_name "RC71L"
    run "$CLI" install --repo "$ORIGIN" --ref v0.1.0
    assert_failure
    assert_output_contains "RC71L"
    assert_output_contains "--force-board"
    [ ! -e "$SRC" ]
}

@test "install refuses when the DMI board cannot be read" {
    rm -f "$AX20_ROOT/sys/class/dmi/id/board_name"
    run "$CLI" install --repo "$ORIGIN" --ref v0.1.0
    assert_failure
    assert_output_contains "unknown"
}

@test "--force-board installs anyway with a warning" {
    fixture_file /sys/class/dmi/id/board_name "QEMU"
    run "$CLI" install --force-board --repo "$ORIGIN" --ref v0.1.0
    assert_success
    assert_output_contains "--force-board"
    [ -d "$SRC/.git" ]
}

@test "--dry-run writes nothing" {
    run "$CLI" --dry-run install --repo "$ORIGIN" --ref v0.1.0
    assert_success
    assert_output_contains "[dry-run]"
    [ ! -e "$SRC" ]
    [ ! -e "$AX20_ROOT$STATE/state" ]
    [ ! -e "$AX20_ROOT$STATE/keys" ]
    [ ! -e "$AX20_ROOT/calls" ]
}

@test "--no-apply stops after clone and pinning" {
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    [ -f "$AX20_ROOT$STATE/state/installed-from" ]
    [ ! -e "$AX20_ROOT/calls" ]
}

@test "re-running install updates the existing checkout to a newer ref" {
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    printf 'next\n' >"$W/NEXT"
    commit_all "$W" "next"
    git -C "$W" tag -a v0.2.0 -m v0.2.0
    git -C "$W" push --quiet origin main --tags
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.2.0
    assert_success
    [ "$(head_of "$SRC")" = "$(head_of "$W" v0.2.0)" ]
    grep -qx "ref=v0.2.0" "$AX20_ROOT$STATE/state/installed-from"
}

@test "re-install refuses to touch a checkout with local modifications" {
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    printf 'mine\n' >>"$SRC/keys/allowed_signers"
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_failure
    assert_output_contains "local modifications"
    grep -q mine "$SRC/keys/allowed_signers"
}

@test "pinned keys are kept on re-install unless --repin-keys" {
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    printf 'pinned-by-owner\n' >"$AX20_ROOT$STATE/keys/allowed_signers"
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
    grep -q pinned-by-owner "$AX20_ROOT$STATE/keys/allowed_signers"
    assert_output_contains "keeping the pinned ones"
    run "$CLI" install --no-apply --repin-keys --repo "$ORIGIN" --ref v0.1.0
    assert_success
    ! grep -q pinned-by-owner "$AX20_ROOT$STATE/keys/allowed_signers"
}

@test "install refuses when read-only mode was disabled, unless --i-know" {
    fixture_file /.ax20-readonly-disabled
    run "$CLI" install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_failure
    assert_output_contains "read-only"
    run "$CLI" --i-know install --no-apply --repo "$ORIGIN" --ref v0.1.0
    assert_success
}

@test "bootstrap.sh clones the newest release tag and runs install" {
    printf 'next\n' >"$W/NEXT"
    commit_all "$W" "next"
    git -C "$W" tag -a v0.10.0 -m v0.10.0
    git -C "$W" push --quiet origin main --tags
    # The fake upstream's stub CLI stands in for the real installer here.
    AX20_REPO_URL="$ORIGIN" run sh "$REPO_ROOT/bootstrap.sh" --force-board
    assert_success
    assert_output_contains "v0.10.0"
    grep -q " install --repo $ORIGIN --ref v0.10.0 --force-board\$" "$AX20_ROOT/calls"
}
