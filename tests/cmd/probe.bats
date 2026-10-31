#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

STATE=/var/lib/ally-x20-steamos

setup() {
    make_root >/dev/null
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR"
    for n in alpha beta; do
        cat >"$AX20_COMPONENTS_DIR/$n.sh" <<C
COMPONENT_DESCRIPTION="$n component"
${n}_files() { :; }
${n}_probe() {
    [ -e "\$(ax20_path /usr/share/$n-native)" ] && return 0
    [ -e "\$(ax20_path /usr/share/$n-unknown)" ] && return 2
    return 1
}
${n}_probe_details() { printf 'checked /usr/share/$n-native\n'; }
C
    done
    Q="$AX20_ROOT$STATE/state/notifications.queue"
}

@test "probe prints one result word per component" {
    fixture_file /usr/share/beta-unknown
    run "$CLI" probe
    assert_success
    [ "$output" = "alpha: needed
beta: unknown" ]
}

@test "--verbose prints probe details" {
    run "$CLI" probe --verbose
    assert_success
    assert_output_contains "    checked /usr/share/alpha-native"
}

@test "--notify queues one notification when a component newly flips to superseded" {
    run "$CLI" probe --notify
    assert_success
    [ ! -s "$Q" ] # nothing superseded yet
    [ -f "$AX20_ROOT$STATE/state/probes.json" ]

    fixture_file /usr/share/alpha-native
    run "$CLI" probe --notify
    assert_success
    assert_output_contains "alpha: superseded"
    [ "$(wc -l <"$Q" | tr -d ' ')" = 1 ]
    # <ts>\t<level>\t<message>
    awk -F'\t' 'NF != 3 || $1 !~ /^20[0-9-]+T[0-9:]+Z$/ || $2 != "info" { exit 1 }' "$Q"
    grep -q 'alpha is now provided by stock SteamOS' "$Q"

    # Still superseded on the next run: no duplicate.
    run "$CLI" probe --notify
    assert_success
    [ "$(wc -l <"$Q" | tr -d ' ')" = 1 ]
}

@test "the first --notify run reports components that are already superseded" {
    fixture_file /usr/share/beta-native
    run "$CLI" probe --notify
    assert_success
    [ "$(wc -l <"$Q" | tr -d ' ')" = 1 ]
    grep -q 'beta is now provided' "$Q"
}

@test "plain probe leaves the baseline alone so --notify still sees the flip" {
    run "$CLI" probe --notify
    fixture_file /usr/share/alpha-native
    run "$CLI" probe
    assert_success
    [ ! -s "$Q" ]
    run "$CLI" probe --notify
    [ "$(wc -l <"$Q" | tr -d ' ')" = 1 ]
}

@test "a flip back to needed and superseded again notifies again" {
    fixture_file /usr/share/alpha-native
    run "$CLI" probe --notify
    rm -f "$AX20_ROOT/usr/share/alpha-native"
    run "$CLI" probe --notify
    fixture_file /usr/share/alpha-native
    run "$CLI" probe --notify
    [ "$(wc -l <"$Q" | tr -d ' ')" = 2 ]
}

@test "probe never removes anything, and --dry-run queues nothing" {
    fixture_file /etc/alpha.d/ally-x20-steamos.conf "ours"
    fixture_file /usr/share/alpha-native
    run "$CLI" --dry-run probe --notify
    assert_success
    [ ! -e "$Q" ]
    [ ! -e "$AX20_ROOT$STATE/state/probes.json" ]
    run "$CLI" probe --notify
    [ -f "$AX20_ROOT/etc/alpha.d/ally-x20-steamos.conf" ]
}
