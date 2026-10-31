#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/audio_dsp.sh: files, apply, status, probes, HRTF lock, Lua core.
load '../test_helper'

H=/home/deck

# fake_hrtf_sets : three tiny stand-in SOFA files plus a lock that pins them,
# so nothing touches the network (AX20_SKIP_DOWNLOADS=1).
fake_hrtf_sets() {
    local d="$BATS_TEST_TMPDIR/sofa" n sha
    mkdir -p "$d"
    {
        printf '# SPDX-License-Identifier: GPL-2.0-only\n'
        printf 'default set-a\n'
        for n in set-a set-b set-c; do
            printf 'fake %s sofa\n' "$n" >"$d/$n.sofa"
            sha=$(ax20_sha256 "$d/$n.sofa")
            printf 'set %s %s 15 CC-BY-4.0 https://example.invalid/%s.sofa\n' "$n" "$sha" "$n"
        done
    } >"$BATS_TEST_TMPDIR/hrtf.lock"
    export AX20_HRTF_SOURCE_DIR="$d"
    export AX20_HRTF_LOCK="$BATS_TEST_TMPDIR/hrtf.lock"
    export AX20_SKIP_DOWNLOADS=1
}

setup() {
    make_root >/dev/null
    source_libs
    unset AX20_HOME AX20_AUDIO_USER SUDO_USER
    fake_hrtf_sets
    mkdir -p "$AX20_ROOT/home/deck" # the user's home always exists on a real system
    component_load audio_dsp
}

@test "files: every destination is in the deck home, x20-prefixed, slot home" {
    run audio_dsp_files
    assert_success
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 6 ]
    while IFS=$'\t' read -r src dest mode slot; do
        [ -f "$REPO_ROOT/overlay/$src" ]
        case "$dest" in "$H"/*) ;; *) false ;; esac
        case "$(basename "$dest")" in 50-x20-* | 51-x20-* | x20-*) ;; *) false ;; esac
        [ "$mode" = 0644 ]
        [ "$slot" = home ]
    done <<<"$output"
}

@test "files: AX20_HOME overrides the target home" {
    export AX20_HOME=/home/alice
    run audio_dsp_files
    assert_output_contains "/home/alice/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf"
    assert_output_contains "/home/alice/.local/share/wireplumber/scripts/x20-route-by-channels.lua"
}

@test "files: LSP limiter variant only when the LV2 bundle exists" {
    run audio_dsp_files
    assert_output_contains "home/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf"
    mkdir -p "$AX20_ROOT/usr/lib/lv2/lsp-plugins.lv2"
    run audio_dsp_files
    assert_output_contains "home/pipewire/pipewire.conf.d/51-x20-speaker-chain-lsp.conf"
    assert_output_contains "$H/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf"
}

@test "apply installs config, HRTF sets, current.sofa and settings; status active" {
    [ "$(component_status audio_dsp)" = stock ]
    component_apply audio_dsp
    local r="$AX20_ROOT$H"
    [ -f "$r/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf" ]
    [ -f "$r/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf" ]
    [ -f "$r/.config/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf" ]
    [ -f "$r/.config/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf" ]
    [ -f "$r/.config/pipewire/client.conf.d/50-x20-no-upmix.conf" ]
    [ -f "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf" ]
    [ -f "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf" ]
    [ -f "$r/.local/share/wireplumber/scripts/x20-route-by-channels.lua" ]
    [ -f "$r/.local/share/wireplumber/scripts/lib/x20-route-core.lua" ]
    for n in set-a set-b set-c; do
        cmp "$r/.config/ally-x20-steamos/hrtf/$n.sofa" "$AX20_HRTF_SOURCE_DIR/$n.sofa"
    done
    [ "$(readlink "$r/.config/ally-x20-steamos/hrtf/current.sofa")" = set-a.sofa ]
    grep -qx 'enabled=1' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'hrtf=set-a' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'stereo_hrtf=0' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'speaker_surround=1' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'stereo_surround=0' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'xtc_delay_us=117' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'xtc_attenuation_db=4' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'xtc_taps=4' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -q 'x20.stereo_hrtf = false' "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    grep -q 'x20.speaker_surround = true' "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    grep -q 'x20.stereo_surround = false' "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    [ "$(component_status audio_dsp)" = active ]
}

@test "apply renders the absolute HRTF path into the surround conf" {
    component_apply audio_dsp
    local f="$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf"
    ! grep -q '@X20_HRTF_FILE@' "$f"
    [ "$(grep -c "filename = \"$H/.config/ally-x20-steamos/hrtf/current.sofa\"" "$f")" = 12 ]
    f="$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf"
    [ "$(grep -c "filename = \"$H/.config/ally-x20-steamos/hrtf/current.sofa\"" "$f")" = 7 ]
}

# speaker_conf : the rendered speaker surround conf.
speaker_conf() { printf '%s\n' "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf"; }

@test "speaker surround: defaults rendered (117 us -> 6.5 samples, 4 dB, 4 taps)" {
    component_apply audio_dsp
    local f
    f=$(speaker_conf)
    ! grep -q '@X20_' "$f"
    [ "$(grep -c '"Delay (s)" = 0.00013542 }' "$f")" = 8 ]
    [ "$(grep -c '"Gain 2" = 0.630957 "Gain 3" = 0.398107 "Gain 4" = 0.251189 "Gain 5" = 0.158489 "Gain 6" = 0.5' "$f")" = 2 ]
    grep -q 'Rendered with: xtc_delay_us=117 (6 samples at 48 kHz = 125 us) xtc_attenuation_db=4 (g=0.6310) xtc_taps=4' "$f"
    grep -q 'node.name        = "x20-speakers-surround"' "$f"
    grep -q 'media.class      = Audio/Sink/Internal' "$f"
    grep -q 'target.object    = "x20-speakers"' "$f"
}

@test "speaker surround: custom XTC settings are rendered, unused taps muted" {
    component_apply audio_dsp
    audio_dsp_write_settings xtc_delay_us=83 xtc_attenuation_db=6 xtc_taps=2
    component_apply audio_dsp
    local f
    f=$(speaker_conf)
    # 83 us * 48 kHz = 3.98 -> 4 samples -> (4 + 0.5) / 48000 s
    [ "$(grep -c '"Delay (s)" = 0.00009375 }' "$f")" = 8 ]
    [ "$(grep -c '"Gain 2" = 0.501187 "Gain 3" = 0.251189 "Gain 4" = 0.000000 "Gain 5" = 0.000000' "$f")" = 2 ]
    # apply kept the user's values
    grep -qx 'xtc_delay_us=83' "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'xtc_taps=2' "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
}

@test "speaker surround: invalid XTC settings fall back to the defaults" {
    component_apply audio_dsp
    # a hand edit with out-of-range values
    printf '%s\n' enabled=1 xtc_delay_us=5000 xtc_attenuation_db=-3 xtc_taps=9 speaker_surround=maybe \
        >"$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    component_apply audio_dsp
    grep -q 'xtc_delay_us=117 (6 samples' "$(speaker_conf)"
    grep -qx 'xtc_attenuation_db=4' "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'xtc_taps=4' "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'speaker_surround=1' "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
}

@test "xtc validators and parameter maths" {
    audio_dsp_xtc_valid_delay 117
    ! audio_dsp_xtc_valid_delay 9
    ! audio_dsp_xtc_valid_delay 1001
    ! audio_dsp_xtc_valid_delay 1.5
    audio_dsp_xtc_valid_atten 4
    audio_dsp_xtc_valid_atten 3.5
    ! audio_dsp_xtc_valid_atten 0.2
    ! audio_dsp_xtc_valid_atten -1
    ! audio_dsp_xtc_valid_atten 4dB
    audio_dsp_xtc_valid_taps 1
    ! audio_dsp_xtc_valid_taps 0
    ! audio_dsp_xtc_valid_taps 5
    [ "$(audio_dsp_xtc_params 117 4 4)" = "0.00013542 0.630957 0.398107 0.251189 0.158489 6 0.6310" ]
    [ "$(audio_dsp_xtc_params 10 3 1)" = "0.00003125 0.707946 0.000000 0.000000 0.000000 1 0.7079" ]
}

@test "write_settings keeps keys it is not given" {
    component_apply audio_dsp
    audio_dsp_write_settings xtc_taps=3 stereo_surround=1
    audio_dsp_write_settings speaker_surround=0
    local c="$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'xtc_taps=3' "$c"
    grep -qx 'stereo_surround=1' "$c"
    grep -qx 'speaker_surround=0' "$c"
    grep -qx 'hrtf=set-a' "$c"
    grep -qx 'enabled=1' "$c"
    audio_dsp_render_wpsettings
    grep -q 'x20.speaker_surround = false' "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    grep -q 'x20.stereo_surround = true' "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
}

@test "every manifest entry is in slot home and owned by audio_dsp" {
    component_apply audio_dsp
    run bash -c 'jq -r "select(.component == \"audio_dsp\") | .slot" "$1" | sort -u' _ "$AX20_ROOT/var/lib/ally-x20-steamos/manifest"
    [ "$output" = home ]
    for p in $(manifest_paths audio_dsp); do
        case "$p" in "$H"/*) ;; *) false ;; esac
    done
}

@test "apply is idempotent and needs no downloads the second time" {
    component_apply audio_dsp
    local before
    before=$(manifest_paths audio_dsp | sort)
    rm -rf "$AX20_HRTF_SOURCE_DIR"
    component_apply audio_dsp
    [ "$(manifest_paths audio_dsp | sort)" = "$before" ]
    [ "$(manifest_paths audio_dsp | sort | uniq -d)" = "" ]
    [ "$(component_status audio_dsp)" = active ]
}

@test "lock verification: a corrupted default set is rejected, surround conf withheld" {
    printf 'tampered' >"$AX20_HRTF_SOURCE_DIR/set-a.sofa"
    component_apply audio_dsp
    local r="$AX20_ROOT$H"
    [ ! -e "$r/.config/ally-x20-steamos/hrtf/set-a.sofa" ]
    [ -f "$r/.config/ally-x20-steamos/hrtf/set-b.sofa" ]
    [ ! -e "$r/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf" ]
    [ ! -e "$r/.config/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf" ]
    [ -f "$r/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf" ]
    [ "$(component_status audio_dsp)" = stock ]
}

@test "skip downloads without a source dir: config still installed, status stock" {
    unset AX20_HRTF_SOURCE_DIR
    component_apply audio_dsp
    [ -f "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf" ]
    [ ! -e "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/set-a.sofa" ]
    [ "$(component_status audio_dsp)" = stock ]
}

@test "dry-run writes nothing" {
    AX20_DRY_RUN=1 component_apply audio_dsp 2>/dev/null
    [ ! -e "$AX20_ROOT/home/deck/.config" ]
    [ ! -s "$AX20_ROOT/var/lib/ally-x20-steamos/manifest" ]
}

@test "hand-edited config file is drift: status stock" {
    component_apply audio_dsp
    printf '# mine\n' >>"$AX20_ROOT$H/.config/pipewire/client.conf.d/50-x20-no-upmix.conf"
    [ "$(component_status audio_dsp)" = stock ]
}

@test "disable removes config, keeps HRTF data; apply then keeps it off" {
    component_apply audio_dsp
    audio_dsp_disable
    local r="$AX20_ROOT$H"
    [ ! -e "$r/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf" ]
    [ ! -e "$r/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf" ]
    [ ! -e "$r/.config/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf" ]
    [ ! -e "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf" ]
    [ ! -e "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/x20-route-by-channels.lua" ]
    [ -f "$r/.config/ally-x20-steamos/hrtf/set-a.sofa" ]
    grep -qx 'enabled=0' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    [ -z "$(audio_dsp_files)" ]
    [ "$(component_status audio_dsp)" = stock ]
    component_apply audio_dsp
    [ ! -e "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf" ]
    ! manifest_has "$H/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf"
}

@test "uninstall-ability: every entry verifies and can be removed newest-first" {
    component_apply audio_dsp
    local line p kind
    while IFS= read -r line; do
        p=$(manifest_entry_get "$line" path)
        kind=$(manifest_entry_get "$line" kind)
        manifest_verify "$p"
        case "$kind" in
            file | symlink)
                case "$p" in *x20* | *ally-x20-steamos*) ;; *) false ;; esac
                rm -f "$AX20_ROOT$p"
                ;;
            dir) rmdir "$AX20_ROOT$p" 2>/dev/null || true ;;
        esac
        manifest_forget "$p"
    done < <(manifest_entries_reverse | grep '"component":"audio_dsp"')
    [ -z "$(find "$AX20_ROOT/home" -type f -o -type l)" ]
}

@test "probe: never superseded" {
    run audio_dsp_probe
    assert_failure 1
}

@test "sofa probe: filter-graph plugin (PipeWire >= 1.3) + libmysofa" {
    fixture_file /usr/lib/pipewire-0.3/libpipewire-module-filter-chain.so "help text mentions sofa"
    run audio_dsp_probe_sofa_support
    assert_failure 1
    fixture_file /usr/lib/spa-0.2/filter-graph/libspa-filter-graph-plugin-sofa.so "ELF"
    run audio_dsp_probe_sofa_support
    assert_failure 1 # plugin present, libmysofa missing
    fixture_file /usr/lib/libmysofa.so.1.3.4 "ELF"
    run audio_dsp_probe_sofa_support
    assert_success
}

@test "sofa probe: legacy filter-chain-sofa module (PipeWire <= 1.2)" {
    fixture_file /usr/lib/pipewire-0.3/libpipewire-module-filter-chain-sofa.so "ELF"
    fixture_file /usr/lib/libmysofa.so.1 "ELF"
    run audio_dsp_probe_sofa_support
    assert_success
}

@test "sofa probe: strings fallback on the filter-chain module" {
    fixture_file /usr/lib/pipewire-0.3/libpipewire-module-filter-chain.so "x mysofa_open_cached x"
    run audio_dsp_probe_sofa_plugin
    assert_success
}

@test "sofa probe: unknown without any PipeWire, libmysofa from our state dir counts" {
    run audio_dsp_probe_sofa_plugin
    assert_failure 2
    run audio_dsp_probe_libmysofa
    assert_failure 1
    fixture_file /var/lib/ally-x20-steamos/lib/libmysofa.so.1 "ELF"
    run audio_dsp_probe_libmysofa
    assert_success
}

@test "fetch-hrtf.sh: verifies, rejects mismatches, lists and reports the default" {
    local f="$REPO_ROOT/overlay/home/hrtf/fetch-hrtf.sh" out="$BATS_TEST_TMPDIR/out"
    run "$f" --lock "$AX20_HRTF_LOCK" --dest "$out" --source-dir "$AX20_HRTF_SOURCE_DIR" set-b
    assert_success
    cmp "$out/set-b.sofa" "$AX20_HRTF_SOURCE_DIR/set-b.sofa"
    printf 'evil' >"$AX20_HRTF_SOURCE_DIR/set-c.sofa"
    run "$f" --lock "$AX20_HRTF_LOCK" --dest "$out" --source-dir "$AX20_HRTF_SOURCE_DIR" set-c
    assert_failure 1
    assert_output_contains "SHA-256 mismatch"
    [ ! -e "$out/set-c.sofa" ] && [ ! -e "$out/set-c.sofa.part" ]
    run "$f" --lock "$AX20_HRTF_LOCK" --dest "$out" nope
    assert_failure 1
    run "$f" --lock "$AX20_HRTF_LOCK" --list
    assert_output_contains "set-a CC-BY-4.0 https://example.invalid/set-a.sofa"
    run "$f" --lock "$AX20_HRTF_LOCK" --default
    [ "$output" = set-a ]
}

@test "shipped hrtf.lock: default exists, 2-3 sets, sha256 + license + https url each" {
    local lock="$REPO_ROOT/overlay/home/hrtf/hrtf.lock" def n
    def=$(awk '$1 == "default" { print $2 }' "$lock")
    awk -v d="$def" '$1 == "set" && $2 == d { f = 1 } END { exit !f }' "$lock"
    n=$(awk '$1 == "set"' "$lock" | wc -l | tr -d ' ')
    [ "$n" -ge 2 ] && [ "$n" -le 3 ]
    awk '$1 == "set" && ($3 !~ /^[0-9a-f]{64}$/ || $5 == "" || $6 !~ /^https:\/\//) { bad = 1 } END { exit bad }' "$lock"
    for n in $(awk '$1 == "set" { print $2 }' "$lock"); do
        grep -q "^attribution $n " "$lock"
        grep -q "$n" "$REPO_ROOT/LICENSE.md"
    done
}

@test "overlay confs: SPDX comment and balanced braces/brackets" {
    local f
    for f in $(find "$REPO_ROOT/overlay/home" -name '*.conf'); do
        head -n1 "$f" | grep -q 'SPDX-License-Identifier: GPL-2.0-only'
        # strip comments and quoted strings, then count delimiters
        run awk '{ sub(/#.*/, ""); gsub(/"[^"]*"/, ""); o += gsub(/\{/, "{"); c += gsub(/\}/, "}"); so += gsub(/\[/, "["); sc += gsub(/\]/, "]") }
            END { if (o != c || so != sc) { print FILENAME, o, c, so, sc; exit 1 } }' "$f"
        assert_success
    done
}

@test "surround conf: per-layout azimuths and channel maps" {
    local f="$REPO_ROOT/overlay/home/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf"
    grep -q 'node.name        = "x20-virtual-surround-71"' "$f"
    grep -q 'node.name        = "x20-virtual-surround-51"' "$f"
    grep -q 'audio.position   = \[ FL FR FC LFE RL RR SL SR \]' "$f"
    grep -q 'audio.position   = \[ FL FR FC LFE RL RR \]' "$f"
    # 7.1 rears at 150/210, 5.1 surrounds at 110/250, sides at 90/270
    for a in 30.0 330.0 0.0 90.0 270.0 150.0 210.0 110.0 250.0; do
        grep -q "\"Azimuth\"   = $a\$" "$f"
    done
}

@test "speaker surround template: 7.1 angles, XTC network wiring, LFE after the canceller" {
    local f="$REPO_ROOT/overlay/home/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf"
    grep -q 'audio.position   = \[ FL FR FC LFE RL RR SL SR \]' "$f"
    for a in 30.0 330.0 0.0 90.0 270.0 150.0 210.0; do
        grep -q "\"Azimuth\"   = $a\$" "$f"
    done
    [ "$(grep -c 'label = delay' "$f")" = 8 ]
    [ "$(grep -c 'label = invert' "$f")" = 4 ]
    # odd taps come inverted from the other side, even taps from the same side
    grep -q '{ output = "ivR1:Out" input = "xoL:In 2" }' "$f"
    grep -q '{ output = "dL2:Out"  input = "xoL:In 3" }' "$f"
    grep -q '{ output = "ivR3:Out" input = "xoL:In 4" }' "$f"
    grep -q '{ output = "dL4:Out"  input = "xoL:In 5" }' "$f"
    grep -q '{ output = "ivL1:Out" input = "xoR:In 2" }' "$f"
    grep -q '{ output = "dR4:Out"  input = "xoR:In 5" }' "$f"
    # band-limited branch, LFE bypasses binaural render and XTC
    grep -q '{ output = "xlpL:Out" input = "dL1:In" }' "$f"
    grep -q '{ output = "cpLFE:Out" input = "xoL:In 6" }' "$f"
    ! grep -q 'cpLFE:Out" input = "bin' "$f"
    grep -q 'outputs = \[ "xoL:Out" "xoR:Out" \]' "$f"
}

@test "headphone sinks are labelled headphones-only" {
    local f="$REPO_ROOT/overlay/home/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf"
    [ "$(grep -c 'node.description = "X20 headphone surround 7.1 (headphones only)"' "$f")" = 2 ]
    [ "$(grep -c 'node.description = "X20 headphone surround 5.1 (headphones only)"' "$f")" = 2 ]
}

# --- Lua decision core (tests/lua/test_x20_route_core.lua) -----------------

lua_bin() {
    local b
    for b in lua lua5.4 lua5.3 luajit; do
        if command -v "$b" >/dev/null 2>&1; then
            printf '%s\n' "$b"
            return 0
        fi
    done
    return 1
}

@test "lua: routing decisions (fixtures in tests/fixtures/audio_dsp)" {
    local lua
    lua=$(lua_bin) || skip "no Lua interpreter (lua, lua5.4, lua5.3, luajit) installed; routing decision tests not run"
    run "$lua" "$REPO_ROOT/tests/lua/test_x20_route_core.lua" "$REPO_ROOT"
    assert_success
    assert_output_contains " 0 failures"
}

@test "lua: router glue and core parse" {
    local lua f
    lua=$(lua_bin) || skip "no Lua interpreter (lua, lua5.4, lua5.3, luajit) installed; syntax check not run"
    for f in "$REPO_ROOT"/overlay/home/wireplumber/scripts/x20-route-by-channels.lua \
        "$REPO_ROOT"/overlay/home/wireplumber/scripts/lib/x20-route-core.lua; do
        run "$lua" -e "assert(loadfile('$f'))"
        assert_success
    done
}

@test "every x20 sink is hidden from pulse pickers (media.class Audio/Sink/Internal)" {
    component_apply audio_dsp
    for f in "$AX20_ROOT$H"/.config/pipewire/pipewire.conf.d/5*-x20-*.conf; do
        ! grep -qE 'media.class\s*=\s*Audio/Sink\s*$' "$f" || { echo "visible sink in $f"; false; }
    done
    [ "$(grep -h 'media.class' "$AX20_ROOT$H"/.config/pipewire/pipewire.conf.d/5*-x20-*.conf | grep -c 'Audio/Sink/Internal')" -ge 4 ]
}
