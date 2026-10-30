# SPDX-License-Identifier: GPL-2.0-only
# lib/notify.sh — producer side of the user-session notification queue.
#
# Root-side code (probe --notify, self-update --check --notify, the boot
# service, the RAUC handlers) appends one line per event to
#   /var/lib/ally-x20-steamos/state/notifications.queue
# and the user-session notifier (ally-x20-steamos-notify.service) shows the
# lines it has not shown yet. Line format, tab separated, no tabs/newlines
# inside fields (docs/notifications.md is the reference):
#   <ts ISO-8601 UTC>\t<level info|warn|error>\t<message>
# The queue is append-only for producers; when it grows past
# NOTIFY_QUEUE_MAX lines it is rewritten atomically keeping the newest
# NOTIFY_QUEUE_KEEP lines.

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"

NOTIFY_QUEUE_REL="${AX20_STATE_REL}/state/notifications.queue"
NOTIFY_QUEUE_MAX="${NOTIFY_QUEUE_MAX:-500}"
NOTIFY_QUEUE_KEEP="${NOTIFY_QUEUE_KEEP:-200}"

notify_queue_file() { ax20_path "$NOTIFY_QUEUE_REL"; }

# notify_enqueue <level> <message...>
notify_enqueue() {
    local level=$1 msg q n
    shift
    case "$level" in
        info | warn | error) ;;
        *) die "notify_enqueue: bad level '$level' (info|warn|error)" ;;
    esac
    msg=$(printf '%s' "$*" | tr '\t\r\n' '   ')
    q=$(notify_queue_file)
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] notify %s: %s\n' "$level" "$msg" >&2
        return 0
    fi
    [ -d "$(dirname "$q")" ] || mkdir -p "$(dirname "$q")" || die "cannot create $(dirname "$q")"
    printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$msg" >>"$q" \
        || die "cannot append to $q"
    chmod 0644 "$q" 2>/dev/null || true
    n=$(wc -l <"$q" | tr -d ' ')
    if [ "$n" -gt "$NOTIFY_QUEUE_MAX" ]; then
        tail -n "$NOTIFY_QUEUE_KEEP" "$q" | ax20_atomic_write "$q" 0644
    fi
    log_info "notification queued ($level): $msg"
}
