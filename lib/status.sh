# SPDX-License-Identifier: GPL-2.0-only
# lib/status.sh — write state/status.json, the machine-readable summary that
# `apply`, the boot service, the notifier and (later) the Decky plugin read.
#
# Shape (all values are strings; extra top-level keys come from the caller):
#   {
#     "version": "0.1.0 (abc1234)",
#     "ts": "2026-10-30T12:00:00+0000",
#     "kver": "7.2.7-valve2-1-neptune-72-g31504582a073",
#     "slot": "A",                         # "" when unknown
#     "components": { "audio": "active", "hdr": "superseded", ... },
#     "<extra key>": "<extra value>", ...
#   }
# Component values are the `status` vocabulary: active | stock | superseded | n/a.
#
# Usage:
#   status_write_json                       # just the standard keys
#   status_write_json last_command apply    # plus "last_command": "apply"

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"
# shellcheck source=lib/slots.sh
. "$AX20_SRC/lib/slots.sh"

# status_json_escape <string> : JSON string body (no surrounding quotes).
status_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr '\n\r' '  '
}

# status_render_json [key value]... : print the document to stdout.
status_render_json() {
    local c st first=1 slot
    slot=$(slots_active 2>/dev/null || true)
    printf '{\n'
    printf '  "version": "%s",\n' "$(status_json_escape "$(ax20_version)")"
    printf '  "ts": "%s",\n' "$(_ax20_ts)"
    printf '  "kver": "%s",\n' "$(status_json_escape "$(probe_running_kver)")"
    printf '  "slot": "%s",\n' "$slot"
    printf '  "components": {'
    for c in $(component_list); do
        st=$(component_status "$c" 2>/dev/null || printf 'n/a')
        [ "$first" = 1 ] || printf ','
        first=0
        printf '\n    "%s": "%s"' "$c" "$(status_json_escape "$st")"
    done
    [ "$first" = 1 ] || printf '\n  '
    printf '}'
    while [ $# -ge 2 ]; do
        printf ',\n  "%s": "%s"' "$(status_json_escape "$1")" "$(status_json_escape "$2")"
        shift 2
    done
    printf '\n}\n'
}

# status_write_json [key value]... : atomically (re)write state/status.json.
status_write_json() {
    local f
    f=$(ax20_path "$AX20_STATUS_JSON_REL")
    [ "$AX20_DRY_RUN" = 1 ] || mkdir -p "$(dirname "$f")"
    status_render_json "$@" | ax20_atomic_write "$f" 0644
}
