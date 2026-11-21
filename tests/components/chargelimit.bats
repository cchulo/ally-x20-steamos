#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/chargelimit.sh, overlay/bin/charge-limit-restore and
# `charge-limit` against fixture roots: the helper and two units are
# installed under /etc; the helper writes the battery's
# charge_control_end_threshold at boot and after resume with the limit last
# in force (recorded at shutdown and after resume), 100 when none was
# recorded, or a fixed limit from /etc/ally-x20-steamos/charge-limit.conf.
load '../test_helper'

HELPER=/etc/ally-x20-steamos/charge-limit-restore
UNIT=/etc/systemd/system/ally-x20-steamos-charge-limit.service
RESUME_UNIT=/etc/systemd/system/ally-x20-steamos-charge-limit-resume.service
CONF=/etc/ally-x20-steamos/charge-limit.conf
STATE=/var/lib/ally-x20-steamos/state/charge-limit
ATTR=/sys/class/power_supply/BAT1/charge_control_end_threshold
OVL="$REPO_ROOT/overlay"
SLEEP_TARGETS="suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"

setup() {
    make_root >/dev/null
    source_libs
    unset AX20_CHARGE_LIMIT_SYSTEM_STEPS
    component_load chargelimit
}

# battery <value> : a battery whose charge limit attribute reads <value>
# (0 = not written this boot).
battery() { fixture_file "$ATTR" "$1
"; }

# helper <mode> : run the helper against the fixture root.
helper() { AX20_ROOT="$AX20_ROOT" CHARGE_LIMIT_WAIT=0 "$OVL/bin/charge-limit-restore" "$@"; }

attr() { cat "$AX20_ROOT$ATTR"; }
recorded() { cat "$AX20_ROOT$STATE"; }

# stubs <dir> : systemctl that records its calls.
stubs() {
    mkdir -p "$1"
    printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\nexit 0\n' "$1" >"$1/systemctl"
    chmod +x "$1/systemctl"
    : >"$1/calls"
}

tree_listing() { (cd "$AX20_ROOT" && find . -path ./var/lib/ally-x20-steamos -prune -o -print | sort); }

@test "files: helper under /etc/ally-x20-steamos, both units under /etc/systemd/system" {
    run component_files chargelimit
    assert_success
    [ "$output" = "$(printf 'bin/charge-limit-restore\t%s\t0755\nsystemd/ally-x20-steamos-charge-limit.service\t%s\t0644\nsystemd/ally-x20-steamos-charge-limit-resume.service\t%s\t0644' "$HELPER" "$UNIT" "$RESUME_UNIT")" ]
}

@test "probe: always needed (stock writes the limit only when it is changed in Steam)" {
    run component_probe chargelimit
    [ "$status" -eq 1 ]
}

@test "apply installs the files and the enable links, records them, and skips systemctl on a fixture root" {
    stubs "$BATS_TEST_TMPDIR/stub"
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" run component_apply chargelimit
    assert_success
    [ -x "$AX20_ROOT$HELPER" ]
    [ -f "$AX20_ROOT$UNIT" ]
    [ -f "$AX20_ROOT$RESUME_UNIT" ]
    link=/etc/systemd/system/multi-user.target.wants/ally-x20-steamos-charge-limit.service
    [ "$(readlink "$AX20_ROOT$link")" = "../ally-x20-steamos-charge-limit.service" ]
    manifest_has "$link"
    for t in $SLEEP_TARGETS; do
        link="/etc/systemd/system/$t.wants/ally-x20-steamos-charge-limit-resume.service"
        [ "$(readlink "$AX20_ROOT$link")" = "../ally-x20-steamos-charge-limit-resume.service" ]
        manifest_has "$link"
    done
    [ ! -s "$BATS_TEST_TMPDIR/stub/calls" ]
    [ "$(component_status chargelimit)" = active ]
}

@test "apply is idempotent" {
    component_apply chargelimit
    run component_apply chargelimit
    assert_success
    [ -z "$(manifest_paths chargelimit | sort | uniq -d)" ]
}

@test "system steps: daemon-reload, then the boot unit is (re)started so the limit is written at once" {
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    PATH="$stub:$PATH" AX20_CHARGE_LIMIT_SYSTEM_STEPS=always run component_apply chargelimit
    assert_success
    [ "$(cat "$stub/calls")" = "systemctl daemon-reload
systemctl restart ally-x20-steamos-charge-limit.service" ]
}

@test "uninstall --component chargelimit removes everything it added and restores the tree" {
    before=$(tree_listing)
    "$CLI" --root "$AX20_ROOT" apply --only chargelimit 2>/dev/null
    "$CLI" --root "$AX20_ROOT" charge-limit 80 2>/dev/null
    [ -e "$AX20_ROOT$CONF" ]
    run "$CLI" --root "$AX20_ROOT" uninstall --component chargelimit --keep-state
    assert_success
    [ -z "$(manifest_paths chargelimit | grep -vx -e /etc/systemd -e /etc/systemd/system)" ]
    rmdir "$AX20_ROOT/etc/systemd/system" "$AX20_ROOT/etc/systemd"
    [ "$(tree_listing)" = "$before" ]
}

@test "boot unit: a oneshot before the display manager that restores at start and records at stop" {
    u="$OVL/systemd/ally-x20-steamos-charge-limit.service"
    grep -qx 'Type=oneshot' "$u"
    grep -qx 'RemainAfterExit=yes' "$u"
    grep -qx "ExecStart=$HELPER boot" "$u"
    grep -qx "ExecStop=$HELPER save" "$u"
    grep -qx 'After=local-fs.target' "$u"
    grep -qx 'Before=display-manager.service' "$u"
    grep -qx "ConditionPathExists=$HELPER" "$u"
    grep -qx 'WantedBy=multi-user.target' "$u"
}

@test "resume unit: a oneshot after every sleep target that runs the helper in resume mode" {
    u="$OVL/systemd/ally-x20-steamos-charge-limit-resume.service"
    grep -qx 'Type=oneshot' "$u"
    grep -qx "ExecStart=$HELPER resume" "$u"
    grep -qx "ConditionPathExists=$HELPER" "$u"
    grep -qx "After=$SLEEP_TARGETS" "$u"
    grep -qx "WantedBy=$SLEEP_TARGETS" "$u"
    # nothing is ordered after it, so it must never block the sleep
    run grep -E '^(Before|RemainAfterExit)=' "$u"
    assert_failure
}

@test "helper boot: nothing recorded, writes 100" {
    battery 0
    run helper boot
    assert_success
    [ "$(attr)" = 100 ]
    assert_output_contains 'charge limit set to 100 % after boot (no limit recorded, default'
}

@test "helper save: records the limit Steam set; the next boot writes it back" {
    battery 80
    run helper save
    assert_success
    [ "$(recorded)" = 80 ]
    battery 0
    run helper boot
    assert_success
    [ "$(attr)" = 80 ]
    assert_output_contains 'the limit recorded earlier'
}

@test "helper save: an attribute reading 0 (never written this boot) keeps the record" {
    fixture_file "$STATE" '70
'
    battery 0
    run helper save
    assert_success
    [ "$(recorded)" = 70 ]
    [ "$(attr)" = 0 ]
}

@test "helper save: the limit switched off in Steam (100) replaces an older record" {
    fixture_file "$STATE" '80
'
    battery 100
    helper save
    [ "$(recorded)" = 100 ]
}

@test "helper save never writes the attribute" {
    fixture_file "$STATE" '80
'
    battery 60
    helper save
    [ "$(attr)" = 60 ]
}

@test "helper resume: records the limit in force and writes it again" {
    fixture_file "$STATE" '100
'
    battery 85
    run helper resume
    assert_success
    [ "$(recorded)" = 85 ]
    [ "$(attr)" = 85 ]
    assert_output_contains 'the limit in force before the sleep'
}

@test "helper resume: attribute reads 0, falls back to the record, then to 100" {
    battery 0
    helper resume
    [ "$(attr)" = 100 ]
    fixture_file "$STATE" '75
'
    battery 0
    helper resume
    [ "$(attr)" = 75 ]
}

@test "helper: limit=<n> always wins and leaves the record alone" {
    fixture_file "$CONF" 'limit=90
'
    fixture_file "$STATE" '80
'
    battery 60
    helper save
    [ "$(recorded)" = 80 ]
    helper resume
    [ "$(attr)" = 90 ]
    [ "$(recorded)" = 80 ]
    battery 0
    helper boot
    [ "$(attr)" = 90 ]
}

@test "helper: limit=off touches neither the attribute nor the record" {
    fixture_file "$CONF" 'limit=off
'
    battery 0
    for m in boot resume save; do
        run helper "$m"
        assert_success
        [ -z "$output" ]
    done
    [ "$(attr)" = 0 ]
    [ ! -e "$AX20_ROOT$STATE" ]
}

@test "helper: a bad limit= is reported and treated as follow" {
    for bad in 19 101 abc 080 -5; do
        fixture_file "$CONF" "limit=$bad
"
        battery 0
        run helper boot
        assert_success
        assert_output_contains "ignoring limit=$bad"
        [ "$(attr)" = 100 ]
    done
}

@test "helper: a damaged record is ignored" {
    for bad in 0 101 x ''; do
        fixture_file "$STATE" "$bad
"
        battery 0
        helper boot
        [ "$(attr)" = 100 ]
    done
}

@test "helper: no battery attribute, exit 0 with a note (silent for save)" {
    run helper boot
    assert_success
    assert_output_contains 'no battery with charge_control_end_threshold'
    run helper save
    assert_success
    [ -z "$output" ]
}

@test "helper: a write the kernel refuses is logged, exit 0" {
    battery 0
    chmod 0444 "$AX20_ROOT$ATTR"
    [ "$(id -u)" != 0 ] || skip "root ignores file modes"
    run helper boot
    assert_success
    assert_output_contains 'failed; the controller keeps its own limit'
}

@test "helper: dry run prints the write and changes nothing" {
    battery 0
    CHARGE_LIMIT_DRY_RUN=1 run helper boot
    assert_success
    [ "$output" = "$AX20_ROOT$ATTR <- 100" ]
    [ "$(attr)" = 0 ]
}

@test "helper: unknown mode prints usage, exit 0" {
    run helper bogus
    assert_success
    assert_output_contains 'usage:'
}

@test "helper is POSIX sh" {
    head -n1 "$OVL/bin/charge-limit-restore" | grep -qx '#!/bin/sh'
    if command -v dash >/dev/null 2>&1; then
        dash -n "$OVL/bin/charge-limit-restore"
    fi
}

@test "charge-limit status: setting, record and limit in force" {
    run "$CLI" --root "$AX20_ROOT" charge-limit status
    assert_success
    assert_output_contains 'setting=follow'
    assert_output_contains 'recorded=none yet (100% is written)'
    assert_output_contains 'in_force=n/a'
    battery 0
    fixture_file "$STATE" '80
'
    run "$CLI" --root "$AX20_ROOT" charge-limit status
    assert_output_contains 'recorded=80%'
    assert_output_contains "in_force=the controller's own stored limit"
    battery 80
    run "$CLI" --root "$AX20_ROOT" charge-limit status
    assert_output_contains 'in_force=80%'
}

@test "charge-limit <n>: writes the settings file as a manifest entry and the limit at once" {
    battery 0
    "$CLI" --root "$AX20_ROOT" apply --only chargelimit 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" charge-limit 85
    assert_success
    grep -qx 'limit=85' "$AX20_ROOT$CONF"
    manifest_has "$CONF"
    [ "$(attr)" = 85 ]
    run "$CLI" --root "$AX20_ROOT" charge-limit status
    assert_output_contains 'setting=85%'
}

@test "charge-limit follow: back to following; the limit in force becomes the record" {
    battery 0
    "$CLI" --root "$AX20_ROOT" apply --only chargelimit 2>/dev/null
    "$CLI" --root "$AX20_ROOT" charge-limit 85 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" charge-limit follow
    assert_success
    grep -qx 'limit=follow' "$AX20_ROOT$CONF"
    [ "$(recorded)" = 85 ]
}

@test "charge-limit off: recorded, nothing written to the battery" {
    battery 0
    "$CLI" --root "$AX20_ROOT" apply --only chargelimit 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" charge-limit off
    assert_success
    grep -qx 'limit=off' "$AX20_ROOT$CONF"
    [ "$(attr)" = 0 ]
}

@test "charge-limit: needs the component, rejects bad values, prints usage" {
    run "$CLI" --root "$AX20_ROOT" charge-limit 80
    assert_failure
    assert_output_contains 'chargelimit is not installed'
    for bad in 19 101 0 080 1000 eighty; do
        run "$CLI" --root "$AX20_ROOT" charge-limit "$bad"
        [ "$status" -eq 2 ]
    done
    run "$CLI" --root "$AX20_ROOT" charge-limit
    [ "$status" -eq 2 ]
    assert_output_contains 'usage:'
    run "$CLI" --root "$AX20_ROOT" charge-limit --help
    assert_success
    run "$CLI" --root "$AX20_ROOT" help
    assert_output_contains 'charge-limit'
}

@test "charge-limit --dry-run changes nothing" {
    battery 0
    "$CLI" --root "$AX20_ROOT" apply --only chargelimit 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" --dry-run charge-limit 80
    assert_success
    [ ! -e "$AX20_ROOT$CONF" ]
    [ "$(attr)" = 0 ]
}
