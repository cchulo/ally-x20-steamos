# SPDX-License-Identifier: GPL-2.0-only
# components/surround.sh — virtual 7.1 surround for the ROG Xbox Ally X20's
# built-in headphone jack and speakers (docs/surround.md).
#
# Stock SteamOS offers the built-in outputs as stereo only, so a game sends
# a stereo mix. This component adds an 8-channel PipeWire sink in front of
# the output in use; it convolves the channels with a head-related impulse
# response set (a "profile") and plays the result on that output.
#
# Files:
#   /etc/ally-x20-steamos/surround/x20-surround      the helper (overlay/bin,
#                                                    python3, stdlib only)
#   /etc/ally-x20-steamos/surround/hrir/*.wav        the shipped sets (four heads,
#                                                    each dry and full)
#   /etc/ally-x20-steamos/surround/NOTICE.md, LICENSE.Apache-2.0
#                                                    their sources and
#                                                    licences
#   /etc/systemd/user/ally-x20-steamos-surround.service
#                                                    the user unit that runs
#                                                    the helper
#   /etc/systemd/user/default.target.wants/...       enable link (manifest
#                                                    symlink, not
#                                                    `systemctl enable`)
# The choice of profile is the user's, not the system's: it lives in
# ~/.config/ally-x20-steamos/surround.conf (written by `surround set`, no
# root needed) and so do the user's own files (surround-user/*.wav). Neither
# is a manifest entry; both survive SteamOS updates with the home directory
# and are left alone by uninstall.
# Stock SteamOS has no virtual surround for these outputs, so the probe
# always says needed.

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="Virtual 7.1 surround for the built-in headphones and speakers (PipeWire filter, switchable profiles; speakers default to stereo)"

SURROUND_DIR_REL="${AX20_EARLY_REL}/surround"
SURROUND_HELPER_REL="${SURROUND_DIR_REL}/x20-surround"
SURROUND_UNIT="${AX20_NAME}-surround.service"
SURROUND_UNIT_REL="/etc/systemd/user/${SURROUND_UNIT}"
SURROUND_HRIRS="sadie-d2-dry hutubs-pp1-dry mit-kemar-dry mit-kemar-large-dry sadie-d2-full hutubs-pp1-full mit-kemar-full mit-kemar-large-full"
export SURROUND_DIR_REL SURROUND_HELPER_REL SURROUND_UNIT SURROUND_UNIT_REL SURROUND_HRIRS

surround_files() {
    local n
    printf 'bin/x20-surround.py\t%s\t0755\n' "$SURROUND_HELPER_REL"
    for n in $SURROUND_HRIRS; do
        printf 'surround/hrir/%s.wav\t%s/hrir/%s.wav\t0644\n' "$n" "$SURROUND_DIR_REL" "$n"
    done
    printf 'surround/NOTICE.md\t%s/NOTICE.md\t0644\n' "$SURROUND_DIR_REL"
    printf 'surround/LICENSE.Apache-2.0\t%s/LICENSE.Apache-2.0\t0644\n' "$SURROUND_DIR_REL"
    printf 'systemd/%s\t%s\t0644\n' "$SURROUND_UNIT" "$SURROUND_UNIT_REL"
}

surround_probe() {
    return "$PROBE_NO"
}

surround_probe_details() {
    printf 'stock SteamOS offers the built-in headphones and speakers as stereo only\n'
    printf "profiles: '%s surround list'; the choice is per user (~/.config/%s/surround.conf)\n" "$AX20_NAME" "$AX20_NAME"
}

# _surround_system_steps : touch the running systemd only on a live system
# (auto), never, or always (tests, with stub commands on PATH).
_surround_system_steps() {
    case "${AX20_SURROUND_SYSTEM_STEPS:-auto}" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [ -z "$AX20_ROOT" ]
}

# _surround_session_user : the account whose user service is (re)started
# ($AX20_SURROUND_USER, else $SUDO_USER, else deck).
_surround_session_user() {
    if [ -n "${AX20_SURROUND_USER:-}" ]; then
        printf '%s\n' "$AX20_SURROUND_USER"
    elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        printf '%s\n' "$SUDO_USER"
    else
        printf 'deck\n'
    fi
}

# _surround_user_systemctl <args...> : systemctl --user in the session of
# the user above; quiet when that user has no running session.
_surround_user_systemctl() {
    local user uid
    user=$(_surround_session_user)
    uid=$(id -u "$user" 2>/dev/null) || {
        log_info "surround: no user $user; the service starts at the next login"
        return 0
    }
    if [ ! -d "$(ax20_path "/run/user/$uid")" ]; then
        log_info "surround: $user has no running session; the service starts at the next login"
        return 0
    fi
    ax20_run systemctl --user -M "$user@" "$@"
}

surround_apply() {
    manifest_install_symlink "../$SURROUND_UNIT" \
        "/etc/systemd/user/default.target.wants/$SURROUND_UNIT" surround
    if ! _surround_system_steps; then
        log_debug "surround: root prefix in use; skipping systemctl (the service starts at the next login)"
        return 0
    fi
    if ! ax20_have systemctl; then
        log_warn "surround: systemctl not found; the service starts at the next login"
        return 0
    fi
    _surround_user_systemctl daemon-reload || log_warn "surround: daemon-reload in the user session failed"
    _surround_user_systemctl restart "$SURROUND_UNIT" \
        || log_warn "surround: could not start $SURROUND_UNIT; it starts at the next login (journalctl --user -u $SURROUND_UNIT)"
    return 0
}

surround_remove() {
    _surround_system_steps || return 0
    ax20_have systemctl || return 0
    # Stop it while the helper is still there; the filter goes with it and
    # the plain hardware output is the default again.
    _surround_user_systemctl stop "$SURROUND_UNIT" || log_warn "surround: stopping $SURROUND_UNIT failed"
    return 0
}
