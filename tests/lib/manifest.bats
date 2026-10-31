#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

setup() {
    make_root >/dev/null
    source_libs
    SRC="$BATS_TEST_TMPDIR/src.conf"
    printf 'options foo bar\n' >"$SRC"
}

@test "manifest_record then manifest_has / manifest_entry" {
    manifest_record /etc/a.conf audio file deadbeef shared false
    manifest_has /etc/a.conf
    ! manifest_has /etc/b.conf
    [ "$(manifest_entry_get "$(manifest_entry /etc/a.conf)" component)" = audio ]
}

@test "manifest_record is idempotent per path" {
    manifest_record /etc/a.conf audio file 1111 shared false
    manifest_record /etc/a.conf audio file 2222 shared false
    [ "$(manifest_paths | wc -l | tr -d ' ')" = 1 ]
    [ "$(manifest_entry_get "$(manifest_entry /etc/a.conf)" sha256)" = 2222 ]
}

@test "manifest_paths filters by component; entries_reverse is newest first" {
    manifest_record /etc/a audio file 1 shared false
    manifest_record /etc/b hdr file 2 shared false
    manifest_record /etc/c audio file 3 shared false
    [ "$(manifest_paths audio | tr '\n' ' ')" = "/etc/a /etc/c " ]
    [ "$(manifest_entries_reverse | head -n1 | _manifest_field path)" = /etc/c ]
    [ "$(manifest_components | tr '\n' ' ')" = "audio hdr " ]
}

@test "manifest_forget removes only that entry" {
    manifest_record /etc/a audio file 1 shared false
    manifest_record /etc/b audio file 2 shared false
    manifest_forget /etc/a
    ! manifest_has /etc/a
    manifest_has /etc/b
}

@test "manifest escapes quotes and backslashes in paths" {
    manifest_record '/etc/we"ird\path' audio file 1 shared false
    manifest_has '/etc/we"ird\path'
}

@test "manifest_install_file copies, records file and created parent dir" {
    manifest_install_file "$SRC" /etc/modprobe.d/ally-x20-steamos.conf audio 0644
    [ -f "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos.conf" ]
    manifest_has /etc/modprobe.d/ally-x20-steamos.conf
    manifest_has /etc/modprobe.d
    [ "$(manifest_entry_get "$(manifest_entry /etc/modprobe.d/ally-x20-steamos.conf)" created_dir)" = true ]
    [ "$(manifest_entry_get "$(manifest_entry /etc/modprobe.d)" kind)" = dir ]
    manifest_verify /etc/modprobe.d/ally-x20-steamos.conf
}

@test "manifest_install_file records every created ancestor directory" {
    manifest_install_file "$SRC" /home/deck/.config/wireplumber/scripts/x20-route.lua audio_dsp 0644 home
    manifest_has /home
    manifest_has /home/deck
    manifest_has /home/deck/.config
    manifest_has /home/deck/.config/wireplumber
    manifest_has /home/deck/.config/wireplumber/scripts
    [ "$(manifest_paths | wc -l | tr -d ' ')" = 6 ]
}

@test "manifest_install_file does not record created_dir for existing parent" {
    mkdir -p "$AX20_ROOT/etc/modprobe.d"
    manifest_install_file "$SRC" /etc/modprobe.d/x.conf audio
    [ "$(manifest_entry_get "$(manifest_entry /etc/modprobe.d/x.conf)" created_dir)" = false ]
    ! manifest_has /etc/modprobe.d
}

@test "manifest_install_file refuses to clobber an unrecorded existing file" {
    fixture_file /etc/stock.conf "stock content"
    run manifest_install_file "$SRC" /etc/stock.conf audio
    assert_failure
    assert_output_contains "refusing to overwrite"
    [ "$(cat "$AX20_ROOT/etc/stock.conf")" = "stock content" ]
}

@test "manifest_install_file is idempotent (re-run overwrites own file)" {
    manifest_install_file "$SRC" /etc/x.conf audio
    printf 'changed\n' >"$SRC"
    manifest_install_file "$SRC" /etc/x.conf audio
    [ "$(cat "$AX20_ROOT/etc/x.conf")" = changed ]
    [ "$(manifest_paths | grep -c '^/etc/x.conf$')" = 1 ]
}

@test "manifest_verify detects modified and missing files" {
    manifest_install_file "$SRC" /etc/x.conf audio
    manifest_verify /etc/x.conf
    printf 'tampered' >"$AX20_ROOT/etc/x.conf"
    run manifest_verify /etc/x.conf
    [ "$status" -eq 1 ]
    rm "$AX20_ROOT/etc/x.conf"
    run manifest_verify /etc/x.conf
    [ "$status" -eq 2 ]
    run manifest_verify /etc/never
    [ "$status" -eq 3 ]
}

@test "manifest_install_symlink records target and verifies" {
    manifest_install_symlink /var/lib/ally-x20-steamos/bin/gamescope /usr/local/bin/gamescope hdr
    [ "$(readlink "$AX20_ROOT/usr/local/bin/gamescope")" = /var/lib/ally-x20-steamos/bin/gamescope ]
    manifest_verify /usr/local/bin/gamescope
    ln -sfn /elsewhere "$AX20_ROOT/usr/local/bin/gamescope"
    run manifest_verify /usr/local/bin/gamescope
    [ "$status" -eq 1 ]
}

@test "manifest_install_symlink refuses to replace a foreign symlink or file" {
    mkdir -p "$AX20_ROOT/usr/local/bin"
    ln -s /stock "$AX20_ROOT/usr/local/bin/foreign"
    run manifest_install_symlink /x /usr/local/bin/foreign hdr
    assert_failure
    fixture_file /usr/local/bin/realfile
    run manifest_install_symlink /x /usr/local/bin/realfile hdr
    assert_failure
}

@test "dry-run install writes neither file nor manifest" {
    AX20_DRY_RUN=1
    manifest_install_file "$SRC" /etc/x.conf audio 2>/dev/null
    [ ! -e "$AX20_ROOT/etc/x.conf" ]
    [ ! -s "$(ax20_manifest_file)" ]
}

@test "manifest reader survives NUL padding left by a crash" {
    manifest_record /etc/a.conf audio file 1 shared false
    manifest_record /etc/b.conf audio file 2 shared false
    printf '\000\000\000\000' >>"$(ax20_manifest_file)"
    [ "$(manifest_paths | wc -l | tr -d ' ')" = 2 ]
    manifest_has /etc/b.conf
    manifest_record /etc/c.conf audio file 3 shared false
    [ "$(manifest_paths | wc -l | tr -d ' ')" = 3 ]
}

@test "manifest_install_file adopts a byte-identical unrecorded file instead of dying" {
    mkdir -p "$AX20_ROOT/etc"
    cp "$SRC" "$AX20_ROOT/etc/x.conf"
    run manifest_install_file "$SRC" /etc/x.conf audio
    assert_success
    assert_output_contains "adopting /etc/x.conf"
    manifest_has /etc/x.conf
    printf 'different\n' >"$AX20_ROOT/etc/y.conf"
    run manifest_install_file "$SRC" /etc/y.conf audio
    assert_failure
}
