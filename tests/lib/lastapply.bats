#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# lib/lastapply.sh: the record of what the last apply did per component.
load '../test_helper'

LA=/var/lib/ally-x20-steamos/state/last-apply.json

setup() {
    make_root >/dev/null
    export AX20_KVER=7.2.7-valve2-test
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR" "$AX20_ROOT/var/lib/ally-x20-steamos/state"
    for c in one two three; do
        printf 'COMPONENT_DESCRIPTION="%s"\n%s_files() { :; }\n%s_probe() { return 1; }\n' "$c" "$c" "$c" >"$AX20_COMPONENTS_DIR/$c.sh"
    done
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/lastapply.sh"
}

get() { jq -r "$1" "$AX20_ROOT$LA"; }

@test "la_write produces valid JSON with one entry per recorded component, in component order" {
    la_begin apply
    la_record two applied
    la_record one unchanged
    la_record three skipped "stock SteamOS provides this"
    la_write 0
    jq -e . "$AX20_ROOT$LA" >/dev/null
    [ "$(get .schema)" = 1 ]
    [ "$(get .result)" = ok ]
    [ "$(get '[.components[].name] | join(" ")')" = "one three two" ]
    [ "$(get '.components[] | select(.name == "three") | .reason')" = "stock SteamOS provides this" ]
    [ "$(get '.components[0] | keys | join(",")')" = "command,name,outcome,when" ]
    # Mode 0644, written atomically (no temp file left behind).
    [ -z "$(find "$AX20_ROOT/var/lib/ally-x20-steamos/state" -name 'last-apply.json.*')" ]
}

@test "a failure keeps the reason and the last error lines, cleaned and bounded; odd characters stay valid JSON" {
    err="$BATS_TEST_TMPDIR/err"
    {
        for i in 1 2 3 4 5 6 7; do printf 'noise line %s\n' "$i"; done
        printf 'cp: cannot create "x\\y"\ttab\n'
        printf 'ally-x20-steamos: error: write to /etc/x failed: "quoted" back\\slash\n'
        printf 'ally-x20-steamos: error: component two failed to apply\n'
        printf '\n'
    } >"$err"
    [ "$(la_reason_from "$err")" = 'write to /etc/x failed: "quoted" back\slash' ]
    la_begin "apply --only two"
    la_record two failed "$(la_reason_from "$err")" "$err"
    la_write 4
    jq -e . "$AX20_ROOT$LA" >/dev/null
    [ "$(get .result)" = failed ]
    [ "$(get .exit_code)" = 4 ]
    [ "$(get '.components[0].reason')" = 'write to /etc/x failed: "quoted" back\slash' ]
    [ "$(get '.components[0].errors | length')" = 5 ]
    [ "$(get '.components[0].errors[2]')" = 'cp: cannot create "x\y" tab' ]
    [ "$(get '.components[0].errors[4]')" = 'component two failed to apply' ]
    # A very long line is cut.
    head -c 2000 /dev/zero | tr '\0' 'x' >"$err"
    la_begin apply
    la_record two failed "long" "$err"
    la_write 4
    [ "$(get '.components[0].errors[0] | length')" = 300 ]
    # Without any output the reason falls back to the last line, or nothing.
    : >"$err"
    [ -z "$(la_reason_from "$err")" ]
}

@test "entries of components this run did not touch are carried over; a component that no longer exists is dropped" {
    la_begin apply
    la_record one applied
    la_record two failed "first failure"
    la_record three applied
    la_write 4
    w1=$(get '.components[] | select(.name == "two") | .when')
    la_begin boot
    la_record one applied
    la_write 0
    [ "$(get .command)" = boot ]
    [ "$(get .result)" = ok ]
    [ "$(get '.components[] | select(.name == "one") | .command')" = boot ]
    [ "$(get '.components[] | select(.name == "two") | .outcome')" = failed ]
    [ "$(get '.components[] | select(.name == "two") | .reason')" = "first failure" ]
    [ "$(get '.components[] | select(.name == "two") | .when')" = "$w1" ]
    [ "$(get '.components[] | select(.name == "two") | .command')" = apply ]
    rm "$AX20_COMPONENTS_DIR/three.sh"
    la_begin apply
    la_record two applied
    la_write 0
    [ "$(get '[.components[].name] | join(" ")')" = "one two" ]
    [ "$(get '.components[] | select(.name == "two") | .outcome')" = applied ]
    [ "$(get '.components[] | select(.name == "two") | has("reason")')" = false ]
}

@test "la_components and la_header read the record back (jq and the python fallback agree)" {
    la_begin apply
    la_record one applied
    la_record two failed 'no "space" left'
    la_write 4
    run la_components
    assert_success
    [ "${#lines[@]}" -eq 2 ]
    printf '%s\n' "${lines[1]}" | awk -F'\t' '$1 == "two" && $2 == "failed" && $4 == "apply" && $5 == "no \"space\" left" { ok = 1 } END { exit !ok }'
    [ "$(la_header command)" = apply ]
    [ "$(la_header result)" = failed ]
    with_jq=$(la_components)
    ax20_have() { [ "$1" = jq ] && return 1; command -v "$1" >/dev/null 2>&1; }
    [ "$(la_components)" = "$with_jq" ]
    [ "$(la_header result)" = failed ]
}

@test "nothing is written in dry-run mode or without a state directory; a missing or broken record reads as empty" {
    la_begin apply
    la_record one applied
    AX20_DRY_RUN=1 la_write 0
    [ ! -e "$AX20_ROOT$LA" ]
    [ -z "$(la_components)" ]
    [ -z "$(la_header when)" ]
    rm -rf "$AX20_ROOT/var/lib/ally-x20-steamos/state"
    la_write 0
    [ ! -e "$AX20_ROOT$LA" ]
    mkdir -p "$AX20_ROOT/var/lib/ally-x20-steamos/state"
    printf 'not json\n' >"$AX20_ROOT$LA"
    [ -z "$(la_components)" ]
    [ -z "$(la_header when)" ]
}

@test "SteamOS version, build and branch come from os-release and the branch file; only stable is supported" {
    fixture_file /etc/os-release 'NAME="SteamOS"
VERSION_ID="3.8.2"
BUILD_ID=20261101.1
'
    [ "$(la_steamos_field VERSION_ID)" = 3.8.2 ]
    [ "$(la_steamos_field BUILD_ID)" = 20261101.1 ]
    [ -z "$(la_steamos_branch)" ]
    fixture_file /var/lib/steamos-branch "beta
"
    [ "$(la_steamos_branch)" = beta ]
    [ "$(AX20_STEAMOS_BRANCH=main la_steamos_branch)" = main ]
    [ "$(la_branch_supported rel)" = true ]
    [ "$(la_branch_supported stable)" = true ]
    [ "$(la_branch_supported beta)" = false ]
    [ "$(la_branch_supported preview)" = false ]
    [ "$(la_branch_supported main)" = false ]
    [ "$(la_branch_supported "")" = null ]
    la_begin apply
    la_write 0
    [ "$(get .steamos.version)" = 3.8.2 ]
    [ "$(get .steamos.branch)" = beta ]
    [ "$(get .steamos.supported)" = false ]
    [ "$(get '.components | length')" = 0 ]
}

@test "la_record rejects an unknown outcome" {
    run la_record one exploded
    assert_failure
}
