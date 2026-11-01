# SPDX-License-Identifier: GPL-2.0-only
# components/power.sh — Steam's TDP limit slider and power profiles on the
# ROG Xbox Ally X20 (docs/power.md).
#
# Two things are missing on stock SteamOS 3.9.5 and both are needed:
#   1. kernel: Valve's asus-armoury has no RC74XA power_limits entry, so the
#      ppt_* firmware attributes return ENODEV. Fixed by patch 0020 and the
#      asus-armoury line in patches/kernel/modules-power.list; the modules
#      component builds, stages and loads it like every other patched module.
#      This component only reports on it.
#   2. steamos-manager 26.4.1 has no RC74XA device file, so it exposes no
#      TdpLimit1 / PerformanceProfile1 interface. This component owns that
#      part (all through the manifest):
#        /etc/ally-x20-steamos/steamos-manager/90-ally-x20-steamos-rc74xa.toml
#            the device entry (upstream values, stock 26.4.1 schema)
#        /etc/ally-x20-steamos/steamos-manager-devices-shim
#            start/stop helper: copies the stock device dir to /run, adds the
#            entry, bind-mounts the copy over /usr/share/steamos-manager/devices
#        /etc/systemd/system/ally-x20-steamos-power-devices.service
#            runs the helper before both steamos-manager daemons
#        .../multi-user.target.wants/ and .../steamos-manager.service.wants/
#            enable links (manifest symlinks, not `systemctl enable`)
#      A bind mount writes nothing under /usr; the helper steps aside by
#      itself at every boot once a stock device file lists RC74XA.

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="Steam TDP slider + power profiles: RC74XA steamos-manager device entry (bind-mount shim); asus-armoury limits via modules"

POWER_UNIT="${AX20_NAME}-power-devices.service"
POWER_TOML_NAME="90-${AX20_NAME}-rc74xa.toml"
POWER_TOML_REL="${AX20_EARLY_REL}/steamos-manager/${POWER_TOML_NAME}"
POWER_SHIM_REL="${AX20_EARLY_REL}/steamos-manager-devices-shim"
POWER_STOCK_DEVICES=/usr/share/steamos-manager/devices
POWER_STATE_REL="/run/${AX20_NAME}/steamos-manager-devices.state"
POWER_ARMOURY_ATTRS=/sys/class/firmware-attributes/asus-armoury/attributes
# auto = run systemctl only on a live system (empty AX20_ROOT); never = skip;
# always = run even with a root prefix (tests, with stub commands on PATH).
AX20_POWER_SYSTEM_STEPS="${AX20_POWER_SYSTEM_STEPS:-auto}"

power_files() {
    # No steamos-manager at all: nothing would read the entry.
    [ -d "$(ax20_path "$POWER_STOCK_DEVICES")" ] || return 0
    printf 'steamos-manager/devices/%s\t%s\t0644\n' "$POWER_TOML_NAME" "$POWER_TOML_REL"
    printf 'bin/steamos-manager-devices-shim\t%s\t0755\n' "$POWER_SHIM_REL"
    printf 'systemd/%s\t/etc/systemd/system/%s\t0644\n' "$POWER_UNIT" "$POWER_UNIT"
}

# power_stock_has_board : a stock steamos-manager device file (not one of
# ours, which the bind mount puts in the same directory) lists RC74XA.
power_stock_has_board() {
    local f
    for f in "$(ax20_path "$POWER_STOCK_DEVICES")"/*.toml; do
        [ -f "$f" ] || continue
        case "${f##*/}" in *"$AX20_NAME"*) continue ;; esac
        grep -q "\"$AX20_BOARD\"" "$f" && return 0
    done
    return 1
}

# power_probe : 0 = stock steamos-manager already has an RC74XA device file
# (superseded), 1 = still needed, 2 = no steamos-manager device directory.
power_probe() {
    [ -d "$(ax20_path "$POWER_STOCK_DEVICES")" ] || return "$PROBE_UNKNOWN"
    power_stock_has_board && return "$PROBE_YES"
    return "$PROBE_NO"
}

# power_kernel_limits : one line about the asus-armoury power limits.
# Returns 0 when ppt_pl1_spl is readable (the kernel side works), 1 when the
# attribute exists but cannot be read (ENODEV: no RC74XA power_limits entry
# in the loaded module), 2 when asus-armoury or the attribute is absent.
power_kernel_limits() {
    local base cur min max
    base=$(ax20_path "$POWER_ARMOURY_ATTRS")
    if [ ! -d "$base" ]; then
        printf 'asus-armoury not loaded (%s missing)\n' "$POWER_ARMOURY_ATTRS"
        return 2
    fi
    if [ ! -d "$base/ppt_pl1_spl" ]; then
        printf 'asus-armoury has no ppt_pl1_spl attribute\n'
        return 2
    fi
    if ! cur=$(cat "$base/ppt_pl1_spl/current_value" 2>/dev/null) || [ -z "$cur" ]; then
        printf 'no %s power limits in the loaded asus-armoury (ppt_pl1_spl reads fail): stage the patched module (%s rebuild) and reboot\n' "$AX20_BOARD" "$AX20_NAME"
        return 1
    fi
    min=$(cat "$base/ppt_pl1_spl/min_value" 2>/dev/null || echo '?')
    max=$(cat "$base/ppt_pl1_spl/max_value" 2>/dev/null || echo '?')
    printf 'SPL %s W (range %s..%s W)\n' "$cur" "$min" "$max"
    return 0
}

# power_shim_state : the state word the helper wrote at its last run.
power_shim_state() {
    local f
    f=$(ax20_path "$POWER_STATE_REL")
    if [ -f "$f" ]; then
        head -n 1 "$f"
    else
        printf 'not run\n'
    fi
}

# power_probe_details : key=value lines for `probe`/`status --verbose`.
power_probe_details() {
    local dev
    if ! [ -d "$(ax20_path "$POWER_STOCK_DEVICES")" ]; then
        dev="no steamos-manager device directory"
    elif power_stock_has_board; then
        dev="stock lists $AX20_BOARD (shim not needed)"
    else
        dev="stock lacks $AX20_BOARD"
    fi
    printf 'steamos_manager_devices=%s\n' "$dev"
    printf 'shim=%s\n' "$(power_shim_state)"
    printf 'asus_armoury=%s\n' "$(power_kernel_limits || true)"
}

# _power_system_steps : should we touch the running system (systemctl)?
_power_system_steps() {
    case "$AX20_POWER_SYSTEM_STEPS" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [ -z "$AX20_ROOT" ]
}

# _power_session_user : the account whose steamos-manager user daemon is
# restarted ($AX20_POWER_USER, else $SUDO_USER, else deck).
_power_session_user() {
    if [ -n "${AX20_POWER_USER:-}" ]; then
        printf '%s\n' "$AX20_POWER_USER"
    elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        printf '%s\n' "$SUDO_USER"
    else
        printf 'deck\n'
    fi
}

# _power_restart_steamos_manager : both daemons cache the device file at
# start, so restart the running ones (try-restart leaves stopped ones alone).
_power_restart_steamos_manager() {
    local user uid
    ax20_run systemctl try-restart steamos-manager.service \
        || log_warn "power: restarting steamos-manager.service failed; reboot to apply"
    user=$(_power_session_user)
    uid=$(id -u "$user" 2>/dev/null) || {
        log_info "power: no user $user; the session's steamos-manager picks up the change at next login"
        return 0
    }
    if [ ! -d "$(ax20_path "/run/user/$uid")" ]; then
        log_info "power: $user has no running session; the change applies at next login"
        return 0
    fi
    ax20_run systemctl --user -M "$user@" try-restart steamos-manager.service \
        || log_warn "power: could not restart $user's steamos-manager; log out and back in (or reboot)"
}

power_apply() {
    local rc=0 msg
    power_probe || rc=$?
    case "$rc" in
        "$PROBE_UNKNOWN")
            log_warn "power: $POWER_STOCK_DEVICES not found (no steamos-manager); nothing to do"
            return 0
            ;;
        "$PROBE_YES")
            log_warn "power: stock steamos-manager already lists $AX20_BOARD; the shim mounts nothing. Run '$AX20_NAME uninstall --superseded' to remove it."
            ;;
    esac
    manifest_install_symlink "../$POWER_UNIT" \
        "/etc/systemd/system/multi-user.target.wants/$POWER_UNIT" power
    manifest_install_symlink "../$POWER_UNIT" \
        "/etc/systemd/system/steamos-manager.service.wants/$POWER_UNIT" power
    if msg=$(power_kernel_limits); then
        log_info "power: asus-armoury: $msg"
    else
        log_warn "power: asus-armoury: $msg"
    fi
    if ! _power_system_steps; then
        log_info "power: root prefix in use; skipping systemctl (the unit starts at the next boot of that root)"
        return 0
    fi
    if ! ax20_have systemctl; then
        log_warn "power: systemctl not found; reboot to start $POWER_UNIT"
        return 0
    fi
    ax20_run systemctl daemon-reload || log_warn "power: systemctl daemon-reload failed"
    if ! ax20_run systemctl restart "$POWER_UNIT"; then
        log_warn "power: $POWER_UNIT failed to start; see: journalctl -u $POWER_UNIT"
        return 0
    fi
    _power_restart_steamos_manager
    return 0
}

power_remove() {
    local shim
    if ! _power_system_steps; then
        return 0
    fi
    if ax20_have systemctl; then
        ax20_run systemctl stop "$POWER_UNIT" || log_warn "power: stopping $POWER_UNIT failed"
    fi
    # The unit's ExecStop unmounts; run the helper too in case the unit was
    # never loaded (daemon-reload missing) or its stop failed.
    shim=$(ax20_path "$POWER_SHIM_REL")
    if [ -x "$shim" ]; then
        ax20_run env AX20_ROOT="$AX20_ROOT" "$shim" stop || log_warn "power: the shim's stop failed; reboot to drop the bind mount"
    fi
    if ax20_have systemctl; then
        _power_restart_steamos_manager
    fi
    # The unit, the helper, the device entry and the enable links are
    # manifest entries; uninstall removes them and runs daemon-reload.
    return 0
}
