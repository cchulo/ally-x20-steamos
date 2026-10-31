# SPDX-License-Identifier: GPL-2.0-only
# components/hdr.sh — HDR for the AMS740LS02 OLED panel, userspace only (plan §1.4).
#
# Three independent pieces, all drop-ins (docs/hdr.md):
#   1. /etc/ld.so.conf.d/00-ally-x20-steamos.conf selects our
#      libdisplay-info.so.3 (0.3.0 + DisplayID 2 CTA backport, built by
#      build/build-hdr.sh into /var/lib/ally-x20-steamos/lib). Fixes Desktop
#      Mode (KWin). Stock gamescope links libdisplay-info statically and is
#      not affected.
#   2. /etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua, the
#      upstream X20 display profile from gamescope PR #2493. Stock gamescope
#      (3.16.30.1) loads it and gets HDR, the 30-120 Hz range and the
#      software backlight without a rebuild. Installed only when the stock
#      Lua helpers it needs are present and stock lacks the profile.
#   3. Only when our gamescope build exists: the wrapper
#      /var/lib/ally-x20-steamos/bin/gamescope plus a gamescope-session user
#      unit drop-in putting it first on PATH. The wrapper runs our build if
#      it accepts every session flag, else stock (status file says why).

# shellcheck disable=SC2034 # read by lib/component.sh
COMPONENT_DESCRIPTION="HDR for the AMS740LS02 OLED: libdisplay-info DisplayID 2 backport (Desktop) + gamescope X20 profile (Game Mode)"

HDR_LDI_MIN_VERSION=0.4.0
HDR_LDI_SONAME=libdisplay-info.so.3
HDR_LIB_DIR="$AX20_STATE_REL/lib"
HDR_GAMESCOPE_PREFIX="${HDR_GAMESCOPE_PREFIX:-$AX20_OPT_REL/gamescope}"
HDR_STOCK_GAMESCOPE=/usr/bin/gamescope
HDR_STOCK_SCRIPTS=/usr/share/gamescope/scripts/00-gamescope
HDR_STOCK_PROFILE="$HDR_STOCK_SCRIPTS/displays/asus.rogallyx20.oled.lua"
HDR_STOCK_LDI_DIR=/usr/lib
HDR_STOCK_LDI_PC=/usr/lib/pkgconfig/libdisplay-info.pc
HDR_LDCONF=/etc/ld.so.conf.d/00-ally-x20-steamos.conf
HDR_LUA=/etc/gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua
HDR_WRAPPER="$AX20_STATE_REL/bin/gamescope"
HDR_SESSION_DROPIN=/etc/systemd/user/gamescope-session.service.d/50-ally-x20-steamos.conf
HDR_STATUS_FILE="$AX20_STATE_REL/state/gamescope-status.txt"
HDR_FLAGS_CACHE="$AX20_STATE_REL/state/gamescope-flags.cache"

# ---------------------------------------------------------------- helpers --

# hdr_stock_ldi_version : stock libdisplay-info version (e.g. 0.3.0).
# Prefers the .pc file; otherwise the real file name libdisplay-info.so.0.X.Y.
# probe_soname_version is not used on purpose: the soname link
# (libdisplay-info.so.3) sorts above 0.3.0 and would read as version "3".
# Exit codes follow the probe contract (2 = no stock library found).
hdr_stock_ldi_version() {
    local pc dir f v best=""
    pc=$(ax20_path "$HDR_STOCK_LDI_PC")
    if [ -f "$pc" ]; then
        v=$(sed -n 's/^Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$pc" | head -n1)
        if [ -n "$v" ]; then
            printf '%s\n' "$v"
            return "$PROBE_YES"
        fi
    fi
    dir=$(ax20_path "$HDR_STOCK_LDI_DIR")
    [ -d "$dir" ] || return "$PROBE_UNKNOWN"
    for f in "$dir"/libdisplay-info.so.*.*.*; do
        [ -e "$f" ] || continue
        v=${f##*/libdisplay-info.so.}
        case "$v" in *[!0-9.]*) continue ;; esac
        if [ -z "$best" ] || ax20_version_ge "$v" "$best"; then
            best=$v
        fi
    done
    [ -n "$best" ] || return "$PROBE_UNKNOWN"
    printf '%s\n' "$best"
    return "$PROBE_YES"
}

# hdr_stock_has_profile : 0 if stock gamescope ships the X20 display profile.
# PR #2493 adds it as a Lua script (matching EDID vendor SDC, product
# 0x4501); the panel name AMS740LS02 from the plan is accepted too in case a
# later build embeds it in the binary.
hdr_stock_has_profile() {
    local d
    [ -f "$(ax20_path "$HDR_STOCK_PROFILE")" ] && return 0
    d=$(ax20_path "$HDR_STOCK_SCRIPTS/displays")
    if [ -d "$d" ] && grep -rlqF 'rogallyx20' "$d" 2>/dev/null; then
        return 0
    fi
    probe_file_contains "$HDR_STOCK_GAMESCOPE" AMS740LS02 && return 0
    return 1
}

# hdr_stock_lua_compatible : stock gamescope's Lua helpers that our profile
# calls (same ones the stock Legion Go 2 OLED profile uses).
hdr_stock_lua_compatible() {
    probe_file_contains "$HDR_STOCK_SCRIPTS/common/modegen.lua" adjust_front_porch || return 1
    probe_file_contains "$HDR_STOCK_SCRIPTS/common/modegen.lua" calc_vrefresh || return 1
    probe_file_contains "$HDR_STOCK_SCRIPTS/common/util.lua" zero_index || return 1
    return 0
}

hdr_lua_wanted() {
    hdr_stock_has_profile && return 1
    hdr_stock_lua_compatible
}

# hdr_build_present : our gamescope build (bin + BUILD-INFO) exists.
hdr_build_present() {
    [ -x "$(ax20_path "$HDR_GAMESCOPE_PREFIX/bin/gamescope")" ] \
        && [ -f "$(ax20_path "$HDR_GAMESCOPE_PREFIX/BUILD-INFO")" ]
}

hdr_wrapper_wanted() {
    hdr_stock_has_profile && return 1
    hdr_build_present
}

# hdr_lib_present : our backported libdisplay-info.so.3 is in the lib dir.
hdr_lib_present() {
    [ -e "$(ax20_path "$HDR_LIB_DIR/$HDR_LDI_SONAME")" ]
}

# hdr_ldcache_ok : 0 if ld.so.cache resolves our copy, 1 if it does not, 2
# if there is no cache to look at (fixture roots). ld.so.cache stores full
# paths, so a fixed-string search is enough.
# TODO(vm): confirm that the cache entry for our directory comes before the
# stock /usr/lib one (`ldconfig -p | grep libdisplay-info.so.3`).
hdr_ldcache_ok() {
    local cache
    cache=$(ax20_path /etc/ld.so.cache)
    [ -f "$cache" ] || return 2
    grep -aFq "$HDR_LIB_DIR/$HDR_LDI_SONAME" "$cache" && return 0
    return 1
}

# hdr_gamescope_status_line <key> : value from the wrapper's status file.
hdr_gamescope_status_line() {
    local f
    f=$(ax20_path "$HDR_STATUS_FILE")
    [ -f "$f" ] || return 1
    sed -n "s/^$1=//p" "$f" | head -n1
}

# ------------------------------------------------------------- contract --

hdr_files() {
    printf 'ld.so.conf.d/00-ally-x20-steamos.conf\t%s\t0644\tshared\n' "$HDR_LDCONF"
    if hdr_lua_wanted; then
        printf 'gamescope/scripts/90-ally-x20-steamos-rogallyx20-oled.lua\t%s\t0644\tshared\n' "$HDR_LUA"
    fi
    if hdr_wrapper_wanted; then
        printf 'bin/gamescope\t%s\t0755\tshared\n' "$HDR_WRAPPER"
        printf 'systemd/user/gamescope-session.service.d/50-ally-x20-steamos.conf\t%s\t0644\tshared\n' "$HDR_SESSION_DROPIN"
    fi
}

# hdr_probe : 0 when stock SteamOS has both halves (libdisplay-info >= 0.4.0
# for KWin and the X20 profile in stock gamescope), 1 otherwise, 2 when the
# stock files are missing.
hdr_probe() {
    local v rc
    [ -e "$(ax20_path "$HDR_STOCK_GAMESCOPE")" ] || return "$PROBE_UNKNOWN"
    v=$(hdr_stock_ldi_version)
    rc=$?
    [ "$rc" = "$PROBE_YES" ] || return "$PROBE_UNKNOWN"
    probe_version_ge "$v" "$HDR_LDI_MIN_VERSION" || return "$PROBE_NO"
    hdr_stock_has_profile || return "$PROBE_NO"
    return "$PROBE_YES"
}

# hdr_probe_details : key=value lines for `probe`/`status --verbose`.
hdr_probe_details() {
    local v gs
    v=$(hdr_stock_ldi_version) || v=missing
    if [ "$v" != missing ]; then
        if ax20_version_ge "$v" "$HDR_LDI_MIN_VERSION"; then
            v="$v (>= $HDR_LDI_MIN_VERSION, searches DisplayID 2)"
        else
            v="$v (< $HDR_LDI_MIN_VERSION, needs backport)"
        fi
    fi
    if ! [ -e "$(ax20_path "$HDR_STOCK_GAMESCOPE")" ]; then
        gs=missing
    elif hdr_stock_has_profile; then
        gs="stock has X20 profile"
    elif hdr_stock_lua_compatible; then
        gs="no X20 profile (drop-in profile applies)"
    else
        gs="no X20 profile, Lua helpers missing (needs custom build)"
    fi
    printf 'libdisplay_info=%s\n' "$v"
    printf 'gamescope=%s\n' "$gs"
}

hdr_apply() {
    local status
    if hdr_wrapper_wanted; then
        status=$(ax20_path "$HDR_STATUS_FILE")
        if [ "$AX20_DRY_RUN" = 1 ]; then
            printf '[dry-run] prepare %s and the gamescope flag cache\n' "$status" >&2
        else
            # The wrapper runs as the session user: the status file must be
            # writable by it. It only ever holds informational text.
            mkdir -p "$(dirname "$status")" || return 1
            [ -f "$status" ] || : >"$status" || return 1
            chmod 0666 "$status" || return 1
            AX20_ROOT="$AX20_ROOT" AX20_GAMESCOPE_PREFIX="$HDR_GAMESCOPE_PREFIX" \
                AX20_GAMESCOPE_WRAPPER_MODE=refresh-cache \
                "$AX20_SRC/overlay/bin/gamescope" \
                || log_warn "hdr: our gamescope build does not run '--help'; the wrapper will use stock gamescope"
        fi
    fi
    if ! hdr_lib_present; then
        log_warn "hdr: $HDR_LIB_DIR/$HDR_LDI_SONAME is not built yet; run build/build-hdr.sh (Desktop Mode HDR stays off until then)"
    fi
    if [ -n "$AX20_ROOT" ]; then
        log_debug "hdr: fixture/slot root, ldconfig deferred to the boot service on that system"
        return 0
    fi
    if ax20_have ldconfig; then
        ax20_run ldconfig || log_warn "hdr: ldconfig failed; libdisplay-info override not active until it succeeds"
    else
        log_warn "hdr: ldconfig not found; libdisplay-info override not active"
    fi
    return 0
}

# hdr_status : active | stock | superseded | n/a. Notes about the gamescope
# selection go to stderr so the word on stdout stays machine-readable.
hdr_status() {
    local word sel reason cache_rc=0
    word=$(component_default_status hdr)
    if [ "$word" = active ]; then
        hdr_ldcache_ok || cache_rc=$?
        if ! hdr_lib_present; then
            log_warn "hdr: libdisplay-info backport not built ($HDR_LIB_DIR/$HDR_LDI_SONAME missing)"
            word=stock
        elif [ "$cache_rc" = 1 ]; then
            log_warn "hdr: ld.so.cache does not list $HDR_LIB_DIR/$HDR_LDI_SONAME (run ldconfig)"
            word=stock
        fi
    fi
    sel=$(hdr_gamescope_status_line selection 2>/dev/null) || sel=""
    if [ "$sel" = stock ] && [ -f "$(ax20_path "$HDR_WRAPPER")" ]; then
        reason=$(hdr_gamescope_status_line reason 2>/dev/null)
        log_warn "hdr: Game Mode fell back to stock gamescope: ${reason:-unknown reason}"
    fi
    printf '%s\n' "$word"
}

# hdr_remove : runtime files the wrapper writes (not in the manifest).
# ldconfig runs in the uninstall flow after the drop-in is removed.
hdr_remove() {
    local f
    for f in "$HDR_STATUS_FILE" "$HDR_FLAGS_CACHE"; do
        f=$(ax20_path "$f")
        [ -e "$f" ] || continue
        ax20_run rm -f "$f"
    done
    return 0
}
