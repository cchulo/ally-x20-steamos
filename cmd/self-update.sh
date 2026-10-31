# SPDX-License-Identifier: GPL-2.0-only
# summary: update this ally-x20-steamos checkout to the newest signed release (or beta), with rollback
#
# Plan §4.4, docs/self-update.md. Operates on the git checkout at AX20_SRC
# (normally /var/lib/ally-x20-steamos/src). Every git call is
# `git -C "$AX20_SRC"`. Exit codes: 0 ok / nothing to do, 1 error,
# 2 usage, 3 cannot reach origin (callers such as rebuild and the RAUC
# pre-install handler treat 3 as "offline, carry on").
# shellcheck source=lib/selfupdate.sh
. "$AX20_SRC/lib/selfupdate.sh"
# shellcheck source=lib/notify.sh
. "$AX20_SRC/lib/notify.sh"

_self_update_usage() {
    cat <<USAGE
usage: $AX20_NAME self-update [--channel stable|beta] [options]

  --channel stable     newest v* release tag signed by a pinned key (default)
  --channel beta       fast-forward the beta branch (signatures optional)
  --check              only report whether an update exists; writes
                       state/last-update-check (honours state/no-update-check)
    --max-age <sec>    with --check: skip if the last check is younger
    --notify           with --check: queue a notification for a new release
  --rollback           check out the commit recorded before the last update
  --verify-commits     beta: require the beta tip commit to be signed
  --insecure-skip-verify  accept unsigned releases (loud warning; dev only)
  --no-apply           do not run 'apply' after updating
USAGE
}

cmd_self_update() {
    local channel="" check=0 rollback=0 skip_verify=0 verify_commits=0 no_apply=0
    local notify=0 max_age=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --channel)
                [ $# -ge 2 ] || die 2 "--channel needs stable|beta"
                channel=$2
                shift 2
                ;;
            --channel=*)
                channel=${1#--channel=}
                shift
                ;;
            --check)
                check=1
                shift
                ;;
            --max-age)
                [ $# -ge 2 ] || die 2 "--max-age needs seconds"
                max_age=$2
                shift 2
                ;;
            --notify)
                notify=1
                shift
                ;;
            --rollback)
                rollback=1
                shift
                ;;
            --verify-commits)
                verify_commits=1
                shift
                ;;
            --insecure-skip-verify)
                skip_verify=1
                shift
                ;;
            --no-apply)
                no_apply=1
                shift
                ;;
            -h | --help)
                _self_update_usage
                return 0
                ;;
            *) die 2 "self-update: unknown argument '$1' (see self-update --help)" ;;
        esac
    done
    case "$max_age" in
        '' | *[!0-9]*) [ -z "$max_age" ] || die 2 "--max-age must be a number of seconds" ;;
    esac
    local explicit_channel=0
    if [ -z "$channel" ]; then
        channel=$(su_read_state update-channel stable)
    else
        explicit_channel=1
    fi
    case "$channel" in
        stable | beta) ;;
        *) die 2 "unknown channel '$channel' (stable|beta)" ;;
    esac

    require_root self-update
    ax20_have git || die "git is required for self-update"
    su_is_git_checkout "$AX20_SRC" \
        || die "$AX20_SRC is not a git checkout; self-update only works on an installation made by 'install' (or a git clone)"
    if [ "$explicit_channel" = 1 ] && [ "$check" = 0 ] && [ "$rollback" = 0 ]; then
        # Remember the channel so the boot-time check and rebuild follow it.
        printf '%s\n' "$channel" | su_write_state update-channel
    fi

    if [ "$check" = 1 ]; then
        _self_update_check "$channel" "$skip_verify" "$notify" "$max_age"
        return $?
    fi
    ax20_check_readonly_root
    su_require_clean "$AX20_SRC"
    if [ "$rollback" = 1 ]; then
        _self_update_rollback "$no_apply"
        return $?
    fi
    _self_update_fetch || return $?
    if [ "$channel" = beta ]; then
        _self_update_beta "$verify_commits" "$no_apply"
    else
        _self_update_stable "$skip_verify" "$no_apply"
    fi
}

# _self_update_fetch : git fetch --tags origin; exit code 3 when unreachable.
_self_update_fetch() {
    su_git "$AX20_SRC" remote get-url origin >/dev/null 2>&1 || die "the checkout has no 'origin' remote"
    if ! ax20_run su_git "$AX20_SRC" fetch --quiet --tags origin; then
        log_error "cannot fetch from origin ($(su_git "$AX20_SRC" remote get-url origin)); offline?"
        return 3
    fi
}

# _self_update_pick_stable <skip_verify> : print "<tag>\t<verified:yes|no>"
# for the newest acceptable release tag, or nothing.
_self_update_pick_stable() {
    local skip=$1 keys t tags
    tags=$(su_stable_tags "$AX20_SRC")
    [ -n "$tags" ] || return 0
    if [ "$skip" = 1 ]; then
        printf '%s\tno\n' "$(printf '%s\n' "$tags" | head -n1)"
        return 0
    fi
    keys=$(su_keys_dir)
    su_has_keys "$keys" || return 0
    for t in $tags; do
        if su_verify_tag "$AX20_SRC" "$t" "$keys"; then
            printf '%s\tyes\n' "$t"
            return 0
        fi
        log_warn "tag $t is not signed by a pinned key; ignoring it"
    done
    return 0
}

# _self_update_contains <rev> : HEAD already contains rev (no update needed).
_self_update_contains() {
    su_git "$AX20_SRC" merge-base --is-ancestor "$1" HEAD 2>/dev/null
}

# _self_update_switch <rev> <label> <no_apply> : record HEAD, move to rev,
# run migrations and apply. rev "beta:<commit>" fast-forwards the local beta
# branch to <commit> (the caller has checked that this is a fast-forward);
# anything else is checked out detached.
_self_update_switch() {
    local rev=$1 label=$2 no_apply=$3 prev rc=0
    prev=$(su_head "$AX20_SRC")
    printf '%s\n' "$prev" | su_write_state self-update.prev
    case "$rev" in
        beta:*)
            if [ "$(su_git "$AX20_SRC" symbolic-ref -q --short HEAD 2>/dev/null)" = beta ]; then
                ax20_run su_git "$AX20_SRC" merge --quiet --ff-only "${rev#beta:}" || rc=$?
            else
                ax20_run su_git "$AX20_SRC" checkout --quiet -B beta "${rev#beta:}" || rc=$?
            fi
            ;;
        *) ax20_run su_git "$AX20_SRC" checkout --quiet --detach "$rev" || rc=$? ;;
    esac
    [ "$rc" = 0 ] || die "git checkout of $label failed; the previous commit is $prev"
    log_info "checked out $label (previous: $(printf '%s' "$prev" | cut -c1-12))"
    su_run_migrations "$AX20_SRC"
    _self_update_apply "$no_apply"
}

_self_update_apply() {
    if [ "$1" = 1 ]; then
        log_info "not running apply (--no-apply)"
        return 0
    fi
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] %s apply\n' "$AX20_NAME" >&2
        return 0
    fi
    su_run_cli "$AX20_SRC" apply || die "apply failed after the update; 'self-update --rollback' returns to the previous commit"
}

_self_update_stable() {
    local skip=$1 no_apply=$2 pick tag
    if [ "$skip" = 1 ]; then
        su_insecure_warning
    fi
    if [ "$skip" != 1 ] && ! su_has_keys "$(su_keys_dir 2>/dev/null)"; then
        die "no release signing key is pinned (keys/ only has placeholders, TODO(owner)). Refusing to install unverified code. Pin a key (docs/self-update.md) or, for development only, pass --insecure-skip-verify"
    fi
    pick=$(_self_update_pick_stable "$skip")
    tag=$(printf '%s' "$pick" | cut -f1)
    if [ -z "$tag" ]; then
        if [ -z "$(su_stable_tags "$AX20_SRC")" ]; then
            die "origin has no release tags (v*) yet; use --channel beta or wait for a release"
        fi
        die "no release tag is signed by a pinned key; refusing to update (every tag was unsigned or signed by an unknown key)"
    fi
    if _self_update_contains "refs/tags/$tag"; then
        printf 'already up to date (%s contains %s)\n' "$(su_describe "$AX20_SRC")" "$tag"
        return 0
    fi
    _self_update_switch "refs/tags/$tag" "$tag" "$no_apply"
    printf 'updated to %s\n' "$tag"
}

_self_update_beta() {
    local verify=$1 no_apply=$2 tip
    tip=$(su_git "$AX20_SRC" rev-parse --verify -q 'refs/remotes/origin/beta^{commit}') \
        || die "origin has no 'beta' branch"
    if [ "$verify" = 1 ] && ! su_verify_commit "$AX20_SRC" "$tip" "$(su_keys_dir)"; then
        die "origin/beta tip $tip is not signed by a pinned key (--verify-commits)"
    fi
    if su_git "$AX20_SRC" rev-parse --verify -q refs/heads/beta >/dev/null; then
        su_git "$AX20_SRC" merge-base --is-ancestor refs/heads/beta "$tip" \
            || die "local branch 'beta' has diverged from origin/beta; refusing to rewrite it"
    fi
    if _self_update_contains "$tip"; then
        printf 'already up to date (HEAD contains origin/beta %s)\n' "$(printf '%s' "$tip" | cut -c1-12)"
        return 0
    fi
    _self_update_switch "beta:$tip" "beta ($(printf '%s' "$tip" | cut -c1-12))" "$no_apply"
    if [ "$AX20_DRY_RUN" != 1 ]; then
        su_git "$AX20_SRC" branch --quiet --set-upstream-to=origin/beta beta >/dev/null 2>&1 || true
    fi
    printf 'updated to beta %s\n' "$(printf '%s' "$tip" | cut -c1-12)"
}

_self_update_rollback() {
    local no_apply=$1 prev cur
    prev=$(su_read_state self-update.prev)
    [ -n "$prev" ] || die "nothing to roll back to: state/self-update.prev is missing (no self-update has run)"
    su_git "$AX20_SRC" cat-file -e "${prev}^{commit}" 2>/dev/null \
        || die "recorded previous commit $prev is not in the checkout"
    cur=$(su_head "$AX20_SRC")
    if [ "$cur" = "$prev" ]; then
        printf 'already at %s\n' "$prev"
        return 0
    fi
    # Swap: rolling back twice returns to where we started.
    _self_update_switch "$prev" "previous commit $(printf '%s' "$prev" | cut -c1-12)" "$no_apply"
    printf 'rolled back to %s (run self-update --rollback again to undo)\n' "$(printf '%s' "$prev" | cut -c1-12)"
}

# _self_update_check <channel> <skip_verify> <notify> <max_age>
# Writes state/last-update-check: "<iso-ts>\t<epoch>\t<result>\t<ref>" where
# result is up-to-date | available | available-unverified | fetch-failed.
_self_update_check() {
    local channel=$1 skip=$2 notify=$3 max_age=$4 marker last_epoch now result ref="" pick
    local prev_line
    if [ -e "$(su_state_file no-update-check)" ]; then
        printf 'update check disabled (state/no-update-check exists)\n'
        return 0
    fi
    marker=$(su_state_file last-update-check)
    now=$(su_now_epoch)
    prev_line=""
    [ -f "$marker" ] && prev_line=$(head -n1 "$marker")
    if [ -n "$max_age" ] && [ -n "$prev_line" ]; then
        last_epoch=$(printf '%s\n' "$prev_line" | cut -f2)
        case "$last_epoch" in
            '' | *[!0-9]*) ;;
            *)
                if [ $((now - last_epoch)) -lt "$max_age" ]; then
                    printf 'checked recently (%s); skipping\n' "$(printf '%s\n' "$prev_line" | cut -f1)"
                    return 0
                fi
                ;;
        esac
    fi
    if ! _self_update_fetch; then
        result=fetch-failed
    elif [ "$channel" = beta ]; then
        ref=$(su_git "$AX20_SRC" rev-parse --verify -q 'refs/remotes/origin/beta^{commit}' || true)
        if [ -z "$ref" ] || _self_update_contains "$ref"; then
            result=up-to-date
        else
            result=available
        fi
        ref=$(printf '%s' "$ref" | cut -c1-12)
    else
        pick=$(_self_update_pick_stable "$skip")
        ref=$(printf '%s' "$pick" | cut -f1)
        result=available
        if [ -z "$ref" ]; then
            # Nothing verifiable: report the newest tag, flagged unverified.
            ref=$(su_stable_tags "$AX20_SRC" | head -n1)
            result=available-unverified
        elif [ "$(printf '%s' "$pick" | cut -f2)" = no ]; then
            result=available-unverified
        fi
        if [ -z "$ref" ] || _self_update_contains "refs/tags/$ref"; then
            result=up-to-date
        fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$(su_now_iso)" "$now" "$result" "$ref" | su_write_state last-update-check
    case "$result" in
        up-to-date) printf 'up to date (%s)\n' "$(su_describe "$AX20_SRC")" ;;
        available) printf 'update available: %s (current %s)\n' "$ref" "$(su_describe "$AX20_SRC")" ;;
        available-unverified) printf 'update available but NOT verified by a pinned key: %s (self-update will refuse it)\n' "$ref" ;;
        fetch-failed) printf 'could not reach origin; no result\n' ;;
    esac
    if [ "$notify" = 1 ] && [ "$result" = available ] \
        && [ "$(printf '%s\n' "$prev_line" | cut -f3-4)" != "$(printf '%s\t%s' "$result" "$ref")" ]; then
        notify_enqueue info "$AX20_NAME $ref is available (installed: $(su_describe "$AX20_SRC")). It is installed automatically with the next SteamOS update, or now with: sudo $AX20_NAME self-update"
    fi
    [ "$result" = fetch-failed ] && return 3
    return 0
}
