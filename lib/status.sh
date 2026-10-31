# SPDX-License-Identifier: GPL-2.0-only
# lib/status.sh — collect the facts `status` shows and write state/status.json,
# the machine-readable summary that `apply`, the boot service, the notifier
# and (later) the Decky plugin read. One writer, one shape:
#
#   {
#     "name": "ally-x20-steamos", "version": "0.1.0-dev", "commit": "abc1234",
#     "generated": "<iso>",
#     "kernel": { "running": "<kver>", "modules_staged": true|false },
#     "update_policy": "block|degrade", "pending_reboot_check": true|false,
#     "last_update_check": { "ts", "result", "ref" } | null,
#     "audio_dsp": "on|off|not configured|unknown",
#     "kver": "<kver>", "slot": "A|B|",          # compatibility keys
#     "<extra key>": "<extra value>", ...        # from the caller
#     "components": [ { "name", "status", "description" }, ... ]
#   }
#
# Usage:
#   status_collect                           # fill the _ST_* facts
#   status_render_json [key value]...        # print the document
#   status_write_json [key value]...         # collect + atomically write the file

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"
# shellcheck source=lib/selfupdate.sh
. "$AX20_SRC/lib/selfupdate.sh"
# shellcheck source=lib/slots.sh
. "$AX20_SRC/lib/slots.sh"

# Collected facts, filled by status_collect (plain variables: bash 3.2).
_ST_VERSION="" _ST_COMMIT="" _ST_KVER="" _ST_MODULES="" _ST_POLICY="" _ST_PENDING=""
_ST_LASTCHECK="" _ST_DSP="" _ST_COMPONENTS=""

# status_deck_home : home directory of the deck user inside the root.
status_deck_home() {
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

# status_audio_dsp : on | off | not configured | unknown, from the file the
# audio_dsp component writes (~deck/.config/ally-x20-steamos/audio-dsp.conf).
# Accepted keys: enabled= / state= / dsp= with on|off|1|0|true|false|yes|no.
status_audio_dsp() {
    local f v
    f=$(ax20_path "$(status_deck_home)/.config/${AX20_NAME}/audio-dsp.conf")
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

status_collect() {
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
    _ST_DSP=$(status_audio_dsp)
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

status_render_json() {
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
    # Compatibility keys used by apply/boot consumers and tests.
    printf '  "kver": %s,\n' "$(su_json_str "$_ST_KVER")"
    printf '  "slot": %s,\n' "$(su_json_str "$(slots_active 2>/dev/null || true)")"
    # Caller-supplied extras (last_command, reapplied, failed, ...).
    while [ $# -ge 2 ]; do
        printf '  %s: %s,\n' "$(su_json_str "$1")" "$(su_json_str "$2")"
        shift 2
    done
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

# status_write_json [key value]... : collect and atomically (re)write
# state/status.json. Never fatal (the state dir may not exist yet).
status_write_json() {
    local f
    f=$(ax20_path "$AX20_STATUS_JSON_REL")
    [ "$AX20_DRY_RUN" = 1 ] && return 0
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    status_collect
    status_render_json "$@" | ax20_atomic_write "$f" 0644
}
