#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/guest/roundtrip-test.sh — install -> status -> uninstall must leave the
# system byte-identical (plan §6 check 1). Runs INSIDE the VM, as root.
#
# Usage: roundtrip-test.sh [--repo DIR] [--out DIR] [--user NAME]
#                          [--watch PATH]... [--exclude ERE]...
#   --repo DIR     ally-x20-steamos checkout inside the VM (default: two
#                  levels above this script, i.e. the repo it ships in)
#   --out DIR      where logs and snapshots go (default ./roundtrip-<date>)
#   --user NAME    desktop user whose ~/.config is watched (default deck)
#   --watch PATH   extra tree to snapshot (repeatable)
#   --exclude ERE  extended regex of paths to ignore (repeatable); defaults
#                  cover files the OS rewrites on its own (see below)
#
# Exit status: 0 identical, 1 differences found, 77 the CLI has no
# install/uninstall commands yet (skip), 2 usage/setup error.
#
# Watched by default: /etc, /var/lib/ally-x20-steamos, /opt/ally-x20-steamos,
# /esp/loader/entries, /efi/EFI/steamos, ~USER/.config. Every manifest path
# recorded after install must be gone after uninstall.
set -eu

RT_SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=vm/guest/measure-etc-survival.sh
. "$RT_SELF_DIR/measure-etc-survival.sh"

rt_die() {
    printf 'roundtrip-test: error: %s\n' "$*" >&2
    exit 2
}
rt_log() { printf 'roundtrip-test: %s\n' "$*" >&2; }

# Paths the OS itself rewrites between two snapshots taken minutes apart.
RT_DEFAULT_EXCLUDES='^/etc/(ld\.so\.cache|mtab|resolv\.conf|adjtime|\.updated|machine-id)$
^/etc/udev/hwdb\.bin$
^/home/[^/]+/\.config/(pulse|plasma|kde|KDE|session|ksmserverrc|kwinrc|Trolltech\.conf)
^/home/[^/]+/\.config/[^/]*(\.lock|~)$'

# rt_snapshot_all <out-file> <tree>... : snapshot every existing tree.
rt_snapshot_all() {
    local out=$1 t
    shift
    : >"$out"
    for t in "$@"; do
        if [ -d "$t" ]; then
            printf '%s\td\t-\n' "$t" >>"$out"
            es_snapshot "$t" "$t" >>"$out"
        fi
    done
}

# rt_filter <excludes-file> : drop snapshot/compare lines whose path matches.
rt_filter() {
    awk -F '\t' -v exf="$1" '
        BEGIN { while ((getline l < exf) > 0) if (l != "") ex[++n] = l }
        {
            p = ($2 ~ /^\//) ? $2 : $1
            for (i = 1; i <= n; i++) if (p ~ ex[i]) next
            print
        }
    '
}

# rt_manifest_paths <manifest> : print the "path" of each JSON line.
rt_manifest_paths() {
    [ -f "$1" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '.path // empty' "$1"
    else
        sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1"
    fi
}

rt_main() {
    local repo="" out="" user=deck watch="" excludes=""
    repo=$(cd "$RT_SELF_DIR/../.." && pwd)
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo | --out | --user | --watch | --exclude)
                [ $# -ge 2 ] || rt_die "$1 needs a value"
                case "$1" in
                    --repo) repo=$2 ;;
                    --out) out=$2 ;;
                    --user) user=$2 ;;
                    --watch) watch="${watch}$2
" ;;
                    --exclude) excludes="${excludes}$2
" ;;
                esac
                shift
                ;;
            -h | --help)
                sed -n '3,/^set -eu/p' "${BASH_SOURCE[0]}" | sed -e '/^set -eu/d' -e 's/^# \{0,1\}//'
                return 0
                ;;
            *) rt_die "unknown option: $1" ;;
        esac
        shift
    done
    local cli="$repo/ally-x20-steamos.sh"
    [ -x "$cli" ] || rt_die "CLI not found: $cli (use --repo)"
    local help
    help=$("$cli" help 2>&1 || true)
    case "$help" in
        *install*uninstall* | *uninstall*install*) ;;
        *)
            rt_log "the CLI has no install/uninstall commands yet; skipping"
            return 77
            ;;
    esac

    [ "$(id -u)" = 0 ] || rt_die "run as root (sudo -n) so every watched file is readable"
    [ -n "$out" ] || out="$PWD/roundtrip-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$out"

    local home trees t
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)
    [ -n "$home" ] || home="/home/$user"
    trees="/etc
/var/lib/ally-x20-steamos
/opt/ally-x20-steamos
/esp/loader/entries
/efi/EFI/steamos
$home/.config
$watch"
    printf '%s\n%s' "$RT_DEFAULT_EXCLUDES" "$excludes" >"$out/excludes"

    local IFS_SAVE=$IFS
    IFS='
'
    # shellcheck disable=SC2086  # newline-split list of trees
    set -- $trees
    IFS=$IFS_SAVE

    rt_log "snapshot before -> $out/before.tsv"
    rt_snapshot_all "$out/before.raw" "$@"
    rt_filter "$out/excludes" <"$out/before.raw" >"$out/before.tsv"

    local rc=0
    rt_log "install"
    "$cli" --yes install >"$out/install.log" 2>&1 || {
        rt_log "install failed (see $out/install.log)"
        rc=1
    }
    "$cli" status >"$out/status.log" 2>&1 || rt_log "status exited non-zero (see $out/status.log)"
    rt_manifest_paths /var/lib/ally-x20-steamos/manifest >"$out/manifest-paths"
    cp /var/lib/ally-x20-steamos/manifest "$out/manifest.jsonl" 2>/dev/null || true
    rt_log "manifest lists $(wc -l <"$out/manifest-paths" | tr -d ' ') paths"

    rt_log "uninstall"
    "$cli" --yes uninstall >"$out/uninstall.log" 2>&1 || {
        rt_log "uninstall failed (see $out/uninstall.log)"
        rc=1
    }

    rt_log "snapshot after -> $out/after.tsv"
    rt_snapshot_all "$out/after.raw" "$@"
    rt_filter "$out/excludes" <"$out/after.raw" >"$out/after.tsv"

    es_compare "$out/before.tsv" "$out/after.tsv" | awk -F '\t' '$1 != "same"' >"$out/diff.tsv"
    if [ -s "$out/diff.tsv" ]; then
        rt_log "system differs after uninstall:"
        cat "$out/diff.tsv" >&2
        rc=1
    fi

    # Every manifest path must be gone unless it existed before install.
    : >"$out/leftovers"
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        if [ -e "$t" ] || [ -L "$t" ]; then
            awk -F '\t' -v p="$t" '$1 == p { f = 1 } END { exit !f }' "$out/before.raw" \
                || printf '%s\n' "$t" >>"$out/leftovers"
        fi
    done <"$out/manifest-paths"
    if [ -s "$out/leftovers" ]; then
        rt_log "manifest paths still present after uninstall:"
        cat "$out/leftovers" >&2
        rc=1
    fi

    if [ "$rc" = 0 ]; then
        rt_log "PASS: byte-identical after install/uninstall"
    else
        rt_log "FAIL (details in $out)"
    fi
    return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    rc=0
    rt_main "$@" || rc=$?
    exit "$rc"
fi
