#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# lib/slots.sh: slot detection and the boot-entry exception (plan §4, §5.2 rules 3a/9).
load '../test_helper'
load '../update_helper'

ENTRY=/efi/EFI/steamos/grub.cfg
INITRD=/efi/EFI/steamos/ally-x20-steamos-acpi.img

setup() {
    make_root >/dev/null
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/slots.sh"
    unset AX20_SLOT AX20_BOOT_ENTRY
    fixture_partsets A
    fixture_grub
    fixture_initrd
    cp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "active slot comes from /dev/disk/by-partsets self vs A/B" {
    [ "$(slots_active)" = A ]
    fixture_partsets B
    [ "$(slots_active)" = B ]
    [ "$(slots_inactive)" = A ]
}

@test "AX20_SLOT overrides detection; invalid names are rejected" {
    AX20_SLOT=B
    [ "$(slots_active)" = B ]
    AX20_SLOT=dev
    run slots_active
    assert_failure
}

@test "active slot is unknown without partsets" {
    rm -rf "$AX20_ROOT/dev"
    run slots_active
    assert_failure
}

@test "slots_other flips A and B and refuses anything else" {
    [ "$(slots_other A)" = B ]
    [ "$(slots_other B)" = A ]
    run slots_other dev
    assert_failure
}

@test "entry path: stage-2 grub.cfg on the slot's efi partition" {
    [ "$(slots_entry_path A)" = "$ENTRY" ]
    [ "$(slots_entry_format "$ENTRY")" = grub ]
}

@test "apply appends kernel args, inserts the early initrd first, saves the original" {
    slots_entry_apply A "acpi_override=1 foo=bar" "$INITRD"
    f="$AX20_ROOT$ENTRY"
    grep -q 'linux /boot/vmlinuz-linux-neptune .* amd_iommu=off acpi_override=1 foo=bar$' "$f"
    grep -q 'initrd	${cmdpath}/ally-x20-steamos-acpi.img /boot/amd-ucode.img /boot/initramfs-linux-neptune.img$' "$f"
    b="$AX20_ROOT/var/lib/ally-x20-steamos/backup/A/grub.cfg"
    cmp "$b" "$BATS_TEST_TMPDIR/pristine"
    [ "$(cat "$b.sha256")" = "$(ax20_sha256 "$BATS_TEST_TMPDIR/pristine")" ]
    [ "$(cat "$AX20_ROOT/var/lib/ally-x20-steamos/backup/A/entry-path")" = "$ENTRY" ]
    slots_entry_is_modified "$f"
}

@test "apply is idempotent (twice = same bytes, one change)" {
    slots_entry_apply A "acpi_override=1" "$INITRD"
    first=$(ax20_sha256 "$AX20_ROOT$ENTRY")
    slots_entry_apply A "acpi_override=1" "$INITRD"
    [ "$(ax20_sha256 "$AX20_ROOT$ENTRY")" = "$first" ]
    [ "$(grep -c 'acpi_override=1' "$AX20_ROOT$ENTRY")" = 2 ] # marker line + kernel line
}

@test "changing the args replaces the earlier change instead of stacking" {
    slots_entry_apply A "one=1" "$INITRD"
    slots_entry_apply A "two=2" "$INITRD"
    ! grep -q 'one=1' "$AX20_ROOT$ENTRY"
    grep -q 'amd_iommu=off two=2$' "$AX20_ROOT$ENTRY"
    [ "$(grep -o 'ally-x20-steamos-acpi.img' "$AX20_ROOT$ENTRY" | wc -l | tr -d ' ')" = 2 ]
    slots_entry_restore A
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "apply refuses a missing initrd and leaves the entry untouched" {
    rm -f "$AX20_ROOT$INITRD"
    run slots_entry_apply A "x=1" "$INITRD"
    assert_failure
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "apply refuses an initrd that is not an uncompressed newc cpio" {
    printf '\x28\xb5\x2f\xfdzstd' >"$AX20_ROOT$INITRD"
    run slots_entry_apply A "x=1" "$INITRD"
    assert_failure
    assert_output_contains "newc cpio"
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "apply refuses an initrd outside the slot's efi directory for grub" {
    fixture_initrd /var/lib/ally-x20-steamos/acpi.img
    run slots_entry_apply A "x=1" /var/lib/ally-x20-steamos/acpi.img
    assert_failure
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "apply refuses an entry without a kernel line" {
    printf 'set timeout=0\n' >"$AX20_ROOT$ENTRY"
    cp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/odd"
    run slots_entry_apply A "x=1" ""
    assert_failure
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/odd"
}

@test "args-only change (no initrd) round-trips" {
    slots_entry_apply A "x=1" ""
    grep -q 'amd_iommu=off x=1$' "$AX20_ROOT$ENTRY"
    ! grep -q 'cmdpath' "$AX20_ROOT$ENTRY"
    slots_entry_restore A
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "restore puts the saved original back byte-for-byte" {
    slots_entry_apply A "acpi_override=1" "$INITRD"
    slots_entry_restore A
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
    ! slots_entry_is_modified "$AX20_ROOT$ENTRY"
    # idempotent
    slots_entry_restore A
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "restore without a backup regenerates the original from the template" {
    slots_entry_apply A "acpi_override=1" "$INITRD"
    rm -rf "$AX20_ROOT/var/lib/ally-x20-steamos/backup"
    run slots_entry_restore A
    assert_success
    assert_output_contains "regenerating"
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "restore with a corrupted backup (hash mismatch) regenerates instead" {
    slots_entry_apply A "acpi_override=1" "$INITRD"
    printf 'garbage\n' >"$AX20_ROOT/var/lib/ally-x20-steamos/backup/A/grub.cfg"
    slots_entry_restore A
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "entry without a final newline round-trips byte-for-byte" {
    printf '%s' "$(cat "$AX20_ROOT$ENTRY")" >"$AX20_ROOT$ENTRY"
    cp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/noeol"
    slots_entry_apply A "acpi_override=1" "$INITRD"
    rm -rf "$AX20_ROOT/var/lib/ally-x20-steamos/backup"
    slots_entry_restore A
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/noeol"
}

@test "a stock regeneration of the entry refreshes the backup" {
    slots_entry_apply A "acpi_override=1" "$INITRD"
    # steamos-finalize-install rewrote grub.cfg (our change is gone).
    fixture_grub
    printf '# new stock line\n' >>"$AX20_ROOT$ENTRY"
    cp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/newstock"
    slots_entry_apply A "acpi_override=1" "$INITRD"
    cmp "$AX20_ROOT/var/lib/ally-x20-steamos/backup/A/grub.cfg" "$BATS_TEST_TMPDIR/newstock"
    slots_entry_restore A
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/newstock"
}

@test "dry-run writes nothing" {
    before=$(tree_digest "$AX20_ROOT")
    AX20_DRY_RUN=1
    slots_entry_apply A "acpi_override=1" "$INITRD" 2>/dev/null
    slots_desired_set "acpi_override=1" "$INITRD" 2>/dev/null
    AX20_DRY_RUN=0
    [ "$(tree_digest "$AX20_ROOT")" = "$before" ]
}

@test "BLS entries: options get the args, early initrd goes first" {
    rm -f "$AX20_ROOT$ENTRY"
    fixture_bls /esp/loader/entries/steamos-A.conf
    fixture_initrd /esp/ally-x20-steamos/acpi.img
    cp "$AX20_ROOT/esp/loader/entries/steamos-A.conf" "$BATS_TEST_TMPDIR/bls"
    [ "$(slots_entry_path A)" = /esp/loader/entries/steamos-A.conf ]
    slots_entry_apply A "acpi_override=1" /esp/ally-x20-steamos/acpi.img
    f="$AX20_ROOT/esp/loader/entries/steamos-A.conf"
    [ "$(grep '^initrd' "$f" | head -n1)" = "initrd /ally-x20-steamos/acpi.img" ]
    grep -q '^options root=PARTUUID=1234 quiet splash acpi_override=1$' "$f"
    slots_entry_restore A
    cmp "$f" "$BATS_TEST_TMPDIR/bls"
}

@test "reconcile follows the desired state, and restores once it is cleared" {
    slots_desired_set "acpi_override=1" "$INITRD"
    ! slots_entry_in_sync A
    slots_entry_reconcile A
    slots_entry_in_sync A
    slots_desired_clear
    ! slots_entry_in_sync A
    slots_entry_reconcile A
    slots_entry_in_sync A
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}

@test "reconcile is a no-op where there is no boot entry (not SteamOS)" {
    rm -rf "$AX20_ROOT/efi"
    slots_desired_set "acpi_override=1" "$INITRD"
    run slots_entry_reconcile A
    assert_success
}

@test "boot-entry CLI: set, show, clear" {
    run "$CLI" --root "$AX20_ROOT" boot-entry set --arg acpi_override=1 --initrd "$INITRD"
    assert_success
    run "$CLI" --root "$AX20_ROOT" boot-entry show
    assert_success
    assert_output_contains "in sync"
    assert_output_contains "acpi_override=1"
    run "$CLI" --root "$AX20_ROOT" boot-entry clear
    assert_success
    cmp "$AX20_ROOT$ENTRY" "$BATS_TEST_TMPDIR/pristine"
}
