# SPDX-License-Identifier: GPL-2.0-only
# summary: battery charge limit: 100 % unless set in Steam: status | follow | off | <20-100>
#
# With Steam's charge limit off, Steam writes 0 to the battery's charge
# limit attribute, and the X20's firmware takes 0 as a limit of about 80 %.
# Component chargelimit replaces the 0 by 100 and keeps a limit set in
# Steam; this command picks the behaviour (docs/power.md, "Battery charge
# limit").

# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

_charge_limit_usage() {
    cat <<USAGE
usage: $AX20_NAME charge-limit <command>

  status      the setting, the recorded limit and the limit in force
  follow      (default) charge to 100 % unless a limit is set in Steam
              (Settings → Power) or by hand. Steam's limit wins; its "no
              limit" (a 0) is replaced by 100
  <20-100>    use this limit instead of 100: written at boot, after resume
              and whenever Steam writes 0; a limit set in Steam lasts until
              the next boot
  off         write nothing: with Steam's limit off the battery stops at
              about 80 %

follow, off and a number need root and the chargelimit component
('$AX20_NAME apply'). See docs/power.md.
USAGE
}

cmd_charge_limit() {
    component_load chargelimit
    case "${1:-}" in
        status) _charge_limit_status ;;
        follow | off) _charge_limit_set "$@" ;;
        -h | --help | help) _charge_limit_usage ;;
        '')
            _charge_limit_usage >&2
            return 2
            ;;
        *[!0-9]* | 0*)
            log_error "unknown charge-limit command: $1"
            _charge_limit_usage >&2
            return 2
            ;;
        *)
            if [ "${#1}" -gt 3 ] || [ "$1" -lt 20 ] || [ "$1" -gt 100 ]; then
                log_error "charge-limit: $1 is outside 20..100"
                return 2
            fi
            _charge_limit_set "$@"
            ;;
    esac
}

_charge_limit_status() {
    printf 'status: %s\n' "$(component_status chargelimit)"
    chargelimit_probe_details
}

# _charge_limit_set <follow|off|N> : record the setting (a manifest entry of
# the component, so uninstall removes it) and, unless off, let the helper
# act on it now.
_charge_limit_set() {
    local want=$1 tmp helper
    if [ $# -gt 1 ]; then
        log_error "usage: $AX20_NAME charge-limit follow|off|<20-100>"
        return 2
    fi
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] %s <- limit=%s\n' "$CHARGE_LIMIT_CONF_REL" "$want" >&2
        return 0
    fi
    require_root charge-limit "$want"
    ax20_check_readonly_root
    if ! component_installed chargelimit; then
        log_error "chargelimit is not installed (status: $(component_status chargelimit)); run '$AX20_NAME apply --only chargelimit' first"
        return 1
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-charge-limit.XXXXXX") || die "cannot create a temporary file"
    {
        printf "# Written by '%s charge-limit'; read by %s.\n" "$AX20_NAME" "$CHARGE_LIMIT_HELPER_REL"
        printf '# limit=follow | off | 20..100 (docs/power.md, "Battery charge limit")\n'
        printf 'limit=%s\n' "$want"
    } >"$tmp"
    manifest_install_file "$tmp" "$CHARGE_LIMIT_CONF_REL" chargelimit 0644
    rm -f "$tmp"
    case "$want" in
        off)
            log_info "charge-limit: off; nothing is written from now on (with Steam's limit off the battery stops at about 80 %)"
            return 0
            ;;
    esac
    # "resume" writes the limit that now applies, without waiting for
    # anything; the running watch reads the new setting on its next round.
    helper=$(ax20_path "$CHARGE_LIMIT_HELPER_REL")
    if [ -x "$helper" ]; then
        AX20_ROOT="$AX20_ROOT" "$helper" resume 2>/dev/null || true
    fi
    log_info "charge-limit: $want; in force now: $(chargelimit_kernel) %"
}
