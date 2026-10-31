# SPDX-License-Identifier: GPL-2.0-only
# summary: headphone/speaker virtual surround + speaker chain: on|off|status|hrtf|stereo-hrtf|speaker-surround|stereo-surround|xtc|lfe|master-gain|test
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
  speaker-surround on|off
                        surround streams on the built-in speakers: virtual
                        surround with crosstalk cancellation (on, default) or
                        plain stereo downmix (off). Moves playing streams live
  stereo-surround on|off
                        also send stereo through the speaker virtual surround
                        (default off)
  xtc                   show the crosstalk cancellation parameters
  xtc set <delay_us> <atten_db> [taps]
                        tune it: delay per tap 10..1000 us, attenuation per tap
                        0.5..30 dB, taps 1..4 (restarts PipeWire)
  xtc reset             back to the X20 defaults (117 us, 4 dB, 4 taps)
  lfe                   show the LFE low-pass and level
  lfe set <cutoff_hz> <gain_db>
                        LFE low-pass 40..250 Hz and level -40..6 dB in every
                        chain (default 120 Hz, -6 dB; restarts PipeWire)
  master-gain           show the worst-case gain analysis and output gains
  master-gain [speakers] auto|strict|<dB>
                        output gain of x20-speakers-surround (or, with
                        "speakers", of x20-speakers): auto (default), strict
                        (no digital clipping even in the worst case) or a
                        number -60..12 (restarts PipeWire)
  test                  play 7.1 and stereo test tones and show which sink each
                        used, then the 7.1 channel sequence through the speaker
                        virtual surround

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
            _audio_dsp_cmd_toggle stereo-hrtf stereo_hrtf "$@"
            ;;
        speaker-surround)
            shift
            _audio_dsp_cmd_toggle speaker-surround speaker_surround "$@"
            ;;
        stereo-surround)
            shift
            _audio_dsp_cmd_toggle stereo-surround stereo_surround "$@"
            ;;
        xtc)
            shift
            _audio_dsp_cmd_xtc "$@"
            ;;
        lfe)
            shift
            _audio_dsp_cmd_lfe "$@"
            ;;
        master-gain)
            shift
            _audio_dsp_cmd_master_gain "$@"
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
    audio_dsp_write_settings enabled=1
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
    printf 'stereo_hrtf:     %s\n' "$(audio_dsp_setting_value stereo_hrtf)"
    printf 'speaker_surround: %s\n' "$(audio_dsp_setting_value speaker_surround)"
    printf 'stereo_surround: %s\n' "$(audio_dsp_setting_value stereo_surround)"
    printf 'xtc:             %s\n' "$(audio_dsp_xtc_describe)"
    printf 'x20-speakers:    %s\n' "$(AX20_GAIN_CHAIN=speakers audio_dsp_gain_describe)"
    printf 'speaker surround: %s\n' "$(audio_dsp_gain_describe)"
    printf 'sofa support:    %s (plugin %s, libmysofa %s)\n' "$sofa" "$plugin" "$lib"
    printf 'speaker chain:   %s\n' "$([ "$lsp" = yes ] && echo 'builtin + LSP limiter' || echo builtin)"
    if [ -z "$AX20_ROOT" ] && ax20_have pw-dump && ax20_have jq; then
        printf 'live sinks:      %s\n' "$(_audio_dsp_as_user pw-dump 2>/dev/null \
            | jq -r '[.[] | select(.info.props["node.name"]? // "" | startswith("x20-")) | select(.info.props["media.class"]? // "" | startswith("Audio/Sink")) | .info.props["node.name"]] | join(" ")' 2>/dev/null)"
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
    audio_dsp_write_settings "hrtf=$name"
    if audio_dsp_enabled; then
        # The confs may be missing if the previous set never downloaded.
        [ -f "$(ax20_path "$(audio_dsp_surround_rel)")" ] || audio_dsp_render_surround
        [ -f "$(ax20_path "$(audio_dsp_speaker_surround_rel)")" ] || audio_dsp_render_speaker_surround
        _audio_dsp_fix_owner
        audio_dsp_restart_services pipewire.service
    fi
    log_info "HRTF set: $name"
}

# _audio_dsp_cmd_toggle <command> <key> on|off : one of the routing
# switches (stereo_hrtf, speaker_surround, stereo_surround). They are
# WirePlumber settings: persisted in audio-dsp.conf and 51-x20-settings.conf,
# and applied to the running session with `wpctl settings`, so playing
# streams move at once (the router rescans on a settings change).
_audio_dsp_cmd_toggle() {
    local cmd=$1 key=$2 v
    case "${3:-}" in
        on) v=1 ;;
        off) v=0 ;;
        *)
            log_error "usage: $AX20_NAME audio-dsp $cmd on|off"
            return 2
            ;;
    esac
    require_root audio-dsp "$cmd" "$3"
    ax20_check_readonly_root
    audio_dsp_write_settings "$key=$v"
    if audio_dsp_enabled; then
        audio_dsp_render_wpsettings
        _audio_dsp_fix_owner
        _audio_dsp_live_setting "x20.$key" "$(_audio_dsp_bool "$v")"
    fi
    log_info "$cmd: $3"
}

# _audio_dsp_live_setting <key> <true|false> : set a WirePlumber setting in
# the running session; restart WirePlumber when that is not possible.
_audio_dsp_live_setting() {
    if [ -n "$AX20_ROOT" ] || [ "${AX20_NO_RESTART:-0}" = 1 ]; then
        log_debug "audio_dsp: not touching the live session (fixture root or AX20_NO_RESTART)"
        return 0
    fi
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] wpctl settings %s %s\n' "$1" "$2" >&2
        return 0
    fi
    if ax20_have wpctl && _audio_dsp_as_user wpctl settings "$1" "$2" >/dev/null 2>&1; then
        log_info "applied to the running session ($1 = $2)"
        return 0
    fi
    audio_dsp_restart_services wireplumber.service
}

# _audio_dsp_cmd_xtc [show | set <delay_us> <atten_db> [taps] | reset]
_audio_dsp_cmd_xtc() {
    local d a t
    case "${1:-show}" in
        show)
            printf '%s\n' "$(audio_dsp_xtc_describe)"
            return 0
            ;;
        reset)
            d=$AUDIO_DSP_XTC_DELAY_US_DEFAULT
            a=$AUDIO_DSP_XTC_ATTEN_DB_DEFAULT
            t=$AUDIO_DSP_XTC_TAPS_DEFAULT
            ;;
        set)
            d=${2:-}
            a=${3:-}
            t=${4:-$(audio_dsp_setting_value xtc_taps)}
            if ! audio_dsp_xtc_valid_delay "$d" || ! audio_dsp_xtc_valid_atten "$a" \
                || ! audio_dsp_xtc_valid_taps "$t"; then
                log_error "usage: $AX20_NAME audio-dsp xtc set <delay_us 10..1000> <atten_db 0.5..30> [taps 1..4]"
                return 2
            fi
            ;;
        *)
            log_error "usage: $AX20_NAME audio-dsp xtc [show | set <delay_us> <atten_db> [taps] | reset]"
            return 2
            ;;
    esac
    require_root audio-dsp xtc "$@"
    ax20_check_readonly_root
    audio_dsp_write_settings "xtc_delay_us=$d" "xtc_attenuation_db=$a" "xtc_taps=$t"
    _audio_dsp_rerender
    log_info "$(audio_dsp_xtc_describe)"
}

# _audio_dsp_rerender : render every chain from the settings and restart
# PipeWire (only while enabled; otherwise the settings are just recorded).
_audio_dsp_rerender() {
    audio_dsp_enabled || return 0
    audio_dsp_render_speaker_chain
    if audio_dsp_hrtf_installed "$(audio_dsp_hrtf_current)"; then
        audio_dsp_render_surround
        audio_dsp_render_speaker_surround
    fi
    _audio_dsp_fix_owner
    audio_dsp_restart_services pipewire.service
}

# _audio_dsp_cmd_lfe [show | set <cutoff_hz> <gain_db>]
_audio_dsp_cmd_lfe() {
    case "${1:-show}" in
        show)
            printf 'lfe_cutoff_hz=%s lfe_gain_db=%s\n' \
                "$(audio_dsp_setting_value lfe_cutoff_hz)" "$(audio_dsp_setting_value lfe_gain_db)"
            return 0
            ;;
        set)
            if ! audio_dsp_valid_lfe_cutoff "${2:-}" || ! audio_dsp_valid_lfe_gain "${3:-}"; then
                log_error "usage: $AX20_NAME audio-dsp lfe set <cutoff_hz 40..250> <gain_db -40..6>"
                return 2
            fi
            ;;
        *)
            log_error "usage: $AX20_NAME audio-dsp lfe [show | set <cutoff_hz> <gain_db>]"
            return 2
            ;;
    esac
    require_root audio-dsp lfe "$@"
    ax20_check_readonly_root
    audio_dsp_write_settings "lfe_cutoff_hz=$2" "lfe_gain_db=$3"
    _audio_dsp_rerender
    log_info "lfe_cutoff_hz=$2 lfe_gain_db=$3"
}

# _audio_dsp_cmd_master_gain [show | [speakers] auto|strict|<dB>]
_audio_dsp_cmd_master_gain() {
    local key=master_gain_db v
    case "${1:-show}" in
        show)
            printf 'x20-speakers:          %s\n' "$(AX20_GAIN_CHAIN=speakers audio_dsp_gain_describe)"
            printf 'x20-speakers-surround: %s\n' "$(audio_dsp_gain_describe)"
            return 0
            ;;
        speakers)
            key=speakers_master_gain_db
            v=${2:-}
            ;;
        *) v=$1 ;;
    esac
    if ! audio_dsp_valid_master "$v"; then
        log_error "usage: $AX20_NAME audio-dsp master-gain [speakers] auto|strict|<dB -60..12>"
        return 2
    fi
    require_root audio-dsp master-gain "$@"
    ax20_check_readonly_root
    audio_dsp_write_settings "$key=$v"
    _audio_dsp_rerender
    log_info "$key=$v"
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

# _audio_dsp_links : "stream -> sink" for our test streams and filter
# outputs, from pw-dump (works for the hidden Audio/Sink/Internal sink too).
_audio_dsp_links() {
    _audio_dsp_as_user pw-dump 2>/dev/null | jq -r '
        (map(select(.type == "PipeWire:Interface:Node")) | map({key: (.id | tostring), value: .info.props}) | from_entries) as $n
        | .[] | select(.type == "PipeWire:Interface:Link")
        | ($n[(.info["output-node-id"] | tostring)] // {}) as $o
        | ($n[(.info["input-node-id"] | tostring)] // {}) as $i
        | select((($o["media.name"] // "") | test("x20-test-"))
            or (($o["node.name"] // "") | test("^x20-.*\\.output$")))
        | "   \(if (($o["media.name"] // "") | test("x20-test-")) then $o["media.name"] else $o["node.name"] end) -> \($i["node.name"])"' \
        | sort -u
}

# _audio_dsp_cmd_test : channel-identification sequences generated with
# python3 at runtime (no audio files in git):
#   1. routing check: a 2 s 7.1 file (each channel a quarter second of its
#      own tone, FL first) and a 2 s stereo file, played together without a
#      target so the router picks the sinks; prints stream -> sink.
#   2. speaker surround: a 7.1 sequence with 0.7 s per channel played
#      straight into x20-speakers-surround (FL FR FC LFE RL RR SL SR), so the
#      virtual speaker positions can be judged by ear on the built-in
#      speakers whatever the routing settings are.
# TODO(vm): run in the SteamOS VM with and without a headphone route.
_audio_dsp_cmd_test() {
    local tmp t t71 t20 tid pid71 pid20 pidid
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
    tid="$tmp/x20-test-7.1-speaker-surround.wav"
    python3 - "$t71" "$t20" "$tid" <<'PY'
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
# FL FR FC LFE RL RR SL SR, in that order
freqs = [440, 494, 523, 60, 587, 659, 698, 784]
def seq(step, gap):
    # channel c sounds for (step - gap) seconds, then the next one
    return lambda c, t: freqs[c] if int(t / step) == c and t % step < step - gap else None
write(sys.argv[1], 8, 2.0, seq(0.25, 0.0))
write(sys.argv[2], 2, 2.0, lambda c, t: 440 if c == 0 else 660)
write(sys.argv[3], 8, 5.6, seq(0.7, 0.15))
PY
    chmod 644 "$t71" "$t20" "$tid"

    printf '1. routing (no target, the router decides):\n'
    _audio_dsp_as_user pw-play --channels 8 --channel-map FL,FR,FC,LFE,RL,RR,SL,SR \
        --media-role Game "$t71" &
    pid71=$!
    _audio_dsp_as_user pw-play --media-role Game "$t20" &
    pid20=$!
    sleep 1
    _audio_dsp_links
    wait "$pid71" "$pid20" 2>/dev/null || true
    printf '   expected with headphones: 7.1 -> x20-virtual-surround-71, 2.0 -> hardware sink\n'
    printf '   expected on speakers:     7.1 -> x20-speakers-surround (speaker_surround=1, now %s)\n' \
        "$(audio_dsp_setting_value speaker_surround)"
    printf '                             2.0 -> x20-speakers (x20-speakers-surround if stereo_surround=1, now %s)\n' \
        "$(audio_dsp_setting_value stereo_surround)"

    printf '2. speaker virtual surround, channel by channel (listen on the built-in speakers):\n'
    printf '   FL FR FC LFE RL RR SL SR, 0.7 s each\n'
    if ! _audio_dsp_as_user pw-dump 2>/dev/null \
        | jq -e 'any(.[]; .info.props["node.name"]? == "x20-speakers-surround")' >/dev/null 2>&1; then
        printf '   x20-speakers-surround is not loaded (audio-dsp off, HRTF missing or no sofa plugin); skipped\n'
        rm -rf "$tmp"
        return 0
    fi
    _audio_dsp_as_user pw-play --target x20-speakers-surround --channels 8 \
        --channel-map FL,FR,FC,LFE,RL,RR,SL,SR --media-role Game "$tid" &
    pidid=$!
    sleep 1
    _audio_dsp_links
    wait "$pidid" 2>/dev/null || true
    rm -rf "$tmp"
    printf '   expected: x20-test-7.1-speaker-surround -> x20-speakers-surround,\n'
    printf '             x20-speakers-surround.output -> x20-speakers, x20-speakers.output -> hardware sink\n'
}
