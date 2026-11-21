# SPDX-License-Identifier: GPL-2.0-only
# components/chargelimit.sh — keep the ROG Xbox Ally X20 charging to 100 %
# unless a charge limit was set on purpose (docs/power.md, "Battery charge
# limit").
#
# With Steam's charge limit off, Steam writes 0 to the battery's
# charge_control_end_threshold at session start (0 is "no limit" on a Steam
# Deck). This firmware takes only 100 as "no limit": with 0 the controller
# stops charging at about 80 % while Steam shows no limit. Steam can write
# the attribute because component power gives it the RC74XA device entry
# ([battery_charge_limit]). This component replaces a 0 by 100, leaves a
# real limit set in Steam alone, and writes that limit again at boot.
#
# Files:
#   /etc/ally-x20-steamos/charge-limit-restore       the helper (overlay/bin)
#   /etc/systemd/system/ally-x20-steamos-charge-limit.service
#                                                    boot: write the recorded
#                                                    limit, then watch the
#                                                    attribute
#   /etc/systemd/system/ally-x20-steamos-charge-limit-resume.service
#                                                    after every sleep
#   .../multi-user.target.wants/ and the sleep targets' .wants/
#                                                    enable links (manifest
#                                                    symlinks, not
#                                                    `systemctl enable`)
# The settings file /etc/ally-x20-steamos/charge-limit.conf is written by
# `ally-x20-steamos charge-limit follow|off|<20-100>` (cmd/charge-limit.sh)
# as a manifest entry of this component. The record of the last limit is
# state: /var/lib/ally-x20-steamos/state/charge-limit.
# Stock SteamOS does not treat 0 differently on this device, so the probe
# always says needed.

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="Battery charge limit: charge to 100 % unless a limit is set in Steam (Steam's \"no limit\" write of 0 means about 80 % to this firmware)"

CHARGE_LIMIT_HELPER_REL="${AX20_EARLY_REL}/charge-limit-restore"
CHARGE_LIMIT_CONF_REL="${AX20_EARLY_REL}/charge-limit.conf"
CHARGE_LIMIT_STATE_REL="${AX20_STATE_REL}/state/charge-limit"
CHARGE_LIMIT_UNIT="${AX20_NAME}-charge-limit.service"
CHARGE_LIMIT_RESUME_UNIT="${AX20_NAME}-charge-limit-resume.service"
# The sleep targets whose completion means "resumed" (systemd.special(7)).
CHARGE_LIMIT_SLEEP_TARGETS="suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"
export CHARGE_LIMIT_HELPER_REL CHARGE_LIMIT_CONF_REL CHARGE_LIMIT_STATE_REL
export CHARGE_LIMIT_UNIT CHARGE_LIMIT_RESUME_UNIT CHARGE_LIMIT_SLEEP_TARGETS

chargelimit_files() {
    printf 'bin/charge-limit-restore\t%s\t0755\n' "$CHARGE_LIMIT_HELPER_REL"
    printf 'systemd/%s\t/etc/systemd/system/%s\t0644\n' "$CHARGE_LIMIT_UNIT" "$CHARGE_LIMIT_UNIT"
    printf 'systemd/%s\t/etc/systemd/system/%s\t0644\n' "$CHARGE_LIMIT_RESUME_UNIT" "$CHARGE_LIMIT_RESUME_UNIT"
}

chargelimit_probe() {
    return "$PROBE_NO"
}

# chargelimit_setting : follow | off | <20..100>, from limit= in the
# settings file (default follow; the helper applies the same rule).
chargelimit_setting() {
    local f v=""
    f=$(ax20_path "$CHARGE_LIMIT_CONF_REL")
    if [ -f "$f" ]; then
        v=$(sed -n 's/^[[:space:]]*limit[[:space:]]*=[[:space:]]*//p' "$f" | tail -n 1 | tr -d '[:space:]')
    fi
    case "$v" in
        off) printf 'off\n' ;;
        '' | *[!0-9]* | 0*) printf 'follow\n' ;;
        *)
            if [ "$v" -ge 20 ] && [ "$v" -le 100 ]; then
                printf '%s\n' "$v"
            else
                printf 'follow\n'
            fi
            ;;
    esac
}

# chargelimit_recorded : the limit recorded for the next boot, or nothing.
chargelimit_recorded() {
    local f v
    f=$(ax20_path "$CHARGE_LIMIT_STATE_REL")
    [ -r "$f" ] || return 0
    v=$(head -n 1 "$f" | tr -d '[:space:]')
    case "$v" in
        '' | *[!0-9]* | 0*) return 0 ;;
    esac
    [ "$v" -le 100 ] && printf '%s\n' "$v"
    return 0
}

# chargelimit_kernel : the battery's charge_control_end_threshold as the
# kernel reports it, or "n/a". 0 was written by Steam as "no limit"; this
# firmware then stops charging at about 80 %.
chargelimit_kernel() {
    local f
    for f in "$(ax20_path /sys/class/power_supply)"/BAT*/charge_control_end_threshold; do
        [ -r "$f" ] || continue
        cat "$f"
        return 0
    done
    printf 'n/a\n'
}

chargelimit_probe_details() {
    local s r k
    s=$(chargelimit_setting)
    r=$(chargelimit_recorded)
    k=$(chargelimit_kernel)
    case "$s" in
        follow) printf "setting=follow (100%% unless a limit is set in Steam or by hand; a 0 written by Steam becomes 100)\n" ;;
        off) printf 'setting=off (nothing is written)\n' ;;
        *) printf 'setting=%s%% (written at boot and after resume, and whenever the attribute reads 0; a limit set in Steam lasts until then)\n' "$s" ;;
    esac
    if [ -n "$r" ]; then
        printf 'recorded=%s%%\n' "$r"
    else
        printf 'recorded=none yet (100%% is written)\n'
    fi
    case "$k" in
        n/a) printf 'in_force=n/a (no battery with charge_control_end_threshold)\n' ;;
        0) printf "in_force=about 80%% (the attribute reads 0, which this firmware takes as a limit)\n" ;;
        *) printf 'in_force=%s%%\n' "$k" ;;
    esac
}

# _chargelimit_system_steps : touch the running systemd only on a live
# system (auto), never, or always (tests, with stub commands on PATH).
_chargelimit_system_steps() {
    case "${AX20_CHARGE_LIMIT_SYSTEM_STEPS:-auto}" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [ -z "$AX20_ROOT" ]
}

chargelimit_apply() {
    local t
    manifest_install_symlink "../$CHARGE_LIMIT_UNIT" \
        "/etc/systemd/system/multi-user.target.wants/$CHARGE_LIMIT_UNIT" chargelimit
    for t in $CHARGE_LIMIT_SLEEP_TARGETS; do
        manifest_install_symlink "../$CHARGE_LIMIT_RESUME_UNIT" \
            "/etc/systemd/system/$t.wants/$CHARGE_LIMIT_RESUME_UNIT" chargelimit
    done
    if ! _chargelimit_system_steps; then
        log_debug "chargelimit: root prefix in use; skipping systemctl (the unit starts at the next boot of that root)"
        return 0
    fi
    if ! ax20_have systemctl; then
        log_warn "chargelimit: systemctl not found; the limit is written from the next boot on"
        return 0
    fi
    ax20_run systemctl daemon-reload || log_warn "chargelimit: systemctl daemon-reload failed"
    # (Re)start it now: writes the limit at once and starts the watch.
    ax20_run systemctl restart "$CHARGE_LIMIT_UNIT" \
        || log_warn "chargelimit: $CHARGE_LIMIT_UNIT failed to start; see: journalctl -u $CHARGE_LIMIT_UNIT"
    return 0
}

chargelimit_remove() {
    _chargelimit_system_steps || return 0
    ax20_have systemctl || return 0
    # Stop the watch; the limit in force stays until something writes
    # another one (Steam writes 0 again at its next start).
    ax20_run systemctl stop "$CHARGE_LIMIT_UNIT" || log_warn "chargelimit: stopping $CHARGE_LIMIT_UNIT failed"
    return 0
}
