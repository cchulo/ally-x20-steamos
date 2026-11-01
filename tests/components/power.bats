#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/power.sh and cmd/power.sh against fixture roots (docs/power.md):
# the rendered RC74XA steamos-manager device entry (with and without the TDP
# slider), the bind-mount shim's unit, probes and the asus-armoury report.
load '../test_helper'

STOCK=/usr/share/steamos-manager/devices
TOML=/etc/ally-x20-steamos/steamos-manager/90-ally-x20-steamos-rc74xa.toml
SHIM=/etc/ally-x20-steamos/steamos-manager-devices-shim
UNIT=/etc/systemd/system/ally-x20-steamos-power-devices.service
WANTS_MU=/etc/systemd/system/multi-user.target.wants/ally-x20-steamos-power-devices.service
WANTS_SM=/etc/systemd/system/steamos-manager.service.wants/ally-x20-steamos-power-devices.service
SETTINGS=/etc/ally-x20-steamos/power.conf
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

@test "files: shim under /etc/ally-x20-steamos, unit under /etc/systemd, nothing under /usr (apply renders the entry)" {
    stock_steamos_manager
    run component_files power
    assert_success
    [ "$output" = "$(printf 'bin/steamos-manager-devices-shim\t%s\t0755\nsystemd/ally-x20-steamos-power-devices.service\t%s\t0644' "$SHIM" "$UNIT")" ]
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
    [ "$(sed -n 's/^tdp_slider=//p' "$AX20_ROOT$SETTINGS")" = off ]
    for p in "$TOML" "$SETTINGS" "$SHIM" "$UNIT" "$WANTS_MU" "$WANTS_SM"; do
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

# ------------------------------------------------------------ tdp slider --
@test "tdp_slider setting: off without a file, on only for on/1, last line wins" {
    run power_tdp_slider
    [ "$output" = off ]
    fixture_file "$SETTINGS" 'tdp_slider=yes'
    run power_tdp_slider
    [ "$output" = off ]
    fixture_file "$SETTINGS" '# x
tdp_slider = on'
    run power_tdp_slider
    [ "$output" = on ]
    fixture_file "$SETTINGS" 'tdp_slider=1
tdp_slider=off'
    run power_tdp_slider
    [ "$output" = off ]
}

@test "CLI power tdp-slider: refuses before power is installed" {
    stock_steamos_manager
    run "$CLI" --root "$AX20_ROOT" power tdp-slider on
    assert_failure
    assert_output_contains "apply --only power"
    [ ! -e "$AX20_ROOT$SETTINGS" ]
}

@test "CLI power tdp-slider on|off re-renders the entry, keeps the manifest verifying; bad value is a usage error" {
    stock_steamos_manager
    "$CLI" --root "$AX20_ROOT" apply --only power 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" power tdp-slider
    [ "$output" = tdp_slider=off ]
    run "$CLI" --root "$AX20_ROOT" power tdp-slider on
    assert_success
    assert_output_contains "tdp-slider: on"
    [ "$(sed -n 's/^tdp_slider=//p' "$AX20_ROOT$SETTINGS")" = on ]
    check_entry "$AX20_ROOT$TOML" 1
    manifest_verify "$TOML"
    manifest_verify "$SETTINGS"
    run component_status power
    [ "$output" = active ]
    # a re-apply (boot service, self-update) keeps the choice
    component_apply power
    check_entry "$AX20_ROOT$TOML" 1
    run "$CLI" --root "$AX20_ROOT" power tdp-slider off
    assert_success
    cmp -s "$OVL/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml" "$AX20_ROOT$TOML"
    manifest_verify "$TOML"
    run "$CLI" --root "$AX20_ROOT" power tdp-slider maybe
    assert_failure 2
}

@test "CLI power tdp-slider on restarts the shim unit and both steamos-manager daemons" {
    stock_steamos_manager
    component_apply power
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    mkdir -p "$AX20_ROOT/run/user/$(id -u)"
    PATH="$stub:$PATH" AX20_POWER_SYSTEM_STEPS=always AX20_POWER_USER="$(id -un)" run "$CLI" --root "$AX20_ROOT" power tdp-slider on
    assert_success
    grep -qx 'systemctl restart ally-x20-steamos-power-devices.service' "$stub/calls"
    grep -qx 'systemctl try-restart steamos-manager.service' "$stub/calls"
    grep -qx "systemctl --user -M $(id -un)@ try-restart steamos-manager.service" "$stub/calls"
}

@test "upgrade: an installed pre-change entry (with [tdp_limit], [gpu_power_profile]) is rewritten by re-apply" {
    stock_steamos_manager
    component_apply power
    # what the previous release installed and recorded
    old="$BATS_TEST_TMPDIR/old.toml"
    cat "$OVL/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml" - >"$old" <<'T'
[gpu_power_profile]
driver = "amdgpu"

[tdp_limit]
method = "firmware_attribute"

[tdp_limit.firmware_attribute]
attribute = "asus-armoury"
performance_profile = "performance"
T
    manifest_install_file "$old" "$TOML" power 0644
    manifest_verify "$TOML"
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    PATH="$stub:$PATH" AX20_POWER_SYSTEM_STEPS=always run "$CLI" --root "$AX20_ROOT" apply --only power
    assert_success
    check_entry "$AX20_ROOT$TOML" 0
    manifest_verify "$TOML"
    [ "$(sed -n 's/^tdp_slider=//p' "$AX20_ROOT$SETTINGS")" = off ]
    # the shim restarts, so it remounts the copy with the new entry
    grep -qx 'systemctl restart ally-x20-steamos-power-devices.service' "$stub/calls"
}

@test "status: power status and apply say the TDP slider is intentionally not exposed" {
    stock_steamos_manager
    component_apply power
    run "$CLI" --root "$AX20_ROOT" power status
    assert_success
    assert_output_contains "status: active"
    assert_output_contains "tdp_slider=off (intentionally not exposed"
    run component_apply power
    assert_output_contains "TDP slider off (intentionally not exposed"
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
    assert_output_contains "tdp_slider=off (intentionally not exposed: this firmware ignores PPT writes"
    assert_output_contains "asus_armoury=asus-armoury not loaded"
}

# ------------------------------------------------------------ overlay data --
# check_entry <file> <tdp:0|1> : the 26.4.1 schema with the upstream RC74XA
# values, no [gpu_power_profile], [tdp_limit] only when asked for.
check_entry() {
    if python3 -c 'import tomllib' 2>/dev/null; then
        run python3 -I - "$1" "$2" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
tdp = sys.argv[2] == "1"
# Only keys the stock 26.4.1 DeviceConfig knows (steamos-manager/src/hardware.rs).
assert set(d) <= {"device", "tdp_limit", "fan_speed", "gpu_performance", "gpu_power_profile",
                  "battery_charge_limit", "performance_profile", "inputplumber", "cec_hw",
                  "firmware_debug"}, sorted(d)
assert d["device"] == [{"dmi": {"sys_vendor": "ASUS", "board_name": "RC74XA"},
                        "device": "rog_xbox_ally_x", "variant": "RC74XA",
                        "friendly_name": "ROG Xbox Ally"}], d["device"]
assert d["gpu_performance"] == {"driver": "amdgpu"}
# no pp_power_profile_mode on this APU
assert "gpu_power_profile" not in d, d
# 26.4.1: platform_profile_name + suggested_default, no driver.acpi table
assert d["performance_profile"] == {"platform_profile_name": "asus-wmi",
                                    "suggested_default": "balanced"}, d["performance_profile"]
assert d["battery_charge_limit"] == {"method": "acpi_sb"}
if tdp:
    assert d["tdp_limit"] == {"method": "firmware_attribute",
                              "firmware_attribute": {"attribute": "asus-armoury",
                                                     "performance_profile": "performance"}}, d["tdp_limit"]
else:
    assert "tdp_limit" not in d, d
PY
        assert_success
    else
        grep -qx 'dmi.sys_vendor = "ASUS"' "$1"
        grep -qx 'dmi.board_name = "RC74XA"' "$1"
        grep -qx 'device = "rog_xbox_ally_x"' "$1"
        grep -qx 'platform_profile_name = "asus-wmi"' "$1"
        grep -qx 'suggested_default = "balanced"' "$1"
        run grep -n '^\[gpu_power_profile' "$1"
        assert_failure
        if [ "$2" = 1 ]; then
            grep -qx '\[tdp_limit\]' "$1"
            grep -qx 'attribute = "asus-armoury"' "$1"
            grep -qx 'method = "firmware_attribute"' "$1"
        else
            run grep -n '^\[tdp_limit' "$1"
            assert_failure
        fi
    fi
    run grep -n '^\[performance_profile\.driver' "$1"
    assert_failure
}

@test "device entry (overlay): profiles and charge limit, no [tdp_limit], no [gpu_power_profile]" {
    check_entry "$OVL/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml" 0
}

@test "device entry (rendered, default): identical to the overlay file, no TDP slider" {
    stock_steamos_manager
    component_apply power
    cmp -s "$OVL/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml" "$AX20_ROOT$TOML"
    check_entry "$AX20_ROOT$TOML" 0
}

@test "device entry (rendered, tdp_slider=on): upstream's [tdp_limit] tables appended" {
    stock_steamos_manager
    fixture_file "$SETTINGS" 'tdp_slider=on'
    power_render_entry >"$BATS_TEST_TMPDIR/entry.toml"
    check_entry "$BATS_TEST_TMPDIR/entry.toml" 1
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
