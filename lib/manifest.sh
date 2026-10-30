# SPDX-License-Identifier: GPL-2.0-only
# lib/manifest.sh — the record of every file ally-x20-steamos has written.
#
# Format: JSON lines at /var/lib/ally-x20-steamos/manifest, one object per
# path, newest last. Fields:
#   path        absolute path WITHOUT the AX20_ROOT prefix
#   component   owning component name (components/<name>.sh)
#   kind        file | symlink | dir
#   sha256      content digest we wrote (files), link target (symlinks), "" (dirs)
#   slot        "A" | "B" | "shared" | "home" | "esp" (best effort, informational)
#   created_dir true if we created the parent directory of this path
#   ts          ISO-8601 timestamp of the write
#
# jq is used when present (SteamOS ships it); python3 is the fallback so the
# library also works on minimal hosts. All functions take paths WITHOUT the
# AX20_ROOT prefix and resolve them internally.

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"

_manifest_json_escape() {
    # Escape a string for inclusion in a JSON string literal.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

# _manifest_field <field> : read stdin JSONL, print that field per line.
_manifest_field() {
    local field=$1
    if ax20_have jq; then
        jq -r --arg f "$field" 'if has($f) and .[$f] != "" then (.[$f] | tostring) else empty end'
    else
        python3 -c '
import json, sys
f = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    v = json.loads(line).get(f, "")
    if v == "":
        continue
    print(v if not isinstance(v, bool) else str(v).lower())
' "$field"
    fi
}

# _manifest_select <field> <value> : stdin JSONL -> lines where field == value.
_manifest_select() {
    local field=$1 value=$2
    if ax20_have jq; then
        jq -c --arg f "$field" --arg v "$value" 'select((.[$f] | tostring) == $v)'
    else
        python3 -c '
import json, sys
f, v = sys.argv[1], sys.argv[2]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    if str(o.get(f, "")).lower() == v.lower() or str(o.get(f, "")) == v:
        print(json.dumps(o, separators=(",", ":")))
' "$field" "$value"
    fi
}

# manifest_entry_get <json-line> <field>
manifest_entry_get() {
    printf '%s\n' "$1" | _manifest_field "$2"
}

# manifest_record <path> <component> <kind> <sha256> <slot> <created_dir:true|false>
# Idempotent: an existing entry for the same path is replaced.
manifest_record() {
    local path=$1 component=$2 kind=$3 sha=$4 slot=${5:-shared} created=${6:-false}
    local file line
    file=$(ax20_manifest_file)
    case "$created" in true | false) ;; *) die "manifest_record: created_dir must be true|false" ;; esac
    case "$kind" in file | symlink | dir) ;; *) die "manifest_record: bad kind '$kind'" ;; esac
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] manifest record %s (%s)\n' "$path" "$component" >&2
        return 0
    fi
    [ -d "$(dirname "$file")" ] || mkdir -p "$(dirname "$file")"
    line=$(printf '{"path":"%s","component":"%s","kind":"%s","sha256":"%s","slot":"%s","created_dir":%s,"ts":"%s"}' \
        "$(_manifest_json_escape "$path")" "$(_manifest_json_escape "$component")" \
        "$kind" "$sha" "$(_manifest_json_escape "$slot")" "$created" "$(_ax20_ts)")
    if [ -f "$file" ] && manifest_has "$path"; then
        manifest_forget "$path"
    fi
    printf '%s\n' "$line" >>"$file"
}

# manifest_entries : all entries in insertion order (empty if no manifest).
manifest_entries() {
    local file
    file=$(ax20_manifest_file)
    [ -f "$file" ] || return 0
    grep -v '^[[:space:]]*$' "$file" || true
}

# manifest_entries_reverse : newest first (uninstall order).
manifest_entries_reverse() {
    manifest_entries | awk '{ l[NR] = $0 } END { for (i = NR; i >= 1; i--) print l[i] }'
}

# manifest_paths [component]
# shellcheck disable=SC2120
manifest_paths() {
    if [ -n "${1:-}" ]; then
        manifest_entries | _manifest_select component "$1" | _manifest_field path
    else
        manifest_entries | _manifest_field path
    fi
}

# manifest_components : distinct component names.
manifest_components() {
    manifest_entries | _manifest_field component | sort -u
}

# manifest_has <path>
manifest_has() {
    manifest_paths | grep -Fxq -- "$1"
}

# manifest_entry <path> : the JSON line for a path (last wins).
manifest_entry() {
    manifest_entries | _manifest_select path "$1" | tail -n1
}

# manifest_forget <path> : remove the entry (does not touch the filesystem).
manifest_forget() {
    local file tmp
    file=$(ax20_manifest_file)
    [ -f "$file" ] || return 0
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] manifest forget %s\n' "$1" >&2
        return 0
    fi
    tmp=$(mktemp "${file}.XXXXXX")
    manifest_entries | _manifest_select path "$1" >/dev/null # validate parse
    if ax20_have jq; then
        jq -c --arg p "$1" 'select(.path != $p)' "$file" >"$tmp"
    else
        python3 -c '
import json, sys
p = sys.argv[1]
for line in open(sys.argv[2]):
    line = line.strip()
    if line and json.loads(line).get("path") != p:
        print(line)
' "$1" "$file" >"$tmp"
    fi
    mv -f "$tmp" "$file"
}

# manifest_verify <path> : 0 if the file on disk still has the recorded
# digest (or symlink target), 1 if modified, 2 if missing, 3 if not recorded.
manifest_verify() {
    local entry kind sha real actual
    entry=$(manifest_entry "$1")
    [ -n "$entry" ] || return 3
    kind=$(manifest_entry_get "$entry" kind)
    sha=$(manifest_entry_get "$entry" sha256)
    real=$(ax20_path "$1")
    case "$kind" in
        dir)
            [ -d "$real" ] && return 0
            return 2
            ;;
        symlink)
            [ -L "$real" ] || return 2
            actual=$(readlink "$real")
            [ "$actual" = "$sha" ] && return 0
            return 1
            ;;
        file)
            [ -f "$real" ] || return 2
            actual=$(ax20_sha256 "$real")
            [ "$actual" = "$sha" ] && return 0
            return 1
            ;;
    esac
    return 3
}

# manifest_install_file <src> <dest> <component> [mode] [slot]
# Copy src to AX20_ROOT/dest atomically and record it. Creates the parent
# directory when needed and records that fact. Idempotent.
manifest_install_file() {
    local src=$1 dest=$2 component=$3 mode=${4:-0644} slot=${5:-shared}
    local real created parent_state
    real=$(ax20_path "$dest")
    parent_state=$(ax20_mkdir_p "$(dirname "$real")")
    created=false
    [ "$parent_state" = created ] && created=true
    if [ -f "$real" ] && ! manifest_has "$dest"; then
        # Something is already there that we did not write. Never clobber a
        # stock file: the drop-in rule means every path we own is ours alone.
        die "refusing to overwrite $dest: it exists and is not in the manifest (not created by $AX20_NAME)"
    fi
    ax20_copy_atomic "$src" "$real" "$mode"
    manifest_record "$dest" "$component" file "$(ax20_sha256 "$src")" "$slot" "$created"
    # Record the parent dir too, so uninstall can remove it if empty.
    if [ "$created" = true ]; then
        manifest_record "$(dirname "$dest")" "$component" dir "" "$slot" false
    fi
}

# manifest_install_symlink <target> <linkpath> <component> [slot]
manifest_install_symlink() {
    local target=$1 link=$2 component=$3 slot=${4:-shared}
    local real created parent_state
    real=$(ax20_path "$link")
    parent_state=$(ax20_mkdir_p "$(dirname "$real")")
    created=false
    [ "$parent_state" = created ] && created=true
    if [ -e "$real" ] && ! [ -L "$real" ]; then
        die "refusing to replace $link: a non-symlink exists there"
    fi
    if [ -L "$real" ] && ! manifest_has "$link"; then
        die "refusing to replace symlink $link: not created by $AX20_NAME"
    fi
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] ln -s %s %s\n' "$target" "$real" >&2
    else
        ln -sfn "$target" "$real"
    fi
    manifest_record "$link" "$component" symlink "$target" "$slot" "$created"
    if [ "$created" = true ]; then
        manifest_record "$(dirname "$link")" "$component" dir "" "$slot" false
    fi
}
