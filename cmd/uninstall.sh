# SPDX-License-Identifier: GPL-2.0-only
# summary: remove everything we installed (or only --superseded / --component X)
#
# Thin wrapper: runs the components' _remove hooks (which need the checkout),
# then hands over to the self-contained uninstaller uninstall/uninstall.sh,
# which is the same file copied to /var/lib/ally-x20-steamos/uninstall.sh at
# install time and works without this checkout.
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"
# shellcheck source=lib/retired.sh
. "$AX20_SRC/lib/retired.sh"

cmd_uninstall() {
    local superseded=0 force=0 keep_state=0 reboot=0 comps="" c rc st args
    while [ $# -gt 0 ]; do
        case "$1" in
            --superseded) superseded=1 ;;
            --component)
                [ $# -ge 2 ] || die 2 "--component needs a name"
                comps="$comps $2"
                shift
                ;;
            --force) force=1 ;;
            --keep-state) keep_state=1 ;;
            --reboot) reboot=1 ;;
            --dry-run) AX20_DRY_RUN=1 ;;
            -h | --help)
                cat <<USAGE
usage: $AX20_NAME uninstall [--superseded] [--component NAME]... [--force] [--keep-state] [--reboot] [--dry-run]
  --superseded    remove only components whose probe says stock SteamOS now provides them
  --component     remove only the named component (repeatable)
  --force         also remove our files whose content changed since we wrote them
  --keep-state    keep /var/lib/$AX20_NAME (manifest, modules, logs)
  --reboot        reboot when done
Global --dry-run prints every action without changing anything.
USAGE
                return 0
                ;;
            *) die 2 "unknown option: $1" ;;
        esac
        shift
    done
    require_root uninstall
    ax20_check_readonly_root

    if [ "$superseded" = 1 ]; then
        for c in $(component_list); do
            st=$(component_status "$c")
            if [ "$st" = superseded ]; then
                comps="$comps $c"
                log_info "$c: superseded by stock SteamOS, will be removed"
            else
                log_debug "$c: $st, kept"
            fi
        done
        if [ -z "${comps# }" ]; then
            log_info "no component is superseded; nothing to do"
            return 0
        fi
    fi
    comps=${comps# }

    # Components this version no longer ships (lib/retired.sh): they have no
    # hook, but their own cleanup (state files, restarting the user's audio)
    # runs here; whatever it keeps is left to the uninstaller below.
    for c in ${comps:-$AX20_RETIRED_COMPONENTS}; do
        component_exists "$c" && continue
        retired_is "$c" || die 2 "unknown component: $c"
        [ -n "$(manifest_paths "$c" | head -n 1)" ] || continue
        retired_prune "$c" || true
    done

    # Component hooks (stop services, remove caches) — only for installed ones.
    for c in ${comps:-$(component_list)}; do
        component_exists "$c" || continue
        if component_installed "$c"; then
            component_remove_hook "$c" || log_warn "$c: remove hook failed; continuing"
        fi
    done

    args="--yes"
    [ -n "$AX20_ROOT" ] && args="$args --root $AX20_ROOT"
    [ "$AX20_DRY_RUN" = 1 ] && args="$args --dry-run"
    [ "$force" = 1 ] && args="$args --force"
    [ "$keep_state" = 1 ] && args="$args --keep-state"
    [ "$reboot" = 1 ] && args="$args --reboot"
    for c in $comps; do args="$args --component $c"; done
    rc=0
    # shellcheck disable=SC2086  # intentional word splitting of flags
    sh "$AX20_SRC/uninstall/uninstall.sh" $args || rc=$?
    [ "$rc" -eq 0 ] || log_warn "uninstaller finished with skipped items (exit $rc); see messages above"
    return "$rc"
}
