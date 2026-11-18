#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# tools/surround-test: install.sh, uninstall.sh, deploy.sh and the switcher
# wrapper against a throwaway HOME, plus one run of the whole flow in a
# private, silent PipeWire session where PipeWire and WirePlumber exist.
load '../test_helper'

RIG="$REPO_ROOT/tools/surround-test"

setup() {
    W="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/surround.XXXXXX")"
    export HOME="$W/home"
    mkdir -p "$HOME"
    unset XDG_DATA_HOME XDG_STATE_HOME X20_SURROUND_HOME X20_SURROUND_STATE
    export XDG_RUNTIME_DIR="$W/run"
    mkdir -p "$XDG_RUNTIME_DIR"
    SHARE="$HOME/.local/share/x20-surround-test"
    STATE="$HOME/.local/state/x20-surround-test"
    LINK="$HOME/.local/bin/surround-test"
}

# fake_out <dir> : a build.sh output with two synthetic candidates.
fake_out() {
    mkdir -p "$1/hrir"
    PYTHONPATH="$RIG:$RIG/tests" python3 -c '
import sys
from synthetic import synthetic_table
from x20surround import forms, manifest, wav
from x20surround.layout import RATE, unpairs
out = sys.argv[1]
full = unpairs(synthetic_table())
data = manifest.empty()
for cid, chans in (("syn-full", full), ("syn-dry", forms.dry_fronts(full))):
    path = "%s/hrir/%s.wav" % (out, cid)
    wav.write(path, RATE, chans)
    manifest.add(data, manifest.describe(path, cid, licence="CC0-1.0"), out)
manifest.save(out + "/manifest.json", data)' "$1"
}

# rig_bare : the rig files in a scratch directory, without a build output
# (the checkout may hold a real out/ from build.sh).
rig_bare() {
    mkdir -p "$W/rig"
    cp "$RIG"/*.sh "$RIG"/*.py "$W/rig/"
    cp -R "$RIG/x20surround" "$W/rig/"
    rm -rf "$W/rig/x20surround/__pycache__"
}

# rig_copy : the same with a fake out/.
rig_copy() {
    rig_bare
    fake_out "$W/rig/out"
}

as_root() {
    mkdir -p "$W/bin"
    printf '#!/bin/sh\necho 0\n' >"$W/bin/id"
    chmod +x "$W/bin/id"
    PATH="$W/bin:$PATH" "$@"
}

@test "install: scripts, package, candidates and the symlink land in the home folder" {
    rig_copy
    run "$W/rig/install.sh"
    assert_success
    assert_output_contains "2 HRIR file(s)"
    for f in surround-test.sh uninstall.sh hrir_tool.py x20surround/switcher.py \
        x20surround/conf.py manifest.json hrir/syn-full.wav hrir/syn-dry.wav; do
        [ -f "$SHARE/$f" ]
    done
    [ -x "$SHARE/surround-test.sh" ]
    [ -d "$STATE" ]
    [ "$(readlink "$LINK")" = "$SHARE/surround-test.sh" ]
    # nothing else in the home folder, and nothing for PipeWire to load
    [ ! -e "$HOME/.config" ]
    run "$LINK" list
    assert_success
    assert_output_contains "syn-full"
}

@test "install: without rendered candidates it says how to get them" {
    rig_bare
    run "$W/rig/install.sh"
    assert_success
    assert_output_contains "0 HRIR file(s)"
    assert_output_contains "build.sh"
    [ ! -e "$SHARE/manifest.json" ]
}

@test "install and the switcher refuse to run as root" {
    as_root run "$RIG/install.sh"
    assert_failure 2
    assert_output_contains "not as root"
    [ ! -e "$SHARE" ]
    as_root run "$RIG/surround-test.sh" list
    assert_failure 2
}

@test "install: usage errors and an incomplete source directory" {
    run "$RIG/install.sh" --bogus
    assert_failure 2
    mkdir -p "$W/empty"
    run "$RIG/install.sh" --from "$W/empty"
    assert_failure 2
    assert_output_contains "is missing"
    [ ! -e "$SHARE" ]
}

@test "uninstall: removes everything install and a session created" {
    rig_copy
    "$W/rig/install.sh" >/dev/null
    before=$(cd "$HOME" && find . | sort)
    printf '{"test":"tone"}\n' >"$STATE/results.jsonl"
    mkdir -p "$XDG_RUNTIME_DIR/x20-surround-test"
    : >"$XDG_RUNTIME_DIR/x20-surround-test/x20test-a.conf"
    run "$SHARE/uninstall.sh"
    assert_success
    [ ! -e "$SHARE" ]
    [ ! -e "$STATE" ]
    [ ! -e "$LINK" ] && [ ! -L "$LINK" ]
    [ ! -e "$XDG_RUNTIME_DIR/x20-surround-test" ]
    [ ! -e "$HOME/x20-surround-test-results.jsonl" ]
    # only the (empty) parent folders install had to create are left
    [ "$(cd "$HOME" && find . -type f | wc -l | tr -d ' ')" = 0 ]
    [ -n "$before" ]
}

@test "uninstall --keep-results keeps the log, and a foreign symlink is left alone" {
    rig_copy
    "$W/rig/install.sh" >/dev/null
    printf '{"test":"tone"}\n' >"$STATE/results.jsonl"
    ln -sf /somewhere/else "$LINK"
    run "$SHARE/uninstall.sh" --keep-results
    assert_success
    [ "$(cat "$HOME/x20-surround-test-results.jsonl")" = '{"test":"tone"}' ]
    [ "$(readlink "$LINK")" = /somewhere/else ]
    run "$RIG/uninstall.sh" --bogus
    assert_failure 2
}

@test "uninstall: an open session is restored first; if that fails nothing is removed" {
    rig_copy
    "$W/rig/install.sh" >/dev/null
    printf '{}\n' >"$STATE/restore.json"
    printf '#!/bin/sh\necho "restore called: $*"\nexit 1\n' >"$SHARE/surround-test.sh"
    run "$SHARE/uninstall.sh"
    assert_failure 1
    assert_output_contains "restore called: restore"
    assert_output_contains "nothing was removed"
    [ -d "$SHARE" ] && [ -f "$STATE/restore.json" ]
    printf '#!/bin/sh\nexit 0\n' >"$SHARE/surround-test.sh"
    run "$SHARE/uninstall.sh"
    assert_success
    [ ! -e "$SHARE" ]
}

@test "deploy: ships the rig and the candidates through ssh and installs them there" {
    fake_out "$W/out"
    mkdir -p "$W/bin" "$W/device"
    # a stand-in for ssh: run the remote command locally with another HOME
    cat >"$W/bin/ssh" <<STUB
#!/bin/sh
echo "\$1" >"$W/ssh-host"
HOME="$W/device" exec sh -c "\$2"
STUB
    chmod +x "$W/bin/ssh"
    PATH="$W/bin:$PATH" run "$RIG/deploy.sh" --out "$W/out" deck@x20.invalid
    assert_success
    [ "$(cat "$W/ssh-host")" = deck@x20.invalid ]
    D="$W/device/.local/share/x20-surround-test"
    [ -f "$D/hrir/syn-full.wav" ] && [ -f "$D/manifest.json" ] && [ -f "$D/x20surround/pw.py" ]
    [ -L "$W/device/.local/bin/surround-test" ]
    # the installer's staging directory is gone
    run find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'x20-surround-install.*' -newer "$W/ssh-host"
    [ -z "$output" ]
}

@test "deploy: needs a host and a build" {
    run "$RIG/deploy.sh"
    assert_failure 2
    run "$RIG/deploy.sh" --out "$W/nothing" deck@x20.invalid
    assert_failure 2
    assert_output_contains "run build.sh first"
}

@test "switcher: help names every phase, results and restore work without PipeWire" {
    run "$RIG/surround-test.sh" --help
    assert_success
    for word in doctor calibrate localise tone results restore add-user; do
        assert_output_contains "$word"
    done
    rig_copy
    "$W/rig/install.sh" >/dev/null
    run "$LINK" results
    assert_success
    assert_output_contains "no results yet"
    run "$LINK" restore
    assert_success
    assert_output_contains "nothing to restore"
}

# The whole flow with real PipeWire and WirePlumber, on null sinks named
# like the X20's. Silent. Skipped where the daemons are not installed (macOS,
# plain CI images) or when running as root.
@test "headless PipeWire: doctor, calibrate, localise, tone, speaker candidates, results, uninstall" {
    for tool in pipewire wireplumber pw-cli pw-cat pw-record pw-metadata wpctl dbus-run-session; do
        command -v "$tool" >/dev/null 2>&1 || skip "$tool not installed"
    done
    [ "$(id -u)" -ne 0 ] || skip "PipeWire sessions are per user, not for root"
    rig_copy
    "$W/rig/install.sh" >/dev/null
    cat >"$W/flow.sh" <<FLOW
set -eu
T=alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Headphones__sink
before=\$(wpctl get-volume @DEFAULT_AUDIO_SINK@)
"$LINK" doctor --measure
"$LINK" calibrate
{ echo; for i in \$(seq 21); do echo 1; done; } | "$LINK" localise --repeats 1 --seed 3
{ echo; echo 2; echo 1; echo p1; echo p0; } | "$LINK" tone --candidates syn-full --rounds 2 \
    --file "\$XDG_RUNTIME_DIR/x20-surround-test/noise.wav" --seed 4
"$LINK" speakers-from syn-dry
"$LINK" calibrate --device speakers --candidates syn-dry-speakers,syn-dry-xtc-d100-s50
"$LINK" results
echo "volume-before=\$before volume-after=\$(wpctl get-volume @DEFAULT_AUDIO_SINK@)"
echo "configured-after=[\$(pw-metadata -n default 0 default.configured.audio.sink 2>/dev/null | grep -c update || true)]"
echo "left-over-nodes=[\$(pw-cli ls Node 2>/dev/null | grep -c x20test- || true)]"
FLOW
    run "$RIG/tests/headless.sh" bash "$W/flow.sh"
    assert_success
    assert_output_contains "largest difference 0.000: matches"
    assert_output_contains "syn-full "
    [[ "$output" != *"NOT MATCHED"* ]]
    assert_output_contains "Done. The labels were:"
    assert_output_contains "Done. Preferences:"
    assert_output_contains "stream x20test-material: 8 channel(s)"
    assert_output_contains "volume-before=Volume: 1.00 volume-after=Volume: 1.00"
    assert_output_contains "configured-after=[0]"
    assert_output_contains "left-over-nodes=[0]"
    assert_output_contains "13 speaker candidate(s)"
    # every candidate measured within 0.5 dB of raw, per hardware sink
    python3 - "$STATE/calibration.json" <<'PY'
import json, sys
cal = json.load(open(sys.argv[1]))
phones = [v for k, v in cal.items() if k.endswith("Headphones__sink")][0]
speakers = [v for k, v in cal.items() if k.endswith("Speaker__sink")][0]
assert set(phones) == {"syn-full", "syn-dry"}, phones
assert set(speakers) == {"syn-dry-speakers", "syn-dry-xtc-d100-s50"}, speakers
for entries in (phones, speakers):
    assert all(abs(e["residual_db"]) <= 0.5 for e in entries.values()), entries
PY
    [ "$(wc -l <"$STATE/results.jsonl" | tr -d ' ')" = 2 ]
    [ ! -e "$STATE/restore.json" ]
    run "$SHARE/uninstall.sh"
    assert_success
    [ ! -e "$SHARE" ] && [ ! -e "$STATE" ]
}
