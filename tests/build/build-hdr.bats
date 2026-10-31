#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# Non-build logic of build/build-hdr.sh: pins, layout, meson arguments,
# patch series, build ids, accepted-flag extraction, BUILD-INFO.
load '../test_helper'

setup() {
    # shellcheck disable=SC1091
    . "$REPO_ROOT/build/build-hdr.sh"
}

@test "sourcing the script does not start a build" {
    run bash -c '. "$1/build/build-hdr.sh" && echo sourced' _ "$REPO_ROOT"
    assert_success
    assert_equal "$output" sourced
}

@test "--help prints usage without building" {
    run "$REPO_ROOT/build/build-hdr.sh" --help
    assert_success
    assert_output_contains "--gamescope-mode cherry-pick|upstream"
}

@test "bad arguments are rejected before any tool check" {
    run "$REPO_ROOT/build/build-hdr.sh" --gamescope-mode nightly
    assert_failure
    assert_output_contains "--gamescope-mode must be"
    run "$REPO_ROOT/build/build-hdr.sh" --bogus
    assert_failure
    assert_output_contains "unknown argument"
}

@test "pins: libdisplay-info 0.3.0 tag commit, soname .so.3" {
    assert_equal "$(hdr_lock_get LDI_VERSION)" 0.3.0
    assert_equal "$(hdr_lock_get LDI_TAG)" 0.3.0
    assert_equal "$(hdr_lock_get LDI_COMMIT)" 47a5590e9c4eb35d67651b8c05a55f1a48259329
    assert_equal "$(hdr_lock_get LDI_SONAME)" libdisplay-info.so.3
}

@test "pins: gamescope 3.16.30.1 for cherry-pick, 3.17.0 for upstream" {
    assert_equal "$(hdr_gamescope_pin cherry-pick VERSION)" 3.16.30.1
    assert_equal "$(hdr_gamescope_pin cherry-pick COMMIT)" d93118d95c786702e588973f7c4a400356897f1d
    assert_equal "$(hdr_gamescope_pin upstream VERSION)" 3.17.0
    assert_equal "$(hdr_gamescope_pin upstream COMMIT)" e6674a98118ca7b098b98a3874b8f195ae1bf750
    run hdr_gamescope_pin nightly COMMIT
    assert_failure
    run hdr_lock_get NO_SUCH_KEY
    assert_failure
}

@test "layout: libdisplay-info lands where ld.so.conf.d and the component look" {
    assert_equal "$(hdr_ldi_libdir)" /var/lib/ally-x20-steamos/lib
    grep -qx "$(hdr_ldi_libdir)" "$REPO_ROOT/overlay/ld.so.conf.d/00-ally-x20-steamos.conf"
    assert_equal "$(hdr_ldi_bindir)" /var/lib/ally-x20-steamos/libdisplay-info/bin
    assert_equal "$(hdr_ldi_build_info)" /var/lib/ally-x20-steamos/libdisplay-info/BUILD-INFO
}

@test "layout: gamescope prefix matches the wrapper and the component" {
    assert_equal "$(hdr_gamescope_bin)" /opt/ally-x20-steamos/gamescope/bin/gamescope
    assert_equal "$(hdr_gamescope_build_info)" /opt/ally-x20-steamos/gamescope/BUILD-INFO
    assert_equal "$(hdr_gamescope_flags_file)" /opt/ally-x20-steamos/gamescope/share/ally-x20-steamos/accepted-flags
    grep -q 'AX20_GAMESCOPE_PREFIX:-/opt/ally-x20-steamos/gamescope}' "$REPO_ROOT/overlay/bin/gamescope"
    grep -q 'share/ally-x20-steamos/accepted-flags' "$REPO_ROOT/overlay/bin/gamescope"
}

@test "layout: one variable moves the gamescope prefix" {
    HDR_GAMESCOPE_PREFIX=/var/lib/ally-x20-steamos/opt/gamescope
    assert_equal "$(hdr_gamescope_bin)" /var/lib/ally-x20-steamos/opt/gamescope/bin/gamescope
    run hdr_gamescope_meson_args bundled
    assert_output_contains "-Dprefix=/var/lib/ally-x20-steamos/opt/gamescope"
}

@test "meson args: libdisplay-info prefix and libdir" {
    run hdr_ldi_meson_args
    assert_success
    assert_output_contains "-Dprefix=/var/lib/ally-x20-steamos"
    assert_output_contains "-Dlibdir=lib"
    assert_output_contains "-Ddefault_library=shared"
}

@test "meson args: gamescope bundled vs shared libdisplay-info" {
    run hdr_gamescope_meson_args bundled
    assert_success
    assert_output_contains "-Dforce_fallback_for=libliftoff,vkroots,wlroots,libdisplay-info"
    assert_output_contains "-Dprefix=/opt/ally-x20-steamos/gamescope"
    run hdr_gamescope_meson_args shared
    assert_success
    assert_output_contains "-Dforce_fallback_for=libliftoff,vkroots,wlroots"
    case "$output" in *libdisplay-info*) false ;; esac
    run hdr_gamescope_meson_args static
    assert_failure
}

@test "patch series: every listed patch exists, in order, with a license note" {
    run hdr_patch_series libdisplay-info
    assert_success
    [ "$(printf '%s\n' "$output" | grep -c .)" = 8 ]
    printf '%s\n' "$output" | head -n1 | grep -q '0001-cta-include-sys-types.h.patch$'
    printf '%s\n' "$output" | tail -n1 | grep -q '0008-info-search-CTA-blocks-in-DisplayID-v2-extensions.patch$'
    local p
    for p in $output; do grep -q '^SPDX-License-Identifier: MIT$' "$p"; done
    run hdr_patch_series gamescope
    assert_success
    [ "$(printf '%s\n' "$output" | grep -c .)" = 3 ]
    for p in $output; do grep -q '^SPDX-License-Identifier: BSD-2-Clause$' "$p"; done
    [ -f "$REPO_ROOT/patches/gamescope/LICENSE" ]
    [ -f "$REPO_ROOT/patches/libdisplay-info/LICENSE" ]
}

@test "patch series: a missing patch fails" {
    HDR_PATCH_DIR="$BATS_TEST_TMPDIR/patches"
    mkdir -p "$HDR_PATCH_DIR/gamescope"
    printf '0001-missing.patch\n' >"$HDR_PATCH_DIR/gamescope/series"
    run hdr_patch_series gamescope
    assert_failure
}

@test "build id: stable for the same inputs, changes with a patch or mode" {
    local a b c
    a=$(hdr_build_id gamescope cherry-pick)
    [ "$a" = "$(hdr_build_id gamescope cherry-pick)" ]
    [ "${#a}" = 16 ]
    c=$(hdr_build_id gamescope upstream)
    [ "$a" != "$c" ]
    cp -R "$REPO_ROOT/patches" "$BATS_TEST_TMPDIR/patches"
    HDR_PATCH_DIR="$BATS_TEST_TMPDIR/patches"
    printf '\n' >>"$HDR_PATCH_DIR/gamescope/0002-scripts-Add-ASUS-ROG-Xbox-Ally-X20-as-a-known-device.patch"
    b=$(hdr_build_id gamescope cherry-pick)
    [ "$a" != "$b" ]
    [ "$c" = "$(hdr_build_id gamescope upstream)" ]
    run hdr_build_id kwin
    assert_failure
}

@test "accepted flags: long and short names from gamescope's option table" {
    cat >"$BATS_TEST_TMPDIR/main.cpp" <<'EOF'
const char *gamescope_optstring = nullptr;
const struct option *gamescope_options = (struct option[]){
	{ "help", no_argument, nullptr, 0 },
	{ "nested-width", required_argument, nullptr, 'w' },
	{ "prefer-vk-device", required_argument, 0 },
	{ "fade-out-duration", required_argument, nullptr, 0 },
	{ "steam", no_argument, nullptr, 'e' },
	{ "prefer-output", required_argument, nullptr, 'O' },
	{} // keep last
};
static struct option other[] = { { "not-gamescope", no_argument, nullptr, 'z' } };
EOF
    run hdr_extract_accepted_flags "$BATS_TEST_TMPDIR/main.cpp"
    assert_success
    local want
    for want in --help --nested-width --prefer-vk-device --fade-out-duration --steam --prefer-output -w -e -O; do
        printf '%s\n' "$output" | grep -qx -- "$want"
    done
    case "$output" in *not-gamescope* | *-z*) false ;; esac
    run hdr_extract_accepted_flags "$BATS_TEST_TMPDIR/nope.cpp"
    assert_failure
}

@test "BUILD-INFO: version line first, then the given keys in order" {
    local f="$BATS_TEST_TMPDIR/out/BUILD-INFO"
    hdr_write_build_info "$f" component=gamescope build_id=abc gamescope_commit=d93118d
    run cat "$f"
    assert_equal "$output" "build_info_version=1
component=gamescope
build_id=abc
gamescope_commit=d93118d"
    run hdr_write_build_info "$f" not-a-pair
    assert_failure
}

@test "hdr-deps.txt lists packages one per line" {
    run grep -vcE '^(#|$)' "$REPO_ROOT/build/hdr-deps.txt"
    [ "$output" -gt 10 ]
    run grep -vE '^(#|$)' "$REPO_ROOT/build/hdr-deps.txt"
    case "$output" in *" "*) false ;; esac
}
