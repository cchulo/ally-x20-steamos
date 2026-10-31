# SPDX-License-Identifier: GPL-2.0-only
# summary: internal: logic behind the RAUC pre-install/post-install handlers
#
#   rauc-handler pre-install
#       self-update (best effort, once), then make sure kernel modules exist
#       for the incoming kernel; if they cannot be produced, apply
#       update-policy: block -> exit 1 (RAUC aborts the update),
#       degrade -> exit 0 and leave state/pending-rebuild.
#   rauc-handler post-install [--slot-root <dir>] [--slot A|B]
#       mount the freshly written slot (unless --slot-root is given), stage
#       modules for its kernel, `apply --slot <dir>` (files, RAUC
#       registration, boot entry), write state/pending-reboot-check there.
# Called by overlay/rauc/*.hook, which also chain the stock handlers.
# Commands from other packages (self-update, rebuild) are used only when
# present.

# shellcheck source=lib/rauc.sh
. "$AX20_SRC/lib/rauc.sh"
# shellcheck source=lib/slots.sh
. "$AX20_SRC/lib/slots.sh"
# shellcheck source=lib/modules.sh
. "$AX20_SRC/lib/modules.sh"
# shellcheck source=cmd/update-policy.sh
. "$AX20_SRC/cmd/update-policy.sh"

_handler_cli() { printf '%s/ally-x20-steamos.sh\n' "$AX20_SRC"; }
_handler_has_cmd() { [ -f "$AX20_SRC/cmd/$1.sh" ]; }
_handler_state() { printf '%s/state\n' "$(ax20_state_dir)"; }

_handler_commit() {
    git -C "$AX20_SRC" rev-parse HEAD 2>/dev/null || cat "$AX20_SRC/VERSION" 2>/dev/null || printf 'unknown\n'
}

# _handler_note <file> <lines...> : small key=value state files.
_handler_note() {
    local f
    f="$(_handler_state)/$1"
    shift
    [ "$AX20_DRY_RUN" = 1 ] || mkdir -p "$(dirname "$f")"
    printf '%s\n' "$@" | ax20_atomic_write "$f" 0644
}

handler_modules_present() {
    [ -d "$(ax20_path "$AX20_MODULES_REL/$1")" ]
}

# handler_try_build <kver> : 0 if modules for kver exist afterwards.
# Backoff: a failure is remembered per kernel + checkout commit, so Steam's
# periodic retries do not rebuild until self-update brought a new commit.
handler_try_build() {
    local kver=$1 commit fail
    commit=$(_handler_commit)
    fail="$(_handler_state)/build-failed-$kver"
    if [ -f "$fail" ] && [ "$(cat "$fail")" = "$commit" ]; then
        log_warn "modules for $kver already failed to build at commit $commit; not retrying until ally-x20-steamos changes"
        return 1
    fi
    if ! _handler_has_cmd rebuild; then
        log_warn "no rebuild command in this checkout; cannot produce modules for $kver"
        return 1
    fi
    if "$(_handler_cli)" rebuild --kver "$kver" && handler_modules_present "$kver"; then
        ax20_run rm -f "$fail"
        return 0
    fi
    if [ "$AX20_DRY_RUN" != 1 ]; then
        mkdir -p "$(dirname "$fail")"
        printf '%s\n' "$commit" >"$fail"
    fi
    return 1
}

rauc_handler_pre_install() {
    local kver policy
    if _handler_has_cmd self-update && [ -z "${AX20_HANDLER_SELF_UPDATED:-}" ]; then
        AX20_HANDLER_SELF_UPDATED=1
        export AX20_HANDLER_SELF_UPDATED
        "$(_handler_cli)" self-update || log_warn "self-update failed or offline; continuing with the current checkout"
        # Continue with the (possibly) new code.
        exec "$(_handler_cli)" rauc-handler pre-install
    fi
    if ! kver=$(rauc_incoming_kver); then
        log_warn "cannot tell the incoming kernel version before installation; post-install and the boot service will handle modules"
        return 0
    fi
    if handler_modules_present "$kver"; then
        log_info "modules for incoming kernel $kver are ready"
        return 0
    fi
    if handler_try_build "$kver"; then
        log_info "modules for incoming kernel $kver built"
        return 0
    fi
    policy=$(policy_effective --consume)
    if [ "$policy" = block ]; then
        _handler_note update-blocked "kver=$kver" "ts=$(_ax20_ts)" "commit=$(_handler_commit)"
        log_error "no kernel modules for incoming kernel $kver; blocking this SteamOS update (policy: block). Run '$AX20_NAME update-policy degrade --once' to let it through."
        return 1
    fi
    _handler_note pending-rebuild "kver=$kver" "ts=$(_ax20_ts)"
    ax20_run rm -f "$(_handler_state)/update-blocked"
    log_warn "no kernel modules for incoming kernel $kver; continuing (policy: degrade), stock modules until a rebuild succeeds"
    return 0
}

# handler_stage_modules <kver> <slot-root> : copy our built modules into the
# new slot's state dir if the stock rsync did not carry them.
handler_stage_modules() {
    local kver=$1 dir=$2 src dst
    src=$(ax20_path "$AX20_MODULES_REL/$kver")
    dst="$dir$AX20_MODULES_REL/$kver"
    [ -d "$src" ] || return 0
    [ -d "$dst" ] && return 0
    ax20_run mkdir -p "$(dirname "$dst")"
    ax20_run cp -a "$src" "$dst.tmp.$$" && ax20_run mv "$dst.tmp.$$" "$dst"
    log_info "staged modules for $kver into the new slot"
}

rauc_handler_post_install() {
    local slot_root="" target="" cur kver mounted=0 rc=0 k
    while [ $# -gt 0 ]; do
        case "$1" in
            --slot-root)
                slot_root=$2
                shift
                ;;
            --slot)
                target=$2
                shift
                ;;
            *) die 2 "rauc-handler post-install: unknown argument '$1'" ;;
        esac
        shift
    done
    cur=$(slots_active) || cur=""
    if [ -z "$target" ]; then
        [ -n "$cur" ] || die "cannot determine the booted slot, so not the updated one either"
        target=$(slots_other "$cur")
    fi
    slots_valid_name "$target" || die "bad target slot '$target'"
    if [ -z "$slot_root" ]; then
        slot_root=$(ax20_path "/run/$AX20_NAME/slot-$target")
        slots_mount_composite "$target" "$slot_root" || die "cannot mount slot $target"
        mounted=1
    fi
    kver=""
    for k in "$slot_root"/usr/lib/modules/*; do
        [ -d "$k" ] && kver=$(basename "$k")
    done
    if [ -n "$kver" ]; then
        handler_stage_modules "$kver" "$slot_root"
    else
        log_warn "cannot read the new slot's kernel version"
    fi
    AX20_SLOT=$target AX20_KVER=${kver:-} "$(_handler_cli)" apply --slot "$slot_root" || rc=1
    if [ "$AX20_DRY_RUN" != 1 ]; then
        mkdir -p "$slot_root$AX20_STATE_REL/state"
        printf 'from=%s\nto=%s\nkver=%s\nts=%s\napply_rc=%s\n' "$cur" "$target" "$kver" "$(_ax20_ts)" "$rc" \
            >"$slot_root$AX20_STATE_REL/state/pending-reboot-check"
    fi
    [ "$mounted" = 1 ] && slots_umount_composite "$slot_root"
    return "$rc"
}

cmd_rauc_handler() {
    local which=${1:-}
    [ $# -gt 0 ] && shift
    case "$which" in
        pre-install) rauc_handler_pre_install "$@" ;;
        post-install) rauc_handler_post_install "$@" ;;
        *) die 2 "rauc-handler: expected pre-install or post-install" ;;
    esac
}
