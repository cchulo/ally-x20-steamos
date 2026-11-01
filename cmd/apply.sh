# SPDX-License-Identifier: GPL-2.0-only
# summary: install or re-apply components here or into a mounted slot: [--slot <mount>] [--only <c>] [--missing-only] [--verify-only]
#
#   --slot <mount>   operate on a mounted SteamOS slot (sets AX20_ROOT); used
#                    by the RAUC post-install handler. --slot-name A|B tells
#                    it which slot that is (for boot-entry backups).
#   --only <c>       just this component.
#   --missing-only   skip components whose files all verify (boot service).
#   --verify-only    report drift, write nothing; exit 1 if anything drifted.
# Components whose probe says stock SteamOS provides them, and that are not
# installed, are skipped (never installed on top of a native fix). Files of
# components this version no longer ships are removed (lib/retired.sh),
# except with --slot.
# Writes state/status.json at the end.

# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"
# shellcheck source=lib/status.sh
. "$AX20_SRC/lib/status.sh"
# shellcheck source=lib/retired.sh
. "$AX20_SRC/lib/retired.sh"

# Results of the last apply_components run (space separated names).
APPLY_DONE=""
APPLY_FAILED=""
APPLY_SKIPPED=""
# 1 = do not prune retired components (apply --slot: the files of a retired
# component live in the user's home, which a mounted slot does not carry).
APPLY_NO_RETIRE=${APPLY_NO_RETIRE:-0}

# apply_verify <component> : print drift lines, return 1 on drift.
apply_verify() {
    local c=$1 p rc drift=0
    for p in $(manifest_paths "$c"); do
        rc=0
        manifest_verify "$p" || rc=$?
        case "$rc" in
            0) ;;
            1)
                printf '%s: modified: %s\n' "$c" "$p"
                drift=1
                ;;
            2)
                printf '%s: missing: %s\n' "$c" "$p"
                drift=1
                ;;
            *)
                printf '%s: unknown: %s\n' "$c" "$p"
                drift=1
                ;;
        esac
    done
    return "$drift"
}

# apply_components <missing-only:0|1> [component] : sets APPLY_* globals.
apply_components() {
    local missing=$1 only=${2:-} c list st prc
    APPLY_DONE=""
    APPLY_FAILED=""
    APPLY_SKIPPED=""
    if [ -n "$only" ] && ! component_exists "$only" && retired_is "$only"; then
        log_info "$only is no longer part of $AX20_NAME; removing its files"
        if retired_prune "$only"; then
            APPLY_DONE=$only
            return 0
        fi
        APPLY_FAILED=$only
        return 1
    fi
    if [ -n "$only" ]; then
        component_exists "$only" || die 2 "unknown component '$only' (see: $AX20_NAME components)"
        list=$only
    else
        list=$(component_list)
    fi
    # Components this version no longer ships (lib/retired.sh): remove their
    # recorded files first, on every apply and boot run, so an upgrade
    # cleans up without an uninstall. A kept (modified) file only warns.
    if [ "$APPLY_NO_RETIRE" != 1 ]; then
        (retired_prune_all) || log_warn "retired components: some files were kept; see above"
    fi
    for c in $list; do
        prc=0
        component_probe "$c" >/dev/null 2>&1 || prc=$?
        if [ "$prc" = "$PROBE_YES" ] && ! component_installed "$c"; then
            log_info "$c: stock SteamOS provides this; not installing"
            APPLY_SKIPPED="$APPLY_SKIPPED $c"
            continue
        fi
        if [ "$missing" = 1 ]; then
            # Re-apply only what was installed and drifted. A component with no
            # manifest entries was never installed (or was uninstalled on
            # purpose); the boot service must not bring it back.
            if ! component_installed "$c"; then
                log_debug "$c: not installed, not re-applying"
                continue
            fi
            st=$(component_status "$c" 2>/dev/null || printf 'stock')
            case "$st" in
                active | superseded)
                    log_debug "$c: $st, nothing to re-apply"
                    continue
                    ;;
            esac
        fi
        # Subshell: a component that dies must not take the others down.
        if (component_apply "$c"); then
            APPLY_DONE="$APPLY_DONE $c"
        else
            log_error "component $c failed to apply"
            APPLY_FAILED="$APPLY_FAILED $c"
        fi
    done
    APPLY_DONE=${APPLY_DONE# }
    APPLY_FAILED=${APPLY_FAILED# }
    APPLY_SKIPPED=${APPLY_SKIPPED# }
    [ -z "$APPLY_FAILED" ]
}

# apply_slot_kver : the only kernel in the root's /usr/lib/modules, if unique.
apply_slot_kver() {
    local d n=0 k=""
    for d in "$(ax20_path /usr/lib/modules)"/*; do
        [ -d "$d" ] || continue
        n=$((n + 1))
        k=$(basename "$d")
    done
    [ "$n" = 1 ] && printf '%s\n' "$k"
}

cmd_apply() {
    local only="" verify=0 missing=0 slot_root="" c drift=0 k rc=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --slot)
                [ $# -ge 2 ] || die 2 "--slot needs a mount point"
                slot_root=$2
                shift
                ;;
            --slot=*) slot_root=${1#--slot=} ;;
            --slot-name)
                [ $# -ge 2 ] || die 2 "--slot-name needs A or B"
                AX20_SLOT=$2
                export AX20_SLOT
                shift
                ;;
            --only)
                [ $# -ge 2 ] || die 2 "--only needs a component"
                only=$2
                shift
                ;;
            --only=*) only=${1#--only=} ;;
            --missing-only) missing=1 ;;
            --verify-only) verify=1 ;;
            -h | --help)
                sed -n '3,14s/^# \{0,1\}//p' "$AX20_SRC/cmd/apply.sh"
                return 0
                ;;
            *) die 2 "apply: unknown argument '$1'" ;;
        esac
        shift
    done
    if [ -n "$slot_root" ]; then
        [ -d "$slot_root" ] || die "apply --slot: not a directory: $slot_root"
        AX20_ROOT=${slot_root%/}
        export AX20_ROOT
        APPLY_NO_RETIRE=1
        # The new slot's var must reach the shared state (symlink into /home).
        ax20_state_dir_ensure >/dev/null
        if [ -z "${AX20_KVER:-}" ]; then
            k=$(apply_slot_kver || true)
            if [ -n "$k" ]; then
                AX20_KVER=$k
                export AX20_KVER
            fi
        fi
        log_info "applying to slot root $AX20_ROOT (kernel ${AX20_KVER:-unknown})"
    fi
    if [ "$verify" = 1 ]; then
        if [ -n "$only" ]; then
            apply_verify "$only" || drift=1
        else
            for c in $(component_list); do
                apply_verify "$c" || drift=1
            done
        fi
        [ "$drift" = 0 ] && log_info "all installed files verify"
        return "$drift"
    fi
    # shellcheck disable=SC2119  # require_root takes no arguments here
    require_root
    ax20_check_readonly_root
    if [ "$AX20_DRY_RUN" != 1 ]; then
        mkdir -p "$(ax20_state_dir)/state" "$(ax20_state_dir)/log"
    fi
    apply_components "$missing" "$only" || rc=1
    [ -n "$APPLY_DONE" ] && log_info "applied: $APPLY_DONE"
    [ -n "$APPLY_FAILED" ] && log_error "failed: $APPLY_FAILED"
    status_write_json last_command apply applied "$APPLY_DONE" failed "$APPLY_FAILED"
    return "$rc"
}
