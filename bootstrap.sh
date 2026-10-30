#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# bootstrap.sh — fetch ally-x20-steamos and run its installer.
#
# Prefer cloning and reading the code first (docs/install.md). If you
# accept the curl|sh trade-off anyway:
#   curl -fsSL https://raw.githubusercontent.com/cchulo/ally-x20-steamos/main/bootstrap.sh | sudo sh
#
# POSIX sh on purpose (runs before anything else exists). Environment:
#   AX20_REPO_URL  repository to clone (default below)
#   AX20_REF       tag or branch (default: newest v* release tag, else the
#                  default branch)
# Any arguments are passed to `ally-x20-steamos.sh install`
# (e.g. --force-board inside a VM).
set -eu

REPO_URL=${AX20_REPO_URL:-https://github.com/cchulo/ally-x20-steamos.git}
REF=${AX20_REF:-}

say() { printf 'ally-x20-steamos bootstrap: %s\n' "$*" >&2; }
fail() {
    say "error: $*"
    exit 1
}

command -v git >/dev/null 2>&1 || fail "git is required (it ships with SteamOS; in a container install it first)"
if [ "$(id -u)" != 0 ] && [ -z "${AX20_ROOT:-}" ]; then
    fail "run as root, e.g.: curl -fsSL <url>/bootstrap.sh | sudo sh   (set a password for 'deck' first with: passwd)"
fi

if [ -z "$REF" ]; then
    REF=$(git ls-remote --tags --refs "$REPO_URL" 'v*' 2>/dev/null \
        | sed -n 's#.*refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1) || REF=""
    [ -z "$REF" ] || REF="v$REF"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/ally-x20-steamos-bootstrap.XXXXXX") || fail "cannot create a temporary directory"
cleanup() {
    case "$tmp" in
        */ally-x20-steamos-bootstrap.*) rm -rf "$tmp" ;;
    esac
}
trap cleanup EXIT INT TERM

if [ -n "$REF" ]; then
    say "cloning $REPO_URL ($REF)"
    git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$tmp/src" || fail "git clone failed"
else
    say "cloning $REPO_URL (default branch; no release tag yet)"
    git clone --quiet --depth 1 "$REPO_URL" "$tmp/src" || fail "git clone failed"
fi

# The installer clones again into /var/lib/ally-x20-steamos/src (from the
# same URL and ref) and runs everything from there; this copy is temporary.
bash "$tmp/src/ally-x20-steamos.sh" install --repo "$REPO_URL" ${REF:+--ref "$REF"} "$@"
