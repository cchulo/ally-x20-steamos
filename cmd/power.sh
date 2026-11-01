# SPDX-License-Identifier: GPL-2.0-only
# summary: Steam power profiles on the X20: status | tdp-slider [on|off]
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

_power_usage() {
    cat <<USAGE
usage: $AX20_NAME power <command>

  status                device entry, shim, TDP slider setting, asus-armoury
  tdp-slider [on|off]   off (default): Steam shows the power profiles only.
                        BIOS RC74XA.303 ignores PPT writes, so a TDP slider
                        would change nothing. on: add [tdp_limit] to the
                        RC74XA steamos-manager entry (slider in the
                        Performance profile), to test after a BIOS update.
                        Re-renders the entry, restarts the shim and both
                        steamos-manager daemons (as apply --only power)

See docs/power.md.
USAGE
}

cmd_power() {
    component_load power
    case "${1:-}" in
        status) _power_cmd_status ;;
        tdp-slider)
            shift
            _power_cmd_tdp_slider "$@"
            ;;
        -h | --help | help) _power_usage ;;
        '')
            _power_usage >&2
            return 2
            ;;
        *)
            log_error "unknown power command: $1"
            _power_usage >&2
            return 2
            ;;
    esac
}

_power_cmd_status() {
    printf 'status: %s\n' "$(component_status power)"
    power_probe_details
}

# _power_cmd_tdp_slider [on|off] : record the setting and re-apply the
# component (renders the entry, restarts the shim and both daemons). Only
# while power is installed: the settings file is a manifest entry of it.
_power_cmd_tdp_slider() {
    case "${1:-}" in
        '')
            printf 'tdp_slider=%s\n' "$(power_tdp_slider)"
            return 0
            ;;
        on | off) ;;
        *)
            log_error "usage: $AX20_NAME power tdp-slider on|off"
            return 2
            ;;
    esac
    require_root power tdp-slider "$1"
    ax20_check_readonly_root
    if ! component_installed power; then
        log_error "power is not installed (status: $(component_status power)); run '$AX20_NAME apply --only power' first"
        return 1
    fi
    power_write_settings "$1"
    component_apply power || return 1
    log_info "tdp-slider: $(power_tdp_slider_describe)"
}
