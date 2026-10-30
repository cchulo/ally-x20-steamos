# SPDX-License-Identifier: GPL-2.0-only
# summary: show what is installed, what is stock and what SteamOS now provides (--json, --verbose)
#
# Always exits 0 unless something internal breaks: a component whose status
# cannot be computed is shown as "error" instead of aborting the table.
# Writes state/status.json (atomically) on every run when the state
# directory exists and is writable. If lib/status.sh (slots/RAUC package)
# provides status_write_json, that writer is used instead of ours.
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"
# shellcheck source=lib/selfupdate.sh
. "$AX20_SRC/lib/selfupdate.sh"
if [ -f "$AX20_SRC/lib/status.sh" ]; then
    # shellcheck disable=SC1091
    . "$AX20_SRC/lib/status.sh"
fi

# Collected facts, filled by _status_collect (plain variables: bash 3.2).
_ST_VERSION="" _ST_COMMIT="" _ST_KVER="" _ST_MODULES="" _ST_POLICY="" _ST_PENDING=""
_ST_LASTCHECK="" _ST_DSP="" _ST_COMPONENTS=""

# _status_deck_home : home directory of the deck user inside the root.
_status_deck_home() {
    local h=""
    if [ -n "${AX20_DECK_HOME:-}" ]; then
        printf '%s\n' "$AX20_DECK_HOME"
        return 0
    fi
    if [ -f "$(ax20_path /etc/passwd)" ]; then
        h=$(awk -F: '$1 == "deck" { print $6; exit }' "$(ax20_path /etc/passwd)")
    fi
    printf '%s\n' "${h:-/home/deck}"
}

# _status_audio_dsp : on | off | not configured | unknown, from the file the
# audio_dsp component writes (~deck/.config/ally-x20-steamos/audio-dsp.conf).
# Accepted keys: enabled= / state= / dsp= with on|off|1|0|true|false|yes|no.
_status_audio_dsp() {
    local f v
    f=$(ax20_path "$(_status_deck_home)/.config/${AX20_NAME}/audio-dsp.conf")
    if [ ! -f "$f" ]; then
        printf 'not configured\n'
        return 0
    fi
    v=$(sed -nE 's/^[[:space:]]*(enabled|state|dsp)[[:space:]]*=[[:space:]]*"?([A-Za-z0-9]*).*/\2/p' "$f" | head -n1)
    [ -n "$v" ] || v=$(sed -nE 's/^[[:space:]]*([A-Za-z0-9]+)[[:space:]]*$/\1/p' "$f" | head -n1)
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
        on | 1 | true | yes | enabled) printf 'on\n' ;;
        off | 0 | false | no | disabled) printf 'off\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

_status_collect() {
    local c st desc
    _ST_VERSION=$(cat "$AX20_SRC/VERSION" 2>/dev/null || echo unknown)
    _ST_COMMIT=""
    if ax20_have git && git -C "$AX20_SRC" rev-parse --short HEAD >/dev/null 2>&1; then
        _ST_COMMIT=$(git -C "$AX20_SRC" rev-parse --short HEAD)
    fi
    _ST_KVER=$(probe_running_kver 2>/dev/null || echo unknown)
    if [ -f "$(ax20_path "${AX20_STATE_REL}/modules/${_ST_KVER}/BUILD-INFO")" ]; then
        _ST_MODULES=yes
    else
        _ST_MODULES=no
    fi
    _ST_POLICY=$(su_read_state update-policy block | awk '{ print $1 }')
    if [ -e "$(su_state_file pending-reboot-check)" ]; then
        _ST_PENDING=yes
    else
        _ST_PENDING=no
    fi
    _ST_LASTCHECK=$(su_read_state last-update-check "")
    _ST_DSP=$(_status_audio_dsp)
    # One "name<TAB>status<TAB>description" line per component. Each runs in
    # a subshell so a broken component cannot abort the whole report.
    _ST_COMPONENTS=""
    for c in $(component_list); do
        st=$( (component_status "$c") 2>/dev/null) || st=error
        [ -n "$st" ] || st=error
        desc=$( (component_description "$c") 2>/dev/null) || desc=""
        _ST_COMPONENTS="${_ST_COMPONENTS}${c}	${st}	${desc}
"
    done
}

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

_status_render_json() {
    local first=1 name st desc lc_ts="" lc_result="" lc_ref=""
    if [ -n "$_ST_LASTCHECK" ]; then
        lc_ts=$(printf '%s\n' "$_ST_LASTCHECK" | cut -f1)
        lc_result=$(printf '%s\n' "$_ST_LASTCHECK" | cut -f3)
        lc_ref=$(printf '%s\n' "$_ST_LASTCHECK" | cut -f4)
    fi
    printf '{\n'
    printf '  "name": %s,\n' "$(su_json_str "$AX20_NAME")"
    printf '  "version": %s,\n' "$(su_json_str "$_ST_VERSION")"
    printf '  "commit": %s,\n' "$(su_json_str "$_ST_COMMIT")"
    printf '  "generated": %s,\n' "$(su_json_str "$(su_now_iso)")"
    printf '  "kernel": { "running": %s, "modules_staged": %s },\n' \
        "$(su_json_str "$_ST_KVER")" "$([ "$_ST_MODULES" = yes ] && echo true || echo false)"
    printf '  "update_policy": %s,\n' "$(su_json_str "$_ST_POLICY")"
    printf '  "pending_reboot_check": %s,\n' "$([ "$_ST_PENDING" = yes ] && echo true || echo false)"
    if [ -n "$lc_ts" ]; then
        printf '  "last_update_check": { "ts": %s, "result": %s, "ref": %s },\n' \
            "$(su_json_str "$lc_ts")" "$(su_json_str "$lc_result")" "$(su_json_str "$lc_ref")"
    else
        printf '  "last_update_check": null,\n'
    fi
    printf '  "audio_dsp": %s,\n' "$(su_json_str "$_ST_DSP")"
    printf '  "components": ['
    while IFS='	' read -r name st desc; do
        [ -n "$name" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        printf '\n    { "name": %s, "status": %s, "description": %s }' \
            "$(su_json_str "$name")" "$(su_json_str "$st")" "$(su_json_str "$desc")"
    done <<EOF
$_ST_COMPONENTS
EOF
    [ "$first" = 1 ] || printf '\n  '
    printf ']\n}\n'
}

# _status_write_file : state/status.json, atomically; never fatal.
_status_write_file() {
    local base dest
    [ "$AX20_DRY_RUN" = 1 ] && return 0
    base=$(ax20_state_dir)
    [ -d "$base" ] && [ -w "$base" ] || return 0
    dest=$(ax20_path "$AX20_STATUS_JSON_REL")
    if declare -F status_write_json >/dev/null 2>&1; then
        (status_write_json) >/dev/null 2>&1 && [ -f "$dest" ] && return 0
        log_debug "status_write_json failed; falling back to the built-in writer"
    fi
    (
        mkdir -p "$(dirname "$dest")" && _status_render_json | ax20_atomic_write "$dest" 0644
    ) || log_warn "could not write $AX20_STATUS_JSON_REL"
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
    _status_collect
    _status_write_file
    if [ "$json" = 1 ]; then
        dest=$(ax20_path "$AX20_STATUS_JSON_REL")
        if declare -F status_write_json >/dev/null 2>&1 && [ -f "$dest" ] && [ "$AX20_DRY_RUN" != 1 ]; then
            cat "$dest"
        else
            _status_render_json
        fi
    else
        _status_render_text "$verbose"
    fi
    return 0
}
