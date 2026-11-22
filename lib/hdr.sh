# SPDX-License-Identifier: GPL-2.0-only
# lib/hdr.sh — the Desktop Mode half of the hdr component: getting our
# libdisplay-info build (0.3.0 + DisplayID 2 backport) onto the device.
#
# Sourced by components/hdr.sh, which owns the constants used here
# (HDR_LIB_DIR, HDR_LDI_SONAME, HDR_LDI_MIN_VERSION, hdr_stock_ldi_version).
# Works like lib/modules.sh does for the kernel modules and reuses its
# helpers: CI builds the library (job "hdr" in build-modules.yml) and
# attaches hdr-libdisplay-info-<version>.tar.zst + .sha256 to the release;
# the device resolves it cache -> release, or builds it in a container when
# asked to (`hdr build`).
#
# The library is selected system-wide through ld.so.conf.d, so a bad copy
# could stop KWin from starting. Nothing is installed unless all of these
# hold (hdr_lib_stock_check, hdr_lib_validate_dir):
#   * SteamOS ships exactly the libdisplay-info version the build replaces
#     (build/hdr.lock LDI_VERSION and LDI_SONAME), and not 0.4.0 or later;
#   * a downloaded tarball matches its .sha256;
#   * BUILD-INFO names the pins and patch hashes of this checkout;
#   * the library file matches the sha256 recorded in BUILD-INFO;
#   * the dynamic loader of this system can load it (hdr_lib_load_test).
# The ABI check against an unpatched 0.3.0 happens at build time
# (build/build-hdr.sh); a build that fails it produces no artifact.
#
# Every file is installed through the manifest (component hdr), so
# `uninstall` removes it and `status` verifies it.
#
# Failure policy: like lib/modules.sh, these functions log and return
# non-zero; they never die. Without the library Desktop Mode HDR stays off
# and everything else works.

# shellcheck source=lib/modules.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/modules.sh"
# Pins, patch digests, build id and the artifact layout live in the build
# script; sourcing it does not start a build.
# shellcheck source=build/build-hdr.sh
. "$AX20_SRC/build/build-hdr.sh"

HDR_LDI_STATE_DIR="$AX20_STATE_REL/libdisplay-info"
HDR_LIB_BUILD_INFO="$HDR_LDI_STATE_DIR/BUILD-INFO"
HDR_LIB_TOOL="$HDR_LDI_STATE_DIR/bin/di-edid-decode"
HDR_LIB_LICENSE="$HDR_LDI_STATE_DIR/LICENSE"
# Where the installed copy came from: source=, origin=, installed_at=.
HDR_LIB_SOURCE_FILE="$HDR_LDI_STATE_DIR/SOURCE"
# Written by `hdr remove`: the user took the library out on purpose, so
# apply, self-update and the boot service must not bring it back.
HDR_LIB_DISABLED_FILE="$AX20_STATE_REL/state/hdr-desktop-disabled"
HDR_LIB_COMPONENT=hdr

# ------------------------------------------------------------- queries --

# hdr_lib_real_rel : the library file, e.g. .../lib/libdisplay-info.so.0.3.0
hdr_lib_real_rel() { printf '%s/%s\n' "$HDR_LIB_DIR" "$(hdr_ldi_real_name)"; }

# hdr_lib_info_get <key> : value from the installed BUILD-INFO.
hdr_lib_info_get() {
    modules_build_info_get "$(ax20_path "$HDR_LIB_BUILD_INFO")" "$1"
}

# hdr_lib_source_get <key> : value from the installed SOURCE file.
hdr_lib_source_get() {
    modules_build_info_get "$(ax20_path "$HDR_LIB_SOURCE_FILE")" "$1"
}

# hdr_lib_disabled : the user removed the library with `hdr remove`.
hdr_lib_disabled() {
    [ -f "$(ax20_path "$HDR_LIB_DISABLED_FILE")" ]
}

# hdr_lib_stock_check : does our build apply to what SteamOS ships? Prints
# the reason when it does not.
#   0  SteamOS ships the pinned version and soname: our build applies
#   1  SteamOS ships 0.4.0 or later, which reads DisplayID 2 itself
#   2  SteamOS ships another version or soname: our build is not for it
#   3  cannot tell what SteamOS ships
hdr_lib_stock_check() {
    local v want soname
    want=$(hdr_lock_get LDI_VERSION) && soname=$(hdr_lock_get LDI_SONAME) || {
        printf 'build/hdr.lock does not name the libdisplay-info version and soname\n'
        return 3
    }
    v=$(hdr_stock_ldi_version) || {
        printf 'cannot tell which libdisplay-info SteamOS ships (none found in %s)\n' "$HDR_STOCK_LDI_DIR"
        return 3
    }
    if ax20_version_ge "$v" "$HDR_LDI_MIN_VERSION"; then
        printf 'SteamOS ships libdisplay-info %s, which reads the HDR data itself; our library is not needed\n' "$v"
        return 1
    fi
    if [ "$v" != "$want" ]; then
        printf 'SteamOS ships libdisplay-info %s; our library replaces %s (%s) only\n' "$v" "$want" "$soname"
        return 2
    fi
    if [ "$soname" != "$HDR_LDI_SONAME" ]; then
        printf 'build/hdr.lock builds %s but the component selects %s\n' "$soname" "$HDR_LDI_SONAME"
        return 2
    fi
    if ! [ -e "$(ax20_path "$HDR_STOCK_LDI_DIR/$soname")" ] && ! [ -L "$(ax20_path "$HDR_STOCK_LDI_DIR/$soname")" ]; then
        printf 'SteamOS has no %s/%s; our library replaces that soname only\n' "$HDR_STOCK_LDI_DIR" "$soname"
        return 2
    fi
    return 0
}

# hdr_lib_matches_checkout <BUILD-INFO> : the build was made from this
# checkout's pins (build/hdr.lock) and patches (patches/libdisplay-info).
# Prints the first mismatch. This is what refuses a build made for another
# libdisplay-info version or soname, or from other patches.
hdr_lib_matches_checkout() {
    local f=$1 key want got
    if [ ! -f "$f" ]; then
        printf 'no BUILD-INFO\n'
        return 1
    fi
    while IFS='=' read -r key want; do
        [ -n "$key" ] || continue
        got=$(modules_build_info_get "$f" "$key" 2>/dev/null || true)
        [ "$got" = "$want" ] && continue
        case "$key" in
            libdisplay_info_patches | build_id)
                printf '%s differs: built from other patches or pins than this checkout has\n' "$key"
                ;;
            *) printf "%s is '%s', this checkout needs '%s'\n" "$key" "$got" "$want" ;;
        esac
        return 1
    done <<EOF
component=libdisplay-info
libdisplay_info_version=$(hdr_lock_get LDI_VERSION)
libdisplay_info_soname=$(hdr_lock_get LDI_SONAME)
libdisplay_info_commit=$(hdr_lock_get LDI_COMMIT)
libdisplay_info_patches=$(hdr_patch_digests libdisplay-info)
build_id=$(hdr_build_id libdisplay-info)
EOF
    return 0
}

# hdr_lib_current : our library is installed, intact and built from this
# checkout's pins and patches.
hdr_lib_current() {
    local real want
    real=$(ax20_path "$(hdr_lib_real_rel)")
    [ -f "$real" ] && [ -e "$(ax20_path "$HDR_LIB_DIR/$HDR_LDI_SONAME")" ] || return 1
    hdr_lib_matches_checkout "$(ax20_path "$HDR_LIB_BUILD_INFO")" >/dev/null || return 1
    want=$(hdr_lib_info_get libdisplay_info_sha256 2>/dev/null) || return 1
    [ -n "$want" ] && [ "$(ax20_sha256 "$real")" = "$want" ]
}

# hdr_lib_fetch_due : an automatic fetch makes sense now.
hdr_lib_fetch_due() {
    hdr_lib_stock_check >/dev/null || return 1
    hdr_lib_disabled && return 1
    ! hdr_lib_current
}

# ---------------------------------------------------------- validation --

# _hdr_lib_edid : the internal panel's EDID, if this root has one.
_hdr_lib_edid() {
    local f
    for f in "$(ax20_path /sys/class/drm)"/card*-eDP-*/edid; do
        if [ -s "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

# _hdr_lib_dlopen <file> : load the library the way a program would, without
# running anything of ours first. Prints the loader's message on failure.
# Returns 2 when there is no python3 to do it with.
_hdr_lib_dlopen() {
    ax20_have python3 || return 2
    python3 -c 'import ctypes, sys
try:
    ctypes.CDLL(sys.argv[1])
except OSError as e:
    print(e)
    sys.exit(1)' "$1" 2>&1
}

# hdr_lib_load_test <dir> : before anything is installed, make sure this
# system can use the candidate library:
#   1. the dynamic loader loads it (missing glibc symbol versions or a wrong
#      architecture fail here);
#   2. the build's di-edid-decode, linked against it, reads the panel's EDID
#      without crashing or missing a symbol.
# Only failures of the library refuse it. di-edid-decode itself may need a
# newer glibc than SteamOS has (the Arch build of 2026-10-27 needs
# GLIBC_2.43, the library only GLIBC_2.27); then step 2 says nothing and
# step 1 decides. Skipped on a fixture or slot root, whose loader is not the
# one running here.
# TODO(hw): confirm on the X20 that the CI build passes both steps.
hdr_lib_load_test() {
    local dir=$1 lib tmp edid rc=0 err
    if [ -n "$AX20_ROOT" ]; then
        log_debug "hdr: fixture/slot root, not load-testing the library"
        return 0
    fi
    lib="$dir/$(hdr_ldi_real_name)"
    err=$(_hdr_lib_dlopen "$lib") || rc=$?
    if [ "$rc" = 1 ]; then
        log_warn "hdr: this system cannot load the library ($err); not installing it"
        return 1
    fi
    [ "$rc" = 0 ] || log_debug "hdr: no python3, loader test skipped"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ax20-hdr-load.XXXXXX") || return 1
    ln -s "$lib" "$tmp/$HDR_LDI_SONAME" || {
        rm -rf "$tmp"
        return 1
    }
    edid=$(_hdr_lib_edid) || edid=/dev/null
    rc=0
    LD_LIBRARY_PATH="$tmp" "$dir/di-edid-decode" <"$edid" >/dev/null 2>"$tmp/err" || rc=$?
    err=$(head -n 3 "$tmp/err" 2>/dev/null | tr '\n' ' ')
    rm -rf "$tmp"
    if [ "$rc" -ge 128 ]; then
        log_warn "hdr: di-edid-decode crashed with the library (exit $rc); not installing it"
        return 1
    fi
    case "$err" in
        *"symbol lookup error"* | *"error while loading shared libraries"*libdisplay-info*)
            log_warn "hdr: di-edid-decode cannot use the library ($err); not installing it"
            return 1
            ;;
    esac
    log_debug "hdr: di-edid-decode ran against the candidate library (exit $rc${err:+: $err})"
    return 0
}

# hdr_lib_validate_dir <dir> : <dir> is an artifact directory (the library,
# di-edid-decode, BUILD-INFO, LICENSE) that may be installed here.
hdr_lib_validate_dir() {
    local dir=$1 why f want real
    real=$(hdr_ldi_real_name) || return 1
    for f in "$real" di-edid-decode BUILD-INFO LICENSE; do
        if [ ! -f "$dir/$f" ] || [ -L "$dir/$f" ] || [ ! -s "$dir/$f" ]; then
            log_warn "hdr: the build in $dir has no usable $f; not installing it"
            return 1
        fi
    done
    if ! why=$(hdr_lib_matches_checkout "$dir/BUILD-INFO"); then
        log_warn "hdr: the build in $dir is not for this checkout ($why); not installing it"
        return 1
    fi
    want=$(modules_build_info_get "$dir/BUILD-INFO" libdisplay_info_sha256 2>/dev/null || true)
    if [ -z "$want" ] || [ "$(ax20_sha256 "$dir/$real")" != "$want" ]; then
        log_warn "hdr: $real in $dir does not match the sha256 in its BUILD-INFO; not installing it"
        return 1
    fi
    hdr_lib_load_test "$dir"
}

# ------------------------------------------------------ install/remove --

# _hdr_lib_make_room <rel-path> : an unrecorded file or link at one of our
# own paths (a build copied in by hand before this was automatic) is
# replaced; manifest_install_* would refuse it.
_hdr_lib_make_room() {
    local real
    real=$(ax20_path "$1")
    if [ -e "$real" ] || [ -L "$real" ]; then
        if ! manifest_has "$1"; then
            log_info "hdr: replacing $1 (not recorded in the manifest, from a manual build)"
            ax20_run rm -f "$real"
        fi
    fi
}

# _hdr_lib_drop_dev_files : what a manual `build-hdr.sh --destdir` install
# leaves besides the library: the linker name, the pkg-config file and the
# headers. Nothing on the device uses them.
_hdr_lib_drop_dev_files() {
    local p real
    for p in "$HDR_LIB_DIR/libdisplay-info.so" "$HDR_LIB_DIR/pkgconfig/libdisplay-info.pc"; do
        real=$(ax20_path "$p")
        if [ -e "$real" ] || [ -L "$real" ]; then
            ax20_run rm -f "$real"
        fi
    done
    real=$(ax20_path "$HDR_LIB_DIR/pkgconfig")
    if [ -d "$real" ] && [ -z "$(ls -A "$real" 2>/dev/null)" ]; then
        ax20_run rmdir "$real"
    fi
    real=$(ax20_path "$HDR_LDI_STATE_DIR/include")
    if [ -d "$real" ]; then
        ax20_run rm -rf "$real"
    fi
}

# _hdr_lib_other_versions : recorded or stray libdisplay-info.so.* in our
# lib dir other than the two names the current pins use.
_hdr_lib_other_versions() {
    local f keep1 keep2
    keep1=$(hdr_ldi_real_name)
    keep2=$HDR_LDI_SONAME
    for f in "$(ax20_path "$HDR_LIB_DIR")"/libdisplay-info.so.*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "${f##*/}" in
            "$keep1" | "$keep2") continue ;;
        esac
        printf '%s/%s\n' "$HDR_LIB_DIR" "${f##*/}"
    done
}

_hdr_lib_stage_do() {
    local src=$1 how=$2 origin=$3 real_name real_rel p tmp
    real_name=$(hdr_ldi_real_name)
    real_rel=$(hdr_lib_real_rel)
    for p in "$real_rel" "$HDR_LIB_DIR/$HDR_LDI_SONAME" "$HDR_LIB_TOOL" "$HDR_LIB_LICENSE" \
        "$HDR_LIB_BUILD_INFO" "$HDR_LIB_SOURCE_FILE"; do
        _hdr_lib_make_room "$p"
    done
    # The file is replaced by rename, so a running KWin keeps the copy it
    # has mapped until it restarts.
    manifest_install_file "$src/$real_name" "$real_rel" "$HDR_LIB_COMPONENT" 0755 shared
    manifest_install_symlink "$real_name" "$HDR_LIB_DIR/$HDR_LDI_SONAME" "$HDR_LIB_COMPONENT" shared
    manifest_install_file "$src/di-edid-decode" "$HDR_LIB_TOOL" "$HDR_LIB_COMPONENT" 0755 shared
    manifest_install_file "$src/LICENSE" "$HDR_LIB_LICENSE" "$HDR_LIB_COMPONENT" 0644 shared
    manifest_install_file "$src/BUILD-INFO" "$HDR_LIB_BUILD_INFO" "$HDR_LIB_COMPONENT" 0644 shared
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-hdr-source.XXXXXX") || die "cannot create a temporary file"
    printf 'source=%s\norigin=%s\ninstalled_at=%s\n' "$how" "$origin" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$tmp"
    manifest_install_file "$tmp" "$HDR_LIB_SOURCE_FILE" "$HDR_LIB_COMPONENT" 0644 shared
    rm -f "$tmp"
    for p in $(_hdr_lib_other_versions); do
        ax20_run rm -f "$(ax20_path "$p")"
        manifest_forget "$p"
    done
    _hdr_lib_drop_dev_files
}

# hdr_lib_stage <dir> <cache|release|container> [origin] : check and install
# an artifact directory as our library. The manifest functions die on
# errors, hence the subshell.
hdr_lib_stage() {
    local src=$1 how=$2 origin=${3:-} why
    if ! why=$(hdr_lib_stock_check); then
        log_warn "hdr: not installing the Desktop Mode library: $why"
        return 1
    fi
    hdr_lib_validate_dir "$src" || return 1
    if ! (_hdr_lib_stage_do "$src" "$how" "$origin"); then
        log_error "hdr: installing the Desktop Mode library failed"
        return 1
    fi
    [ "$AX20_DRY_RUN" = 1 ] || log_info "hdr: installed the Desktop Mode library (build $(modules_build_info_get "$src/BUILD-INFO" build_id), from $how)"
}

# hdr_lib_unstage : take our library out again. Files first, the manifest
# afterwards, so a damaged manifest cannot keep a bad library in place.
# Directories stay (empty, recorded) for the next install. Prints nothing;
# returns 1 if a file could not be removed.
hdr_lib_unstage() {
    local p real rc=0 list
    list="$(hdr_lib_real_rel)
$HDR_LIB_DIR/$HDR_LDI_SONAME
$(_hdr_lib_other_versions)
$HDR_LIB_TOOL
$HDR_LIB_LICENSE
$HDR_LIB_BUILD_INFO
$HDR_LIB_SOURCE_FILE"
    for p in $list; do
        real=$(ax20_path "$p")
        if [ -e "$real" ] || [ -L "$real" ]; then
            ax20_run rm -f "$real" || rc=1
        fi
    done
    _hdr_lib_drop_dev_files
    for p in $list; do
        (manifest_has "$p" && manifest_forget "$p") 2>/dev/null || true
    done
    return "$rc"
}

# hdr_lib_set_disabled / hdr_lib_clear_disabled : the `hdr remove` marker.
hdr_lib_set_disabled() {
    local f
    f=$(ax20_path "$HDR_LIB_DISABLED_FILE")
    [ "$AX20_DRY_RUN" = 1 ] || mkdir -p "$(dirname "$f")" || return 1
    printf 'removed_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | ax20_atomic_write "$f" 0644
}
hdr_lib_clear_disabled() {
    local f
    f=$(ax20_path "$HDR_LIB_DISABLED_FILE")
    [ -f "$f" ] || return 0
    ax20_run rm -f "$f"
}

# hdr_ldconfig : refresh ld.so.cache so the loader sees (or forgets) our
# copy. Live system only; a fixture or slot root gets it from its own boot
# service (hdr_status reports "stock" until the cache lists the library).
hdr_ldconfig() {
    if [ -n "$AX20_ROOT" ]; then
        log_debug "hdr: fixture/slot root, ldconfig deferred to the boot service on that system"
        return 0
    fi
    if ax20_have ldconfig; then
        ax20_run ldconfig || log_warn "hdr: ldconfig failed; libdisplay-info override not active until it succeeds"
    else
        log_warn "hdr: ldconfig not found; libdisplay-info override not active"
    fi
    return 0
}

# ----------------------------------------------------------- resolution --

# _hdr_lib_install_tarball <tar.zst> <how> <origin> : verify layout,
# extract, stage.
_hdr_lib_install_tarball() {
    local tarball=$1 how=$2 origin=$3 top x listing bad
    top=$(hdr_ldi_artifact_top) || return 1
    ax20_have zstd || {
        log_warn "zstd not available; cannot unpack $tarball"
        return 1
    }
    listing=$(zstd -dc "$tarball" 2>/dev/null | tar -tf - 2>/dev/null) || {
        log_warn "$tarball is not a valid tar.zst"
        return 1
    }
    bad=$(printf '%s\n' "$listing" | awk -v k="$top" '
        { sub(/^\.\//, "") }
        $0 == "" || $0 == k || $0 == k "/" { next }
        index($0, k "/") != 1 || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /^\// { print; exit }')
    if [ -n "$bad" ]; then
        log_warn "$tarball contains an unexpected entry: $bad"
        return 1
    fi
    x=$(mktemp -d "${TMPDIR:-/tmp}/ax20-hdr.XXXXXX") || return 1
    if ! zstd -dc "$tarball" | tar -xf - -C "$x"; then
        rm -rf "$x"
        return 1
    fi
    if ! hdr_lib_stage "$x/$top" "$how" "$origin"; then
        rm -rf "$x"
        return 1
    fi
    rm -rf "$x"
}

# _hdr_lib_try_cache : already installed and current, or a downloaded
# artifact kept from an earlier run.
_hdr_lib_try_cache() {
    local a origin
    if [ "${AX20_HDR_FORCE:-0}" != 1 ]; then
        hdr_lib_current && return 0
    fi
    a="$(_modules_artifact_dir)/$(hdr_ldi_artifact_name)"
    [ -f "$a" ] && [ -f "$a.sha256" ] || return 1
    if ! _modules_sha256_file_ok "$a" "$a.sha256"; then
        log_warn "cached artifact $a fails its checksum; ignoring it"
        return 1
    fi
    origin=$(head -n1 "$a.url" 2>/dev/null || true)
    _hdr_lib_install_tarball "$a" cache "${origin:-$a}"
}

# _hdr_lib_try_release : the release of this checkout's VERSION, then the
# latest release (_modules_release_urls). A release without the asset (every
# release up to v0.2.0) is skipped quietly; one whose build does not match
# this checkout is refused and the next one is tried.
_hdr_lib_try_release() {
    local name dir tmp base tried=""
    modules_online || {
        log_info "hdr: offline, not downloading the Desktop Mode library"
        return 1
    }
    name=$(hdr_ldi_artifact_name) || return 1
    dir=$(_modules_artifact_dir)
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] download %s\n' "$(_modules_release_urls | head -n1)/$name" >&2
        return 1
    fi
    mkdir -p "$dir" || return 1
    for base in $(_modules_release_urls); do
        tried="${tried:+$tried }$base"
        tmp=$(mktemp -d "$dir/.dl.XXXXXX") || return 1
        if ! _modules_fetch "$base/$name.sha256" "$tmp/$name.sha256" 2>/dev/null \
            || ! _modules_fetch "$base/$name" "$tmp/$name" 2>/dev/null; then
            log_debug "no release artifact at $base/$name"
            rm -rf "$tmp"
            continue
        fi
        if ! _modules_sha256_file_ok "$tmp/$name" "$tmp/$name.sha256"; then
            log_warn "hdr: the release artifact $base/$name fails its checksum; not installing it"
            rm -rf "$tmp"
            continue
        fi
        if _hdr_lib_install_tarball "$tmp/$name" release "$base/$name"; then
            printf '%s\n' "$base/$name" >"$tmp/$name.url"
            mv -f "$tmp/$name" "$tmp/$name.sha256" "$tmp/$name.url" "$dir/"
            rm -rf "$tmp"
            return 0
        fi
        rm -rf "$tmp"
    done
    log_info "hdr: no prebuilt Desktop Mode library for this version in the releases (tried: $tried)"
    return 1
}

# _hdr_podman_storage : where rootful podman keeps images for our builds.
# Its default, /var/lib/containers, is on SteamOS's per-slot /var partition
# (about 230 MB): measured on the X20, pulling the Arch image there fails
# with "no space left on device". The state dir is a symlink into /home, so
# the storage goes under its cache directory. Prints nothing for rootless
# podman, whose storage is in the user's home already. AX20_PODMAN_ROOT
# overrides the location.
_hdr_podman_storage() {
    local d
    if [ -n "${AX20_PODMAN_ROOT:-}" ]; then
        printf '%s\n' "$AX20_PODMAN_ROOT"
        return 0
    fi
    ax20_is_root || return 0
    d=$(ax20_path "$AX20_MODULES_CACHE_REL/podman")
    if [ "$AX20_DRY_RUN" != 1 ]; then
        mkdir -p "$d" || return 1
        # Physical path: podman records it, and /var/lib/... is a symlink.
        d=$(cd "$d" && pwd -P) || return 1
    fi
    printf '%s\n' "$d"
}

# hdr_lib_container_build <out-dir> : build libdisplay-info in the Arch
# build container (build/Containerfile + build/Containerfile.hdr) with
# build/build-hdr.sh as entrypoint. Leaves the artifact directory in
# <out-dir>/artifact/libdisplay-info-<version>.
hdr_lib_container_build() {
    local out=$1 base image digest storage
    ax20_have podman || return 1
    base=${AX20_BUILD_IMAGE:-localhost/${AX20_NAME}-build:latest}
    image=${AX20_HDR_BUILD_IMAGE:-localhost/${AX20_NAME}-build-hdr:latest}
    storage=$(_hdr_podman_storage) || return 1
    ax20_run mkdir -p "$out" || return 1
    set -- podman
    [ -z "$storage" ] || set -- "$@" --root "$storage"
    ax20_run "$@" build -t "$base" -f "$AX20_SRC/build/Containerfile" "$AX20_SRC/build" || return 1
    ax20_run "$@" build -t "$image" --build-arg "BASE_IMAGE=$base" \
        -f "$AX20_SRC/build/Containerfile.hdr" "$AX20_SRC/build" || return 1
    digest=$("$@" image inspect --format '{{.Digest}}' "$image" 2>/dev/null || echo unknown)
    set -- "$@" run --rm --security-opt label=disable \
        -v "$AX20_SRC:/src:ro" -v "$out:/out" -e HOME=/tmp \
        -e "AX20_BUILD_IMAGE=$image@$digest"
    if ax20_is_root; then
        ax20_run chown -R "$(_modules_build_uid)" "$out" || return 1
        set -- "$@" --user "$(_modules_build_uid)"
    else
        set -- "$@" --userns=keep-id
    fi
    ax20_run "$@" "$image" --only libdisplay-info --destdir /out/stage --artifact-dir /out/artifact
}

# _hdr_lib_try_container : only on request (`hdr build`).
_hdr_lib_try_container() {
    local out rc=0
    ax20_have podman || {
        log_info "hdr: podman not available, cannot build the Desktop Mode library here"
        return 1
    }
    modules_online || {
        log_info "hdr: offline, cannot build the Desktop Mode library (the build downloads the sources)"
        return 1
    }
    out=$(ax20_path "$AX20_MODULES_CACHE_REL/build-out/hdr")
    ax20_run rm -rf "$out"
    log_info "hdr: building libdisplay-info in a container; the first run downloads the build image and takes a few minutes"
    hdr_lib_container_build "$out" || rc=$?
    if [ "$rc" != 0 ]; then
        log_warn "hdr: the container build failed (exit $rc)"
        return 1
    fi
    [ "$AX20_DRY_RUN" = 1 ] && return 0
    hdr_lib_stage "$out/artifact/$(hdr_ldi_artifact_top)" container "local build"
}

# hdr_lib_resolve [--source cache|release|container]
# Installs our library, trying cache -> release (or only the named source).
# The container build is never tried on its own accord: it downloads a build
# image of about 1 GB, which nobody should get as a side effect of `apply`.
# Prints the source that succeeded. Returns 1 after logging when nothing
# worked, 3 when the library does not apply to this SteamOS; never dies.
hdr_lib_resolve() {
    local only="" order m why
    while [ $# -gt 0 ]; do
        case "$1" in
            --source)
                only=${2:-}
                shift 2 || return 2
                ;;
            *)
                log_error "hdr_lib_resolve: unknown argument '$1'"
                return 2
                ;;
        esac
    done
    case "$only" in
        '') order="cache release" ;;
        cache | release | container) order=$only ;;
        *)
            log_error "unknown source '$only' (cache|release|container)"
            return 2
            ;;
    esac
    if ! why=$(hdr_lib_stock_check); then
        log_info "hdr: $why"
        return 3
    fi
    for m in $order; do
        case "$m" in
            cache) _hdr_lib_try_cache ;;
            release) _hdr_lib_try_release ;;
            container) _hdr_lib_try_container ;;
        esac && {
            printf '%s\n' "$m"
            return 0
        }
    done
    return 1
}
