#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

KV=7.2.7-valve2-2-neptune-72-g31504582a073

setup() {
    make_root >/dev/null
    source_libs
    export AX20_KVER="$KV"
    export AX20_PATCHES_DIR="$BATS_TEST_TMPDIR/patches"
    mkdir -p "$AX20_PATCHES_DIR"
    printf '0001-a.patch\tsound/soc/amd/acp\tsnd-soc-acpi-amd-match.ko\n' >"$AX20_PATCHES_DIR/modules.list"
    printf '0010-h.patch\tdrivers/hid\thid-asus-ally.ko\n' >"$AX20_PATCHES_DIR/modules-hid.list"
}

# stock_modules <asoc-content> <hid-content> : fixture stock modules.
stock_modules() {
    fixture_file "/usr/lib/modules/$KV/kernel/sound/soc/amd/acp/snd-soc-acpi-amd-match.ko" "$1"
    fixture_file "/usr/lib/modules/$KV/kernel/drivers/hid/hid-asus-ally.ko" "$2"
}

stage_build() {
    local d="$BATS_TEST_TMPDIR/build"
    mkdir -p "$d"
    printf 'kver=%s\n' "$KV" >"$d/BUILD-INFO"
    printf 'a' >"$d/snd-soc-acpi-amd-match.ko.zst"
    printf 'h' >"$d/hid-asus-ally.ko.zst"
    modules_stage "$KV" "$d"
}

@test "component loads and lists the helper in the state dir, nothing under /usr" {
    component_load modules
    run component_files modules
    assert_success
    [ "$output" = "$(printf 'bin/load-or-fallback\t/var/lib/ally-x20-steamos/bin/load-or-fallback\t0755\tshared')" ]
}

@test "apply installs the helper and a modprobe.d drop-in generated from the lists" {
    run component_apply modules
    assert_success
    [ -x "$AX20_ROOT/var/lib/ally-x20-steamos/bin/load-or-fallback" ]
    conf="$AX20_ROOT/etc/modprobe.d/ally-x20-steamos-modules.conf"
    [ -f "$conf" ]
    grep -Fxq 'install hid-asus-ally /var/lib/ally-x20-steamos/bin/load-or-fallback hid-asus-ally $CMDLINE_OPTS' "$conf"
    grep -Fxq 'install snd-soc-acpi-amd-match /var/lib/ally-x20-steamos/bin/load-or-fallback snd-soc-acpi-amd-match $CMDLINE_OPTS' "$conf"
    [ -d "$AX20_ROOT/var/lib/ally-x20-steamos/modules" ]
    manifest_has /etc/modprobe.d/ally-x20-steamos-modules.conf
    manifest_has /var/lib/ally-x20-steamos/bin/load-or-fallback
    [ -z "$(find "$AX20_ROOT/usr" -newer "$AX20_ROOT/etc" 2>/dev/null)" ]
}

@test "apply is idempotent" {
    component_apply modules
    run component_apply modules
    assert_success
    [ "$(manifest_paths modules | sort | uniq -d)" = "" ]
}

@test "probe: 2 when the stock modules dir for the kernel is absent" {
    component_load modules
    run modules_probe
    [ "$status" -eq 2 ]
}

@test "probe: 1 when a stock module lacks its fix string" {
    component_load modules
    stock_modules "...RC74XA..." "no rings here"
    run modules_probe
    [ "$status" -eq 1 ]
    stock_modules "nothing" "go_s:rgb:joystick_rings"
    run modules_probe
    [ "$status" -eq 1 ]
}

@test "probe: 0 only when every stock module contains its fix" {
    component_load modules
    stock_modules "x RC74XA y" "x go_s:rgb:joystick_rings y"
    run modules_probe
    [ "$status" -eq 0 ]
}

@test "status: n/a when nothing installed and nothing to inspect" {
    run component_status modules
    [ "$output" = n/a ]
}

@test "status: stock (pending rebuild) when hooks are in place but no build for this kernel" {
    stock_modules "nothing" "nothing"
    component_apply modules
    run component_status modules
    [ "$output" = stock ]
    run modules_status_detail
    assert_output_contains "pending rebuild"
    assert_output_contains "$KV"
}

@test "status: active when hooks are in place and modules for AX20_KVER are staged" {
    stock_modules "nothing" "nothing"
    component_apply modules
    stage_build
    run component_status modules
    [ "$output" = active ]
    # a different running kernel has no build yet
    AX20_KVER=7.2.10-valve1-1-neptune-72-g1b214a39f3cb run component_status modules
    [ "$output" = stock ]
}

@test "status: stock with an explanation when kernel lockdown is active" {
    stock_modules "nothing" "nothing"
    component_apply modules
    stage_build
    fixture_file /sys/kernel/security/lockdown "none [integrity] confidentiality"
    run component_status modules
    [ "$output" = stock ]
    run modules_status_detail
    assert_output_contains "lockdown"
}

@test "status: stock when the drop-in was modified" {
    stock_modules "nothing" "nothing"
    component_apply modules
    stage_build
    printf '# edited\n' >>"$AX20_ROOT/etc/modprobe.d/ally-x20-steamos-modules.conf"
    run component_status modules
    [ "$output" = stock ]
}

@test "status: superseded when stock carries the fixes" {
    stock_modules "RC74XA" "go_s:rgb:joystick_rings"
    component_apply modules
    run component_status modules
    [ "$output" = superseded ]
}

@test "status: superseded when our build found every patch already upstream" {
    stock_modules "nothing" "nothing"
    component_apply modules
    d="$BATS_TEST_TMPDIR/build"
    mkdir -p "$d"
    printf 'kver=%s\nmodule.snd-soc-acpi-amd-match=superseded\nmodule.hid-asus-ally=superseded\n' "$KV" >"$d/BUILD-INFO"
    modules_stage "$KV" "$d"
    run component_status modules
    [ "$output" = superseded ]
}

@test "rebuild command: prints the source used and BUILD-INFO" {
    a="$AX20_ROOT/var/lib/ally-x20-steamos/cache/artifacts"
    mkdir -p "$a" "$BATS_TEST_TMPDIR/art/$KV"
    printf 'kver=%s\nheader_source=2\n' "$KV" >"$BATS_TEST_TMPDIR/art/$KV/BUILD-INFO"
    printf 'a' >"$BATS_TEST_TMPDIR/art/$KV/snd-soc-acpi-amd-match.ko.zst"
    printf 'h' >"$BATS_TEST_TMPDIR/art/$KV/hid-asus-ally.ko.zst"
    tar -C "$BATS_TEST_TMPDIR/art" -cf - "$KV" | zstd -q -o "$a/modules-$KV.tar.zst"
    printf '%s  x\n' "$(ax20_sha256 "$a/modules-$KV.tar.zst")" >"$a/modules-$KV.tar.zst.sha256"
    run env AX20_OFFLINE=1 "$CLI" --root "$AX20_ROOT" rebuild --source cache
    assert_success
    assert_output_contains "modules for $KV: cache"
    assert_output_contains "header_source=2"
}

@test "rebuild command: failure is reported, unknown source rejected" {
    run env AX20_OFFLINE=1 "$CLI" --root "$AX20_ROOT" rebuild
    assert_failure
    assert_output_contains "stock modules stay in use"
    run "$CLI" --root "$AX20_ROOT" rebuild --source floppy
    assert_failure 2
}
