#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# Unit tests for the pure parts of build/build-modules.sh. Network, git
# clones and make are never run: bm_fetch is stubbed to read fixture files.
load '../test_helper'

TAB="$(printf '\t')"

setup() {
    # shellcheck disable=SC1091
    . "$REPO_ROOT/build/build-modules.sh"
    WORK="$BATS_TEST_TMPDIR/work"
    CACHE_DIR="$BATS_TEST_TMPDIR/cache"
    PATCHES_DIR="$BATS_TEST_TMPDIR/patches"
    MIRROR="$BATS_TEST_TMPDIR/mirror"
    mkdir -p "$WORK" "$CACHE_DIR" "$PATCHES_DIR" "$MIRROR"
    KVER=7.2.7-valve2-2-neptune-72-g31504582a073
    CHANNEL=jupiter-main
    BM_ALL_CHANNELS="jupiter-main jupiter-rel"
    KERNEL_SRC_URL="" VMLINUZ="" KERNEL_CONFIG="" JOBS=1
    bm_parse_kver "$KVER"
    # bm_fetch <url> <dest> : serve <mirror>/<path after the base URL>.
    bm_fetch() {
        local rel=${1#"$BM_MIRROR_BASE"/}
        [ -f "$MIRROR/$rel" ] || return 22
        cp "$MIRROR/$rel" "$2"
    }
}

write_lists() {
    printf '0001-asoc.patch\tsound/soc/amd/acp\tsnd-soc-acpi-amd-match.ko\n# comment\n\n0002-acp.patch\tsound/soc/amd/\tsnd-acp-config\n' \
        >"$PATCHES_DIR/modules.list"
    printf '0010-hid.patch\tdrivers/hid\thid-asus-ally.ko\n0011-hid.patch\t./drivers/hid\thid-asus-ally\n' \
        >"$PATCHES_DIR/modules-hid.list"
}

# make_desc <dir> <name> <version> <filename> <sha>
make_desc() {
    mkdir -p "$1/$2-$3"
    printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%BASE%%\nlinux-neptune-72\n\n%%VERSION%%\n%s\n\n%%SHA256SUM%%\n%s\n\n' \
        "$4" "$2" "$3" "$5" >"$1/$2-$3/desc"
}

@test "bm_parse_kver splits a SteamOS kernel release into package coordinates" {
    bm_parse_kver 7.2.7-valve2-2-neptune-72-g31504582a073
    [ "$BM_BASE" = 7.2.7 ]
    [ "$BM_EXTRA" = valve2 ]
    [ "$BM_REL" = 2 ]
    [ "$BM_FLAVOUR" = neptune-72 ]
    [ "$BM_GITHASH" = 31504582a073 ]
    [ "$BM_PKGBASE" = linux-neptune-72 ]
    [ "$BM_PKGVER" = 7.2.7.valve2 ]
    [ "$BM_TAG" = 7.2.7-valve2 ]
    bm_parse_kver 7.2.7-valve2-1-neptune-72
    [ "$BM_GITHASH" = "" ]
    [ "$BM_REL" = 1 ]
    bm_parse_kver 5.13.0-valve37-1-neptune
    [ "$BM_PKGBASE" = linux-neptune ]
    bm_parse_kver 7.2.0-rc3-valve-beta1-2-neptune-72
    [ "$BM_PKGVER" = 7.2.0.rc3.valve.beta1 ]
    [ "$BM_TAG" = 7.2.0-rc3-valve-beta1 ]
    run bm_parse_kver 6.12.0-arch1-1
    assert_failure
}

@test "list parsing: both lists, comments skipped, suffixes and slashes normalised" {
    write_lists
    run bm_list_entries "$PATCHES_DIR"
    assert_success
    [ "${lines[0]}" = "0010-hid.patch${TAB}drivers/hid${TAB}hid-asus-ally" ]
    [ "${lines[1]}" = "0011-hid.patch${TAB}drivers/hid${TAB}hid-asus-ally" ]
    [ "${lines[2]}" = "0001-asoc.patch${TAB}sound/soc/amd/acp${TAB}snd-soc-acpi-amd-match" ]
    [ "${lines[3]}" = "0002-acp.patch${TAB}sound/soc/amd${TAB}snd-acp-config" ]
    [ "${#lines[@]}" -eq 4 ]
    [ "$(bm_list_entries "$PATCHES_DIR" | bm_entries_column 2 | tr '\n' ' ')" = "drivers/hid sound/soc/amd sound/soc/amd/acp " ]
    [ "$(bm_list_entries "$PATCHES_DIR" | bm_kos_for_mdir drivers/hid)" = hid-asus-ally ]
}

@test "list parsing rejects malformed and unsafe lines" {
    printf 'only-two\tfields\n' >"$PATCHES_DIR/modules.list"
    run bm_list_entries "$PATCHES_DIR"
    assert_failure
    printf 'p.patch\t../../etc\tx.ko\n' >"$PATCHES_DIR/modules.list"
    run bm_list_entries "$PATCHES_DIR"
    assert_failure
    rm "$PATCHES_DIR/modules.list"
    run bm_list_entries "$PATCHES_DIR"
    assert_success
    [ -z "$output" ]
}

@test "build script and lib/modules.sh parse the lists identically" {
    write_lists
    expected=$(bm_list_entries "$PATCHES_DIR")
    actual=$(AX20_PATCHES_DIR="$PATCHES_DIR" bash -c '. "$1/lib/modules.sh"; modules_list_entries' _ "$REPO_ROOT")
    [ "$expected" = "$actual" ]
}

@test "modprobe.d drop-in is generated from the lists, one hook per module" {
    write_lists
    run env AX20_PATCHES_DIR="$PATCHES_DIR" bash -c '. "$1/lib/modules.sh"; modules_render_modprobe_conf' _ "$REPO_ROOT"
    assert_success
    hooks=$(printf '%s\n' "$output" | grep '^install ')
    [ "$(printf '%s\n' "$hooks" | wc -l | tr -d ' ')" = 3 ]
    for m in hid-asus-ally snd-acp-config snd-soc-acpi-amd-match; do
        printf '%s\n' "$hooks" | grep -Fxq "install $m /bin/sh -c '/etc/ally-x20-steamos/load-or-fallback $m \"\$@\" || exec modprobe --ignore-install $m \"\$@\"' -- \$CMDLINE_OPTS"
    done
    # nothing points into /usr
    ! printf '%s\n' "$output" | grep -q ' /usr/'
}

@test "bm_patch_touched_files and bm_check_patch_scope" {
    write_lists
    printf -- '--- a/sound/soc/amd/acp/amd-acp70-acpi-match.c\n+++ b/sound/soc/amd/acp/amd-acp70-acpi-match.c\n@@ -1 +1 @@\n-a\n+b\n' >"$PATCHES_DIR/0001-asoc.patch"
    printf -- '--- a/sound/soc/amd/acp-config.c\n+++ b/sound/soc/amd/acp-config.c\n@@ -1 +1 @@\n-a\n+b\n' >"$PATCHES_DIR/0002-acp.patch"
    printf -- '--- a/drivers/hid/hid-asus-ally.c\n+++ b/drivers/hid/hid-asus-ally.c\n@@ -1 +1 @@\n-a\n+b\n' >"$PATCHES_DIR/0010-hid.patch"
    printf -- '--- /dev/null\n+++ b/drivers/hid/hid-asus-ally-new.h\n@@ -0,0 +1 @@\n+b\n' >"$PATCHES_DIR/0011-hid.patch"
    [ "$(bm_patch_touched_files "$PATCHES_DIR/0011-hid.patch")" = drivers/hid/hid-asus-ally-new.h ]
    run bash -c '. "$1"; bm_list_entries "$2" | bm_check_patch_scope "$2"' _ "$REPO_ROOT/build/build-modules.sh" "$PATCHES_DIR"
    assert_success
    printf -- '--- a/include/linux/hid.h\n+++ b/include/linux/hid.h\n@@ -1 +1 @@\n-a\n+b\n' >"$PATCHES_DIR/0011-hid.patch"
    run bash -c '. "$1"; bm_list_entries "$2" | bm_check_patch_scope "$2"' _ "$REPO_ROOT/build/build-modules.sh" "$PATCHES_DIR"
    assert_failure
    assert_output_contains "include/linux/hid.h, outside M=drivers/hid"
}

@test "repo database lookup on a gzip db (exact name and version)" {
    db="$BATS_TEST_TMPDIR/db"
    make_desc "$db" linux-neptune-72-headers 7.2.7.valve2-2 linux-neptune-72-headers-7.2.7.valve2-2-x86_64.pkg.tar.zst aaaa
    make_desc "$db" linux-neptune-72 7.2.7.valve2-2 linux-neptune-72-7.2.7.valve2-2-x86_64.pkg.tar.zst bbbb
    make_desc "$db" linux-neptune-72-headers-extra 7.2.7.valve2-2 wrong.pkg.tar.zst cccc
    (cd "$db" && tar -czf "$BATS_TEST_TMPDIR/jupiter-main.db" ./*)
    run bm_repo_db_lookup "$BATS_TEST_TMPDIR/jupiter-main.db" linux-neptune-72-headers 7.2.7.valve2-2
    assert_success
    [ "$output" = "linux-neptune-72-headers-7.2.7.valve2-2-x86_64.pkg.tar.zst${TAB}aaaa" ]
    run bm_repo_db_lookup "$BATS_TEST_TMPDIR/jupiter-main.db" linux-neptune-72-headers 7.2.7.valve2-1
    assert_failure
    [ "$(bm_repo_db_versions "$BATS_TEST_TMPDIR/jupiter-main.db" linux-neptune-72-headers)" = 7.2.7.valve2-2 ]
}

@test "repo database lookup on xz and zstd databases (the mirror uses xz)" {
    db="$BATS_TEST_TMPDIR/db"
    make_desc "$db" linux-neptune-72-headers 7.2.7.valve2-2 h.pkg.tar.zst abcd
    (cd "$db" && tar -cf "$BATS_TEST_TMPDIR/plain.tar" ./*)
    if command -v xz >/dev/null 2>&1; then
        xz -c "$BATS_TEST_TMPDIR/plain.tar" >"$BATS_TEST_TMPDIR/x.db"
        run bm_repo_db_lookup "$BATS_TEST_TMPDIR/x.db" linux-neptune-72-headers 7.2.7.valve2-2
        assert_success
        [ "$output" = "h.pkg.tar.zst${TAB}abcd" ]
    fi
    if command -v zstd >/dev/null 2>&1; then
        zstd -q -c "$BATS_TEST_TMPDIR/plain.tar" >"$BATS_TEST_TMPDIR/z.db"
        run bm_repo_db_lookup "$BATS_TEST_TMPDIR/z.db" linux-neptune-72-headers 7.2.7.valve2-2
        assert_success
        [ "$output" = "h.pkg.tar.zst${TAB}abcd" ]
    fi
}

# fake_headers_package <dest-file> : a pacman-style package with a build dir.
fake_headers_package() {
    local p="$BATS_TEST_TMPDIR/pkgroot/usr/lib/modules/$KVER/build"
    mkdir -p "$p"
    printf 'all:\n' >"$p/Makefile"
    printf 'CONFIG_HID=y\n' >"$p/.config"
    printf '0x00000000\thid_hw_start\tvmlinux\tEXPORT_SYMBOL_GPL\t\n' >"$p/Module.symvers"
    printf '%s\n' "$KVER" >"$p/version"
    (cd "$BATS_TEST_TMPDIR/pkgroot" && tar -cf - usr) | gzip -c >"$1"
}

@test "step 2: headers package found via the repo db, checksum verified, cached; step 1 reuses it" {
    pkgdir="$MIRROR/jupiter-rel/os/x86_64"
    mkdir -p "$pkgdir" "$MIRROR/jupiter-main/os/x86_64"
    fn=linux-neptune-72-headers-7.2.7.valve2-2-x86_64.pkg.tar.zst
    fake_headers_package "$pkgdir/$fn"
    sha=$(bm_sha256 "$pkgdir/$fn")
    # jupiter-main has an older release only; jupiter-rel has ours.
    make_desc "$BATS_TEST_TMPDIR/dbm" linux-neptune-72-headers 7.2.7.valve2-1 old.pkg.tar.zst 0000
    (cd "$BATS_TEST_TMPDIR/dbm" && tar -czf "$MIRROR/jupiter-main/os/x86_64/jupiter-main.db" ./*)
    make_desc "$BATS_TEST_TMPDIR/dbr" linux-neptune-72-headers 7.2.7.valve2-2 "$fn" "$sha"
    (cd "$BATS_TEST_TMPDIR/dbr" && tar -czf "$pkgdir/jupiter-rel.db" ./*)
    bm_headers_from_mirror
    [ "$BM_HEADER_SOURCE" = 2 ]
    [ "$BM_HEADER_URL" = "$BM_MIRROR_BASE/jupiter-rel/os/x86_64/$fn" ]
    [ "$BM_HEADER_SHA256" = "$sha" ]
    [ "$BM_CHANNEL_USED" = jupiter-rel ]
    [ -f "$CACHE_DIR/headers/$KVER/Module.symvers" ]
    BM_HEADER_SOURCE="" BM_HEADER_URL=""
    bm_headers_from_cache
    [ "$BM_HEADER_SOURCE" = 1 ]
    [ "$BM_HEADER_ORIGIN" = 2 ]
    [ "$BM_HEADER_URL" = "$BM_MIRROR_BASE/jupiter-rel/os/x86_64/$fn" ]
}

@test "step 2 rejects a package whose sha256 differs from the repo db" {
    pkgdir="$MIRROR/jupiter-main/os/x86_64"
    mkdir -p "$pkgdir"
    fn=linux-neptune-72-headers-7.2.7.valve2-2-x86_64.pkg.tar.zst
    fake_headers_package "$pkgdir/$fn"
    make_desc "$BATS_TEST_TMPDIR/db" linux-neptune-72-headers 7.2.7.valve2-2 "$fn" deadbeef
    (cd "$BATS_TEST_TMPDIR/db" && tar -czf "$pkgdir/jupiter-main.db" ./*)
    run bm_headers_from_mirror
    assert_failure
    assert_output_contains "sha256 does not match"
    [ ! -d "$CACHE_DIR/headers/$KVER" ]
}

@test "step 2 explains a kver without the -g<commit> suffix" {
    KVER=7.2.7-valve2-2-neptune-72
    pkgdir="$MIRROR/jupiter-main/os/x86_64"
    mkdir -p "$pkgdir"
    fn=h.pkg.tar.zst
    KVER=7.2.7-valve2-2-neptune-72-g31504582a073 fake_headers_package "$pkgdir/$fn"
    make_desc "$BATS_TEST_TMPDIR/db" linux-neptune-72-headers 7.2.7.valve2-2 "$fn" "$(bm_sha256 "$pkgdir/$fn")"
    (cd "$BATS_TEST_TMPDIR/db" && tar -czf "$pkgdir/jupiter-main.db" ./*)
    run bm_headers_from_mirror
    assert_failure
    assert_output_contains "-g<commit>"
}

@test "step 4 (linux-stable) is refused without a cached Valve tree" {
    BM_ENTRIES=""
    run bm_headers_from_stable
    assert_failure
    assert_output_contains "no cached Valve source"
}

@test "bm_trees_match: identical paths pass, a missing file (hid-asus-ally.c) or a changed byte fails" {
    a="$BATS_TEST_TMPDIR/a" b="$BATS_TEST_TMPDIR/b"
    mkdir -p "$a/sound/soc/amd" "$b/sound/soc/amd" "$a/drivers/hid" "$b/drivers/hid"
    printf 'x' >"$a/sound/soc/amd/f.c"
    printf 'x' >"$b/sound/soc/amd/f.c"
    run bm_trees_match "$a" "$b" sound/soc/amd
    assert_success
    printf 'ally' >"$a/drivers/hid/hid-asus-ally.c"
    run bm_trees_match "$a" "$b" sound/soc/amd drivers/hid
    assert_failure
    printf 'y' >"$b/sound/soc/amd/f.c"
    run bm_trees_match "$a" "$b" sound/soc/amd
    assert_failure
}

@test "symbol check: undefined symbols must be exported, CRCs must agree when versioned" {
    sv="$BATS_TEST_TMPDIR/Module.symvers"
    printf '0x00000000\thid_hw_start\tvmlinux\tEXPORT_SYMBOL_GPL\t\n0x12345678\tvalidate_mcu_fw_version\tdrivers/hid/hid-asus\tEXPORT_SYMBOL_GPL\t\n' >"$sv"
    printf 'hid_hw_start\nvalidate_mcu_fw_version\n' >"$BATS_TEST_TMPDIR/undef"
    : >"$BATS_TEST_TMPDIR/vers"
    run bm_symbol_check "$BATS_TEST_TMPDIR/undef" "$BATS_TEST_TMPDIR/vers" "$sv"
    assert_success
    printf '0x12345678\tvalidate_mcu_fw_version\n' >"$BATS_TEST_TMPDIR/vers"
    run bm_symbol_check "$BATS_TEST_TMPDIR/undef" "$BATS_TEST_TMPDIR/vers" "$sv"
    assert_success
    printf '0x87654321\tvalidate_mcu_fw_version\n' >"$BATS_TEST_TMPDIR/vers"
    run bm_symbol_check "$BATS_TEST_TMPDIR/undef" "$BATS_TEST_TMPDIR/vers" "$sv"
    assert_failure
    assert_output_contains "CRC mismatch for validate_mcu_fw_version"
    : >"$BATS_TEST_TMPDIR/vers"
    printf 'hid_hw_start\nnot_exported_anywhere\n' >"$BATS_TEST_TMPDIR/undef"
    run bm_symbol_check "$BATS_TEST_TMPDIR/undef" "$BATS_TEST_TMPDIR/vers" "$sv"
    assert_failure
    assert_output_contains "not_exported_anywhere"
    # a symbol exported by a sibling module built in the same M= dir
    printf '0x00000000\tnot_exported_anywhere\tdrivers/hid/hid-asus-ally\tEXPORT_SYMBOL\t\n' >"$BATS_TEST_TMPDIR/M.symvers"
    run bm_symbol_check "$BATS_TEST_TMPDIR/undef" "$BATS_TEST_TMPDIR/vers" "$sv" "$BATS_TEST_TMPDIR/M.symvers"
    assert_success
}

@test "bm_vermagic_ok compares the release word only" {
    bm_vermagic_ok "$KVER SMP preempt mod_unload " "$KVER"
    ! bm_vermagic_ok "7.2.7-valve2-1-neptune-72 SMP preempt mod_unload " "$KVER"
    ! bm_vermagic_ok "" "$KVER"
}

# make_patch <tree> <path> <old> <new> <patch-file>
make_patch() {
    mkdir -p "$BATS_TEST_TMPDIR/pa/a/$(dirname "$2")" "$BATS_TEST_TMPDIR/pa/b/$(dirname "$2")"
    printf '%s\n' "$3" >"$BATS_TEST_TMPDIR/pa/a/$2"
    printf '%s\n' "$4" >"$BATS_TEST_TMPDIR/pa/b/$2"
    (cd "$BATS_TEST_TMPDIR/pa" && diff -u "a/$2" "b/$2") >"$5" || true
    rm -rf "$BATS_TEST_TMPDIR/pa"
}

@test "patches already in Valve's tree are skipped and their module marked superseded" {
    command -v git >/dev/null 2>&1 || skip "git not installed"
    write_lists
    rm "$PATCHES_DIR/modules.list"
    printf '0010-hid.patch\tdrivers/hid\thid-asus-ally.ko\n0011-hid.patch\tdrivers/hid\thid-asus-ally.ko\n' >"$PATCHES_DIR/modules-hid.list"
    printf '0001-asoc.patch\tsound/soc/amd/acp\tsnd-soc-acpi-amd-match.ko\n' >"$PATCHES_DIR/modules.list"
    make_patch t drivers/hid/hid-asus-ally.c 'old line' 'new line' "$PATCHES_DIR/0010-hid.patch"
    make_patch t drivers/hid/hid-asus-ally.h 'h old' 'h new' "$PATCHES_DIR/0011-hid.patch"
    make_patch t sound/soc/amd/acp/match.c 'no RC74XA' 'RC74XA entry' "$PATCHES_DIR/0001-asoc.patch"
    BM_ENTRIES=$(bm_list_entries "$PATCHES_DIR")
    tree="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$tree/drivers/hid" "$tree/sound/soc/amd/acp"
    printf 'old line\n' >"$tree/drivers/hid/hid-asus-ally.c"
    printf 'h old\n' >"$tree/drivers/hid/hid-asus-ally.h"
    # Valve already carries the ASoC fix
    printf 'RC74XA entry\n' >"$tree/sound/soc/amd/acp/match.c"
    bm_apply_patches "$tree"
    [ "$(cat "$tree/drivers/hid/hid-asus-ally.c")" = "new line" ]
    [ "$(cat "$tree/drivers/hid/hid-asus-ally.h")" = "h new" ]
    printf '%s' "$BM_PATCH_STATUS" | grep -qx '0001-asoc.patch already-upstream'
    printf '%s' "$BM_PATCH_STATUS" | grep -qx '0010-hid.patch applied'
    bm_is_superseded snd-soc-acpi-amd-match
    ! bm_is_superseded hid-asus-ally
    ! bm_mdir_needed sound/soc/amd/acp
    bm_mdir_needed drivers/hid
}

@test "a patch that applies neither way fails the build" {
    command -v git >/dev/null 2>&1 || skip "git not installed"
    printf '0010-hid.patch\tdrivers/hid\thid-asus-ally.ko\n' >"$PATCHES_DIR/modules-hid.list"
    make_patch t drivers/hid/hid-asus-ally.c 'old line' 'new line' "$PATCHES_DIR/0010-hid.patch"
    BM_ENTRIES=$(bm_list_entries "$PATCHES_DIR")
    tree="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$tree/drivers/hid"
    printf 'something else\n' >"$tree/drivers/hid/hid-asus-ally.c"
    run bm_apply_patches "$tree"
    assert_failure
    assert_output_contains "neither forward nor reverse"
}

@test "BUILD-INFO rendering records kver, vermagic, sources, patch and module hashes" {
    write_lists
    for p in 0001-asoc.patch 0002-acp.patch 0010-hid.patch 0011-hid.patch; do printf '%s\n' "$p" >"$PATCHES_DIR/$p"; done
    BM_ENTRIES=$(bm_list_entries "$PATCHES_DIR")
    out="$BATS_TEST_TMPDIR/out"
    mkdir -p "$out"
    printf 'ko' >"$out/hid-asus-ally.ko.zst"
    BM_VERMAGIC="$KVER SMP preempt mod_unload "
    BM_HEADER_SOURCE=2 BM_HEADER_DESC=valve-headers-package
    BM_HEADER_URL=https://example/h.pkg.tar.zst BM_HEADER_SHA256=abc
    BM_CHANNEL_USED=jupiter-main
    BM_SOURCE_URL=https://github.com/evlaV/linux-integration.git
    BM_SOURCE_REF=7.2.7-valve2@31504582a07316ae0e8a8fb3b8fdc39d94842816
    BM_SOURCE_SHA256=""
    BM_PATCH_STATUS="0001-asoc.patch already-upstream
0002-acp.patch already-upstream
0010-hid.patch applied
0011-hid.patch applied
"
    BM_SUPERSEDED=" snd-acp-config snd-soc-acpi-amd-match"
    AX20_COMMIT=0123abc BUILD_DATE=2026-10-30T00:00:00Z
    CONTAINER_IMAGE=localhost/ally-x20-steamos-build CONTAINER_IMAGE_DIGEST=sha256:feed
    bm_render_build_info "$out" >"$out/BUILD-INFO"
    get() { AX20_SRC="$REPO_ROOT" bash -c '. "$1/lib/modules.sh"; modules_build_info_get "$2" "$3"' _ "$REPO_ROOT" "$out/BUILD-INFO" "$1"; }
    [ "$(get kver)" = "$KVER" ]
    [ "$(get vermagic)" = "$BM_VERMAGIC" ]
    [ "$(get header_source)" = 2 ]
    [ "$(get header_url)" = https://example/h.pkg.tar.zst ]
    [ "$(get source_ref)" = 7.2.7-valve2@31504582a07316ae0e8a8fb3b8fdc39d94842816 ]
    [ "$(get patch.0010-hid.patch)" = "$(bm_sha256 "$PATCHES_DIR/0010-hid.patch")" ]
    [ "$(get patch.0001-asoc.patch.status)" = already-upstream ]
    [ "$(get patch.0011-hid.patch.status)" = applied ]
    [ "$(get module.hid-asus-ally)" = "$(bm_sha256 "$out/hid-asus-ally.ko.zst")" ]
    [ "$(get module.snd-soc-acpi-amd-match)" = superseded ]
    [ "$(get ax20_commit)" = 0123abc ]
    [ "$(get build_date)" = 2026-10-30T00:00:00Z ]
    [ "$(get container_digest)" = sha256:feed ]
}

@test "bm_channels puts CHANNEL first without duplicates" {
    CHANNEL=jupiter-rel
    [ "$(bm_channels | tr '\n' ' ')" = "jupiter-rel jupiter-main " ]
}

@test "bm_pkgbuild_tag reads _tag without sourcing the PKGBUILD" {
    printf 'pkgbase=linux-neptune-72\n_tag=7.2.7-valve2\npkgver=${_tag//-/.}\n' >"$BATS_TEST_TMPDIR/PKGBUILD"
    [ "$(bm_pkgbuild_tag "$BATS_TEST_TMPDIR/PKGBUILD")" = 7.2.7-valve2 ]
}

@test "bm_sparse_dirs keeps two path components for relative includes" {
    write_lists
    BM_ENTRIES=$(bm_list_entries "$PATCHES_DIR")
    [ "$(bm_sparse_dirs | tr '\n' ' ')" = "drivers/hid sound/soc " ]
}
