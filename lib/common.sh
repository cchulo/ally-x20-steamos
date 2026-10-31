# SPDX-License-Identifier: GPL-2.0-only
# lib/common.sh — shared constants, logging, path helpers for ally-x20-steamos.
#
# Sourced by the CLI dispatcher, every cmd/*.sh, every components/*.sh and
# the test helper. Must stay compatible with bash 3.2 (macOS dev hosts) and
# bash 5 (SteamOS). No associative arrays, no mapfile, no ${var,,}.
#
# Path contract
# -------------
# Every filesystem path we touch is built from AX20_ROOT so that the whole
# tool can be exercised against a fixture tree in tests ("--root <dir>"):
#   ax20_path /etc/modprobe.d/x.conf   ->  ${AX20_ROOT}/etc/modprobe.d/x.conf
# AX20_ROOT is empty on a real system. Never hard-code an absolute path
# without going through ax20_path (a policy test greps for offenders).

if [ -n "${AX20_COMMON_LOADED:-}" ]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
AX20_COMMON_LOADED=1

AX20_NAME="ally-x20-steamos"
AX20_BOARD="RC74XA"
export AX20_NAME AX20_BOARD

# Resolve the source checkout root (the directory holding ally-x20-steamos.sh).
if [ -z "${AX20_SRC:-}" ]; then
    _ax20_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    AX20_SRC=$(cd "${_ax20_lib_dir}/.." && pwd)
    unset _ax20_lib_dir
fi
export AX20_SRC

# Fixture root prefix. Empty on a live system. Normalised to have no
# trailing slash so "${AX20_ROOT}/etc" is always well formed.
AX20_ROOT="${AX20_ROOT:-}"
case "$AX20_ROOT" in
    */) AX20_ROOT="${AX20_ROOT%/}" ;;
esac
export AX20_ROOT

# Behavioural flags (set by the dispatcher from global options).
AX20_DRY_RUN="${AX20_DRY_RUN:-0}"
AX20_VERBOSE="${AX20_VERBOSE:-0}"
AX20_I_KNOW="${AX20_I_KNOW:-0}"
AX20_ASSUME_YES="${AX20_ASSUME_YES:-0}"
export AX20_DRY_RUN AX20_VERBOSE AX20_I_KNOW AX20_ASSUME_YES

# Canonical locations (all relative to AX20_ROOT; use ax20_path to resolve).
AX20_STATE_REL="/var/lib/${AX20_NAME}"
# Files the kernel/udev need BEFORE /var and /home are mounted (the modprobe
# install helper, the staged .ko.zst, the amp tuning firmware). /etc is an
# overlay set up by the initramfs, so it exists when udev loads modules; its
# upper dir lives in the slot's var and is rsynced to the other slot on
# update. Measured on the X20: a helper under /var/lib (-> /home) gave
# "No such file or directory" at udev time and no module loaded at all.
AX20_EARLY_REL="/etc/${AX20_NAME}"
AX20_OPT_REL="/opt/${AX20_NAME}"
AX20_MANIFEST_REL="${AX20_STATE_REL}/manifest"
AX20_STATUS_JSON_REL="${AX20_STATE_REL}/state/status.json"
AX20_LOG_REL="${AX20_STATE_REL}/log/${AX20_NAME}.log"
export AX20_STATE_REL AX20_EARLY_REL AX20_OPT_REL AX20_MANIFEST_REL AX20_STATUS_JSON_REL AX20_LOG_REL

# ax20_path <absolute-path> : prefix with AX20_ROOT.
ax20_path() {
    case "$1" in
        /*) printf '%s%s\n' "$AX20_ROOT" "$1" ;;
        *) printf '%s/%s\n' "$AX20_ROOT" "$1" ;;
    esac
}

ax20_state_dir() { ax20_path "$AX20_STATE_REL"; }

# Where the state really lives. SteamOS has a separate var-A/var-B partition
# per slot (256 MiB, rsynced across on update), so /var/lib/ally-x20-steamos
# is a symlink into the shared /home partition, like SteamOS's own
# /home/.steamos/offload. AX20_STATE_REL stays the canonical path everywhere.
AX20_STATE_REAL_REL="/home/.${AX20_NAME}"
export AX20_STATE_REAL_REL

# ax20_state_dir_ensure : make sure the state dir exists on this root. If
# /var/lib/ally-x20-steamos is absent and the root has a /home, create the
# real directory under /home and the symlink; if a real directory is already
# there (older install, fixture roots) it is kept as is. Prints the path.
ax20_state_dir_ensure() {
    local link real
    link=$(ax20_state_dir)
    real=$(ax20_path "$AX20_STATE_REAL_REL")
    if [ -L "$link" ] || [ -d "$link" ]; then
        printf '%s\n' "$link"
        return 0
    fi
    if [ -d "$(ax20_path /home)" ]; then
        if [ "$AX20_DRY_RUN" = 1 ]; then
            printf '[dry-run] mkdir -p %s; ln -s ../..%s %s\n' "$real" "$AX20_STATE_REAL_REL" "$link" >&2
        else
            mkdir -p "$real" "$(dirname "$link")" || die "cannot create $real"
            # Relative, so it resolves inside a mounted slot or a fixture root too.
            ln -s "../..$AX20_STATE_REAL_REL" "$link" || die "cannot create symlink $link"
        fi
    else
        ax20_mkdir_p "$link" >/dev/null
    fi
    printf '%s\n' "$link"
}
ax20_manifest_file() { ax20_path "$AX20_MANIFEST_REL"; }

# ---------------------------------------------------------------- logging --
_ax20_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

_ax20_log_to_file() {
    local f
    f=$(ax20_path "$AX20_LOG_REL")
    if [ -d "$(dirname "$f")" ] && [ -w "$(dirname "$f")" ]; then
        printf '%s %s %s\n' "$(_ax20_ts)" "$1" "$2" >>"$f" 2>/dev/null || true
    fi
}

log_info() {
    printf '%s: %s\n' "$AX20_NAME" "$*" >&2
    _ax20_log_to_file INFO "$*"
}
log_warn() {
    printf '%s: warning: %s\n' "$AX20_NAME" "$*" >&2
    _ax20_log_to_file WARN "$*"
}
log_error() {
    printf '%s: error: %s\n' "$AX20_NAME" "$*" >&2
    _ax20_log_to_file ERROR "$*"
}
log_debug() {
    if [ "$AX20_VERBOSE" = 1 ]; then
        printf '%s: debug: %s\n' "$AX20_NAME" "$*" >&2
    fi
}
# die [exit-code] <message>
die() {
    local code=1
    case "$1" in
        '' | *[!0-9]*) ;;
        *)
            code=$1
            shift
            ;;
    esac
    log_error "$*"
    exit "$code"
}

# -------------------------------------------------------------- utilities --
ax20_have() { command -v "$1" >/dev/null 2>&1; }

# ax20_sha256 <file> : hex digest only. Works with coreutils and macOS.
# Reads via stdin: GNU sha256sum escapes file names containing a backslash
# or newline and prefixes the digest line with "\".
ax20_sha256() {
    if ax20_have sha256sum; then
        sha256sum <"$1" | cut -d' ' -f1
    elif ax20_have shasum; then
        shasum -a 256 <"$1" | cut -d' ' -f1
    else
        die "no sha256 tool available"
    fi
}

# ax20_sha256_string <string>
ax20_sha256_string() {
    if ax20_have sha256sum; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    fi
}

# ax20_version_ge <a> <b> : true if a >= b (dotted versions, sort -V).
ax20_version_ge() {
    [ "$1" = "$2" ] && return 0
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# ax20_is_root : true when running as uid 0.
ax20_is_root() { [ "$(id -u)" = 0 ]; }

# require_root : die unless root, or unless operating on a fixture root
# (AX20_ROOT set) where privileges are meaningless.
require_root() {
    if [ -n "$AX20_ROOT" ] || [ "${AX20_ALLOW_UNPRIVILEGED:-0}" = 1 ]; then
        return 0
    fi
    ax20_is_root || die "this command must run as root (try: sudo $AX20_NAME $*)"
}

# ax20_run <cmd...> : execute, or print when dry-running.
ax20_run() {
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] %s\n' "$*" >&2
        return 0
    fi
    log_debug "run: $*"
    "$@"
}

# ax20_mkdir_p <dir> : create directory chain; prints "created" if the leaf
# did not exist before (so callers can record created_dir in the manifest).
ax20_mkdir_p() {
    if [ -d "$1" ]; then
        printf 'existed\n'
        return 0
    fi
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] mkdir -p %s\n' "$1" >&2
        printf 'created\n'
        return 0
    fi
    mkdir -p "$1" || die "cannot create directory $1"
    printf 'created\n'
}

# ax20_mkdir_p_list <dir> : like ax20_mkdir_p, but prints every directory
# that had to be created, top-most first, one per line (nothing if all
# existed). Used by the manifest so uninstall can remove each of them again.
ax20_mkdir_p_list() {
    local d=$1 missing="" out
    while [ -n "$d" ] && [ "$d" != / ] && [ ! -d "$d" ]; do
        missing="$d
$missing"
        d=$(dirname "$d")
    done
    [ -n "$missing" ] || return 0
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] mkdir -p %s\n' "$1" >&2
    else
        mkdir -p "$1" || die "cannot create directory $1"
    fi
    out=$(printf '%s' "$missing" | grep -v '^$')
    printf '%s\n' "$out"
}

# ax20_atomic_write <dest> [mode] : write stdin to dest via temp+rename.
ax20_atomic_write() {
    local dest=$1 mode=${2:-0644} tmp
    if [ "$AX20_DRY_RUN" = 1 ]; then
        cat >/dev/null
        printf '[dry-run] write %s (mode %s)\n' "$dest" "$mode" >&2
        return 0
    fi
    tmp=$(mktemp "${dest}.XXXXXX") || die "cannot create temp file next to $dest"
    if ! cat >"$tmp"; then
        rm -f "$tmp"
        die "write to $dest failed"
    fi
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest" || {
        rm -f "$tmp"
        die "rename into $dest failed"
    }
}

# ax20_copy_atomic <src> <dest> [mode]
ax20_copy_atomic() {
    local src=$1 dest=$2 mode=${3:-0644}
    [ -f "$src" ] || die "source file missing: $src"
    ax20_atomic_write "$dest" "$mode" <"$src"
}

# --------------------------------------------------- read-only root policy --
# SteamOS keeps / read-only. We never toggle it (policy test greps for the
# toggling commands). If someone else disabled it, stock files may have been
# altered by other tools, so refuse to operate unless --i-know was given.
ax20_check_readonly_root() {
    local status_cmd state
    status_cmd=$(ax20_path /usr/bin/steamos-readonly)
    if [ -n "$AX20_ROOT" ]; then
        # Fixture roots: honour a marker file so tests can simulate both states.
        if [ -f "$(ax20_path /.ax20-readonly-disabled)" ]; then
            state=disabled
        else
            state=enabled
        fi
    elif [ -x "$status_cmd" ]; then
        state=$("$status_cmd" status 2>/dev/null || echo unknown)
    else
        # Not SteamOS (or fixture) – nothing to check.
        return 0
    fi
    case "$state" in
        *disabled*)
            if [ "$AX20_I_KNOW" = 1 ]; then
                log_warn "root filesystem is writable (read-only mode is off); continuing because --i-know was given"
                return 0
            fi
            die "root filesystem is writable (steamos-readonly is disabled). $AX20_NAME never needs this and refuses to run in that state; re-enable read-only mode, or pass --i-know if you understand the risk"
            ;;
    esac
    return 0
}

# ax20_version : the repo version (VERSION file + git describe when available).
ax20_version() {
    local v
    v=$(cat "$AX20_SRC/VERSION" 2>/dev/null || echo unknown)
    if ax20_have git && git -C "$AX20_SRC" rev-parse --short HEAD >/dev/null 2>&1; then
        v="$v ($(git -C "$AX20_SRC" rev-parse --short HEAD))"
    fi
    printf '%s\n' "$v"
}
