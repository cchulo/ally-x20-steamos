# SPDX-License-Identifier: GPL-2.0-only
# lib/component.sh — discovery and generic driving of components/*.sh.
#
# A component is one self-contained fix (audio, inputplumber, hdr, ...). Each
# lives in components/<name>.sh and defines (replace <name> accordingly):
#
#   COMPONENT_DESCRIPTION  one line shown by `status` and `help`
#   <name>_files           print one line per file to install:
#                            "<overlay-relative-src>\t<abs-dest>\t<mode>[\t<slot>]"
#                          src is relative to $AX20_SRC/overlay; dest WITHOUT
#                          AX20_ROOT prefix. May print nothing.
#   <name>_apply           optional. Extra work after the files are in place
#                          (depmod, ldconfig, systemctl enable, downloads).
#                          Must be idempotent and AX20_ROOT-aware.
#   <name>_probe           required. 0 = stock SteamOS now provides this
#                          (superseded), 1 = still needed, 2 = unknown.
#   <name>_status          optional override of component_default_status.
#   <name>_remove          optional. Extra cleanup before the manifest-driven
#                          file removal (stop services, remove caches).
#
# Components never write files themselves outside manifest_install_* so that
# `uninstall` can always undo them. Names contain [a-z0-9_] only; the file
# name is the component name.

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$AX20_SRC/lib/manifest.sh"
# shellcheck source=lib/probes.sh
. "$AX20_SRC/lib/probes.sh"

AX20_COMPONENTS_DIR="${AX20_COMPONENTS_DIR:-$AX20_SRC/components}"

# component_list : names, sorted, one per line.
component_list() {
    local f
    for f in "$AX20_COMPONENTS_DIR"/*.sh; do
        [ -f "$f" ] || continue
        basename "$f" .sh
    done | sort
}

# component_exists <name>
component_exists() {
    [ -f "$AX20_COMPONENTS_DIR/$1.sh" ]
}

# component_load <name> : source it (idempotent), die if malformed.
component_load() {
    local name=$1 f
    case "$name" in
        *[!a-z0-9_]*) die "invalid component name '$name'" ;;
    esac
    f="$AX20_COMPONENTS_DIR/$name.sh"
    [ -f "$f" ] || die "unknown component '$name'"
    eval "[ -n \"\${AX20_COMPONENT_LOADED_$name:-}\" ]" && return 0
    # shellcheck disable=SC2034  # set by the component file, read via eval below
    COMPONENT_DESCRIPTION=""
    # shellcheck disable=SC1090
    . "$f"
    eval "AX20_COMPONENT_LOADED_$name=1"
    eval "AX20_COMPONENT_DESC_$name=\"\$COMPONENT_DESCRIPTION\""
    _component_has_fn "${name}_probe" || die "component '$name' does not define ${name}_probe"
    _component_has_fn "${name}_files" || die "component '$name' does not define ${name}_files"
}

_component_has_fn() { declare -F "$1" >/dev/null 2>&1; }

# component_description <name>
component_description() {
    component_load "$1"
    eval "printf '%s\n' \"\${AX20_COMPONENT_DESC_$1}\""
}

# component_files <name> : the normalised file list (tab separated).
component_files() {
    component_load "$1"
    "${1}_files"
}

# component_apply <name> : install files via manifest, then run <name>_apply.
component_apply() {
    local name=$1 src dest mode slot line
    component_load "$name"
    log_info "applying component: $name"
    component_files "$name" | while IFS=$'\t' read -r src dest mode slot; do
        [ -n "$src" ] || continue
        [ -n "$mode" ] || mode=0644
        [ -n "$slot" ] || slot=shared
        line="$AX20_SRC/overlay/$src"
        [ -f "$line" ] || die "component $name: overlay file missing: overlay/$src"
        manifest_install_file "$line" "$dest" "$name" "$mode" "$slot"
    done || return 1
    if _component_has_fn "${name}_apply"; then
        "${name}_apply" || return 1
    fi
    return 0
}

# component_probe <name> : run the probe, return its code.
component_probe() {
    component_load "$1"
    "${1}_probe"
}

# component_installed <name> : 0 if at least one manifest entry exists for it.
component_installed() {
    [ -n "$(manifest_paths "$1" | head -n1)" ]
}

# component_default_status <name> : active | stock | superseded | n/a
#   superseded  stock now provides it (probe == 0), regardless of install state
#   active      installed, every manifest file verifies, probe says still needed
#   stock       not installed (or incomplete), still needed
#   n/a         probe cannot tell on this host and nothing is installed
component_default_status() {
    local name=$1 rc p drift=0
    component_probe "$name" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "$PROBE_YES" ]; then
        printf 'superseded\n'
        return 0
    fi
    if component_installed "$name"; then
        for p in $(manifest_paths "$name"); do
            manifest_verify "$p" || drift=1
        done
        if [ "$drift" = 0 ]; then
            printf 'active\n'
        else
            printf 'stock\n' # incomplete: boot service will re-apply
        fi
        return 0
    fi
    if [ "$rc" = "$PROBE_UNKNOWN" ]; then
        printf 'n/a\n'
    else
        printf 'stock\n'
    fi
}

# component_status <name>
component_status() {
    component_load "$1"
    if _component_has_fn "${1}_status"; then
        "${1}_status"
    else
        component_default_status "$1"
    fi
}

# component_remove_hook <name> : run <name>_remove if present.
component_remove_hook() {
    component_load "$1"
    if _component_has_fn "${1}_remove"; then
        "${1}_remove"
    fi
}
