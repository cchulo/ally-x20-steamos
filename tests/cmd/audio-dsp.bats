#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# cmd/audio-dsp.sh through the CLI against a fixture root.
load '../test_helper'

H=/home/deck

setup() {
    make_root >/dev/null
    local d="$BATS_TEST_TMPDIR/sofa" n sha
    mkdir -p "$d"
    {
        printf 'default set-a\n'
        for n in set-a set-b; do
            printf 'fake %s\n' "$n" >"$d/$n.sofa"
            if command -v sha256sum >/dev/null 2>&1; then
                sha=$(sha256sum "$d/$n.sofa" | cut -d' ' -f1)
            else
                sha=$(shasum -a 256 "$d/$n.sofa" | cut -d' ' -f1)
            fi
            printf 'set %s %s 10 CC-BY-4.0 https://example.invalid/%s.sofa\n' "$n" "$sha" "$n"
        done
    } >"$BATS_TEST_TMPDIR/hrtf.lock"
    export AX20_HRTF_SOURCE_DIR="$d" AX20_HRTF_LOCK="$BATS_TEST_TMPDIR/hrtf.lock" AX20_SKIP_DOWNLOADS=1
    unset AX20_HOME AX20_AUDIO_USER SUDO_USER
}

ax() { "$CLI" --root "$AX20_ROOT" "$@"; }
settings() { cat "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"; }
loader="$H/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf"

@test "help lists audio-dsp" {
    run "$CLI" help
    assert_output_contains "audio-dsp"
}

@test "no subcommand or unknown subcommand exits 2" {
    run ax audio-dsp
    assert_failure 2
    run ax audio-dsp frobnicate
    assert_failure 2
    assert_output_contains "unknown audio-dsp command"
}

@test "status before install reports stock" {
    run ax audio-dsp status
    assert_success
    assert_output_contains "status:          stock"
    assert_output_contains "user/home:       deck /home/deck"
}

@test "on installs and reports active; on again is idempotent" {
    run ax audio-dsp on
    assert_success
    [ -f "$AX20_ROOT$loader" ]
    run ax audio-dsp status
    assert_output_contains "status:          active"
    assert_output_contains "hrtf:            set-a (installed)"
    local n
    n=$(wc -l <"$AX20_ROOT/var/lib/ally-x20-steamos/manifest")
    run ax audio-dsp on
    assert_success
    [ "$(wc -l <"$AX20_ROOT/var/lib/ally-x20-steamos/manifest")" = "$n" ]
}

@test "off removes the loader fragment and sinks, keeps HRTF data; on restores" {
    ax audio-dsp on
    run ax audio-dsp off
    assert_success
    [ ! -e "$AX20_ROOT$loader" ]
    [ ! -e "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf" ]
    [ -f "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/set-a.sofa" ]
    settings | grep -qx 'enabled=0'
    run ax audio-dsp status
    assert_output_contains "status:          stock"
    assert_output_contains "enabled:         0"
    run ax audio-dsp on
    assert_success
    [ -f "$AX20_ROOT$loader" ]
    settings | grep -qx 'enabled=1'
}

@test "off keeps a file the user modified and says so" {
    ax audio-dsp on
    printf '# mine\n' >>"$AX20_ROOT$loader"
    run ax audio-dsp off
    assert_failure
    assert_output_contains "was modified after install"
    [ -f "$AX20_ROOT$loader" ]
}

@test "hrtf list marks the current set; hrtf <name> relinks and persists" {
    ax audio-dsp on
    run ax audio-dsp hrtf list
    assert_success
    assert_output_contains "* set-a"
    assert_output_contains "  set-b"
    run ax audio-dsp hrtf set-b
    assert_success
    [ "$(readlink "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/current.sofa")" = set-b.sofa ]
    settings | grep -qx 'hrtf=set-b'
    run ax audio-dsp hrtf list
    assert_output_contains "* set-b"
    # a later apply keeps the user's choice
    ax audio-dsp on
    [ "$(readlink "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/current.sofa")" = set-b.sofa ]
}

@test "hrtf with an unknown name fails without touching anything" {
    ax audio-dsp on
    run ax audio-dsp hrtf nope
    assert_failure 2
    [ "$(readlink "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/current.sofa")" = set-a.sofa ]
}

@test "stereo-hrtf on|off toggles the settings file and the WirePlumber fragment" {
    ax audio-dsp on
    run ax audio-dsp stereo-hrtf on
    assert_success
    settings | grep -qx 'stereo_hrtf=1'
    grep -q 'x20.stereo_hrtf = true' "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    run ax audio-dsp stereo-hrtf off
    settings | grep -qx 'stereo_hrtf=0'
    grep -q 'x20.stereo_hrtf = false' "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    run ax audio-dsp stereo-hrtf maybe
    assert_failure 2
}

@test "stereo-hrtf while off only records the choice" {
    ax audio-dsp on
    ax audio-dsp off
    run ax audio-dsp stereo-hrtf on
    assert_success
    settings | grep -qx 'stereo_hrtf=1'
    [ ! -e "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf" ]
    ax audio-dsp on
    grep -q 'x20.stereo_hrtf = true' "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
}

@test "--dry-run on writes nothing" {
    run "$CLI" --root "$AX20_ROOT" --dry-run audio-dsp on
    assert_success
    [ ! -e "$AX20_ROOT/home" ]
    [ ! -s "$AX20_ROOT/var/lib/ally-x20-steamos/manifest" ]
}

@test "test refuses to run against a fixture root" {
    run ax audio-dsp test
    assert_failure 1
    assert_output_contains "needs the live system"
}

@test "refuses when the root filesystem was made writable" {
    : >"$AX20_ROOT/.ax20-readonly-disabled"
    run ax audio-dsp on
    assert_failure
    assert_output_contains "read-only"
}
