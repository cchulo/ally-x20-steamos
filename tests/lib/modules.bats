#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'

KV=7.2.7-valve2-2-neptune-72-g31504582a073

setup() {
    make_root >/dev/null
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/modules.sh"
    export AX20_PATCHES_DIR="$BATS_TEST_TMPDIR/patches"
    mkdir -p "$AX20_PATCHES_DIR"
    printf '0001-a.patch\tsound/soc/amd/acp\tsnd-soc-acpi-amd-match.ko\n' >"$AX20_PATCHES_DIR/modules.list"
    printf '0010-h.patch\tdrivers/hid\thid-asus-ally.ko\n0011-h.patch\tdrivers/hid\thid-asus-ally.ko\n' >"$AX20_PATCHES_DIR/modules-hid.list"
    export AX20_OFFLINE=0
}

# make_build <dir> <kver> [module...] : a fake build output directory.
make_build() {
    local d=$1 k=$2 m
    shift 2
    mkdir -p "$d"
    printf 'format=1\nkver=%s\nvermagic=%s SMP\n' "$k" "$k" >"$d/BUILD-INFO"
    [ $# -gt 0 ] || set -- hid-asus-ally snd-soc-acpi-amd-match
    for m in "$@"; do
        printf 'ko %s %s' "$m" "$k" >"$d/$m.ko.zst"
    done
}

# make_artifact <kver> <dest.tar.zst> : release-style tarball + .sha256
make_artifact() {
    local s="$BATS_TEST_TMPDIR/art"
    rm -rf "$s"
    make_build "$s/$1" "$1"
    tar -C "$s" -cf - "$1" | zstd -q -o "$2"
    printf '%s  %s\n' "$(ax20_sha256 "$2")" "$(basename "$2")" >"$2.sha256"
}

@test "modules_list_names reads every modules*.list, de-duplicated" {
    [ "$(modules_list_names | tr '\n' ' ')" = "hid-asus-ally snd-soc-acpi-amd-match " ]
}

@test "modules_dir_for is under the state dir and unprefixed" {
    [ "$(modules_dir_for "$KV")" = "/var/lib/ally-x20-steamos/modules/$KV" ]
}

@test "modules_stage copies atomically and records everything in the manifest" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV"
    run modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    assert_success
    d="$AX20_ROOT/var/lib/ally-x20-steamos/modules/$KV"
    [ -f "$d/hid-asus-ally.ko.zst" ]
    [ -f "$d/snd-soc-acpi-amd-match.ko.zst" ]
    [ -f "$d/BUILD-INFO" ]
    modules_available "$KV"
    manifest_has "/var/lib/ally-x20-steamos/modules/$KV/hid-asus-ally.ko.zst"
    manifest_has "/var/lib/ally-x20-steamos/modules/$KV/BUILD-INFO"
    manifest_has "/var/lib/ally-x20-steamos/modules/$KV"
    [ "$(manifest_entry_get "$(manifest_entry "/var/lib/ally-x20-steamos/modules/$KV/BUILD-INFO")" component)" = modules ]
    manifest_verify "/var/lib/ally-x20-steamos/modules/$KV/hid-asus-ally.ko.zst"
    # no leftovers from the staging dance
    [ -z "$(find "$AX20_ROOT/var/lib/ally-x20-steamos/modules" -maxdepth 1 -name '.*' ! -name . )" ]
}

@test "modules_stage replaces an older build and drops stale manifest entries" {
    make_build "$BATS_TEST_TMPDIR/b1" "$KV" hid-asus-ally snd-soc-acpi-amd-match old-module
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b1"
    manifest_has "/var/lib/ally-x20-steamos/modules/$KV/old-module.ko.zst"
    make_build "$BATS_TEST_TMPDIR/b2" "$KV"
    printf 'new' >"$BATS_TEST_TMPDIR/b2/hid-asus-ally.ko.zst"
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b2"
    [ "$(cat "$AX20_ROOT/var/lib/ally-x20-steamos/modules/$KV/hid-asus-ally.ko.zst")" = new ]
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/modules/$KV/old-module.ko.zst" ]
    ! manifest_has "/var/lib/ally-x20-steamos/modules/$KV/old-module.ko.zst"
    manifest_verify "/var/lib/ally-x20-steamos/modules/$KV/hid-asus-ally.ko.zst"
}

@test "modules_stage refuses incomplete or mismatched builds" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV" hid-asus-ally
    run modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    assert_failure
    assert_output_contains "lacks snd-soc-acpi-amd-match.ko.zst"
    make_build "$BATS_TEST_TMPDIR/c" 7.2.7-valve2-1-neptune-72
    run modules_stage "$KV" "$BATS_TEST_TMPDIR/c"
    assert_failure
    [ ! -d "$AX20_ROOT/var/lib/ally-x20-steamos/modules/$KV" ]
}

@test "a module recorded as superseded in BUILD-INFO counts as available" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV" hid-asus-ally
    printf 'module.snd-soc-acpi-amd-match=superseded\n' >>"$BATS_TEST_TMPDIR/b/BUILD-INFO"
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    modules_available "$KV"
    [ "$(modules_superseded_names "$KV")" = snd-soc-acpi-amd-match ]
    ! modules_all_superseded "$KV"
}

@test "modules_stage in dry-run writes nothing" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV"
    AX20_DRY_RUN=1 run modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    assert_success
    [ ! -d "$AX20_ROOT/var/lib/ally-x20-steamos/modules/$KV" ]
}

@test "resolve: cache hit when already staged, nothing else is tried" {
    make_build "$BATS_TEST_TMPDIR/b" "$KV"
    modules_stage "$KV" "$BATS_TEST_TMPDIR/b"
    _modules_fetch() { echo "fetch called" >&2; return 1; }
    modules_container_build() { echo "build called" >&2; return 1; }
    run modules_resolve "$KV"
    assert_success
    [ "${lines[${#lines[@]} - 1]}" = cache ]
    [[ "$output" != *called* ]]
}

@test "resolve: cached release artifact is verified and staged" {
    a="$AX20_ROOT/var/lib/ally-x20-steamos/cache/artifacts"
    mkdir -p "$a"
    make_artifact "$KV" "$a/modules-$KV.tar.zst"
    run modules_resolve "$KV" --source cache
    assert_success
    [ "${lines[${#lines[@]} - 1]}" = cache ]
    modules_available "$KV"
}

@test "resolve: release download when the cache is empty; bad checksum rejected" {
    srv="$BATS_TEST_TMPDIR/srv"
    mkdir -p "$srv"
    make_artifact "$KV" "$srv/modules-$KV.tar.zst"
    modules_online() { return 0; }
    _modules_fetch() { cp "$srv/${1##*/}" "$2"; }
    modules_container_build() { echo "build called" >&2; return 1; }
    run modules_resolve "$KV"
    assert_success
    [ "${lines[${#lines[@]} - 1]}" = release ]
    modules_available "$KV"
    [ -f "$AX20_ROOT/var/lib/ally-x20-steamos/cache/artifacts/modules-$KV.tar.zst" ]
    # second kernel with a corrupted checksum file falls through to container
    K2=7.2.10-valve1-1-neptune-72-g1b214a39f3cb
    make_artifact "$K2" "$srv/modules-$K2.tar.zst"
    printf '0000  x\n' >"$srv/modules-$K2.tar.zst.sha256"
    run modules_resolve "$K2"
    assert_failure
    assert_output_contains "fails its checksum"
    ! modules_available "$K2"
}

@test "resolve: release tarball with entries outside <kver>/ is rejected" {
    srv="$BATS_TEST_TMPDIR/srv"
    mkdir -p "$srv/x/$KV" "$srv/x/evil"
    make_build "$srv/x/$KV" "$KV"
    printf 'x' >"$srv/x/evil/f"
    tar -C "$srv/x" -cf - "$KV" evil | zstd -q -o "$srv/modules-$KV.tar.zst"
    printf '%s  f\n' "$(ax20_sha256 "$srv/modules-$KV.tar.zst")" >"$srv/modules-$KV.tar.zst.sha256"
    modules_online() { return 0; }
    _modules_fetch() { cp "$srv/${1##*/}" "$2"; }
    run modules_resolve "$KV" --source release
    assert_failure
    assert_output_contains "unexpected entry"
}

@test "resolve: offline skips release and container, failure is reported not fatal" {
    modules_online() { return 1; }
    _modules_fetch() { echo "fetch called" >&2; return 1; }
    run modules_resolve "$KV"
    assert_failure 1
    assert_output_contains "stock modules will be used"
    [[ "$output" != *"fetch called"* ]]
}

@test "resolve: container build is used last and its output staged" {
    modules_online() { return 0; }
    _modules_fetch() { return 1; }
    ax20_have() { [ "$1" = podman ] && return 0; command -v "$1" >/dev/null 2>&1; }
    modules_container_build() {
        printf '%s %s\n' "$1" "$2" >"$BATS_TEST_TMPDIR/build-args"
        make_build "$3/$1" "$1"
    }
    run modules_resolve "$KV" --channel jupiter-rel
    assert_success
    [ "${lines[${#lines[@]} - 1]}" = container ]
    [ "$(cat "$BATS_TEST_TMPDIR/build-args")" = "$KV jupiter-rel" ]
    modules_available "$KV"
}

@test "resolve: no podman means no container attempt" {
    modules_online() { return 0; }
    _modules_fetch() { return 1; }
    ax20_have() { [ "$1" = podman ] && return 1; command -v "$1" >/dev/null 2>&1; }
    run modules_resolve "$KV" --source container
    assert_failure
    assert_output_contains "podman not available"
}

@test "resolve rejects an unknown source" {
    run modules_resolve "$KV" --source floppy
    assert_failure 2
}

@test "lockdown detection reads the selected mode from fixture sysfs" {
    run modules_lockdown_active
    assert_failure
    fixture_file /sys/kernel/security/lockdown "[none] integrity confidentiality"
    run modules_lockdown_active
    assert_failure
    fixture_file /sys/kernel/security/lockdown "none [integrity] confidentiality"
    run modules_lockdown_active
    assert_success
    fixture_file /sys/kernel/security/lockdown "none integrity [confidentiality]"
    run modules_lockdown_active
    assert_success
}

@test "modules_detect_channel honours AX20_CHANNEL and maps branches" {
    AX20_CHANNEL=jupiter-staging run modules_detect_channel
    [ "$output" = jupiter-staging ]
    unset AX20_CHANNEL
    run modules_detect_channel
    [ "$output" = jupiter-main ]
    fixture_file /var/lib/steamos-branch "rel"
    run modules_detect_channel
    [ "$output" = jupiter-rel ]
}
