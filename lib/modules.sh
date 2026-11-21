# SPDX-License-Identifier: GPL-2.0-only
# lib/modules.sh — version-gated substitution of the patched kernel modules.
#
# Plan §3, §4.2c, §4.3, §4.5. The patched modules for kernel <kver> live in
#   /etc/ally-x20-steamos/modules/<kver>/{<module>.ko.zst,BUILD-INFO}
# and are loaded by the modprobe.d `install` hooks through
#   /etc/ally-x20-steamos/load-or-fallback  (must exist at udev time: /etc, not /var)
# only when `uname -r` has a matching directory; otherwise stock modules load.
#
# The module set is never hard-coded: it comes from the machine-readable
# lists patches/kernel/modules*.list, one line per patch:
#   <patch-file> <TAB> <make M= dir> <TAB> <ko name> [<TAB> <options>]
# Blank lines and lines starting with '#' are ignored. Several patches may
# name the same module (they are applied in file-name order). <options> is a
# comma separated set of required (default), optional and needs=<patch>; it
# only matters for partial builds (docs/kernel-modules.md).
#
# A staged build is complete (every listed module is patched, or superseded
# because Valve's kernel already has the patches) or partial: made by a
# local build for a kernel some patches do not apply to, with BUILD-INFO
# partial=1 and module.<name>=stock for the modules that were not built.
# Release artifacts are never partial.
#
# Path convention: functions that print a location print it WITHOUT the
# AX20_ROOT prefix (like manifest paths); resolve with ax20_path.
#
# Failure policy: modules_resolve and its helpers log and return non-zero,
# they never die, because the boot service and the RAUC hook must carry on
# with stock modules when no patched build is available.

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$AX20_SRC/lib/manifest.sh"
# shellcheck source=lib/probes.sh
. "$AX20_SRC/lib/probes.sh"

AX20_MODULES_REL="${AX20_EARLY_REL}/modules"
AX20_MODULES_CACHE_REL="${AX20_STATE_REL}/cache"
AX20_HELPER_REL="${AX20_EARLY_REL}/load-or-fallback"
AX20_MODPROBE_CONF_REL="/etc/modprobe.d/${AX20_NAME}-modules.conf"
AX20_MODULES_COMPONENT=modules
# Release assets: <base>/modules-<kver>.tar.zst and .sha256. CI attaches every
# kernel in build/kernels.txt to every release, so "latest" always works.
AX20_MODULES_RELEASE_URL="${AX20_MODULES_RELEASE_URL:-https://github.com/cchulo/${AX20_NAME}/releases/latest/download}"
# The release of this checkout's VERSION is tried before "latest": a newer
# release's artifact may be built from other patches and would be refused.
AX20_MODULES_RELEASE_BASE="${AX20_MODULES_RELEASE_BASE:-https://github.com/cchulo/${AX20_NAME}/releases/download}"
export AX20_MODULES_REL AX20_MODULES_CACHE_REL AX20_HELPER_REL AX20_MODPROBE_CONF_REL

# modules_patches_dir : where the patches and modules*.list files live.
modules_patches_dir() {
    printf '%s\n' "${AX20_PATCHES_DIR:-$AX20_SRC/patches/kernel}"
}

# modules_list_files : the list files, sorted (may print nothing).
modules_list_files() {
    local f
    for f in "$(modules_patches_dir)"/modules*.list; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# modules_list_entries_full : normalised lines from every list,
#   "<patch>\t<mdir>\t<ko>\t<required|optional>\t<needs>"
# <ko> loses any .ko/.ko.zst suffix, <mdir> any leading ./ or trailing /;
# <needs> is the comma separated needs= ids or "-". Returns 1 (after
# logging) on a malformed line. Must stay in sync with bm_list_entries_full
# in build/build-modules.sh (a test compares them).
modules_list_entries_full() {
    local f
    for f in $(modules_list_files); do
        awk -v file="$f" '
            /^[ \t]*(#|$)/ { next }
            {
                if (NF != 3 && NF != 4) {
                    printf "%s:%d: expected 3 or 4 fields (patch, M= dir, ko name[, options]), got %d\n", file, NR, NF > "/dev/stderr"
                    bad = 1; exit 1
                }
                p = $1; m = $2; k = $3; req = "required"; needs = "-"
                sub(/^\.\//, "", m); sub(/\/+$/, "", m)
                sub(/\.ko(\.zst|\.xz|\.gz)?$/, "", k)
                if (m ~ /^\// || m ~ /(^|\/)\.\.(\/|$)/ || p ~ /\// || k ~ /\//) {
                    printf "%s:%d: unsafe entry\n", file, NR > "/dev/stderr"
                    bad = 1; exit 1
                }
                if (NF == 4) {
                    n = split($4, o, ",")
                    for (i = 1; i <= n; i++) {
                        if (o[i] == "required" || o[i] == "optional") {
                            req = o[i]
                        } else if (o[i] ~ /^needs=[0-9A-Za-z._-]+$/) {
                            v = substr(o[i], 7)
                            needs = (needs == "-" ? v : needs "," v)
                        } else {
                            printf "%s:%d: unknown option \"%s\" (required, optional, needs=<patch>)\n", file, NR, o[i] > "/dev/stderr"
                            bad = 1; exit 1
                        }
                    }
                }
                printf "%s\t%s\t%s\t%s\t%s\n", p, m, k, req, needs
            }
            END { exit bad }
        ' "$f" || {
            log_error "malformed module list: $f"
            return 1
        }
    done
}

# modules_list_entries : "<patch>\t<mdir>\t<ko>" lines (the first three
# columns of modules_list_entries_full).
modules_list_entries() {
    local full
    full=$(modules_list_entries_full) || return 1
    [ -n "$full" ] || return 0
    printf '%s\n' "$full" | cut -f1-3
}

# modules_lists_digest : sha256 over the normalised list lines, as
# build/build-modules.sh records it in BUILD-INFO (lists_sha256).
modules_lists_digest() {
    local full
    full=$(modules_list_entries_full) || return 1
    if ax20_have sha256sum; then
        printf '%s\n' "$full" | LC_ALL=C sort | sha256sum | cut -d' ' -f1
    else
        printf '%s\n' "$full" | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1
    fi
}

# modules_list_names : distinct module names, sorted.
modules_list_names() {
    local entries
    entries=$(modules_list_entries) || return 1
    [ -n "$entries" ] || return 0
    printf '%s\n' "$entries" | cut -f3 | sort -u
}

# modules_dir_for <kver>
modules_dir_for() {
    printf '%s/%s\n' "$AX20_MODULES_REL" "$1"
}

# modules_build_info_get <file> <key> : value of "key=value" (first match).
modules_build_info_get() {
    [ -f "$1" ] || return 1
    awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found = 1; exit } END { exit !found }' "$1"
}

# modules_module_state <build-dir> <name> : what a build says about a module:
#   patched     <name>.ko.zst is in the build
#   superseded  every patch for it is already in Valve's tree: the stock
#               module is the right one and no .ko.zst is shipped
#   stock       a partial build did not build it (module.<name>.reason says
#               why); the stock module is loaded
#   missing     the build says nothing about it (incomplete, or made from
#               other module lists)
modules_module_state() {
    local v
    v=$(modules_build_info_get "$1/BUILD-INFO" "module.$2" 2>/dev/null || true)
    case "$v" in
        superseded | stock)
            printf '%s\n' "$v"
            return 0
            ;;
    esac
    if [ -s "$1/$2.ko.zst" ]; then
        printf 'patched\n'
    else
        printf 'missing\n'
    fi
}

# _modules_has_module <build-dir> <name> : the build accounts for the module
# (patched, superseded, or deliberately left stock by a partial build).
_modules_has_module() {
    [ "$(modules_module_state "$1" "$2")" != missing ]
}

# modules_build_partial <build-dir> : BUILD-INFO marks the build as partial.
modules_build_partial() {
    [ "$(modules_build_info_get "$1/BUILD-INFO" partial 2>/dev/null || true)" = 1 ]
}

# modules_superseded_names <kver> : modules the staged build marks superseded.
modules_superseded_names() {
    local f
    f="$(ax20_path "$(modules_dir_for "$1")")/BUILD-INFO"
    [ -f "$f" ] || return 0
    sed -n 's/^module\.\([^=]*\)=superseded$/\1/p' "$f" | sort -u
}

# modules_all_superseded <kver> : the staged build for kver marks every
# listed module superseded (Valve's kernel already carries all our patches).
modules_all_superseded() {
    local names n sup
    names=$(modules_list_names) || return 1
    [ -n "$names" ] || return 1
    sup=$(modules_superseded_names "$1")
    for n in $names; do
        printf '%s\n' "$sup" | grep -Fxq -- "$n" || return 1
    done
    return 0
}

# modules_build_matches_patches <build-dir> : the build was made from the
# patches this checkout ships. BUILD-INFO records patch.<name>=<sha256> for
# every patch it applied (build/build-modules.sh); each listed patch must be
# there with the checkout's hash. Without that check a release that changes
# only a patch (v0.1.7: hid-asus-ally 0016) kept loading the previous build,
# because the kernel version had not changed. A partial build additionally
# depends on the list options (required/optional/needs=), so its
# lists_sha256 must be the checkout's too. Prints the first mismatch.
modules_build_matches_patches() {
    local dir=$1 entries p want got
    entries=$(modules_list_entries) || return 1
    for p in $(printf '%s\n' "$entries" | cut -f1 | sort -u); do
        want=$(ax20_sha256 "$(modules_patches_dir)/$p" 2>/dev/null || true)
        got=$(modules_build_info_get "$dir/BUILD-INFO" "patch.$p" 2>/dev/null || true)
        if [ -z "$got" ]; then
            printf '%s: not in the build\n' "$p"
            return 1
        fi
        if [ "$got" != "$want" ]; then
            printf '%s: built from a different version of the patch\n' "$p"
            return 1
        fi
    done
    if modules_build_partial "$dir"; then
        want=$(modules_lists_digest 2>/dev/null || true)
        got=$(modules_build_info_get "$dir/BUILD-INFO" lists_sha256 2>/dev/null || true)
        if [ -z "$got" ] || [ "$got" != "$want" ]; then
            printf 'partial build made with other module lists\n'
            return 1
        fi
    fi
    return 0
}

# modules_available <kver> : 0 if a staged build for kver is current: made
# from this checkout's patches and accounting for every listed module. That
# includes a partial build, so that a kernel some patches do not apply to
# is built once and not again on every boot; modules_staged_kind tells the
# two apart.
modules_available() {
    local kver=$1 dir names n
    dir=$(ax20_path "$(modules_dir_for "$kver")")
    [ -f "$dir/BUILD-INFO" ] || return 1
    [ "$(modules_build_info_get "$dir/BUILD-INFO" kver)" = "$kver" ] || return 1
    names=$(modules_list_names) || return 1
    [ -n "$names" ] || return 1
    for n in $names; do
        _modules_has_module "$dir" "$n" || return 1
    done
    modules_build_matches_patches "$dir" >/dev/null || return 1
    return 0
}

# modules_staged_stale <kver> : a build is staged for kver but not from this
# checkout's patches; prints why.
modules_staged_stale() {
    local dir
    dir=$(ax20_path "$(modules_dir_for "$1")")
    [ -f "$dir/BUILD-INFO" ] || return 1
    [ "$(modules_build_info_get "$dir/BUILD-INFO" kver)" = "$1" ] || return 1
    ! modules_build_matches_patches "$dir"
}

# modules_staged_states <kver> [build-dir] : one line per listed module for
# the staged build (or the given build directory):
#   "<name>\t<patched|superseded|stock|missing>\t<detail>"
# <detail> is the reason for stock, or "without <patches>" for a patched
# module that lacks optional patches, else empty.
modules_staged_states() {
    local dir=${2:-} names n st detail
    [ -n "$dir" ] || dir=$(ax20_path "$(modules_dir_for "$1")")
    names=$(modules_list_names) || return 1
    for n in $names; do
        st=$(modules_module_state "$dir" "$n")
        detail=""
        case "$st" in
            stock) detail=$(modules_build_info_get "$dir/BUILD-INFO" "module.$n.reason" 2>/dev/null || true) ;;
            patched)
                detail=$(modules_build_info_get "$dir/BUILD-INFO" "module.$n.without" 2>/dev/null || true)
                [ -z "$detail" ] || detail="without $detail"
                ;;
        esac
        printf '%s\t%s\t%s\n' "$n" "$st" "$detail"
    done
}

# modules_staged_kind <kver> : one word for the staged build of kver:
#   none        nothing current is staged (no build, another kernel's, or
#               made from other patches)
#   full        every listed module is patched or superseded
#   partial     some modules are patched, others stay stock
#   stock       a partial build in which no module could be patched
#   superseded  every listed module is superseded
modules_staged_kind() {
    local states patched stock
    if ! modules_available "$1"; then
        printf 'none\n'
        return 0
    fi
    states=$(modules_staged_states "$1") || {
        printf 'none\n'
        return 0
    }
    patched=$(printf '%s\n' "$states" | awk -F'\t' '$2 == "patched"' | wc -l | tr -d ' ')
    stock=$(printf '%s\n' "$states" | awk -F'\t' '$2 == "stock"' | wc -l | tr -d ' ')
    if [ "$stock" = 0 ] && [ "$patched" = 0 ]; then
        printf 'superseded\n'
    elif [ "$stock" = 0 ]; then
        printf 'full\n'
    elif [ "$patched" = 0 ]; then
        printf 'stock\n'
    else
        printf 'partial\n'
    fi
}

# modules_validate_build_dir <kver> <dir> [allow-partial:0|1] : the directory
# holds a build for kver that accounts for every listed module. A partial
# build is accepted only when the caller allows it (a local container
# build); a release artifact that claims to be partial is refused.
modules_validate_build_dir() {
    local kver=$1 src=$2 allow_partial=${3:-0} names n got why
    if [ ! -f "$src/BUILD-INFO" ]; then
        log_error "no BUILD-INFO in $src"
        return 1
    fi
    got=$(modules_build_info_get "$src/BUILD-INFO" kver || true)
    if [ "$got" != "$kver" ]; then
        log_error "BUILD-INFO in $src is for kernel '$got', not '$kver'"
        return 1
    fi
    names=$(modules_list_names) || return 1
    if [ -z "$names" ]; then
        log_error "no modules are listed in $(modules_patches_dir)/modules*.list"
        return 1
    fi
    for n in $names; do
        case "$(modules_module_state "$src" "$n")" in
            missing)
                log_error "build in $src lacks $n.ko.zst"
                return 1
                ;;
            stock)
                if ! modules_build_partial "$src"; then
                    log_error "build in $src leaves $n stock but is not marked partial"
                    return 1
                fi
                if [ -e "$src/$n.ko.zst" ]; then
                    log_error "build in $src marks $n as stock but ships $n.ko.zst"
                    return 1
                fi
                ;;
        esac
    done
    if modules_build_partial "$src" && [ "$allow_partial" != 1 ]; then
        log_warn "build in $src is a partial build; only a local build may be partial (release artifacts never are); not staging it"
        return 1
    fi
    if ! why=$(modules_build_matches_patches "$src"); then
        log_warn "build in $src does not match this checkout's patches ($why); not staging it"
        return 1
    fi
    return 0
}

# modules_log_partial <kver> : after staging, say what a partial build left
# stock. Nothing for a complete build.
modules_log_partial() {
    local name st detail
    case "$(modules_staged_kind "$1")" in
        partial | stock) ;;
        *) return 0 ;;
    esac
    log_warn "the build for $1 is partial: some patches do not apply to this kernel"
    modules_staged_states "$1" | while IFS='	' read -r name st detail; do
        case "$st" in
            stock) log_warn "  $name: stock module stays in use ($detail)" ;;
            patched) log_info "  $name: patched${detail:+ ($detail)}" ;;
            superseded) log_info "  $name: already fixed in this kernel" ;;
        esac
    done
    log_warn "kernel $1 is not a supported kernel (only SteamOS stable is); no support is provided for this state"
}

# _modules_forget_under <rel-dir> : drop manifest entries below a directory.
_modules_forget_under() {
    local p
    for p in $(manifest_paths "$AX20_MODULES_COMPONENT"); do
        case "$p" in
            "$1"/*) manifest_forget "$p" ;;
        esac
    done
}

# modules_ensure_base_dir : create /etc/ally-x20-steamos/modules, recorded.
modules_ensure_base_dir() {
    local base state
    base=$(ax20_path "$AX20_MODULES_REL")
    state=$(ax20_mkdir_p "$base")
    if [ "$state" = created ]; then
        manifest_record "$AX20_MODULES_REL" "$AX20_MODULES_COMPONENT" dir "" shared false
    fi
}

# modules_stage <kver> <src-dir> [allow-partial:0|1] : install
# <src-dir>/{*.ko.zst,BUILD-INFO} as the build for kver. The new directory
# is assembled next to the final one and renamed into place, so a reader
# sees the old set or the new set.
modules_stage() {
    local kver=$1 src=$2 allow_partial=${3:-0} rel dir base tmp old f
    case "$kver" in
        '' | */* | .*)
            log_error "modules_stage: bad kernel version '$kver'"
            return 1
            ;;
    esac
    modules_validate_build_dir "$kver" "$src" "$allow_partial" || return 1
    rel=$(modules_dir_for "$kver")
    dir=$(ax20_path "$rel")
    base=$(dirname "$dir")
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] stage %s -> %s\n' "$src" "$dir" >&2
        return 0
    fi
    modules_ensure_base_dir
    tmp=$(mktemp -d "$base/.stage.XXXXXX") || return 1
    for f in "$src"/*.ko.zst "$src/BUILD-INFO"; do
        [ -f "$f" ] || continue
        if ! cp "$f" "$tmp/"; then
            rm -rf "$tmp"
            log_error "copy of $f failed"
            return 1
        fi
    done
    chmod 0755 "$tmp"
    chmod 0644 "$tmp"/*
    old=""
    if [ -d "$dir" ]; then
        old="$base/.old.$kver.$$"
        rm -rf "$old"
        mv "$dir" "$old" || {
            rm -rf "$tmp"
            return 1
        }
    fi
    if ! mv "$tmp" "$dir"; then
        [ -n "$old" ] && mv "$old" "$dir"
        rm -rf "$tmp"
        log_error "could not move staged modules into $dir"
        return 1
    fi
    [ -n "$old" ] && rm -rf "$old"
    _modules_forget_under "$rel"
    manifest_record "$rel" "$AX20_MODULES_COMPONENT" dir "" shared false
    for f in "$dir"/*; do
        manifest_record "$rel/$(basename "$f")" "$AX20_MODULES_COMPONENT" file "$(ax20_sha256 "$f")" shared false
    done
    log_info "staged patched modules for $kver"
}

# modules_lockdown_active : 0 if kernel lockdown (integrity/confidentiality)
# is in force, in which case our unsigned modules can never load.
modules_lockdown_active() {
    local f
    f=$(ax20_path /sys/kernel/security/lockdown)
    [ -r "$f" ] || return 1
    grep -Eq '\[(integrity|confidentiality)\]' "$f"
}

# modules_render_modprobe_conf : the modprobe.d drop-in, one install hook per
# listed module. Generated from the lists so it can never drift from them.
modules_render_modprobe_conf() {
    local names n helper
    names=$(modules_list_names) || return 1
    helper=$AX20_HELPER_REL
    printf '# Generated by %s (component modules) from patches/kernel/modules*.list.\n' "$AX20_NAME"
    printf '# Loads the patched build for the running kernel when one exists in\n'
    printf '# %s/<uname -r>/, otherwise the stock module.\n' "$AX20_MODULES_REL"
    printf '# Do not edit: re-run "%s apply" instead.\n' "$AX20_NAME"
    for n in $names; do
        # $CMDLINE_OPTS is expanded by modprobe itself, not by us. The inner
        # "|| exec modprobe --ignore-install" guarantees the stock module
        # still loads if the helper is missing or fails for any reason
        # (exit 127 at early boot must never leave the device driverless).
        # shellcheck disable=SC2016
        printf 'install %s /bin/sh -c '"'"'%s %s "$@" || exec modprobe --ignore-install %s "$@"'"'"' -- $CMDLINE_OPTS\n' "$n" "$helper" "$n" "$n"
    done
}

# ----------------------------------------------------------- resolution --

# modules_online : best-effort connectivity check (AX20_OFFLINE=1 forces off).
modules_online() {
    [ "${AX20_OFFLINE:-0}" = 1 ] && return 1
    ax20_have curl || return 1
    curl -fsS --max-time 5 -o /dev/null -I https://github.com >/dev/null 2>&1
}

# _modules_fetch <url> <dest> : download (stubbed in tests).
_modules_fetch() {
    ax20_have curl || return 1
    curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "$1"
}

# modules_detect_channel : SteamOS package channel for header lookups.
# AX20_CHANNEL wins; otherwise the device's branch is mapped to a repo.
# The build script searches the other channels too, so this only sets the
# order. TODO(vm): confirm where SteamOS 3.8+ records the selected branch.
modules_detect_channel() {
    local branch="" f
    if [ -n "${AX20_CHANNEL:-}" ]; then
        printf '%s\n' "$AX20_CHANNEL"
        return 0
    fi
    for f in /var/lib/steamos-branch /etc/steamos-branch; do
        if [ -r "$(ax20_path "$f")" ]; then
            branch=$(tr -d ' \n' <"$(ax20_path "$f")")
            break
        fi
    done
    case "$branch" in
        rel | stable) printf 'jupiter-rel\n' ;;
        staging) printf 'jupiter-staging\n' ;;
        *) printf 'jupiter-main\n' ;;
    esac
}

# _modules_sha256_file_ok <file> <sha256-file>
_modules_sha256_file_ok() {
    local want got
    want=$(awk 'NR == 1 { print $1 }' "$2" 2>/dev/null)
    [ -n "$want" ] || return 1
    got=$(ax20_sha256 "$1")
    [ "$want" = "$got" ]
}

# _modules_install_tarball <kver> <tar.zst> : verify layout, extract, stage.
_modules_install_tarball() {
    local kver=$1 tarball=$2 x listing bad
    ax20_have zstd || {
        log_warn "zstd not available; cannot unpack $tarball"
        return 1
    }
    listing=$(zstd -dc "$tarball" 2>/dev/null | tar -tf - 2>/dev/null) || {
        log_warn "$tarball is not a valid tar.zst"
        return 1
    }
    bad=$(printf '%s\n' "$listing" | awk -v k="$kver" '
        { sub(/^\.\//, "") }
        $0 == "" || $0 == k || $0 == k "/" { next }
        index($0, k "/") != 1 || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /^\// { print; exit }')
    if [ -n "$bad" ]; then
        log_warn "$tarball contains an unexpected entry: $bad"
        return 1
    fi
    x=$(mktemp -d "${TMPDIR:-/tmp}/ax20-modules.XXXXXX") || return 1
    if ! zstd -dc "$tarball" | tar -xf - -C "$x"; then
        rm -rf "$x"
        return 1
    fi
    if ! modules_stage "$kver" "$x/$kver"; then
        rm -rf "$x"
        return 1
    fi
    rm -rf "$x"
}

# _modules_artifact_dir : where downloaded release artifacts are kept.
_modules_artifact_dir() {
    ax20_path "$AX20_MODULES_CACHE_REL/artifacts"
}

# _modules_try_cache <kver>
_modules_try_cache() {
    local kver=$1 a
    if [ "${AX20_MODULES_FORCE:-0}" != 1 ]; then
        modules_available "$kver" && return 0
    fi
    a="$(_modules_artifact_dir)/modules-$kver.tar.zst"
    [ -f "$a" ] && [ -f "$a.sha256" ] || return 1
    if ! _modules_sha256_file_ok "$a" "$a.sha256"; then
        log_warn "cached artifact $a fails its checksum; ignoring it"
        return 1
    fi
    _modules_install_tarball "$kver" "$a"
}

# _modules_release_urls : download bases to try, one per line: the release
# matching this checkout's VERSION (when the file exists), then "latest".
_modules_release_urls() {
    local v
    if [ -f "$AX20_SRC/VERSION" ]; then
        v=$(tr -d '[:space:]' <"$AX20_SRC/VERSION")
        [ -n "$v" ] && printf '%s/v%s\n' "${AX20_MODULES_RELEASE_BASE%/}" "$v"
    fi
    printf '%s\n' "${AX20_MODULES_RELEASE_URL%/}"
}

# _modules_try_release <kver>
_modules_try_release() {
    local kver=$1 name url dir tmp base
    modules_online || {
        log_info "offline: skipping release download for $kver"
        return 1
    }
    name="modules-$kver.tar.zst"
    dir=$(_modules_artifact_dir)
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] download %s\n' "$(_modules_release_urls | head -n1)/$name" >&2
        return 1
    fi
    mkdir -p "$dir" || return 1
    tmp=$(mktemp -d "$dir/.dl.XXXXXX") || return 1
    url=""
    for base in $(_modules_release_urls); do
        if _modules_fetch "$base/$name.sha256" "$tmp/$name.sha256" && _modules_fetch "$base/$name" "$tmp/$name"; then
            url="$base/$name"
            break
        fi
        log_debug "no release artifact at $base/$name"
    done
    if [ -z "$url" ]; then
        log_info "no release artifact for $kver (tried: $(_modules_release_urls | tr '\n' ' '))"
        rm -rf "$tmp"
        return 1
    fi
    if ! _modules_sha256_file_ok "$tmp/$name" "$tmp/$name.sha256"; then
        log_warn "release artifact for $kver fails its checksum"
        rm -rf "$tmp"
        return 1
    fi
    mv -f "$tmp/$name" "$tmp/$name.sha256" "$dir/" && rm -rf "$tmp"
    _modules_install_tarball "$kver" "$dir/$name"
}

# _modules_build_uid : uid the container build runs as for rootful podman.
_modules_build_uid() { printf '%s\n' "${AX20_BUILD_UID:-1000}"; }

# modules_container_build <kver> <channel> <out-dir> : run build/Containerfile
# with build/build-modules.sh as entrypoint. Rootless when invoked as a user
# (image cached in ~/.local/share/containers); rootful under the boot service
# (image cached in /var/lib/containers). Both live on /var or /home and
# survive SteamOS updates. TODO(vm): measure rootful podman on SteamOS.
# The build is partial (PARTIAL=1: patches that do not apply are left out,
# see build/build-modules.sh) unless AX20_MODULES_STRICT=1 (rebuild --strict).
modules_container_build() {
    local kver=$1 channel=$2 out=$3 image cache digest vmlinuz commit partial=1
    [ "${AX20_MODULES_STRICT:-0}" = 1 ] && partial=0
    ax20_have podman || return 1
    image=${AX20_BUILD_IMAGE:-localhost/${AX20_NAME}-build:latest}
    cache=$(ax20_path "$AX20_MODULES_CACHE_REL/build")
    commit=$(git -C "$AX20_SRC" rev-parse HEAD 2>/dev/null || echo unknown)
    ax20_run mkdir -p "$cache" "$out" || return 1
    ax20_run podman build -t "$image" -f "$AX20_SRC/build/Containerfile" "$AX20_SRC/build" || return 1
    digest=$(podman image inspect --format '{{.Digest}}' "$image" 2>/dev/null || echo unknown)
    set -- podman run --rm --security-opt label=disable \
        -v "$AX20_SRC:/src:ro" -v "$cache:/cache" -v "$out:/out" \
        -e "KVER=$kver" -e "CHANNEL=$channel" -e OUT_DIR=/out -e CACHE_DIR=/cache \
        -e PATCHES_DIR=/src/patches/kernel -e HOME=/tmp -e "AX20_COMMIT=$commit" \
        -e "CONTAINER_IMAGE=$image" -e "CONTAINER_IMAGE_DIGEST=$digest" \
        -e "PARTIAL=$partial"
    if ax20_is_root; then
        ax20_run chown -R "$(_modules_build_uid)" "$cache" "$out" || return 1
        set -- "$@" --user "$(_modules_build_uid)"
    else
        set -- "$@" --userns=keep-id
    fi
    vmlinuz=$(ax20_path "/usr/lib/modules/$kver/vmlinuz")
    if [ -f "$vmlinuz" ]; then
        set -- "$@" -v "$vmlinuz:/vmlinuz:ro" -e VMLINUZ=/vmlinuz
    fi
    ax20_run "$@" "$image"
}

# _modules_try_container <kver> <channel>
_modules_try_container() {
    local kver=$1 channel=$2 out rc
    ax20_have podman || {
        log_info "podman not available: skipping container build for $kver"
        return 1
    }
    modules_online || {
        log_info "offline: skipping container build for $kver"
        return 1
    }
    [ -n "$channel" ] || channel=$(modules_detect_channel)
    out=$(ax20_path "$AX20_MODULES_CACHE_REL/build-out/$kver")
    rm -rf "$out"
    log_info "building patched modules for $kver in a container (channel $channel); this takes a few minutes"
    rc=0
    modules_container_build "$kver" "$channel" "$out" || rc=$?
    if [ "$rc" != 0 ]; then
        log_warn "container build for $kver failed (exit $rc)"
        log_warn "if the output above says 'no space left on device': podman keeps its images under /var, which is small on SteamOS; see docs/kernel-modules.md, \"Podman storage\""
        return 1
    fi
    [ "$AX20_DRY_RUN" = 1 ] && return 0
    # A local build may be partial; a release artifact (above) may not.
    modules_stage "$kver" "$out/$kver" 1 || return 1
    modules_log_partial "$kver"
}

# _modules_try_source <cache|release|container> <kver> <channel>
_modules_try_source() {
    case "$1" in
        cache) _modules_try_cache "$2" ;;
        release) _modules_try_release "$2" ;;
        container) _modules_try_container "$2" "$3" ;;
        *) return 2 ;;
    esac
}

# modules_resolve <kver> [--source cache|release|container] [--channel <c>]
# Makes modules for kver available, trying cache -> release -> container (or
# only the named source). Prints the source that succeeded. Returns 1 after
# logging when nothing worked; never dies.
modules_resolve() {
    local kver=$1 only="" channel="" order m
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --source)
                only=${2:-}
                shift 2 || return 2
                ;;
            --channel)
                channel=${2:-}
                shift 2 || return 2
                ;;
            *)
                log_error "modules_resolve: unknown argument '$1'"
                return 2
                ;;
        esac
    done
    case "$only" in
        '') order="cache release container" ;;
        cache | release | container) order=$only ;;
        *)
            log_error "unknown module source '$only' (cache|release|container)"
            return 2
            ;;
    esac
    for m in $order; do
        if _modules_try_source "$m" "$kver" "$channel"; then
            printf '%s\n' "$m"
            return 0
        fi
    done
    log_warn "no patched modules for kernel $kver (tried: $order); stock modules will be used"
    return 1
}
