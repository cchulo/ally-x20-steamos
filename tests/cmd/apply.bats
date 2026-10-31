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
