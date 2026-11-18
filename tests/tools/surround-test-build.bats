#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# tools/surround-test: fetch-sofa.sh and build.sh (phase 1 of the blind-test
# rig). No network, no audio: SOFA files are fixtures made on the spot.
load '../test_helper'

RIG="$REPO_ROOT/tools/surround-test"

setup() {
    W="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/surround.XXXXXX")"
    mkdir -p "$W/src"
}

sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# lock_for <name> <file> : append a lock record for a fixture file.
lock_for() {
    printf 'set %s %s %s CC0-1.0 https://example.invalid/%s.sofa\n' \
        "$1" "$(sha "$2")" "$(wc -c <"$2" | tr -d ' ')" "$1" >>"$W/lock"
}

have_numpy() { python3 -c 'import numpy, scipy, h5py' 2>/dev/null; }

# synthetic_sofa <file> : a small SOFA set (needs numpy and h5py).
synthetic_sofa() {
    PYTHONPATH="$RIG/tests" python3 -c '
import sys
from test_render_sofa import write_sofa
write_sofa(sys.argv[1])' "$1"
}

@test "lock file: six sets, each with a 64-digit hash, a licence and an attribution" {
    run "$RIG/fetch-sofa.sh" --list
    assert_success
    [ "${#lines[@]}" -eq 6 ]
    while read -r kind name hash size licence url; do
        [ "$kind" = set ] || continue
        [ "${#hash}" -eq 64 ]
        [ "$size" -gt 0 ]
        [ -n "$licence" ]
        case "$url" in https://sofacoustics.org/data/database/*.sofa) ;; *) false ;; esac
        grep -q "^attribution $name " "$RIG/hrtf.lock"
    done <"$RIG/hrtf.lock"
}

@test "the three sets of the old hrtf.lock are kept with the same hashes" {
    for name in mit-kemar hutubs-pp1 cipic-003; do
        old=$(git -C "$REPO_ROOT" show 899ba9b:overlay/home/hrtf/hrtf.lock 2>/dev/null \
            | awk -v n="$name" '$1 == "set" && $2 == n { print $3 }')
        [ -n "$old" ] || skip "commit 899ba9b not in this clone"
        new=$(awk -v n="$name" '$1 == "set" && $2 == n { print $3 }' "$RIG/hrtf.lock")
        [ "$old" = "$new" ]
    done
}

@test "fetch-sofa: copies from --source-dir and verifies the hash" {
    printf 'pretend sofa' >"$W/src/one.sofa"
    lock_for one "$W/src/one.sofa"
    run "$RIG/fetch-sofa.sh" --lock "$W/lock" --dest "$W/out" --source-dir "$W/src"
    assert_success
    assert_equal "$output" "one $W/out/one.sofa"
    cmp -s "$W/src/one.sofa" "$W/out/one.sofa"
    # a second run finds the verified file and does not need the source
    run "$RIG/fetch-sofa.sh" --lock "$W/lock" --dest "$W/out" --source-dir "$W/nowhere"
    assert_success
}

@test "fetch-sofa: a file with the wrong hash is refused and not kept" {
    printf 'pretend sofa' >"$W/src/one.sofa"
    lock_for one "$W/src/one.sofa"
    printf 'tampered' >"$W/src/one.sofa"
    run "$RIG/fetch-sofa.sh" --lock "$W/lock" --dest "$W/out" --source-dir "$W/src"
    assert_failure 1
    assert_output_contains "SHA-256 mismatch"
    [ ! -e "$W/out/one.sofa" ]
    [ ! -e "$W/out/one.sofa.part" ]
}

@test "fetch-sofa: unknown set, bad name, missing lock, unknown option" {
    : >"$W/lock"
    run "$RIG/fetch-sofa.sh" --lock "$W/lock" --dest "$W/out" nope
    assert_failure 1
    assert_output_contains "unknown set: nope"
    run "$RIG/fetch-sofa.sh" --lock "$W/lock" --dest "$W/out" '../x'
    assert_failure 1
    assert_output_contains "invalid set name"
    run "$RIG/fetch-sofa.sh" --lock "$W/missing"
    assert_failure 2
    run "$RIG/fetch-sofa.sh" --bogus
    assert_failure 2
}

@test "build: usage errors" {
    run "$RIG/build.sh" --bogus
    assert_failure 2
    run "$RIG/build.sh" --out
    assert_failure 2
    run "$RIG/build.sh" --help
    assert_success
    assert_output_contains "usage: build.sh"
}

@test "build: says what is missing when python3 has no numpy" {
    mkdir -p "$W/bin"
    printf '#!/bin/sh\nexit 1\n' >"$W/bin/python3"
    chmod +x "$W/bin/python3"
    PATH="$W/bin:$PATH" run "$RIG/build.sh" --out "$W/out"
    assert_failure 2
    assert_output_contains "numpy, scipy and h5py"
    [ ! -e "$W/out" ]
}

@test "build: a missing --user-wav or lock file stops before anything is written" {
    have_numpy || skip "python3 without numpy/scipy/h5py"
    run "$RIG/build.sh" --out "$W/out" --user-wav "$W/missing.wav"
    assert_failure 2
    run "$RIG/build.sh" --out "$W/out" --lock "$W/missing.lock"
    assert_failure 2
    [ ! -e "$W/out" ]
}

@test "build: renders both forms per set, adds the user file, writes manifest and report" {
    have_numpy || skip "python3 without numpy/scipy/h5py"
    synthetic_sofa "$W/src/syn.sofa"
    lock_for syn "$W/src/syn.sofa"
    run "$RIG/build.sh" --out "$W/out" --lock "$W/lock" --source-dir "$W/src"
    assert_success
    [ -f "$W/out/hrir/syn-full.wav" ]
    [ -f "$W/out/hrir/syn-dry.wav" ]
    [ -f "$W/out/hrir/syn.json" ]
    assert_output_contains "syn-full"
    assert_output_contains "syn-dry"
    cmp -s <(printf '%s\n' "$output" | sed -n '/^candidate/,$p') "$W/out/report.txt"
    ids=$(python3 -c 'import json,sys; print(" ".join(c["id"] for c in json.load(open(sys.argv[1]))["candidates"]))' "$W/out/manifest.json")
    assert_equal "$ids" "syn-full syn-dry"
    # the user file: one more candidate, taken as given
    run "$RIG/build.sh" --out "$W/out" --lock "$W/lock" --source-dir "$W/src" \
        --user-wav "$W/out/hrir/syn-full.wav"
    assert_success
    cmp -s "$W/out/hrir/syn-full.wav" "$W/out/hrir/user.wav"
    python3 -c '
import json, sys
c = [c for c in json.load(open(sys.argv[1]))["candidates"] if c["id"] == "user"][0]
assert c["file"] == "hrir/user.wav" and c["form"] == "as-given", c
assert "not redistributable" in c["licence"], c' "$W/out/manifest.json"
}

@test "nothing binary is tracked: no .sofa or .wav under tools/surround-test" {
    git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
    run git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard -- \
        'tools/surround-test/*.sofa' 'tools/surround-test/*.wav' 'tools/surround-test/**/*.wav'
    assert_success
    [ -z "$output" ]
    grep -qx 'out/' "$RIG/.gitignore"
    grep -qx '\*.sofa' "$RIG/.gitignore"
    grep -qx '\*.wav' "$RIG/.gitignore"
}
