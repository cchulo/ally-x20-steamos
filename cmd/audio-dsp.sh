# SPDX-License-Identifier: GPL-2.0-only
# summary: headphone virtual surround + speaker chain: on|off|status|hrtf|stereo-hrtf|test
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

_audio_dsp_usage() {
    cat <<USAGE
usage: $AX20_NAME audio-dsp <command>

  on                    enable (installs config, fetches HRTF sets, restarts PipeWire)
  off                   disable: remove the config so audio is stock; HRTF data is kept
  status                show settings, installed files and PipeWire support
  hrtf list             list HRTF sets (* = current)
  hrtf <name>           switch the HRTF set (relinks current.sofa, restarts PipeWire)
  stereo-hrtf on|off    also send stereo through the HRTF on headphones (default off)
  test                  play 7.1 and stereo test tones and show which sink each used

The user whose session is configured is \$SUDO_USER (or deck); override with
AX20_AUDIO_USER / AX20_HOME. See docs/audio-dsp.md.
USAGE
}

cmd_audio_dsp() {
    component_load audio_dsp
    case "${1:-}" in
        on)
            require_root audio-dsp on
            ax20_check_readonly_root
            _audio_dsp_cmd_on
            ;;
        off)
            require_root audio-dsp off
            ax20_check_readonly_root
            audio_dsp_disable
            log_info "audio-dsp is off (stock PipeWire behaviour); 'audio-dsp on' restores it"
            ;;
        status) _audio_dsp_cmd_status ;;
        hrtf)
            shift
            _audio_dsp_cmd_hrtf "$@"
            ;;
        stereo-hrtf)
            shift
            _audio_dsp_cmd_stereo_hrtf "$@"
            ;;
        test) _audio_dsp_cmd_test ;;
        -h | --help | help) _audio_dsp_usage ;;
        '')
            _audio_dsp_usage >&2
            return 2
            ;;
        *)
            log_error "unknown audio-dsp command: $1"
            _audio_dsp_usage >&2
            return 2
            ;;
    esac
}

_audio_dsp_cmd_on() {
    audio_dsp_write_settings 1 "$(audio_dsp_hrtf_current)" "$(audio_dsp_setting stereo_hrtf 0)"
    component_apply audio_dsp
    log_info "audio-dsp is on (status: $(audio_dsp_status))"
}

_audio_dsp_cmd_status() {
    local rc name lsp="no" sofa plugin lib
    rc=0
    audio_dsp_probe_sofa_plugin >/dev/null 2>&1 || rc=$?
    plugin=$(probe_result_word "$rc" | sed 's/superseded/present/;s/needed/missing/')
    rc=0
    audio_dsp_probe_libmysofa >/dev/null 2>&1 || rc=$?
    lib=$(probe_result_word "$rc" | sed 's/superseded/present/;s/needed/missing/')
    rc=0
    audio_dsp_probe_sofa_support >/dev/null 2>&1 || rc=$?
    sofa=$(probe_result_word "$rc" | sed 's/superseded/yes/;s/needed/no/')
    audio_dsp_have_lsp && lsp="yes"
    name=$(audio_dsp_hrtf_current)
    printf 'status:          %s\n' "$(audio_dsp_status)"
    printf 'user/home:       %s %s\n' "$(audio_dsp_user)" "$(audio_dsp_home)"
    printf 'enabled:         %s\n' "$(audio_dsp_setting enabled 1)"
    printf 'hrtf:            %s (%s)\n' "$name" "$(audio_dsp_hrtf_installed "$name" && echo installed || echo missing)"
    printf 'stereo_hrtf:     %s\n' "$(audio_dsp_setting stereo_hrtf 0)"
    printf 'sofa support:    %s (plugin %s, libmysofa %s)\n' "$sofa" "$plugin" "$lib"
    printf 'speaker chain:   %s\n' "$([ "$lsp" = yes ] && echo 'builtin + LSP limiter' || echo builtin)"
    if [ -z "$AX20_ROOT" ] && ax20_have pw-dump && ax20_have jq; then
        printf 'live sinks:      %s\n' "$(_audio_dsp_as_user pw-dump 2>/dev/null \
            | jq -r '[.[] | select(.info.props["node.name"]? // "" | startswith("x20-")) | select(.info.props["media.class"]? == "Audio/Sink") | .info.props["node.name"]] | join(" ")' 2>/dev/null)"
    fi
}

_audio_dsp_cmd_hrtf() {
    local name cur n mark
    case "${1:-list}" in
        list)
            cur=$(audio_dsp_hrtf_current)
            for n in $(audio_dsp_hrtf_names); do
                mark=" "
                [ "$n" = "$cur" ] && mark="*"
                printf '%s %-12s %-22s %s\n' "$mark" "$n" "$(audio_dsp_hrtf_license "$n")" \
                    "$(audio_dsp_hrtf_installed "$n" && echo installed || echo not-downloaded)"
            done
            return 0
            ;;
    esac
    name=$1
    if ! audio_dsp_hrtf_known "$name"; then
        log_error "unknown HRTF set '$name' (see: $AX20_NAME audio-dsp hrtf list)"
        return 2
    fi
    require_root audio-dsp hrtf "$name"
    ax20_check_readonly_root
    audio_dsp_fetch_hrtf "$name" || {
        log_error "HRTF set '$name' could not be installed"
        return 1
    }
    audio_dsp_link_hrtf "$name"
    audio_dsp_write_settings "$(audio_dsp_setting enabled 1)" "$name" "$(audio_dsp_setting stereo_hrtf 0)"
    if audio_dsp_enabled; then
        # The conf may be missing if the previous set never downloaded.
        [ -f "$(ax20_path "$(audio_dsp_surround_rel)")" ] || audio_dsp_render_surround
        _audio_dsp_fix_owner
        audio_dsp_restart_services pipewire.service
    fi
    log_info "HRTF set: $name"
}

_audio_dsp_cmd_stereo_hrtf() {
    local v
    case "${1:-}" in
        on) v=1 ;;
        off) v=0 ;;
        *)
            log_error "usage: $AX20_NAME audio-dsp stereo-hrtf on|off"
            return 2
            ;;
    esac
    require_root audio-dsp stereo-hrtf "$1"
    ax20_check_readonly_root
    audio_dsp_write_settings "$(audio_dsp_setting enabled 1)" "$(audio_dsp_hrtf_current)" "$v"
    if audio_dsp_enabled; then
        audio_dsp_render_wpsettings "$v"
        _audio_dsp_fix_owner
        audio_dsp_restart_services wireplumber.service
    fi
    log_info "stereo through HRTF: $1"
}

# _audio_dsp_as_user <cmd...> : run in the target user's audio session.
_audio_dsp_as_user() {
    local user uid
    user=$(audio_dsp_user)
    if ax20_is_root && [ "$user" != root ] && ax20_have runuser; then
        uid=$(id -u "$user")
        runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"
    else
        "$@"
    fi
}

# _audio_dsp_cmd_test : generate a 2 s channel-identification sequence (each
# channel of a 7.1 file gets a quarter second of its own tone, FL first) and
# a 2 s stereo file with python3 at runtime (no audio files in git), play
# both and report the sink each stream was linked to (from pw-dump).
# TODO(vm): run in the SteamOS VM with and without a headphone route.
_audio_dsp_cmd_test() {
    local tmp t t71 t20 pid71 pid20
    if [ -n "$AX20_ROOT" ]; then
        log_error "audio-dsp test needs the live system (not --root)"
        return 1
    fi
    for t in pw-play pw-dump jq python3; do
        ax20_have "$t" || {
            log_error "audio-dsp test needs $t"
            return 1
        }
    done
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] generate test tones, pw-play them, report targets via pw-dump\n' >&2
        return 0
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ax20-audio-test.XXXXXX")
    chmod 755 "$tmp"
    t71="$tmp/x20-test-7.1.wav"
    t20="$tmp/x20-test-2.0.wav"
    python3 - "$t71" "$t20" <<'PY'
import math, struct, sys, wave
RATE = 48000
def write(path, channels, seconds, tone_for):
    n = int(RATE * seconds)
    frames = bytearray()
    for i in range(n):
        t = i / RATE
        for c in range(channels):
            f = tone_for(c, t)
            v = 0.0 if f is None else 0.3 * math.sin(2 * math.pi * f * t)
            frames += struct.pack('<h', int(v * 32767))
    w = wave.open(path, 'wb')
    w.setnchannels(channels)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(bytes(frames))
    w.close()
# FL FR FC LFE RL RR SL SR, 0.25 s each, in that order
freqs = [440, 494, 523, 60, 587, 659, 698, 784]
write(sys.argv[1], 8, 2.0, lambda c, t: freqs[c] if int(t / 0.25) == c else None)
write(sys.argv[2], 2, 2.0, lambda c, t: 440 if c == 0 else 660)
PY
    chmod 644 "$t71" "$t20"
    _audio_dsp_as_user pw-play --channels 8 --channel-map FL,FR,FC,LFE,RL,RR,SL,SR \
        --media-role Game "$t71" &
    pid71=$!
    _audio_dsp_as_user pw-play --media-role Game "$t20" &
    pid20=$!
    sleep 1
    _audio_dsp_as_user pw-dump 2>/dev/null | jq -r '
        (map(select(.type == "PipeWire:Interface:Node")) | map({key: (.id | tostring), value: .info.props}) | from_entries) as $n
        | .[] | select(.type == "PipeWire:Interface:Link")
        | select(($n[(.info["output-node-id"] | tostring)]["media.name"] // "") | test("x20-test-"))
        | "\($n[(.info["output-node-id"] | tostring)]["media.name"]) -> \($n[(.info["input-node-id"] | tostring)]["node.name"])"' \
        | sort -u
    wait "$pid71" "$pid20" 2>/dev/null || true
    rm -rf "$tmp"
    printf 'expected with headphones: 7.1 -> x20-virtual-surround-71, 2.0 -> hardware sink\n'
    printf 'expected on speakers:     both -> x20-speakers\n'
}
