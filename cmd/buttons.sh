# SPDX-License-Identifier: GPL-2.0-only
# summary: what the Armoury Crate and action buttons do: status | layout [deck|legacy]
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

_buttons_usage() {
    cat <<USAGE
usage: $AX20_NAME buttons <command>

  status                 the layout in use and whether it applies
  layout [deck|legacy]   without a value: print the setting.
                         deck (default): action button (top right) opens
                         Steam's Quick Access menu, Armoury Crate (top left)
                         is the Steam button. Screenshot: Xbox button + R1.
                         legacy: Armoury Crate opens Quick Access, the action
                         button takes a screenshot (the layout up to v0.1.11).
                         The Xbox button is the Steam button in both.
                         Installs the matching InputPlumber button map and
                         restarts inputplumber.service (as apply --only
                         inputplumber); the controller drops out for a moment

See docs/inputplumber.md, section 6.
USAGE
}

cmd_buttons() {
    component_load inputplumber
    case "${1:-}" in
        status) _buttons_cmd_status ;;
        layout)
            shift
            _buttons_cmd_layout "$@"
            ;;
        -h | --help | help) _buttons_usage ;;
        '')
            _buttons_usage >&2
            return 2
            ;;
        *)
            log_error "unknown buttons command: $1"
            _buttons_usage >&2
            return 2
            ;;
    esac
}

# _buttons_applies : the layout only reaches the buttons through the button
# map, which is installed with the stock-adapted profile.
_buttons_applies() {
    [ "$(inputplumber_variant)" = stock ]
}

_buttons_cmd_status() {
    printf 'status: %s\n' "$(component_status inputplumber)"
    printf 'layout=%s\n' "$(inputplumber_button_layout_describe)"
    if _buttons_applies; then
        printf 'applies=yes (stock-adapted profile with the %s button map)\n' "$AX20_NAME"
    else
        printf "applies=no (upstream profile with the stock 'aly2' button map: Armoury Crate = Steam+X, action button unmapped)\n"
    fi
}

# _buttons_cmd_layout [deck|legacy] : record the setting and re-apply the
# component (installs the matching button map, restarts the daemon). Only
# while inputplumber is installed: the settings file is a manifest entry of it.
_buttons_cmd_layout() {
    case "${1:-}" in
        '')
            printf 'layout=%s\n' "$(inputplumber_button_layout)"
            return 0
            ;;
        deck | legacy) ;;
        *)
            log_error "usage: $AX20_NAME buttons layout deck|legacy"
            return 2
            ;;
    esac
    require_root buttons layout "$1"
    ax20_check_readonly_root
    if ! component_installed inputplumber; then
        log_error "inputplumber is not installed (status: $(component_status inputplumber)); run '$AX20_NAME apply --only inputplumber' first"
        return 1
    fi
    inputplumber_write_button_settings "$1" || return 1
    component_apply inputplumber || return 1
    if _buttons_applies; then
        log_info "buttons: layout $(inputplumber_button_layout_describe)"
    else
        log_warn "buttons: layout=$1 saved, but the installed profile is the upstream one, which uses the stock 'aly2' button map; the layout has no effect until the stock-adapted profile is in use"
    fi
}
