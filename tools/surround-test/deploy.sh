#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# deploy.sh — copy the rig and the rendered candidates to the device over
# SSH and run install.sh there (as that user, no sudo).
#
# usage: deploy.sh [--out DIR] USER@HOST
#   --out DIR   build.sh output directory (default: out/ next to this script)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="$here/out"
host=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            [ $# -ge 2 ] || {
                echo "deploy: --out needs a directory" >&2
                exit 2
            }
            out=$2
            shift 2
            ;;
        -h | --help)
            sed -n '3,8p' "$0"
            exit 0
            ;;
        -*)
            echo "deploy: unknown option: $1" >&2
            exit 2
            ;;
        *)
            host=$1
            shift
            ;;
    esac
done
[ -n "$host" ] || {
    echo "usage: deploy.sh [--out DIR] USER@HOST" >&2
    exit 2
}
[ -f "$out/manifest.json" ] || {
    echo "deploy: $out/manifest.json not found; run build.sh first" >&2
    exit 2
}

stage=$(mktemp -d "${TMPDIR:-/tmp}/x20-surround-deploy.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/x20surround" "$stage/out/hrir"
cp "$here/surround-test.sh" "$here/install.sh" "$here/uninstall.sh" "$here/hrir_tool.py" "$stage/"
cp "$here"/x20surround/*.py "$stage/x20surround/"
cp "$out/manifest.json" "$stage/out/"
cp "$out"/hrir/*.wav "$stage/out/hrir/"

# shellcheck disable=SC2016  # expanded by the remote shell
# --no-xattrs / COPYFILE_DISABLE: macOS tar would add Apple attributes that
# GNU tar on the device reports as unknown header keywords, one per file.
# -m on the device: do not restore modification times, so a small clock
# difference between the two machines does not print "in the future".
COPYFILE_DISABLE=1 tar -C "$stage" --no-xattrs -czf - . | ssh "$host" '
    set -e
    d=$(mktemp -d "${TMPDIR:-/tmp}/x20-surround-install.XXXXXX")
    trap "rm -rf \"$d\"" EXIT
    tar -C "$d" -xzmf -
    bash "$d/install.sh" --from "$d"'
