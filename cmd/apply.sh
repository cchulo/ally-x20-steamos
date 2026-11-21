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
# A component that fails is skipped and the others are still applied; the
# command then ends with a summary and exit code 4. Exit codes: 0 all
# applied, 1 error before anything ran, 2 usage, 4 some components failed.
# Writes state/status.json and state/last-apply.json (what happened to each
# component, with the reason for a failure) at the end.

# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"
# shellcheck source=lib/status.sh
. "$AX20_SRC/lib/status.sh"
# shellcheck source=lib/retired.sh
. "$AX20_SRC/lib/retired.sh"
# shellcheck source=lib/lastapply.sh
. "$AX20_SRC/lib/lastapply.sh"

# Results of the last apply_components run (space separated names).
# APPLY_DONE holds every component whose apply succeeded; APPLY_UNCHANGED is
# the subset whose files were already in place.
APPLY_DONE=""
APPLY_UNCHANGED=""
APPLY_FAILED=""
APPLY_SKIPPED=""
# "<name>\t<reason>" lines for the failed ones.
APPLY_FAILED_REASONS=""
# How the run is named in state/last-apply.json (set by the caller).
APPLY_COMMAND=${APPLY_COMMAND:-apply}
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

# _apply_signature <component> : one line per manifest entry of the
# component, "<path> <recorded digest> <verify result>". Equal before and
# after an apply, with every verify result 0, means nothing changed. Sorted:
# re-recording an entry moves it to the end of the manifest.
_apply_signature() {
    local p rc
    for p in $(manifest_paths "$1"); do
        rc=0
        manifest_verify "$p" || rc=$?
        printf '%s %s %s\n' "$p" "$(manifest_entry_get "$(manifest_entry "$p")" sha256)" "$rc"
    done | LC_ALL=C sort
}

# _apply_signature_clean <signature> : non-empty and every entry verifies.
_apply_signature_clean() {
    [ -n "$1" ] && ! printf '%s\n' "$1" | grep -qv ' 0$'
}

# _apply_one <component> <stderr-file> : component_apply in a subshell (a
# component that dies must not take the others down). Its stderr is shown
# as it comes and also kept in <stderr-file>, where the reason for a
# failure is read from. Returns the component's exit code.
_apply_one() {
    local rc
    if [ -z "$2" ]; then
        (component_apply "$1")
        return $?
    fi
    {
        (component_apply "$1") 2>&1 1>&3 3>&- | tee "$2" >&2
        rc=${PIPESTATUS[0]}
    } 3>&1
    return "$rc"
}

# apply_components <missing-only:0|1> [component] : sets the APPLY_* globals
# and collects each component's outcome for state/last-apply.json (the
# caller writes it with la_write). Never stops at a failing component.
# With missing-only (the boot service) only the components that were
# re-applied are recorded; the others keep their previous record.
apply_components() {
    local missing=$1 only=${2:-} c list st prc tmp errf pre post reason
    APPLY_DONE=""
    APPLY_UNCHANGED=""
    APPLY_FAILED=""
    APPLY_SKIPPED=""
    APPLY_FAILED_REASONS=""
    la_begin "$APPLY_COMMAND"
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
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ax20-apply.XXXXXX" 2>/dev/null || true)
    for c in $list; do
        prc=0
        component_probe "$c" >/dev/null 2>&1 || prc=$?
        if [ "$prc" = "$PROBE_YES" ] && ! component_installed "$c"; then
            log_info "$c: stock SteamOS provides this; not installing"
            APPLY_SKIPPED="$APPLY_SKIPPED $c"
            [ "$missing" = 1 ] || la_record "$c" skipped "stock SteamOS provides this"
            continue
        fi
        pre=""
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
                active | partial | superseded)
                    log_debug "$c: $st, nothing to re-apply"
                    continue
                    ;;
            esac
        elif [ "$AX20_DRY_RUN" != 1 ]; then
            pre=$(_apply_signature "$c")
        fi
        errf=""
        [ -z "$tmp" ] || errf="$tmp/$c.err"
        if _apply_one "$c" "$errf"; then
            APPLY_DONE="$APPLY_DONE $c"
            post=""
            if _apply_signature_clean "$pre"; then
                post=$(_apply_signature "$c")
            fi
            if [ -n "$post" ] && [ "$pre" = "$post" ]; then
                APPLY_UNCHANGED="$APPLY_UNCHANGED $c"
                la_record "$c" unchanged
            else
                la_record "$c" applied
            fi
        else
            reason=""
            [ -z "$errf" ] || reason=$(la_reason_from "$errf")
            [ -n "$reason" ] || reason="its apply step failed without an error message"
            log_error "component $c failed to apply; skipping it and carrying on with the others"
            APPLY_FAILED="$APPLY_FAILED $c"
            APPLY_FAILED_REASONS="$APPLY_FAILED_REASONS$c	$reason
"
            la_record "$c" failed "$reason" "$errf"
        fi
    done
    [ -z "$tmp" ] || rm -rf "${tmp:?}"
    APPLY_DONE=${APPLY_DONE# }
    APPLY_UNCHANGED=${APPLY_UNCHANGED# }
    APPLY_FAILED=${APPLY_FAILED# }
    APPLY_SKIPPED=${APPLY_SKIPPED# }
    [ -z "$APPLY_FAILED" ]
}

# apply_summary : say what the run did, one line per outcome, then one line
# per failed component with its reason and where the record is.
apply_summary() {
    local c changed="" name reason n
    for c in $APPLY_DONE; do
        case " $APPLY_UNCHANGED " in *" $c "*) ;; *) changed="$changed $c" ;; esac
    done
    changed=${changed# }
    [ -z "$changed" ] || log_info "applied: $changed"
    [ -z "$APPLY_UNCHANGED" ] || log_info "unchanged: $APPLY_UNCHANGED"
    [ -z "$APPLY_SKIPPED" ] || log_info "skipped (stock SteamOS provides them): $APPLY_SKIPPED"
    [ -n "$APPLY_FAILED" ] || return 0
    log_error "failed: $APPLY_FAILED"
    printf '%s' "$APPLY_FAILED_REASONS" | while IFS='	' read -r name reason; do
        [ -n "$name" ] || continue
        log_error "  $name: $reason"
    done
    n=$(printf '%s\n' "$APPLY_FAILED" | wc -w | tr -d ' ')
    log_error "$n component(s) failed and were skipped; the others were applied. Details: $(la_file) (or: $AX20_NAME status)"
    log_error "what a failed component had already installed stays recorded in the manifest; fix the cause and run '$AX20_NAME apply' again, or remove it with '$AX20_NAME uninstall --component <name>'"
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
    local only="" verify=0 missing=0 slot_root="" c drift=0 k rc=0 record=$AX20_LAST_APPLY_REL
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
                sed -n '3,19s/^# \{0,1\}//p' "$AX20_SRC/cmd/apply.sh"
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
    APPLY_COMMAND=apply
    [ -z "$only" ] || APPLY_COMMAND="apply --only $only"
    [ "$missing" != 1 ] || APPLY_COMMAND="$APPLY_COMMAND --missing-only"
    if [ -n "$slot_root" ]; then
        APPLY_COMMAND="$APPLY_COMMAND --slot"
        record=$AX20_LAST_APPLY_SLOT_REL
    fi
    apply_components "$missing" "$only" || rc=$AX20_EXIT_PARTIAL
    apply_summary
    la_write "$rc" "$record" || log_warn "could not write $record"
    status_write_json last_command apply applied "$APPLY_DONE" failed "$APPLY_FAILED"
    return "$rc"
}
