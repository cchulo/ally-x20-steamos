# SPDX-License-Identifier: GPL-2.0-only
# summary: check whether stock SteamOS now provides each fix (--verbose, --notify)
#
# Prints "<component>: superseded|needed|unknown". Never removes anything
# (plan §5 probe policy): a superseded component stays installed until the
# user runs `uninstall --superseded`.
#
# --notify compares with the previous state/probes.json and queues one
# notification (lib/notify.sh, docs/notifications.md) for every component
# that newly flipped to superseded, then saves the new results as the next
# baseline. Without --notify the baseline is left alone, so a manual run
# cannot swallow a flip the boot service would have announced.
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"
# shellcheck source=lib/selfupdate.sh
. "$AX20_SRC/lib/selfupdate.sh"
# shellcheck source=lib/notify.sh
. "$AX20_SRC/lib/notify.sh"

PROBES_JSON_REL="${AX20_STATE_REL}/state/probes.json"

# _probe_previous <name> : result recorded in probes.json, or nothing.
# probes.json is written by _probe_render_json below, one component per
# line, so a line-oriented read is enough (no jq dependency).
_probe_previous() {
    local f
    f=$(ax20_path "$PROBES_JSON_REL")
    [ -f "$f" ] || return 0
    sed -n "s/^    \"$1\": \"\\([a-z]*\\)\",\\{0,1\\}\$/\\1/p" "$f" | head -n1
}

# _probe_render_json <results> : results are "name<TAB>word" lines.
_probe_render_json() {
    local first=1 name word
    printf '{\n  "generated": %s,\n  "probes": {' "$(su_json_str "$(su_now_iso)")"
    while IFS='	' read -r name word; do
        [ -n "$name" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        printf '\n    "%s": "%s"' "$name" "$word"
    done <<EOF
$1
EOF
    [ "$first" = 1 ] || printf '\n  '
    printf '}\n}\n'
}

cmd_probe() {
    local verbose=$AX20_VERBOSE notify=0 c rc word results="" prev flipped=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --verbose | -v) verbose=1 ;;
            --notify) notify=1 ;;
            -h | --help)
                printf 'usage: %s probe [--verbose] [--notify]\n' "$AX20_NAME"
                return 0
                ;;
            *) die 2 "probe: unknown argument '$1'" ;;
        esac
        shift
    done
    if [ "$notify" = 1 ]; then
        require_root probe --notify
    fi
    for c in $(component_list); do
        rc=0
        (
            component_load "$c"
            "${c}_probe"
        ) >/dev/null 2>&1 || rc=$?
        word=$(probe_result_word "$rc")
        printf '%s: %s\n' "$c" "$word"
        if [ "$verbose" = 1 ]; then
            (
                component_load "$c"
                if declare -F "${c}_probe_details" >/dev/null 2>&1; then
                    "${c}_probe_details" 2>&1 | sed 's/^/    /'
                fi
            ) 2>/dev/null || true
        fi
        results="${results}${c}	${word}
"
        if [ "$notify" = 1 ] && [ "$word" = superseded ]; then
            prev=$(_probe_previous "$c")
            if [ "$prev" != superseded ]; then
                flipped=$((flipped + 1))
                notify_enqueue info "$c is now provided by stock SteamOS (superseded). Nothing was removed; to drop our copy run: sudo $AX20_NAME uninstall --superseded"
            fi
        fi
    done
    if [ "$notify" = 1 ] && [ "$AX20_DRY_RUN" != 1 ]; then
        su_ensure_state_subdir
        _probe_render_json "$results" | ax20_atomic_write "$(ax20_path "$PROBES_JSON_REL")" 0644
        log_debug "probe: $flipped component(s) newly superseded"
    fi
    return 0
}
