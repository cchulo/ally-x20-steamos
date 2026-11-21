# SPDX-License-Identifier: GPL-2.0-only
# components/controlcenter.sh — the privileged path of the Control Center UI
# (docs/control-center.md): a root-owned helper with a closed list of
# operations, and a sudoers drop-in that lets the session user run exactly
# those without a password, so Game Mode never has to ask for one.
#
# Files:
#   /etc/ally-x20-steamos/control-center-helper          the helper (overlay/bin)
#   /etc/sudoers.d/zz-ally-x20-steamos-control-center    the NOPASSWD rule, 0440
#
# Opt-in: a plain `apply`/`install` does not install this. Turn it on with
#   ally-x20-steamos apply --only controlcenter
# and off with
#   ally-x20-steamos uninstall --component controlcenter
# Once on, it is re-applied like every other component (boot service,
# SteamOS updates).
#
# The drop-in is not in controlcenter_files on purpose: component_apply
# copies that list before <name>_apply runs, and the drop-in must be
# checked with `visudo -cf` BEFORE it reaches /etc/sudoers.d. A sudoers file
# with a syntax error makes sudo refuse every command. No visudo, or a
# failed check, means nothing is installed there.

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="Control Center: root helper with a fixed list of operations and the passwordless sudo rule for it (opt-in)"
# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_OPT_IN=1

CONTROLCENTER_HELPER_REL="${AX20_EARLY_REL}/control-center-helper"
CONTROLCENTER_SUDOERS_SRC="sudoers.d/zz-${AX20_NAME}-control-center"
CONTROLCENTER_SUDOERS_REL="/etc/sudoers.d/zz-${AX20_NAME}-control-center"
export CONTROLCENTER_HELPER_REL CONTROLCENTER_SUDOERS_SRC CONTROLCENTER_SUDOERS_REL

controlcenter_files() {
    printf 'bin/control-center-helper\t%s\t0755\n' "$CONTROLCENTER_HELPER_REL"
}

# Stock SteamOS has nothing like it: always "needed" (it is opt-in, so that
# only matters once the owner has turned it on).
controlcenter_probe() {
    return "$PROBE_NO"
}

controlcenter_probe_details() {
    if [ -f "$(ax20_path "$CONTROLCENTER_SUDOERS_REL")" ]; then
        printf 'passwordless sudo rule: installed (%s)\n' "$CONTROLCENTER_SUDOERS_REL"
    else
        printf 'passwordless sudo rule: not installed (enable with: %s apply --only controlcenter)\n' "$AX20_NAME"
    fi
}

# _controlcenter_system_steps : check the whole live sudo configuration only
# on a live system (auto), never, or always (tests, with a stub visudo).
_controlcenter_system_steps() {
    case "${AX20_CONTROLCENTER_SYSTEM_STEPS:-auto}" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [ -z "$AX20_ROOT" ]
}

# _controlcenter_withdraw : take the drop-in out again (file and manifest
# entry). Used when the live configuration does not parse with it.
_controlcenter_withdraw() {
    rm -f "$(ax20_path "$CONTROLCENTER_SUDOERS_REL")"
    manifest_forget "$CONTROLCENTER_SUDOERS_REL"
}

controlcenter_apply() {
    local src="$AX20_SRC/overlay/$CONTROLCENTER_SUDOERS_SRC"
    [ -f "$src" ] || die "controlcenter: overlay file missing: overlay/$CONTROLCENTER_SUDOERS_SRC"
    ax20_have visudo \
        || die "controlcenter: visudo not found, so the sudoers drop-in cannot be checked; not installing it"
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] visudo -cf %s\n' "$src" >&2
    elif ! visudo -cf "$src" >/dev/null 2>&1; then
        die "controlcenter: visudo rejected overlay/$CONTROLCENTER_SUDOERS_SRC; not installing it (sudo is untouched)"
    fi
    manifest_install_file "$src" "$CONTROLCENTER_SUDOERS_REL" controlcenter 0440
    if [ "$AX20_DRY_RUN" != 1 ] && _controlcenter_system_steps; then
        # Second check, of the configuration sudo will really read (the main
        # file plus every drop-in, with owner and mode).
        if ! visudo -c >/dev/null 2>&1; then
            _controlcenter_withdraw
            die "controlcenter: 'visudo -c' fails with the drop-in in place; removed it again. Check the sudo configuration with: sudo visudo -c"
        fi
    fi
    return 0
}
