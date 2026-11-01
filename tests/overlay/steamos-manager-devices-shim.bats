#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# overlay/bin/steamos-manager-devices-shim is POSIX sh; run it with /bin/sh
# against a fixture root. mount/umount are stubs that record their calls and
# keep a fake mountinfo (AX20_MOUNTINFO) in step, so stacking, our-layer
# detection and foreign mounts can be exercised without privileges.
load '../test_helper'

SHIM="$REPO_ROOT/overlay/bin/steamos-manager-devices-shim"
STOCK=/usr/share/steamos-manager/devices
OURS=/etc/ally-x20-steamos/steamos-manager
MERGED=/run/ally-x20-steamos/steamos-manager-devices
STATE=/run/ally-x20-steamos/steamos-manager-devices.state

setup() {
    make_root >/dev/null
    STUBS="$BATS_TEST_TMPDIR/stubs"
    CALLS="$BATS_TEST_TMPDIR/calls"
    AX20_MOUNTINFO="$BATS_TEST_TMPDIR/mountinfo"
    export CALLS AX20_MOUNTINFO
    mkdir -p "$STUBS"
    : >"$CALLS"
    : >"$AX20_MOUNTINFO"
    printf '22 1 0:21 / / ro,relatime shared:1 - btrfs /dev/root ro\n' >>"$AX20_MOUNTINFO"
    cat >"$STUBS/mount" <<'S'
#!/bin/sh
echo "mount $*" >>"$CALLS"
if [ "$1" = --bind ]; then
    src=${2#"$AX20_ROOT"}
    dst=${3#"$AX20_ROOT"}
    echo "99 22 0:42 ${src#/run} $dst rw,relatime shared:9 - tmpfs tmpfs rw" >>"$AX20_MOUNTINFO"
fi
exit 0
S
    cat >"$STUBS/umount" <<'S'
#!/bin/sh
echo "umount $*" >>"$CALLS"
dst=${1#"$AX20_ROOT"}
awk -v mp="$dst" '{ l[NR] = $0; if ($5 == mp) last = NR } END { for (i = 1; i <= NR; i++) if (i != last) print l[i] }' \
    "$AX20_MOUNTINFO" >"$AX20_MOUNTINFO.new" && mv "$AX20_MOUNTINFO.new" "$AX20_MOUNTINFO"
S
    chmod +x "$STUBS"/*
    export PATH="$STUBS:$PATH"
}

stock() {
    fixture_file "$STOCK/rog-ally-series.toml" 'dmi.board_name = "RC73XA"'
    fixture_file "$STOCK/legion-go-s.toml" 'dmi.board_name = "83L3"'
    fixture_file "$STOCK/README" 'not a toml'
}

ours() {
    mkdir -p "$AX20_ROOT$OURS"
    cp "$REPO_ROOT/overlay/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml" "$AX20_ROOT$OURS/"
}

layers() { awk -v mp="$STOCK" '$5 == mp' "$AX20_MOUNTINFO" | wc -l | tr -d ' '; }

@test "start: copies every stock file plus our entry and bind-mounts the copy read-only" {
    stock
    ours
    run "${TEST_SH:-sh}" "$SHIM" start
    assert_success
    [ "$(cd "$AX20_ROOT$MERGED" && ls | sort | tr '\n' ' ')" = "90-ally-x20-steamos-rc74xa.toml README legion-go-s.toml rog-ally-series.toml " ]
    cmp -s "$AX20_ROOT$STOCK/rog-ally-series.toml" "$AX20_ROOT$MERGED/rog-ally-series.toml"
    grep -qx "mount --bind $AX20_ROOT$MERGED $AX20_ROOT$STOCK" "$CALLS"
    grep -qx "mount -o remount,bind,ro $AX20_ROOT$STOCK" "$CALLS"
    [ "$(cat "$AX20_ROOT$STATE")" = mounted ]
    # the stock directory itself is never written
    [ "$(ls "$AX20_ROOT$STOCK" | sort | tr '\n' ' ')" = "README legion-go-s.toml rog-ally-series.toml " ]
    [ "$(layers)" = 1 ]
}

@test "start twice: our previous layer is unmounted first, never stacked" {
    stock
    ours
    "${TEST_SH:-sh}" "$SHIM" start
    run "${TEST_SH:-sh}" "$SHIM" start
    assert_success
    [ "$(grep -c "^umount $AX20_ROOT$STOCK\$" "$CALLS")" = 1 ]
    [ "$(layers)" = 1 ]
}

@test "start again after the entry changed (re-apply): the new entry is what gets mounted" {
    stock
    ours
    "${TEST_SH:-sh}" "$SHIM" start
    printf '# new entry\n' >>"$AX20_ROOT$OURS/90-ally-x20-steamos-rc74xa.toml"
    run "${TEST_SH:-sh}" "$SHIM" start
    assert_success
    cmp -s "$AX20_ROOT$OURS/90-ally-x20-steamos-rc74xa.toml" "$AX20_ROOT$MERGED/90-ally-x20-steamos-rc74xa.toml"
    [ "$(grep -c "^mount --bind " "$CALLS")" = 2 ]
    [ "$(layers)" = 1 ]
}

@test "start: steps aside when a stock file already lists RC74XA" {
    stock
    ours
    fixture_file "$STOCK/rog-xbox-ally-x20.toml" 'dmi.board_name = "RC74XA"'
    run "${TEST_SH:-sh}" "$SHIM" start
    assert_success
    assert_output_contains "already lists RC74XA"
    run grep '^mount' "$CALLS"
    assert_failure
    [ "$(cat "$AX20_ROOT$STATE")" = stock-has-board ]
    [ ! -e "$AX20_ROOT$MERGED" ]
}

@test "start: a stale mount of ours is dropped before the stock check" {
    stock
    ours
    "${TEST_SH:-sh}" "$SHIM" start
    # a SteamOS update now ships the entry (seen once our layer is gone)
    fixture_file "$STOCK/rog-xbox-ally-x20.toml" 'dmi.board_name = "RC74XA"'
    run "${TEST_SH:-sh}" "$SHIM" start
    assert_success
    [ "$(layers)" = 0 ]
    [ "$(cat "$AX20_ROOT$STATE")" = stock-has-board ]
}

@test "start: our own file in the directory is not mistaken for a stock entry" {
    stock
    ours
    cp "$AX20_ROOT$OURS/90-ally-x20-steamos-rc74xa.toml" "$AX20_ROOT$STOCK/"
    run "${TEST_SH:-sh}" "$SHIM" start
    assert_success
    [ "$(cat "$AX20_ROOT$STATE")" = mounted ]
}

@test "start: a mount that is not ours is left alone and nothing is mounted on top" {
    stock
    ours
    printf '50 22 0:30 /someone-else %s rw - overlay overlay rw\n' "$STOCK" >>"$AX20_MOUNTINFO"
    run "${TEST_SH:-sh}" "$SHIM" start
    assert_success
    assert_output_contains "not ours"
    run grep -E '^(u?mount)' "$CALLS"
    assert_failure
    [ "$(cat "$AX20_ROOT$STATE")" = foreign-mount ]
}

@test "start: no steamos-manager directory is not an error" {
    ours
    run "${TEST_SH:-sh}" "$SHIM" start
    assert_success
    [ "$(cat "$AX20_ROOT$STATE")" = no-stock-dir ]
    [ ! -s "$CALLS" ]
}

@test "start: fails without our device entry" {
    stock
    run "${TEST_SH:-sh}" "$SHIM" start
    assert_failure 1
    assert_output_contains "apply --only power"
    [ "$(cat "$AX20_ROOT$STATE")" = missing-config ]
    run grep '^mount' "$CALLS"
    assert_failure
}

@test "stop: unmounts, deletes the copy, status reports it" {
    stock
    ours
    "${TEST_SH:-sh}" "$SHIM" start
    run "${TEST_SH:-sh}" "$SHIM" status
    [ "$output" = mounted ]
    run "${TEST_SH:-sh}" "$SHIM" stop
    assert_success
    [ "$(layers)" = 0 ]
    [ ! -e "$AX20_ROOT$MERGED" ]
    run "${TEST_SH:-sh}" "$SHIM" status
    [ "$output" = stopped ]
}

@test "usage error on an unknown verb" {
    run "${TEST_SH:-sh}" "$SHIM" frobnicate
    assert_failure 2
}

@test "the standalone uninstaller drops our bind mount before the files" {
    u="$REPO_ROOT/uninstall/uninstall.sh"
    grep -q '^release_power_mount() {' "$u"
    # called before the backups and files are processed
    [ "$(grep -n '^    release_power_mount$' "$u" | cut -d: -f1)" -lt "$(grep -n '^    restore_backups$' "$u" | cut -d: -f1)" ]
    # only layers whose source is ours
    grep -q 'tok="/$NAME/"' "$u"
}
