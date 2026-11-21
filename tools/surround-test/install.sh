#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# install.sh — put the surround blind-test rig into the current user's home
# folder. No sudo, nothing outside $HOME, nothing in ~/.config/pipewire.
#
# usage: install.sh [--from DIR]
#   --from DIR   directory holding the rig (default: where this script is).
#                It must contain surround-test.sh, uninstall.sh, hrir_tool.py
#                and x20surround/; with out/manifest.json and out/hrir/*.wav
#                (from build.sh) the rendered candidates are installed too.
#
# Installs:
#   ~/.local/share/x20-surround-test/   scripts, manifest.json, hrir/*.wav
#   ~/.local/state/x20-surround-test/   results.jsonl, calibration.json
#   ~/.local/bin/surround-test          symlink to the switcher
# uninstall.sh removes all three.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
from=$here
while [ $# -gt 0 ]; do
    case "$1" in
        --from)
            [ $# -ge 2 ] || {
                echo "install: --from needs a directory" >&2
                exit 2
            }
            from=$2
            shift 2
            ;;
        -h | --help)
            sed -n '3,17p' "$0"
            exit 0
            ;;
        *)
            echo "install: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "install: run as the logged-in user (deck), not as root" >&2
    exit 2
fi
for f in surround-test.sh uninstall.sh hrir_tool.py x20surround/switcher.py; do
    [ -f "$from/$f" ] || {
        echo "install: $from/$f is missing" >&2
        exit 2
    }
done

share="${XDG_DATA_HOME:-$HOME/.local/share}/x20-surround-test"
state="${XDG_STATE_HOME:-$HOME/.local/state}/x20-surround-test"
bin="$HOME/.local/bin"

mkdir -p "$share/x20surround" "$share/hrir" "$state" "$bin"
cp "$from/surround-test.sh" "$from/uninstall.sh" "$from/hrir_tool.py" "$share/"
cp "$from"/x20surround/*.py "$share/x20surround/"
chmod 755 "$share/surround-test.sh" "$share/uninstall.sh"
count=0
if [ -f "$from/out/manifest.json" ]; then
    cp "$from/out/manifest.json" "$share/manifest.json"
    for w in "$from"/out/hrir/*.wav; do
        [ -f "$w" ] || continue
        cp "$w" "$share/hrir/"
        count=$((count + 1))
    done
fi
ln -sf "$share/surround-test.sh" "$bin/surround-test"

echo "installed into $share ($count HRIR file(s))"
if [ "$count" -eq 0 ]; then
    echo "no rendered candidates were found in $from/out; run build.sh on the development"
    echo "machine first, or add a local file with: surround-test add-user FILE"
fi
echo "next: $bin/surround-test doctor"
