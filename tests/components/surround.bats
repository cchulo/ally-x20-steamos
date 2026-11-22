#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/surround.sh and the `surround` command against fixture roots:
# the helper, its x20dsp package, the eight impulse response sets with their
# notice and licence, and the user unit are installed under /etc; the command
# passes status, list, set, xtc and prepare to the helper, which keeps the
# choice in the user's ~/.config and the generated speaker variants in the
# user's ~/.cache. The helper's own logic is in tests/surround/.
load '../test_helper'

DIR=/etc/ally-x20-steamos/surround
HELPER=$DIR/x20-surround
UNIT=/etc/systemd/user/ally-x20-steamos-surround.service
LINK=/etc/systemd/user/default.target.wants/ally-x20-steamos-surround.service
OVL="$REPO_ROOT/overlay"
SETS="sadie-d2-dry hutubs-pp1-dry mit-kemar-dry mit-kemar-large-dry sadie-d2-full hutubs-pp1-full mit-kemar-full mit-kemar-large-full"
DSP="__init__ checks dsp layout level wav xtc"
CONF=.config/ally-x20-steamos/surround.conf
CACHE=.cache/ally-x20-steamos/surround

setup() {
    make_root >/dev/null
    source_libs
    unset AX20_SURROUND_SYSTEM_STEPS
    component_load surround
    export HOME="$BATS_TEST_TMPDIR/home" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
    unset XDG_CONFIG_HOME XDG_CACHE_HOME
    export X20_SURROUND_ALLOW_ROOT=1  # a root test runner (containers) is fine here
    mkdir -p "$HOME"
    # no PipeWire in the tests: pw-dump must not find a real one
    mkdir -p "$BATS_TEST_TMPDIR/nopw"
    printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/nopw/pw-dump"
    chmod +x "$BATS_TEST_TMPDIR/nopw/pw-dump"
    PATH="$BATS_TEST_TMPDIR/nopw:$PATH"
}

# stubs <dir> : systemctl and id that record / answer for a fixture user.
stubs() {
    mkdir -p "$1"
    printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\nexit 0\n' "$1" >"$1/systemctl"
    chmod +x "$1/systemctl"
    : >"$1/calls"
}

tree_listing() { (cd "$AX20_ROOT" && find . -path ./var/lib/ally-x20-steamos -prune -o -print | sort); }

@test "files: helper, eight sets, the x20dsp package, notice, licence, user unit" {
    run component_files surround
    assert_success
    assert_output_contains "$(printf 'bin/x20-surround.py\t%s\t0755' "$HELPER")"
    for s in $SETS; do
        assert_output_contains "$(printf 'surround/hrir/%s.wav\t%s/hrir/%s.wav\t0644' "$s" "$DIR" "$s")"
    done
    for m in $DSP; do
        assert_output_contains "$(printf 'surround/x20dsp/%s.py\t%s/x20dsp/%s.py\t0644' "$m" "$DIR" "$m")"
    done
    assert_output_contains "$(printf 'surround/NOTICE.md\t%s/NOTICE.md\t0644' "$DIR")"
    assert_output_contains "$(printf 'surround/LICENSE.Apache-2.0\t%s/LICENSE.Apache-2.0\t0644' "$DIR")"
    assert_output_contains "$(printf 'systemd/ally-x20-steamos-surround.service\t%s\t0644' "$UNIT")"
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 19 ]
}

@test "the overlay ships exactly the x20dsp modules the component installs, no manifest code" {
    [ "$(cd "$OVL/surround/x20dsp" && ls -- *.py | sort | tr '\n' ' ')" = "$(for m in $DSP; do echo "$m.py"; done | sort | tr '\n' ' ')" ]
    run grep -l 'import.*manifest\|add_speaker_candidates' "$OVL"/surround/x20dsp/*.py
    assert_failure
}

@test "the overlay ships exactly the sets the component installs" {
    [ "$(cd "$OVL/surround/hrir" && ls | sort | tr '\n' ' ')" = "$(for s in $SETS; do echo "$s.wav"; done | sort | tr '\n' ' ')" ]
}

@test "probe: always needed (stock offers the built-in outputs as stereo only)" {
    run component_probe surround
    [ "$status" -eq 1 ]
}

@test "apply installs everything, enables the user unit by link, and skips systemctl on a fixture root" {
    stubs "$BATS_TEST_TMPDIR/stub"
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" run component_apply surround
    assert_success
    [ -x "$AX20_ROOT$HELPER" ]
    for s in $SETS; do
        cmp -s "$AX20_ROOT$DIR/hrir/$s.wav" "$OVL/surround/hrir/$s.wav"
        manifest_has "$DIR/hrir/$s.wav"
    done
    for m in $DSP; do
        cmp -s "$AX20_ROOT$DIR/x20dsp/$m.py" "$OVL/surround/x20dsp/$m.py"
        manifest_has "$DIR/x20dsp/$m.py"
    done
    [ -f "$AX20_ROOT$DIR/NOTICE.md" ]
    [ -f "$AX20_ROOT$DIR/LICENSE.Apache-2.0" ]
    [ -f "$AX20_ROOT$UNIT" ]
    [ "$(readlink "$AX20_ROOT$LINK")" = "../ally-x20-steamos-surround.service" ]
    manifest_has "$LINK"
    [ ! -s "$BATS_TEST_TMPDIR/stub/calls" ]
    [ "$(component_status surround)" = active ]
}

@test "apply is idempotent" {
    component_apply surround
    run component_apply surround
    assert_success
    [ -z "$(manifest_paths surround | sort | uniq -d)" ]
}

@test "system steps: the user's session reloads and (re)starts the unit" {
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    me=$(id -un)
    mkdir -p "$AX20_ROOT/run/user/$(id -u)"
    PATH="$stub:$PATH" AX20_SURROUND_SYSTEM_STEPS=always AX20_SURROUND_USER="$me" run component_apply surround
    assert_success
    [ "$(cat "$stub/calls")" = "systemctl --user -M $me@ daemon-reload
systemctl --user -M $me@ restart ally-x20-steamos-surround.service" ]
}

@test "system steps: no session for the user, nothing is called" {
    stub="$BATS_TEST_TMPDIR/stub"
    stubs "$stub"
    PATH="$stub:$PATH" AX20_SURROUND_SYSTEM_STEPS=always AX20_SURROUND_USER="$(id -un)" run component_apply surround
    assert_success
    [ ! -s "$stub/calls" ]
}

@test "uninstall --component surround removes everything it added; the user's choice and cache stay" {
    before=$(tree_listing)
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    "$CLI" --root "$AX20_ROOT" surround set headphones stereo
    # the installed helper loads the installed x20dsp and generates a speaker
    # variant; it must leave nothing (no __pycache__) under the root
    "$CLI" --root "$AX20_ROOT" surround xtc 80 50
    [ -z "$(find "$AX20_ROOT$DIR" -name '__pycache__' -o -name '*.pyc')" ]
    run "$CLI" --root "$AX20_ROOT" uninstall --component surround --keep-state
    assert_success
    [ -z "$(manifest_paths surround | grep -vx -e /etc/systemd -e /etc/systemd/user)" ]
    rmdir "$AX20_ROOT/etc/systemd/user" "$AX20_ROOT/etc/systemd"
    [ "$(tree_listing)" = "$before" ]
    grep -qx 'headphones=stereo' "$HOME/$CONF"
    grep -qx 'speakers_xtc=80/50' "$HOME/$CONF"
    [ "$(find "$HOME/$CACHE" -name '*-d080-s50.wav' | wc -l)" -eq 1 ]
}

@test "unit: a user service that runs the helper and is restarted on failure" {
    u="$OVL/systemd/ally-x20-steamos-surround.service"
    grep -qx 'Type=simple' "$u"
    grep -qx "ExecStart=$HELPER run" "$u"
    grep -qx 'Restart=on-failure' "$u"
    grep -qx 'After=pipewire.service wireplumber.service' "$u"
    grep -qx "ConditionPathExists=$HELPER" "$u"
    grep -qx 'WantedBy=default.target' "$u"
}

@test "surround list and status work from the checkout, before apply" {
    run "$CLI" --root "$AX20_ROOT" surround list
    assert_success
    assert_output_contains 'sadie-d2-dry'
    assert_output_contains '(default for headphones and speakers)'
    assert_output_contains 'crosstalk cancellation'
    run "$CLI" --root "$AX20_ROOT" surround status
    assert_success
    assert_output_contains 'status: stock'
    assert_output_contains 'headphones sadie-d2-dry  (sadie-d2-dry.wav, trim -1.10 dB)'
    assert_output_contains 'speakers   sadie-d2-dry  (sadie-d2-dry.wav, trim -1.10 dB)'
    assert_output_contains 'xtc        60 us / 50 %  (speakers only): not generated yet'
    # status generates nothing
    [ ! -e "$HOME/$CACHE" ]
}

@test "surround prepare works from the checkout: the tested grid with trim and check" {
    run "$CLI" --root "$AX20_ROOT" surround prepare
    assert_success
    assert_output_contains 'speakers: sadie-d2-dry (sadie-d2-dry.wav, trim -1.10 dB without xtc)'
    assert_output_contains '* 60 us / 50 %    -1.60 dB  usable'
    [ "$(printf '%s\n' "$output" | grep -c ' us / .* dB  usable$')" -eq 12 ]
    [ "$(find "$HOME/$CACHE" -name '*.wav' | wc -l)" -eq 12 ]
    [ "$(find "$HOME/$CACHE" -name '*.json' | wc -l)" -eq 12 ]
    run "$CLI" --root "$AX20_ROOT" surround status
    assert_output_contains 'speakers   sadie-d2-dry + xtc 60 us / 50 %  (sadie-d2-dry.wav, trim -1.60 dB)'
}

@test "surround set: needs the component, then records the choice per output in the user's config" {
    run "$CLI" --root "$AX20_ROOT" surround set headphones stereo
    assert_failure
    assert_output_contains 'surround is not installed'
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" surround set headphones hutubs-pp1-dry
    assert_success
    assert_output_contains 'headphones: hutubs-pp1-dry'
    conf="$HOME/$CONF"
    # the other output keeps its own setting
    grep -qx 'speakers=sadie-d2-dry' "$conf"
    run "$CLI" --root "$AX20_ROOT" surround set speakers mit-kemar-dry
    assert_success
    assert_output_contains 'speakers: mit-kemar-dry + xtc 60 us / 50 %  (trim -5.23 dB)'
    grep -qx 'headphones=hutubs-pp1-dry' "$conf"
    grep -qx 'speakers=mit-kemar-dry' "$conf"
    grep -qx 'speakers_xtc=60/50' "$conf"
    # the older spelling is still accepted
    run "$CLI" --root "$AX20_ROOT" surround set stereo --device headphones
    assert_success
    grep -qx 'headphones=stereo' "$conf"
    # nothing of it under the root: the choice is the user's
    [ -z "$(manifest_paths surround | grep surround.conf || true)" ]
}

@test "surround set user without a file: recorded, falls back to the default" {
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" surround set headphones user
    assert_success
    assert_output_contains 'headphones: user -> sadie-d2-dry'
    assert_output_contains 'no .wav file'
    run "$CLI" --root "$AX20_ROOT" surround set speakers user
    assert_success
    assert_output_contains 'speakers: user -> sadie-d2-dry + xtc 60 us / 50 %'
}

@test "surround set without the output is an error and changes nothing" {
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" surround set stereo
    assert_failure
    assert_output_contains 'name the output: set headphones stereo, or set speakers stereo'
    run "$CLI" --root "$AX20_ROOT" surround set hdmi stereo
    assert_failure
    assert_output_contains "unknown output 'hdmi'"
    [ ! -e "$HOME/$CONF" ]
}

@test "surround xtc: needs the component, sets the speakers' crosstalk cancellation, refuses bad values" {
    run "$CLI" --root "$AX20_ROOT" surround xtc 100 30
    assert_failure
    assert_output_contains 'surround is not installed'
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" surround xtc 100 30
    assert_success
    assert_output_contains 'xtc: 100 us / 30 %  (speakers only)'
    assert_output_contains 'speakers: sadie-d2-dry + xtc 100 us / 30 %  (trim -1.29 dB)'
    grep -qx 'speakers_xtc=100/30' "$HOME/$CONF"
    grep -qx 'headphones=sadie-d2-dry' "$HOME/$CONF"
    run "$CLI" --root "$AX20_ROOT" surround xtc 10 30
    assert_failure
    assert_output_contains 'delay 10 is out of range'
    grep -qx 'speakers_xtc=100/30' "$HOME/$CONF"
    run "$CLI" --root "$AX20_ROOT" surround xtc off
    assert_success
    grep -qx 'speakers_xtc=off' "$HOME/$CONF"
}

@test "surround xtc: a setting that fails its check is not played, and the reason is shown" {
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    "$CLI" --root "$AX20_ROOT" surround set speakers mit-kemar-dry
    run "$CLI" --root "$AX20_ROOT" surround xtc 60 70
    assert_success
    assert_output_contains 'is not usable with mit-kemar-dry (routing check'
    assert_output_contains 'playing mit-kemar-dry without it'
    run "$CLI" --root "$AX20_ROOT" surround status
    assert_output_contains 'speakers   mit-kemar-dry  (mit-kemar-dry.wav, trim -5.03 dB)'
    assert_output_contains 'xtc        60 us / 70 %  (speakers only): not in use, see the note'
    [ -z "$(find "$HOME/$CACHE" -name '*-d060-s70.wav')" ]
}

@test "surround: usage, unknown command, unknown profile, dry run" {
    run "$CLI" --root "$AX20_ROOT" surround
    [ "$status" -eq 2 ]
    assert_output_contains 'usage:'
    run "$CLI" --root "$AX20_ROOT" surround bogus
    [ "$status" -eq 2 ]
    run "$CLI" --root "$AX20_ROOT" surround --help
    assert_success
    assert_output_contains 'set <headphones|speakers> <profile>'
    assert_output_contains 'xtc off | xtc <delay_us> <strength_pct>'
    assert_output_contains 'prepare'
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    run "$CLI" --root "$AX20_ROOT" surround set headphones cipic-003-full
    assert_failure
    run "$CLI" --root "$AX20_ROOT" --dry-run surround set headphones stereo
    assert_success
    run "$CLI" --root "$AX20_ROOT" --dry-run surround xtc off
    assert_success
    run "$CLI" --root "$AX20_ROOT" --dry-run surround prepare
    assert_success
    [ ! -e "$HOME/$CONF" ]
    [ ! -e "$HOME/$CACHE" ]
    run "$CLI" --root "$AX20_ROOT" help
    assert_output_contains 'surround'
}

@test "as the user, with a manifest only root can read: set, xtc and status still work" {
    [ "$(id -u)" != 0 ] || skip "root can read everything"
    "$CLI" --root "$AX20_ROOT" apply --only surround 2>/dev/null
    chmod 000 "$AX20_ROOT/var/lib/ally-x20-steamos/manifest"
    run "$CLI" --root "$AX20_ROOT" surround set headphones hutubs-pp1-dry
    chmod 644 "$AX20_ROOT/var/lib/ally-x20-steamos/manifest"
    assert_success
    assert_output_contains 'headphones: hutubs-pp1-dry'
    [ -z "$(printf '%s\n' "$output" | grep -i 'permission denied' || true)" ]
    chmod 000 "$AX20_ROOT/var/lib/ally-x20-steamos/manifest"
    run "$CLI" --root "$AX20_ROOT" surround xtc 80 50
    s1=$status
    run "$CLI" --root "$AX20_ROOT" surround status
    chmod 644 "$AX20_ROOT/var/lib/ally-x20-steamos/manifest"
    [ "$s1" -eq 0 ]
    assert_success
    assert_output_contains "status: installed (run 'sudo ally-x20-steamos status' for the full check)"
    [ -z "$(printf '%s\n' "$output" | grep -i 'permission denied' || true)" ]
}

@test "surround set before apply says it is not installed" {
    run "$CLI" --root "$AX20_ROOT" surround set headphones stereo
    assert_failure
    assert_output_contains 'surround is not installed'
}
