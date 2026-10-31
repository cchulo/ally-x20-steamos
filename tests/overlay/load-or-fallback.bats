#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# overlay/bin/load-or-fallback is POSIX sh; run it with /bin/sh and stub
# uname, modinfo, insmod, modprobe and logger through PATH.
load '../test_helper'

KV=7.2.7-valve2-2-neptune-72-g31504582a073
HELPER="$REPO_ROOT/overlay/bin/load-or-fallback"

setup() {
    make_root >/dev/null
    STUBS="$BATS_TEST_TMPDIR/stubs"
    CALLS="$BATS_TEST_TMPDIR/calls"
    export CALLS STUB_KVER="$KV" STUB_VERMAGIC="$KV" STUB_DEPENDS="" INSMOD_FAIL="" MODINFO_NO_ZSTD=""
    mkdir -p "$STUBS"
    : >"$CALLS"
    cat >"$STUBS/uname" <<'S'
#!/bin/sh
echo "$STUB_KVER"
S
    cat >"$STUBS/modinfo" <<'S'
#!/bin/sh
field=$2 file=$3
case "$file" in *.zst) [ -n "$MODINFO_NO_ZSTD" ] && exit 1 ;; esac
case "$field" in
    vermagic) echo "$STUB_VERMAGIC SMP preempt mod_unload " ;;
    depends) echo "$STUB_DEPENDS" ;;
esac
S
    cat >"$STUBS/insmod" <<'S'
#!/bin/sh
echo "insmod $*" >>"$CALLS"
case "$INSMOD_FAIL" in
    all) exit 1 ;;
    zst) case "$1" in *.zst) exit 1 ;; esac ;;
esac
exit 0
S
    cat >"$STUBS/modprobe" <<'S'
#!/bin/sh
echo "modprobe $*" >>"$CALLS"
exit 0
S
    cat >"$STUBS/logger" <<'S'
#!/bin/sh
echo "logger $*" >>"$CALLS"
S
    chmod +x "$STUBS"/*
    export PATH="$STUBS:$PATH"
    MODDIR="$AX20_ROOT/etc/ally-x20-steamos/modules/$KV"
}

stage_module() {
    mkdir -p "$MODDIR"
    printf 'patched module bytes' | zstd -q -o "$MODDIR/$1.ko.zst"
}

@test "loads the patched module when present and vermagic matches" {
    stage_module hid-asus-ally
    run "${TEST_SH:-sh}" "$HELPER" hid-asus-ally
    assert_success
    grep -q "^insmod $MODDIR/hid-asus-ally.ko.zst\$" "$CALLS"
    ! grep -q '^modprobe' "$CALLS"
    grep -q 'loaded patched hid-asus-ally' "$CALLS"
}

@test "passes module options through to insmod" {
    stage_module hid-asus-ally
    run "${TEST_SH:-sh}" "$HELPER" hid-asus-ally debug=1
    assert_success
    grep -q "^insmod $MODDIR/hid-asus-ally.ko.zst debug=1\$" "$CALLS"
}

@test "falls back to stock when no build exists for the running kernel" {
    run "${TEST_SH:-sh}" "$HELPER" hid-asus-ally
    assert_success
    grep -q '^modprobe --ignore-install hid-asus-ally$' "$CALLS"
    ! grep -q '^insmod' "$CALLS"
}

@test "falls back to stock on a vermagic mismatch" {
    stage_module snd-soc-acpi-amd-match
    export STUB_VERMAGIC=7.2.7-valve2-1-neptune-72
    run "${TEST_SH:-sh}" "$HELPER" snd-soc-acpi-amd-match
    assert_success
    grep -q '^modprobe --ignore-install snd-soc-acpi-amd-match$' "$CALLS"
    ! grep -q '^insmod' "$CALLS"
    grep -q 'vermagic' "$CALLS"
}

@test "falls back to stock when insmod fails, after trying a decompressed copy" {
    stage_module hid-asus-ally
    export INSMOD_FAIL=all
    run "${TEST_SH:-sh}" "$HELPER" hid-asus-ally opt=2
    assert_success
    [ "$(grep -c '^insmod' "$CALLS")" = 2 ]
    grep -q '^modprobe --ignore-install hid-asus-ally opt=2$' "$CALLS"
    # the temporary decompressed copy is cleaned up
    second=$(grep '^insmod' "$CALLS" | sed -n 2p | awk '{ print $2 }')
    [ ! -e "$second" ]
}

@test "insmod without zstd support: retries with a decompressed copy and succeeds" {
    stage_module hid-asus-ally
    export INSMOD_FAIL=zst
    run "${TEST_SH:-sh}" "$HELPER" hid-asus-ally
    assert_success
    [ "$(grep -c '^insmod' "$CALLS")" = 2 ]
    ! grep -q '^modprobe' "$CALLS"
    grep -q 'decompressed' "$CALLS"
}

@test "modinfo without zstd support: vermagic is read from a decompressed copy" {
    stage_module hid-asus-ally
    export MODINFO_NO_ZSTD=1
    run "${TEST_SH:-sh}" "$HELPER" hid-asus-ally
    assert_success
    grep '^insmod' "$CALLS" | grep -vq '\.zst'
    ! grep -q '^modprobe --ignore-install' "$CALLS"
}

@test "dependencies are loaded through modprobe first" {
    stage_module hid-asus-ally
    export STUB_DEPENDS="hid-asus,led-class-multicolor"
    run "${TEST_SH:-sh}" "$HELPER" hid-asus-ally
    assert_success
    [ "$(sed -n 1p "$CALLS")" = "modprobe hid-asus" ]
    [ "$(sed -n 2p "$CALLS")" = "modprobe led-class-multicolor" ]
    grep -q '^insmod' "$CALLS"
}

@test "already loaded module: nothing happens" {
    stage_module hid-asus-ally
    mkdir -p "$AX20_ROOT/sys/module/hid_asus_ally"
    run "${TEST_SH:-sh}" "$HELPER" hid-asus-ally
    assert_success
    ! grep -q -e '^insmod' -e '^modprobe' "$CALLS"
}

@test "no arguments never fails" {
    run "${TEST_SH:-sh}" "$HELPER"
    assert_success
}

@test "uname failure falls back to stock" {
    printf '#!/bin/sh\nexit 1\n' >"$STUBS/uname"
    run "${TEST_SH:-sh}" "$HELPER" hid-asus-ally
    assert_success
    grep -q '^modprobe --ignore-install hid-asus-ally$' "$CALLS"
}
