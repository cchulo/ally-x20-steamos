#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# lib/retired.sh: removing the files of components this version no longer
# ships (audio_dsp, removed 2026-11-01) on apply, boot and uninstall.
load '../test_helper'
load '../update_helper'

H=/home/deck
SETTINGS=$H/.config/ally-x20-steamos/audio-dsp.conf
HPCONF=$H/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf
WPLOADER=$H/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf
HOOK=$H/.local/share/wireplumber/scripts/x20-select-default-sink.lua
CORE=$H/.local/share/wireplumber/scripts/lib/x20-route-core.lua
SOFA=$H/.config/ally-x20-steamos/hrtf/mit-kemar.sofa
CURRENT=$H/.config/ally-x20-steamos/hrtf/current.sofa
VOLSTATE=$H/.local/state/wireplumber/x20-hardware-volume

setup() {
    make_root >/dev/null
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/retired.sh"
    unset AX20_SLOT AX20_KVER
    export AX20_KVER=7.2.7-valve2-test AX20_NO_RESTART=1
    mkdir -p "$AX20_ROOT$H/.config" "$AX20_ROOT$H/.local/share"
}

# old_audio_dsp_install : what the last version with audio_dsp left in the
# deck home, recorded under component audio_dsp exactly as it recorded it.
old_audio_dsp_install() {
    local src="$BATS_TEST_TMPDIR/src.d" p
    mkdir -p "$src"
    for p in "$SETTINGS" "$HPCONF" "$WPLOADER" "$HOOK" "$CORE" "$SOFA"; do
        printf 'old audio_dsp file %s\n' "$p" >"$src/f"
        manifest_install_file "$src/f" "$p" audio_dsp 0644 home
    done
    manifest_install_symlink mit-kemar.sofa "$CURRENT" audio_dsp home
    # written by WirePlumber, not by us
    fixture_file "$VOLSTATE" "[x20-hardware-volume]
alsa_output.speaker=0.550000
"
}

assert_audio_dsp_gone() {
    local p
    for p in "$SETTINGS" "$HPCONF" "$WPLOADER" "$HOOK" "$CORE" "$SOFA" "$CURRENT" "$VOLSTATE"; do
        [ ! -e "$AX20_ROOT$p" ] && [ ! -L "$AX20_ROOT$p" ]
    done
    [ -z "$(manifest_paths audio_dsp)" ]
    # directories we created are gone, the home and stock dirs stay
    [ ! -d "$AX20_ROOT$H/.config/ally-x20-steamos" ]
    [ ! -d "$AX20_ROOT$H/.config/pipewire" ]
    [ ! -d "$AX20_ROOT$H/.config/wireplumber" ]
    [ ! -d "$AX20_ROOT$H/.local/share/wireplumber" ]
    [ -d "$AX20_ROOT$H/.config" ]
    [ -d "$AX20_ROOT$H/.local/share" ]
}

@test "audio_dsp is retired and no longer a component" {
    retired_is audio_dsp
    ! retired_is audio || false
    ! component_exists audio_dsp || false
    [ ! -e "$REPO_ROOT/components/audio_dsp.sh" ]
    [ ! -e "$REPO_ROOT/cmd/audio-dsp.sh" ]
    [ ! -d "$REPO_ROOT/overlay/home" ]
}

@test "retired_prune_all removes every recorded audio_dsp file, its state file and empty dirs" {
    old_audio_dsp_install
    [ -n "$(manifest_paths audio_dsp)" ]
    run retired_prune_all
    assert_success
    assert_output_contains "audio_dsp: removing $HPCONF (component removed from ally-x20-steamos)"
    assert_output_contains "held a sink at 100 %"
    assert_output_contains "audio_dsp: removed (no longer part of ally-x20-steamos)"
    assert_audio_dsp_gone
}

@test "retired_prune_all with nothing recorded does nothing" {
    run retired_prune_all
    assert_success
    [ -z "$output" ]
}

@test "a modified file is kept, reported and stays in the manifest; the rest goes" {
    old_audio_dsp_install
    printf 'hand edit\n' >>"$AX20_ROOT$WPLOADER"
    run retired_prune_all
    assert_failure 1
    assert_output_contains "$WPLOADER was modified after install; leaving it in place"
    [ -f "$AX20_ROOT$WPLOADER" ]
    [ "$(manifest_paths audio_dsp | grep -c x20)" -ge 1 ]
    manifest_has "$WPLOADER"
    [ ! -e "$AX20_ROOT$HPCONF" ]
    [ ! -e "$AX20_ROOT$HOOK" ]
    # its directory is not empty, so it stays
    [ -d "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d" ]
}

@test "a recorded path without an x20 marker is never removed" {
    old_audio_dsp_install
    fixture_file "$H/.config/pipewire/pipewire.conf.d/stock.conf" "stock"
    manifest_record "$H/.config/pipewire/pipewire.conf.d/stock.conf" audio_dsp file \
        "$(ax20_sha256 "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/stock.conf")" home false
    run retired_prune_all
    assert_failure 1
    assert_output_contains "not removing $H/.config/pipewire/pipewire.conf.d/stock.conf: no x20 marker"
    [ -f "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/stock.conf" ]
}

@test "files already gone are forgotten; other components' entries are untouched" {
    old_audio_dsp_install
    rm -f "$AX20_ROOT$HOOK"
    fixture_file /etc/ally-x20-steamos-audio.conf "x"
    manifest_record /etc/ally-x20-steamos-audio.conf audio file "$(ax20_sha256 "$AX20_ROOT/etc/ally-x20-steamos-audio.conf")" shared false
    run retired_prune_all
    assert_success
    ! manifest_has "$HOOK" || false
    manifest_has /etc/ally-x20-steamos-audio.conf
    [ -f "$AX20_ROOT/etc/ally-x20-steamos-audio.conf" ]
}

@test "the settings directory is kept when something else lives in it" {
    old_audio_dsp_install
    fixture_file "$H/.config/ally-x20-steamos/notes.txt" "mine"
    run retired_prune_all
    assert_success
    [ -f "$AX20_ROOT$H/.config/ally-x20-steamos/notes.txt" ]
    [ ! -e "$AX20_ROOT$SETTINGS" ]
    [ ! -d "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf" ]
}

@test "homes are read from the removed paths" {
    run _retired_homes <<P
/home/deck/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf
/home/deck/.local/share/wireplumber/scripts/lib/x20-route-core.lua
/home/first.last/.config/ally-x20-steamos/audio-dsp.conf
/etc/ally-x20-steamos.conf
P
    assert_success
    [ "$output" = "/home/deck
/home/first.last" ]
}

@test "the user's audio is not restarted in a fixture root or with AX20_NO_RESTART" {
    run ax20_restart_user_audio deck
    assert_success
    [ -z "$output" ] || assert_output_contains "not restarting"
}

# --- through the CLI ------------------------------------------------------

@test "apply removes a retired component's files and writes status.json without it" {
    old_audio_dsp_install
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$AX20_ROOT" apply
    assert_success
    assert_output_contains "audio_dsp: removed"
    assert_audio_dsp_gone
    s="$AX20_ROOT/var/lib/ally-x20-steamos/state/status.json"
    jq -e . "$s" >/dev/null
    [ "$(jq -r 'has("audio_dsp")' "$s")" = false ]
    [ "$(jq -r '[.components[].name] | index("audio_dsp")' "$s")" = null ]
    # a second apply has nothing left to do
    run "$FAKE_CLI" --root "$AX20_ROOT" apply
    assert_success
    [[ "$output" != *"audio_dsp"* ]]
}

@test "the boot service run (apply --missing-only) removes them too" {
    old_audio_dsp_install
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --missing-only
    assert_success
    assert_audio_dsp_gone
}

@test "apply --only audio_dsp removes it instead of failing as unknown" {
    old_audio_dsp_install
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only audio_dsp
    assert_success
    assert_output_contains "audio_dsp is no longer part of ally-x20-steamos"
    assert_audio_dsp_gone
    run "$FAKE_CLI" --root "$AX20_ROOT" apply --only nonesuch
    assert_failure 2
}

@test "apply --slot leaves a retired component alone (its files live in /home)" {
    old_audio_dsp_install
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR"
    fake_src self-update rebuild
    slot="$BATS_TEST_TMPDIR/slotB"
    mkdir -p "$slot/usr/lib/modules/7.3.0-valve1-neptune" "$slot/etc" "$slot/var/lib/ally-x20-steamos"
    cp "$AX20_ROOT/var/lib/ally-x20-steamos/manifest" "$slot/var/lib/ally-x20-steamos/manifest"
    run env AX20_SLOT=B "$FAKE_CLI" --root "$AX20_ROOT" apply --slot "$slot"
    assert_success
    [[ "$output" != *"audio_dsp"* ]]
    [ -n "$(AX20_ROOT=$slot manifest_paths audio_dsp)" ]
}

@test "full uninstall from an old install removes the audio_dsp files" {
    old_audio_dsp_install
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$AX20_ROOT" uninstall --keep-state
    assert_success
    assert_audio_dsp_gone
}

@test "uninstall --component audio_dsp is accepted and removes even a modified file with --force" {
    old_audio_dsp_install
    printf 'hand edit\n' >>"$AX20_ROOT$HPCONF"
    export AX20_COMPONENTS_DIR="$BATS_TEST_TMPDIR/components"
    mkdir -p "$AX20_COMPONENTS_DIR"
    fake_src self-update rebuild
    run "$FAKE_CLI" --root "$AX20_ROOT" uninstall --component audio_dsp --force --keep-state
    assert_success
    assert_audio_dsp_gone
    run "$FAKE_CLI" --root "$AX20_ROOT" uninstall --component nonesuch
    assert_failure 2
}
