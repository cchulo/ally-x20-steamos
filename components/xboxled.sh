# SPDX-License-Identifier: GPL-2.0-only
# components/xboxled.sh — restore the ROG Xbox Ally X20's Xbox-button light
# settings at boot, reconnect and resume.
#
# Files:
#   /etc/ally-x20-steamos/xbox-led-restore          the helper (overlay/bin)
#   /etc/udev/rules.d/70-ally-x20-steamos-xbox-led.rules  starts it when the
#                                                    ring LED device appears
#                                                    (boot, reconnect)
#   /etc/systemd/system/ally-x20-steamos-xbox-led-resume.service
#                                                    starts it after every
#                                                    suspend/resume cycle,
#                                                    which produces no udev
#                                                    add event (issue #63)
#   .../suspend.target.wants/ and the other sleep targets' .wants/
#                                                    enable links (manifest
#                                                    symlinks, not
#                                                    `systemctl enable`)
# The settings file /etc/ally-x20-steamos/xbox-led.conf is written by
# `ally-x20-steamos xbox-led brightness|breathe` (cmd/xbox-led.sh) as a
# manifest entry of this component. On/off needs no restore: hid-asus-ally
# patch 0016 keeps it in the power mask it writes at probe.
# Stock SteamOS has nothing for this light, so the probe always says needed.

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="Xbox button light: re-apply brightness and breathing when the controller appears and after resume"

XBOX_LED_HELPER_REL="${AX20_EARLY_REL}/xbox-led-restore"
XBOX_LED_RULE_REL="/etc/udev/rules.d/70-${AX20_NAME}-xbox-led.rules"
XBOX_LED_CONF_REL="${AX20_EARLY_REL}/xbox-led.conf"
XBOX_LED_RESUME_UNIT="${AX20_NAME}-xbox-led-resume.service"
XBOX_LED_RESUME_UNIT_REL="/etc/systemd/system/${XBOX_LED_RESUME_UNIT}"
# The sleep targets whose completion means "resumed" (systemd.special(7)).
XBOX_LED_SLEEP_TARGETS="suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"
export XBOX_LED_HELPER_REL XBOX_LED_RULE_REL XBOX_LED_CONF_REL
export XBOX_LED_RESUME_UNIT XBOX_LED_RESUME_UNIT_REL XBOX_LED_SLEEP_TARGETS

xboxled_files() {
    printf 'bin/xbox-led-restore\t%s\t0755\n' "$XBOX_LED_HELPER_REL"
    printf 'udev/rules.d/70-ally-x20-steamos-xbox-led.rules\t%s\t0644\n' "$XBOX_LED_RULE_REL"
    printf 'systemd/%s\t%s\t0644\n' "$XBOX_LED_RESUME_UNIT" "$XBOX_LED_RESUME_UNIT_REL"
}

xboxled_probe() {
    return "$PROBE_NO"
}

xboxled_probe_details() {
    printf 'stock SteamOS has no control for the Xbox-button light\n'
    if [ -r "$(ax20_path "$XBOX_LED_CONF_REL")" ]; then
        printf 'settings: %s\n' "$(tr '\n' ' ' <"$(ax20_path "$XBOX_LED_CONF_REL")")"
    else
        printf 'settings: none yet (xbox-led brightness|breathe writes them)\n'
    fi
}

# _xboxled_system_steps : touch the running udev and systemd only on a live
# system (auto), never, or always (tests, with stub commands on PATH).
_xboxled_system_steps() {
    case "${AX20_XBOX_LED_SYSTEM_STEPS:-auto}" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [ -z "$AX20_ROOT" ]
}

xboxled_apply() {
    local t
    for t in $XBOX_LED_SLEEP_TARGETS; do
        manifest_install_symlink "../$XBOX_LED_RESUME_UNIT" \
            "/etc/systemd/system/$t.wants/$XBOX_LED_RESUME_UNIT" xboxled
    done
    if ! _xboxled_system_steps; then
        log_debug "xbox-led: root prefix in use; skipping udevadm and systemctl reloads"
        return 0
    fi
    if ax20_have udevadm; then
        ax20_run udevadm control --reload >/dev/null 2>&1 || log_warn "xbox-led: udevadm control --reload failed"
    fi
    if ax20_have systemctl; then
        ax20_run systemctl daemon-reload || log_warn "xbox-led: systemctl daemon-reload failed; $XBOX_LED_RESUME_UNIT runs from the next boot on"
    else
        log_warn "xbox-led: systemctl not found; $XBOX_LED_RESUME_UNIT runs from the next boot on"
    fi
    return 0
}
