#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/hdr.sh and overlay/bin/gamescope against fixture roots.
load '../test_helper'

setup() {
    make_root >/dev/null
    source_libs
    component_load hdr
}

# ------------------------------------------------------------- fixtures --

# stock_ldi <version> [pc] : stock libdisplay-info as SteamOS packages it
# (real file .so.0.X.Y, soname link .so.<minor>), optionally with a .pc file.
stock_ldi() {
    local v=$1 minor
    minor=$(printf '%s' "$v" | cut -d. -f2)
    fixture_file "/usr/lib/libdisplay-info.so.$v" "ELF libdisplay-info $v"
    ln -sf "libdisplay-info.so.$v" "$AX20_ROOT/usr/lib/libdisplay-info.so.$minor"
    if [ "${2:-}" = pc ]; then
        fixture_file /usr/lib/pkgconfig/libdisplay-info.pc "prefix=/usr
Name: libdisplay-info
Version: $v
Libs: -ldisplay-info"
    fi
}

# stock_gamescope [binary-content] : /usr/bin/gamescope plus the 3.16.30.1
# Lua helpers our drop-in profile relies on.
stock_gamescope() {
    fixture_file /usr/bin/gamescope "${1:-ELF gamescope 3.16.30.1}"
    fixture_file /usr/share/gamescope/scripts/00-gamescope/common/modegen.lua \
        "gamescope.modegen.adjust_front_porch = function(mode, vfp) end
gamescope.modegen.calc_vrefresh = function(mode, refresh) end"
    fixture_file /usr/share/gamescope/scripts/00-gamescope/common/util.lua \
        "function zero_index(index) return index + 1 end"
    fixture_file /usr/share/gamescope/scripts/00-gamescope/displays/lenovo.legiongo2.oled.lua "-- go 2"
}

stock_profile() {
    fixture_file /usr/share/gamescope/scripts/00-gamescope/displays/asus.rogallyx20.oled.lua \
        "gamescope.config.known_displays.rogallyx20_oled = {}"
}

our_lib() {
    fixture_file /var/lib/ally-x20-steamos/lib/libdisplay-info.so.0.3.0 "ELF backport"
    ln -sf libdisplay-info.so.0.3.0 "$AX20_ROOT/var/lib/ally-x20-steamos/lib/libdisplay-info.so.3"
}

# our_build : a fake gamescope build under /opt.
our_build() {
    local p="$AX20_ROOT/opt/ally-x20-steamos/gamescope"
    mkdir -p "$p/bin" "$p/share/ally-x20-steamos"
    cat >"$p/bin/gamescope" <<EOF
#!/bin/bash
if [ "\$1" = --help ]; then
    printf 'help\n' >>"$BATS_TEST_TMPDIR/help-calls"
    cat >&2 <<'USAGE'
usage: gamescope [options...] -- [command...]

Options:
  --help                         show help message
  -W, --output-width             output width
  -w, --nested-width             game width
  -h, --nested-height            game height
  -m, --max-scale                maximum scale factor
  -F, --filter                   upscaler filter (linear, nearest, fsr, nis, pixel, sgsr)
                                     fsr => AMD FidelityFX Super Resolution 1.0
  --sharpness, --fsr-sharpness   upscaler sharpness from 0 (max) to 20 (min)
  -R, --ready-fd                 notify FD when ready
  -T, --stats-path               write statistics to path
  -C, --hide-cursor-delay        hide cursor image after delay
  -e, --steam                    enable Steam integration
  --xwayland-count               create N xwayland servers
  -O, --prefer-output            list of connectors in order of preference
  --default-touch-mode           0: hover, 1: left, 2: right, 3: middle, 4: passthrough
  --generate-drm-mode            DRM mode generation algorithm (cvt, fixed)
USAGE
    exit 0
fi
printf 'OURS LD=%s PATH=%s ARGS=%s\n' "\${LD_LIBRARY_PATH:-}" "\$PATH" "\$*" >"$BATS_TEST_TMPDIR/out"
EOF
    chmod 0755 "$p/bin/gamescope"
    printf 'build_info_version=1\ncomponent=gamescope\nbuild_id=abc123\ngamescope_libdisplay_info=bundled\n' >"$p/BUILD-INFO"
    printf -- '--fade-out-duration\n--generate-drm-mode\n-e\n' >"$p/share/ally-x20-steamos/accepted-flags"
}

# wrapper_setup : install the wrapper where apply puts it and a stub stock
# gamescope on PATH after it.
wrapper_setup() {
    WRAPPER_DIR="$AX20_ROOT/var/lib/ally-x20-steamos/bin"
    STOCK_DIR="$BATS_TEST_TMPDIR/stock-bin"
    mkdir -p "$WRAPPER_DIR" "$STOCK_DIR" "$AX20_ROOT/var/lib/ally-x20-steamos/state"
    cp "$REPO_ROOT/overlay/bin/gamescope" "$WRAPPER_DIR/gamescope"
    chmod 0755 "$WRAPPER_DIR/gamescope"
    cat >"$STOCK_DIR/gamescope" <<EOF
#!/bin/bash
printf 'STOCK PATH=%s ARGS=%s\n' "\$PATH" "\$*" >"$BATS_TEST_TMPDIR/out"
EOF
    chmod 0755 "$STOCK_DIR/gamescope"
    WRAP_PATH="$WRAPPER_DIR:$STOCK_DIR:/usr/bin:/bin"
}

# The flags SteamOS 3.9's /usr/lib/steamos/gamescope-session passes.
SESSION_FLAGS=(--generate-drm-mode fixed --xwayland-count 2 -w 1280 -h 800
    --default-touch-mode 4 --hide-cursor-delay 3000 --max-scale 2
    --fade-out-duration 200 -e -R /run/user/1000/startup.socket
    -T /run/user/1000/stats.pipe -O '*,eDP-1')

run_wrapper() {
    run env PATH="$WRAP_PATH" AX20_ROOT="$AX20_ROOT" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg" \
        "$WRAPPER_DIR/gamescope" "$@"
}

status_file() { cat "$AX20_ROOT/var/lib/ally-x20-steamos/state/gamescope-status.txt"; }

# ---------------------------------------------------------------- probe --

@test "probe: unknown (2) when stock gamescope is missing" {
    stock_ldi 0.4.0 pc
    run hdr_probe
    assert_failure 2
}

@test "probe: unknown (2) when no stock libdisplay-info can be found" {
    stock_gamescope
    stock_profile
    run hdr_probe
    assert_failure 2
}

@test "probe: still needed on SteamOS 3.9 (0.3.0, soname .so.3, no X20 profile)" {
    stock_gamescope
    stock_ldi 0.3.0
    run hdr_stock_ldi_version
    assert_success
    assert_equal "$output" 0.3.0
    run hdr_probe
    assert_failure 1
}

@test "probe: still needed when libdisplay-info is new but gamescope lacks the profile" {
    stock_gamescope
    stock_ldi 0.4.0 pc
    run hdr_probe
    assert_failure 1
}

@test "probe: still needed when gamescope has the profile but libdisplay-info is 0.3.0" {
    stock_gamescope
    stock_profile
    stock_ldi 0.3.0 pc
    run hdr_probe
    assert_failure 1
}

@test "probe: superseded when stock has libdisplay-info >= 0.4.0 and the X20 profile" {
    stock_gamescope
    stock_profile
    stock_ldi 0.4.0
    run hdr_probe
    assert_success
}

@test "probe: superseded when the stock binary names the AMS740LS02 and the .pc says 0.4.1" {
    stock_gamescope "ELF ... AMS740LS02 ..."
    stock_ldi 0.4.1 pc
    run hdr_probe
    assert_success
}

@test "probe: .pc version wins over file names" {
    stock_gamescope
    stock_ldi 0.3.0
    fixture_file /usr/lib/pkgconfig/libdisplay-info.pc "Version: 0.4.0"
    [ "$(hdr_stock_ldi_version)" = 0.4.0 ]
}

@test "probe_details prints libdisplay_info and gamescope lines" {
    stock_gamescope
    stock_ldi 0.3.0
    run hdr_probe_details
    assert_success
    assert_output_contains "libdisplay_info=0.3.0 (< 0.4.0, needs backport)"
    assert_output_contains "gamescope=no X20 profile (drop-in profile applies)"
}

@test "probe_details reports missing files" {
    run hdr_probe_details
    assert_output_contains "libdisplay_info=missing"
    assert_output_contains "gamescope=missing"
}

# ---------------------------------------------------------------- apply --

@test "apply on stock 3.9 installs the ld.so.conf.d drop-in and the Lua profile only" {
    stock_gamescope
    stock_ldi 0.3.0
    component_apply hdr
    cmp "$AX20_ROOT/etc/ld.so.conf.d/00-ally-x20-steamos.conf" "$REPO_ROOT/overlay/ld.so.conf.d/00-ally-x20-steamos.conf"
    cmp "$AX20_ROOT/etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua" \
        "$REPO_ROOT/overlay/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua"
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/bin/gamescope" ]
    [ ! -e "$AX20_ROOT/etc/systemd/user/gamescope-session.service.d/50-ally-x20-steamos.conf" ]
}

@test "the ld.so.conf.d drop-in points at the lib dir the build installs into" {
    run grep -vE '^(#|$)' "$REPO_ROOT/overlay/ld.so.conf.d/00-ally-x20-steamos.conf"
    assert_equal "$output" "/var/lib/ally-x20-steamos/lib"
}

@test "apply skips the Lua profile when stock gamescope already ships it" {
    stock_gamescope
    stock_profile
    stock_ldi 0.3.0
    component_apply hdr
    [ -f "$AX20_ROOT/etc/ld.so.conf.d/00-ally-x20-steamos.conf" ]
    [ ! -e "$AX20_ROOT/etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua" ]
}

@test "apply skips the Lua profile when stock Lua helpers are missing" {
    fixture_file /usr/bin/gamescope "ELF"
    stock_ldi 0.3.0
    component_apply hdr
    [ ! -e "$AX20_ROOT/etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua" ]
}

@test "apply installs wrapper, session drop-in, status file and flag cache when our build exists" {
    stock_gamescope
    stock_ldi 0.3.0
    our_build
    component_apply hdr
    local w="$AX20_ROOT/var/lib/ally-x20-steamos/bin/gamescope"
    [ -x "$w" ]
    cmp "$w" "$REPO_ROOT/overlay/bin/gamescope"
    grep -q '^Environment=PATH=/var/lib/ally-x20-steamos/bin:' \
        "$AX20_ROOT/etc/systemd/user/gamescope-session.service.d/50-ally-x20-steamos.conf"
    local s="$AX20_ROOT/var/lib/ally-x20-steamos/state/gamescope-status.txt"
    [ -f "$s" ]
    [ "$(stat -c %a "$s" 2>/dev/null || stat -f %Lp "$s")" = 666 ]
    local c="$AX20_ROOT/var/lib/ally-x20-steamos/state/gamescope-flags.cache"
    [ "$(head -n1 "$c")" = build_id=abc123 ]
    grep -qx -- '--fade-out-duration' "$c"
    grep -qx -- '--output-width' "$c"
    grep -qx -- '-O' "$c"
}

@test "apply never installs the wrapper when stock gamescope has the X20 profile" {
    stock_gamescope
    stock_profile
    stock_ldi 0.3.0
    our_build
    component_apply hdr
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/bin/gamescope" ]
}

@test "dry-run apply writes nothing" {
    stock_gamescope
    stock_ldi 0.3.0
    our_build
    AX20_DRY_RUN=1
    component_apply hdr 2>/dev/null
    [ ! -e "$AX20_ROOT/etc/ld.so.conf.d" ]
    [ ! -e "$AX20_ROOT/etc/gamescope" ]
    [ ! -e "$AX20_ROOT/etc/systemd" ]
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/bin" ]
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/state" ]
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/manifest" ]
}

@test "apply is idempotent" {
    stock_gamescope
    stock_ldi 0.3.0
    our_build
    component_apply hdr
    component_apply hdr
    [ "$(manifest_paths hdr | grep -c '00-ally-x20-steamos.conf')" = 1 ]
    [ "$(manifest_paths hdr | grep -c 'rogallyx20-oled.lua')" = 1 ]
    [ "$(manifest_paths hdr | grep -c 'bin/gamescope$')" = 1 ]
}

@test "manifest round-trip: every installed path is recorded and verifies" {
    stock_gamescope
    stock_ldi 0.3.0
    our_build
    component_apply hdr
    local p n=0
    for p in $(manifest_paths hdr); do
        manifest_verify "$p"
        n=$((n + 1))
    done
    # 4 files + created dirs
    [ "$(manifest_entries | _manifest_select kind file | _manifest_field path | grep -c .)" = 4 ]
    [ "$n" -gt 4 ]
    manifest_paths hdr | grep -qx /etc/ld.so.conf.d/00-ally-x20-steamos.conf
    manifest_paths hdr | grep -qx /etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua
    manifest_paths hdr | grep -qx /var/lib/ally-x20-steamos/bin/gamescope
    manifest_paths hdr | grep -qx /etc/systemd/user/gamescope-session.service.d/50-ally-x20-steamos.conf
}

@test "every path hdr installs carries the ally-x20-steamos name and is outside /usr" {
    stock_gamescope
    stock_ldi 0.3.0
    our_build
    run hdr_files
    assert_success
    printf '%s\n' "$output" | while IFS=$'\t' read -r src dest mode slot; do
        case "$dest" in /usr/*) false ;; esac
        case "$dest" in *ally-x20-steamos*) ;; *) false ;; esac
    done
}

@test "apply does not run ldconfig on a fixture root" {
    stock_gamescope
    stock_ldi 0.3.0
    mkdir -p "$BATS_TEST_TMPDIR/fakebin"
    printf '#!/bin/sh\ntouch "%s/ldconfig-ran"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/fakebin/ldconfig"
    chmod +x "$BATS_TEST_TMPDIR/fakebin/ldconfig"
    PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" component_apply hdr
    [ ! -e "$BATS_TEST_TMPDIR/ldconfig-ran" ]
}

# --------------------------------------------------------------- status --

@test "status: stock before apply, stock when the library is not built, active when it is" {
    stock_gamescope
    stock_ldi 0.3.0
    [ "$(hdr_status 2>/dev/null)" = stock ]
    component_apply hdr 2>/dev/null
    [ "$(hdr_status 2>/dev/null)" = stock ]
    run hdr_status
    assert_output_contains "not built"
    our_lib
    [ "$(hdr_status 2>/dev/null)" = active ]
}

@test "status: stock when ld.so.cache exists but does not list our library" {
    stock_gamescope
    stock_ldi 0.3.0
    our_lib
    component_apply hdr 2>/dev/null
    fixture_file /etc/ld.so.cache "glibc-ld.so.cache1.1 /usr/lib/libdisplay-info.so.3"
    [ "$(hdr_status 2>/dev/null)" = stock ]
    fixture_file /etc/ld.so.cache "glibc-ld.so.cache1.1 /var/lib/ally-x20-steamos/lib/libdisplay-info.so.3 /usr/lib/libdisplay-info.so.3"
    [ "$(hdr_status 2>/dev/null)" = active ]
}

@test "status: superseded when the probe says so" {
    stock_gamescope
    stock_ldi 0.3.0
    component_apply hdr 2>/dev/null
    stock_profile
    fixture_file /usr/lib/pkgconfig/libdisplay-info.pc "Version: 0.4.0"
    [ "$(hdr_status 2>/dev/null)" = superseded ]
}

@test "status: drift (edited drop-in) reports stock" {
    stock_gamescope
    stock_ldi 0.3.0
    our_lib
    component_apply hdr 2>/dev/null
    printf '/tmp\n' >"$AX20_ROOT/etc/ld.so.conf.d/00-ally-x20-steamos.conf"
    [ "$(hdr_status 2>/dev/null)" = stock ]
}

@test "status: surfaces a gamescope fallback from the wrapper's status file" {
    stock_gamescope
    stock_ldi 0.3.0
    our_lib
    our_build
    component_apply hdr 2>/dev/null
    printf 'selection=stock\nreason=custom build does not accept session flag --new\n' \
        >"$AX20_ROOT/var/lib/ally-x20-steamos/state/gamescope-status.txt"
    run hdr_status
    assert_success
    assert_output_contains "fell back to stock gamescope: custom build does not accept session flag --new"
    [ "$(hdr_status 2>/dev/null)" = active ]
}

@test "remove hook deletes the wrapper's runtime files only" {
    stock_gamescope
    stock_ldi 0.3.0
    our_build
    component_apply hdr
    hdr_remove
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/state/gamescope-status.txt" ]
    [ ! -e "$AX20_ROOT/var/lib/ally-x20-steamos/state/gamescope-flags.cache" ]
    [ -f "$AX20_ROOT/var/lib/ally-x20-steamos/bin/gamescope" ]
}

# -------------------------------------------------------------- wrapper --

@test "wrapper: session flags known to our build => ours is exec'd, our dir leaves PATH" {
    our_build
    wrapper_setup
    run_wrapper "${SESSION_FLAGS[@]}"
    assert_success
    run cat "$BATS_TEST_TMPDIR/out"
    assert_output_contains "OURS LD= "
    assert_output_contains "ARGS=--generate-drm-mode fixed --xwayland-count 2"
    case "$output" in *"$WRAPPER_DIR"*) false ;; esac
    run status_file
    assert_output_contains "selection=ours"
    assert_output_contains "build_id=abc123"
}

@test "wrapper: unknown flag => stock is exec'd and the status file says why" {
    our_build
    wrapper_setup
    run_wrapper "${SESSION_FLAGS[@]}" --brand-new-flag 1
    assert_success
    run cat "$BATS_TEST_TMPDIR/out"
    assert_output_contains "STOCK"
    assert_output_contains "--brand-new-flag 1"
    case "$output" in *"$WRAPPER_DIR"*) false ;; esac
    run status_file
    assert_output_contains "selection=stock"
    assert_output_contains "reason=custom build does not accept session flag --brand-new-flag"
}

@test "wrapper: unknown short flag => stock" {
    our_build
    wrapper_setup
    run_wrapper -e -Z
    run status_file
    assert_output_contains "session flag -Z"
}

@test "wrapper: a flag only in the source option table (not in --help) is accepted" {
    our_build
    wrapper_setup
    run_wrapper --fade-out-duration 200 -e
    run status_file
    assert_output_contains "selection=ours"
    rm "$AX20_ROOT/opt/ally-x20-steamos/gamescope/share/ally-x20-steamos/accepted-flags"
    rm -f "$AX20_ROOT/var/lib/ally-x20-steamos/state/gamescope-flags.cache"
    run_wrapper --fade-out-duration 200 -e
    run status_file
    assert_output_contains "selection=stock"
}

@test "wrapper: arguments after -- are the command, not flags" {
    our_build
    wrapper_setup
    run_wrapper -e -- steam --not-a-gamescope-flag
    run status_file
    assert_output_contains "selection=ours"
}

@test "wrapper: missing build => stock" {
    wrapper_setup
    run_wrapper "${SESSION_FLAGS[@]}"
    assert_success
    run cat "$BATS_TEST_TMPDIR/out"
    assert_output_contains "STOCK"
    run status_file
    assert_output_contains "reason=no custom build"
}

@test "wrapper: build without BUILD-INFO => stock" {
    our_build
    rm "$AX20_ROOT/opt/ally-x20-steamos/gamescope/BUILD-INFO"
    wrapper_setup
    run_wrapper -e
    run status_file
    assert_output_contains "reason=custom build has no valid BUILD-INFO"
}

@test "wrapper: our build failing --help => stock" {
    our_build
    printf '#!/bin/sh\nexit 1\n' >"$AX20_ROOT/opt/ally-x20-steamos/gamescope/bin/gamescope"
    wrapper_setup
    run_wrapper -e
    run cat "$BATS_TEST_TMPDIR/out"
    assert_output_contains "STOCK"
    run status_file
    assert_output_contains "failed to run --help"
}

@test "wrapper: internal error => stock" {
    our_build
    wrapper_setup
    run env PATH="$WRAP_PATH" AX20_ROOT="$AX20_ROOT" AX20_GAMESCOPE_WRAPPER_FAULT=1 \
        "$WRAPPER_DIR/gamescope" -e
    assert_success
    run cat "$BATS_TEST_TMPDIR/out"
    assert_output_contains "STOCK"
    run status_file
    assert_output_contains "reason=wrapper error"
}

@test "wrapper: stock profile present => stock (superseded)" {
    our_build
    stock_profile
    wrapper_setup
    run_wrapper -e
    run status_file
    assert_output_contains "selection=stock"
    assert_output_contains "superseded"
}

@test "wrapper: AX20_GAMESCOPE_DISABLE=1 => stock" {
    our_build
    wrapper_setup
    run env PATH="$WRAP_PATH" AX20_ROOT="$AX20_ROOT" AX20_GAMESCOPE_DISABLE=1 "$WRAPPER_DIR/gamescope" -e
    run status_file
    assert_output_contains "reason=disabled"
}

@test "wrapper: --help runs once per build id, then the cache is used" {
    our_build
    wrapper_setup
    run_wrapper -e
    run_wrapper -e
    run_wrapper -e
    [ "$(grep -c help "$BATS_TEST_TMPDIR/help-calls")" = 1 ]
    sed -i.bak 's/build_id=abc123/build_id=def456/' "$AX20_ROOT/opt/ally-x20-steamos/gamescope/BUILD-INFO"
    run_wrapper -e
    [ "$(grep -c help "$BATS_TEST_TMPDIR/help-calls")" = 2 ]
    [ "$(head -n1 "$AX20_ROOT/var/lib/ally-x20-steamos/state/gamescope-flags.cache")" = build_id=def456 ]
}

@test "wrapper: shared libdisplay-info build gets LD_LIBRARY_PATH, bundled does not" {
    our_build
    wrapper_setup
    run_wrapper -e
    run cat "$BATS_TEST_TMPDIR/out"
    assert_output_contains "OURS LD= "
    sed -i.bak 's/gamescope_libdisplay_info=bundled/gamescope_libdisplay_info=shared/' \
        "$AX20_ROOT/opt/ally-x20-steamos/gamescope/BUILD-INFO"
    run_wrapper -e
    run cat "$BATS_TEST_TMPDIR/out"
    assert_output_contains "OURS LD=$AX20_ROOT/var/lib/ally-x20-steamos/lib PATH="
}

@test "wrapper: unwritable state dir => status and cache go to XDG_RUNTIME_DIR" {
    [ "$(id -u)" != 0 ] || skip "root can write anywhere"
    our_build
    wrapper_setup
    chmod 0555 "$AX20_ROOT/var/lib/ally-x20-steamos/state"
    run_wrapper --brand-new-flag
    chmod 0755 "$AX20_ROOT/var/lib/ally-x20-steamos/state"
    run cat "$BATS_TEST_TMPDIR/out"
    assert_output_contains "STOCK"
    grep -q 'selection=stock' "$BATS_TEST_TMPDIR/xdg/ally-x20-steamos/gamescope-status.txt"
    [ "$(head -n1 "$BATS_TEST_TMPDIR/xdg/ally-x20-steamos/gamescope-flags.cache")" = build_id=abc123 ]
}

@test "wrapper: never loops back to itself when it is the only gamescope on PATH" {
    wrapper_setup
    mkdir -p "$AX20_ROOT/usr/bin"
    printf '#!/bin/sh\nprintf "ROOT-STOCK %%s\\n" "$*" >"%s/out"\n' "$BATS_TEST_TMPDIR" >"$AX20_ROOT/usr/bin/gamescope"
    chmod 0755 "$AX20_ROOT/usr/bin/gamescope"
    run env PATH="$WRAPPER_DIR:/nonexistent" AX20_ROOT="$AX20_ROOT" "$WRAPPER_DIR/gamescope" -e
    assert_success
    run cat "$BATS_TEST_TMPDIR/out"
    assert_equal "$output" "ROOT-STOCK -e"
}
