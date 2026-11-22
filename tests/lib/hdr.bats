#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# lib/hdr.sh: getting the Desktop Mode HDR library (libdisplay-info 0.3.0 +
# backport) from the cache, a release or a container build, and the checks
# that keep a wrong or broken copy out.
load '../test_helper'
load '../hdr_helper'

setup() {
    make_root >/dev/null
    source_libs
    component_load hdr
    export AX20_OFFLINE=0
    LIB="$AX20_ROOT$HDR_STATE/lib"
    SRV="$BATS_TEST_TMPDIR/srv"
    mkdir -p "$SRV/versioned" "$SRV/latest"
    # Function-level stubs: a release server in $SRV, no real network.
    modules_online() { return 0; }
    _modules_fetch() {
        printf '%s\n' "$1" >>"$SRV/fetch.log"
        case "$1" in
            */latest/download/*) cp "$SRV/latest/${1##*/}" "$2" 2>/dev/null ;;
            *) cp "$SRV/versioned/${1##*/}" "$2" 2>/dev/null ;;
        esac
    }
    hdr_lib_container_build() {
        echo "container build called" >&2
        return 1
    }
}

last_line() { printf '%s\n' "${lines[${#lines[@]} - 1]}"; }

# ------------------------------------------------------------- naming --

@test "the artifact is named after the libdisplay-info version it replaces, not a kernel" {
    assert_equal "$(hdr_ldi_artifact_name)" "$HDR_ART"
    assert_equal "$(hdr_ldi_artifact_top)" "$HDR_TOP"
    assert_equal "$(hdr_ldi_real_name)" "$HDR_REAL"
}

@test "the component, the lock file and the build layout agree on soname and directories" {
    assert_equal "$HDR_LDI_SONAME" "$(hdr_lock_get LDI_SONAME)"
    assert_equal "$HDR_LIB_DIR" "$(hdr_ldi_libdir)"
    assert_equal "$HDR_LIB_BUILD_INFO" "$(hdr_ldi_build_info)"
    assert_equal "$HDR_LIB_TOOL" "$(hdr_ldi_bindir)/di-edid-decode"
}

# -------------------------------------------------------- stock check --

@test "stock check: applies to 0.3.0, not needed from 0.4.0, refused for anything else" {
    run hdr_lib_stock_check
    assert_failure 3
    assert_output_contains "cannot tell which libdisplay-info SteamOS ships"
    hdr_stock 0.3.0
    run hdr_lib_stock_check
    assert_success
    rm "$AX20_ROOT/usr/lib/libdisplay-info.so.3"
    run hdr_lib_stock_check
    assert_failure 2
    assert_output_contains "has no /usr/lib/libdisplay-info.so.3"
}

@test "stock check: SteamOS with 0.4.0 or later reads DisplayID 2 itself" {
    hdr_stock 0.4.0
    run hdr_lib_stock_check
    assert_failure 1
    assert_output_contains "our library is not needed"
    hdr_stock 0.5.1
    run hdr_lib_stock_check
    assert_failure 1
}

@test "stock check: another old version (other soname) is refused" {
    hdr_stock 0.2.0
    run hdr_lib_stock_check
    assert_failure 2
    assert_output_contains "SteamOS ships libdisplay-info 0.2.0; our library replaces 0.3.0 (libdisplay-info.so.3) only"
}

# ------------------------------------------------------------ staging --

@test "stage installs the library through the manifest and status turns active" {
    hdr_stock 0.3.0
    component_apply hdr 2>/dev/null
    [ "$(hdr_status 2>/dev/null)" = stock ]
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    run hdr_lib_stage "$BATS_TEST_TMPDIR/b" release "https://example.invalid/$HDR_ART"
    assert_success
    cmp "$LIB/$HDR_REAL" "$BATS_TEST_TMPDIR/b/$HDR_REAL"
    [ "$(readlink "$LIB/libdisplay-info.so.3")" = "$HDR_REAL" ]
    [ -x "$AX20_ROOT$HDR_STATE/libdisplay-info/bin/di-edid-decode" ]
    [ -f "$AX20_ROOT$HDR_STATE/libdisplay-info/LICENSE" ]
    cmp "$AX20_ROOT$HDR_STATE/libdisplay-info/BUILD-INFO" "$BATS_TEST_TMPDIR/b/BUILD-INFO"
    local p
    for p in "$HDR_STATE/lib/$HDR_REAL" "$HDR_STATE/lib/libdisplay-info.so.3" \
        "$HDR_STATE/libdisplay-info/BUILD-INFO" "$HDR_STATE/libdisplay-info/bin/di-edid-decode" \
        "$HDR_STATE/libdisplay-info/LICENSE" "$HDR_STATE/libdisplay-info/SOURCE"; do
        manifest_verify "$p"
        [ "$(manifest_entry_get "$(manifest_entry "$p")" component)" = hdr ]
    done
    hdr_lib_current
    assert_equal "$(hdr_lib_source_get source)" release
    assert_equal "$(hdr_lib_source_get origin)" "https://example.invalid/$HDR_ART"
    assert_equal "$(hdr_lib_info_get build_id)" "$(hdr_build_id libdisplay-info)"
    [ "$(hdr_status 2>/dev/null)" = active ]
}

@test "stage refuses a build for another libdisplay-info version or soname" {
    hdr_stock 0.3.0
    hdr_fake_build "$BATS_TEST_TMPDIR/b" "ELF" libdisplay_info_version=0.4.0
    run hdr_lib_stage "$BATS_TEST_TMPDIR/b" release
    assert_failure
    assert_output_contains "libdisplay_info_version is '0.4.0', this checkout needs '0.3.0'"
    hdr_fake_build "$BATS_TEST_TMPDIR/c" "ELF" libdisplay_info_soname=libdisplay-info.so.4
    run hdr_lib_stage "$BATS_TEST_TMPDIR/c" release
    assert_failure
    assert_output_contains "libdisplay_info_soname is 'libdisplay-info.so.4'"
    [ ! -e "$LIB" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/manifest" ]
}

@test "stage refuses a build made from other patches, another commit or without BUILD-INFO" {
    hdr_stock 0.3.0
    hdr_fake_build "$BATS_TEST_TMPDIR/b" "ELF" libdisplay_info_patches=0001-x.patch:abc
    run hdr_lib_stage "$BATS_TEST_TMPDIR/b" cache
    assert_failure
    assert_output_contains "libdisplay_info_patches differs"
    hdr_fake_build "$BATS_TEST_TMPDIR/c" "ELF" build_id=0000000000000000
    run hdr_lib_stage "$BATS_TEST_TMPDIR/c" cache
    assert_failure
    assert_output_contains "build_id differs"
    hdr_fake_build "$BATS_TEST_TMPDIR/d" "ELF" libdisplay_info_commit=deadbeef
    run hdr_lib_stage "$BATS_TEST_TMPDIR/d" cache
    assert_failure
    hdr_fake_build "$BATS_TEST_TMPDIR/e"
    rm "$BATS_TEST_TMPDIR/e/BUILD-INFO"
    run hdr_lib_stage "$BATS_TEST_TMPDIR/e" cache
    assert_failure
    assert_output_contains "no usable BUILD-INFO"
    [ ! -e "$LIB" ]
}

@test "stage refuses a library whose sha256 is not the one in BUILD-INFO" {
    hdr_stock 0.3.0
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    printf 'tampered' >"$BATS_TEST_TMPDIR/b/$HDR_REAL"
    run hdr_lib_stage "$BATS_TEST_TMPDIR/b" release
    assert_failure
    assert_output_contains "does not match the sha256 in its BUILD-INFO"
    [ ! -e "$LIB" ]
}

@test "stage installs nothing when SteamOS ships 0.4.0 or another version" {
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    hdr_stock 0.4.0
    run hdr_lib_stage "$BATS_TEST_TMPDIR/b" release
    assert_failure
    assert_output_contains "our library is not needed"
    [ ! -e "$LIB" ]
    rm -rf "$AX20_ROOT/usr/lib"
    hdr_stock 0.2.0
    run hdr_lib_stage "$BATS_TEST_TMPDIR/b" release
    assert_failure
    [ ! -e "$LIB" ]
}

@test "stage replaces an unrecorded hand-built copy and drops its development files" {
    hdr_stock 0.3.0
    # What `build-hdr.sh --destdir` bind-mounted onto the state dir leaves.
    fixture_file "$HDR_STATE/lib/$HDR_REAL" "ELF manual build"
    ln -s "$HDR_REAL" "$LIB/libdisplay-info.so.3"
    ln -s libdisplay-info.so.3 "$LIB/libdisplay-info.so"
    fixture_file "$HDR_STATE/lib/pkgconfig/libdisplay-info.pc" "Version: 0.3.0"
    fixture_file "$HDR_STATE/libdisplay-info/include/libdisplay-info/info.h" "/* header */"
    fixture_file "$HDR_STATE/libdisplay-info/bin/di-edid-decode" "ELF tool"
    fixture_file "$HDR_STATE/libdisplay-info/BUILD-INFO" "build_id=manual"
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    run hdr_lib_stage "$BATS_TEST_TMPDIR/b" release
    assert_success
    assert_output_contains "not recorded in the manifest, from a manual build"
    cmp "$LIB/$HDR_REAL" "$BATS_TEST_TMPDIR/b/$HDR_REAL"
    hdr_lib_current
    [ ! -e "$LIB/libdisplay-info.so" ] && [ ! -L "$LIB/libdisplay-info.so" ]
    [ ! -e "$LIB/pkgconfig" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/libdisplay-info/include" ]
    manifest_verify "$HDR_STATE/lib/$HDR_REAL"
    manifest_verify "$HDR_STATE/libdisplay-info/BUILD-INFO"
}

@test "stage replaces an older recorded build in place" {
    hdr_stock 0.3.0
    hdr_fake_build "$BATS_TEST_TMPDIR/b1" "ELF build one"
    hdr_lib_stage "$BATS_TEST_TMPDIR/b1" release 2>/dev/null
    hdr_fake_build "$BATS_TEST_TMPDIR/b2" "ELF build two"
    hdr_lib_stage "$BATS_TEST_TMPDIR/b2" container 2>/dev/null
    [ "$(cat "$LIB/$HDR_REAL")" = "ELF build two" ]
    manifest_verify "$HDR_STATE/lib/$HDR_REAL"
    assert_equal "$(hdr_lib_source_get source)" container
    [ "$(manifest_paths hdr | grep -c "/lib/$HDR_REAL\$")" = 1 ]
}

@test "stage in dry-run writes nothing" {
    hdr_stock 0.3.0
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    AX20_DRY_RUN=1 run hdr_lib_stage "$BATS_TEST_TMPDIR/b" release
    assert_success
    [ ! -e "$LIB" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/libdisplay-info" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/manifest" ]
}

# ---------------------------------------------------------- load test --

@test "load test: a file the dynamic loader cannot load is refused" {
    command -v python3 >/dev/null 2>&1 || skip "no python3"
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    AX20_ROOT="" run hdr_lib_load_test "$BATS_TEST_TMPDIR/b"
    assert_failure
    assert_output_contains "this system cannot load the library"
}

@test "load test: accepted when the loader takes it and di-edid-decode runs" {
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    _hdr_lib_dlopen() { return 0; }
    AX20_ROOT="" run hdr_lib_load_test "$BATS_TEST_TMPDIR/b"
    assert_success
    # the tool exiting 1 (it could not parse an empty EDID) still means it ran
    printf '#!/bin/sh\necho "di_edid_parse failed" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/b/di-edid-decode"
    AX20_ROOT="" run hdr_lib_load_test "$BATS_TEST_TMPDIR/b"
    assert_success
}

@test "load test: a crash or a missing symbol in di-edid-decode refuses the library" {
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    _hdr_lib_dlopen() { return 0; }
    printf '#!/bin/sh\nkill -SEGV $$\n' >"$BATS_TEST_TMPDIR/b/di-edid-decode"
    AX20_ROOT="" run hdr_lib_load_test "$BATS_TEST_TMPDIR/b"
    assert_failure
    assert_output_contains "crashed with the library"
    printf '#!/bin/sh\necho "di-edid-decode: symbol lookup error: undefined symbol: di_info_get_hdr_static_metadata" >&2\nexit 127\n' \
        >"$BATS_TEST_TMPDIR/b/di-edid-decode"
    AX20_ROOT="" run hdr_lib_load_test "$BATS_TEST_TMPDIR/b"
    assert_failure
    assert_output_contains "cannot use the library"
}

@test "load test: di-edid-decode needing a newer glibc than the system is not held against the library" {
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    _hdr_lib_dlopen() { return 0; }
    printf '#!/bin/sh\necho "di-edid-decode: /usr/lib/libc.so.6: version GLIBC_2.43 not found (required by di-edid-decode)" >&2\nexit 127\n' \
        >"$BATS_TEST_TMPDIR/b/di-edid-decode"
    AX20_ROOT="" run hdr_lib_load_test "$BATS_TEST_TMPDIR/b"
    assert_success
}

@test "load test: the panel's EDID is what di-edid-decode reads when the system has one" {
    fixture_file /sys/class/drm/card1-eDP-1/edid "EDID-BYTES"
    assert_equal "$(_hdr_lib_edid)" "$AX20_ROOT/sys/class/drm/card1-eDP-1/edid"
}

# --------------------------------------------------------- resolution --

@test "resolve: an installed, current library is a cache hit; nothing is downloaded" {
    hdr_stock 0.3.0
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    hdr_lib_stage "$BATS_TEST_TMPDIR/b" release 2>/dev/null
    run hdr_lib_resolve
    assert_success
    assert_equal "$(last_line)" cache
    [ ! -e "$SRV/fetch.log" ]
}

@test "resolve: a cached artifact is verified and installed without the network" {
    hdr_stock 0.3.0
    modules_online() { return 1; }
    a="$AX20_ROOT$HDR_STATE/cache/artifacts"
    hdr_fake_tarball "$a/$HDR_ART"
    run hdr_lib_resolve
    assert_success
    assert_equal "$(last_line)" cache
    hdr_lib_current
    assert_equal "$(hdr_lib_source_get source)" cache
}

@test "resolve: a cached artifact with a bad checksum is ignored" {
    hdr_stock 0.3.0
    modules_online() { return 1; }
    a="$AX20_ROOT$HDR_STATE/cache/artifacts"
    hdr_fake_tarball "$a/$HDR_ART"
    printf '0000  x\n' >"$a/$HDR_ART.sha256"
    run hdr_lib_resolve
    assert_failure 1
    assert_output_contains "fails its checksum"
    [ ! -e "$LIB" ]
}

@test "resolve: order is cache, then this version's release, then the latest release" {
    hdr_stock 0.3.0
    hdr_fake_tarball "$SRV/latest/$HDR_ART"
    run hdr_lib_resolve
    assert_success
    assert_equal "$(last_line)" release
    hdr_lib_current
    v=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")
    assert_equal "$(sed -n 1p "$SRV/fetch.log")" "https://github.com/cchulo/ally-x20-steamos/releases/download/v$v/$HDR_ART.sha256"
    assert_equal "$(sed -n 2p "$SRV/fetch.log")" "https://github.com/cchulo/ally-x20-steamos/releases/latest/download/$HDR_ART.sha256"
    assert_equal "$(hdr_lib_source_get origin)" "https://github.com/cchulo/ally-x20-steamos/releases/latest/download/$HDR_ART"
    # the download is kept for the next run
    [ -f "$AX20_ROOT$HDR_STATE/cache/artifacts/$HDR_ART" ]
    [ -f "$AX20_ROOT$HDR_STATE/cache/artifacts/$HDR_ART.sha256" ]
    [[ "$output" != *"container build called"* ]]
}

@test "resolve: a release artifact that fails its checksum is never installed" {
    hdr_stock 0.3.0
    hdr_fake_tarball "$SRV/versioned/$HDR_ART"
    printf '0000  x\n' >"$SRV/versioned/$HDR_ART.sha256"
    run hdr_lib_resolve
    assert_failure 1
    assert_output_contains "fails its checksum; not installing it"
    [ ! -e "$LIB" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/cache/artifacts/$HDR_ART" ]
}

@test "resolve: a release artifact built from other pins is refused; a matching later one is used" {
    hdr_stock 0.3.0
    hdr_fake_tarball "$SRV/versioned/$HDR_ART" "ELF other" libdisplay_info_soname=libdisplay-info.so.4
    run hdr_lib_resolve
    assert_failure 1
    assert_output_contains "is not for this checkout"
    [ ! -e "$LIB" ]
    hdr_fake_tarball "$SRV/latest/$HDR_ART" "ELF good"
    run hdr_lib_resolve
    assert_success
    [ "$(cat "$LIB/$HDR_REAL")" = "ELF good" ]
}

@test "resolve: a tarball with entries outside libdisplay-info-<version>/ is rejected" {
    hdr_stock 0.3.0
    s="$BATS_TEST_TMPDIR/x"
    hdr_fake_build "$s/$HDR_TOP"
    mkdir -p "$s/evil" && printf 'x' >"$s/evil/f"
    tar -C "$s" -cf - "$HDR_TOP" evil | zstd -q -o "$SRV/versioned/$HDR_ART"
    printf '%s  f\n' "$(ax20_sha256 "$SRV/versioned/$HDR_ART")" >"$SRV/versioned/$HDR_ART.sha256"
    run hdr_lib_resolve --source release
    assert_failure 1
    assert_output_contains "unexpected entry"
    [ ! -e "$LIB" ]
}

@test "resolve: offline is not an error to die on; nothing is fetched" {
    hdr_stock 0.3.0
    modules_online() { return 1; }
    run hdr_lib_resolve
    assert_failure 1
    assert_output_contains "offline, not downloading"
    [ ! -e "$SRV/fetch.log" ]
}

@test "resolve: a release without the asset (v0.2.0) finds nothing and says so once, without a warning" {
    hdr_stock 0.3.0
    run hdr_lib_resolve
    assert_failure 1
    [ "${#lines[@]}" = 1 ]
    assert_output_contains "no prebuilt Desktop Mode library for this version in the releases"
    [[ "$output" != *warning* ]]
    [[ "$output" != *error* ]]
    [ -z "$(ls -A "$AX20_ROOT$HDR_STATE/cache/artifacts")" ]
}

@test "resolve: does nothing when SteamOS ships a newer libdisplay-info" {
    hdr_stock 0.4.0
    hdr_fake_tarball "$SRV/versioned/$HDR_ART"
    run hdr_lib_resolve
    assert_failure 3
    [ ! -e "$SRV/fetch.log" ]
    [ ! -e "$LIB" ]
}

@test "resolve: the container build is only used when asked for" {
    hdr_stock 0.3.0
    ax20_have() {
        [ "$1" = podman ] && return 0
        command -v "$1" >/dev/null 2>&1
    }
    hdr_lib_container_build() {
        hdr_fake_build "$1/artifact/$HDR_TOP" "ELF local build"
    }
    run hdr_lib_resolve
    assert_failure 1
    run hdr_lib_resolve --source container
    assert_success
    assert_equal "$(last_line)" container
    [ "$(cat "$LIB/$HDR_REAL")" = "ELF local build" ]
    assert_equal "$(hdr_lib_source_get source)" container
}

@test "resolve: no podman or a failed build leaves the system as it was" {
    hdr_stock 0.3.0
    ax20_have() {
        [ "$1" = podman ] && return 1
        command -v "$1" >/dev/null 2>&1
    }
    run hdr_lib_resolve --source container
    assert_failure 1
    assert_output_contains "podman not available"
    ax20_have() {
        [ "$1" = podman ] && return 0
        command -v "$1" >/dev/null 2>&1
    }
    run hdr_lib_resolve --source container
    assert_failure 1
    assert_output_contains "the container build failed"
    [ ! -e "$LIB" ]
    run hdr_lib_resolve --source floppy
    assert_failure 2
}

@test "container build: both images, storage on /home for rootful podman, build-hdr.sh arguments" {
    unset -f hdr_lib_container_build
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/hdr.sh"
    hdr_stub_bin
    PATH="$HDR_BIN:$PATH"
    ax20_is_root() { return 0; }
    # like SteamOS: the state dir is a symlink into /home
    rm -rf "$AX20_ROOT$HDR_STATE"
    mkdir -p "$AX20_ROOT/home/.ally-x20-steamos"
    ln -s ../../home/.ally-x20-steamos "$AX20_ROOT$HDR_STATE"
    run hdr_lib_container_build "$BATS_TEST_TMPDIR/out"
    assert_success
    store=$(cd "$AX20_ROOT/home/.ally-x20-steamos/cache/podman" && pwd -P)
    run cat "$HDR_SRV/podman.log"
    [ "${#lines[@]}" = 4 ]
    case "${lines[0]}" in "--root $store build -t localhost/ally-x20-steamos-build:latest -f $REPO_ROOT/build/Containerfile "*) ;; *) false ;; esac
    case "${lines[1]}" in "--root $store build -t localhost/ally-x20-steamos-build-hdr:latest --build-arg BASE_IMAGE=localhost/ally-x20-steamos-build:latest -f $REPO_ROOT/build/Containerfile.hdr "*) ;; *) false ;; esac
    case "${lines[3]}" in "--root $store run --rm "*) ;; *) false ;; esac
    assert_output_contains "-v $REPO_ROOT:/src:ro -v $BATS_TEST_TMPDIR/out:/out"
    assert_output_contains "--user 1000 localhost/ally-x20-steamos-build-hdr:latest --only libdisplay-info --destdir /out/stage --artifact-dir /out/artifact"
    assert_output_contains "AX20_BUILD_IMAGE=localhost/ally-x20-steamos-build-hdr:latest@sha256:feedface"
}

@test "container build: rootless podman keeps its own storage and maps the caller's uid" {
    unset -f hdr_lib_container_build
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/hdr.sh"
    hdr_stub_bin
    PATH="$HDR_BIN:$PATH"
    ax20_is_root() { return 1; }
    run hdr_lib_container_build "$BATS_TEST_TMPDIR/out"
    assert_success
    run cat "$HDR_SRV/podman.log"
    [[ "$output" != *"--root"* ]]
    assert_output_contains "--userns=keep-id localhost/ally-x20-steamos-build-hdr:latest --only libdisplay-info"
}

# ------------------------------------------------------------- remove --

@test "unstage takes every library file out, cleans the manifest and leaves the drop-ins" {
    hdr_stock 0.3.0
    component_apply hdr 2>/dev/null
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    hdr_lib_stage "$BATS_TEST_TMPDIR/b" release 2>/dev/null
    run hdr_lib_unstage
    assert_success
    [ ! -e "$LIB/$HDR_REAL" ] && [ ! -L "$LIB/libdisplay-info.so.3" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/libdisplay-info/BUILD-INFO" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/libdisplay-info/bin/di-edid-decode" ]
    ! manifest_has "$HDR_STATE/lib/$HDR_REAL"
    ! manifest_has "$HDR_STATE/lib/libdisplay-info.so.3"
    ! hdr_lib_present
    [ -f "$AX20_ROOT/etc/ld.so.conf.d/00-ally-x20-steamos.conf" ]
    [ -f "$AX20_ROOT/etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua" ]
    local p
    for p in $(manifest_paths hdr); do manifest_verify "$p"; done
}

@test "unstage also removes a hand-installed copy that was never recorded" {
    fixture_file "$HDR_STATE/lib/$HDR_REAL" "ELF manual"
    ln -s "$HDR_REAL" "$LIB/libdisplay-info.so.3"
    ln -s libdisplay-info.so.3 "$LIB/libdisplay-info.so"
    run hdr_lib_unstage
    assert_success
    [ -z "$(ls -A "$LIB")" ]
}

@test "the remove marker stops automatic fetches until it is cleared" {
    hdr_stock 0.3.0
    hdr_lib_fetch_due
    hdr_lib_set_disabled
    hdr_lib_disabled
    ! hdr_lib_fetch_due
    hdr_lib_clear_disabled
    hdr_lib_fetch_due
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    hdr_lib_stage "$BATS_TEST_TMPDIR/b" release 2>/dev/null
    ! hdr_lib_fetch_due
}

# -------------------------------------------------------------- apply --

@test "apply fetches the library from the release when asked to" {
    hdr_stock 0.3.0
    hdr_fake_tarball "$SRV/versioned/$HDR_ART"
    AX20_HDR_AUTO_FETCH=1 run component_apply hdr
    assert_success
    hdr_lib_current
    [ "$(hdr_status 2>/dev/null)" = active ]
    [[ "$output" != *"hdr fetch"* ]]
}

@test "apply offline succeeds and prints the notice naming the hdr command" {
    hdr_stock 0.3.0
    modules_online() { return 1; }
    AX20_HDR_AUTO_FETCH=1 run component_apply hdr
    assert_success
    assert_output_contains "Game Mode HDR already works; this is only about Desktop Mode."
    assert_output_contains "could not be downloaded now (offline, or this release has no prebuilt copy yet)"
    assert_output_contains "'sudo ally-x20-steamos hdr fetch'"
    assert_output_contains "'sudo ally-x20-steamos hdr build'"
    [[ "$output" != *"build/build-hdr.sh"* ]]
    [ ! -e "$LIB" ]
    [ -f "$AX20_ROOT/etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua" ]
}

@test "apply with no artifact in any release succeeds with the same notice" {
    hdr_stock 0.3.0
    AX20_HDR_AUTO_FETCH=1 run component_apply hdr
    assert_success
    assert_output_contains "'sudo ally-x20-steamos hdr fetch'"
    [ "$(printf '%s\n' "$output" | grep -c 'warning:')" = 1 ]
}

@test "apply on a fixture or slot root does not download; the boot service mode prints nothing" {
    hdr_stock 0.3.0
    hdr_fake_tarball "$SRV/versioned/$HDR_ART"
    run component_apply hdr
    assert_success
    assert_output_contains "has not been downloaded yet"
    [ ! -e "$SRV/fetch.log" ]
    AX20_HDR_AUTO_FETCH=0 run component_apply hdr
    assert_success
    [[ "$output" != *"Desktop Mode"* ]]
    [ ! -e "$SRV/fetch.log" ]
}

@test "apply leaves the library out after 'hdr remove' and when SteamOS has 0.4.0" {
    hdr_stock 0.3.0
    hdr_fake_tarball "$SRV/versioned/$HDR_ART"
    hdr_lib_set_disabled
    AX20_HDR_AUTO_FETCH=1 run component_apply hdr
    assert_success
    assert_output_contains "stays out"
    [ ! -e "$LIB" ]
    [ ! -e "$SRV/fetch.log" ]
    # removed on purpose: Game Mode half is all there is, and that is complete
    [ "$(hdr_status 2>/dev/null)" = active ]
    hdr_lib_clear_disabled
    rm -rf "$AX20_ROOT/usr/lib"
    hdr_stock 0.4.0
    AX20_HDR_AUTO_FETCH=1 run component_apply hdr
    assert_success
    [ ! -e "$LIB" ]
    [ ! -e "$SRV/fetch.log" ]
}

@test "apply replaces a library from another build when a matching one is released, and keeps it otherwise" {
    hdr_stock 0.3.0
    hdr_fake_build "$BATS_TEST_TMPDIR/b" "ELF old"
    hdr_lib_stage "$BATS_TEST_TMPDIR/b" release 2>/dev/null
    sed -i.bak 's/^build_id=.*/build_id=0000000000000000/' "$AX20_ROOT$HDR_STATE/libdisplay-info/BUILD-INFO"
    ! hdr_lib_current
    AX20_HDR_AUTO_FETCH=1 run component_apply hdr
    assert_success
    assert_output_contains "keeping the installed Desktop Mode library"
    [ "$(cat "$LIB/$HDR_REAL")" = "ELF old" ]
    hdr_fake_tarball "$SRV/versioned/$HDR_ART" "ELF new"
    AX20_HDR_AUTO_FETCH=1 run component_apply hdr
    assert_success
    [ "$(cat "$LIB/$HDR_REAL")" = "ELF new" ]
    hdr_lib_current
}

@test "dry-run apply with fetching on downloads and writes nothing" {
    hdr_stock 0.3.0
    hdr_fake_tarball "$SRV/versioned/$HDR_ART"
    AX20_DRY_RUN=1 AX20_HDR_AUTO_FETCH=1 run component_apply hdr
    assert_success
    [ ! -e "$SRV/fetch.log" ]
    [ ! -e "$LIB" ]
}
