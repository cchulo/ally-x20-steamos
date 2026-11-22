# SPDX-License-Identifier: GPL-2.0-only
# summary: HDR: status | fetch | build | remove the Desktop Mode library (Game Mode HDR needs none of this)
#
# HDR has two halves (docs/hdr.md). Game Mode gets it from a gamescope
# display profile that `apply` installs; nothing here is needed for it.
# Desktop Mode (KDE/KWin) needs our libdisplay-info build, which the loader
# picks up through /etc/ld.so.conf.d/00-ally-x20-steamos.conf. This command
# looks after that library:
#
#   status   what is installed for both modes, the library's build id and
#            where it came from, what SteamOS ships
#   fetch    install the prebuilt library: local cache, then the release
#   build    build it on this device in a container (podman) and install it
#   remove   take our library out again. Desktop Mode goes back to stock
#            behavior (no HDR toggle). This is the recovery path if the
#            library ever keeps the desktop from starting; it works from a
#            text console (Ctrl+Alt+F3) or over SSH.
#
# `apply`, `install` and `self-update` already run the equivalent of
# `fetch`; the boot service starts `fetch --auto` detached when the library
# is missing or from another build.

# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

_hdr_usage() {
    cat <<USAGE
usage: $AX20_NAME hdr <status|fetch|build|remove>

  status           what is installed for Game Mode and Desktop Mode
  fetch [--force]  download the prebuilt Desktop Mode library (local cache,
                   then the release) and install it; --force installs it
                   again even when the installed copy is current
  build            build the library on this device in a container (podman,
                   needs the network, a few minutes) and install it
  remove           take our library out again; Desktop Mode behaves like
                   stock SteamOS. Run this from a text console (Ctrl+Alt+F3)
                   or over SSH if Desktop Mode does not start.

Game Mode HDR does not use the library and works without it: enable it in
Steam > Settings > Display > Enable HDR.
USAGE
}

# _hdr_row <label> <value>
_hdr_row() { printf '  %-18s %s\n' "$1" "$2"; }

_hdr_status() {
    local v why rc=0 sel reason cache_rc=0 real state hint=""
    printf 'Game Mode (gamescope)\n'
    if hdr_stock_has_profile; then
        _hdr_row "display profile:" "SteamOS ships its own X20 profile; ours is not needed"
    elif [ -f "$(ax20_path "$HDR_LUA")" ]; then
        _hdr_row "display profile:" "installed ($HDR_LUA)"
    elif hdr_stock_lua_compatible; then
        _hdr_row "display profile:" "not installed (run: $AX20_NAME apply --only hdr)"
    else
        _hdr_row "display profile:" "not installed: this gamescope lacks the Lua helpers the profile needs"
    fi
    if [ -f "$(ax20_path "$HDR_WRAPPER")" ]; then
        sel=$(hdr_gamescope_status_line selection 2>/dev/null) || sel=""
        reason=$(hdr_gamescope_status_line reason 2>/dev/null) || reason=""
        _hdr_row "custom gamescope:" "installed; last start used ${sel:-unknown}${reason:+ ($reason)}"
    else
        _hdr_row "custom gamescope:" "not installed (not needed)"
    fi
    _hdr_row "enable it:" "Steam > Settings > Display > Enable HDR, then in the game"

    printf '\nDesktop Mode (KDE/KWin)\n'
    v=$(hdr_stock_ldi_version) || v=""
    why=$(hdr_lib_stock_check) || rc=$?
    case "$rc" in
        0) _hdr_row "SteamOS ships:" "libdisplay-info $v (does not read the panel's HDR data; our library replaces it)" ;;
        1) _hdr_row "SteamOS ships:" "libdisplay-info $v (reads the HDR data itself; our library is not needed)" ;;
        *) _hdr_row "SteamOS ships:" "${v:+libdisplay-info $v: }$why" ;;
    esac
    real=$(ax20_path "$(hdr_lib_real_rel)")
    if hdr_lib_present; then
        if hdr_lib_current; then
            state="installed"
        elif [ -f "$(ax20_path "$HDR_LIB_BUILD_INFO")" ]; then
            state="installed, from another build than this version asks for ($(hdr_lib_matches_checkout "$(ax20_path "$HDR_LIB_BUILD_INFO")" || true))"
            [ -f "$real" ] || state="installed, but $(hdr_lib_real_rel) is missing"
            hint="sudo $AX20_NAME hdr fetch"
        else
            state="installed by hand (no BUILD-INFO; not checked)"
            hint="sudo $AX20_NAME hdr fetch"
        fi
    elif hdr_lib_disabled; then
        state="removed with '$AX20_NAME hdr remove' (stays out until: sudo $AX20_NAME hdr fetch)"
    elif [ "$rc" = 0 ]; then
        state="not installed"
        hint="sudo $AX20_NAME hdr fetch"
    else
        state="not installed"
    fi
    _hdr_row "our library:" "$state"
    if hdr_lib_present; then
        _hdr_row "file:" "$HDR_LIB_DIR/$HDR_LDI_SONAME"
        _hdr_row "build id:" "$(hdr_lib_info_get build_id 2>/dev/null || printf 'unknown')"
        _hdr_row "built at:" "$(hdr_lib_info_get built_at 2>/dev/null || printf 'unknown')"
        _hdr_row "came from:" "$(hdr_lib_source_get source 2>/dev/null || printf 'unknown (not installed by this command)')"
        if why=$(hdr_lib_source_get origin 2>/dev/null) && [ -n "$why" ]; then
            _hdr_row "origin:" "$why"
        fi
        if why=$(hdr_lib_source_get installed_at 2>/dev/null); then
            _hdr_row "installed at:" "$why"
        fi
        hdr_ldcache_ok || cache_rc=$?
        if ! [ -f "$(ax20_path "$HDR_LDCONF")" ]; then
            _hdr_row "loader:" "$HDR_LDCONF is missing: the library is not used (run: $AX20_NAME apply --only hdr)"
        elif [ "$cache_rc" = 0 ]; then
            _hdr_row "loader:" "ld.so.cache lists our copy; programs started from now on use it"
        elif [ "$cache_rc" = 1 ]; then
            _hdr_row "loader:" "ld.so.cache does not list our copy yet (run: sudo ldconfig)"
        else
            _hdr_row "loader:" "no ld.so.cache on this root to look at"
        fi
    fi
    if [ -n "$hint" ]; then
        printf '\nTo get the current Desktop Mode library: %s\n' "$hint"
    fi
    if hdr_lib_present; then
        printf '\nIf Desktop Mode ever fails to start, take the library out from a text\nconsole (Ctrl+Alt+F3) or over SSH: sudo %s hdr remove\n' "$AX20_NAME"
    fi
    return 0
}

# _hdr_require_applicable <verb> : stop when our library is not for the
# libdisplay-info this SteamOS ships.
_hdr_require_applicable() {
    local why rc=0
    why=$(hdr_lib_stock_check) || rc=$?
    case "$rc" in
        0) return 0 ;;
        1)
            printf '%s\n' "$why"
            return 1
            ;;
        *) die "hdr $1: $why. Nothing was installed" ;;
    esac
}

# _hdr_after_install <how> : ldconfig and what to do next.
_hdr_after_install() {
    hdr_ldconfig
    printf 'Desktop Mode HDR library: %s\n' "$1"
    if [ "$AX20_DRY_RUN" != 1 ] && [ -f "$(ax20_path "$HDR_LIB_BUILD_INFO")" ]; then
        sed -n -e '/^build_id=/p' -e '/^built_at=/p' -e '/^libdisplay_info_version=/p' \
            -e '/^libdisplay_info_sha256=/p' "$(ax20_path "$HDR_LIB_BUILD_INFO")"
    fi
    if ! [ -f "$(ax20_path "$HDR_LDCONF")" ]; then
        log_warn "$HDR_LDCONF is not installed, so nothing uses the library yet; run: $AX20_NAME apply --only hdr"
    fi
    printf 'Log out of Desktop Mode and back in (or reboot), then look for the HDR switch\nin System Settings > Display & Monitor. If Desktop Mode does not start, press\nCtrl+Alt+F3, log in and run: sudo %s hdr remove\n' "$AX20_NAME"
}

# _hdr_fetch_auto : what install, self-update and the boot service run.
# Quiet, never fails, respects `hdr remove`.
_hdr_fetch_auto() {
    if ! hdr_lib_fetch_due; then
        log_debug "hdr: nothing to fetch"
        return 0
    fi
    if hdr_lib_resolve >/dev/null; then
        hdr_ldconfig
    fi
    return 0
}

_hdr_fetch() {
    local auto=0 how
    while [ $# -gt 0 ]; do
        case "$1" in
            --auto) auto=1 ;;
            --force)
                AX20_HDR_FORCE=1
                export AX20_HDR_FORCE
                ;;
            *) die 2 "hdr fetch: unknown argument '$1' (see hdr --help)" ;;
        esac
        shift
    done
    require_root hdr fetch
    ax20_check_readonly_root
    if [ "$auto" = 1 ]; then
        _hdr_fetch_auto
        return 0
    fi
    _hdr_require_applicable fetch || return 0
    hdr_lib_clear_disabled
    if ! how=$(hdr_lib_resolve); then
        log_error "no Desktop Mode library was installed (offline, or the release has no prebuilt copy for this version). Try again later, or build it here: sudo $AX20_NAME hdr build. Game Mode HDR is not affected"
        return 1
    fi
    _hdr_after_install "$how"
}

_hdr_build() {
    local how
    [ $# -eq 0 ] || die 2 "hdr build: unknown argument '$1' (see hdr --help)"
    require_root hdr build
    ax20_check_readonly_root
    _hdr_require_applicable build || return 0
    ax20_have podman || die "hdr build needs podman (it ships with SteamOS)"
    hdr_lib_clear_disabled
    if ! how=$(hdr_lib_resolve --source container); then
        log_error "the local build did not produce an installable library; see the messages above. Game Mode HDR is not affected"
        return 1
    fi
    _hdr_after_install "$how"
}

_hdr_remove() {
    local had=0 rc=0
    [ $# -eq 0 ] || die 2 "hdr remove: unknown argument '$1' (see hdr --help)"
    require_root hdr remove
    hdr_lib_present && had=1
    hdr_lib_unstage || rc=1
    hdr_lib_set_disabled || log_warn "could not record the removal; the next apply may download the library again"
    hdr_ldconfig
    if [ "$rc" != 0 ]; then
        log_error "some files of the library could not be removed. By hand: sudo rm $HDR_LDCONF && sudo ldconfig"
        return 1
    fi
    if [ "$had" = 1 ]; then
        printf 'Removed our libdisplay-info from %s. Desktop Mode uses the SteamOS library again\n(no HDR switch) the next time it starts. Game Mode HDR is not affected.\n' "$HDR_LIB_DIR"
    else
        printf 'Our libdisplay-info was not installed; nothing to remove.\n'
    fi
    printf 'It stays out until you run: sudo %s hdr fetch\n' "$AX20_NAME"
}

cmd_hdr() {
    local sub=${1:-}
    case "$sub" in
        '')
            _hdr_usage >&2
            return 2
            ;;
        -h | --help | help)
            _hdr_usage
            return 0
            ;;
    esac
    shift
    component_load hdr
    case "$sub" in
        status)
            [ $# -eq 0 ] || die 2 "hdr status takes no arguments"
            _hdr_status
            ;;
        fetch) _hdr_fetch "$@" ;;
        build) _hdr_build "$@" ;;
        remove) _hdr_remove "$@" ;;
        *) die 2 "hdr: unknown sub-command '$sub' (status|fetch|build|remove)" ;;
    esac
}
