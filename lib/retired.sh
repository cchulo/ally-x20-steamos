# SPDX-License-Identifier: GPL-2.0-only
# lib/retired.sh — clean up after components this version no longer ships.
#
# A component that is removed from components/ still has its files recorded
# in the manifest of every device that had it. `apply` (and the boot
# service, through apply_components) calls retired_prune_all, which removes
# them with the uninstaller's rules:
#   * only paths recorded in our manifest under that component name,
#   * only paths with an x20 marker in them,
#   * files and symlinks checked against the recorded digest first; a
#     modified file is kept, reported and stays in the manifest (remove it
#     by hand, or `uninstall --force`),
#   * directories we created are removed only when empty, deepest first,
#     never through a symlink.
# Each retired component may define retired_<name>_extra (paths it created
# outside the manifest) and retired_<name>_after (restart what loaded the
# files); both get the list of removed paths on stdin.
#
# Retired:
#   audio_dsp  removed 2026-11-01: headphone virtual surround and speaker
#              DSP (PipeWire filter-chain sinks, WirePlumber hooks, HRTF
#              data). See docs/audio-dsp-history.md.

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$AX20_SRC/lib/manifest.sh"

AX20_RETIRED_COMPONENTS="audio_dsp"

# retired_is <name> : 0 when <name> is a component this version retired.
retired_is() {
    case " $AX20_RETIRED_COMPONENTS " in *" $1 "*) return 0 ;; esac
    return 1
}

# _retired_recorded <component> <kind> : its manifest paths of that kind.
_retired_recorded() {
    manifest_entries | _manifest_select component "$1" \
        | _manifest_select kind "$2" | _manifest_field path
}

# _retired_unlink <component> <path> : remove one recorded file or symlink.
# 0 removed (or already gone), 1 kept (modified or no marker).
_retired_unlink() {
    local rc=0
    case "$2" in *x20*) ;; *)
        log_warn "$1: not removing $2: no x20 marker in the path"
        return 1
        ;;
    esac
    manifest_verify "$2" || rc=$?
    case "$rc" in
        0 | 2)
            log_info "$1: removing $2 (component removed from $AX20_NAME)"
            ax20_run rm -f "$(ax20_path "$2")"
            manifest_forget "$2"
            return 0
            ;;
    esac
    log_warn "$1: $2 was modified after install; leaving it in place (remove it by hand)"
    return 1
}

# _retired_prune_dirs <component> : directories it created, deepest first,
# removed when empty; vanished ones are forgotten.
_retired_prune_dirs() {
    local d real
    _retired_recorded "$1" dir | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2- \
        | while IFS= read -r d; do
            case "$d" in /?*) ;; *) continue ;; esac
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

# retired_prune <component> : remove what the manifest records for it.
# Returns 1 if anything was kept.
retired_prune() {
    local c=$1 p rc=0 removed=""
    for p in $(_retired_recorded "$c" file) $(_retired_recorded "$c" symlink); do
        if _retired_unlink "$c" "$p"; then
            removed="$removed$p
"
        else
            rc=1
        fi
    done
    if declare -F "retired_${c}_extra" >/dev/null 2>&1; then
        printf '%s' "$removed" | "retired_${c}_extra" || rc=1
    fi
    _retired_prune_dirs "$c"
    if [ -n "$removed" ] && declare -F "retired_${c}_after" >/dev/null 2>&1; then
        printf '%s' "$removed" | "retired_${c}_after" || true
    fi
    if [ -z "$(manifest_paths "$c" | head -n 1)" ]; then
        log_info "$c: removed (no longer part of $AX20_NAME)"
    fi
    return $rc
}

# retired_prune_all : retired_prune every retired component the manifest
# still mentions. Returns 1 if anything was kept.
retired_prune_all() {
    local c rc=0
    for c in $AX20_RETIRED_COMPONENTS; do
        [ -n "$(manifest_paths "$c" | head -n 1)" ] || continue
        retired_prune "$c" || rc=1
    done
    return $rc
}

# ------------------------------------------------------------ audio_dsp --

# _retired_homes : the home directories in the removed paths on stdin
# (the leading run of components that do not start with a dot, followed by
# /.config/ or /.local/), one per line.
_retired_homes() {
    sed -nE 's#^((/[^/.][^/]*)+)/\.(config|local)/.*#\1#p' | sort -u
}

# retired_audio_dsp_extra : the WirePlumber state file of the removed
# hardware-volume hook (written by WirePlumber, so not in the manifest) and
# the settings directory it left empty. Reads removed paths on stdin.
retired_audio_dsp_extra() {
    local h f d
    for h in $(_retired_homes); do
        f=$(ax20_path "$h/.local/state/wireplumber/x20-hardware-volume")
        if [ -f "$f" ] && ! [ -L "$f" ]; then
            if grep -q '=' "$f" 2>/dev/null; then
                log_warn "audio_dsp: the hardware volume hook held a sink at 100 % for $h; check the volume before playing anything loud"
            fi
            log_info "audio_dsp: removing $h/.local/state/wireplumber/x20-hardware-volume"
            ax20_run rm -f "$f"
        fi
        for d in "$h/.config/$AX20_NAME/hrtf" "$h/.config/$AX20_NAME"; do
            f=$(ax20_path "$d")
            if [ ! -d "$f" ] || [ -L "$f" ]; then
                continue
            fi
            [ -z "$(find "$f" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ] || continue
            ax20_run rmdir "$f"
        done
    done
    return 0
}

# retired_audio_dsp_after : restart the PipeWire session of every user whose
# home lost files, so the removed sinks and hooks are gone at once.
retired_audio_dsp_after() {
    local h user
    for h in $(_retired_homes); do
        user=$(stat -c %U "$(ax20_path "$h")" 2>/dev/null) || user=""
        case "$user" in '' | UNKNOWN | root) user=$(basename "$h") ;; esac
        ax20_restart_user_audio "$user"
    done
}

# ax20_restart_user_audio <user> : restart the user's PipeWire, PipeWire-Pulse
# and WirePlumber so their config is re-read. Live system only (no
# AX20_ROOT, systemd present, a running session in /run/user/<uid>);
# AX20_NO_RESTART=1 disables it.
ax20_restart_user_audio() {
    local user=$1 uid
    set -- pipewire.service pipewire-pulse.service wireplumber.service
    if [ -n "$AX20_ROOT" ] || [ "${AX20_NO_RESTART:-0}" = 1 ]; then
        log_debug "not restarting $* for $user (fixture root or AX20_NO_RESTART)"
        return 0
    fi
    ax20_have systemctl || return 0
    uid=$(id -u "$user" 2>/dev/null) || return 0
    if [ ! -d "/run/user/$uid" ]; then
        log_info "$user has no running session; the audio change applies at next login"
        return 0
    fi
    if ax20_is_root; then
        ax20_run systemctl --user -M "$user@" restart "$@" \
            || log_warn "could not restart $* for $user; log out and back in"
    else
        ax20_run systemctl --user restart "$@" \
            || log_warn "could not restart $*; log out and back in"
    fi
}
