# SPDX-License-Identifier: GPL-2.0-only
# summary: what a SteamOS update does if kernel modules cannot be built: show | block | degrade [--once]
#
#   block    (default) the RAUC pre-install handler aborts the update when
#            modules for the incoming kernel cannot be produced; Steam retries
#            later, and each retry runs self-update first.
#   degrade  never block; the new kernel boots with stock modules until a
#            rebuild succeeds (speakers silent, RGB menu and QAM button gone).
#   degrade --once
#            let only the next update through regardless, then back to block.
# Persisted in /var/lib/ally-x20-steamos/state/update-policy{,-once}.

POLICY_FILE_REL="${AX20_STATE_REL}/state/update-policy"
POLICY_ONCE_REL="${AX20_STATE_REL}/state/update-policy-once"

# policy_get : the persisted policy (block when unset or unreadable).
policy_get() {
    local f v
    f=$(ax20_path "$POLICY_FILE_REL")
    v=$(head -n1 "$f" 2>/dev/null || true)
    case "$v" in
        degrade) printf 'degrade\n' ;;
        *) printf 'block\n' ;;
    esac
}

policy_once_pending() { [ -f "$(ax20_path "$POLICY_ONCE_REL")" ]; }

# policy_effective [--consume] : the policy for the update happening now.
# --consume removes the one-shot marker (used by the pre-install handler
# only when it actually lets an update through because of it).
policy_effective() {
    if policy_once_pending; then
        if [ "${1:-}" = --consume ]; then
            ax20_run rm -f "$(ax20_path "$POLICY_ONCE_REL")"
        fi
        printf 'degrade\n'
        return 0
    fi
    policy_get
}

_policy_write() {
    local f
    f=$(ax20_path "$POLICY_FILE_REL")
    [ "$AX20_DRY_RUN" = 1 ] || mkdir -p "$(dirname "$f")"
    printf '%s\n' "$1" | ax20_atomic_write "$f" 0644
}

cmd_update_policy() {
    local action=${1:-show} once=0 f
    [ $# -gt 0 ] && shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --once) once=1 ;;
            --consume) once=2 ;;
            *) die 2 "update-policy: unknown argument '$1'" ;;
        esac
        shift
    done
    case "$action" in
        show)
            if policy_once_pending; then
                printf '%s (next update: degrade once)\n' "$(policy_get)"
            else
                policy_get
            fi
            ;;
        effective)
            if [ "$once" = 2 ]; then
                policy_effective --consume
            else
                policy_effective
            fi
            ;;
        block)
            [ "$once" = 0 ] || die 2 "update-policy: --once only applies to degrade"
            require_root
            _policy_write block
            ax20_run rm -f "$(ax20_path "$POLICY_ONCE_REL")"
            log_info "update policy: block"
            ;;
        degrade)
            require_root
            if [ "$once" = 1 ]; then
                f=$(ax20_path "$POLICY_ONCE_REL")
                [ "$AX20_DRY_RUN" = 1 ] || mkdir -p "$(dirname "$f")"
                printf '%s\n' "$(_ax20_ts)" | ax20_atomic_write "$f" 0644
                log_info "update policy: the next update will not be blocked; policy stays $(policy_get)"
            else
                _policy_write degrade
                log_info "update policy: degrade"
            fi
            ;;
        -h | --help | help)
            sed -n '3,12s/^# \{0,1\}//p' "$AX20_SRC/cmd/update-policy.sh"
            ;;
        *) die 2 "update-policy: expected show | block | degrade [--once]" ;;
    esac
}
