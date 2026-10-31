# SPDX-License-Identifier: GPL-2.0-only
# summary: fetch or build the patched kernel modules for a kernel (default: running)
# shellcheck source=lib/modules.sh
. "$AX20_SRC/lib/modules.sh"

_rebuild_usage() {
    cat <<USAGE
usage: $AX20_NAME rebuild [--kver <uname -r>] [--channel <repo>] [--source cache|release|container] [--no-self-update] [--force]

Makes patched modules available for a kernel, trying the local cache, then
the release artifact for that kernel, then a container build (podman).
Runs self-update first when available and online (best-effort).
USAGE
}

# _rebuild_self_update : best-effort, never fatal.
_rebuild_self_update() {
    [ -f "$AX20_SRC/cmd/self-update.sh" ] || return 0
    if ! modules_online; then
        log_info "offline: skipping self-update before rebuild"
        return 0
    fi
    if [ -n "$AX20_ROOT" ]; then
        "$AX20_SRC/ally-x20-steamos.sh" --root "$AX20_ROOT" self-update \
            || log_warn "self-update failed; rebuilding with the current checkout"
    else
        "$AX20_SRC/ally-x20-steamos.sh" self-update \
            || log_warn "self-update failed; rebuilding with the current checkout"
    fi
    return 0
}

cmd_rebuild() {
    local kver="" channel="" source="" self_update=1 how dir
    while [ $# -gt 0 ]; do
        case "$1" in
            --kver | --channel | --source)
                [ $# -ge 2 ] || die 2 "$1 needs a value"
                case "$1" in
                    --kver) kver=$2 ;;
                    --channel) channel=$2 ;;
                    --source) source=$2 ;;
                esac
                shift 2
                ;;
            --no-self-update)
                self_update=0
                shift
                ;;
            --force)
                # Restage even when modules for this kernel are already staged
                # (e.g. a newer artifact in the cache). Staging itself is
                # atomic, so never delete the staged directory by hand.
                AX20_MODULES_FORCE=1
                export AX20_MODULES_FORCE
                shift
                ;;
            -h | --help)
                _rebuild_usage
                return 0
                ;;
            *) die 2 "rebuild: unknown argument '$1' (see rebuild --help)" ;;
        esac
    done
    case "$source" in
        '' | cache | release | container) ;;
        *) die 2 "rebuild: --source must be cache, release or container" ;;
    esac
    require_root rebuild
    [ -n "$kver" ] || kver=$(probe_running_kver)
    [ -n "$channel" ] || channel=$(modules_detect_channel)
    if [ "$self_update" = 1 ]; then
        _rebuild_self_update
    fi
    if modules_lockdown_active; then
        log_warn "kernel lockdown is active: the patched modules will not load until it is off; stock modules stay in use"
    fi
    set -- "$kver" --channel "$channel"
    [ -n "$source" ] && set -- "$@" --source "$source"
    if ! how=$(modules_resolve "$@"); then
        log_error "no patched modules for $kver; stock modules stay in use (see $AX20_NAME status)"
        return 1
    fi
    dir=$(ax20_path "$(modules_dir_for "$kver")")
    printf 'modules for %s: %s\n' "$kver" "$how"
    if [ -f "$dir/BUILD-INFO" ]; then
        cat "$dir/BUILD-INFO"
    fi
    if [ "$kver" = "$(probe_running_kver)" ]; then
        log_info "reboot (or reload the modules) to use them"
    fi
}
