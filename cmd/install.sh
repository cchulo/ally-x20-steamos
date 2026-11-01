# SPDX-License-Identifier: GPL-2.0-only
# summary: install on this device: clone into the state dir, pin keys, apply, show status
#
# Plan §4.4 / docs/install.md. Steps, all idempotent:
#   1. root + read-only root check, DMI board must be RC74XA (--force-board)
#   2. create /var/lib/ally-x20-steamos/{modules,firmware,cache,backup,state,log,bin}
#   3. clone (or update) the git checkout at /var/lib/ally-x20-steamos/src,
#      unless we are already running from there
#   4. pin keys/ into /var/lib/ally-x20-steamos/keys (kept on re-install
#      unless --repin-keys), record state/installed-from
#   5. copy the standalone uninstaller, run migrations, apply, status
# shellcheck source=lib/selfupdate.sh
. "$AX20_SRC/lib/selfupdate.sh"

# _install_stage_modules <src> : stage the patched modules for the running
# kernel right away (release artifact, cache or container build) so one
# reboot is enough. Only on a real system; the boot service retries later
# if this fails (no network, no artifact yet), so a failure is not fatal.
_install_stage_modules() {
    local src=$1 kver
    [ -n "$AX20_ROOT" ] && return 0
    [ -f "$src/cmd/rebuild.sh" ] || return 0
    kver=$(probe_running_kver 2>/dev/null || uname -r)
    [ -n "$kver" ] || return 0
    if [ -d "${AX20_EARLY_REL}/modules/$kver" ]; then
        return 0
    fi
    log_info "staging the patched kernel modules for $kver (release artifact, cache or local build)"
    su_run_cli "$src" rebuild --kver "$kver" --no-self-update \
        || log_warn "could not stage the modules now; the boot service retries after the reboot (or run: $AX20_NAME rebuild)"
    return 0
}

_install_usage() {
    cat <<USAGE
usage: $AX20_NAME install [options]

  --repo <url>     clone from this URL (default: origin of the running checkout)
  --ref <ref>      tag or branch to install (default: the running checkout's tag/branch)
  --force-board    install even if the DMI board is not $AX20_BOARD
  --repin-keys     replace already pinned signing keys with the checkout's keys/
  --no-apply       stop after cloning and pinning (do not run apply/status)
USAGE
}

# _install_check_board <force>
_install_check_board() {
    local f board=""
    f=$(ax20_path /sys/class/dmi/id/board_name)
    if [ -r "$f" ]; then
        board=$(tr -d ' \t\r\n' <"$f")
    fi
    if [ "$board" = "$AX20_BOARD" ]; then
        log_info "board $board detected"
        return 0
    fi
    if [ "$1" = 1 ]; then
        log_warn "board is '${board:-unknown}', not $AX20_BOARD; continuing because --force-board was given"
        return 0
    fi
    die "this is not a ROG Xbox Ally X20 (DMI board '${board:-unknown}', expected $AX20_BOARD). Refusing to install; pass --force-board to override (e.g. in a VM)"
}

# _install_current_ref : the running checkout's exact tag, else its branch.
_install_current_ref() {
    su_is_git_checkout "$AX20_SRC" || return 0
    su_git "$AX20_SRC" describe --tags --exact-match HEAD 2>/dev/null \
        || su_git "$AX20_SRC" symbolic-ref -q --short HEAD 2>/dev/null || true
}

# _install_same_dir <a> <b>
_install_same_dir() {
    [ -d "$1" ] && [ -d "$2" ] && [ "$(cd "$1" && pwd -P)" = "$(cd "$2" && pwd -P)" ]
}

# _install_update_existing <target> <ref> : fetch and move an existing
# checkout to <ref> (fast-forward only for branches).
_install_update_existing() {
    local target=$1 ref=$2
    log_info "updating existing checkout at $SU_SRC_REL"
    su_require_clean "$target"
    ax20_run su_git "$target" fetch --quiet --tags origin || die 3 "cannot fetch from origin of $SU_SRC_REL (offline?)"
    [ -n "$ref" ] || return 0
    if su_git "$target" rev-parse --verify -q "refs/tags/$ref" >/dev/null; then
        ax20_run su_git "$target" checkout --quiet --detach "refs/tags/$ref" || die "cannot check out $ref"
    elif su_git "$target" rev-parse --verify -q "refs/remotes/origin/$ref" >/dev/null; then
        if su_git "$target" rev-parse --verify -q "refs/heads/$ref" >/dev/null; then
            ax20_run su_git "$target" checkout --quiet "$ref" || die "cannot check out $ref"
            ax20_run su_git "$target" merge --quiet --ff-only "origin/$ref" \
                || die "branch $ref in $SU_SRC_REL has diverged from origin; resolve it by hand"
        else
            ax20_run su_git "$target" checkout --quiet -b "$ref" --track "origin/$ref" || die "cannot check out $ref"
        fi
    else
        die "ref '$ref' does not exist in origin of $SU_SRC_REL"
    fi
}

# _install_clone <url> <ref> <target>
_install_clone() {
    local url=$1 ref=$2 target=$3 commit
    if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        die "$SU_SRC_REL exists, is not empty and is not a git checkout; move it away and retry"
    fi
    log_info "cloning $url${ref:+ ($ref)} into $SU_SRC_REL"
    if [ -n "$ref" ]; then
        ax20_run su_git "$(dirname "$target")" clone --quiet --branch "$ref" "$url" "$target" \
            || die 3 "git clone of $url ($ref) failed"
    else
        ax20_run su_git "$(dirname "$target")" clone --quiet "$url" "$target" \
            || die 3 "git clone of $url failed"
        # Detached checkout without a tag: pin the exact commit we run from.
        commit=$(su_head "$AX20_SRC" 2>/dev/null || true)
        if [ -n "$commit" ] && [ "$AX20_DRY_RUN" != 1 ]; then
            if su_git "$target" cat-file -e "${commit}^{commit}" 2>/dev/null; then
                su_git "$target" checkout --quiet --detach "$commit"
            else
                log_warn "commit $commit is not on $url; installed its default branch instead"
            fi
        fi
    fi
}

_install_record_from() {
    local target=$1 url=$2 ref=$3
    {
        printf 'url=%s\n' "$url"
        printf 'ref=%s\n' "$ref"
        printf 'commit=%s\n' "$(su_head "$target" 2>/dev/null || echo unknown)"
        printf 'date=%s\n' "$(su_now_iso)"
        printf 'keys_sha256=%s\n' "$(su_keys_digest "$(ax20_path "$SU_KEYS_REL")")"
    } | su_write_state installed-from
}

_install_copy_uninstaller() {
    local target=$1 f
    for f in "$target/uninstall/uninstall.sh" "$AX20_SRC/uninstall/uninstall.sh"; do
        if [ -f "$f" ]; then
            ax20_copy_atomic "$f" "$(ax20_state_dir)/uninstall.sh" 0755
            log_info "standalone uninstaller copied to ${AX20_STATE_REL}/uninstall.sh"
            return 0
        fi
    done
    log_warn "no standalone uninstaller in this version (uninstall/uninstall.sh); skipped"
}

cmd_install() {
    local repo="" ref="" ref_given=0 force_board=0 repin=0 no_apply=0
    local base target url d
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo)
                [ $# -ge 2 ] || die 2 "--repo needs a URL"
                repo=$2
                shift 2
                ;;
            --ref)
                [ $# -ge 2 ] || die 2 "--ref needs a tag or branch"
                ref=$2
                ref_given=1
                shift 2
                ;;
            --force-board)
                force_board=1
                shift
                ;;
            --repin-keys)
                repin=1
                shift
                ;;
            --no-apply)
                no_apply=1
                shift
                ;;
            -h | --help)
                _install_usage
                return 0
                ;;
            *) die 2 "install: unknown argument '$1' (see install --help)" ;;
        esac
    done

    require_root install
    ax20_check_readonly_root
    _install_check_board "$force_board"
    ax20_have git || die "git is required (it ships with SteamOS)"

    base=$(ax20_state_dir_ensure)
    target=$(ax20_path "$SU_SRC_REL")
    for d in $SU_STATE_SUBDIRS; do
        ax20_mkdir_p "$base/$d" >/dev/null
    done

    [ "$ref_given" = 1 ] || ref=$(_install_current_ref)
    url=$repo
    if [ -z "$url" ] && su_is_git_checkout "$AX20_SRC"; then
        url=$(su_git "$AX20_SRC" remote get-url origin 2>/dev/null || true)
    fi

    if _install_same_dir "$target" "$AX20_SRC"; then
        log_info "running from $SU_SRC_REL already; not cloning"
        [ -n "$url" ] || url=unknown
    elif su_is_git_checkout "$target"; then
        _install_update_existing "$target" "$ref"
        [ -n "$url" ] || url=$(su_git "$target" remote get-url origin 2>/dev/null || echo unknown)
    else
        [ -n "$url" ] || die 2 "cannot tell where to clone from: $AX20_SRC has no 'origin' remote; pass --repo <url>"
        _install_clone "$url" "$ref" "$target"
    fi

    if [ "$AX20_DRY_RUN" = 1 ] && [ ! -d "$target" ]; then
        printf '[dry-run] would pin keys, record state/installed-from, copy the uninstaller, run migrations, apply and status\n' >&2
        return 0
    fi

    su_pin_keys "$target" "$repin"
    _install_record_from "$target" "$url" "$ref"
    _install_copy_uninstaller "$target"
    su_run_migrations "$target"
    if [ "$no_apply" = 1 ]; then
        log_info "installed checkout at $SU_SRC_REL (--no-apply: nothing applied)"
        return 0
    fi
    su_run_cli "$target" apply || die "apply failed; see ${AX20_LOG_REL}. Re-running install is safe"
    _install_stage_modules "$target"
    su_run_cli "$target" status || true
}
