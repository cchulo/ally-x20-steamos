# SPDX-License-Identifier: GPL-2.0-only
# summary: boot-time check run by ally-x20-steamos.service: re-apply what an update dropped, start module builds, probe
#
# Steps (plan §4.2 step 2), each bounded and non-fatal:
#   1. apply --missing-only: components whose files or registrations
#      drifted (e.g. after a SteamOS update) are re-applied;
#   2. if the running kernel has no modules of ours and this checkout has a
#      `rebuild` command, start it detached (systemd-run) — it takes
#      effect on the next boot;
#   3. probes + state/status.json;
#   4. if anything is worth telling the user, write state/notify for the
#      user-session notifier. Consumes state/pending-reboot-check.

# shellcheck source=cmd/apply.sh
. "$AX20_SRC/cmd/apply.sh"

# boot_kick_rebuild <kver> : start a detached rebuild. Never waits.
boot_kick_rebuild() {
    local kver=$1
    if [ -n "$AX20_ROOT" ]; then
        log_info "would start a detached rebuild for $kver (fixture root: not starting)"
        return 0
    fi
    if ax20_have systemd-run; then
        ax20_run systemd-run --no-block --collect --unit="${AX20_NAME}-rebuild" \
            --description="ally-x20-steamos: build kernel modules for $kver" \
            "$AX20_SRC/ally-x20-steamos.sh" rebuild --kver "$kver" >/dev/null 2>&1 \
            || log_warn "could not start the detached rebuild for $kver"
    else
        log_warn "systemd-run not available; run '$AX20_NAME rebuild --kver $kver' manually"
    fi
}

cmd_boot() {
    local kver pending="" superseded="" update="" blocked="" c st state notify
    # shellcheck disable=SC2119  # require_root takes no arguments here
    require_root
    ax20_check_readonly_root
    state="$(ax20_state_dir)/state"
    [ "$AX20_DRY_RUN" = 1 ] || mkdir -p "$state" "$(ax20_state_dir)/log"

    apply_components 1 "" || true

    kver=$(probe_running_kver)
    # Staged modules live under the early boot dir (/etc), not the state dir.
    if [ -f "$AX20_SRC/cmd/rebuild.sh" ] && ! [ -d "$(ax20_path "${AX20_EARLY_REL}/modules/$kver")" ]; then
        pending="kernel modules for $kver"
        boot_kick_rebuild "$kver"
    fi

    for c in $(component_list); do
        st=$(component_status "$c" 2>/dev/null || true)
        [ "$st" = superseded ] && superseded="$superseded $c"
    done
    superseded=${superseded# }

    if [ -f "$state/pending-reboot-check" ]; then
        update=$(sed -n 's/^from=//p' "$state/pending-reboot-check")" -> "$(sed -n 's/^to=//p' "$state/pending-reboot-check")
        ax20_run rm -f "$state/pending-reboot-check"
    fi
    if [ -f "$state/update-blocked" ]; then
        blocked=$(sed -n 's/^kver=//p' "$state/update-blocked")
    fi

    status_write_json last_command boot reapplied "$APPLY_DONE" failed "$APPLY_FAILED" \
        pending "$pending" superseded "$superseded" update "$update" blocked "$blocked"

    notify="$state/notify"
    if [ -n "$APPLY_DONE$APPLY_FAILED$pending$superseded$update$blocked" ]; then
        printf 'update=%s\nreapplied=%s\nfailed=%s\npending=%s\nsuperseded=%s\nblocked=%s\n' \
            "$update" "$APPLY_DONE" "$APPLY_FAILED" "$pending" "$superseded" "$blocked" \
            | ax20_atomic_write "$notify" 0644
    elif [ -f "$notify" ]; then
        ax20_run rm -f "$notify"
    fi
    return 0
}
