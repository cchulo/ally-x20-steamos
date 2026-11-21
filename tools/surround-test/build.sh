#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# build.sh — phase 1 of the surround blind-test rig: fetch the SOFA sets,
# render every candidate, run the offline checks, write the manifest.
#
# usage: build.sh [--out DIR] [--lock FILE] [--source-dir DIR]
#                 [--user-wav FILE] [NAME...]
#   --out DIR          output directory (default: out/ next to this script;
#                      ignored by git)
#   --lock FILE        lock file (default: hrtf.lock next to this script)
#   --source-dir DIR   take <name>.sofa from DIR instead of downloading
#   --user-wav FILE    add a local 14-channel 48 kHz HRIR file as candidate
#                      "user" (copied into the output directory, which is
#                      never committed; it is not fetched from anywhere)
#   NAME...            sets from hrtf.lock (default: all)
#
# Result:
#   DIR/sofa/<name>.sofa          downloaded, SHA-256 checked
#   DIR/hrir/<name>-full.wav      7.1 through the HRTF
#   DIR/hrir/<name>-dry.wav       FL/FR/FC dry, sides and rears through it
#   DIR/hrir/user.wav             with --user-wav
#   DIR/manifest.json, DIR/report.txt
#
# Runs on a development machine or CI (python3 with numpy, scipy, h5py), not
# on the device. Exit status: 0 ok (warnings allowed), 1 a candidate failed a
# check or a step failed, 2 usage error.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="$here/out"
lock="$here/hrtf.lock"
source_dir=""
user_wav=""

err() { printf 'build: %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --out | --lock | --source-dir | --user-wav)
            [ $# -ge 2 ] || {
                err "$1 needs a value"
                exit 2
            }
            case "$1" in
                --out) out=$2 ;;
                --lock) lock=$2 ;;
                --source-dir) source_dir=$2 ;;
                --user-wav) user_wav=$2 ;;
            esac
            shift 2
            ;;
        -h | --help)
            sed -n '3,26p' "$0"
            exit 0
            ;;
        -*)
            err "unknown option: $1"
            exit 2
            ;;
        *) break ;;
    esac
done

python3 -c 'import numpy, scipy, h5py' 2>/dev/null || {
    err "python3 needs numpy, scipy and h5py (see README.md, \"Development machine\")"
    exit 2
}
if [ -n "$user_wav" ] && [ ! -f "$user_wav" ]; then
    err "--user-wav: no such file: $user_wav"
    exit 2
fi

[ -f "$lock" ] || {
    err "lock file not found: $lock"
    exit 2
}

mkdir -p "$out/sofa" "$out/hrir"
if [ $# -eq 0 ]; then
    # shellcheck disable=SC2046  # names never contain whitespace
    set -- $("$here/fetch-sofa.sh" --lock "$lock" --list | cut -d' ' -f1)
fi

if [ -n "$source_dir" ]; then
    "$here/fetch-sofa.sh" --lock "$lock" --dest "$out/sofa" --source-dir "$source_dir" "$@" >/dev/null
else
    "$here/fetch-sofa.sh" --lock "$lock" --dest "$out/sofa" "$@" >/dev/null
fi

manifest="$out/manifest.json"
rm -f "$manifest"
rc=0
for name in "$@"; do
    licence=$("$here/fetch-sofa.sh" --lock "$lock" --list | awk -v n="$name" '$1 == n { print $2 }')
    full="$out/hrir/$name-full.wav"
    dry="$out/hrir/$name-dry.wav"
    python3 "$here/render_sofa.py" --json "$out/hrir/$name.json" "$out/sofa/$name.sofa" "$full"
    python3 "$here/hrir_tool.py" dry "$full" "$dry"
    python3 "$here/hrir_tool.py" add --manifest "$manifest" --id "$name-full" --set "$name" \
        --form full --licence "$licence" --source "hrtf.lock: $name" "$full" || rc=1
    python3 "$here/hrir_tool.py" add --manifest "$manifest" --id "$name-dry" --set "$name" \
        --form dry --licence "$licence" --source "hrtf.lock: $name" "$dry" || rc=1
done
if [ -n "$user_wav" ]; then
    cp "$user_wav" "$out/hrir/user.wav"
    python3 "$here/hrir_tool.py" add --manifest "$manifest" --id user --set user --form as-given \
        --licence "local file, not redistributable" --source "user supplied" \
        "$out/hrir/user.wav" || rc=1
fi
python3 "$here/hrir_tool.py" report --manifest "$manifest" | tee "$out/report.txt"
exit $rc
