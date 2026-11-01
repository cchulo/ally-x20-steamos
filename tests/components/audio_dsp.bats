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
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 9 ]
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
    assert_output_contains "/home/alice/.config/pipewire/client.conf.d/50-x20-no-upmix.conf"
    assert_output_contains "/home/alice/.local/share/wireplumber/scripts/x20-route-by-channels.lua"
}

@test "speaker chain: rendered from the LSP limiter variant only when the LV2 bundle exists" {
    local f="$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf"
    component_apply audio_dsp
    ! grep -q 'lsp-plug.in' "$f"
    mkdir -p "$AX20_ROOT/usr/lib/lv2/lsp-plugins.lv2"
    component_apply audio_dsp
    grep -q 'plugin = "http://lsp-plug.in/plugins/lv2/limiter_stereo"' "$f"
    grep -q '{ output = "mgL:Out" input = "lim:in_l" }' "$f"
    ! grep -q '@X20_' "$f"
}

@test "apply installs config, HRTF sets, current.sofa and settings; status active" {
    [ "$(component_status audio_dsp)" = stock ]
    component_apply audio_dsp
    local r="$AX20_ROOT$H"
    [ -f "$r/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf" ]
    [ -f "$r/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf" ]
    [ ! -e "$r/.config/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf" ]
    [ -f "$r/.config/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf" ]
    [ -f "$r/.config/pipewire/client.conf.d/50-x20-no-upmix.conf" ]
    [ -f "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf" ]
    [ -f "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf" ]
    [ -f "$r/.local/share/wireplumber/scripts/x20-route-by-channels.lua" ]
    [ -f "$r/.local/share/wireplumber/scripts/lib/x20-route-core.lua" ]
    [ -f "$r/.local/share/wireplumber/scripts/x20-select-default-sink.lua" ]
    [ -f "$r/.local/share/wireplumber/scripts/lib/x20-sink-facts.lua" ]
    [ -f "$r/.local/share/wireplumber/scripts/x20-hardware-volume.lua" ]
    [ -f "$r/.local/share/wireplumber/scripts/lib/x20-volume-core.lua" ]
    manifest_has "$H/.local/share/wireplumber/scripts/x20-hardware-volume.lua"
    manifest_has "$H/.local/share/wireplumber/scripts/lib/x20-volume-core.lua"
    grep -q 'name = x20-select-default-sink.lua, type = script/lua' "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf"
    grep -q 'name = x20-hardware-volume.lua, type = script/lua' "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf"
    grep -q 'custom.x20-hardware-volume \]' "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf"
    grep -q 'x20.hardware_volume = true' "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    grep -qx 'hardware_volume=1' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    for n in set-a set-b set-c; do
        cmp "$r/.config/ally-x20-steamos/hrtf/$n.sofa" "$AX20_HRTF_SOURCE_DIR/$n.sofa"
    done
    [ "$(readlink "$r/.config/ally-x20-steamos/hrtf/current.sofa")" = set-a.sofa ]
    grep -qx 'enabled=1' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'hrtf=set-a' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'stereo_hrtf=0' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'speakers_precedence=1' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    ! grep -Eq '^(speaker_surround|stereo_surround|xtc_[a-z_]*|master_gain_db)=' "$r/.config/ally-x20-steamos/audio-dsp.conf" || false
    grep -q 'x20.stereo_hrtf = false' "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    ! grep -Eq 'x20\.(speaker_surround|stereo_surround)' "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf" || false
    grep -q 'x20.speakers_precedence = true' "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    grep -q 'x20.headphones_virtual_surround = true' "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    grep -qx 'headphones_virtual_surround=1' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    [ "$(component_status audio_dsp)" = active ]
}

@test "apply renders the absolute HRTF path into the headphone conf" {
    component_apply audio_dsp
    local f="$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf"
    ! grep -q '@X20_HRTF_FILE@' "$f"
    [ "$(grep -c "filename = \"$H/.config/ally-x20-steamos/hrtf/current.sofa\"" "$f")" = 7 ]
}

# pinned_output <file> : x20-speakers.output goes to the hardware speaker
# sink by name, never falls back, waits (linger) instead of being destroyed.
pinned_output() {
    local f=$1 pb
    pb=$(sed -n '/playback.props = {/,/}/p' "$f")
    printf '%s\n' "$pb" | grep -q 'node.name        = "x20-speakers.output"'
    printf '%s\n' "$pb" | grep -qx '                target.object    = "alsa_output.pci-0000_64_00.5-platform-amd_sdw.HiFi__Speaker__sink"'
    printf '%s\n' "$pb" | grep -qx '                node.dont-fallback = true'
    printf '%s\n' "$pb" | grep -qx '                node.linger      = true'
    printf '%s\n' "$pb" | grep -qx '                node.passive     = true'
}

@test "speaker chain: output pinned to the hardware Speaker sink (builtin and LSP variant)" {
    local f="$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf"
    component_apply audio_dsp
    pinned_output "$f"
    mkdir -p "$AX20_ROOT/usr/lib/lv2/lsp-plugins.lv2"
    component_apply audio_dsp
    grep -q 'lsp-plug.in' "$f"
    pinned_output "$f"
    # the templates themselves, so neither variant can drift
    pinned_output "$REPO_ROOT/overlay/home/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf"
    pinned_output "$REPO_ROOT/overlay/home/pipewire/pipewire.conf.d/51-x20-speaker-chain-lsp.conf"
    # the speaker virtual surround is gone (removed 2026-10)
    [ ! -e "$REPO_ROOT/overlay/home/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf" ]
}

# prio <conf> : the priority.session and priority.driver values of a rendered
# conf, one line ("<session> <driver>" per sink, space separated).
prio() {
    local f="$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/$1"
    printf '%s %s\n' "$(sed -n 's/^ *priority.session = //p' "$f" | tr '\n' ' ' | sed 's/ $//')" \
        "$(sed -n 's/^ *priority.driver  = //p' "$f" | tr '\n' ' ' | sed 's/ $//')"
}

@test "priorities: x20-speakers 750 by default; x20-headphones 50" {
    component_apply audio_dsp
    [ "$(prio 51-x20-speaker-chain.conf)" = "750 750" ]
    [ "$(prio 50-x20-headphones.conf)" = "50 " ]
    [ "$(audio_dsp_priority)" = 750 ]
}

@test "WirePlumber settings: precedence and headphone surround rendered from audio-dsp.conf" {
    component_apply audio_dsp
    audio_dsp_write_settings speakers_precedence=0 headphones_virtual_surround=0
    audio_dsp_render_wpsettings
    local w="$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    grep -q 'x20.speakers_precedence = false' "$w"
    grep -q 'x20.headphones_virtual_surround = false' "$w"
    # invalid values fall back to the default (on)
    audio_dsp_write_settings headphones_virtual_surround=maybe
    [ "$(audio_dsp_setting_value headphones_virtual_surround)" = 1 ]
    # the schema has no entries for the removed speaker virtual surround
    ! grep -Eq '^  x20\.(speaker_surround|stereo_surround) = \{' "$REPO_ROOT/overlay/home/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf" || false
    # every rendered key has a schema entry in the loader
    for k in $(sed -n 's/^  \(x20\.[a-z_]*\) = .*/\1/p' "$w"); do
        grep -q "^  $k = {" "$REPO_ROOT/overlay/home/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf"
    done
}

@test "uninstall removes the WirePlumber hook files" {
    component_apply audio_dsp
    run sh "$REPO_ROOT/uninstall/uninstall.sh" --root "$AX20_ROOT" --yes --quiet --component audio_dsp
    assert_success
    local r="$AX20_ROOT$H"
    [ ! -e "$r/.local/share/wireplumber/scripts/x20-select-default-sink.lua" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/lib/x20-sink-facts.lua" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/x20-route-by-channels.lua" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/x20-hardware-volume.lua" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/lib/x20-volume-core.lua" ]
    [ ! -e "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf" ]
}

@test "priorities: speakers_precedence=0 puts x20-speakers at 50 (also with the LSP variant)" {
    component_apply audio_dsp
    audio_dsp_write_settings speakers_precedence=0
    mkdir -p "$AX20_ROOT/usr/lib/lv2/lsp-plugins.lv2"
    component_apply audio_dsp
    [ "$(prio 51-x20-speaker-chain.conf)" = "50 50" ]
    [ "$(audio_dsp_priority)" = 50 ]
    grep -qx 'speakers_precedence=0' "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    # invalid values fall back to the default (on)
    audio_dsp_write_settings speakers_precedence=maybe
    [ "$(audio_dsp_setting_value speakers_precedence)" = 1 ]
}

@test "settings of the removed speaker virtual surround are ignored and dropped" {
    component_apply audio_dsp
    local c="$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    # a settings file written by the previous version, plus garbage
    printf '%s\n' enabled=1 hrtf=set-b stereo_hrtf=0 speaker_surround=1 speakers_precedence=1 \
        headphones_virtual_surround=1 stereo_surround=1 hardware_volume=0 xtc_delay_us=117 \
        xtc_attenuation_db=4 xtc_taps=4 lfe_cutoff_hz=90 lfe_gain_db=-6 master_gain_db=-3 \
        speakers_master_gain_db=auto 'not a setting' >"$c"
    [ "$(audio_dsp_setting_value hrtf)" = set-b ]
    [ "$(audio_dsp_setting_value hardware_volume)" = 0 ]
    [ "$(audio_dsp_setting_value lfe_cutoff_hz)" = 90 ]
    run audio_dsp_setting_value stereo_surround
    assert_failure
    component_apply audio_dsp
    # known keys kept, removed ones dropped on the rewrite
    grep -qx 'hrtf=set-b' "$c"
    grep -qx 'hardware_volume=0' "$c"
    grep -qx 'lfe_cutoff_hz=90' "$c"
    ! grep -Eq '^(speaker_surround|stereo_surround|xtc_[a-z_]*|master_gain_db)=' "$c" || false
    ! grep -q 'not a setting' "$c" || false
    [ "$(prio 51-x20-speaker-chain.conf)" = "750 750" ]
    [ "$(component_status audio_dsp)" = active ]
}

# pwconf <name> : a rendered PipeWire conf in the deck home.
pwconf() { printf '%s\n' "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/$1"; }

@test "LFE: low-passed (2 cascaded biquads at 120 Hz) and folded at -6 dB in every chain" {
    component_apply audio_dsp
    local f
    for f in 50-x20-headphones.conf 51-x20-speaker-chain.conf; do
        ! grep -q '@X20_' "$(pwconf "$f")"
        ! grep -q 'name = cpLFE' "$(pwconf "$f")"
    done
    # one graph in each conf
    [ "$(grep -c 'label = bq_lowpass name = lfeLP[12]' "$(pwconf 50-x20-headphones.conf)")" = 2 ]
    [ "$(grep -c '"Freq" = 120.0 "Q" = 0.707' "$(pwconf 50-x20-headphones.conf)")" = 2 ]
    [ "$(grep -c '"Freq" = 120.0 "Q" = 0.707' "$(pwconf 51-x20-speaker-chain.conf)")" = 2 ]
    [ "$(grep -c '"Gain 5" = 0.501187' "$(pwconf 51-x20-speaker-chain.conf)")" = 2 ]
    [ "$(grep -c '"Gain 8" = 0.501187' "$(pwconf 50-x20-headphones.conf)")" = 2 ]
    grep -q '{ output = "lfeLP1:Out" input = "lfeLP2:In" }' "$(pwconf 51-x20-speaker-chain.conf)"
    grep -q 'inputs  = \[ "dmL:In 1" "dmR:In 1" "cpFC:In" "lfeLP1:In"' "$(pwconf 51-x20-speaker-chain.conf)"
}

@test "LFE: custom cutoff and level are rendered" {
    component_apply audio_dsp
    audio_dsp_write_settings lfe_cutoff_hz=80 lfe_gain_db=-10
    component_apply audio_dsp
    [ "$(grep -c '"Freq" = 80.0 "Q" = 0.707' "$(pwconf 50-x20-headphones.conf)")" = 2 ]
    [ "$(grep -c '"Freq" = 80.0 "Q" = 0.707' "$(pwconf 51-x20-speaker-chain.conf)")" = 2 ]
    [ "$(grep -c '"Gain 5" = 0.316228' "$(pwconf 51-x20-speaker-chain.conf)")" = 2 ]
}

@test "gain analysis: default numbers and rendered master gain" {
    component_apply audio_dsp
    # stereo, 7.1 downmix (dB over full scale before master), master dB, linear
    [ "$(audio_dsp_gain_numbers)" = "1.9 11.8 0.0 1.000000" ]
    [ "$(grep -c '"Gain 1" = 1.000000 }' "$(pwconf 51-x20-speaker-chain.conf)")" = 2 ]
    grep -q 'worst case before master: stereo +1.9 dB, 7.1 downmix +11.8 dB; speakers_master_gain_db=auto (+0.0 dB)' "$(pwconf 51-x20-speaker-chain.conf)"
}

@test "gain analysis: strict and explicit master gain" {
    component_apply audio_dsp
    audio_dsp_write_settings speakers_master_gain_db=strict
    [ "$(audio_dsp_gain_numbers)" = "1.9 11.8 -11.8 0.256832" ]
    audio_dsp_write_settings speakers_master_gain_db=-1.5
    component_apply audio_dsp
    [ "$(audio_dsp_gain_numbers | cut -d' ' -f3-)" = "-1.5 0.841395" ]
    [ "$(grep -c '"Gain 1" = 0.841395 }' "$(pwconf 51-x20-speaker-chain.conf)")" = 2 ]
    # out-of-range values fall back to auto
    audio_dsp_write_settings speakers_master_gain_db=loud
    [ "$(audio_dsp_setting_value speakers_master_gain_db)" = auto ]
}

@test "gain analysis matches an independent python implementation" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    component_apply audio_dsp
    audio_dsp_write_settings lfe_cutoff_hz=90 lfe_gain_db=-3
    local want
    want=$(python3 - <<'PY'
import cmath, math
fs = 48000.0
def bq(kind, f0, Q, g=0.0):
    w0 = 2 * math.pi * f0 / fs; al = math.sin(w0) / (2 * Q); k = math.cos(w0); A = 10 ** (g / 40)
    if kind == 'lp': b = [(1 - k) / 2, 1 - k, (1 - k) / 2]; a = [1 + al, -2 * k, 1 - al]
    if kind == 'hp': b = [(1 + k) / 2, -(1 + k), (1 + k) / 2]; a = [1 + al, -2 * k, 1 - al]
    if kind == 'pk': b = [1 + al * A, -2 * k, 1 - al * A]; a = [1 + al / A, -2 * k, 1 - al / A]
    if kind in ('ls', 'hs'):
        k2 = 2 * math.sqrt(A) * al; s = 1 if kind == 'ls' else -1
        b = [A * ((A + 1) - s * (A - 1) * k + k2), s * 2 * A * ((A - 1) - s * (A + 1) * k), A * ((A + 1) - s * (A - 1) * k - k2)]
        a = [(A + 1) + s * (A - 1) * k + k2, -s * 2 * ((A - 1) + s * (A + 1) * k), (A + 1) + s * (A - 1) * k - k2]
    def H(f):
        z = cmath.exp(-2j * math.pi * f / fs)
        return (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    return H
eq = [bq('hp', 150, .707), bq('ls', 250, .707, 3), bq('pk', 3500, 1, -2), bq('hs', 8000, .707, 2)]
lp = bq('lp', 90, .707)
lfe = 10 ** (-3 / 20); W = 0.992
m = [0, 0]
for i in range(601):
    f = 20 * 1000 ** (i / 600)
    E = abs(eq[0](f) * eq[1](f) * eq[2](f) * eq[3](f)); L = abs(lp(f)) ** 2
    v = [W * E, W * E * (1 + 3 * .707 + L * lfe)]
    m = [max(x, y) for x, y in zip(m, v)]
print(' '.join('%.1f' % (20 * math.log10(x)) for x in m))
PY
)
    [ "$(audio_dsp_gain_numbers | cut -d' ' -f1-2)" = "$want" ]
}

@test "write_settings keeps keys it is not given" {
    component_apply audio_dsp
    audio_dsp_write_settings lfe_cutoff_hz=90 stereo_hrtf=1
    audio_dsp_write_settings hardware_volume=0
    local c="$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    grep -qx 'lfe_cutoff_hz=90' "$c"
    grep -qx 'stereo_hrtf=1' "$c"
    grep -qx 'hardware_volume=0' "$c"
    grep -qx 'hrtf=set-a' "$c"
    grep -qx 'enabled=1' "$c"
    audio_dsp_render_wpsettings
    grep -q 'x20.stereo_hrtf = true' "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    grep -q 'x20.hardware_volume = false' "$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
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

@test "lock verification: a corrupted default set is rejected, headphone conf withheld" {
    printf 'tampered' >"$AX20_HRTF_SOURCE_DIR/set-a.sofa"
    component_apply audio_dsp
    local r="$AX20_ROOT$H"
    [ ! -e "$r/.config/ally-x20-steamos/hrtf/set-a.sofa" ]
    [ -f "$r/.config/ally-x20-steamos/hrtf/set-b.sofa" ]
    [ ! -e "$r/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf" ]
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
    [ ! -e "$r/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf" ]
    [ ! -e "$r/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf" ]
    [ ! -e "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf" ]
    [ ! -e "$r/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/x20-route-by-channels.lua" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/x20-select-default-sink.lua" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/lib/x20-sink-facts.lua" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/lib/x20-route-core.lua" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/x20-hardware-volume.lua" ]
    [ ! -e "$r/.local/share/wireplumber/scripts/lib/x20-volume-core.lua" ]
    [ -f "$r/.config/ally-x20-steamos/hrtf/set-a.sofa" ]
    grep -qx 'enabled=0' "$r/.config/ally-x20-steamos/audio-dsp.conf"
    [ -z "$(audio_dsp_files)" ]
    [ "$(component_status audio_dsp)" = stock ]
    component_apply audio_dsp
    [ ! -e "$r/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf" ]
    ! manifest_has "$H/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf"
}

# old_layout : record a file of the previous version (the two-sink
# 50-x20-virtual-surround.conf) and one in a directory only it used, the way
# an older apply would have; prints nothing.
OLD=/home/deck/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf
OLDDIR=/home/deck/.config/pipewire/x20-old.d
old_layout() {
    local src="$BATS_TEST_TMPDIR/old.conf"
    printf '# old two-sink conf: x20-virtual-surround-71, -51\n' >"$src"
    manifest_install_file "$src" "$OLD" audio_dsp 0644 home
    manifest_install_file "$src" "$OLDDIR/x20-old.conf" audio_dsp 0644 home
    [ -f "$AX20_ROOT$OLD" ] && manifest_has "$OLD" && manifest_has "$OLDDIR"
}

@test "upgrade: apply prunes files of an earlier version and the directories only they used" {
    component_apply audio_dsp
    old_layout
    component_apply audio_dsp
    [ ! -e "$AX20_ROOT$OLD" ]
    ! manifest_has "$OLD"
    [ ! -e "$AX20_ROOT$OLDDIR" ]
    ! manifest_has "$OLDDIR"
    ! manifest_has "$OLDDIR/x20-old.conf"
    # the new layout is complete, the shared directory stays
    [ -f "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf" ]
    manifest_has "$H/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf"
    [ -d "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d" ]
    [ "$(component_status audio_dsp)" = active ]
}

@test "upgrade: apply prunes 52-x20-speaker-surround.conf (speaker virtual surround removed)" {
    component_apply audio_dsp
    # what the previous version rendered and recorded, with its settings
    local src="$BATS_TEST_TMPDIR/surround.conf" sur="$H/.config/pipewire/pipewire.conf.d/52-x20-speaker-surround.conf"
    printf '# old x20-speakers-surround filter-chain (HRTF + crosstalk cancellation)\n' >"$src"
    manifest_install_file "$src" "$sur" audio_dsp 0644 home
    printf '%s\n' stereo_surround=1 xtc_delay_us=117 xtc_attenuation_db=4 xtc_taps=4 master_gain_db=auto \
        >>"$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    [ -f "$AX20_ROOT$sur" ] && manifest_has "$sur"
    run component_apply audio_dsp
    assert_success
    assert_output_contains "removing $sur (no longer installed by this version)"
    [ ! -e "$AX20_ROOT$sur" ]
    ! manifest_has "$sur" || false
    ! grep -Eq '^(stereo_surround|xtc_[a-z_]*|master_gain_db)=' "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf" || false
    [ "$(prio 51-x20-speaker-chain.conf)" = "750 750" ]
    [ "$(component_status audio_dsp)" = active ]
}

@test "upgrade: a modified old file is kept, reported and stays in the manifest" {
    component_apply audio_dsp
    old_layout
    printf '# my edit\n' >>"$AX20_ROOT$OLD"
    run component_apply audio_dsp
    assert_success
    assert_output_contains "50-x20-virtual-surround.conf was modified after install"
    [ -f "$AX20_ROOT$OLD" ]
    manifest_has "$OLD"
}

@test "upgrade: prune keeps HRTF sets, current.sofa, settings and other components' files" {
    component_apply audio_dsp
    local src="$BATS_TEST_TMPDIR/other.conf" other=/etc/modprobe.d/x20-other.conf
    printf 'x\n' >"$src"
    manifest_install_file "$src" "$other" audio 0644 shared
    # the headphone conf withheld this time (HRTF missing) is still ours
    rm -rf "$AX20_HRTF_SOURCE_DIR" "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/set-a.sofa"
    manifest_forget "$H/.config/ally-x20-steamos/hrtf/set-a.sofa"
    component_apply audio_dsp
    [ -f "$AX20_ROOT$other" ]
    [ -f "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf" ]
    [ -f "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/set-b.sofa" ]
    [ -L "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/current.sofa" ]
    [ -f "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf" ]
}

@test "upgrade: off removes old-layout files too, keeps HRTF data and settings" {
    component_apply audio_dsp
    old_layout
    audio_dsp_disable
    [ ! -e "$AX20_ROOT$OLD" ]
    ! manifest_has "$OLD"
    [ ! -e "$AX20_ROOT$OLDDIR" ]
    [ ! -e "$AX20_ROOT$H/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf" ]
    [ ! -e "$AX20_ROOT$H/.local/share/wireplumber/scripts/x20-hardware-volume.lua" ]
    [ -z "$(find "$AX20_ROOT$H/.config/pipewire" "$AX20_ROOT$H/.config/wireplumber" "$AX20_ROOT$H/.local" -type f 2>/dev/null)" ]
    [ -f "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/set-a.sofa" ]
    [ -L "$AX20_ROOT$H/.config/ally-x20-steamos/hrtf/current.sofa" ]
    grep -qx 'enabled=0' "$AX20_ROOT$H/.config/ally-x20-steamos/audio-dsp.conf"
    # and on again brings the new layout back
    audio_dsp_write_settings enabled=1
    component_apply audio_dsp
    [ "$(component_status audio_dsp)" = active ]
    [ ! -e "$AX20_ROOT$OLD" ]
}

@test "upgrade: uninstall removes the new and the old layout" {
    component_apply audio_dsp
    old_layout
    run sh "$REPO_ROOT/uninstall/uninstall.sh" --root "$AX20_ROOT" --yes --quiet --component audio_dsp
    assert_success
    [ ! -e "$AX20_ROOT$OLD" ]
    [ -z "$(find "$AX20_ROOT/home" -type f -o -type l)" ]
    [ -z "$(manifest_paths audio_dsp)" ]
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

@test "headphone conf: one 7.1 sink x20-headphones, 7.1 azimuths, no 5.1 sink" {
    local f="$REPO_ROOT/overlay/home/pipewire/pipewire.conf.d/50-x20-headphones.conf"
    [ "$(grep -c 'name = libpipewire-module-filter-chain' "$f")" = 1 ]
    grep -q 'node.name        = "x20-headphones"' "$f"
    grep -q 'node.name        = "x20-headphones.output"' "$f"
    ! grep -q 'node.name *= "x20-virtual-surround' "$f"
    grep -q 'audio.position   = \[ FL FR FC LFE RL RR SL SR \]' "$f"
    ! grep -q 'audio.position   = \[ FL FR FC LFE RL RR \]' "$f"
    # 7.1 rears at 150/210, sides at 90/270; no 5.1 angles
    for a in 30.0 330.0 0.0 90.0 270.0 150.0 210.0; do
        grep -q "\"Azimuth\"   = $a\$" "$f"
    done
    ! grep -q '"Azimuth"   = 110.0$' "$f"
    [ ! -e "$REPO_ROOT/overlay/home/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf" ]
}

@test "headphone sink is labelled X20 Headphones" {
    local f="$REPO_ROOT/overlay/home/pipewire/pipewire.conf.d/50-x20-headphones.conf"
    [ "$(grep -c 'node.description = "X20 Headphones (virtual surround)"' "$f")" = 2 ]
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

@test "lua: hardware volume rule (fixtures in tests/fixtures/audio_dsp/volume-cases.txt)" {
    local lua
    lua=$(lua_bin) || skip "no Lua interpreter (lua, lua5.4, lua5.3, luajit) installed; volume rule tests not run"
    run "$lua" "$REPO_ROOT/tests/lua/test_x20_volume_core.lua" "$REPO_ROOT"
    assert_success
    assert_output_contains " 0 failures"
}

@test "WirePlumber settings: hardware_volume rendered, default on, invalid falls back to on" {
    component_apply audio_dsp
    local w="$AX20_ROOT$H/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf"
    grep -q 'x20.hardware_volume = true' "$w"
    audio_dsp_write_settings hardware_volume=0
    audio_dsp_render_wpsettings
    grep -q 'x20.hardware_volume = false' "$w"
    audio_dsp_write_settings hardware_volume=maybe
    [ "$(audio_dsp_setting_value hardware_volume)" = 1 ]
}

@test "lua: hook glue and core parse" {
    local lua f
    lua=$(lua_bin) || skip "no Lua interpreter (lua, lua5.4, lua5.3, luajit) installed; syntax check not run"
    for f in "$REPO_ROOT"/overlay/home/wireplumber/scripts/*.lua \
        "$REPO_ROOT"/overlay/home/wireplumber/scripts/lib/*.lua; do
        run "$lua" -e "assert(loadfile('$f'))"
        assert_success
    done
}

@test "every x20 sink is a plain Audio/Sink (WirePlumber 0.5 cannot link streams into Audio/Sink/Internal)" {
    component_apply audio_dsp
    for f in "$AX20_ROOT$H"/.config/pipewire/pipewire.conf.d/5*-x20-*.conf; do
        ! grep -E '^\s*media.class' "$f" | grep -q 'Audio/Sink/Internal' || { echo "internal sink in $f"; false; }
    done
    [ "$(grep -h 'media.class' "$AX20_ROOT$H"/.config/pipewire/pipewire.conf.d/5*-x20-*.conf | grep -cE 'Audio/Sink\s*$')" -ge 2 ]
}
