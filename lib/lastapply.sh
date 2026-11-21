# SPDX-License-Identifier: GPL-2.0-only
# lib/lastapply.sh — the record of what the last apply did to each component.
#
# `apply`, `install` (through apply) and the boot service write
#   /var/lib/ally-x20-steamos/state/last-apply.json
# so that "what happened last time" can be looked up after the terminal
# output is gone. `status` reads it. `apply --slot` (the SteamOS update
# hook, which works on the other slot) writes last-apply-slot.json instead,
# so the record of the running system is not replaced by one about another
# slot. Schema (documented in docs/architecture.md, "last-apply.json"):
#
#   {
#     "schema": 1,
#     "name": "ally-x20-steamos",
#     "when": "<iso-8601 UTC>",          # when this run finished
#     "command": "apply",                # apply | apply --only <c> |
#                                        # apply --missing-only | apply --slot | boot
#     "result": "ok" | "failed",         # failed = at least one component failed in this run
#     "exit_code": 0,                    # what the command returned (boot always returns 0)
#     "version": "0.1.11", "commit": "abc1234",
#     "kernel": "<uname -r>",
#     "steamos": { "version": "3.8.2", "build": "20261101.1",
#                  "branch": "stable", "supported": true|false|null },
#     "components": [
#       { "name": "audio", "outcome": "applied", "when": "<iso>", "command": "apply" },
#       { "name": "hdr", "outcome": "failed", "when": "<iso>", "command": "apply",
#         "reason": "<one line>", "errors": ["<last error lines>", ...] }
#     ]
#   }
#
# outcome is one of
#   applied    the component's files and steps were (re)applied
#   unchanged  apply ran and found the component's files already in place
#   failed     its apply stopped with an error; it was skipped, the other
#              components were still applied; "reason" and "errors" say why
#   skipped    not attempted ("reason" says why, e.g. stock SteamOS provides it)
#
# Every component of this version has at most one entry: its outcome in the
# last run that touched it. A run that leaves a component alone (apply
# --only <other>, or the boot service finding nothing to re-apply) keeps the
# component's previous entry, with that entry's own "when" and "command".
# Each entry is written on one line, which is what makes that carry-over a
# plain text operation.
#
# Usage:
#   la_begin <command>                    # start collecting
#   la_record <name> <outcome> [reason] [errors-file]
#   la_write <exit-code> [file-rel]
#   la_file                               # path of the record (unprefixed)
#   la_header <key>                       # when | command | result of the record
#   la_components                         # "name\toutcome\twhen\tcommand\treason" lines

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"
# shellcheck source=lib/selfupdate.sh
. "$AX20_SRC/lib/selfupdate.sh"

AX20_LAST_APPLY_REL="${AX20_STATE_REL}/state/last-apply.json"
AX20_LAST_APPLY_SLOT_REL="${AX20_STATE_REL}/state/last-apply-slot.json"
export AX20_LAST_APPLY_REL AX20_LAST_APPLY_SLOT_REL

# How many error lines are kept per failed component, and how long each is.
LA_MAX_ERRORS=5
LA_MAX_LINE=300

# Entries collected for the current run: one rendered JSON object per line.
_LA_ENTRIES=""
_LA_NAMES=""
_LA_WHEN=""
_LA_COMMAND=""
_LA_FAILED=0

la_file() { printf '%s\n' "$AX20_LAST_APPLY_REL"; }

# la_begin <command> : forget anything collected so far; <command> is how
# the run is named in the record ("apply", "boot", ...).
la_begin() {
    _LA_ENTRIES=""
    _LA_NAMES=""
    _LA_FAILED=0
    _LA_COMMAND=${1:-apply}
    _LA_WHEN=$(su_now_iso)
}

# _la_clean_line : stdin -> one line without control characters or our log
# prefix, cut to LA_MAX_LINE characters.
_la_clean_line() {
    tr '\t\r' '  ' | tr -d '\000-\010\013\014\016-\037' \
        | sed -e "s/^${AX20_NAME}: \(error: \)\{0,1\}//" | cut -c1-"$LA_MAX_LINE"
}

# la_error_tail <stderr-file> : the lines worth keeping from a failed
# component's output: the last LA_MAX_ERRORS non-empty lines.
la_error_tail() {
    [ -f "$1" ] || return 0
    grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n "$LA_MAX_ERRORS" | _la_clean_line
}

# la_reason_from <stderr-file> : one line saying why: the last line our own
# code reported as an error, else the last line of output.
la_reason_from() {
    local r=""
    [ -f "$1" ] || return 0
    r=$(grep "^${AX20_NAME}: error: " "$1" 2>/dev/null | grep -v ': error: component .* failed to apply$' | tail -n 1 | _la_clean_line)
    [ -n "$r" ] || r=$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | _la_clean_line)
    printf '%s\n' "$r"
}

# la_record <name> <outcome> [reason] [errors-file] : note one component's
# outcome for this run. A second call for the same name replaces the first.
la_record() {
    local name=$1 outcome=$2 reason=${3:-} errf=${4:-} line errs="" e first=1
    case "$outcome" in
        applied | unchanged | failed | skipped) ;;
        *) die "la_record: bad outcome '$outcome'" ;;
    esac
    [ -n "$_LA_WHEN" ] || la_begin apply
    reason=$(printf '%s' "$reason" | _la_clean_line)
    line=$(printf '{ "name": %s, "outcome": %s, "when": %s, "command": %s' \
        "$(su_json_str "$name")" "$(su_json_str "$outcome")" "$(su_json_str "$_LA_WHEN")" "$(su_json_str "$_LA_COMMAND")")
    [ -z "$reason" ] || line="$line, \"reason\": $(su_json_str "$reason")"
    if [ -n "$errf" ] && [ -f "$errf" ]; then
        while IFS= read -r e; do
            [ -n "$e" ] || continue
            [ "$first" = 1 ] || errs="$errs, "
            first=0
            errs="$errs$(su_json_str "$e")"
        done <<EOF
$(la_error_tail "$errf")
EOF
        [ -z "$errs" ] || line="$line, \"errors\": [$errs]"
    fi
    line="$line }"
    if printf '%s\n' "$_LA_NAMES" | grep -Fxq -- "$name"; then
        _LA_ENTRIES=$(printf '%s' "$_LA_ENTRIES" | grep -Fv -- "{ \"name\": $(su_json_str "$name"), " || true)
        [ -z "$_LA_ENTRIES" ] || _LA_ENTRIES="$_LA_ENTRIES
"
    else
        _LA_NAMES="$_LA_NAMES$name
"
    fi
    _LA_ENTRIES="$_LA_ENTRIES$line
"
    [ "$outcome" != failed ] || _LA_FAILED=1
}

# la_steamos_field <KEY> : value of KEY= in the root's os-release.
la_steamos_field() {
    local f
    for f in /etc/os-release /usr/lib/os-release; do
        f=$(ax20_path "$f")
        [ -r "$f" ] || continue
        sed -n "s/^$1=//p" "$f" | head -n 1 | sed -e 's/^"//' -e 's/"$//'
        return 0
    done
}

# la_steamos_branch : the update branch this system follows (rel, stable,
# beta, preview, main, ...), or nothing when it cannot be told. Reads the
# branch files lib/modules.sh also looks at. On a live system, outside the
# boot service (AX20_NO_BRANCH_CMD=1), `steamos-select-branch -c` is asked
# as a fallback, with a time limit.
# TODO(hw): confirm on the X20 which of these SteamOS 3.8+ provides.
la_steamos_branch() {
    local f b=""
    if [ -n "${AX20_STEAMOS_BRANCH:-}" ]; then
        printf '%s\n' "$AX20_STEAMOS_BRANCH"
        return 0
    fi
    for f in /var/lib/steamos-branch /etc/steamos-branch; do
        if [ -r "$(ax20_path "$f")" ]; then
            b=$(tr -d ' \t\r\n' <"$(ax20_path "$f")")
            [ -z "$b" ] || break
        fi
    done
    if [ -z "$b" ] && [ -z "$AX20_ROOT" ] && [ "${AX20_NO_BRANCH_CMD:-0}" != 1 ] \
        && ax20_have steamos-select-branch && ax20_have timeout; then
        b=$(timeout 3 steamos-select-branch -c 2>/dev/null | head -n 1 | tr -d ' \t\r\n' || true)
    fi
    printf '%s\n' "$b"
}

# la_branch_supported <branch> : prints true (the stable channel), false
# (any other known branch) or null (unknown).
la_branch_supported() {
    case "$1" in
        '') printf 'null\n' ;;
        rel | stable) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

# _la_previous_entry <file> <name> : the component's entry line in an
# existing record (without leading blanks or the trailing comma).
_la_previous_entry() {
    [ -f "$1" ] || return 0
    grep -F -- "{ \"name\": $(su_json_str "$2"), " "$1" 2>/dev/null | head -n 1 \
        | sed -e 's/^[[:space:]]*//' -e 's/,[[:space:]]*$//'
}

# la_write <exit-code> [file-rel] : merge what this run recorded with the
# previous record and write the file atomically. Never fatal, and nothing
# is written in dry-run mode or when the state directory is absent.
la_write() {
    local code=$1 rel=${2:-$AX20_LAST_APPLY_REL} f c line body="" first=1 ver commit branch
    [ "$AX20_DRY_RUN" = 1 ] && return 0
    f=$(ax20_path "$rel")
    [ -d "$(dirname "$f")" ] && [ -w "$(dirname "$f")" ] || return 0
    [ -n "$_LA_WHEN" ] || la_begin apply
    for c in $(component_list); do
        line=$(printf '%s' "$_LA_ENTRIES" | grep -F -- "{ \"name\": $(su_json_str "$c"), " | head -n 1 || true)
        [ -n "$line" ] || line=$(_la_previous_entry "$f" "$c")
        [ -n "$line" ] || continue
        [ "$first" = 1 ] || body="$body,"
        first=0
        body="$body
    $line"
    done
    ver=$(cat "$AX20_SRC/VERSION" 2>/dev/null || echo unknown)
    commit=""
    if ax20_have git && git -C "$AX20_SRC" rev-parse --short HEAD >/dev/null 2>&1; then
        commit=$(git -C "$AX20_SRC" rev-parse --short HEAD)
    fi
    branch=$(la_steamos_branch)
    {
        printf '{\n'
        printf '  "schema": 1,\n'
        printf '  "name": %s,\n' "$(su_json_str "$AX20_NAME")"
        printf '  "when": %s,\n' "$(su_json_str "$(su_now_iso)")"
        printf '  "command": %s,\n' "$(su_json_str "$_LA_COMMAND")"
        printf '  "result": %s,\n' "$([ "$_LA_FAILED" = 1 ] && echo '"failed"' || echo '"ok"')"
        printf '  "exit_code": %s,\n' "$(printf '%s' "$code" | tr -cd '0-9' | sed 's/^$/0/')"
        printf '  "version": %s,\n' "$(su_json_str "$ver")"
        printf '  "commit": %s,\n' "$(su_json_str "$commit")"
        printf '  "kernel": %s,\n' "$(su_json_str "$(probe_running_kver 2>/dev/null || echo unknown)")"
        printf '  "steamos": { "version": %s, "build": %s, "branch": %s, "supported": %s },\n' \
            "$(su_json_str "$(la_steamos_field VERSION_ID)")" "$(su_json_str "$(la_steamos_field BUILD_ID)")" \
            "$(su_json_str "$branch")" "$(la_branch_supported "$branch")"
        printf '  "components": [%s' "$body"
        [ "$first" = 1 ] || printf '\n  '
        printf ']\n}\n'
    } | ax20_atomic_write "$f" 0644
}

# la_header <key> [file-rel] : a top-level string of the record (when,
# command, result), or nothing.
la_header() {
    local f
    f=$(ax20_path "${2:-$AX20_LAST_APPLY_REL}")
    [ -f "$f" ] || return 0
    if ax20_have jq; then
        jq -r --arg k "$1" '.[$k] // empty' "$f" 2>/dev/null || true
    else
        python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
except Exception:
    v = ""
print(v if v is not None else "")
' "$f" "$1" 2>/dev/null || true
    fi
}

# la_components [file-rel] : "name\toutcome\twhen\tcommand\treason" per
# recorded component (nothing when there is no readable record).
la_components() {
    local f
    f=$(ax20_path "${1:-$AX20_LAST_APPLY_REL}")
    [ -f "$f" ] || return 0
    if ax20_have jq; then
        jq -r '.components[]? | [.name, .outcome, (.when // ""), (.command // ""), (.reason // "")]
            | map(tostring | gsub("\t"; " ")) | join("\t")' "$f" 2>/dev/null || true
    else
        python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for c in d.get("components", []):
    print("\t".join(str(c.get(k, "")).replace("\t", " ") for k in ("name", "outcome", "when", "command", "reason")))
' "$f" 2>/dev/null || true
    fi
}
