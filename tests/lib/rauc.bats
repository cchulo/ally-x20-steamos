#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# lib/rauc.sh and the RAUC handlers (plan §4.6, §5.2 rule 3b).
load '../test_helper'
load '../update_helper'

CONF=/etc/rauc/system.conf
PRE=/var/lib/ally-x20-steamos/libexec/rauc-pre-install.hook
POST=/var/lib/ally-x20-steamos/libexec/rauc-post-install.hook

setup() {
    make_root >/dev/null
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/rauc.sh"
    fixture_rauc_conf 1
    cp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/pristine"
}

@test "register appends one delimited block and saves the original with its digest" {
    rauc_register "$PRE" "$POST"
    f="$AX20_ROOT$CONF"
    [ "$(grep -c '^# >>> ally-x20-steamos' "$f")" = 1 ]
    [ "$(grep -c '^# <<< ally-x20-steamos' "$f")" = 1 ]
    [ "$(tail -n1 "$f")" = "# <<< ally-x20-steamos" ]
    grep -qx "pre-install=$PRE" "$f"
    grep -qx "post-install=$POST" "$f"
    # stock lines untouched, in place
    [ "$(head -n "$(wc -l <"$BATS_TEST_TMPDIR/pristine")" "$f" | ax20_sha256 /dev/stdin)" = "$(ax20_sha256 "$BATS_TEST_TMPDIR/pristine")" ]
    b="$AX20_ROOT/var/lib/ally-x20-steamos/backup/rauc/system.conf"
    cmp "$b" "$BATS_TEST_TMPDIR/pristine"
    [ "$(cat "$b.sha256")" = "$(ax20_sha256 "$b")" ]
    rauc_registered "$PRE" "$POST"
}

@test "existing stock handlers are chained, not replaced" {
    rauc_register "$PRE" "$POST"
    [ "$(rauc_chain_get post-install)" = /usr/lib/rauc/post-install.sh ]
    [ -z "$(rauc_chain_get pre-install)" ]
    # The stock value is still what the file says outside our block.
    [ "$(rauc_handler_value "$AX20_ROOT$CONF" post-install)" = /usr/lib/rauc/post-install.sh ]
}

@test "relative handler paths are resolved against /etc/rauc" {
    fixture_rauc_conf 1
    sed -i.bak 's#^post-install=.*#post-install=hooks/post.sh#' "$AX20_ROOT$CONF"
    rm -f "$AX20_ROOT$CONF.bak"
    rauc_register "$PRE" "$POST"
    [ "$(rauc_chain_get post-install)" = /etc/rauc/hooks/post.sh ]
}

@test "without a stock [handlers] section nothing is chained" {
    fixture_rauc_conf 0
    cp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/nohandlers"
    rauc_register "$PRE" "$POST"
    [ -z "$(rauc_chain_get post-install)" ]
    [ -z "$(rauc_chain_get pre-install)" ]
    rauc_unregister
    cmp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/nohandlers"
}

@test "register is idempotent (run twice = same bytes)" {
    rauc_register "$PRE" "$POST"
    first=$(ax20_sha256 "$AX20_ROOT$CONF")
    rauc_register "$PRE" "$POST"
    [ "$(ax20_sha256 "$AX20_ROOT$CONF")" = "$first" ]
    [ "$(grep -c '^# >>> ally-x20-steamos' "$AX20_ROOT$CONF")" = 1 ]
}

@test "never chains to itself when our handler is the stock value" {
    sed -i.bak "s#^post-install=.*#post-install=$POST#" "$AX20_ROOT$CONF"
    rm -f "$AX20_ROOT$CONF.bak"
    rauc_register "$PRE" "$POST"
    [ -z "$(rauc_chain_get post-install)" ]
}

@test "unregister restores the original byte-for-byte and drops the chain file" {
    rauc_register "$PRE" "$POST"
    rauc_unregister
    cmp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/pristine"
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/state/rauc-chain" ]
    ! rauc_block_present
    # idempotent
    rauc_unregister
    cmp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/pristine"
}

@test "original without a final newline round-trips byte-for-byte" {
    printf '%s' "$(cat "$AX20_ROOT$CONF")" >"$AX20_ROOT$CONF"
    cp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/noeol"
    rauc_register "$PRE" "$POST"
    rm -rf "$AX20_ROOT/var/lib/ally-x20-steamos/backup"
    rauc_unregister
    cmp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/noeol"
}

@test "corrupted backup: unregister strips only our block, still byte-identical" {
    rauc_register "$PRE" "$POST"
    printf 'tampered\n' >"$AX20_ROOT/var/lib/ally-x20-steamos/backup/rauc/system.conf"
    run rauc_unregister
    assert_success
    assert_output_contains "no valid backup"
    cmp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/pristine"
}

@test "stock file changed under our block: backup refreshed on register, new stock restored" {
    rauc_register "$PRE" "$POST"
    # A SteamOS update shipped a new stock system.conf; apply re-registers.
    fixture_rauc_conf 1
    printf '[slot.rootfs.1]\ndevice=/dev/disk/by-partsets/B/rootfs\n' >>"$AX20_ROOT$CONF"
    cp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/newstock"
    rauc_register "$PRE" "$POST"
    cmp "$AX20_ROOT/var/lib/ally-x20-steamos/backup/rauc/system.conf" "$BATS_TEST_TMPDIR/newstock"
    rauc_unregister
    cmp "$AX20_ROOT$CONF" "$BATS_TEST_TMPDIR/newstock"
}

@test "missing system.conf (not SteamOS): register skips with a warning" {
    rm -f "$AX20_ROOT$CONF"
    run rauc_register "$PRE" "$POST"
    assert_success
    assert_output_contains "not found"
    [ ! -e "$AX20_ROOT$CONF" ]
}

@test "dry-run register writes nothing" {
    before=$(tree_digest "$AX20_ROOT")
    AX20_DRY_RUN=1
    rauc_register "$PRE" "$POST" 2>/dev/null
    AX20_DRY_RUN=0
    [ "$(tree_digest "$AX20_ROOT")" = "$before" ]
}

@test "incoming kernel version: override, bundle manifest hint, unknown" {
    AX20_INCOMING_KVER=7.3.0-valve1 run rauc_incoming_kver
    assert_success
    [ "$output" = 7.3.0-valve1 ]
    mkdir -p "$BATS_TEST_TMPDIR/bundle"
    printf '[update]\ncompatible=steamos-amd64\n' >"$BATS_TEST_TMPDIR/bundle/manifest.raucm"
    RAUC_BUNDLE_MOUNT_POINT="$BATS_TEST_TMPDIR/bundle" run rauc_incoming_kver
    assert_failure
    printf 'kernel-version=7.3.1-valve1\n' >>"$BATS_TEST_TMPDIR/bundle/manifest.raucm"
    RAUC_BUNDLE_MOUNT_POINT="$BATS_TEST_TMPDIR/bundle" run rauc_incoming_kver
    [ "$output" = 7.3.1-valve1 ]
}

# ---------------------------------------------------------------- handlers --

hook_env() {
    fake_src self-update rebuild
    export AX20_SRC="$BATS_TEST_TMPDIR/src"
    export AX20_HANDLER_SELF_UPDATED=1
    STOCK_LOG="$BATS_TEST_TMPDIR/stock.log"
    export STOCK_LOG
    mkdir -p "$AX20_ROOT/usr/lib/rauc"
    printf '#!/bin/sh\necho "stock $0 $*" >>"$STOCK_LOG"\nexit ${STOCK_RC:-0}\n' >"$AX20_ROOT/usr/lib/rauc/post-install.sh"
    chmod +x "$AX20_ROOT/usr/lib/rauc/post-install.sh"
    rauc_register "$PRE" "$POST"
}

@test "pre-install hook: blocks under policy block when modules are missing" {
    hook_env
    AX20_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_failure
    assert_output_contains "blocking this SteamOS update"
    grep -q '^kver=7.9.0-test$' "$AX20_ROOT/var/lib/ally-x20-steamos/state/update-blocked"
}

@test "pre-install hook: degrade --once lets exactly one update through" {
    hook_env
    "$FAKE_CLI" --root "$AX20_ROOT" update-policy degrade --once
    AX20_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    grep -q '^kver=7.9.0-test$' "$AX20_ROOT/var/lib/ally-x20-steamos/state/pending-rebuild"
    AX20_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_failure
}

@test "pre-install hook: passes when modules exist or the kernel is unknown" {
    hook_env
    mkdir -p "$AX20_ROOT/etc/ally-x20-steamos/modules/7.9.0-test"
    AX20_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    assert_output_contains "cannot tell the incoming kernel"
}

@test "pre-install hook: a rebuild command, when present, produces the modules" {
    hook_env
    cat >"$AX20_SRC/cmd/rebuild.sh" <<'C'
# summary: fake
cmd_rebuild() { mkdir -p "$(ax20_path "$AX20_MODULES_REL")/$2"; }
C
    AX20_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    [ -d "$AX20_ROOT/etc/ally-x20-steamos/modules/7.9.0-test" ]
}

@test "pre-install hook: without a checkout it never blocks" {
    hook_env
    AX20_SRC="$BATS_TEST_TMPDIR/nowhere" AX20_INCOMING_KVER=7.9.0-test run "$REPO_ROOT/overlay/rauc/pre-install.hook"
    assert_success
    assert_output_contains "checkout not found"
}

@test "post-install hook: runs the stock handler first, then re-applies to the new slot" {
    hook_env
    slot="$BATS_TEST_TMPDIR/slotB"
    mkdir -p "$slot/usr/lib/modules/7.9.0-test" "$slot/etc" "$slot/var/lib/ally-x20-steamos"
    mkdir -p "$AX20_ROOT/etc/ally-x20-steamos/modules/7.9.0-test"
    printf 'ko\n' >"$AX20_ROOT/etc/ally-x20-steamos/modules/7.9.0-test/x.ko"
    # Fake components dir with nothing in it keeps this test about the flow.
    mkdir -p "$BATS_TEST_TMPDIR/nocomponents"
    AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/nocomponents" AX20_SLOT=A \
        run "$REPO_ROOT/overlay/rauc/post-install.hook"
    # No partsets in the fixture, so mounting the new slot fails: the hook
    # still succeeds (never fails an update), after running the stock handler.
    assert_success
    assert_output_contains "will retry on first boot"
    grep -q 'stock' "$STOCK_LOG"
    # Now drive our part directly with a prepared slot root.
    AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/nocomponents" AX20_SLOT=A \
        run "$FAKE_CLI" --root "$AX20_ROOT" rauc-handler post-install --slot-root "$slot"
    assert_success
    [ -f "$slot/etc/ally-x20-steamos/modules/7.9.0-test/x.ko" ]
    grep -q '^to=B$' "$slot/var/lib/ally-x20-steamos/state/pending-reboot-check"
    grep -q '^kver=7.9.0-test$' "$slot/var/lib/ally-x20-steamos/state/pending-reboot-check"
    [ -f "$slot/var/lib/ally-x20-steamos/state/status.json" ]
}

@test "post-install hook: a failing stock handler is propagated and we stay out" {
    hook_env
    STOCK_RC=3 run "$REPO_ROOT/overlay/rauc/post-install.hook"
    assert_failure 3
    assert_output_contains "not touching the new slot"
}
