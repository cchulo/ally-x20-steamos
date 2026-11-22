#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# cmd/hdr.sh (status | fetch | build | remove) through the real CLI on a
# fixture root, with curl, podman and ldconfig stubbed on PATH; uninstall;
# the boot service's detached fetch; the CI job that builds the library.
load '../test_helper'
load '../hdr_helper'

setup() {
    make_root >/dev/null
    source_libs
    component_load hdr
    hdr_stub_bin
    hdr_stock 0.3.0
    export AX20_OFFLINE=0
    LIB="$AX20_ROOT$HDR_STATE/lib"
}

@test "hdr without a sub-command prints usage and exits 2; help lists it" {
    run "$CLI" hdr
    assert_failure 2
    assert_output_contains "usage: ally-x20-steamos hdr <status|fetch|build|remove>"
    run "$CLI" hdr --help
    assert_success
    assert_output_contains "Ctrl+Alt+F3"
    run "$CLI" hdr explode
    assert_failure 2
    run "$CLI" help
    assert_success
    assert_output_contains "  hdr "
}

@test "status before anything is installed: Game Mode and Desktop Mode, what SteamOS ships" {
    hdr_cli hdr status
    assert_success
    assert_output_contains "Game Mode (gamescope)"
    assert_output_contains "not installed (run: ally-x20-steamos apply --only hdr)"
    assert_output_contains "Desktop Mode (KDE/KWin)"
    assert_output_contains "libdisplay-info 0.3.0 (does not read the panel's HDR data; our library replaces it)"
    assert_output_contains "our library:       not installed"
    assert_output_contains "To get the current Desktop Mode library: sudo ally-x20-steamos hdr fetch"
}

@test "fetch downloads, verifies and installs; status shows build id and origin" {
    hdr_cli apply --only hdr
    assert_success
    hdr_fake_tarball "$HDR_SRV/versioned/$HDR_ART"
    hdr_cli hdr fetch
    assert_success
    assert_output_contains "Desktop Mode HDR library: release"
    assert_output_contains "build_id=$(hdr_build_id libdisplay-info)"
    assert_output_contains "sudo ally-x20-steamos hdr remove"
    [ "$(readlink "$LIB/libdisplay-info.so.3")" = "$HDR_REAL" ]
    hdr_lib_current
    manifest_verify "$HDR_STATE/lib/$HDR_REAL"
    # fixture root: the live system's ldconfig is not ours to run
    [ ! -e "$HDR_SRV/ldconfig-ran" ]
    hdr_cli hdr status
    assert_success
    assert_output_contains "installed ($HDR_LUA)"
    assert_output_contains "our library:       installed"
    assert_output_contains "build id:          $(hdr_build_id libdisplay-info)"
    assert_output_contains "came from:         release"
    assert_output_contains "/releases/download/v$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")/$HDR_ART"
    assert_output_contains "sudo ally-x20-steamos hdr remove"
    hdr_cli status
    assert_success
    [ "$(printf '%s\n' "$output" | awk '$1 == "hdr" { print $2 }')" = active ]
}

@test "fetch a second time is a cache hit and downloads nothing" {
    hdr_fake_tarball "$HDR_SRV/versioned/$HDR_ART"
    hdr_cli hdr fetch
    assert_success
    n=$(grep -c . "$HDR_SRV/curl.log")
    hdr_cli hdr fetch
    assert_success
    assert_output_contains "Desktop Mode HDR library: cache"
    [ "$(grep -c . "$HDR_SRV/curl.log")" = "$n" ]
}

@test "fetch offline fails cleanly, installs nothing and says Game Mode is not affected" {
    touch "$HDR_SRV/offline"
    hdr_cli hdr fetch
    assert_failure 1
    assert_output_contains "no Desktop Mode library was installed"
    assert_output_contains "Game Mode HDR is not affected"
    [ ! -e "$LIB" ]
}

@test "fetch refuses a download that fails its checksum" {
    hdr_fake_tarball "$HDR_SRV/versioned/$HDR_ART"
    printf '0000  x\n' >"$HDR_SRV/versioned/$HDR_ART.sha256"
    hdr_cli hdr fetch
    assert_failure 1
    assert_output_contains "fails its checksum; not installing it"
    [ ! -e "$LIB" ]
}

@test "fetch refuses a build for another libdisplay-info version" {
    hdr_fake_tarball "$HDR_SRV/versioned/$HDR_ART" "ELF" libdisplay_info_version=0.4.0 libdisplay_info_soname=libdisplay-info.so.4
    hdr_cli hdr fetch
    assert_failure 1
    assert_output_contains "is not for this checkout"
    [ ! -e "$LIB" ]
}

@test "fetch and build install nothing when SteamOS ships 0.4.0, and refuse another old version" {
    hdr_fake_tarball "$HDR_SRV/versioned/$HDR_ART"
    rm -rf "$AX20_ROOT/usr/lib"
    hdr_stock 0.4.0
    hdr_cli hdr fetch
    assert_success
    assert_output_contains "our library is not needed"
    hdr_cli hdr build
    assert_success
    [ ! -e "$LIB" ]
    [ ! -e "$HDR_SRV/curl.log" ] && [ ! -e "$HDR_SRV/podman.log" ]
    hdr_cli hdr status
    assert_output_contains "reads the HDR data itself; our library is not needed"
    rm -rf "$AX20_ROOT/usr/lib"
    hdr_stock 0.2.0
    hdr_cli hdr fetch
    assert_failure 1
    assert_output_contains "Nothing was installed"
    [ ! -e "$LIB" ]
}

@test "build runs the container build with podman and installs its output" {
    hdr_fake_build "$HDR_SRV/podman-artifact/$HDR_TOP" "ELF local build"
    hdr_cli hdr build
    assert_success
    assert_output_contains "Desktop Mode HDR library: container"
    [ "$(cat "$LIB/$HDR_REAL")" = "ELF local build" ]
    grep -q -- "-f $REPO_ROOT/build/Containerfile.hdr" "$HDR_SRV/podman.log"
    grep -q -- "--only libdisplay-info --destdir /out/stage --artifact-dir /out/artifact" "$HDR_SRV/podman.log"
    hdr_cli hdr status
    assert_output_contains "came from:         container"
}

@test "build: a failed container build or a wrong output installs nothing" {
    touch "$HDR_SRV/podman-fails"
    hdr_cli hdr build
    assert_failure 1
    assert_output_contains "the container build failed"
    rm "$HDR_SRV/podman-fails"
    hdr_fake_build "$HDR_SRV/podman-artifact/$HDR_TOP" "ELF" build_id=0000000000000000
    hdr_cli hdr build
    assert_failure 1
    [ ! -e "$LIB" ]
}

@test "remove takes the library out, keeps it out across apply, and fetch brings it back" {
    hdr_cli apply --only hdr
    hdr_fake_tarball "$HDR_SRV/versioned/$HDR_ART"
    hdr_cli hdr fetch
    assert_success
    hdr_cli hdr remove
    assert_success
    assert_output_contains "Removed our libdisplay-info"
    assert_output_contains "It stays out until you run: sudo ally-x20-steamos hdr fetch"
    [ ! -e "$LIB/$HDR_REAL" ] && [ ! -L "$LIB/libdisplay-info.so.3" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/libdisplay-info/BUILD-INFO" ]
    hdr_cli apply --verify-only --only hdr
    assert_success
    hdr_cli hdr status
    assert_output_contains "removed with 'ally-x20-steamos hdr remove'"
    # apply with downloads on does not bring it back
    run env PATH="$HDR_BIN:$PATH" AX20_HDR_AUTO_FETCH=1 "$CLI" --root "$AX20_ROOT" apply --only hdr
    assert_success
    assert_output_contains "stays out"
    [ ! -e "$LIB/$HDR_REAL" ]
    hdr_cli hdr fetch --auto
    assert_success
    [ ! -e "$LIB/$HDR_REAL" ]
    hdr_cli hdr fetch
    assert_success
    [ -f "$LIB/$HDR_REAL" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/state/hdr-desktop-disabled" ]
}

@test "remove with nothing installed says so and still records the choice" {
    hdr_cli hdr remove
    assert_success
    assert_output_contains "was not installed; nothing to remove"
    [ -f "$AX20_ROOT$HDR_STATE/state/hdr-desktop-disabled" ]
}

@test "fetch --auto is quiet and never fails: offline, no artifact, then a release" {
    touch "$HDR_SRV/offline"
    hdr_cli hdr fetch --auto
    assert_success
    rm "$HDR_SRV/offline"
    hdr_cli hdr fetch --auto
    assert_success
    [[ "$output" != *warning* ]] && [[ "$output" != *error* ]]
    [ ! -e "$LIB" ]
    hdr_fake_tarball "$HDR_SRV/latest/$HDR_ART"
    hdr_cli hdr fetch --auto
    assert_success
    hdr_lib_current
}

@test "apply with downloads on and no network exits 0 with the new notice" {
    touch "$HDR_SRV/offline"
    run env PATH="$HDR_BIN:$PATH" AX20_HDR_AUTO_FETCH=1 "$CLI" --root "$AX20_ROOT" apply --only hdr
    assert_success
    assert_output_contains "Game Mode HDR already works; this is only about Desktop Mode."
    assert_output_contains "'sudo ally-x20-steamos hdr fetch'"
    [[ "$output" != *"build/build-hdr.sh"* ]]
    [[ "$output" != *"not built yet"* ]]
}

@test "apply with downloads on installs the library in one go" {
    hdr_fake_tarball "$HDR_SRV/versioned/$HDR_ART"
    run env PATH="$HDR_BIN:$PATH" AX20_HDR_AUTO_FETCH=1 "$CLI" --root "$AX20_ROOT" apply --only hdr
    assert_success
    hdr_lib_current
    hdr_cli apply --verify-only --only hdr
    assert_success
}

@test "uninstall --component hdr removes the library and restores /etc" {
    before=$(cd "$AX20_ROOT" && find etc usr | LC_ALL=C sort)
    hdr_cli apply --only hdr
    hdr_fake_tarball "$HDR_SRV/versioned/$HDR_ART"
    hdr_cli hdr fetch
    assert_success
    hdr_cli uninstall --component hdr --keep-state
    assert_success
    assert_equal "$(cd "$AX20_ROOT" && find etc usr | LC_ALL=C sort)" "$before"
    [ ! -e "$LIB" ]
    [ ! -e "$AX20_ROOT$HDR_STATE/libdisplay-info" ]
    [ -z "$(manifest_paths hdr)" ]
}

@test "full uninstall after fetch leaves no trace of ours" {
    before=$(cd "$AX20_ROOT" && find . -path ./var/lib/ally-x20-steamos -prune -o -print | LC_ALL=C sort)
    hdr_cli apply --only hdr
    hdr_fake_tarball "$HDR_SRV/versioned/$HDR_ART"
    hdr_cli hdr fetch
    hdr_cli hdr remove
    hdr_cli hdr fetch
    assert_success
    hdr_cli uninstall
    assert_success
    [ ! -e "$AX20_ROOT$HDR_STATE" ]
    assert_equal "$(cd "$AX20_ROOT" && find . -print | LC_ALL=C sort)" "$before"
}

@test "boot service: starts a detached fetch only when one is due, and apply does not download during boot" {
    # shellcheck disable=SC1091
    . "$REPO_ROOT/cmd/boot.sh"
    run boot_kick_hdr_fetch
    assert_success
    [ -z "$output" ]
    component_apply hdr 2>/dev/null
    run boot_kick_hdr_fetch
    assert_success
    assert_output_contains "would start a detached fetch of the Desktop Mode HDR library"
    hdr_lib_set_disabled
    run boot_kick_hdr_fetch
    [ -z "$output" ]
    hdr_lib_clear_disabled
    hdr_fake_build "$BATS_TEST_TMPDIR/b"
    hdr_lib_stage "$BATS_TEST_TMPDIR/b" release 2>/dev/null
    run boot_kick_hdr_fetch
    [ -z "$output" ]
    grep -q '^    AX20_HDR_AUTO_FETCH=0$' "$REPO_ROOT/cmd/boot.sh"
    grep -q 'hdr fetch --auto' "$REPO_ROOT/cmd/boot.sh"
    grep -q -- '--no-block' "$REPO_ROOT/cmd/boot.sh"
}

@test "install and self-update get the library through apply" {
    grep -q 'su_run_cli "\$target" apply' "$REPO_ROOT/cmd/install.sh"
    grep -q 'su_run_cli "\$AX20_SRC" apply' "$REPO_ROOT/cmd/self-update.sh"
    grep -q 'hdr_apply_desktop_lib' "$REPO_ROOT/components/hdr.sh"
}

# ------------------------------------------------------------------ CI --

# job_block <name> : the lines of one job in build-modules.yml.
job_block() {
    awk -v j="  $1:" '$0 == j { on = 1; next } on && /^  [a-z_-]+:$/ { on = 0 } on' \
        "$REPO_ROOT/.github/workflows/build-modules.yml"
}

@test "CI: the hdr job builds only libdisplay-info in the build container and uploads the artifact" {
    block=$(job_block hdr)
    [ -n "$block" ]
    printf '%s\n' "$block" | grep -q -- '-f build/Containerfile build'
    printf '%s\n' "$block" | grep -q -- '-f build/Containerfile.hdr build'
    printf '%s\n' "$block" | grep -q -- '--only libdisplay-info --destdir /out/stage --artifact-dir /out/artifact'
    printf '%s\n' "$block" | grep -q 'hdr-libdisplay-info-\$ver'
    printf '%s\n' "$block" | grep -q 'sha256sum "\$name.tar.zst" >"\$name.tar.zst.sha256"'
    printf '%s\n' "$block" | grep -q 'BUILD-INFO'
    printf '%s\n' "$block" | grep -q 'actions/upload-artifact@v4'
    printf '%s\n' "$block" | grep -q 'if-no-files-found: error'
    # the names CI packs are the names the device asks for
    assert_equal "hdr-libdisplay-info-$(hdr_lock_get LDI_VERSION).tar.zst" "$(hdr_ldi_artifact_name)"
    assert_equal "libdisplay-info-$(hdr_lock_get LDI_VERSION)" "$(hdr_ldi_artifact_top)"
}

@test "CI: the one release job waits for the modules and the hdr job and attaches everything" {
    block=$(job_block release)
    printf '%s\n' "$block" | grep -qx '    needs: \[build, hdr\]'
    printf '%s\n' "$block" | grep -q 'merge-multiple: true'
    printf '%s\n' "$block" | grep -q 'gh release upload "\$TAG" .* dist/\*'
    # no other workflow creates or edits a release
    run grep -lE 'gh release (create|edit|upload)' "$REPO_ROOT"/.github/workflows/*.yml
    assert_equal "$output" "$REPO_ROOT/.github/workflows/build-modules.yml"
}

@test "CI: the workflow runs for the HDR sources on push and pull request, and still for the modules" {
    w="$REPO_ROOT/.github/workflows/build-modules.yml"
    [ "$(grep -c "      - 'patches/libdisplay-info/\*\*'" "$w")" = 2 ]
    [ "$(grep -c "      - 'build/\*\*'" "$w")" = 2 ]
    [ "$(grep -c "      - 'patches/kernel/\*\*'" "$w")" = 2 ]
    grep -q "tags: \['v\*'\]" "$w"
    job_block build | grep -q 'modules-\$KVER.tar.zst'
}

@test "the HDR image adds meson, ninja and hwdata to the module build image" {
    f="$REPO_ROOT/build/Containerfile.hdr"
    grep -q '^FROM \${BASE_IMAGE}$' "$f"
    grep -q 'pacman -Sy --noconfirm --needed meson ninja hwdata' "$f"
    grep -q '^ENTRYPOINT \["/src/build/build-hdr.sh"\]$' "$f"
}
