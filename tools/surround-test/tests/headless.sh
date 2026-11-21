#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# headless.sh — run a command inside a private, silent PipeWire session
# that has two null sinks named like the X20's hardware sinks.
#
# usage: headless.sh COMMAND [ARG...]
# Needs pipewire, wireplumber, pw-cli and dbus-run-session (Linux). Used by
# tests/tools/surround-test-device.bats; nothing is audible.
set -eu
if [ -z "${X20_HEADLESS_INNER:-}" ]; then
    exec env X20_HEADLESS_INNER=1 dbus-run-session -- "$0" "$@"
fi
run=$(mktemp -d "${TMPDIR:-/tmp}/x20-headless.XXXXXX")
export XDG_RUNTIME_DIR="$run" PIPEWIRE_RUNTIME_DIR="$run"
export XDG_STATE_HOME="$run/wp-state" XDG_CONFIG_HOME="$run/wp-config"
pids=""
cleanup() {
    # shellcheck disable=SC2086
    [ -z "$pids" ] || kill $pids 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$run"
}
trap cleanup EXIT
pipewire >"$run/pipewire.log" 2>&1 &
pids="$!"
i=0
until [ -e "$run/pipewire-0" ] || [ $i -ge 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
wireplumber >"$run/wireplumber.log" 2>&1 &
pids="$pids $!"
i=0
until pw-cli ls Client 2>/dev/null | grep -q WirePlumber || [ $i -ge 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
sleep 1
sink() {
    pw-cli create-node adapter "{ factory.name=support.null-audio-sink node.name=$1 node.description=$2 media.class=Audio/Sink object.linger=true audio.position=[FL FR] priority.session=$3 priority.driver=$3 }" >/dev/null 2>&1
}
sink alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink Speaker 712
sink alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Headphones__sink Headphones 1000
sleep 1
unset XDG_STATE_HOME XDG_CONFIG_HOME
"$@"
