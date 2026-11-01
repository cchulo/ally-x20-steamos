#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

STATE=/var/lib/ally-x20-steamos

# Same throwaway "demo" component as tests/lib/component.bats, plus a
# probe_details hook.
setup() {
    make_root >/dev/null
    export AX20_KVER="7.2.7-valve2-1-neptune-72"
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR" "$BATS_TEST_TMPDIR/overlay/demo"
    printf 'demo file\n' >"$BATS_TEST_TMPDIR/overlay/demo/demo.conf"
    cat >"$AX20_COMPONENTS_DIR/demo.sh" <<'C'
COMPONENT_DESCRIPTION="demo component"
demo_files() {
    printf 'demo/demo.conf\t/etc/demo.d/ally-x20-steamos.conf\t0644\n'
}
demo_probe() {
    [ -e "$(ax20_path /usr/share/demo-native)" ] && return 0
    [ -e "$(ax20_path /usr/share/demo-unknown)" ] && return 2
    return 1
}
demo_probe_details() { printf 'looked for demo-native\n'; }
C
}

json_ok() {
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$1" >/dev/null
    else
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
    fi
}

json_get() {
    if command -v jq >/dev/null 2>&1; then
        jq -r "$2" "$1"
    else
        python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
expr = sys.argv[2].lstrip(".")
for part in expr.replace("[", ".").replace("]", "").split("."):
    if part == "":
        continue
    d = d[int(part)] if part.isdigit() else d[part]
print(str(d).lower() if isinstance(d, bool) else d)
PY
    fi
}

install_demo() {
    (
        source_libs
        manifest_install_file "$BATS_TEST_TMPDIR/overlay/demo/demo.conf" /etc/demo.d/ally-x20-steamos.conf demo
    )
}

@test "status prints header and one row per component, exit 0" {
    run "$CLI" status
    assert_success
    assert_output_contains "running kernel:"
    assert_output_contains "$AX20_KVER"
    assert_output_contains "update policy:           block"
    assert_output_contains "last self-update check:  never"
    [[ "$output" != *"audio DSP"* ]]
    echo "$output" | grep -Eq '^demo +stock +demo component$'
}

@test "status follows the component lifecycle: stock, active, superseded, n/a" {
    install_demo
    run "$CLI" status
    echo "$output" | grep -Eq '^demo +active '
    fixture_file /usr/share/demo-native
    run "$CLI" status
    echo "$output" | grep -Eq '^demo +superseded '
    rm -f "$AX20_ROOT/usr/share/demo-native" "$AX20_ROOT/etc/demo.d/ally-x20-steamos.conf"
    rm -f "$AX20_ROOT$STATE/manifest"
    fixture_file /usr/share/demo-unknown
    run "$CLI" status
    echo "$output" | grep -Eq '^demo +n/a '
}

@test "--verbose adds <name>_probe_details output" {
    run "$CLI" status --verbose
    assert_success
    assert_output_contains "    looked for demo-native"
    run "$CLI" status
    [[ "$output" != *"looked for demo-native"* ]]
}

@test "header reads policy, pending check, staged modules, last check" {
    fixture_file "$STATE/state/update-policy" "degrade
"
    fixture_file "$STATE/state/pending-reboot-check" ""
    fixture_file "/etc/ally-x20-steamos/modules/$AX20_KVER/BUILD-INFO" "commit=abc"
    fixture_file "$STATE/state/last-update-check" "$(printf '2026-10-30T10:00:00Z\t1793354400\tavailable\tv0.2.0')"
    run "$CLI" status
    assert_success
    assert_output_contains "modules staged for it:   yes"
    assert_output_contains "update policy:           degrade"
    assert_output_contains "pending reboot check:    yes"
    assert_output_contains "2026-10-30T10:00:00Z (available v0.2.0)"
}

@test "--json is valid JSON with the same facts, and status.json is written" {
    install_demo
    fixture_file "$STATE/state/last-update-check" "$(printf '2026-10-30T10:00:00Z\t1793354400\tup-to-date\tv0.1.0')"
    run "$CLI" status --json
    assert_success
    printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out.json"
    json_ok "$BATS_TEST_TMPDIR/out.json"
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .components[0].name)" = demo ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .components[0].status)" = active ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .kernel.running)" = "$AX20_KVER" ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .kernel.modules_staged)" = false ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .update_policy)" = block ]
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .last_update_check.result)" = up-to-date ]
    # the audio DSP (removed 2026-11) has no key any more
    ! grep -q '"audio_dsp"' "$BATS_TEST_TMPDIR/out.json" || false
    json_ok "$AX20_ROOT$STATE/state/status.json"
    [ "$(json_get "$AX20_ROOT$STATE/state/status.json" .components[0].status)" = active ]
}

@test "plain status also refreshes status.json; --dry-run does not" {
    run "$CLI" status
    assert_success
    json_ok "$AX20_ROOT$STATE/state/status.json"
    rm -f "$AX20_ROOT$STATE/state/status.json"
    run "$CLI" --dry-run status --json
    assert_success
    [ ! -e "$AX20_ROOT$STATE/state/status.json" ]
}

@test "JSON escapes awkward descriptions" {
    cat >"$AX20_COMPONENTS_DIR/quote.sh" <<'C'
COMPONENT_DESCRIPTION='has "quotes" and \ backslash'
quote_files() { :; }
quote_probe() { return 1; }
C
    run "$CLI" status --json
    assert_success
    printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/out.json"
    json_ok "$BATS_TEST_TMPDIR/out.json"
    [ "$(json_get "$BATS_TEST_TMPDIR/out.json" .components[1].description)" = 'has "quotes" and \ backslash' ]
}

@test "a broken component shows as error without failing status" {
    printf 'COMPONENT_DESCRIPTION=broken\n' >"$AX20_COMPONENTS_DIR/broken.sh"
    run "$CLI" status
    assert_success
    echo "$output" | grep -Eq '^broken +error'
    echo "$output" | grep -Eq '^demo +stock'
}

@test "lib/status.sh status_write_json is the writer of status.json" {
    # Stand-in for the slots/RAUC package's writer, in a private copy of the tree.
    src="$BATS_TEST_TMPDIR/src"
    mkdir -p "$src"
    cp -R "$REPO_ROOT/ally-x20-steamos.sh" "$REPO_ROOT/VERSION" "$REPO_ROOT/lib" "$REPO_ROOT/cmd" "$src/"
    cat >>"$src/lib/status.sh" <<'L'
status_write_json() {
    printf '{"writer":"lib/status.sh"}\n' | ax20_atomic_write "$(ax20_path "$AX20_STATUS_JSON_REL")"
}
L
    mkdir -p "$AX20_ROOT$STATE/state"
    run "$src/ally-x20-steamos.sh" status --json
    assert_success
    grep -q '"writer":"lib/status.sh"' "$AX20_ROOT$STATE/state/status.json"
}
