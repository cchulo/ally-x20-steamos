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
    [ ! -e "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf" ]
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

wpset() { cat "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"; }
@test "no speaker virtual surround: no sink, no settings, its commands are unknown" {
    run ax audio-dsp on
    assert_success
    [ ! -e "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf" ]
    ! settings | grep -Eq '^(speaker_surround|stereo_surround|xtc_[a-z_]*|master_gain_db)=' || false
    ! wpset | grep -Eq 'x20\.(speaker_surround|stereo_surround)' || false
    local before c
    before=$(settings)
    for c in "stereo-surround on" "stereo-surround off" "speaker-surround off" "xtc" "xtc set 117 4" "xtc reset"; do
        # shellcheck disable=SC2086  # split the command words
        run ax audio-dsp $c
        assert_failure 2
        assert_output_contains "unknown audio-dsp command"
    done
    [ "$(settings)" = "$before" ]
    run ax audio-dsp status
    ! printf '%s\n' "$output" | grep -Eq 'stereo_surround|speaker_surround|speaker surround|xtc|x20-speakers-surround' || false
    run ax audio-dsp help
    ! printf '%s\n' "$output" | grep -Eq 'stereo-surround|speaker-surround|xtc' || false
}

chainconf="$H/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf"

@test "lfe set renders every chain and persists; bad values rejected" {
    ax audio-dsp on
    run ax audio-dsp lfe
    assert_output_contains "lfe_cutoff_hz=120 lfe_gain_db=-6"
    run ax audio-dsp lfe set 90 -9
    assert_success
    settings | grep -qx 'lfe_cutoff_hz=90'
    settings | grep -qx 'lfe_gain_db=-9'
    grep -q '"Freq" = 90.0' "$AX20_ROOT$chainconf"
    grep -q '"Freq" = 90.0' "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf"
    local before
    before=$(settings)
    run ax audio-dsp lfe set 20 -6
    assert_failure 2
    run ax audio-dsp lfe set 120 10
    assert_failure 2
    run ax audio-dsp lfe set 120
    assert_failure 2
    [ "$(settings)" = "$before" ]
}

@test "master-gain: show, auto, strict, number, optional speakers word; persisted across apply" {
    ax audio-dsp on
    run ax audio-dsp master-gain
    assert_success
    assert_output_contains "x20-speakers: lfe 120 Hz -6 dB; worst case before master: stereo +1.9 dB, 7.1 downmix +11.8 dB; speakers_master_gain_db=auto (+0.0 dB)"
    ! printf '%s\n' "$output" | grep -q 'surround' || false
    run ax audio-dsp master-gain strict
    assert_success
    settings | grep -qx 'speakers_master_gain_db=strict'
    grep -q '"Gain 1" = 0.256832 }' "$AX20_ROOT$chainconf"
    run ax audio-dsp master-gain -4.5
    assert_success
    settings | grep -qx 'speakers_master_gain_db=-4.5'
    grep -q '"Gain 1" = 0.595662 }' "$AX20_ROOT$chainconf"
    run ax audio-dsp master-gain speakers strict
    assert_success
    settings | grep -qx 'speakers_master_gain_db=strict'
    ax audio-dsp on
    grep -q '"Gain 1" = 0.256832 }' "$AX20_ROOT$chainconf"
    run ax audio-dsp master-gain loud
    assert_failure 2
    run ax audio-dsp master-gain speakers
    assert_failure 2
    run ax audio-dsp master-gain auto
    assert_success
    grep -q '"Gain 1" = 1.000000 }' "$AX20_ROOT$chainconf"
    ! settings | grep -q '^master_gain_db=' || false
}

@test "lfe and master-gain while off only record the choice" {
    ax audio-dsp on
    ax audio-dsp off
    run ax audio-dsp master-gain strict
    assert_success
    run ax audio-dsp lfe set 100 -12
    assert_success
    [ ! -e "$AX20_ROOT$chainconf" ]
    settings | grep -qx 'speakers_master_gain_db=strict'
    settings | grep -qx 'lfe_cutoff_hz=100'
    ax audio-dsp on
    grep -q '"Freq" = 100.0' "$AX20_ROOT$chainconf"
}

@test "status shows the gain structure" {
    ax audio-dsp on
    run ax audio-dsp status
    assert_output_contains "x20-speakers:    lfe 120 Hz -6 dB; worst case before master: stereo +1.9 dB"
}

prio_of() { sed -n 's/^ *priority.session = //p' "$AX20_ROOT$1" | head -n1; }

@test "speakers-precedence off|on re-renders the x20-speakers priority; status shows it" {
    ax audio-dsp on
    [ "$(prio_of "$chainconf")" = 750 ]
    run ax audio-dsp status
    assert_output_contains "speakers_precedence: 1 (priority.session x20-speakers 750)"
    run ax audio-dsp speakers-precedence off
    assert_success
    assert_output_contains "speakers-precedence: off (priority.session x20-speakers 50)"
    settings | grep -qx 'speakers_precedence=0'
    [ "$(prio_of "$chainconf")" = 50 ]
    run ax audio-dsp status
    assert_output_contains "speakers_precedence: 0 (priority.session x20-speakers 50)"
    # survives a re-apply
    ax audio-dsp on
    [ "$(prio_of "$chainconf")" = 50 ]
    run ax audio-dsp speakers-precedence on
    assert_success
    [ "$(prio_of "$chainconf")" = 750 ]
    run ax audio-dsp speakers-precedence sometimes
    assert_failure 2
}

@test "speakers-precedence while off only records the choice" {
    ax audio-dsp on
    ax audio-dsp off
    run ax audio-dsp speakers-precedence off
    assert_success
    [ ! -e "$AX20_ROOT$chainconf" ]
    settings | grep -qx 'speakers_precedence=0'
    ax audio-dsp on
    [ "$(prio_of "$chainconf")" = 50 ]
}

@test "stereo-hrtf is recorded but says it no longer routes" {
    ax audio-dsp on
    run ax audio-dsp stereo-hrtf on
    assert_success
    assert_output_contains "no longer changes routing"
    settings | grep -qx 'stereo_hrtf=1'
    wpset | grep -q 'x20.stereo_hrtf = true'
}

@test "headphones-virtual-surround off|on: persisted and rendered for the default-sink hook" {
    ax audio-dsp on
    settings | grep -qx 'headphones_virtual_surround=1'
    wpset | grep -q 'x20.headphones_virtual_surround = true'
    run ax audio-dsp headphones-virtual-surround off
    assert_success
    settings | grep -qx 'headphones_virtual_surround=0'
    wpset | grep -q 'x20.headphones_virtual_surround = false'
    run ax audio-dsp status
    assert_output_contains "headphones_virtual_surround: 0"
    # survives a re-apply
    ax audio-dsp on
    wpset | grep -q 'x20.headphones_virtual_surround = false'
    run ax audio-dsp headphones-virtual-surround on
    assert_success
    wpset | grep -q 'x20.headphones_virtual_surround = true'
    run ax audio-dsp headphones-virtual-surround maybe
    assert_failure 2
}

@test "speakers-precedence is rendered for the default-sink hook too" {
    ax audio-dsp on
    wpset | grep -q 'x20.speakers_precedence = true'
    ax audio-dsp speakers-precedence off
    wpset | grep -q 'x20.speakers_precedence = false'
}

@test "hardware-volume off|on: default on, persisted, rendered for the hook, shown in status" {
    ax audio-dsp on
    settings | grep -qx 'hardware_volume=1'
    wpset | grep -q 'x20.hardware_volume = true'
    run ax audio-dsp status
    assert_output_contains "hardware_volume: 1"
    run ax audio-dsp hardware-volume off
    assert_success
    settings | grep -qx 'hardware_volume=0'
    wpset | grep -q 'x20.hardware_volume = false'
    run ax audio-dsp status
    assert_output_contains "hardware_volume: 0"
    # survives a re-apply; the other defaults are untouched
    ax audio-dsp on
    wpset | grep -q 'x20.hardware_volume = false'
    settings | grep -qx 'speakers_precedence=1'
    settings | grep -qx 'headphones_virtual_surround=1'
    run ax audio-dsp hardware-volume on
    assert_success
    wpset | grep -q 'x20.hardware_volume = true'
    run ax audio-dsp hardware-volume loud
    assert_failure 2
}
