# SPDX-License-Identifier: GPL-2.0-only
# lib/selfupdate.sh — helpers shared by install, self-update and status:
# state files, the pinned signing keys, signature verification of the git
# checkout, migrations, and running sibling commands of a checkout.
#
# Function prefix su_ (the "update" component owns update_*).
#
# Trust model (plan §4.4, docs/self-update.md): the public keys in keys/ are
# copied ("pinned") into /var/lib/ally-x20-steamos/keys at install time.
# self-update verifies tags against the pinned copy, never against whatever
# the checkout currently contains, so a tag cannot bring its own key.

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"

SU_SRC_REL="${AX20_STATE_REL}/src"
SU_KEYS_REL="${AX20_STATE_REL}/keys"
SU_STATE_SUBDIRS="modules firmware cache backup state log bin"
export SU_SRC_REL SU_KEYS_REL SU_STATE_SUBDIRS

# su_state_file <name> : absolute (root-prefixed) path of state/<name>.
su_state_file() { ax20_path "${AX20_STATE_REL}/state/$1"; }

# su_ensure_state_subdir : make sure state/ exists (dry-run aware).
su_ensure_state_subdir() {
    ax20_mkdir_p "$(ax20_path "${AX20_STATE_REL}/state")" >/dev/null
}

# su_write_state <name> : stdin -> state/<name>, atomically.
su_write_state() {
    su_ensure_state_subdir
    ax20_atomic_write "$(su_state_file "$1")" 0644
}

# su_read_state <name> [default] : first line of state/<name>.
su_read_state() {
    local f v=""
    f=$(su_state_file "$1")
    if [ -f "$f" ]; then
        v=$(head -n1 "$f" 2>/dev/null)
    fi
    [ -n "$v" ] || v=${2:-}
    printf '%s\n' "$v"
}

# su_json_str <string> : print a JSON string literal (quotes included).
# Control characters become spaces; values here are single-line words.
su_json_str() {
    printf '"%s"' "$(printf '%s' "$1" | tr '\t\r\n' '   ' | tr -d '\000-\010\013\014\016-\037' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

su_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
su_now_epoch() { date '+%s'; }

# ----------------------------------------------------------------- git --
# su_git <repo> <git args...> : git with a stable, non-interactive setup.
su_git() {
    local repo=$1
    shift
    GIT_TERMINAL_PROMPT=0 git -C "$repo" -c advice.detachedHead=false "$@"
}

# su_is_git_checkout <dir> : dir is the top level of a git work tree.
su_is_git_checkout() {
    local top
    [ -d "$1" ] && ax20_have git || return 1
    top=$(su_git "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ "$(cd "$1" && pwd -P)" = "$(cd "$top" && pwd -P)" ]
}

# su_require_clean <repo> : die if the work tree has any local change.
su_require_clean() {
    local changes
    changes=$(su_git "$1" status --porcelain 2>/dev/null) || die "cannot read git status of $1"
    if [ -n "$changes" ]; then
        log_error "the checkout at $1 has local modifications:"
        printf '%s\n' "$changes" | sed 's/^/    /' >&2
        die "refusing to update over local changes (they are never discarded). Commit, stash or remove them, then retry"
    fi
}

# su_head <repo> : full commit id of HEAD.
su_head() { su_git "$1" rev-parse --verify -q 'HEAD^{commit}'; }

# su_describe <repo> : nearest v* tag description of HEAD, or the short commit.
su_describe() {
    su_git "$1" describe --tags --match 'v[0-9]*' 2>/dev/null \
        || su_git "$1" rev-parse --short HEAD 2>/dev/null || printf 'unknown\n'
}

# su_stable_tags <repo> : release tags newest first. Pre-releases with a
# '-' suffix (v1.2.0-rc1) are not part of the stable channel.
su_stable_tags() {
    su_git "$1" tag -l 'v[0-9]*' --sort=-version:refname | grep -v -- '-' || true
}

# ---------------------------------------------------------------- keys --
# su_keys_dir : the pinned key directory, falling back to the checkout's
# keys/ (with a warning) when install never pinned anything.
su_keys_dir() {
    local pinned
    pinned=$(ax20_path "$SU_KEYS_REL")
    if [ -d "$pinned" ]; then
        printf '%s\n' "$pinned"
    else
        log_warn "no pinned keys at $SU_KEYS_REL (install not run?); using the keys in $AX20_SRC/keys"
        printf '%s\n' "$AX20_SRC/keys"
    fi
}

# su_gpg_key_files <dir> : *.asc files that contain real key material.
su_gpg_key_files() {
    local f
    for f in "$1"/*.asc; do
        [ -f "$f" ] || continue
        if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$f"; then
            printf '%s\n' "$f"
        fi
    done
    return 0
}

# su_has_ssh_signers <dir> : allowed_signers has at least one entry.
su_has_ssh_signers() {
    [ -f "$1/allowed_signers" ] && grep -qv -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1/allowed_signers"
}

# su_has_keys <dir> : any usable key (GPG or SSH) present.
su_has_keys() {
    [ -n "$(su_gpg_key_files "$1")" ] || su_has_ssh_signers "$1"
}

# _su_keyring <keydir> : build a throwaway GNUPGHOME holding only the
# pinned GPG keys plus a copy of allowed_signers; prints its path.
_su_keyring() {
    local keys=$1 gh f
    gh=$(mktemp -d "${TMPDIR:-/tmp}/ax20-gnupg.XXXXXX") || die "cannot create a temporary keyring"
    chmod 0700 "$gh"
    # An existing (empty) common.conf stops gpg >= 2.4 from switching a new
    # home to keyboxd, so no daemon is needed just to import and verify.
    : >"$gh/common.conf"
    : >"$gh/allowed_signers"
    if su_has_ssh_signers "$keys"; then
        cp "$keys/allowed_signers" "$gh/allowed_signers"
    fi
    if ax20_have gpg; then
        for f in $(su_gpg_key_files "$keys"); do
            GNUPGHOME="$gh" gpg --batch --quiet --import "$f" >/dev/null 2>&1 \
                || log_warn "could not import key file $f"
        done
    fi
    printf '%s\n' "$gh"
}

_su_keyring_drop() {
    local gh=${1:?}
    if ax20_have gpgconf; then
        GNUPGHOME="$gh" gpgconf --kill all >/dev/null 2>&1 || true
    fi
    case "$gh" in
        */ax20-gnupg.*) rm -rf "${gh:?}" ;;
    esac
}

# su_verify_tag <repo> <tag> <keydir> : 0 if <tag> is an annotated tag whose
# signature verifies against a pinned key AND whose embedded tag name
# matches the ref (stops replaying an older signed tag under a new name).
su_verify_tag() {
    local repo=$1 tag=$2 keys=$3 name gh rc=1
    name=$(su_git "$repo" cat-file tag "refs/tags/$tag" 2>/dev/null | sed -n 's/^tag //p' | head -n1)
    if [ "$name" != "$tag" ]; then
        log_debug "tag $tag: not an annotated tag, or embedded name '$name' differs"
        return 1
    fi
    su_has_keys "$keys" || return 1
    gh=$(_su_keyring "$keys")
    if GNUPGHOME="$gh" su_git "$repo" -c gpg.ssh.allowedSignersFile="$gh/allowed_signers" \
        verify-tag "refs/tags/$tag" >/dev/null 2>&1; then
        rc=0
    fi
    _su_keyring_drop "$gh"
    return "$rc"
}

# su_verify_commit <repo> <rev> <keydir> : 0 if the commit is signed by a pinned key.
su_verify_commit() {
    local repo=$1 rev=$2 keys=$3 gh rc=1
    su_has_keys "$keys" || return 1
    gh=$(_su_keyring "$keys")
    if GNUPGHOME="$gh" su_git "$repo" -c gpg.ssh.allowedSignersFile="$gh/allowed_signers" \
        verify-commit "$rev" >/dev/null 2>&1; then
        rc=0
    fi
    _su_keyring_drop "$gh"
    return "$rc"
}

# su_insecure_warning : the loud banner for --insecure-skip-verify.
su_insecure_warning() {
    cat >&2 <<'WARN'
########################################################################
#  WARNING: --insecure-skip-verify                                     #
#  Signature verification of ally-x20-steamos releases is DISABLED.    #
#  Whoever controls the git remote (or the network path to it) can     #
#  now run code as root on this device. Only use this for development  #
#  or before the project owner has published a signing key.            #
########################################################################
WARN
    log_warn "signature verification skipped (--insecure-skip-verify)"
}

# su_pin_keys <checkout> [force] : copy keys/*.asc and keys/allowed_signers
# into the pinned key directory. An existing pin is kept unless force=1.
su_pin_keys() {
    local src=$1/keys force=${2:-0} dest f same=1
    dest=$(ax20_path "$SU_KEYS_REL")
    if [ ! -d "$src" ]; then
        log_warn "checkout has no keys/ directory; nothing to pin"
        return 0
    fi
    if [ -d "$dest" ] && [ "$force" != 1 ]; then
        for f in "$src"/*.asc "$src"/allowed_signers; do
            [ -f "$f" ] || continue
            cmp -s "$f" "$dest/$(basename "$f")" || same=0
        done
        if [ "$same" = 0 ]; then
            log_warn "keys/ in the checkout differ from the pinned keys; keeping the pinned ones (re-pin with: install --repin-keys)"
        fi
        return 0
    fi
    ax20_mkdir_p "$dest" >/dev/null
    if [ "$AX20_DRY_RUN" != 1 ]; then
        for f in "$dest"/*.asc "$dest"/allowed_signers; do
            [ -f "$f" ] || continue
            rm -f -- "$f"
        done
    fi
    for f in "$src"/*.asc "$src"/allowed_signers; do
        [ -f "$f" ] || continue
        ax20_copy_atomic "$f" "$dest/$(basename "$f")" 0644
    done
    if ! su_has_keys "$src"; then
        log_warn "keys/ holds only placeholders (TODO(owner)): self-update will refuse releases until a real signing key is pinned"
    fi
    log_info "pinned signing keys into $SU_KEYS_REL"
}

# su_keys_digest <dir> : one sha256 over the key files (for installed-from).
su_keys_digest() {
    local f all=""
    for f in "$1"/*.asc "$1"/allowed_signers; do
        [ -f "$f" ] || continue
        all="$all$(basename "$f")=$(ax20_sha256 "$f");"
    done
    ax20_sha256_string "$all"
}

# ---------------------------------------------------------- migrations --
# su_run_migrations <checkout> : run migrations/[0-9]*.sh in lexical order,
# each at most once; applied names are appended to state/migrations.done as
# "<name>\t<ts>\t<commit>". A failing migration stops the run and is not
# recorded, so the next self-update retries it.
su_run_migrations() {
    local src=$1 done_file m name commit
    done_file=$(su_state_file migrations.done)
    [ -d "$src/migrations" ] || return 0
    commit=$(su_head "$src" 2>/dev/null || printf 'unknown')
    for m in "$src"/migrations/[0-9]*.sh; do
        [ -f "$m" ] || continue
        name=$(basename "$m")
        if [ -f "$done_file" ] && cut -f1 "$done_file" | grep -Fxq -- "$name"; then
            continue
        fi
        if [ "$AX20_DRY_RUN" = 1 ]; then
            printf '[dry-run] migration %s\n' "$name" >&2
            continue
        fi
        log_info "running migration $name"
        AX20_SRC="$src" bash "$m" \
            || die "migration $name failed; later migrations were not run. Fix the cause and re-run '$AX20_NAME self-update' (pending migrations are retried)"
        su_ensure_state_subdir
        printf '%s\t%s\t%s\n' "$name" "$(su_now_iso)" "$commit" >>"$done_file"
    done
}

# su_run_cli <checkout> <command> [args...] : run a command of that
# checkout's CLI if the command exists there. Returns its exit code, or 0
# with a note when the command is not available (yet).
su_run_cli() {
    local src=$1 cmd=$2
    shift 2
    if [ -f "$src/cmd/$cmd.sh" ] && [ -f "$src/ally-x20-steamos.sh" ]; then
        bash "$src/ally-x20-steamos.sh" "$cmd" "$@"
        return $?
    fi
    printf '%s not available yet in %s (skipped)\n' "$cmd" "$src" >&2
    return 0
}
