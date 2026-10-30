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
    grep -q 'x20.stereo_hrtf = false' "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    [ "$(component_status audio_dsp)" = active ]
}

@test "apply renders the absolute HRTF path into the surround conf" {
    component_apply audio_dsp
    local f="$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf"
    ! grep -q '@X20_HRTF_FILE@' "$f"
    [ "$(grep -c "filename = \"$H/.config/ally-x20-steamos/hrtf/current.sofa\"" "$f")" = 12 ]
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
    [ ! -e "$AX20_ROOT/home" ]
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
