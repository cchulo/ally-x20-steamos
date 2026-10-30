#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# build/build-hdr.sh — build the HDR userspace pieces for the X20 (plan §1.4).
#
#   (a) libdisplay-info 0.3.0 + the upstream DisplayID 2 CTA backport
#       (patches/libdisplay-info), soname libdisplay-info.so.3, installed with
#       prefix /var/lib/ally-x20-steamos and libdir lib, so the library lands
#       in /var/lib/ally-x20-steamos/lib (selected by the ld.so.conf.d drop-in).
#   (b) gamescope at the version SteamOS ships + PR #2493
#       (patches/gamescope), or upstream 3.17.0 with --gamescope-mode upstream,
#       installed under /opt/ally-x20-steamos/gamescope (HDR_GAMESCOPE_PREFIX).
#
# Runs inside the Arch build container (build/Containerfile; extra packages in
# build/hdr-deps.txt). Never on the SteamOS host. Everything is installed
# into --destdir (default /out); bind-mount the host's
# /var/lib/ally-x20-steamos and /opt/ally-x20-steamos under it, or copy the
# staged tree afterwards.
#
# Usage: build/build-hdr.sh [--destdir DIR] [--workdir DIR]
#                           [--only libdisplay-info|gamescope]
#                           [--gamescope-mode cherry-pick|upstream]
#                           [--gamescope-libdisplay-info bundled|shared]
#                           [--verify-edid FILE] [--jobs N]
#
# The non-build logic (pins, prefix layout, meson arguments, accepted flag
# extraction, BUILD-INFO) is in functions that tests/build/build-hdr.bats
# sources without running main.

if [ -z "${AX20_SRC:-}" ]; then
    AX20_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi
# shellcheck source=lib/common.sh
. "$AX20_SRC/lib/common.sh"

HDR_LOCK_FILE="${HDR_LOCK_FILE:-$AX20_SRC/build/hdr.lock}"
HDR_PATCH_DIR="${HDR_PATCH_DIR:-$AX20_SRC/patches}"
# The one variable that decides where our gamescope lives. overlay/bin/gamescope
# and components/hdr.sh use the same default. TODO(vm): /opt is writable and
# shared between A/B slots on SteamOS; if not, point this under the state dir.
HDR_GAMESCOPE_PREFIX="${HDR_GAMESCOPE_PREFIX:-$AX20_OPT_REL/gamescope}"
HDR_LDI_PREFIX="${HDR_LDI_PREFIX:-$AX20_STATE_REL}"
HDR_BUILD_INFO_VERSION=1

# ------------------------------------------------------------------ pins --
# hdr_lock_get <KEY> : value from build/hdr.lock; fails when missing.
hdr_lock_get() {
    local key=$1 line val=""
    [ -f "$HDR_LOCK_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*)
                val=${line#*=}
                ;;
        esac
    done <"$HDR_LOCK_FILE"
    [ -n "$val" ] || return 1
    printf '%s\n' "$val"
}

# hdr_gamescope_pin <mode> <VERSION|TAG|COMMIT>
hdr_gamescope_pin() {
    case "$1" in
        cherry-pick) hdr_lock_get "GAMESCOPE_$2" ;;
        upstream) hdr_lock_get "GAMESCOPE_UPSTREAM_$2" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------- layout --
hdr_ldi_libdir() { printf '%s/lib\n' "$HDR_LDI_PREFIX"; }
hdr_ldi_bindir() { printf '%s/libdisplay-info/bin\n' "$HDR_LDI_PREFIX"; }
hdr_ldi_build_info() { printf '%s/libdisplay-info/BUILD-INFO\n' "$HDR_LDI_PREFIX"; }
hdr_gamescope_bin() { printf '%s/bin/gamescope\n' "$HDR_GAMESCOPE_PREFIX"; }
hdr_gamescope_build_info() { printf '%s/BUILD-INFO\n' "$HDR_GAMESCOPE_PREFIX"; }
hdr_gamescope_flags_file() { printf '%s/share/%s/accepted-flags\n' "$HDR_GAMESCOPE_PREFIX" "$AX20_NAME"; }

# hdr_ldi_meson_args : one argument per line.
hdr_ldi_meson_args() {
    printf '%s\n' \
        "-Dprefix=$HDR_LDI_PREFIX" \
        "-Dlibdir=lib" \
        "-Dbindir=libdisplay-info/bin" \
        "-Dincludedir=libdisplay-info/include" \
        "-Ddefault_library=shared" \
        "-Dbuildtype=release"
}

# hdr_gamescope_meson_args <bundled|shared> : one argument per line.
# bundled links gamescope's own libdisplay-info submodule statically (what
# SteamOS's package does; 0.4.0 in 3.16.30.1); shared links our .so.3.
hdr_gamescope_meson_args() {
    local fallback="libliftoff,vkroots,wlroots"
    case "$1" in
        bundled) fallback="$fallback,libdisplay-info" ;;
        shared) ;;
        *) return 1 ;;
    esac
    printf '%s\n' \
        "-Dprefix=$HDR_GAMESCOPE_PREFIX" \
        "-Dbuildtype=release" \
        "-Dforce_fallback_for=$fallback" \
        "-Dpipewire=enabled" \
        "-Denable_openvr_support=false" \
        "-Denable_gamescope_wsi_layer=false" \
        "-Denable_tests=false" \
        "-Dbenchmark=disabled"
}

# --------------------------------------------------------------- patches --
# hdr_patch_series <component> : patch file paths in series order.
hdr_patch_series() {
    local dir="$HDR_PATCH_DIR/$1" name
    [ -f "$dir/series" ] || return 1
    while IFS= read -r name || [ -n "$name" ]; do
        case "$name" in '' | '#'*) continue ;; esac
        [ -f "$dir/$name" ] || {
            log_error "patch listed in $dir/series is missing: $name"
            return 1
        }
        printf '%s\n' "$dir/$name"
    done <"$dir/series"
}

# hdr_patch_digests <component> : "name:sha256,name:sha256" (empty if none).
hdr_patch_digests() {
    local p out=""
    for p in $(hdr_patch_series "$1"); do
        out="${out:+$out,}$(basename "$p"):$(ax20_sha256 "$p")"
    done
    printf '%s\n' "$out"
}

# hdr_build_id <component> [mode] : digest of every pinned input, so a
# change of pin or patch gives a different id (the wrapper keys its flag
# cache on it).
hdr_build_id() {
    local comp=$1 mode=${2:-} inputs
    case "$comp" in
        libdisplay-info)
            inputs="ldi|$(hdr_lock_get LDI_COMMIT)|$(hdr_patch_digests libdisplay-info)"
            ;;
        gamescope)
            inputs="gs|$mode|$(hdr_gamescope_pin "$mode" COMMIT)"
            [ "$mode" = cherry-pick ] && inputs="$inputs|$(hdr_patch_digests gamescope)"
            ;;
        *) return 1 ;;
    esac
    ax20_sha256_string "$inputs" | cut -c1-16
}

# ---------------------------------------------------------- flag listing --
# hdr_extract_accepted_flags <src/main.cpp> : every option in gamescope's
# getopt table as "--long" and "-c" lines. `--help` does not list them all
# (3.16.30.1 omits --fade-out-duration, which gamescope-session passes), so
# the wrapper uses this list plus the parsed --help output.
hdr_extract_accepted_flags() {
    [ -f "$1" ] || return 1
    sed -n '/gamescope_options = /,/^};/p' "$1" \
        | sed -n 's/^[[:space:]]*{[[:space:]]*"\([A-Za-z0-9-]*\)".*/\1/p' \
        | sed 's/^/--/'
    sed -n '/gamescope_options = /,/^};/p' "$1" \
        | sed -n "s/^[[:space:]]*{[[:space:]]*\"[A-Za-z0-9-]*\".*'\\([A-Za-z0-9]\\)'[[:space:]]*}.*/\\1/p" \
        | sed 's/^/-/'
}

# ------------------------------------------------------------ BUILD-INFO --
# hdr_write_build_info <dest-file> <key=value>... : stable, sorted-by-call
# order key=value file. The build_info_version line always comes first.
hdr_write_build_info() {
    local dest=$1 kv
    shift
    mkdir -p "$(dirname "$dest")" || return 1
    {
        printf 'build_info_version=%s\n' "$HDR_BUILD_INFO_VERSION"
        for kv in "$@"; do
            case "$kv" in
                *=*) printf '%s\n' "$kv" ;;
                *) return 1 ;;
            esac
        done
    } >"$dest.tmp" && mv -f "$dest.tmp" "$dest"
}

# ----------------------------------------------------------------- build --
_hdr_git_checkout() {
    # _hdr_git_checkout <url> <tag> <commit> <dir> [submodules:0|1]
    local url=$1 tag=$2 commit=$3 dir=$4 subs=${5:-0} got
    rm -rf -- "${dir:?}"
    git init -q "$dir" || return 1
    git -C "$dir" remote add origin "$url" || return 1
    git -C "$dir" fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag" || return 1
    got=$(git -C "$dir" rev-parse "refs/tags/$tag^{commit}") || return 1
    [ "$got" = "$commit" ] || {
        log_error "tag $tag of $url is $got, pinned $commit; refusing to build"
        return 1
    }
    git -C "$dir" -c advice.detachedHead=false checkout -q "$commit" || return 1
    if [ "$subs" = 1 ]; then
        git -C "$dir" submodule update -q --init --recursive --depth 1 || return 1
    fi
}

_hdr_git_am() {
    # _hdr_git_am <dir> <component>
    local p
    for p in $(hdr_patch_series "$2"); do
        GIT_COMMITTER_NAME=ally-x20-steamos GIT_COMMITTER_EMAIL=build@localhost \
            git -C "$1" am -q --keep-cr "$p" || {
            log_error "patch does not apply: $(basename "$p")"
            git -C "$1" am --abort 2>/dev/null
            return 1
        }
    done
}

_hdr_meson_build() {
    # _hdr_meson_build <src> <builddir> <destdir> <args-function> [arg]
    local src=$1 bdir=$2 destdir=$3 fn=$4 arg=${5:-} args
    if [ -n "$arg" ]; then
        args=$("$fn" "$arg") || return 1
    else
        args=$("$fn") || return 1
    fi
    # shellcheck disable=SC2086 # one meson argument per line, no spaces inside
    meson setup "$bdir" "$src" $args || return 1
    ninja -C "$bdir" ${HDR_JOBS:+-j "$HDR_JOBS"} || return 1
    DESTDIR="$destdir" meson install -C "$bdir" --no-rebuild || return 1
}

_hdr_exported_symbols() {
    nm -D --defined-only "$1" | awk 'NF >= 3 { print $3 }' | LC_ALL=C sort -u
}

hdr_build_libdisplay_info() {
    local destdir=$1 work=$2 src base so libdir soname commit
    src="$work/libdisplay-info"
    base="$work/libdisplay-info-baseline"
    commit=$(hdr_lock_get LDI_COMMIT) || die "LDI_COMMIT missing from $HDR_LOCK_FILE"
    soname=$(hdr_lock_get LDI_SONAME) || die "LDI_SONAME missing from $HDR_LOCK_FILE"
    log_info "libdisplay-info: fetching $(hdr_lock_get LDI_TAG) ($commit)"
    _hdr_git_checkout "$(hdr_lock_get LDI_URL)" "$(hdr_lock_get LDI_TAG)" "$commit" "$src" \
        || die "libdisplay-info checkout failed"
    rm -rf -- "${base:?}" && cp -R "$src" "$base"
    _hdr_git_am "$src" libdisplay-info || die "libdisplay-info backport failed"

    # Unpatched baseline, only to compare the exported ABI.
    if ! meson setup "$work/build-ldi-baseline" "$base" -Ddefault_library=shared >/dev/null \
        || ! ninja -C "$work/build-ldi-baseline" >/dev/null; then
        die "libdisplay-info baseline build failed"
    fi
    _hdr_meson_build "$src" "$work/build-ldi" "$destdir" hdr_ldi_meson_args \
        || die "libdisplay-info build failed"

    libdir="$destdir$(hdr_ldi_libdir)"
    so="$libdir/libdisplay-info.so.$(hdr_lock_get LDI_VERSION)"
    [ -f "$so" ] || die "expected $so after install"
    readelf -d "$so" | grep -q "(SONAME).*\[$soname\]" \
        || die "wrong soname in $so (need $soname, or the overlay would be a no-op for stock binaries)"
    _hdr_exported_symbols "$work/build-ldi-baseline/libdisplay-info.so.$(hdr_lock_get LDI_VERSION)" >"$work/sym-base"
    _hdr_exported_symbols "$so" >"$work/sym-new"
    if [ -n "$(LC_ALL=C comm -23 "$work/sym-base" "$work/sym-new")" ]; then
        LC_ALL=C comm -23 "$work/sym-base" "$work/sym-new" >&2
        die "backport dropped exported symbols of $soname"
    fi
    if [ -n "${HDR_VERIFY_EDID:-}" ]; then
        "$destdir$(hdr_ldi_bindir)/di-edid-decode" <"$HDR_VERIFY_EDID" >"$work/edid.txt" 2>&1 || true
        grep -q 'HDR Static Metadata' "$work/edid.txt" \
            || die "di-edid-decode does not report an HDR Static Metadata block for $HDR_VERIFY_EDID"
    fi

    hdr_write_build_info "$destdir$(hdr_ldi_build_info)" \
        "component=libdisplay-info" \
        "build_id=$(hdr_build_id libdisplay-info)" \
        "built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "libdisplay_info_version=$(hdr_lock_get LDI_VERSION)" \
        "libdisplay_info_tag=$(hdr_lock_get LDI_TAG)" \
        "libdisplay_info_commit=$commit" \
        "libdisplay_info_patches=$(hdr_patch_digests libdisplay-info)" \
        "libdisplay_info_soname=$soname" \
        "libdisplay_info_sha256=$(ax20_sha256 "$so")" \
        "libdir=$(hdr_ldi_libdir)" \
        "container_image=${AX20_BUILD_IMAGE:-unknown}" \
        || die "cannot write BUILD-INFO"
    log_info "libdisplay-info: installed $soname into $libdir"
}

hdr_build_gamescope() {
    local destdir=$1 work=$2 mode=$3 ldi=$4 src commit tag version bin args
    src="$work/gamescope"
    commit=$(hdr_gamescope_pin "$mode" COMMIT) || die "unknown gamescope mode '$mode'"
    tag=$(hdr_gamescope_pin "$mode" TAG)
    version=$(hdr_gamescope_pin "$mode" VERSION)
    log_info "gamescope: fetching $tag ($commit), mode $mode"
    _hdr_git_checkout "$(hdr_lock_get GAMESCOPE_URL)" "$tag" "$commit" "$src" 1 \
        || die "gamescope checkout failed"
    if [ "$mode" = cherry-pick ]; then
        _hdr_git_am "$src" gamescope || die "gamescope PR #2493 does not apply to $tag"
    fi
    if [ "$ldi" = shared ]; then
        PKG_CONFIG_SYSROOT_DIR="$destdir"
        PKG_CONFIG_PATH="$destdir$(hdr_ldi_libdir)/pkgconfig"
        export PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_PATH
    fi
    _hdr_meson_build "$src" "$work/build-gamescope" "$destdir" hdr_gamescope_meson_args "$ldi" \
        || die "gamescope build failed"
    bin="$destdir$(hdr_gamescope_bin)"
    [ -x "$bin" ] || die "expected $bin after install"
    "$bin" --help >/dev/null 2>&1 || die "built gamescope does not run '--help'"

    mkdir -p "$(dirname "$destdir$(hdr_gamescope_flags_file)")"
    hdr_extract_accepted_flags "$src/src/main.cpp" | LC_ALL=C sort -u >"$destdir$(hdr_gamescope_flags_file)"
    [ -s "$destdir$(hdr_gamescope_flags_file)" ] || die "could not extract gamescope's option table"
    cp "$HDR_PATCH_DIR/gamescope/LICENSE" "$destdir$HDR_GAMESCOPE_PREFIX/LICENSE"

    args=$(hdr_gamescope_meson_args "$ldi" | tr '\n' ' ')
    hdr_write_build_info "$destdir$(hdr_gamescope_build_info)" \
        "component=gamescope" \
        "build_id=$(hdr_build_id gamescope "$mode")" \
        "built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "gamescope_mode=$mode" \
        "gamescope_version=$version" \
        "gamescope_tag=$tag" \
        "gamescope_commit=$commit" \
        "gamescope_patches=$([ "$mode" = cherry-pick ] && hdr_patch_digests gamescope)" \
        "gamescope_libdisplay_info=$ldi" \
        "gamescope_libdisplay_info_commit=$(git -C "$src/subprojects/libdisplay-info" rev-parse HEAD 2>/dev/null)" \
        "gamescope_sha256=$(ax20_sha256 "$bin")" \
        "gamescope_meson_args=${args% }" \
        "container_image=${AX20_BUILD_IMAGE:-unknown}" \
        || die "cannot write BUILD-INFO"
    log_info "gamescope: installed into $destdir$HDR_GAMESCOPE_PREFIX"
}

hdr_build_main() {
    local destdir=/out work=/tmp/ally-x20-steamos-hdr-build only="" mode=cherry-pick ldi=bundled
    while [ $# -gt 0 ]; do
        case "$1" in
            --destdir) destdir=$2 && shift ;;
            --workdir) work=$2 && shift ;;
            --only) only=$2 && shift ;;
            --gamescope-mode) mode=$2 && shift ;;
            --gamescope-libdisplay-info) ldi=$2 && shift ;;
            --verify-edid) HDR_VERIFY_EDID=$2 && shift ;;
            --jobs) HDR_JOBS=$2 && shift ;;
            -h | --help)
                sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
                return 0
                ;;
            *) die "unknown argument: $1" ;;
        esac
        shift
    done
    case "$mode" in cherry-pick | upstream) ;; *) die "--gamescope-mode must be cherry-pick or upstream" ;; esac
    case "$ldi" in bundled | shared) ;; *) die "--gamescope-libdisplay-info must be bundled or shared" ;; esac
    case "$only" in '' | libdisplay-info | gamescope) ;; *) die "--only must be libdisplay-info or gamescope" ;; esac
    for t in git meson ninja readelf nm; do
        ax20_have "$t" || die "$t not found: run this inside the build container (build/hdr-deps.txt)"
    done
    mkdir -p "$destdir" "$work" || die "cannot create $destdir or $work"
    if [ -z "$only" ] || [ "$only" = libdisplay-info ]; then
        hdr_build_libdisplay_info "$destdir" "$work"
    fi
    if [ -z "$only" ] || [ "$only" = gamescope ]; then
        hdr_build_gamescope "$destdir" "$work" "$mode" "$ldi"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -eu
    hdr_build_main "$@"
fi
