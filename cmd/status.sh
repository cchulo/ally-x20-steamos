# SPDX-License-Identifier: GPL-2.0-only
# summary: show what is installed, what is stock and what SteamOS now provides (--json, --verbose)
#
# Always exits 0 unless something internal breaks: a component whose status
# cannot be computed is shown as "error" instead of aborting the table.
# Writes state/status.json (atomically) on every run when the state
# directory exists and is writable, through lib/status.sh (the single
# writer shared with apply and the boot service).
# shellcheck source=lib/status.sh
. "$AX20_SRC/lib/status.sh"

_status_lastcheck_human() {
    if [ -z "$_ST_LASTCHECK" ]; then
        printf 'never\n'
        return 0
    fi
    # "<iso-ts>\t<epoch>\t<result>\t<ref>" (cmd/self-update.sh)
    printf '%s\n' "$_ST_LASTCHECK" | awk -F'\t' '{ s = $1 " (" $3; if ($4 != "") s = s " " $4; print s ")" }'
}

_status_render_text() {
    local verbose=$1 name st desc
    printf '%s %s%s\n' "$AX20_NAME" "$_ST_VERSION" "${_ST_COMMIT:+ ($_ST_COMMIT)}"
    printf '  %-24s %s\n' "running kernel:" "$_ST_KVER"
    printf '  %-24s %s\n' "modules staged for it:" "$_ST_MODULES"
    printf '  %-24s %s\n' "update policy:" "$_ST_POLICY"
    printf '  %-24s %s\n' "pending reboot check:" "$_ST_PENDING"
    printf '  %-24s %s\n' "last self-update check:" "$(_status_lastcheck_human)"
    printf '  %-24s %s\n' "audio DSP:" "$_ST_DSP"
    printf '\n%-16s %-11s %s\n' COMPONENT STATUS DESCRIPTION
    if [ -z "$_ST_COMPONENTS" ]; then
        printf '(no components)\n'
        return 0
    fi
    printf '%s' "$_ST_COMPONENTS" | while IFS='	' read -r name st desc; do
        [ -n "$name" ] || continue
        printf '%-16s %-11s %s\n' "$name" "$st" "$desc"
        if [ "$verbose" = 1 ]; then
            (
                component_load "$name"
                if declare -F "${name}_probe_details" >/dev/null 2>&1; then
                    "${name}_probe_details" 2>&1 | sed 's/^/    /'
                fi
            ) 2>/dev/null || true
        fi
    done
}

# _status_write_file : state/status.json via lib/status.sh; never fatal.
_status_write_file() {
    local base
    [ "$AX20_DRY_RUN" = 1 ] && return 0
    base=$(ax20_state_dir)
    [ -d "$base" ] && [ -w "$base" ] || return 0
    status_write_json last_command status || log_warn "could not write $AX20_STATUS_JSON_REL"
}

cmd_status() {
    local json=0 verbose=$AX20_VERBOSE dest
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=1 ;;
            --verbose | -v) verbose=1 ;;
            -h | --help)
                printf 'usage: %s status [--json] [--verbose]\n' "$AX20_NAME"
                return 0
                ;;
            *) die 2 "status: unknown argument '$1'" ;;
        esac
        shift
    done
    status_collect
    _status_write_file
    if [ "$json" = 1 ]; then
        status_render_json last_command status
    else
        _status_render_text "$verbose"
    fi
    return 0
}
