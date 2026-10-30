# SPDX-License-Identifier: GPL-2.0-only
# components/audio_dsp.sh — headphone virtual surround + speaker chain
# (X20-STEAMOS-PLAN.md section 1.5). Required component, on by default.
#
# Everything lives in the user's home (manifest slot "home"), so it survives
# SteamOS updates untouched and never needs the read-only root:
#   ~/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf  (rendered)
#   ~/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf
#   ~/.config/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf
#   ~/.config/pipewire/client.conf.d/50-x20-no-upmix.conf
#   ~/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf
#   ~/.config/wireplumber/wireplumber.conf.d/51-x20-settings.conf      (rendered)
#   ~/.local/share/wireplumber/scripts/x20-route-by-channels.lua
#   ~/.local/share/wireplumber/scripts/lib/x20-route-core.lua
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
#   stereo_hrtf=0|1   stereo streams through the HRTF on headphones
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
audio_dsp_surround_rel() { printf '%s/.config/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf\n' "$(audio_dsp_home)"; }
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
# surround sinks then fail to load (nofail) and the router uses the hardware.
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
    local h chain=51-x20-speaker-chain.conf
    h=$(audio_dsp_home)
    audio_dsp_have_lsp && chain=51-x20-speaker-chain-lsp.conf
    printf 'home/pipewire/pipewire.conf.d/%s\t%s/.config/pipewire/pipewire.conf.d/51-x20-speaker-chain.conf\t0644\thome\n' "$chain" "$h"
    printf 'home/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf\t%s/.config/pipewire/pipewire-pulse.conf.d/50-x20-no-upmix.conf\t0644\thome\n' "$h"
    printf 'home/pipewire/client.conf.d/50-x20-no-upmix.conf\t%s/.config/pipewire/client.conf.d/50-x20-no-upmix.conf\t0644\thome\n' "$h"
    printf 'home/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf\t%s/.config/wireplumber/wireplumber.conf.d/50-x20-route-by-channels.conf\t0644\thome\n' "$h"
    printf 'home/wireplumber/scripts/x20-route-by-channels.lua\t%s/.local/share/wireplumber/scripts/x20-route-by-channels.lua\t0644\thome\n' "$h"
    printf 'home/wireplumber/scripts/lib/x20-route-core.lua\t%s/.local/share/wireplumber/scripts/lib/x20-route-core.lua\t0644\thome\n' "$h"
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

# audio_dsp_write_settings <enabled> <hrtf> <stereo_hrtf>
audio_dsp_write_settings() {
    printf '%s\n' \
        "# $AX20_NAME audio-dsp settings. Managed by '$AX20_NAME audio-dsp';" \
        "# edit with that command (hand edits are kept but flagged as drift)." \
        "enabled=$1" \
        "hrtf=$2" \
        "stereo_hrtf=$3" \
        | _audio_dsp_install_rendered "$(audio_dsp_settings_rel)"
}

# audio_dsp_render_wpsettings <0|1> : WirePlumber settings fragment.
audio_dsp_render_wpsettings() {
    local v=false
    [ "$1" = 1 ] && v=true
    printf '%s\n' \
        "# SPDX-License-Identifier: GPL-2.0-only" \
        "# Generated by $AX20_NAME (audio-dsp stereo-hrtf on|off); do not edit." \
        "# true: stereo streams on headphones go through the HRTF renderer." \
        "wireplumber.settings = {" \
        "  x20.stereo_hrtf = $v" \
        "}" \
        | _audio_dsp_install_rendered "$(audio_dsp_wpsettings_rel)"
}

# audio_dsp_render_surround : the virtual surround conf with the absolute
# HRTF path (libmysofa does not expand "~"). /home is not part of the A/B
# slots, so the live path is used even when applying to a staged slot.
audio_dsp_render_surround() {
    local hrtf_file
    hrtf_file="$(audio_dsp_hrtf_rel)/current.sofa"
    sed "s#@X20_HRTF_FILE@#$hrtf_file#g" \
        "$AX20_SRC/overlay/home/pipewire/pipewire.conf.d/50-x20-virtual-surround.conf" \
        | _audio_dsp_install_rendered "$(audio_dsp_surround_rel)"
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
    local name stereo enabled
    enabled=$(audio_dsp_setting enabled 1)
    name=$(audio_dsp_hrtf_current)
    stereo=$(audio_dsp_setting stereo_hrtf 0)
    case "$enabled" in 1 | 0) ;; *) enabled=1 ;; esac
    case "$stereo" in 1 | 0) ;; *) stereo=0 ;; esac
    if [ "$enabled" != 1 ]; then
        log_info "audio_dsp: disabled in $(audio_dsp_settings_rel); keeping it off"
        audio_dsp_write_settings 0 "$name" "$stereo"
        _audio_dsp_fix_owner
        return 0
    fi

    # HRTF data: every locked set (2-3 small files) so switching is offline.
    # shellcheck disable=SC2046
    audio_dsp_fetch_hrtf $(audio_dsp_hrtf_names) \
        || log_warn "audio_dsp: some HRTF sets are missing; re-run apply when online"
    audio_dsp_link_hrtf "$name"

    if audio_dsp_hrtf_installed "$name" || [ "$AX20_DRY_RUN" = 1 ]; then
        audio_dsp_render_surround
    else
        log_warn "audio_dsp: HRTF set '$name' unavailable; headphone virtual surround not installed (stereo passthrough and speaker chain still active)"
    fi
    audio_dsp_render_wpsettings "$stereo"
    audio_dsp_write_settings 1 "$name" "$stereo"

    if ! audio_dsp_probe_sofa_support >/dev/null 2>&1; then
        log_warn "audio_dsp: PipeWire sofa support (libmysofa) not detected; virtual surround sinks may not load (see docs/audio-dsp.md)"
    fi
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

# audio_dsp_disable : `audio-dsp off`. Removes every configuration file so
# PipeWire/WirePlumber run exactly as stock (no virtual sinks in the output
# picker, no routing script), keeps the downloaded HRTF data and records
# enabled=0 so neither `apply` nor the boot service turns it back on.
audio_dsp_disable() {
    local name stereo dest rc=0
    name=$(audio_dsp_hrtf_current)
    stereo=$(audio_dsp_setting stereo_hrtf 0)
    audio_dsp_write_settings 0 "$name" "$stereo"
    while IFS=$'\t' read -r _ dest _; do
        [ -n "$dest" ] || continue
        _audio_dsp_unlink "$dest" || rc=1
    done <<EOF
$(_audio_dsp_static_files)
$(printf 'x\t%s\n' "$(audio_dsp_surround_rel)")
$(printf 'x\t%s\n' "$(audio_dsp_wpsettings_rel)")
EOF
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
        || ! [ -f "$(ax20_path "$(audio_dsp_surround_rel)")" ]; then
        printf 'stock\n'
        return 0
    fi
    printf 'active\n'
}
