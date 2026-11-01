# SPDX-License-Identifier: GPL-2.0-only
# components/audio_dsp.sh — headphone virtual surround + speaker chain
# (X20-STEAMOS-PLAN.md section 1.5). Required component, on by default.
#
# Streams follow the default sink. With Steam's output on "Default", the
# x20-select-default-sink hook makes it x20-speakers on the built-in
# speakers and x20-headphones on any headphones; a sink picked by hand in
# Steam always wins.
# x20-speakers.output is pinned to the hardware speaker sink in its conf; the
# route-by-channels hook links the headphone surround output to an available
# headphone sink (docs/audio-dsp.md, "Automatic output selection"). While
# one of our sinks is the default, the x20-hardware-volume hook holds every
# sink under it (down to the hardware) at 100 % (docs/audio-dsp.md,
# "Volumes").
#
# Everything lives in the user's home (manifest slot "home"), so it survives
# SteamOS updates untouched and never needs the read-only root:
#   ~/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf        (rendered)
#   ~/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf      (rendered)
#   ~/.config/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf
#   ~/.config/pipewire/client.conf.d/50-x20-no-upmix.conf
#   ~/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf
#   ~/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf      (rendered)
#   ~/.local/share/wireplumber/scripts/x20-route-by-channels.lua
#   ~/.local/share/wireplumber/scripts/x20-select-default-sink.lua
#   ~/.local/share/wireplumber/scripts/x20-hardware-volume.lua
#   ~/.local/share/wireplumber/scripts/lib/x20-route-core.lua
#   ~/.local/share/wireplumber/scripts/lib/x20-sink-facts.lua
#   ~/.local/share/wireplumber/scripts/lib/x20-volume-core.lua
#   ~/.config/ally-x20-steamos/hrtf/<set>.sofa + current.sofa -> <set>.sofa
#   ~/.config/ally-x20-steamos/audio-dsp.conf                          (settings)
#
# WirePlumber 0.5 (SteamOS 3.9 ships 0.5.18) loads scripts from
# $XDG_DATA_HOME/wireplumber/scripts, hence ~/.local/share for the Lua files;
# 0.4 used ~/.config/wireplumber/{main.lua.d,scripts} and is not supported
# (see docs/audio-dsp.md).
#
# Settings file (key=value), the single source of truth for the user's choice:
#   enabled=1|0       0 = `audio-dsp off`: config files removed, HRTF data kept
#   hrtf=<set>        set name from overlay/home/hrtf/hrtf.lock
#   stereo_hrtf=0|1   kept for compatibility; no effect since streams follow
#                     the default sink (pick X20 Headphones in Steam)
#   speakers_precedence=1|0  1 (default): the automatic default on the
#                     speakers is x20-speakers (hook), and it gets priority
#                     750, above the hardware Speaker sink (712); 0: neither
#                     (priority 50, manual pick only)
#   headphones_virtual_surround=1|0  1 (default): the automatic default on
#                     headphones is x20-headphones
#   hardware_volume=1|0  1 (default): while one of our sinks is the default,
#                     the sinks under it are held at 100 % (hook)
#   lfe_cutoff_hz=<int>   LFE low-pass in every chain (40..250, default 120)
#   lfe_gain_db=<num>     LFE level folded into the outputs (-40..6, default -6)
#   speakers_master_gain_db=auto|strict|<dB>
#                         output gain of x20-speakers (default auto = 0 dB)
# Keys of earlier versions (speaker_surround, stereo_surround, xtc_*,
# master_gain_db: the speaker virtual surround, removed 2026-10, see
# docs/xtc-notes.md) are ignored and dropped on the next rewrite.
# When enabled=0, audio_dsp_files lists nothing and audio_dsp_apply only
# keeps the settings file, so the boot-time re-apply never undoes `off`.
#
# Environment knobs (tests, offline installs):
#   AX20_HOME             target home directory (default: the deck user's)
#   AX20_AUDIO_USER       target user (default: $SUDO_USER, else deck)
#   AX20_SKIP_DOWNLOADS=1 never download; use AX20_HRTF_SOURCE_DIR if set
#   AX20_HRTF_SOURCE_DIR  directory holding <set>.sofa files to copy
#   AX20_HRTF_LOCK        alternative lock file
#   AX20_NO_RESTART=1     never restart the user's PipeWire/WirePlumber

# AX20_* globals come from lib/common.sh; COMPONENT_DESCRIPTION is read by
# lib/component.sh.
# shellcheck disable=SC2034,SC2153
COMPONENT_DESCRIPTION="headphone virtual surround (HRTF) + speaker chain, per-user PipeWire/WirePlumber config"

AUDIO_DSP_COMPONENT=audio_dsp

# Settings keys, in the order they are written to audio-dsp.conf.
AUDIO_DSP_KEYS="enabled hrtf stereo_hrtf speakers_precedence headphones_virtual_surround hardware_volume lfe_cutoff_hz lfe_gain_db speakers_master_gain_db"

# priority.session of x20-speakers. Measured on the X20 (SteamOS
# 3.9.5): hardware Speaker sink 712, headphone jack sink 1000; USB and
# Bluetooth headsets get >= 1000. WirePlumber makes the available sink with
# the highest priority the default unless the user picked one, so 750 puts
# our chain above the bare speakers and below every headphone output: auto
# mode plays through the DSP, switches to headphones while they are
# available (jack plugged, headset connected) and comes back afterwards.
AUDIO_DSP_PRIO_SPEAKERS=750
AUDIO_DSP_PRIO_MANUAL=50

# LFE: real LFE is band-limited to 120 Hz by spec (Dolby, ITU-R BS.775); the
# chains low-pass it there and fold it into the outputs at -6 dB.
AUDIO_DSP_LFE_CUTOFF_DEFAULT=120
AUDIO_DSP_LFE_GAIN_DB_DEFAULT=-6

# ------------------------------------------------------------ user / paths --

# audio_dsp_user : the account whose PipeWire session we configure.
audio_dsp_user() {
    if [ -n "${AX20_AUDIO_USER:-}" ]; then
        printf '%s\n' "$AX20_AUDIO_USER"
    elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        printf '%s\n' "$SUDO_USER"
    elif [ -z "$AX20_ROOT" ] && ! ax20_is_root; then
        id -un
    else
        printf 'deck\n'
    fi
}

# audio_dsp_home : that user's home, WITHOUT the AX20_ROOT prefix.
audio_dsp_home() {
    local user h=""
    if [ -n "${AX20_HOME:-}" ]; then
        printf '%s\n' "${AX20_HOME%/}"
        return 0
    fi
    user=$(audio_dsp_user)
    if [ -z "$AX20_ROOT" ]; then
        if ax20_have getent; then
            h=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        fi
        if [ -z "$h" ] && [ "$user" = "$(id -un)" ]; then
            h=${HOME:-}
        fi
    fi
    [ -n "$h" ] || h="/home/$user"
    printf '%s\n' "$h"
}

audio_dsp_state_rel() { printf '%s/.config/%s\n' "$(audio_dsp_home)" "$AX20_NAME"; }
audio_dsp_settings_rel() { printf '%s/audio-dsp.conf\n' "$(audio_dsp_state_rel)"; }
audio_dsp_hrtf_rel() { printf '%s/hrtf\n' "$(audio_dsp_state_rel)"; }
audio_dsp_lock() { printf '%s\n' "${AX20_HRTF_LOCK:-$AX20_SRC/overlay/home/hrtf/hrtf.lock}"; }

# Destinations of the rendered (not copied) files.
audio_dsp_headphones_rel() { printf '%s/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf\n' "$(audio_dsp_home)"; }
audio_dsp_speaker_chain_rel() { printf '%s/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf\n' "$(audio_dsp_home)"; }
audio_dsp_wpsettings_rel() { printf '%s/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf\n' "$(audio_dsp_home)"; }

# ---------------------------------------------------------------- settings --

# audio_dsp_setting <key> [default] : value from the settings file.
audio_dsp_setting() {
    local f v
    f=$(ax20_path "$(audio_dsp_settings_rel)")
    v=""
    if [ -f "$f" ]; then
        v=$(sed -n "s/^$1=//p" "$f" | tail -n1)
    fi
    [ -n "$v" ] || v=${2:-}
    printf '%s\n' "$v"
}

audio_dsp_enabled() { [ "$(audio_dsp_setting enabled 1)" = 1 ]; }

# _audio_dsp_number_in <value> <min> <max> : signed decimal within range.
_audio_dsp_number_in() {
    printf '%s\n' "$1" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$' || return 1
    LC_ALL=C awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'
}
audio_dsp_valid_lfe_cutoff() {
    case "$1" in '' | *[!0-9]*) return 1 ;; esac
    [ "$1" -ge 40 ] && [ "$1" -le 250 ]
}
audio_dsp_valid_lfe_gain() { _audio_dsp_number_in "$1" -40 6; }
# master gains: auto, strict, or dB in -60..12 (see audio_dsp_gain_numbers).
audio_dsp_valid_master() {
    case "$1" in auto | strict) return 0 ;; esac
    _audio_dsp_number_in "$1" -60 12
}

# audio_dsp_setting_value <key> : the stored value, validated, or the default.
audio_dsp_setting_value() {
    local v
    case "$1" in
        hrtf)
            audio_dsp_hrtf_current
            return 0
            ;;
        enabled | speakers_precedence | headphones_virtual_surround | hardware_volume)
            v=$(audio_dsp_setting "$1" 1)
            case "$v" in 0 | 1) ;; *) v=1 ;; esac
            ;;
        stereo_hrtf)
            v=$(audio_dsp_setting "$1" 0)
            case "$v" in 0 | 1) ;; *) v=0 ;; esac
            ;;
        lfe_cutoff_hz)
            v=$(audio_dsp_setting "$1" "")
            audio_dsp_valid_lfe_cutoff "$v" || v=$AUDIO_DSP_LFE_CUTOFF_DEFAULT
            ;;
        lfe_gain_db)
            v=$(audio_dsp_setting "$1" "")
            audio_dsp_valid_lfe_gain "$v" || v=$AUDIO_DSP_LFE_GAIN_DB_DEFAULT
            ;;
        speakers_master_gain_db)
            v=$(audio_dsp_setting "$1" "")
            audio_dsp_valid_master "$v" || v=auto
            ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$v"
}

# ------------------------------------------------------------- HRTF sets --

audio_dsp_hrtf_names() { awk '$1 == "set" { print $2 }' "$(audio_dsp_lock)"; }
audio_dsp_hrtf_default() { awk '$1 == "default" { print $2; exit }' "$(audio_dsp_lock)"; }
audio_dsp_hrtf_sha() { awk -v n="$1" '$1 == "set" && $2 == n { print $3; exit }' "$(audio_dsp_lock)"; }
audio_dsp_hrtf_license() { awk -v n="$1" '$1 == "set" && $2 == n { print $5; exit }' "$(audio_dsp_lock)"; }
audio_dsp_hrtf_known() { [ -n "$1" ] && [ -n "$(audio_dsp_hrtf_sha "$1")" ]; }

# audio_dsp_hrtf_current : configured set, falling back to the lock default.
audio_dsp_hrtf_current() {
    local n
    n=$(audio_dsp_setting hrtf "")
    if ! audio_dsp_hrtf_known "$n"; then
        n=$(audio_dsp_hrtf_default)
    fi
    printf '%s\n' "$n"
}

# audio_dsp_hrtf_installed <name> : the .sofa is in place with the locked digest.
audio_dsp_hrtf_installed() {
    local f
    f=$(ax20_path "$(audio_dsp_hrtf_rel)/$1.sofa")
    [ -f "$f" ] && [ "$(ax20_sha256 "$f")" = "$(audio_dsp_hrtf_sha "$1")" ]
}

# audio_dsp_fetch_hrtf <name...> : download (or copy from
# AX20_HRTF_SOURCE_DIR), verify against the lock, install through the
# manifest. Already-installed sets are skipped, so re-applying needs no
# network. Returns 1 if any requested set could not be installed.
audio_dsp_fetch_hrtf() {
    local need="" n tmp rc=0 dir
    dir=$(audio_dsp_hrtf_rel)
    for n in "$@"; do
        audio_dsp_hrtf_installed "$n" && manifest_has "$dir/$n.sofa" && continue
        need="$need $n"
    done
    [ -n "$need" ] || return 0
    if [ "${AX20_SKIP_DOWNLOADS:-0}" = 1 ] && [ -z "${AX20_HRTF_SOURCE_DIR:-}" ]; then
        log_warn "audio_dsp: AX20_SKIP_DOWNLOADS=1, not fetching HRTF sets:$need"
        return 1
    fi
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] fetch HRTF sets:%s into %s\n' "$need" "$(ax20_path "$dir")" >&2
        return 0
    fi
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ax20-hrtf.XXXXXX") || die "cannot create a temporary directory"
    set -- --lock "$(audio_dsp_lock)" --dest "$tmp"
    if [ -n "${AX20_HRTF_SOURCE_DIR:-}" ]; then
        set -- "$@" --source-dir "$AX20_HRTF_SOURCE_DIR"
    fi
    # shellcheck disable=SC2086  # set names never contain whitespace
    "$AX20_SRC/overlay/home/hrtf/fetch-hrtf.sh" "$@" $need >/dev/null || rc=1
    for n in $need; do
        if [ -f "$tmp/$n.sofa" ]; then
            manifest_install_file "$tmp/$n.sofa" "$dir/$n.sofa" "$AUDIO_DSP_COMPONENT" 0644 home
        else
            log_warn "audio_dsp: HRTF set '$n' could not be fetched or failed verification"
            rc=1
        fi
    done
    rm -rf "$tmp"
    return $rc
}

# audio_dsp_link_hrtf <name> : point current.sofa at <name>.sofa.
audio_dsp_link_hrtf() {
    manifest_install_symlink "$1.sofa" "$(audio_dsp_hrtf_rel)/current.sofa" "$AUDIO_DSP_COMPONENT" home
}

# ------------------------------------------------------------------ probes --

# audio_dsp_probe_sofa_plugin : does stock PipeWire have the sofa spatializer?
#   PipeWire >= 1.3 ships it as a filter-graph plugin, <= 1.2 as a separate
#   filter-chain module; both exist only when PipeWire was built against
#   libmysofa. Last resort for unknown layouts: the filter-chain module
#   importing mysofa_* symbols (the plan's `strings | grep sofa`, narrowed to
#   "mysofa" because every filter-chain build mentions "sofa" in its help
#   text). 0 yes, 1 no, 2 unknown (no PipeWire filter-chain found at all).
audio_dsp_probe_sofa_plugin() {
    local fc=/usr/lib/pipewire-0.3/libpipewire-module-filter-chain.so rc
    probe_file_exists /usr/lib/spa-0.2/filter-graph/libspa-filter-graph-plugin-sofa.so && return "$PROBE_YES"
    probe_file_exists /usr/lib/pipewire-0.3/libpipewire-module-filter-chain-sofa.so && return "$PROBE_YES"
    rc=0
    probe_file_contains "$fc" mysofa || rc=$?
    return "$rc"
}

# audio_dsp_probe_libmysofa : libmysofa shared library present.
audio_dsp_probe_libmysofa() {
    local d
    for d in /usr/lib /usr/lib64 /var/lib/ally-x20-steamos/lib; do
        if ls "$(ax20_path "$d")"/libmysofa.so* >/dev/null 2>&1; then
            return "$PROBE_YES"
        fi
    done
    return "$PROBE_NO"
}

# audio_dsp_probe_sofa_support : 0 when the HRTF chain can load. TODO(hw):
# SteamOS 3.9's pipewire-audio 1.6.8 package contains the sofa plugin and
# depends on libmysofa, so this is expected to be 0 on the X20.
# Fallback when the plugin exists but libmysofa is missing: build it with
# build/build-libmysofa.sh and stage it in /var/lib/ally-x20-steamos/lib,
# which the hdr component's ld.so.conf.d drop-in puts on the loader path.
# Without the plugin itself there is no sofa support to rescue; the virtual
# surround sinks then fail to load (nofail) and are simply absent.
audio_dsp_probe_sofa_support() {
    local rc=0
    audio_dsp_probe_sofa_plugin || rc=$?
    [ "$rc" = "$PROBE_YES" ] || return "$rc"
    audio_dsp_probe_libmysofa
}

# audio_dsp_have_lsp : LSP Plugins LV2 bundle installed (system or ~/.lv2).
audio_dsp_have_lsp() {
    probe_file_exists /usr/lib/lv2/lsp-plugins.lv2 && return 0
    probe_file_exists "$(audio_dsp_home)/.lv2/lsp-plugins.lv2" && return 0
    return 1
}

# ------------------------------------------------------- component contract --

# _audio_dsp_static_files : every copied file, regardless of the enabled flag.
_audio_dsp_static_files() {
    local h
    h=$(audio_dsp_home)
    printf 'home/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf\t%s/.config/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf\t0644\thome\n' "$h"
    printf 'home/pipewire/client.conf.d/50-x20-no-upmix.conf\t%s/.config/pipewire/client.conf.d/50-x20-no-upmix.conf\t0644\thome\n' "$h"
    printf 'home/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf\t%s/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf\t0644\thome\n' "$h"
    printf 'home/wireplumber/scripts/x20-route-by-channels.lua\t%s/.local/share/wireplumber/scripts/x20-route-by-channels.lua\t0644\thome\n' "$h"
    printf 'home/wireplumber/scripts/x20-select-default-sink.lua\t%s/.local/share/wireplumber/scripts/x20-select-default-sink.lua\t0644\thome\n' "$h"
    printf 'home/wireplumber/scripts/x20-hardware-volume.lua\t%s/.local/share/wireplumber/scripts/x20-hardware-volume.lua\t0644\thome\n' "$h"
    printf 'home/wireplumber/scripts/lib/x20-route-core.lua\t%s/.local/share/wireplumber/scripts/lib/x20-route-core.lua\t0644\thome\n' "$h"
    printf 'home/wireplumber/scripts/lib/x20-sink-facts.lua\t%s/.local/share/wireplumber/scripts/lib/x20-sink-facts.lua\t0644\thome\n' "$h"
    printf 'home/wireplumber/scripts/lib/x20-volume-core.lua\t%s/.local/share/wireplumber/scripts/lib/x20-volume-core.lua\t0644\thome\n' "$h"
}

audio_dsp_files() {
    audio_dsp_enabled || return 0
    _audio_dsp_static_files
}

# Never superseded: stock SteamOS has no per-stream HRTF routing and Valve's
# own DSP (steamdeck-dsp) is tuned for the Steam Deck only. Status reports
# on/off through audio_dsp_status instead.
audio_dsp_probe() {
    return "$PROBE_NO"
}

# _audio_dsp_install_rendered <dest> : stdin -> manifest-tracked file.
_audio_dsp_install_rendered() {
    local dest=$1 tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-render.XXXXXX") || die "cannot create a temporary file"
    cat >"$tmp"
    manifest_install_file "$tmp" "$dest" "$AUDIO_DSP_COMPONENT" 0644 home
    rm -f "$tmp"
}

# audio_dsp_write_settings [key=value...] : rewrite the settings file. Keys
# not given keep their current (validated) value or get their default.
audio_dsp_write_settings() {
    local k v a body=""
    for k in $AUDIO_DSP_KEYS; do
        v=$(audio_dsp_setting_value "$k")
        for a in "$@"; do
            case "$a" in "$k="*) v=${a#*=} ;; esac
        done
        body="$body$k=$v
"
    done
    {
        printf '%s\n' \
            "# $AX20_NAME audio-dsp settings. Managed by '$AX20_NAME audio-dsp';" \
            "# edit with that command (hand edits are kept but flagged as drift)."
        printf '%s' "$body"
    } | _audio_dsp_install_rendered "$(audio_dsp_settings_rel)"
}

_audio_dsp_bool() { if [ "$1" = 1 ]; then echo true; else echo false; fi; }

# audio_dsp_render_wpsettings : WirePlumber settings fragment from the
# current settings file (read by x20-select-default-sink.lua and
# x20-hardware-volume.lua; stereo_hrtf is kept for compatibility only).
audio_dsp_render_wpsettings() {
    printf '%s\n' \
        "# SPDX-License-Identifier: GPL-2.0-only" \
        "# Generated by $AX20_NAME (audio-dsp speakers-precedence," \
        "# headphones-virtual-surround, hardware-volume); do not edit." \
        "# See 50-x20-route-by-channels.conf." \
        "wireplumber.settings = {" \
        "  x20.speakers_precedence = $(_audio_dsp_bool "$(audio_dsp_setting_value speakers_precedence)")" \
        "  x20.headphones_virtual_surround = $(_audio_dsp_bool "$(audio_dsp_setting_value headphones_virtual_surround)")" \
        "  x20.stereo_hrtf = $(_audio_dsp_bool "$(audio_dsp_setting_value stereo_hrtf)")" \
        "  x20.hardware_volume = $(_audio_dsp_bool "$(audio_dsp_setting_value hardware_volume)")" \
        "}" \
        | _audio_dsp_install_rendered "$(audio_dsp_wpsettings_rel)"
}

# audio_dsp_lfe_gain_lin : lfe_gain_db as a linear mixer gain.
audio_dsp_lfe_gain_lin() {
    LC_ALL=C awk -v db="$(audio_dsp_setting_value lfe_gain_db)" 'BEGIN { printf "%.6f\n", exp(db / 20 * log(10)) }'
}

# audio_dsp_gain_numbers : worst-case gain analysis of x20-speakers, prints
# "<stereo> <downmix71> <spk_master> <spk_master_lin>" (dB unless _lin).
#
# Model: steady-state sinusoids at full scale on every input, swept over
# 20 Hz-20 kHz; at each frequency the magnitudes of all input->output paths
# are added (coherent worst case), the maximum over frequency is reported.
# Filters use the RBJ formulas PipeWire's builtin biquads use, at 48 kHz.
# Constants mirror the template: downmix 1 / 0.707 x3, width 0.85 + 0.142,
# EQ high-pass 150, low shelf 250 +3, peak 3500 -2 (Q 1), high shelf 8000 +2.
#   stereo        FL+FR only (what stereo streams feed it)
#   downmix71     all 8 channels
# Master gain: auto = 0 dB (stereo keeps unity), strict = safe for
# downmix71. A number is used as is.
audio_dsp_gain_numbers() {
    LC_ALL=C awk -v fc="$(audio_dsp_setting_value lfe_cutoff_hz)" -v lfe="$(audio_dsp_lfe_gain_lin)" \
        -v mpset="$(audio_dsp_setting_value speakers_master_gain_db)" '
    function coef(kind, f0, Q, gdb,   w0, al, k, A, k2) {
        w0 = 2 * PI * f0 / FS; al = sin(w0) / (2 * Q); k = cos(w0); A = exp(gdb / 40 * log(10))
        if (kind == "lp") { b0 = (1 - k) / 2; b1 = 1 - k; b2 = b0; a0 = 1 + al; a1 = -2 * k; a2 = 1 - al }
        if (kind == "hp") { b0 = (1 + k) / 2; b1 = -(1 + k); b2 = b0; a0 = 1 + al; a1 = -2 * k; a2 = 1 - al }
        if (kind == "pk") { b0 = 1 + al * A; b1 = -2 * k; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * k; a2 = 1 - al / A }
        if (kind == "ls" || kind == "hs") {
            k2 = 2 * sqrt(A) * al
            if (kind == "ls") {
                b0 = A * ((A + 1) - (A - 1) * k + k2); b1 = 2 * A * ((A - 1) - (A + 1) * k); b2 = A * ((A + 1) - (A - 1) * k - k2)
                a0 = (A + 1) + (A - 1) * k + k2; a1 = -2 * ((A - 1) + (A + 1) * k); a2 = (A + 1) + (A - 1) * k - k2
            } else {
                b0 = A * ((A + 1) + (A - 1) * k + k2); b1 = -2 * A * ((A - 1) + (A + 1) * k); b2 = A * ((A + 1) + (A - 1) * k - k2)
                a0 = (A + 1) - (A - 1) * k + k2; a1 = 2 * ((A - 1) - (A + 1) * k); a2 = (A + 1) - (A - 1) * k - k2
            }
        }
    }
    # H(e^jw) of a biquad into HR, HI
    function bq(kind, f0, Q, gdb, w,   nr, ni, dr, di, d) {
        coef(kind, f0, Q, gdb)
        nr = b0 + b1 * cos(w) + b2 * cos(2 * w); ni = -(b1 * sin(w) + b2 * sin(2 * w))
        dr = a0 + a1 * cos(w) + a2 * cos(2 * w); di = -(a1 * sin(w) + a2 * sin(2 * w))
        d = dr * dr + di * di
        HR = (nr * dr + ni * di) / d; HI = (ni * dr - nr * di) / d
    }
    function mag(kind, f0, Q, gdb, w) { bq(kind, f0, Q, gdb, w); return sqrt(HR * HR + HI * HI) }
    function db(x) { return 20 * log(x) / log(10) }
    function gainof(set, safe) {
        if (set == "auto" || set == "strict") return safe
        return exp(set / 20 * log(10))
    }
    BEGIN {
        PI = atan2(0, -1); FS = 48000; W = 0.85 + 0.142
        mps = m71 = 0
        for (i = 0; i <= 600; i++) {
            f = 20 * exp(i / 600 * log(1000)); w = 2 * PI * f / FS
            E = mag("hp", 150, 0.707, 0, w) * mag("ls", 250, 0.707, 3, w) * mag("pk", 3500, 1, -2, w) * mag("hs", 8000, 0.707, 2, w)
            L = mag("lp", fc, 0.707, 0, w) ^ 2
            ps = W * E; p71 = W * E * (1 + 3 * 0.707 + L * lfe)
            if (ps > mps) mps = ps; if (p71 > m71) m71 = p71
        }
        mp = gainof(mpset, (mpset == "strict") ? 1 / m71 : 1)
        if (mp > 10) mp = 10
        printf "%.1f %.1f %.1f %.6f\n", db(mps), db(m71), db(mp), mp
    }'
}

_audio_dsp_signed() { LC_ALL=C awk -v v="$1" 'BEGIN { printf "%+.1f", v }'; }

# audio_dsp_gain_describe : one line for humans (status, rendered conf).
audio_dsp_gain_describe() {
    local p
    p=$(audio_dsp_gain_numbers)
    # shellcheck disable=SC2086  # numbers only
    set -- $p
    printf 'lfe %s Hz %s dB; worst case before master: stereo %s dB, 7.1 downmix %s dB; speakers_master_gain_db=%s (%s dB)\n' \
        "$(audio_dsp_setting_value lfe_cutoff_hz)" "$(audio_dsp_setting_value lfe_gain_db)" \
        "$(_audio_dsp_signed "$1")" "$(_audio_dsp_signed "$2")" \
        "$(audio_dsp_setting_value speakers_master_gain_db)" "$(_audio_dsp_signed "$3")"
}

# audio_dsp_priority : priority.session of x20-speakers from
# speakers_precedence.
audio_dsp_priority() {
    if [ "$(audio_dsp_setting_value speakers_precedence)" = 1 ]; then
        printf '%s\n' "$AUDIO_DSP_PRIO_SPEAKERS"
    else
        printf '%s\n' "$AUDIO_DSP_PRIO_MANUAL"
    fi
}

# audio_dsp_render_speaker_chain : x20-speakers (or its LSP variant) with
# the LFE, master gain and priority settings.
audio_dsp_render_speaker_chain() {
    local src=51-x20-speaker-chain.conf p
    audio_dsp_have_lsp && src=51-x20-speaker-chain-lsp.conf
    p=$(audio_dsp_gain_numbers)
    # shellcheck disable=SC2086  # numbers only
    set -- $p
    sed -e "s#@X20_LFE_CUTOFF@#$(audio_dsp_setting_value lfe_cutoff_hz).0#g" \
        -e "s#@X20_LFE_GAIN@#$(audio_dsp_lfe_gain_lin)#g" \
        -e "s#@X20_SPK_MASTER@#$4#g" \
        -e "s#@X20_SPK_PRIORITY@#$(audio_dsp_priority)#g" \
        -e "s#@X20_GAIN_SUMMARY@#$(audio_dsp_gain_describe)#g" \
        "$AX20_SRC/overlay/home/pipewire/pipewire.conf.d/$src" \
        | _audio_dsp_install_rendered "$(audio_dsp_speaker_chain_rel)"
}

# audio_dsp_render_headphones : the headphone virtual surround conf (sink
# x20-headphones) with the absolute HRTF path (libmysofa does not expand
# "~"). /home is not part of the A/B slots, so the live path is used even
# when applying to a staged slot.
audio_dsp_render_headphones() {
    local hrtf_file
    hrtf_file="$(audio_dsp_hrtf_rel)/current.sofa"
    sed -e "s#@X20_HRTF_FILE@#$hrtf_file#g" \
        -e "s#@X20_LFE_CUTOFF@#$(audio_dsp_setting_value lfe_cutoff_hz).0#g" \
        -e "s#@X20_LFE_GAIN@#$(audio_dsp_lfe_gain_lin)#g" \
        "$AX20_SRC/overlay/home/pipewire/pipewire.conf.d/50-x20-headphones.conf" \
        | _audio_dsp_install_rendered "$(audio_dsp_headphones_rel)"
}

# _audio_dsp_fix_owner : files we created in the home must belong to the
# user, including intermediate directories mkdir -p made as root (e.g.
# ~/.config/pipewire). Only on a live system, only when running as root.
_audio_dsp_fix_owner() {
    local user home p d
    [ -z "$AX20_ROOT" ] || return 0
    [ "$AX20_DRY_RUN" = 1 ] && return 0
    ax20_is_root || return 0
    user=$(audio_dsp_user)
    home=$(audio_dsp_home)
    id "$user" >/dev/null 2>&1 || return 0
    for p in $(manifest_paths "$AUDIO_DSP_COMPONENT"); do
        case "$p" in "$home"/*) ;; *) continue ;; esac
        [ -e "$p" ] || [ -L "$p" ] || continue
        chown -h "$user:" "$p" 2>/dev/null || true
        d=$(dirname "$p")
        while [ "$d" != "$home" ] && [ "$d" != / ]; do
            if [ "$(stat -c %u "$d" 2>/dev/null)" = 0 ]; then
                chown "$user:" "$d" 2>/dev/null || true
            fi
            d=$(dirname "$d")
        done
    done
}

# audio_dsp_restart_services [units...] : restart the user's audio daemons so
# new config is read. Guarded: live system only, systemd present, user
# session running (/run/user/<uid>), AX20_NO_RESTART unset.
audio_dsp_restart_services() {
    local user uid
    [ $# -gt 0 ] || set -- pipewire.service pipewire-pulse.service wireplumber.service
    if [ -n "$AX20_ROOT" ] || [ "${AX20_NO_RESTART:-0}" = 1 ]; then
        log_debug "audio_dsp: not restarting $* (fixture root or AX20_NO_RESTART)"
        return 0
    fi
    ax20_have systemctl || return 0
    user=$(audio_dsp_user)
    uid=$(id -u "$user" 2>/dev/null) || return 0
    if [ ! -d "/run/user/$uid" ]; then
        log_info "audio_dsp: $user has no running session; changes apply at next login"
        return 0
    fi
    if ax20_is_root; then
        ax20_run systemctl --user -M "$user@" restart "$@" \
            || log_warn "audio_dsp: could not restart $* for $user; log out and back in"
    else
        ax20_run systemctl --user restart "$@" \
            || log_warn "audio_dsp: could not restart $*; log out and back in"
    fi
}

audio_dsp_apply() {
    local name enabled
    enabled=$(audio_dsp_setting_value enabled)
    name=$(audio_dsp_hrtf_current)
    if [ "$enabled" != 1 ]; then
        log_info "audio_dsp: disabled in $(audio_dsp_settings_rel); keeping it off"
        audio_dsp_write_settings enabled=0
        _audio_dsp_fix_owner
        return 0
    fi

    # HRTF data: every locked set (2-3 small files) so switching is offline.
    # shellcheck disable=SC2046
    audio_dsp_fetch_hrtf $(audio_dsp_hrtf_names) \
        || log_warn "audio_dsp: some HRTF sets are missing; re-run apply when online"
    audio_dsp_link_hrtf "$name"

    audio_dsp_render_speaker_chain
    if audio_dsp_hrtf_installed "$name" || [ "$AX20_DRY_RUN" = 1 ]; then
        audio_dsp_render_headphones
    else
        log_warn "audio_dsp: HRTF set '$name' unavailable; headphone virtual surround not installed (speaker chain still active)"
    fi
    # Settings first: the WirePlumber fragment is rendered from them.
    audio_dsp_write_settings enabled=1
    audio_dsp_render_wpsettings

    if ! audio_dsp_probe_sofa_support >/dev/null 2>&1; then
        log_warn "audio_dsp: PipeWire sofa support (libmysofa) not detected; virtual surround sinks may not load (see docs/audio-dsp.md)"
    fi
    # Upgrades: drop what an earlier version installed and this one does not
    # (50-x20-virtual-surround.conf would load the old sinks next to the new;
    # 52-x20-speaker-surround.conf, the removed speaker virtual surround).
    audio_dsp_prune || true
    _audio_dsp_fix_owner
    audio_dsp_restart_services
    return 0
}

# _audio_dsp_unlink <dest> : remove one manifest-tracked file or symlink we
# wrote. Modified files are kept (same rule as uninstall) and reported.
_audio_dsp_unlink() {
    local rc=0
    manifest_verify "$1" || rc=$?
    case "$rc" in
        0 | 2)
            ax20_run rm -f "$(ax20_path "$1")"
            manifest_forget "$1"
            ;;
        1)
            log_warn "audio_dsp: $1 was modified after install; leaving it in place (remove it by hand)"
            return 1
            ;;
    esac
    return 0
}

# _audio_dsp_known_paths : every path this version installs while enabled,
# one per line, whether or not this apply could render it (the headphone conf
# withheld because the HRTF set is missing is still ours, not stale).
_audio_dsp_known_paths() {
    local dir n
    _audio_dsp_static_files | cut -f2
    audio_dsp_headphones_rel
    audio_dsp_speaker_chain_rel
    audio_dsp_wpsettings_rel
    audio_dsp_settings_rel
    dir=$(audio_dsp_hrtf_rel)
    printf '%s/current.sofa\n' "$dir"
    for n in $(audio_dsp_hrtf_names); do
        printf '%s/%s.sofa\n' "$dir" "$n"
    done
}

# _audio_dsp_recorded <kind> : manifest paths of this component of that kind
# (file, symlink, dir).
_audio_dsp_recorded() {
    manifest_entries | _manifest_select component "$AUDIO_DSP_COMPONENT" \
        | _manifest_select kind "$1" | _manifest_field path
}

# _audio_dsp_prune_dirs : directories we created (recorded as kind dir) that
# are empty now are removed, deepest first; vanished ones are forgotten.
# Never the home directory itself, never anything outside it, never through
# a symlink (the uninstaller's rules).
_audio_dsp_prune_dirs() {
    local home d real
    home=$(audio_dsp_home)
    _audio_dsp_recorded dir | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2- \
        | while IFS= read -r d; do
            case "$d" in "$home"/?*) ;; *) continue ;; esac
            real=$(ax20_path "$d")
            [ -L "$real" ] && continue
            if [ ! -d "$real" ]; then
                manifest_forget "$d"
                continue
            fi
            [ -z "$(find "$real" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ] || continue
            ax20_run rmdir "$real" && manifest_forget "$d"
        done
}

# audio_dsp_prune : remove the files and symlinks recorded for this
# component that this version no longer installs (renamed or dropped in an
# upgrade), then the directories we created that this left empty. Same
# rules as the uninstaller: only paths in our manifest that carry an x20
# marker, content checked against the recorded digest first; a modified
# file is kept, reported and stays in the manifest. Returns 1 if anything
# was kept.
audio_dsp_prune() {
    local known p rc=0
    known=$(_audio_dsp_known_paths)
    for p in $(_audio_dsp_recorded file) $(_audio_dsp_recorded symlink); do
        printf '%s\n' "$known" | grep -Fxq -- "$p" && continue
        case "$p" in *x20*) ;; *)
            log_warn "audio_dsp: not pruning $p: no x20 marker in the path"
            rc=1
            continue
            ;;
        esac
        log_info "audio_dsp: removing $p (no longer installed by this version)"
        if ! _audio_dsp_unlink "$p"; then
            log_warn "audio_dsp: PipeWire/WirePlumber still load $p; remove it by hand"
            rc=1
        fi
    done
    _audio_dsp_prune_dirs
    return $rc
}

# audio_dsp_disable : `audio-dsp off`. Removes every configuration file we
# recorded, including names from earlier versions, so PipeWire/WirePlumber
# run exactly as stock (no virtual sinks in the output picker, no hook
# scripts), keeps the downloaded HRTF data (and current.sofa) and records
# enabled=0 so neither `apply` nor the boot service turns it back on.
audio_dsp_disable() {
    local p rc=0 settings hrtf
    audio_dsp_write_settings enabled=0
    settings=$(audio_dsp_settings_rel)
    hrtf=$(audio_dsp_hrtf_rel)
    for p in $(_audio_dsp_recorded file) $(_audio_dsp_recorded symlink); do
        case "$p" in "$settings" | "$hrtf"/*) continue ;; esac
        _audio_dsp_unlink "$p" || rc=1
    done
    _audio_dsp_prune_dirs
    _audio_dsp_fix_owner
    audio_dsp_restart_services
    return $rc
}

# audio_dsp_status : active when enabled and every file verifies and the
# selected HRTF resolves; stock when disabled, missing or drifted (the boot
# service re-applies "stock", which is a no-op while disabled).
audio_dsp_status() {
    local p
    if ! [ -f "$(ax20_path "$(audio_dsp_settings_rel)")" ] || ! audio_dsp_enabled; then
        printf 'stock\n'
        return 0
    fi
    if ! component_installed "$AUDIO_DSP_COMPONENT"; then
        printf 'stock\n'
        return 0
    fi
    for p in $(manifest_paths "$AUDIO_DSP_COMPONENT"); do
        if ! manifest_verify "$p"; then
            printf 'stock\n'
            return 0
        fi
    done
    if ! [ -f "$(ax20_path "$(audio_dsp_hrtf_rel)/current.sofa")" ] \
        || ! [ -f "$(ax20_path "$(audio_dsp_headphones_rel)")" ] \
        || ! [ -f "$(ax20_path "$(audio_dsp_speaker_chain_rel)")" ]; then
        printf 'stock\n'
        return 0
    fi
    printf 'active\n'
}
