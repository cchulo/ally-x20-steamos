# SPDX-License-Identifier: GPL-2.0-only
# lib/probes.sh — generic "has stock SteamOS caught up?" helpers.
#
# Every component implements <name>_probe using these. Exit-code contract for
# all probe functions:
#   0  yes / present / superseded by stock
#   1  no  / absent  / still needed
#   2  unknown (cannot determine on this host; status reports "n/a")
# All paths go through ax20_path so probes run against fixture roots.

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"

PROBE_YES=0
PROBE_NO=1
PROBE_UNKNOWN=2
export PROBE_YES PROBE_NO PROBE_UNKNOWN

# probe_file_exists <abs-path>
probe_file_exists() {
    [ -e "$(ax20_path "$1")" ] && return "$PROBE_YES"
    return "$PROBE_NO"
}

# probe_file_contains <abs-path> <fixed-string>
# Binary-safe (grep -a), so it works on .so/.ko files like `strings | grep`.
probe_file_contains() {
    local f
    f=$(ax20_path "$1")
    [ -f "$f" ] || return "$PROBE_UNKNOWN"
    if ax20_have zstd && [ "${f##*.}" = zst ]; then
        zstd -dc "$f" 2>/dev/null | grep -aFq -- "$2" && return "$PROBE_YES"
        return "$PROBE_NO"
    fi
    grep -aFq -- "$2" "$f" && return "$PROBE_YES"
    return "$PROBE_NO"
}

# probe_version_ge <have> <need>
probe_version_ge() {
    [ -n "$1" ] || return "$PROBE_UNKNOWN"
    ax20_version_ge "$1" "$2" && return "$PROBE_YES"
    return "$PROBE_NO"
}

# probe_running_kver : uname -r, or the AX20_KVER override for fixtures.
probe_running_kver() {
    if [ -n "${AX20_KVER:-}" ]; then
        printf '%s\n' "$AX20_KVER"
    else
        uname -r
    fi
}

# probe_stock_module_path <module-name> [kver]
# Prints the stock module file (compressed or not) under /usr/lib/modules.
probe_stock_module_path() {
    local name=$1 kver=${2:-} base p
    [ -n "$kver" ] || kver=$(probe_running_kver)
    base=$(ax20_path "/usr/lib/modules/$kver")
    [ -d "$base" ] || return "$PROBE_UNKNOWN"
    p=$(find "$base/kernel" -name "${name}.ko*" 2>/dev/null | head -n1)
    [ -n "$p" ] || return "$PROBE_NO"
    printf '%s\n' "${p#"$AX20_ROOT"}"
    return "$PROBE_YES"
}

# probe_stock_module_contains <module-name> <string> [kver]
probe_stock_module_contains() {
    local p rc
    p=$(probe_stock_module_path "$1" "${3:-}")
    rc=$?
    [ "$rc" = "$PROBE_YES" ] || return "$rc"
    probe_file_contains "$p" "$2"
}

# probe_soname_version <abs-path-glob-dir> <libname>
# Prints the highest "libname.so.X.Y.Z" version found in a directory.
probe_soname_version() {
    local dir=$1 lib=$2 best
    dir=$(ax20_path "$dir")
    [ -d "$dir" ] || return "$PROBE_UNKNOWN"
    best=$(find "$dir" -maxdepth 1 -name "${lib}.so.*" 2>/dev/null \
        | sed -n "s#.*/${lib}\.so\.\([0-9][0-9.]*\)\$#\1#p" | sort -V | tail -n1)
    [ -n "$best" ] || return "$PROBE_NO"
    printf '%s\n' "$best"
    return "$PROBE_YES"
}

# probe_result_word <rc> : map an exit code to the status vocabulary.
probe_result_word() {
    case "$1" in
        0) printf 'superseded\n' ;;
        1) printf 'needed\n' ;;
        *) printf 'unknown\n' ;;
    esac
}
