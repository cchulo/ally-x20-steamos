#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# cmd/apply.sh, cmd/boot.sh, cmd/notify.sh and components/update.sh.
load '../test_helper'
load '../update_helper'

demo_components() {
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR" "$BATS_TEST_TMPDIR/overlay/demo"
    printf 'demo\n' >"$BATS_TEST_TMPDIR/overlay/demo/a.conf"
    printf 'demo2\n' >"$BATS_TEST_TMPDIR/overlay/demo/b.conf"
    cat >"$AX20_COMPONENTS_DIR/alpha.sh" <<'C'
COMPONENT_DESCRIPTION="alpha"
alpha_files() { printf 'demo/a.conf\t/etc/demo.d/ally-x20-steamos-a.conf\t0644\n'; }
alpha_probe() { return 1; }
alpha_apply() { [ "$AX20_DRY_RUN" = 1 ] || printf 'x\n' >>"$(ax20_path /var/lib/ally-x20-steamos/alpha-runs)"; }
C
    cat >"$AX20_COMPONENTS_DIR/beta.sh" <<'C'
COMPONENT_DESCRIPTION="beta"
beta_files() { printf 'demo/b.conf\t/etc/demo.d/ally-x20-steamos-b.conf\t0644\n'; }
beta_probe() { return 1; }
beta_apply() { [ "$AX20_DRY_RUN" = 1 ] || printf 'x\n' >>"$(ax20_path /var/lib/ally-x20-steamos/beta-runs)"; }
C
    cat >"$AX20_COMPONENTS_DIR/native.sh" <<'C'
COMPONENT_DESCRIPTION="stock already has it"
native_files() { printf 'demo/a.conf\t/etc/demo.d/ally-x20-steamos-native.conf\t0644\n'; }
native_probe() { return 0; }
C
    fake_src self-update rebuild
    rm -f "$BATS_TEST_TMPDIR/src/overlay"
    ln -s "$BATS_TEST_TMPDIR/overlay" "$BATS_TEST_TMPDIR/src/overlay"
}

broken_component() {
    cat >"$AX20_COMPONENTS_DIR/broken.sh" <<'C'
COMPONENT_DESCRIPTION="dies"
broken_files() { :; }
broken_probe() { return 1; }
broken_apply() { die "boom"; }
C
}

setup() {
    make_root >/dev/null
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/common.sh"
    unset AX20_SLOT AX20_BOOT_ENTRY AX20_KVER
    export AX20_KVER=7.2.7-valve2-test
}

@test "apply installs every component and writes a valid status.json" {
    demo_components
    run "$FAKE_CLI" --root "$AX20_ROOT" apply
    assert_success
    [ -f "$AX20_ROOT/etc/demo.d/ally-x20-steamos-a.conf" ]
    [ -f "$AX20_ROOT/etc/demo.d/ally-x20-steamos-b.conf" ]
    s="$AX20_ROOT/var/lib/ally-x20-steamos/state/status.json"
    jq -e . "$s" >/dev/null
    [ "$(jq -r '.components[] | select(.name == "alpha") | .status' "$s")" = active ]
    [ "$(jq -r '.components[] | select(.name == "native") | .status' "$s")" = superseded ]
    [ "$(jq -r .kver "$s")" = 7.2.7-valve2-test ]
    [ "$(jq -r .applied "$s")" = "alpha beta" ]
}

@test "a component that stock SteamOS provides is not installed" {
    demo_components
    run "$FAKE_CLI" --root "$AX20_ROOT" apply
    assert_output_contains "native: stock SteamOS provides this"
    [ ! -e "$AX20_ROOT/etc/demo.d/ally-x20-steamos-native.conf" ]
}

@test "apply is idempotent (twice = same files, same manifest)" {
    demo_components
    "$FAKE_CLI" --root "$AX20_ROOT" apply 2>/dev/null
    m1=$(jq -r .path "$AX20_ROOT/var/lib/ally-x20-steamos/manifest" | sort)
    s1=$(ax20_sha256 "$AX20_ROOT/etc/demo.d/ally-x20-steamos-a.conf")
    "$FAKE_CLI" --root "$AX20_ROOT" apply 2>/dev/null
    [ "$(jq -r .path "$AX20_ROOT/var/lib/ally-x20-steamos/manifest" | sort)" = "$m1" ]
    [ "$(ax20_sha256 "$AX20_ROOT/etc/demo.d/ally-x20-steamos-a.conf")" = "$s1" ]
}

@test "--only applies a single component; unknown names exit 2" {
    demo_components
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only beta
    assert_success
    [ ! -e "$AX20_ROOT/etc/demo.d/ally-x20-steamos-a.conf" ]
    [ -f "$AX20_ROOT/etc/demo.d/ally-x20-steamos-b.conf" ]
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only nope
    assert_failure 2
}

@test "a failing component does not stop the others; exit 1 and recorded" {
    demo_components
    broken_component
    run "$FAKE_CLI" --root "$AX20_ROOT" apply
    assert_failure 1
    [ -f "$AX20_ROOT/etc/demo.d/ally-x20-steamos-b.conf" ]
    [ "$(jq -r .failed "$AX20_ROOT/var/lib/ally-x20-steamos/state/status.json")" = broken ]
}

@test "--verify-only reports drift, exits 1, and writes nothing" {
    demo_components
    "$FAKE_CLI" --root "$AX20_ROOT" apply 2>/dev/null
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --verify-only
    assert_success
    rm "$AX20_ROOT/etc/demo.d/ally-x20-steamos-a.conf"
    printf 'tampered\n' >"$AX20_ROOT/etc/demo.d/ally-x20-steamos-b.conf"
    before=$(tree_digest "$AX20_ROOT")
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --verify-only
    assert_failure 1
    assert_output_contains "alpha: missing: /etc/demo.d/ally-x20-steamos-a.conf"
    assert_output_contains "beta: modified: /etc/demo.d/ally-x20-steamos-b.conf"
    [ "$(tree_digest "$AX20_ROOT")" = "$before" ]
}

@test "--missing-only re-applies only the drifted components" {
    demo_components
    "$FAKE_CLI" --root "$AX20_ROOT" apply 2>/dev/null
    rm "$AX20_ROOT/etc/demo.d/ally-x20-steamos-a.conf"
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --missing-only
    assert_success
    [ -f "$AX20_ROOT/etc/demo.d/ally-x20-steamos-a.conf" ]
    [ "$(wc -l <"$AX20_ROOT/var/lib/ally-x20-steamos/alpha-runs" | tr -d ' ')" = 2 ]
    [ "$(wc -l <"$AX20_ROOT/var/lib/ally-x20-steamos/beta-runs" | tr -d ' ')" = 1 ]
}

@test "--slot <mount> applies into that root and reads its kernel version" {
    demo_components
    unset AX20_KVER
    slot="$BATS_TEST_TMPDIR/slotB"
    mkdir -p "$slot/usr/lib/modules/7.3.0-valve1-neptune" "$slot/etc" "$slot/var/lib/ally-x20-steamos"
    run env AX20_SLOT=B "$FAKE_CLI" --root "$AX20_ROOT" apply --slot "$slot"
    assert_success
    [ -f "$slot/etc/demo.d/ally-x20-steamos-a.conf" ]
    [ ! -e "$AX20_ROOT/etc/demo.d/ally-x20-steamos-a.conf" ]
    [ "$(jq -r .kver "$slot/var/lib/ally-x20-steamos/state/status.json")" = 7.3.0-valve1-neptune ]
    [ "$(jq -r .slot "$slot/var/lib/ally-x20-steamos/state/status.json")" = B ]
}

@test "--slot rejects a missing mount point" {
    demo_components
    run "$FAKE_CLI" apply --slot "$BATS_TEST_TMPDIR/nope"
    assert_failure
}

@test "dry-run apply writes nothing" {
    demo_components
    before=$(tree_digest "$AX20_ROOT")
    run "$FAKE_CLI" --root "$AX20_ROOT" --dry-run apply
    assert_success
    [ "$(tree_digest "$AX20_ROOT")" = "$before" ]
}

# ------------------------------------------------------ update component --

update_root() {
    fixture_partsets A
    fixture_grub
    fixture_initrd
    fixture_rauc_conf 1
    cp "$AX20_ROOT/etc/rauc/system.conf" "$BATS_TEST_TMPDIR/rauc.pristine"
    cp "$AX20_ROOT/efi/EFI/steamos/grub.cfg" "$BATS_TEST_TMPDIR/grub.pristine"
    fake_src self-update rebuild
}

@test "update component: units, enable links, handlers, RAUC block, boot entry" {
    update_root
    "$FAKE_CLI" --root "$AX20_ROOT" boot-entry set --arg acpi_override=1 \
        --initrd /efi/EFI/steamos/ally-x20-steamos-acpi.img 2>/dev/null
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only update
    assert_success
    r=$AX20_ROOT
    [ -f "$r/etc/systemd/system/ally-x20-steamos.service" ]
    [ -f "$r/etc/systemd/user/ally-x20-steamos-notify.service" ]
    [ "$(readlink "$r/etc/systemd/system/multi-user.target.wants/ally-x20-steamos.service")" = ../ally-x20-steamos.service ]
    [ "$(readlink "$r/etc/systemd/user/default.target.wants/ally-x20-steamos-notify.service")" = ../ally-x20-steamos-notify.service ]
    [ -x "$r/var/lib/ally-x20-steamos/libexec/rauc-pre-install.hook" ]
    [ -x "$r/var/lib/ally-x20-steamos/libexec/rauc-post-install.hook" ]
    grep -qx 'post-install=/var/lib/ally-x20-steamos/libexec/rauc-post-install.hook' "$r/etc/rauc/system.conf"
    grep -q 'acpi_override=1$' "$r/efi/EFI/steamos/grub.cfg"
    [ "$(jq -r '.components[] | select(.name == "update") | .status' "$r/var/lib/ally-x20-steamos/state/status.json")" = active ]
    # twice = no change
    s1=$(ax20_sha256 "$r/etc/rauc/system.conf")
    g1=$(ax20_sha256 "$r/efi/EFI/steamos/grub.cfg")
    "$FAKE_CLI" --root "$AX20_ROOT" apply --only update 2>/dev/null
    [ "$(ax20_sha256 "$r/etc/rauc/system.conf")" = "$s1" ]
    [ "$(ax20_sha256 "$r/efi/EFI/steamos/grub.cfg")" = "$g1" ]
}

@test "update component: a SteamOS update drops the RAUC block; boot re-applies and notifies" {
    update_root
    "$FAKE_CLI" --root "$AX20_ROOT" apply --only update 2>/dev/null
    # New slot boots with a stock system.conf (rsync excludes etc/upper/rauc).
    cp "$BATS_TEST_TMPDIR/rauc.pristine" "$AX20_ROOT/etc/rauc/system.conf"
    printf 'from=A\nto=B\nkver=x\n' >"$AX20_ROOT/var/lib/ally-x20-steamos/state/pending-reboot-check"
    run "$FAKE_CLI" --root "$AX20_ROOT" boot
    assert_success
    grep -q '^# >>> ally-x20-steamos' "$AX20_ROOT/etc/rauc/system.conf"
    n="$AX20_ROOT/var/lib/ally-x20-steamos/state/notify"
    grep -q '^reapplied=.*update' "$n"
    grep -qx 'update=A -> B' "$n"
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/state/pending-reboot-check" ]
    # Second boot: nothing to say any more.
    run "$FAKE_CLI" --root "$AX20_ROOT" boot
    assert_success
    [ ! -e "$n" ]
}

@test "update component: remove restores system.conf and the boot entry byte-for-byte" {
    update_root
    "$FAKE_CLI" --root "$AX20_ROOT" boot-entry set --arg acpi_override=1 \
        --initrd /efi/EFI/steamos/ally-x20-steamos-acpi.img 2>/dev/null
    "$FAKE_CLI" --root "$AX20_ROOT" apply --only update 2>/dev/null
    source_libs
    component_remove_hook update
    cmp "$AX20_ROOT/etc/rauc/system.conf" "$BATS_TEST_TMPDIR/rauc.pristine"
    cmp "$AX20_ROOT/efi/EFI/steamos/grub.cfg" "$BATS_TEST_TMPDIR/grub.pristine"
}

@test "update component: probe never reports superseded" {
    source_libs
    run component_probe update
    assert_failure 1
}

# ------------------------------------------- factory-reset fail-safe --

CLEANUP_REL=/efi/EFI/steamos/ally-x20-steamos-cleanup.sh
RESET_UNIT=ally-x20-steamos-reset-cleanup.service

@test "update component: installs the EFI clean-up script and the reset-cleanup unit, recorded in the manifest" {
    update_root
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only update
    assert_success
    r=$AX20_ROOT
    cmp "$r$CLEANUP_REL" "$REPO_ROOT/uninstall/efi-cleanup.sh"
    cmp "$r/etc/systemd/system/$RESET_UNIT" "$REPO_ROOT/overlay/systemd/$RESET_UNIT"
    [ "$(readlink "$r/etc/systemd/system/multi-user.target.wants/$RESET_UNIT")" = "../$RESET_UNIT" ]
    source_libs
    for p in "$CLEANUP_REL" "/etc/systemd/system/$RESET_UNIT" "/etc/systemd/system/multi-user.target.wants/$RESET_UNIT"; do
        [ "$(manifest_entry_get "$(manifest_entry "$p")" component)" = update ]
        manifest_verify "$p"
    done
    [ "$(manifest_entry_get "$(manifest_entry "$CLEANUP_REL")" slot)" = esp ]
    # Idempotent, and the component stays active.
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only update
    assert_success
    [ "$(jq -r '.components[] | select(.name == "update") | .status' "$r/var/lib/ally-x20-steamos/state/status.json")" = active ]
}

@test "update component: an existing install gets the new files on apply; a missing copy is re-applied at boot" {
    update_root
    "$FAKE_CLI" --root "$AX20_ROOT" apply --only update 2>/dev/null
    source_libs
    # Simulate an install from before this change.
    rm -f "$AX20_ROOT$CLEANUP_REL" "$AX20_ROOT/etc/systemd/system/$RESET_UNIT" \
        "$AX20_ROOT/etc/systemd/system/multi-user.target.wants/$RESET_UNIT"
    manifest_forget "$CLEANUP_REL"
    manifest_forget "/etc/systemd/system/$RESET_UNIT"
    manifest_forget "/etc/systemd/system/multi-user.target.wants/$RESET_UNIT"
    run "$FAKE_CLI" --root "$AX20_ROOT" apply
    assert_success
    [ -f "$AX20_ROOT$CLEANUP_REL" ]
    [ -L "$AX20_ROOT/etc/systemd/system/multi-user.target.wants/$RESET_UNIT" ]
    # Lost from the efi partition: the boot service puts it back.
    rm -f "$AX20_ROOT$CLEANUP_REL"
    run "$FAKE_CLI" --root "$AX20_ROOT" boot
    assert_success
    cmp "$AX20_ROOT$CLEANUP_REL" "$REPO_ROOT/uninstall/efi-cleanup.sh"
}

@test "update component: the clean-up script goes only where the grub directory exists" {
    fixture_partsets A
    fixture_rauc_conf 1
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only update
    assert_success
    [ ! -e "$AX20_ROOT/efi" ]
    [ -f "$AX20_ROOT/etc/systemd/system/$RESET_UNIT" ]
}

@test "update component: apply --slot puts the clean-up script on that slot's efi partition" {
    update_root
    slot="$BATS_TEST_TMPDIR/slotB"
    mkdir -p "$slot/var/lib/ally-x20-steamos" "$slot/etc" "$slot/efi/EFI/steamos"
    cp "$AX20_ROOT/efi/EFI/steamos/grub.cfg" "$slot/efi/EFI/steamos/grub.cfg"
    cp -R "$AX20_ROOT/etc/rauc" "$slot/etc/"
    AX20_SLOT=B run "$FAKE_CLI" apply --slot "$slot" --only update
    assert_success
    cmp "$slot$CLEANUP_REL" "$REPO_ROOT/uninstall/efi-cleanup.sh"
    grep -q "\"path\":\"$CLEANUP_REL\"" "$slot/var/lib/ally-x20-steamos/manifest"
    [ ! -e "$AX20_ROOT$CLEANUP_REL" ]
}

@test "update component: a leftover copy from an earlier install is replaced, a foreign file is not" {
    update_root
    printf '#!/bin/sh\n# ally-x20-steamos EFI clean-up: an older version\n' >"$AX20_ROOT$CLEANUP_REL"
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only update
    assert_success
    assert_output_contains "replacing a leftover"
    cmp "$AX20_ROOT$CLEANUP_REL" "$REPO_ROOT/uninstall/efi-cleanup.sh"
    # Someone else's file under our name without our header: refused.
    source_libs
    manifest_forget "$CLEANUP_REL"
    printf 'not ours\n' >"$AX20_ROOT$CLEANUP_REL"
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only update
    assert_failure
    [ "$(cat "$AX20_ROOT$CLEANUP_REL")" = "not ours" ]
}

@test "update component: uninstall removes the clean-up script, the unit and its link" {
    update_root
    "$FAKE_CLI" --root "$AX20_ROOT" boot-entry set --arg acpi_override=1 \
        --initrd /efi/EFI/steamos/ally-x20-steamos-acpi.img 2>/dev/null
    "$FAKE_CLI" --root "$AX20_ROOT" apply --only update 2>/dev/null
    [ -f "$AX20_ROOT$CLEANUP_REL" ]
    run "$FAKE_CLI" --root "$AX20_ROOT" uninstall
    assert_success
    [[ "$output" != *REFUSED* ]]
    [ ! -e "$AX20_ROOT$CLEANUP_REL" ]
    [ ! -e "$AX20_ROOT/etc/systemd/system/$RESET_UNIT" ]
    [ ! -L "$AX20_ROOT/etc/systemd/system/multi-user.target.wants/$RESET_UNIT" ]
    cmp "$AX20_ROOT/efi/EFI/steamos/grub.cfg" "$BATS_TEST_TMPDIR/grub.pristine"
    # Stock EFI files stay.
    [ -d "$AX20_ROOT/efi/EFI/steamos" ]
}

@test "reset-cleanup unit: oneshot armed at boot, stop runs the clean-up only for a pending reset" {
    u="$REPO_ROOT/overlay/systemd/$RESET_UNIT"
    head -n 1 "$u" | grep -q '^# SPDX-License-Identifier: GPL-2.0-only$'
    grep -qx 'Type=oneshot' "$u"
    grep -qx 'RemainAfterExit=yes' "$u"
    grep -qx 'ExecStart=/bin/true' "$u"
    grep -qx 'ExecStop=-/bin/sh /var/lib/ally-x20-steamos/src/uninstall/efi-cleanup.sh --if-reset-pending --all-slots --keep' "$u"
    grep -qx 'TimeoutStopSec=20s' "$u"
    grep -qx 'After=local-fs.target efi.automount esp.automount' "$u"
    grep -qx 'ConditionPathExists=/var/lib/ally-x20-steamos/src/uninstall/efi-cleanup.sh' "$u"
    grep -qx 'WantedBy=multi-user.target' "$u"
    # Never pin the automounted partitions (an idle expiry would stop us early).
    ! grep -q '^RequiresMountsFor=' "$u"
    ! grep -q '^Requires=' "$u"
    # The paths it runs exist in the checkout layout the boot service uses.
    [ -f "$REPO_ROOT/uninstall/efi-cleanup.sh" ]
    grep -q '^ExecStart=/var/lib/ally-x20-steamos/src/ally-x20-steamos.sh boot$' \
        "$REPO_ROOT/overlay/systemd/ally-x20-steamos.service"
}

@test "notify: prints a summary, and shows each distinct summary once" {
    fake_src
    mkdir -p "$AX20_ROOT/var/lib/ally-x20-steamos/state"
    printf 'update=A -> B\nreapplied=update\nfailed=\npending=kernel modules for 7.3\nsuperseded=hdr\nblocked=\n' \
        >"$AX20_ROOT/var/lib/ally-x20-steamos/state/notify"
    run "$FAKE_CLI" --root "$AX20_ROOT" notify --print
    assert_success
    assert_output_contains "SteamOS was updated (slot A -> B)"
    assert_output_contains "Re-applied: update."
    assert_output_contains "Building kernel modules for 7.3"
    assert_output_contains "uninstall --superseded"
    # Without notify-send on PATH it prints, then remembers.
    export HOME=/home/deck XDG_STATE_HOME=
    unset XDG_STATE_HOME
    run env PATH="/usr/bin:/bin" "$FAKE_CLI" --root "$AX20_ROOT" notify
    assert_success
    assert_output_contains "Re-applied"
    [ -f "$AX20_ROOT/home/deck/.local/state/ally-x20-steamos/notified" ]
    run env PATH="/usr/bin:/bin" "$FAKE_CLI" --root "$AX20_ROOT" notify
    assert_success
    [ -z "$output" ]
}
