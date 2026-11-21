#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# uninstall.sh — remove everything install.sh and the switcher put into the
# user's home folder, after restoring volumes and the default sink if a
# session was left open.
#
# usage: uninstall.sh [--keep-results]
#   --keep-results   move the results log to ~/x20-surround-test-results.jsonl
#                    before removing the rest
set -eu

keep=0
case "${1:-}" in
    "") ;;
    --keep-results) keep=1 ;;
    -h | --help)
        sed -n '3,10p' "$0"
        exit 0
        ;;
    *)
        echo "uninstall: unknown argument: $1" >&2
        exit 2
        ;;
esac

share="${XDG_DATA_HOME:-$HOME/.local/share}/x20-surround-test"
state="${XDG_STATE_HOME:-$HOME/.local/state}/x20-surround-test"
runtime="${XDG_RUNTIME_DIR:-/tmp}/x20-surround-test"
link="$HOME/.local/bin/surround-test"

if [ -f "$state/restore.json" ] && [ -x "$share/surround-test.sh" ]; then
    "$share/surround-test.sh" restore || {
        echo "uninstall: restoring the volumes failed; nothing was removed." >&2
        echo "uninstall: fix the cause (is PipeWire running?) and run this again." >&2
        exit 1
    }
fi
if [ "$keep" -eq 1 ] && [ -f "$state/results.jsonl" ]; then
    mv "$state/results.jsonl" "$HOME/x20-surround-test-results.jsonl"
    echo "kept $HOME/x20-surround-test-results.jsonl"
fi
if [ -L "$link" ] && [ "$(readlink "$link")" = "$share/surround-test.sh" ]; then
    rm -f "$link"
    echo "removed $link"
fi
for d in "$runtime" "$state" "$share"; do
    if [ -d "$d" ]; then
        rm -rf "$d"
        echo "removed $d"
    fi
done
