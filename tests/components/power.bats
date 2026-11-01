#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/power.sh against fixture roots (docs/power.md): the RC74XA
# steamos-manager device entry, the bind-mount shim's unit, probes and the
# asus-armoury power-limits report.
load '../test_helper'

STOCK=/usr/share/steamos-manager/devices
TOML=/etc/ally-x20-steamos/steamos-manager/90-ally-x20-steamos-rc74xa.toml
SHIM=/etc/ally-x20-steamos/steamos-manager-devices-shim
UNIT=/etc/systemd/system/ally-x20-steamos-power-devices.service
WANTS_MU=/etc/systemd/system/multi-user.target.wants/ally-x20-steamos-power-devices.service
WANTS_SM=/etc/systemd/system/steamos-manager.service.wants/ally-x20-steamos-power-devices.service
OVL="$REPO_ROOT/overlay"
ATTRS=/sys/class/firmware-attributes/asus-armoury/attributes

setup() {
    make_root >/dev/null
    source_libs
    unset AX20_POWER_SYSTEM_STEPS AX20_POWER_USER
    component_load power
}

# stock_steamos_manager : the 26.4.1 device files (no RC74XA).
stock_steamos_manager() {
    fixture_file "$STOCK/rog-ally-series.toml" '[[device]]
dmi.sys_vendor = "ASUSTeK COMPUTER INC."
dmi.board_name = "RC73XA"
device = "rog_xbox_ally_x"
variant = "RC73XA"
'
    fixture_file "$STOCK/rog-xbox-ally.toml" '[[device]]
dmi.sys_vendor = "ASUSTeK COMPUTER INC."
dmi.board_name = "RC73YA"
'
}

tree_listing() { (cd "$AX20_ROOT" && find . -path ./var/lib/ally-x20-steamos -prune -o -print | sort); }

# stubs <dir> : systemctl that records its calls (is-enabled fails).
stubs() {
    mkdir -p "$1"
    printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\nexit 0\n' "$1" >"$1/systemctl"
    chmod +x "$1/systemctl"
    : >"$1/calls"
}

# ------------------------------------------------------------------ files --
@test "files: nothing without a steamos-manager device directory" {
    run component_files power
    assert_success
    [ -z "$output" ]
}

@test "files: device entry and shim under /etc/ally-x20-steamos, unit under /etc/systemd, nothing under /usr" {
    stock_steamos_manager
    run component_files power
    assert_success
    [ "$output" = "$(printf 'steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml\t%s\t0644\nbin/steamos-manager-devices-shim\t%s\t0755\nsystemd/ally-x20-steamos-power-devices.service\t%s\t0644' "$TOML" "$SHIM" "$UNIT")" ]
    run bash -c 'printf "%s\n" "$1" | cut -f2 | grep "^/usr/"' _ "$output"
    assert_failure
}

# ----------------------------------------------------------------- probes --
@test "probe: 2 without steamos-manager, 1 when stock lacks RC74XA, 0 when a stock file lists it" {
    run power_probe
    assert_failure 2
    stock_steamos_manager
    run power_probe
    assert_failure 1
    fixture_file "$STOCK/rog-ally-series.toml" '[[device]]
dmi.sys_vendor = "ASUS"
dmi.board_name = "RC74XA"
'
    run power_probe
    assert_success
}

@test "probe: our own entry in the (bind-mounted) directory does not count as stock" {
    stock_steamos_manager
    cp "$OVL/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml" "$AX20_ROOT$STOCK/"
    run power_probe
    assert_failure 1
}

@test "probe: a future schema (performance_profile.driver.acpi) with RC74XA is still detected" {
    stock_steamos_manager
    fixture_file "$STOCK/rog-xbox-ally-x20.toml" '[[device]]
dmi.sys_vendor = "ASUS"
dmi.board_name = "RC74XA"
[performance_profile.driver.acpi]
name = "asus-wmi"
'
    run power_probe
    assert_success
}

# ------------------------------------------------------------------ apply --
@test "apply installs entry, shim, unit and both enable links through the manifest" {
    stock_steamos_manager
    run component_apply power
    assert_success
    cmp -s "$OVL/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml" "$AX20_ROOT$TOML"
    cmp -s "$OVL/bin/steamos-manager-devices-shim" "$AX20_ROOT$SHIM"
    [ -x "$AX20_ROOT$SHIM" ]
    cmp -s "$OVL/systemd/ally-x20-steamos-power-devices.service" "$AX20_ROOT$UNIT"
    [ "$(readlink "$AX20_ROOT$WANTS_MU")" = ../ally-x20-steamos-power-devices.service ]
    [ "$(readlink "$AX20_ROOT$WANTS_SM")" = ../ally-x20-steamos-power-devices.service ]
    for p in "$TOML" "$SHIM" "$UNIT" "$WANTS_MU" "$WANTS_SM"; do
        manifest_has "$p"
        manifest_verify "$p"
    done
    # the stock directory is untouched
    [ "$(ls "$AX20_ROOT$STOCK")" = "$(printf 'rog-ally-series.toml\nrog-xbox-ally.toml')" ]
    run component_status power
    [ "$output" = active ]
}

@test "apply is idempotent and never runs systemctl under a root prefix" {
    stock_steamos_manager
    stubs "$BATS_TEST_TMPDIR/stub"
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" component_apply power
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" run component_apply power
    assert_success
    [ ! -s "$BATS_TEST_TMPDIR/stub/calls" ]
    [ -z "$(manifest_paths power | sort | uniq -d)" ]
}

@test "apply via the CLI is skipped when stock steamos-manager already lists RC74XA" {
    stock_steamos_manager
    fixture_file "$STOCK/rog-xbox-ally-x20.toml" 'dmi.board_name = "RC74XA"'
    run "$CLI" --root "$AX20_ROOT" apply --only power
    assert_success
    assert_output_contains "stock SteamOS provides this"
    [ ! -e "$AX20_ROOT$TOML" ]
    [ -z "$(manifest_paths power)" ]
    run component_status power
    [ "$output" = superseded ]
}

@test "status: n/a without steamos-manager, stock when needed but not installed" {
    run component_status power
    [ "$output" = n/a ]
    stock_steamos_manager
    run component_status power
    [ "$output" = stock ]
}

@test "system steps: daemon-reload, restart the unit, try-restart both steamos-manager daemons; remove stops it" {
    stock_steamos_manager
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    mkdir -p "$AX20_ROOT/run/user/$(id -u)"
    PATH="$stub:$PATH" AX20_POWER_SYSTEM_STEPS=always AX20_POWER_USER="$(id -un)" run component_apply power
    assert_success
    grep -qx 'systemctl daemon-reload' "$stub/calls"
    grep -qx 'systemctl restart ally-x20-steamos-power-devices.service' "$stub/calls"
    grep -qx 'systemctl try-restart steamos-manager.service' "$stub/calls"
    grep -qx "systemctl --user -M $(id -un)@ try-restart steamos-manager.service" "$stub/calls"
    # the unit comes before the daemon restarts
    [ "$(grep -n 'restart ally-x20' "$stub/calls" | cut -d: -f1)" -lt "$(grep -n 'try-restart steamos-manager' "$stub/calls" | head -n1 | cut -d: -f1)" ]
    : >"$stub/calls"
    PATH="$stub:$PATH" AX20_POWER_SYSTEM_STEPS=always AX20_POWER_USER="$(id -un)" AX20_MOUNTINFO=/dev/null run component_remove_hook power
    assert_success
    grep -qx 'systemctl stop ally-x20-steamos-power-devices.service' "$stub/calls"
    grep -qx 'systemctl try-restart steamos-manager.service' "$stub/calls"
    [ "$(cat "$AX20_ROOT/run/ally-x20-steamos/steamos-manager-devices.state")" = stopped ]
}

@test "system steps: no user session means no user restart" {
    stock_steamos_manager
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    PATH="$stub:$PATH" AX20_POWER_SYSTEM_STEPS=always AX20_POWER_USER="$(id -un)" run component_apply power
    assert_success
    assert_output_contains "no running session"
    run grep -- '--user' "$stub/calls"
    assert_failure
}

@test "uninstall --component power removes everything it added and restores the tree" {
    stock_steamos_manager
    before=$(tree_listing)
    "$CLI" --root "$AX20_ROOT" apply --only power 2>/dev/null
    [ -e "$AX20_ROOT$UNIT" ]
    run "$CLI" --root "$AX20_ROOT" uninstall --component power --keep-state
    assert_success
    # only the protected /etc/systemd{,/system} dirs (fixture-only: a real
    # system always has them) stay recorded
    [ -z "$(manifest_paths power | grep -vx -e /etc/systemd -e /etc/systemd/system)" ]
    rmdir "$AX20_ROOT/etc/systemd/system" "$AX20_ROOT/etc/systemd"
    [ "$(tree_listing)" = "$before" ]
}

# ------------------------------------------------------- kernel limits --
@test "kernel limits: not loaded, attribute unreadable (ENODEV), readable" {
    run power_kernel_limits
    assert_failure 2
    assert_output_contains "asus-armoury not loaded"
    mkdir -p "$AX20_ROOT$ATTRS/ppt_pl1_spl"
    run power_kernel_limits
    assert_failure 1
    assert_output_contains "no RC74XA power limits"
    assert_output_contains "rebuild"
    fixture_file "$ATTRS/ppt_pl1_spl/current_value" "35"
    fixture_file "$ATTRS/ppt_pl1_spl/min_value" "7"
    fixture_file "$ATTRS/ppt_pl1_spl/max_value" "35"
    run power_kernel_limits
    assert_success
    [ "$output" = "SPL 35 W (range 7..35 W)" ]
}

@test "probe details: device files, shim state, asus-armoury" {
    stock_steamos_manager
    fixture_file /run/ally-x20-steamos/steamos-manager-devices.state mounted
    run power_probe_details
    assert_success
    assert_output_contains "steamos_manager_devices=stock lacks RC74XA"
    assert_output_contains "shim=mounted"
    assert_output_contains "asus_armoury=asus-armoury not loaded"
}

# ------------------------------------------------------------ overlay data --
@test "device entry: the 26.4.1 schema with the upstream RC74XA values" {
    f="$OVL/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml"
    if python3 -c 'import tomllib' 2>/dev/null; then
        run python3 -I - "$f" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
# Only keys the stock 26.4.1 DeviceConfig knows (steamos-manager/src/hardware.rs).
assert set(d) <= {"device", "tdp_limit", "fan_speed", "gpu_performance", "gpu_power_profile",
                  "battery_charge_limit", "performance_profile", "inputplumber", "cec_hw",
                  "firmware_debug"}, sorted(d)
assert d["device"] == [{"dmi": {"sys_vendor": "ASUS", "board_name": "RC74XA"},
                        "device": "rog_xbox_ally_x_20", "variant": "RC74XA",
                        "friendly_name": "ROG Xbox Ally"}], d["device"]
assert d["gpu_performance"] == {"driver": "amdgpu"}
assert d["gpu_power_profile"] == {"driver": "amdgpu"}
# 26.4.1: platform_profile_name + suggested_default, no driver.acpi table
assert d["performance_profile"] == {"platform_profile_name": "asus-wmi",
                                    "suggested_default": "performance"}, d["performance_profile"]
assert d["tdp_limit"] == {"method": "firmware_attribute",
                          "firmware_attribute": {"attribute": "asus-armoury",
                                                 "performance_profile": "performance"}}, d["tdp_limit"]
assert d["battery_charge_limit"] == {"method": "acpi_sb"}
PY
        assert_success
    else
        grep -qx 'dmi.sys_vendor = "ASUS"' "$f"
        grep -qx 'dmi.board_name = "RC74XA"' "$f"
        grep -qx 'platform_profile_name = "asus-wmi"' "$f"
        grep -qx 'attribute = "asus-armoury"' "$f"
        grep -qx 'method = "firmware_attribute"' "$f"
    fi
    run grep -n '^\[performance_profile\.driver' "$f"
    assert_failure
}

@test "unit: oneshot before both steamos-manager daemons, wanted by multi-user and steamos-manager" {
    u="$OVL/systemd/ally-x20-steamos-power-devices.service"
    grep -qx 'Type=oneshot' "$u"
    grep -qx 'RemainAfterExit=yes' "$u"
    grep -qx "ExecStart=$SHIM start" "$u"
    grep -qx "ExecStop=$SHIM stop" "$u"
    before=$(sed -n 's/^Before=//p' "$u")
    for w in steamos-manager.service systemd-user-sessions.service; do
        case " $before " in *" $w "*) ;; *)
            echo "not Before=$w"
            false
            ;;
        esac
    done
    grep -qx 'WantedBy=multi-user.target steamos-manager.service' "$u"
    grep -qx "ConditionPathExists=$SHIM" "$u"
}

@test "the component writes nothing under /usr" {
    stock_steamos_manager
    snap() { (cd "$AX20_ROOT/usr" && find . -exec ls -ld {} + | awk '{ print $1, $5, $NF }' | sort && find . -type f -exec cat {} +); }
    before=$(snap)
    component_apply power
    [ "$(snap)" = "$before" ]
}
