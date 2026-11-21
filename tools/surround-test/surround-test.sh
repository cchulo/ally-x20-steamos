#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# surround-test — on-device switcher of the virtual-surround blind test.
# bash + python3 standard library only; see `surround-test --help` and
# README.md. Installed by install.sh into the deck user's home folder.
set -eu
here=$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")")" && pwd)
if [ "$(id -u)" -eq 0 ]; then
    echo "surround-test: run as the logged-in user, not as root (PipeWire is per user)" >&2
    exit 2
fi
command -v python3 >/dev/null 2>&1 || {
    echo "surround-test: python3 not found" >&2
    exit 2
}
X20_SURROUND_HOME="${X20_SURROUND_HOME:-$here}"
export X20_SURROUND_HOME
PYTHONPATH="$here${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m x20surround.switcher "$@"
