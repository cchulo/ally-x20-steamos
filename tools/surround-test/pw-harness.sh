#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# pw-harness.sh — run pw_harness.py inside a private D-Bus session.
#
# usage: pw-harness.sh raw | candidate HRIR.wav | pin HRIR.wav | ceiling
#                      | sofa SET.sofa RENDERED.wav
# See pw_harness.py for what each mode measures. Linux only (PipeWire and
# WirePlumber installed, no sound hardware needed, nothing is audible).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
command -v dbus-run-session >/dev/null 2>&1 || {
    echo "pw-harness: dbus-run-session not found" >&2
    exit 2
}
exec dbus-run-session -- python3 "$here/pw_harness.py" "$@"
