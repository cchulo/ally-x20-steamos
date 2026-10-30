#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

setup() {
    make_root >/dev/null
    source_libs
    export AX20_KVER="7.2.7-valve2-1-neptune-72"
}

@test "probe_file_exists" {
    run probe_file_exists /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
    [ "$status" -eq 1 ]
    fixture_file /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
    run probe_file_exists /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
    [ "$status" -eq 0 ]
}

@test "probe_file_contains handles missing, absent, present" {
    run probe_file_contains /usr/bin/gamescope AMS740LS02
    [ "$status" -eq 2 ]
    fixture_file /usr/bin/gamescope "binary junk without it"
    run probe_file_contains /usr/bin/gamescope AMS740LS02
    [ "$status" -eq 1 ]
    fixture_file /usr/bin/gamescope "$(printf 'x\001yAMS740LS02\002')"
    run probe_file_contains /usr/bin/gamescope AMS740LS02
    [ "$status" -eq 0 ]
}

@test "probe_version_ge" {
    run probe_version_ge 0.4.0 0.4.0; [ "$status" -eq 0 ]
    run probe_version_ge 0.3.1 0.4.0; [ "$status" -eq 1 ]
    run probe_version_ge "" 0.4.0;    [ "$status" -eq 2 ]
}

@test "probe_stock_module_path finds compressed modules for AX20_KVER" {
    run probe_stock_module_path hid_asus_ally
    [ "$status" -eq 2 ]
    fixture_file "/usr/lib/modules/$AX20_KVER/kernel/drivers/hid/hid-asus-ally.ko.zst" "mod"
    run probe_stock_module_path hid-asus-ally
    [ "$status" -eq 0 ]
    [ "$output" = "/usr/lib/modules/$AX20_KVER/kernel/drivers/hid/hid-asus-ally.ko.zst" ]
    run probe_stock_module_path snd-soc-acpi-amd-match
    [ "$status" -eq 1 ]
}

@test "probe_stock_module_contains on an uncompressed module" {
    fixture_file "/usr/lib/modules/$AX20_KVER/kernel/sound/soc/amd/snd-soc-acpi-amd-match.ko" "...RC74XA..."
    run probe_stock_module_contains snd-soc-acpi-amd-match RC74XA
    [ "$status" -eq 0 ]
    run probe_stock_module_contains snd-soc-acpi-amd-match NOPE
    [ "$status" -eq 1 ]
}

@test "probe_soname_version picks the highest version" {
    fixture_file /usr/lib/libdisplay-info.so.2.1.0
    fixture_file /usr/lib/libdisplay-info.so.1
    fixture_file /usr/lib/libdisplay-info.so.2.0.0
    run probe_soname_version /usr/lib libdisplay-info
    [ "$status" -eq 0 ]
    [ "$output" = 2.1.0 ]
    run probe_soname_version /usr/lib libnothing
    [ "$status" -eq 1 ]
    run probe_soname_version /nonexistent libnothing
    [ "$status" -eq 2 ]
}

@test "probe_result_word maps codes" {
    [ "$(probe_result_word 0)" = superseded ]
    [ "$(probe_result_word 1)" = needed ]
    [ "$(probe_result_word 2)" = unknown ]
}
