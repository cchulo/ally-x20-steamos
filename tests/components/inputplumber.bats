#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/inputplumber.sh against fixture roots (plan §1.2, §5, §6 check 5).
load '../test_helper'

PROFILE=/etc/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml
CAPMAP=/etc/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml
HWDB=/etc/udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb
DROPIN=/etc/systemd/system/inputplumber.service.d/50-ally-x20-steamos.conf
OVL="$REPO_ROOT/overlay"

setup() {
    make_root >/dev/null
    source_libs
    unset AX20_INPUTPLUMBER_FALLBACK AX20_INPUTPLUMBER_SYSTEM_STEPS
    component_load inputplumber
}

# stock_inputplumber <version> : stock package without an X20 profile.
stock_inputplumber() {
    fixture_file /usr/share/inputplumber/devices/50-rog_xbox_ally.yaml \
        "matches:
  - dmi_data:
      board_name: RC73XA
"
    fixture_file /usr/share/inputplumber/VERSION "$1"
}

fallback_binary() {
    fixture_file /opt/ally-x20-steamos/inputplumber/bin/inputplumber '#!/bin/sh
echo inputplumber 0.83.1
'
    chmod +x "$AX20_ROOT/opt/ally-x20-steamos/inputplumber/bin/inputplumber"
}

same_file() { cmp -s "$1" "$2"; }

tree_listing() { (cd "$AX20_ROOT" && find . -path ./var/lib/ally-x20-steamos -prune -o -print | sort); }

# ------------------------------------------------------------------ probes --
@test "probe: 1 when stock devices/ lacks RC74XA, 0 when present, 2 when missing" {
    run inputplumber_probe
    assert_failure 2
    stock_inputplumber 0.78.0
    run inputplumber_probe
    assert_failure 1
    fixture_file /usr/share/inputplumber/devices/50-rog_xbox_ally_x20.yaml "board_name: RC74XA"
    run inputplumber_probe
    assert_success
}

@test "stock version: fixture marker, --version style text, pacman db, unknown" {
    run inputplumber_stock_version
    assert_failure 2
    fixture_file /usr/lib/holo/pacmandb/local/inputplumber-0.83.1-1/desc "%NAME%
inputplumber

%VERSION%
0.83.1-1
"
    [ "$(inputplumber_stock_version)" = 0.83.1 ]
    fixture_file /usr/share/inputplumber/VERSION "inputplumber 0.78.0"
    [ "$(inputplumber_stock_version)" = 0.78.0 ]
    fixture_file /usr/share/inputplumber/VERSION "garbage"
    rm -rf "$AX20_ROOT/usr/lib/holo"
    run inputplumber_stock_version
    assert_failure 2
}

@test "daemon version probe: >= 0.78.0 ok, older too old, unknown is 2" {
    run inputplumber_probe_daemon_version
    assert_failure 2
    stock_inputplumber 0.78.0
    run inputplumber_probe_daemon_version
    assert_success
    fixture_file /usr/share/inputplumber/VERSION 0.77.7
    run inputplumber_probe_daemon_version
    assert_failure 1
    fixture_file /usr/share/inputplumber/VERSION 0.83.1
    run inputplumber_probe_daemon_version
    assert_success
}

# ------------------------------------------------------------------- apply --
@test "stock 0.78.0 without profile: installs adapted profile, capability map, hwdb; status active" {
    stock_inputplumber 0.78.0
    [ "$(component_status inputplumber)" = stock ]
    run component_apply inputplumber
    assert_success
    assert_output_contains "profile variant: stock"
    assert_output_contains "skipping systemd-hwdb update"
    same_file "$AX20_ROOT$PROFILE" "$OVL/inputplumber/devices.d/50-rog_xbox_ally_x20.stock.yaml"
    same_file "$AX20_ROOT$CAPMAP" "$OVL/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml"
    same_file "$AX20_ROOT$HWDB" "$OVL/udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb"
    [ ! -e "$AX20_ROOT$DROPIN" ]
    [ "$(component_status inputplumber)" = active ]
}

@test "stock >= 0.82.0: installs the verbatim upstream profile and no capability map" {
    stock_inputplumber 0.83.1
    component_apply inputplumber
    same_file "$AX20_ROOT$PROFILE" "$OVL/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml"
    [ ! -e "$AX20_ROOT$CAPMAP" ]
    [ -f "$AX20_ROOT$HWDB" ]
    [ "$(component_status inputplumber)" = active ]
}

@test "stock already has an RC74XA profile: superseded, apply still allowed but warns" {
    stock_inputplumber 0.83.1
    fixture_file /usr/share/inputplumber/devices/50-rog_xbox_ally_x20.yaml "      board_name: RC74XA"
    [ "$(component_status inputplumber)" = superseded ]
    run component_apply inputplumber
    assert_success
    assert_output_contains "already ships an RC74XA profile"
    [ -f "$AX20_ROOT$PROFILE" ]
    [ "$(component_status inputplumber)" = superseded ]
}

@test "no stock InputPlumber: status n/a and apply installs nothing" {
    [ "$(component_status inputplumber)" = n/a ]
    run component_apply inputplumber
    assert_success
    assert_output_contains "stock InputPlumber not found"
    [ -z "$(manifest_paths inputplumber)" ]
    [ ! -e "$AX20_ROOT/etc/inputplumber" ]
}

# ---------------------------------------------------------------- fallback --
@test "fallback drop-in is not installed unless flagged or the daemon is too old" {
    stock_inputplumber 0.78.0
    fallback_binary
    component_apply inputplumber
    [ ! -e "$AX20_ROOT$DROPIN" ]
}

@test "fallback flagged without a build: warns, keeps the stock daemon and stock profile" {
    stock_inputplumber 0.78.0
    export AX20_INPUTPLUMBER_FALLBACK=1
    run component_apply inputplumber
    assert_success
    assert_output_contains "build it with build/build-inputplumber.sh"
    [ ! -e "$AX20_ROOT$DROPIN" ]
    same_file "$AX20_ROOT$PROFILE" "$OVL/inputplumber/devices.d/50-rog_xbox_ally_x20.stock.yaml"
}

@test "fallback flagged with a build: ExecStart drop-in + upstream profile" {
    stock_inputplumber 0.78.0
    fallback_binary
    export AX20_INPUTPLUMBER_FALLBACK=1
    component_apply inputplumber
    [ -f "$AX20_ROOT$DROPIN" ]
    grep -qx 'ExecStart=' "$AX20_ROOT$DROPIN"
    grep -qx 'ExecStart=/opt/ally-x20-steamos/inputplumber/bin/inputplumber' "$AX20_ROOT$DROPIN"
    grep -qx 'Environment=XDG_DATA_DIRS=/opt/ally-x20-steamos/inputplumber/share' "$AX20_ROOT$DROPIN"
    [ -z "$(grep '@AX20_' "$AX20_ROOT$DROPIN")" ]
    same_file "$AX20_ROOT$PROFILE" "$OVL/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml"
    manifest_verify "$DROPIN"
    [ "$(component_status inputplumber)" = active ]
}

@test "fallback is selected automatically when the stock daemon is too old" {
    stock_inputplumber 0.70.0
    fallback_binary
    component_apply inputplumber
    [ -f "$AX20_ROOT$DROPIN" ]
}

@test "fallback opt dir is one variable (can move under /var/lib)" {
    stock_inputplumber 0.78.0
    export AX20_INPUTPLUMBER_OPT_REL=/var/lib/ally-x20-steamos/opt/inputplumber
    fixture_file /var/lib/ally-x20-steamos/opt/inputplumber/bin/inputplumber '#!/bin/sh'
    chmod +x "$AX20_ROOT/var/lib/ally-x20-steamos/opt/inputplumber/bin/inputplumber"
    export AX20_INPUTPLUMBER_FALLBACK=1
    component_apply inputplumber
    grep -qx 'ExecStart=/var/lib/ally-x20-steamos/opt/inputplumber/bin/inputplumber' "$AX20_ROOT$DROPIN"
}

# ------------------------------------------------- idempotency, dry-run ... --
@test "apply is idempotent" {
    stock_inputplumber 0.78.0
    fallback_binary
    export AX20_INPUTPLUMBER_FALLBACK=1
    component_apply inputplumber
    first=$(manifest_paths inputplumber | sort)
    sums1=$(cd "$AX20_ROOT" && find etc -type f -exec cksum {} + | sort)
    component_apply inputplumber
    [ "$(manifest_paths inputplumber | sort)" = "$first" ]
    [ "$(cd "$AX20_ROOT" && find etc -type f -exec cksum {} + | sort)" = "$sums1" ]
    [ "$(manifest_paths inputplumber | grep -c 50-rog_xbox_ally_x20.yaml)" = 1 ]
}

@test "dry-run writes nothing, not even the manifest" {
    stock_inputplumber 0.78.0
    fallback_binary
    export AX20_INPUTPLUMBER_FALLBACK=1
    before=$(tree_listing)
    AX20_DRY_RUN=1 run component_apply inputplumber
    assert_success
    assert_output_contains "[dry-run]"
    [ "$(tree_listing)" = "$before" ]
    [ ! -s "$AX20_ROOT/var/lib/ally-x20-steamos/manifest" ]
}

@test "manifest round-trip: every path recorded and verified; removing them restores the tree" {
    stock_inputplumber 0.78.0
    fallback_binary
    export AX20_INPUTPLUMBER_FALLBACK=1
    before=$(tree_listing)
    component_apply inputplumber
    for p in "$PROFILE" "$HWDB" "$DROPIN"; do
        manifest_has "$p"
        manifest_verify "$p"
    done
    manifest_has /etc/inputplumber/devices.d
    run component_remove_hook inputplumber
    assert_success
    # what uninstall does: newest first; files, then the (empty) dirs we created
    for kind in file dir; do
        manifest_entries_reverse | while IFS= read -r e; do
            [ "$(manifest_entry_get "$e" kind)" = "$kind" ] || continue
            p=$(manifest_entry_get "$e" path)
            if [ "$kind" = file ]; then rm -f "$AX20_ROOT$p"; else rmdir "$AX20_ROOT$p"; fi
            manifest_forget "$p"
        done
    done
    [ -z "$(manifest_paths inputplumber)" ]
    # parents of parents (e.g. /etc/inputplumber) are created implicitly by
    # mkdir -p; a real uninstall removes them when empty as well
    rmdir "$AX20_ROOT/etc/inputplumber" "$AX20_ROOT/etc/udev" "$AX20_ROOT/etc/systemd/system" "$AX20_ROOT/etc/systemd" 2>/dev/null || true
    [ "$(tree_listing)" = "$before" ]
}

@test "system steps run hwdb update, udev trigger and enable --now when the unit is disabled" {
    stock_inputplumber 0.78.0
    stub="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$stub"
    for c in systemd-hwdb udevadm systemctl; do
        printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n[ "$1" = is-enabled ] && exit 1\nexit 0\n' "$c" "$stub" >"$stub/$c"
        chmod +x "$stub/$c"
    done
    PATH="$stub:$PATH" AX20_INPUTPLUMBER_SYSTEM_STEPS=always run component_apply inputplumber
    assert_success
    grep -qx 'systemd-hwdb update' "$stub/calls"
    grep -qx 'udevadm trigger --action=change --subsystem-match=dmi' "$stub/calls"
    grep -qx 'systemctl enable --now inputplumber.service' "$stub/calls"
    [ -f "$AX20_ROOT/var/lib/ally-x20-steamos/inputplumber/service-enabled-by-ally-x20-steamos" ]
    PATH="$stub:$PATH" AX20_INPUTPLUMBER_SYSTEM_STEPS=always run component_remove_hook inputplumber
    grep -qx 'systemctl disable inputplumber.service' "$stub/calls"
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/inputplumber/service-enabled-by-ally-x20-steamos" ]
}

# ------------------------------------------------------------ overlay data --
# yaml_check <file> : parse with PyYAML when available, otherwise check the
# required top-level keys structurally.
yaml_check() {
    if python3 -c 'import yaml' 2>/dev/null; then
        python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert d["version"] == 1; assert d["kind"] in ("CompositeDevice", "CapabilityMap")' "$1"
    else
        grep -qx 'version: 1' "$1"
        grep -qE '^kind: (CompositeDevice|CapabilityMap)$' "$1"
        grep -qE '^name: .+' "$1"
        [ -z "$(grep "$(printf '\t')" "$1")" ]
    fi
}

@test "device profiles parse and match RC74XA" {
    for f in 50-rog_xbox_ally_x20.yaml 50-rog_xbox_ally_x20.stock.yaml; do
        y="$OVL/inputplumber/devices.d/$f"
        yaml_check "$y"
        grep -qx 'kind: CompositeDevice' "$y"
        for k in matches source_devices target_devices capability_map_id options; do
            grep -q "^$k:" "$y"
        done
        grep -qx '      board_name: RC74XA' "$y"
        head -n 1 "$y" | grep -q 'SPDX-License-Identifier: GPL-3.0-or-later'
    done
    grep -qx 'capability_map_id: ally_x20_steamos_aly2' "$OVL/inputplumber/devices.d/50-rog_xbox_ally_x20.stock.yaml"
}

@test "capability map parses and carries the id the stock profile references" {
    y="$OVL/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml"
    yaml_check "$y"
    grep -qx 'kind: CapabilityMap' "$y"
    grep -qx 'id: ally_x20_steamos_aly2' "$y"
}

capmap_targets() {
    # "<source key> <target button>" per mapping of the X20 capability map
    awk '/^      - keyboard: / { k = $3 } /^        button: / { print k, $2 }' \
        "$OVL/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml"
}

@test "X20 map: Armoury Crate -> QuickAccess, capture -> Screenshot, no Steam chords" {
    run capmap_targets
    assert_success
    printf '%s\n' "$output" | grep -qx 'KeyF16 QuickAccess'
    printf '%s\n' "$output" | grep -qx 'KeyProg1 QuickAccess'
    printf '%s\n' "$output" | grep -qx 'KeyF21 QuickAccess'
    printf '%s\n' "$output" | grep -qx 'KeyProg2 Screenshot'
    printf '%s\n' "$output" | grep -qx 'KeyF22 Screenshot'
    printf '%s\n' "$output" | grep -qx 'KeyF14 LeftPaddle1'
    printf '%s\n' "$output" | grep -qx 'KeyF15 RightPaddle1'
    # Keyboard (Steam+X via the default profile), Guide and QuickAccess2 leak
    # Steam chords or a bare Steam press
    run grep -E '^        button: (Keyboard|Guide|QuickAccess2|South|North)$' \
        "$OVL/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml"
    assert_failure
}

@test "X20 stock profile: every mapped key is in the evdev include list, KeyProg2 matches patch 0012" {
    y="$OVL/inputplumber/devices.d/50-rog_xbox_ally_x20.stock.yaml"
    for k in $(capmap_targets | awk '{ print $1 }'); do
        grep -qx "        - Keyboard:$k" "$y" || {
            echo "not included: $k"
            false
        }
    done
    grep -q 'KEY_PROG2, data\[1\] == ALLY_X20_KEY_RIGHT' "$REPO_ROOT"/patches/kernel/0012-*.patch
    # hidraw sources stay (they set qam_mode=0); one evdev source only
    [ "$(grep -c '^    hidraw:$' "$y")" -eq 2 ]
    [ "$(grep -c '^    evdev:$' "$y")" -eq 1 ]
}

@test "upstream profile is byte-identical to InputPlumber v0.83.0 after our header" {
    y="$OVL/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml"
    body=$(awk 'f { print; next } /^$/ { f = 1 }' "$y" | git hash-object --stdin)
    [ "$body" = 24bd3e6134329dad02e1b259de1ea0cd1ba69604 ]
}

@test "hwdb drop-in has the upstream DMI match and autostart property" {
    h="$OVL/udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb"
    grep -qx 'dmi:\*svnASUS:\*rnRC74XA:\*' "$h"
    grep -qx '  USE_INPUTPLUMBER=1' "$h"
}

@test "build script: help and dry-run show the pinned tag without building" {
    run "$REPO_ROOT/build/build-inputplumber.sh" --help
    assert_success
    assert_output_contains "FALLBACK ONLY"
    run "$REPO_ROOT/build/build-inputplumber.sh" --dry-run --engine host --out "$AX20_ROOT/out"
    assert_success
    assert_output_contains "v0.83.1"
    assert_output_contains "cargo build --release --locked"
    [ ! -e "$AX20_ROOT/out" ]
}
