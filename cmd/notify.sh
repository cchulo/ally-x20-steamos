# SPDX-License-Identifier: GPL-2.0-only
# summary: show one desktop notification about the last boot (ally-x20-steamos-notify.service): [--print]
#
# Reads state/notify written by `boot`. Runs as the session user; remembers
# what it already showed in ${XDG_STATE_HOME:-~/.local/state}/ally-x20-steamos/notified
# so each distinct summary is shown once. --print writes to stdout instead.

NOTIFY_REL="${AX20_STATE_REL}/state/notify"

# notify_body <file> : human summary, one line per non-empty item.
notify_body() {
    local f=$1 v
    v=$(sed -n 's/^update=//p' "$f")
    [ -n "$v" ] && printf 'SteamOS was updated (slot %s).\n' "$v"
    v=$(sed -n 's/^reapplied=//p' "$f")
    [ -n "$v" ] && printf 'Re-applied: %s.\n' "$v"
    v=$(sed -n 's/^failed=//p' "$f")
    [ -n "$v" ] && printf 'Could not re-apply: %s (see %s status).\n' "$v" "$AX20_NAME"
    v=$(sed -n 's/^pending=//p' "$f")
    [ -n "$v" ] && printf 'Building %s in the background; reboot once it is done.\n' "$v"
    v=$(sed -n 's/^blocked=//p' "$f")
    [ -n "$v" ] && printf 'A SteamOS update with kernel %s was held back: no modules yet. Override: %s update-policy degrade --once.\n' "$v" "$AX20_NAME"
    v=$(sed -n 's/^superseded=//p' "$f")
    [ -n "$v" ] && printf 'SteamOS now provides: %s. Remove ours with: %s uninstall --superseded.\n' "$v" "$AX20_NAME"
    return 0
}

cmd_notify() {
    local print=0 f body seen sha
    case "${1:-}" in
        --print) print=1 ;;
        '') ;;
        *) die 2 "notify: unknown argument '$1'" ;;
    esac
    f=$(ax20_path "$NOTIFY_REL")
    [ -f "$f" ] || return 0
    body=$(notify_body "$f")
    [ -n "$body" ] || return 0
    if [ "$print" = 1 ]; then
        printf '%s\n' "$body"
        return 0
    fi
    seen=$(ax20_path "${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}/$AX20_NAME/notified")
    sha=$(ax20_sha256 "$f")
    if [ -f "$seen" ] && [ "$(cat "$seen")" = "$sha" ]; then
        return 0
    fi
    if ax20_have notify-send; then
        ax20_run notify-send --app-name="$AX20_NAME" --icon=audio-speakers "ROG Xbox Ally X20 support" "$body" \
            || log_warn "notify-send failed"
    else
        printf '%s\n' "$body"
    fi
    if [ "$AX20_DRY_RUN" != 1 ]; then
        mkdir -p "$(dirname "$seen")"
        printf '%s\n' "$sha" >"$seen"
    fi
}
