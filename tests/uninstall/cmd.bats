#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# The CLI wrappers: uninstall (with --superseded and component hooks) and audit.
load '../test_helper'

setup() {
    make_root >/dev/null
    source_libs
    # Private component tree + overlay (same pattern as tests/lib/component.bats).
    export AX20_SRC="$BATS_TEST_TMPDIR/src"
    export AX20_COMPONENTS_DIR="$AX20_SRC/components"
    mkdir -p "$AX20_COMPONENTS_DIR" "$AX20_SRC/overlay/demo" "$AX20_SRC/cmd"
    ln -s "$REPO_ROOT/lib" "$AX20_SRC/lib"
    ln -s "$REPO_ROOT/uninstall" "$AX20_SRC/uninstall"
    ln -s "$REPO_ROOT/ally-x20-steamos.sh" "$AX20_SRC/ally-x20-steamos.sh"
    cp "$REPO_ROOT/cmd/uninstall.sh" "$REPO_ROOT/cmd/audit.sh" "$REPO_ROOT/cmd/help.sh" "$AX20_SRC/cmd/"
    cp "$REPO_ROOT/VERSION" "$AX20_SRC/"
    printf 'one\n' >"$AX20_SRC/overlay/demo/one.conf"
    printf 'two\n' >"$AX20_SRC/overlay/demo/two.conf"
    cat >"$AX20_COMPONENTS_DIR/alpha.sh" <<'C'
COMPONENT_DESCRIPTION="alpha"
alpha_files() { printf 'demo/one.conf\t/etc/modprobe.d/ally-x20-steamos-alpha.conf\t0644\n'; }
alpha_probe() { [ -e "$(ax20_path /usr/share/alpha-native)" ] && return 0; return 1; }
alpha_remove() { touch "$(ax20_path /var/lib/ally-x20-steamos/alpha-remove-hook-ran)"; }
C
    cat >"$AX20_COMPONENTS_DIR/beta.sh" <<'C'
COMPONENT_DESCRIPTION="beta"
beta_files() { printf 'demo/two.conf\t/etc/environment.d/90-ally-x20-steamos-beta.conf\t0644\n'; }
beta_probe() { return 1; }
C
    CLI="$AX20_SRC/ally-x20-steamos.sh"
    component_apply alpha
    component_apply beta
}

@test "uninstall --superseded removes only superseded components and runs their remove hook" {
    fixture_file /usr/share/alpha-native
    run "$CLI" --root "$AX20_ROOT" uninstall --superseded
    assert_success
    assert_output_contains "alpha: superseded"
    [ ! -e "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos-alpha.conf" ]
    [ -f "$AX20_ROOT/etc/environment.d/90-ally-x20-steamos-beta.conf" ]
    [ -e "$AX20_ROOT/var/lib/ally-x20-steamos/alpha-remove-hook-ran" ]
    [ -d "$AX20_ROOT/var/lib/ally-x20-steamos" ] # partial removal keeps the state dir
}

@test "uninstall --superseded with nothing superseded is a no-op" {
    run "$CLI" --root "$AX20_ROOT" uninstall --superseded
    assert_success
    assert_output_contains "nothing to do"
    [ -f "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos-alpha.conf" ]
}

@test "full uninstall via CLI removes everything and the state dir" {
    run "$CLI" --root "$AX20_ROOT" uninstall
    assert_success
    [ ! -e "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos-alpha.conf" ]
    [ ! -e "$AX20_ROOT/etc/environment.d/90-ally-x20-steamos-beta.conf" ]
    [ ! -d "$AX20_ROOT/var/lib/ally-x20-steamos" ]
}

@test "uninstall --dry-run via CLI changes nothing" {
    run "$CLI" --root "$AX20_ROOT" --dry-run uninstall
    assert_success
    assert_output_contains "[dry-run]"
    [ -f "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos-alpha.conf" ]
}

@test "uninstall refuses when read-only root was disabled unless --i-know" {
    touch "$AX20_ROOT/.ax20-readonly-disabled"
    run "$CLI" --root "$AX20_ROOT" uninstall
    assert_failure
    run "$CLI" --root "$AX20_ROOT" --i-know uninstall
    assert_success
}

@test "uninstall --component unknown is rejected" {
    run "$CLI" --root "$AX20_ROOT" uninstall --component nope
    assert_failure 2
}

@test "audit is clean after apply" {
    run "$CLI" --root "$AX20_ROOT" audit
    assert_success
    assert_output_contains "audit clean"
}

@test "audit reports modified, missing and unexpected files, exit 1" {
    printf 'tampered' >"$AX20_ROOT/etc/modprobe.d/ally-x20-steamos-alpha.conf"
    rm "$AX20_ROOT/etc/environment.d/90-ally-x20-steamos-beta.conf"
    fixture_file /etc/ld.so.conf.d/00-ally-x20-steamos.conf "stray"
    fixture_file /home/deck/.config/pipewire/pipewire.conf.d/50-x20-stray.conf "stray"
    run "$CLI" --root "$AX20_ROOT" audit
    assert_failure 1
    assert_output_contains "modified   /etc/modprobe.d/ally-x20-steamos-alpha.conf"
    assert_output_contains "missing    /etc/environment.d/90-ally-x20-steamos-beta.conf"
    assert_output_contains "unexpected /etc/ld.so.conf.d/00-ally-x20-steamos.conf"
    assert_output_contains "unexpected /home/deck/.config/pipewire/pipewire.conf.d/50-x20-stray.conf"
}

@test "audit --json emits valid JSON" {
    rm "$AX20_ROOT/etc/environment.d/90-ally-x20-steamos-beta.conf"
    run "$CLI" --root "$AX20_ROOT" audit --json
    assert_failure 1
    printf '%s' "$output" | jq -e 'map(select(.state == "missing")) | length == 1' >/dev/null
}
