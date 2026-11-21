# SPDX-License-Identifier: GPL-2.0-only
# summary: show what is installed, what is stock and what SteamOS now provides (--json, --verbose)
#
# The LAST APPLY column is what the last `apply` (or boot re-apply) did to
# the component: applied, unchanged, failed, skipped, or "-" when there is
# no record; failures are listed with their reason under the table. It
# comes from state/last-apply.json (lib/lastapply.sh).
# When the patched kernel modules for the running kernel are a partial
# build, the modules that are patched and the ones left stock are listed.
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

# _status_modules_human : the "modules staged for it" value.
_status_modules_human() {
    local counts
    counts=$(printf '%s\n' "$_ST_MODULES_STATES" | awk -F'\t' '
        $2 == "patched" { p++ } $2 == "stock" { s++ } $2 == "superseded" { u++ }
        END { printf "%d patched, %d stock, %d already in this kernel", p, s, u }')
    case "$_ST_MODULES_KIND" in
        partial) printf 'partial (%s)\n' "$counts" ;;
        stock) printf 'none usable (%s)\n' "$counts" ;;
        *) printf '%s\n' "$_ST_MODULES" ;;
    esac
}

# _status_render_modules : one line per listed module for the staged build.
_status_render_modules() {
    local name st detail
    printf '\nKernel modules for %s:\n' "$_ST_KVER"
    printf '%s\n' "$_ST_MODULES_STATES" | while IFS='	' read -r name st detail; do
        [ -n "$name" ] || continue
        case "$st" in
            patched) printf '  %-28s patched%s\n' "$name" "${detail:+ ($detail)}" ;;
            superseded) printf '  %-28s stock (already fixed in this kernel)\n' "$name" ;;
            stock) printf '  %-28s stock: %s\n' "$name" "${detail:-not built}" ;;
            *) printf '  %-28s stock (not in the staged build)\n' "$name" ;;
        esac
    done
    case "$_ST_MODULES_KIND" in
        partial | stock)
            printf '  Some patches do not apply to this kernel. Only SteamOS stable is supported;\n'
            printf '  on other channels the parts that do not fit are left out, without support.\n'
            ;;
    esac
}

# _status_render_last_apply : where the record is, and the failures in it.
_status_render_last_apply() {
    local name outcome when command reason
    if [ -z "$_ST_LA_WHEN" ]; then
        return 0
    fi
    printf '\nLast apply: %s by "%s": %s (record: %s)\n' "$_ST_LA_WHEN" "$_ST_LA_COMMAND" \
        "$([ "$_ST_LA_RESULT" = failed ] && echo 'some components failed' || echo ok)" "$(la_file)"
    printf '%s\n' "$_ST_LA_ROWS" | while IFS='	' read -r name outcome when command reason; do
        [ "$outcome" = failed ] || continue
        printf '  %s failed (%s, "%s"): %s\n' "$name" "$when" "$command" "${reason:-no reason recorded}"
    done
}

_status_render_text() {
    local verbose=$1 name st desc la
    printf '%s %s%s\n' "$AX20_NAME" "$_ST_VERSION" "${_ST_COMMIT:+ ($_ST_COMMIT)}"
    printf '  %-24s %s\n' "running kernel:" "$_ST_KVER"
    printf '  %-24s %s\n' "modules staged for it:" "$(_status_modules_human)"
    printf '  %-24s %s\n' "update policy:" "$_ST_POLICY"
    printf '  %-24s %s\n' "pending reboot check:" "$_ST_PENDING"
    printf '  %-24s %s\n' "last self-update check:" "$(_status_lastcheck_human)"
    printf '\n%-16s %-11s %-11s %s\n' COMPONENT STATUS 'LAST APPLY' DESCRIPTION
    if [ -z "$_ST_COMPONENTS" ]; then
        printf '(no components)\n'
        return 0
    fi
    printf '%s' "$_ST_COMPONENTS" | while IFS='	' read -r name st desc; do
        [ -n "$name" ] || continue
        la=$(_status_la_field "$name" 2)
        printf '%-16s %-11s %-11s %s\n' "$name" "$st" "${la:--}" "$desc"
        if [ "$verbose" = 1 ]; then
            (
                component_load "$name"
                if declare -F "${name}_probe_details" >/dev/null 2>&1; then
                    "${name}_probe_details" 2>&1 | sed 's/^/    /'
                fi
            ) 2>/dev/null || true
        fi
    done
    # A complete build needs no list here (--verbose shows one under the
    # modules row, from modules_probe_details).
    case "$_ST_MODULES_KIND" in
        partial | stock) _status_render_modules ;;
    esac
    _status_render_last_apply
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
