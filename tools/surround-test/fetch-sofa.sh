#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# fetch-sofa.sh — download and verify the HRTF (SOFA) sets listed in hrtf.lock.
#
# The fetch script of the removed audio_dsp component
# (899ba9b:overlay/home/hrtf/fetch-hrtf.sh), reused for the blind-test rig.
# Standalone: no ally-x20-steamos libraries. Runs on the development
# machine; the device only ever receives the rendered .wav files.
#
# usage: fetch-sofa.sh [--lock FILE] [--dest DIR] [--source-dir DIR] [NAME...]
#        fetch-sofa.sh [--lock FILE] --list
#   --lock FILE        lock file (default: hrtf.lock next to this script)
#   --dest DIR         where to put <name>.sofa (default: current directory)
#   --source-dir DIR   copy <name>.sofa from DIR instead of downloading
#                      (offline runs and tests); still verified
#   --list             print "<name> <license> <url>" for every set
#   NAME...            sets to fetch (default: all sets in the lock file)
# Exit status: 0 all good, 1 download/verification failure, 2 usage error.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
lock="$here/hrtf.lock"
dest=.
source_dir=""
mode=fetch

err() { printf 'fetch-sofa: %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --lock)
            [ $# -ge 2 ] || {
                err "--lock needs a file"
                exit 2
            }
            lock=$2
            shift 2
            ;;
        --dest)
            [ $# -ge 2 ] || {
                err "--dest needs a directory"
                exit 2
            }
            dest=$2
            shift 2
            ;;
        --source-dir)
            [ $# -ge 2 ] || {
                err "--source-dir needs a directory"
                exit 2
            }
            source_dir=$2
            shift 2
            ;;
        --list)
            mode=list
            shift
            ;;
        -h | --help)
            sed -n '3,18p' "$0"
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            err "unknown option: $1"
            exit 2
            ;;
        *) break ;;
    esac
done

[ -f "$lock" ] || {
    err "lock file not found: $lock"
    exit 2
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# set_field <name> <field-number> : field of the "set" record (3=sha 4=size
# 5=license 6=url, counting "set" as 1 and the name as 2).
set_field() {
    awk -v n="$1" -v f="$2" '$1 == "set" && $2 == n { print $f; exit }' "$lock"
}

all_sets() { awk '$1 == "set" { print $2 }' "$lock"; }

case "$mode" in
    list)
        awk '$1 == "set" { print $2, $5, $6 }' "$lock"
        exit 0
        ;;
esac

if [ $# -eq 0 ]; then
    # shellcheck disable=SC2046  # names never contain whitespace
    set -- $(all_sets)
fi

download() {
    local url=$1 out=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 20 -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" "$url"
    else
        err "neither curl nor wget is available"
        return 1
    fi
}

mkdir -p "$dest"
rc=0
for name in "$@"; do
    case "$name" in
        *[!A-Za-z0-9._-]* | '')
            err "invalid set name: $name"
            rc=1
            continue
            ;;
    esac
    sha=$(set_field "$name" 3)
    url=$(set_field "$name" 6)
    if [ -z "$sha" ] || [ -z "$url" ]; then
        err "unknown set: $name (see --list)"
        rc=1
        continue
    fi
    out="$dest/$name.sofa"
    if [ -f "$out" ] && [ "$(sha256_of "$out")" = "$sha" ]; then
        printf '%s %s\n' "$name" "$out"
        continue
    fi
    part="$out.part"
    rm -f "$part"
    if [ -n "$source_dir" ]; then
        if ! cp "$source_dir/$name.sofa" "$part" 2>/dev/null; then
            err "$name: not found in $source_dir"
            rm -f "$part"
            rc=1
            continue
        fi
    elif ! download "$url" "$part"; then
        err "$name: download failed: $url"
        rm -f "$part"
        rc=1
        continue
    fi
    got=$(sha256_of "$part")
    if [ "$got" != "$sha" ]; then
        err "$name: SHA-256 mismatch (got $got, expected $sha)"
        rm -f "$part"
        rc=1
        continue
    fi
    mv -f "$part" "$out"
    printf '%s %s\n' "$name" "$out"
done
exit $rc
