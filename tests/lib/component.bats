#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

setup() {
    make_root >/dev/null
    source_libs
    # A throwaway component tree so the suite does not depend on real components.
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR" "$BATS_TEST_TMPDIR/overlay/demo"
    printf 'demo file\n' >"$BATS_TEST_TMPDIR/overlay/demo/demo.conf"
    # Point overlay lookups at the temp overlay by overriding AX20_SRC/overlay via symlink.
    export AX20_SRC="$BATS_TEST_TMPDIR/src"
    mkdir -p "$AX20_SRC"
    ln -s "$REPO_ROOT/lib" "$AX20_SRC/lib"
    ln -s "$BATS_TEST_TMPDIR/overlay" "$AX20_SRC/overlay"
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
demo_apply() { touch "$(ax20_path /var/lib/ally-x20-steamos/demo-applied)"; }
C
}

@test "component_list and description" {
    [ "$(component_list)" = demo ]
    [ "$(component_description demo)" = "demo component" ]
}

@test "component_load rejects malformed components" {
    printf 'COMPONENT_DESCRIPTION=x\n' >"$AX20_COMPONENTS_DIR/bad.sh"
    run component_load bad
    assert_failure
    assert_output_contains "bad_probe"
}

@test "status is stock before apply, active after, superseded when probe says so" {
    [ "$(component_status demo)" = stock ]
    component_apply demo
    [ -f "$AX20_ROOT/etc/demo.d/ally-x20-steamos.conf" ]
    [ -f "$AX20_ROOT/var/lib/ally-x20-steamos/demo-applied" ]
    [ "$(component_status demo)" = active ]
    fixture_file /usr/share/demo-native
    [ "$(component_status demo)" = superseded ]
}

@test "status is n/a when probe is unknown and nothing installed" {
    fixture_file /usr/share/demo-unknown
    [ "$(component_status demo)" = n/a ]
}

@test "drifted install reports stock (needs re-apply)" {
    component_apply demo
    printf 'tampered' >"$AX20_ROOT/etc/demo.d/ally-x20-steamos.conf"
    [ "$(component_status demo)" = stock ]
}

@test "component_apply is idempotent" {
    component_apply demo
    component_apply demo
    [ "$(manifest_paths demo | grep -c 'ally-x20-steamos.conf')" = 1 ]
}
