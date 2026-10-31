#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# build/build-modules.sh — build the patched kernel modules for one SteamOS
# kernel version (X20-STEAMOS-PLAN.md §3, §4.5).
#
# Runs as the entrypoint of build/Containerfile, or directly on any Linux host
# that has the build dependencies (see build/kernel-sources.md).
#
# Inputs (flags override environment variables):
#   --kver <v>            KVER            target `uname -r`, e.g. 7.2.7-valve2-2-neptune-72-g31504582a073
#   --channel <c>         CHANNEL         package repo searched first (jupiter-main, jupiter-rel, jupiter-staging, ...)
#   --out-dir <d>         OUT_DIR         results go to <d>/<kver>/{*.ko.zst,BUILD-INFO}
#   --cache-dir <d>       CACHE_DIR       headers and sources are cached here between runs
#   --patches-dir <d>     PATCHES_DIR     holds *.patch and modules*.list
#   --kernel-src-url <u>  KERNEL_SRC_URL  explicit Valve source (.src.tar.gz, git URL, or kernel tarball)
#   --vmlinuz <f>         VMLINUZ         target slot's kernel image, for scripts/extract-ikconfig
#   --config <f>          KERNEL_CONFIG   explicit .config for steps 3/4
#   --jobs <n>            JOBS            make -j (default: nproc)
# Provenance passed in by the caller: AX20_COMMIT, CONTAINER_IMAGE,
# CONTAINER_IMAGE_DIGEST.
#
# Header resolution order (BUILD-INFO header_source):
#   1 cached headers         CACHE_DIR/headers/<kver>
#   2 Valve headers package  <mirror>/<channel>/os/x86_64/<pkgbase>-headers-<ver>-<rel>-x86_64.pkg.tar.zst,
#                            sha256 checked against the repo database
#   3 Valve source           evlaV/linux-integration tag (full checkout) or the mirror's .src.tar.gz,
#                            .config from the slot's vmlinuz (extract-ikconfig), make modules_prepare
#   4 linux-stable v<base>   only when every touched file is byte-identical to the cached Valve source
#
# Steps 1 and 2 provide no .c files, so the M= directories are taken from a
# sparse checkout of the exact Valve commit (evlaV tag, verified against the
# -g<commit> suffix). Patches already present in that tree (`git apply
# --check --reverse` succeeds, or the patch names a "Valve-Upstream:" tag
# not newer than the target's) are skipped and recorded as already-upstream;
# a module whose patches are all upstream is not built and is recorded as
# superseded in BUILD-INFO. Only the listed .ko files are built; include/
# headers changed by a patch are searched before the kernel's own.
#
# Every function is side-effect free on load: the script can be sourced by the
# test-suite, which stubs bm_fetch / bm_git / bm_make and calls the pure
# helpers (list parsing, repo-db lookup, BUILD-INFO rendering) directly.

BM_MIRROR_BASE="${BM_MIRROR_BASE:-https://steamdeck-packages.steamos.cloud/archlinux-mirror}"
# Public mirror of gitlab.steamos.cloud/jupiter/linux-integration (which needs
# an account). Tag <x.y.z>-valveN peels to the -g<commit> of `uname -r`.
BM_GIT_URL="${KERNEL_GIT_URL:-https://github.com/evlaV/linux-integration.git}"
BM_STABLE_GIT_URL="${KERNEL_STABLE_GIT_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
# Repos searched after CHANNEL. jupiter-beta is accepted as a name but the
# mirror has no such repo today; beta images pull from jupiter-main.
BM_ALL_CHANNELS="${BM_ALL_CHANNELS:-jupiter-main jupiter-rel jupiter-staging}"
BM_FULL_BUILD="${BM_FULL_BUILD:-1}"
BM_SYMBOL_IGNORE="${BM_SYMBOL_IGNORE:-^$}"

bm_log() { printf 'build-modules: %s\n' "$*" >&2; }
bm_warn() { printf 'build-modules: warning: %s\n' "$*" >&2; }
bm_die() {
    printf 'build-modules: error: %s\n' "$*" >&2
    exit 1
}

bm_usage() {
    sed -n '3,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

bm_have() { command -v "$1" >/dev/null 2>&1; }

bm_sha256() {
    if bm_have sha256sum; then
        sha256sum <"$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# ------------------------------------------------------------ arguments --
bm_parse_args() {
    KVER="${KVER:-}"
    CHANNEL="${CHANNEL:-jupiter-main}"
    OUT_DIR="${OUT_DIR:-$PWD/build/out}"
    CACHE_DIR="${CACHE_DIR:-$PWD/build/cache}"
    PATCHES_DIR="${PATCHES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/patches/kernel}"
    KERNEL_SRC_URL="${KERNEL_SRC_URL:-}"
    VMLINUZ="${VMLINUZ:-}"
    KERNEL_CONFIG="${KERNEL_CONFIG:-}"
    JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --kver | --channel | --out-dir | --cache-dir | --patches-dir | --kernel-src-url | --vmlinuz | --config | --jobs)
                [ $# -ge 2 ] || bm_die "$1 needs a value"
                case "$1" in
                    --kver) KVER=$2 ;;
                    --channel) CHANNEL=$2 ;;
                    --out-dir) OUT_DIR=$2 ;;
                    --cache-dir) CACHE_DIR=$2 ;;
                    --patches-dir) PATCHES_DIR=$2 ;;
                    --kernel-src-url) KERNEL_SRC_URL=$2 ;;
                    --vmlinuz) VMLINUZ=$2 ;;
                    --config) KERNEL_CONFIG=$2 ;;
                    --jobs) JOBS=$2 ;;
                esac
                shift 2
                ;;
            -h | --help)
                bm_usage
                exit 0
                ;;
            *) bm_die "unknown argument: $1 (see --help)" ;;
        esac
    done
    [ -n "$KVER" ] || bm_die "KVER is required (--kver)"
}

# ------------------------------------------------------ version strings --
# bm_parse_kver <kver> : split a SteamOS kernel release into its package
# coordinates. 7.2.7-valve2-2-neptune-72-g31504582a073 gives
#   BM_BASE=7.2.7 BM_EXTRA=valve2 BM_REL=2 BM_FLAVOUR=neptune-72
#   BM_GITHASH=31504582a073 BM_PKGBASE=linux-neptune-72
#   BM_PKGVER=7.2.7.valve2 BM_TAG=7.2.7-valve2
# (PKGBUILD: pkgver=${_tag//-/.}, localversion files "-<pkgrel>" and
# "-neptune-72", plus CONFIG_LOCALVERSION_AUTO's "-g<commit>".)
bm_parse_kver() {
    local k=$1 h
    h=$(printf '%s' "$k" | sed -n 's/.*-g\([0-9a-f]\{7,40\}\)$/\1/p')
    [ -n "$h" ] && k=${k%-g"$h"}
    BM_BASE=$(printf '%s' "$k" | sed -nE 's/^([0-9]+\.[0-9]+(\.[0-9]+)?)-(.+)-([0-9]+)-(neptune.*)$/\1/p')
    [ -n "$BM_BASE" ] || return 1
    BM_EXTRA=$(printf '%s' "$k" | sed -nE 's/^([0-9]+\.[0-9]+(\.[0-9]+)?)-(.+)-([0-9]+)-(neptune.*)$/\3/p')
    BM_REL=$(printf '%s' "$k" | sed -nE 's/^([0-9]+\.[0-9]+(\.[0-9]+)?)-(.+)-([0-9]+)-(neptune.*)$/\4/p')
    BM_FLAVOUR=$(printf '%s' "$k" | sed -nE 's/^([0-9]+\.[0-9]+(\.[0-9]+)?)-(.+)-([0-9]+)-(neptune.*)$/\5/p')
    BM_GITHASH=$h
    BM_PKGBASE="linux-$BM_FLAVOUR"
    BM_PKGVER="$BM_BASE.$(printf '%s' "$BM_EXTRA" | tr '-' '.')"
    BM_TAG="$BM_BASE-$BM_EXTRA"
}

# bm_vermagic_ok <vermagic> <kver> : the first vermagic word is the release.
bm_vermagic_ok() {
    [ -n "$1" ] && [ "${1%% *}" = "$2" ]
}

# ---------------------------------------------------------- module lists --
# bm_list_entries <patches-dir> : "<patch>\t<mdir>\t<ko>" from modules*.list.
# Must stay in sync with modules_list_entries in lib/modules.sh (a test
# compares them).
bm_list_entries() {
    local f
    for f in "$1"/modules*.list; do
        [ -f "$f" ] || continue
        awk -v file="$f" '
            /^[ \t]*(#|$)/ { next }
            {
                if (NF != 3) {
                    printf "%s:%d: expected 3 fields (patch, M= dir, ko name), got %d\n", file, NR, NF > "/dev/stderr"
                    bad = 1; exit 1
                }
                p = $1; m = $2; k = $3
                sub(/^\.\//, "", m); sub(/\/+$/, "", m)
                sub(/\.ko(\.zst|\.xz|\.gz)?$/, "", k)
                if (m ~ /^\// || m ~ /(^|\/)\.\.(\/|$)/ || p ~ /\// || k ~ /\//) {
                    printf "%s:%d: unsafe entry\n", file, NR > "/dev/stderr"
                    bad = 1; exit 1
                }
                printf "%s\t%s\t%s\n", p, m, k
            }
            END { exit bad }
        ' "$f" || return 1
    done
}

# bm_entries_column <n> : distinct values of column n of entries on stdin.
bm_entries_column() { cut -f"$1" | sort -u; }

# bm_kos_for_mdir <mdir> : module names built in one M= dir (entries on stdin).
bm_kos_for_mdir() { awk -F'\t' -v m="$1" '$2 == m { print $3 }' | sort -u; }

# bm_patch_touched_files <patch> : repository paths a patch modifies.
bm_patch_touched_files() {
    awk '
        /^\+\+\+ / || /^--- / {
            p = $2
            if (p == "/dev/null") next
            sub(/^[ab]\//, "", p)
            print p
        }
        /^rename (from|to) / { print $3 }
    ' "$1" | sort -u
}

# bm_check_patch_scope <patches-dir> : entries on stdin; every file a patch
# touches must sit below one of the M= dirs the patch is listed with,
# otherwise a headers based out-of-tree build would silently ignore that part
# of the patch. Two exceptions: Documentation/ (excluded when applying) and
# include/ (patched headers are put ahead of the kernel's include/ for every
# M= build, see bm_include_overlay; every module that uses a changed header
# must then be listed for that patch).
bm_check_patch_scope() {
    local dir=$1 entries p f m ok bad=0
    entries=$(cat)
    for p in $(printf '%s\n' "$entries" | bm_entries_column 1); do
        [ -n "$p" ] || continue
        if [ ! -f "$dir/$p" ]; then
            bm_warn "listed patch not found: $dir/$p"
            bad=1
            continue
        fi
        for f in $(bm_patch_touched_files "$dir/$p"); do
            case "$f" in
                Documentation/* | include/*) continue ;; # see above
            esac
            ok=0
            for m in $(printf '%s\n' "$entries" | awk -F'\t' -v p="$p" '$1 == p { print $2 }'); do
                case "$f" in "$m"/*) ok=1 ;; esac
            done
            if [ "$ok" = 0 ]; then
                bm_warn "$p touches $f, outside M=$(printf '%s\n' "$entries" | awk -F'\t' -v p="$p" '$1 == p { print $2 }' | sort -u | paste -sd, -)"
                bad=1
            fi
        done
    done
    return "$bad"
}

# bm_patch_valve_upstream <patch> : the Valve tag named by a
# "Valve-Upstream: <x.y.z>-valveN" line in the patch description, if any.
# Used for backports whose text cannot reverse-apply on the newer Valve tree
# (Valve carries prerequisites we do not), see bm_patch_state.
bm_patch_valve_upstream() {
    awk '/^---$/ || /^diff --git / { exit } /^Valve-Upstream: / { print $2; exit }' "$1"
}

# bm_tag_key <x.y[.z]-valveN> : fixed-width sort key, empty if malformed.
bm_tag_key() {
    printf '%s\n' "$1" | sed -nE 's/^([0-9]+)\.([0-9]+)(\.([0-9]+))?-valve([0-9]+)$/\1 \2 x\4 \5/p' \
        | awk '{ sub(/^x/, "", $3); printf "%08d%08d%08d%08d\n", $1, $2, $3, $4 }'
}

# bm_tag_ge <tag-a> <tag-b> : Valve tag a is the same as or newer than b.
bm_tag_ge() {
    local a b
    a=$(bm_tag_key "$1")
    b=$(bm_tag_key "$2")
    [ -n "$a" ] && [ -n "$b" ] || return 1
    [ "$a" = "$b" ] || [ "$(printf '%s\n%s\n' "$a" "$b" | sort | tail -n1)" = "$a" ]
}

# -------------------------------------------------------------- repo db --
# bm_unpack_tar <archive> <dir> : extract a tar compressed with zstd, xz,
# gzip or nothing (repo databases are .tar.xz today, packages .tar.zst).
bm_unpack_tar() {
    local magic
    mkdir -p "$2" || return 1
    magic=$(od -An -tx1 -N6 "$1" 2>/dev/null | tr -d ' \n')
    case "$magic" in
        28b52ffd*) zstd -q -dc "$1" | tar -xf - -C "$2" ;;
        fd377a585a00*) xz -dc "$1" | tar -xf - -C "$2" ;;
        1f8b*) gzip -dc "$1" | tar -xf - -C "$2" ;;
        *) tar -xf "$1" -C "$2" ;;
    esac
}

# bm_desc_field <desc-file> <FIELD> : first value of %FIELD% in a pacman desc.
bm_desc_field() {
    awk -v want="%$2%" '
        /^%[A-Z0-9]+%$/ { key = $0; next }
        key == want && $0 != "" { print; exit }
    ' "$1"
}

# bm_repo_db_lookup <db-file> <pkgname> <version> : print
# "<filename>\t<sha256>" for that exact package, return 1 if absent.
bm_repo_db_lookup() {
    local db=$1 name=$2 ver=$3 x d rc=1
    x=$(mktemp -d "${TMPDIR:-/tmp}/bm-db.XXXXXX") || return 1
    if ! bm_unpack_tar "$db" "$x"; then
        rm -rf "$x"
        return 1
    fi
    for d in "$x"/*/desc; do
        [ -f "$d" ] || continue
        [ "$(bm_desc_field "$d" NAME)" = "$name" ] || continue
        [ "$(bm_desc_field "$d" VERSION)" = "$ver" ] || continue
        printf '%s\t%s\n' "$(bm_desc_field "$d" FILENAME)" "$(bm_desc_field "$d" SHA256SUM)"
        rc=0
        break
    done
    rm -rf "$x"
    return "$rc"
}

# bm_repo_db_versions <db-file> <pkgname> : versions present (diagnostics).
bm_repo_db_versions() {
    local x d
    x=$(mktemp -d "${TMPDIR:-/tmp}/bm-db.XXXXXX") || return 1
    bm_unpack_tar "$1" "$x" || {
        rm -rf "$x"
        return 1
    }
    for d in "$x"/*/desc; do
        [ -f "$d" ] || continue
        [ "$(bm_desc_field "$d" NAME)" = "$2" ] && bm_desc_field "$d" VERSION
    done
    rm -rf "$x"
    return 0
}

# ------------------------------------------------- network / build steps --
# Stubbed by tests. Each returns non-zero on failure and never exits.
bm_fetch() { curl -fL --retry 3 --connect-timeout 20 -o "$2" "$1"; }
bm_git() { git -c advice.detachedHead=false "$@"; }
bm_make() { make "$@"; }

# bm_channels : CHANNEL first, then the others, no duplicates.
bm_channels() {
    # shellcheck disable=SC2086  # BM_ALL_CHANNELS is a word list
    printf '%s\n' "$CHANNEL" $BM_ALL_CHANNELS | awk 'NF && !seen[$0]++'
}

# bm_fetch_repo_db <channel> <dest>
bm_fetch_repo_db() {
    bm_fetch "$BM_MIRROR_BASE/$1/os/x86_64/$1.db" "$2"
}

# bm_fetch_package <pkgname> <dest-dir> : find <pkgname> at
# BM_PKGVER-BM_REL in the channels' repo DBs, download, verify. Sets
# BM_PKG_FILE BM_PKG_URL BM_PKG_SHA256 BM_PKG_CHANNEL (call it directly, not
# in a command substitution, or the globals are lost).
bm_fetch_package() {
    local name=$1 dest=$2 ch db hit fn sha
    mkdir -p "$dest" || return 1
    for ch in $(bm_channels); do
        db="$dest/$ch.db"
        if ! bm_fetch_repo_db "$ch" "$db" 2>/dev/null; then
            bm_log "repo $ch: database not reachable"
            continue
        fi
        if ! hit=$(bm_repo_db_lookup "$db" "$name" "$BM_PKGVER-$BM_REL"); then
            bm_log "repo $ch: no $name $BM_PKGVER-$BM_REL (has: $(bm_repo_db_versions "$db" "$name" | tr '\n' ' '))"
            continue
        fi
        fn=$(printf '%s' "$hit" | cut -f1)
        sha=$(printf '%s' "$hit" | cut -f2)
        case "$fn" in */* | '') continue ;; esac
        BM_PKG_URL="$BM_MIRROR_BASE/$ch/os/x86_64/$fn"
        bm_log "downloading $BM_PKG_URL"
        bm_fetch "$BM_PKG_URL" "$dest/$fn" || continue
        if [ "$(bm_sha256 "$dest/$fn")" != "$sha" ]; then
            bm_warn "$fn: sha256 does not match the $ch repo database"
            rm -f "$dest/$fn"
            continue
        fi
        BM_PKG_SHA256=$sha
        BM_PKG_CHANNEL=$ch
        BM_PKG_FILE="$dest/$fn"
        return 0
    done
    return 1
}

# bm_kernelrelease_of <tree> : the release a prepared tree/headers dir is for.
bm_kernelrelease_of() {
    if [ -f "$1/version" ]; then
        head -n1 "$1/version"
    elif [ -f "$1/include/config/kernel.release" ]; then
        head -n1 "$1/include/config/kernel.release"
    fi
}

# bm_headers_valid <dir> : looks like a usable build dir for KVER.
bm_headers_valid() {
    [ -f "$1/Makefile" ] && [ -f "$1/.config" ] && [ -s "$1/Module.symvers" ] \
        && [ "$(bm_kernelrelease_of "$1")" = "$KVER" ]
}

bm_write_provenance() {
    {
        printf 'header_origin=%s\n' "$BM_HEADER_SOURCE"
        printf 'header_origin_name=%s\n' "$BM_HEADER_DESC"
        printf 'header_url=%s\n' "${BM_HEADER_URL:-}"
        printf 'header_sha256=%s\n' "${BM_HEADER_SHA256:-}"
        printf 'channel=%s\n' "${BM_CHANNEL_USED:-}"
    } >"$CACHE_DIR/headers/$KVER.provenance"
}

bm_read_provenance() {
    local f="$CACHE_DIR/headers/$KVER.provenance"
    [ -f "$f" ] || return 0
    BM_HEADER_ORIGIN=$(sed -n 's/^header_origin=//p' "$f")
    BM_HEADER_ORIGIN_DESC=$(sed -n 's/^header_origin_name=//p' "$f")
    BM_HEADER_URL=$(sed -n 's/^header_url=//p' "$f")
    BM_HEADER_SHA256=$(sed -n 's/^header_sha256=//p' "$f")
    BM_CHANNEL_USED=$(sed -n 's/^channel=//p' "$f")
}

# bm_install_headers_dir <src-dir> : move a build dir into the cache.
bm_install_headers_dir() {
    local dst="$CACHE_DIR/headers/$KVER"
    mkdir -p "$CACHE_DIR/headers" || return 1
    rm -rf "$dst.new"
    mv "$1" "$dst.new" || return 1
    rm -rf "$dst"
    mv "$dst.new" "$dst" || return 1
    BM_HEADERS_DIR=$dst
    bm_write_provenance
}

# Step 1.
bm_headers_from_cache() {
    local dir="$CACHE_DIR/headers/$KVER"
    bm_headers_valid "$dir" || return 1
    BM_HEADERS_DIR=$dir
    BM_HEADER_SOURCE=1
    BM_HEADER_DESC=cache
    bm_read_provenance
    bm_log "using cached headers $dir (originally from ${BM_HEADER_ORIGIN_DESC:-unknown})"
}

# Step 2.
bm_headers_from_mirror() {
    local pkg x build
    bm_fetch_package "$BM_PKGBASE-headers" "$WORK/dl" || {
        bm_log "no published headers package for $KVER"
        return 1
    }
    pkg=$BM_PKG_FILE
    x="$WORK/headers-pkg"
    bm_unpack_tar "$pkg" "$x" || return 1
    build="$x/usr/lib/modules/$KVER/build"
    if [ ! -d "$build" ]; then
        bm_warn "headers package has no build dir for $KVER; it contains: $(find "$x/usr/lib/modules" -mindepth 1 -maxdepth 1 -exec basename {} ';' 2>/dev/null | tr '\n' ' ')"
        bm_warn "pass the full 'uname -r' (including any -g<commit> suffix) as KVER"
        return 1
    fi
    bm_headers_valid "$build" || {
        bm_warn "headers package for $KVER is incomplete"
        return 1
    }
    BM_HEADER_SOURCE=2
    BM_HEADER_DESC="valve-headers-package"
    BM_HEADER_URL=$BM_PKG_URL
    BM_HEADER_SHA256=$BM_PKG_SHA256
    BM_CHANNEL_USED=$BM_PKG_CHANNEL
    bm_install_headers_dir "$build" || return 1
    rm -rf "$x" "$pkg"
}

# bm_tree_commit_ok <tree> : HEAD matches the -g<commit> of KVER (if any).
bm_tree_commit_ok() {
    local head
    [ -n "$BM_GITHASH" ] || return 0
    head=$(bm_git -C "$1" rev-parse HEAD 2>/dev/null) || return 1
    case "$head" in
        "$BM_GITHASH"*) return 0 ;;
    esac
    bm_warn "$1 is at $head, but $KVER was built from $BM_GITHASH"
    return 1
}

# bm_src_from_git <url> <ref> <dest> [sparse-dir...] : shallow clone of a
# tag; with sparse dirs only those paths are checked out (blobless clone).
bm_src_from_git() {
    local url=$1 ref=$2 dest=$3
    shift 3
    rm -rf "$dest"
    if [ $# -gt 0 ]; then
        bm_git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$ref" "$url" "$dest" || return 1
        bm_git -C "$dest" sparse-checkout set "$@" || return 1
    else
        bm_git clone --quiet --depth 1 --branch "$ref" "$url" "$dest" || return 1
    fi
    set -- "$url" "$ref" "$dest"
    bm_tree_commit_ok "$3" || return 1
    BM_SOURCE_URL="$1"
    BM_SOURCE_REF="$2@$(bm_git -C "$3" rev-parse HEAD)"
    BM_SOURCE_SHA256=""
}

# bm_pkgbuild_tag <PKGBUILD> : _tag= value, read as text (never sourced).
bm_pkgbuild_tag() {
    sed -n "s/^_tag=['\"]\{0,1\}\([^'\" ]*\)['\"]\{0,1\}[[:space:]]*\$/\1/p" "$1" | head -n1
}

# bm_src_from_srcpkg <file.src.tar.gz> <dest> : Valve's makepkg --allsource
# tarball holds PKGBUILD, config.x86_64, config-neptune and a bare git repo.
bm_src_from_srcpkg() {
    local pkg=$1 dest=$2 x top bare tag
    x="$WORK/srcpkg"
    rm -rf "$x" "$dest"
    bm_unpack_tar "$pkg" "$x" || return 1
    top=$(find "$x" -mindepth 2 -maxdepth 2 -name PKGBUILD | head -n1)
    [ -n "$top" ] || {
        bm_warn "no PKGBUILD in $pkg"
        return 1
    }
    top=$(dirname "$top")
    tag=$(bm_pkgbuild_tag "$top/PKGBUILD")
    bare=$(find "$top" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/HEAD' ';' -print | head -n1)
    [ -n "$tag" ] && [ -n "$bare" ] || {
        bm_warn "unexpected source package layout in $pkg"
        return 1
    }
    bm_git clone --quiet --no-checkout "$bare" "$dest" || return 1
    bm_git -C "$dest" checkout --quiet "refs/tags/$tag" || return 1
    bm_tree_commit_ok "$dest" || return 1
    mkdir -p "$dest/.ax20-config"
    for f in config.x86_64 config-neptune config; do
        [ -f "$top/$f" ] && cp "$top/$f" "$dest/.ax20-config/"
    done
    rm -rf "$x"
    BM_SOURCE_REF="$tag@$(bm_git -C "$dest" rev-parse HEAD)"
}

# bm_sparse_dirs : the first two path components of every M= dir, so that
# relative includes such as sound/soc/amd/acp -> ../../codecs still resolve,
# plus the directory of every include/ header a listed patch touches.
bm_sparse_dirs() {
    local p
    {
        printf '%s\n' "$BM_ENTRIES" | bm_entries_column 2 | awk -F/ '{ print (NF > 1 ? $1 "/" $2 : $1) }'
        for p in $(printf '%s\n' "$BM_ENTRIES" | bm_entries_column 1); do
            [ -f "$PATCHES_DIR/$p" ] || continue
            bm_patch_touched_files "$PATCHES_DIR/$p" | sed -n 's|^\(include/.*\)/[^/]*$|\1|p'
        done
    } | sort -u
}

# bm_sparse_has <dir> : a cached sparse tree covers every bm_sparse_dirs path.
bm_sparse_has() {
    local have want d
    have=$(sed -n 's/^sparse=//p' "$1/.ax20-source" | tr ' ' '\n')
    want=$(bm_sparse_dirs)
    for d in $want; do
        printf '%s\n' "$have" | grep -Fxq -- "$d" || return 1
    done
    return 0
}

# bm_use_cached_source <dir> : adopt a cached tree and its provenance.
bm_use_cached_source() {
    [ -f "$1/.ax20-source" ] || return 1
    BM_VALVE_SRC=$1
    BM_SOURCE_URL=$(sed -n 's/^url=//p' "$1/.ax20-source")
    BM_SOURCE_REF=$(sed -n 's/^ref=//p' "$1/.ax20-source")
    BM_SOURCE_SHA256=$(sed -n 's/^sha256=//p' "$1/.ax20-source")
}

# bm_source_valve_sparse : just the M= directories of the exact Valve commit,
# enough for steps 1/2. Cached in CACHE_DIR/valve-sparse/KVER. Falls back to
# the full source.
bm_source_valve_sparse() {
    local dest="$CACHE_DIR/valve-sparse/$KVER" full="$CACHE_DIR/valve-src/$KVER"
    if [ -f "$full/Makefile" ] && bm_use_cached_source "$full"; then
        return 0
    fi
    if [ -d "$dest" ] && bm_sparse_has "$dest" && bm_use_cached_source "$dest"; then
        return 0
    fi
    if [ -z "$KERNEL_SRC_URL" ]; then
        mkdir -p "$CACHE_DIR/valve-sparse" || return 1
        # shellcheck disable=SC2046
        if bm_src_from_git "$BM_GIT_URL" "$BM_TAG" "$dest.tmp" $(bm_sparse_dirs); then
            printf 'url=%s\nref=%s\nsha256=\nsparse=%s\n' "$BM_SOURCE_URL" "$BM_SOURCE_REF" "$(bm_sparse_dirs | tr '\n' ' ')" >"$dest.tmp/.ax20-source"
            rm -rf "$dest"
            mv "$dest.tmp" "$dest" || return 1
            BM_VALVE_SRC=$dest
            bm_log "Valve source (sparse: $(bm_sparse_dirs | tr '\n' ' ')) from $BM_GIT_URL tag $BM_TAG"
            return 0
        fi
        rm -rf "$dest.tmp"
    fi
    bm_source_valve
}

# bm_source_valve : a pristine, full Valve source tree in
# CACHE_DIR/valve-src/KVER. Sets BM_VALVE_SRC and the BM_SOURCE_* provenance.
bm_source_valve() {
    local dest="$CACHE_DIR/valve-src/$KVER" tmp ch url
    if [ -f "$dest/Makefile" ] && bm_use_cached_source "$dest"; then
        return 0
    fi
    mkdir -p "$CACHE_DIR/valve-src" "$WORK/dl" || return 1
    tmp="$dest.tmp"
    BM_SOURCE_URL="" BM_SOURCE_REF="" BM_SOURCE_SHA256=""
    if [ -n "$KERNEL_SRC_URL" ]; then
        case "$KERNEL_SRC_URL" in
            *.git | git+*)
                bm_src_from_git "${KERNEL_SRC_URL#git+}" "$BM_TAG" "$tmp" || return 1
                ;;
            *)
                bm_fetch "$KERNEL_SRC_URL" "$WORK/dl/src" || return 1
                BM_SOURCE_URL=$KERNEL_SRC_URL
                BM_SOURCE_SHA256=$(bm_sha256 "$WORK/dl/src")
                if [ -n "${KERNEL_SRC_SHA256:-}" ] && [ "$KERNEL_SRC_SHA256" != "$BM_SOURCE_SHA256" ]; then
                    bm_warn "$KERNEL_SRC_URL: sha256 mismatch"
                    return 1
                fi
                case "$KERNEL_SRC_URL" in
                    *.src.tar.gz) bm_src_from_srcpkg "$WORK/dl/src" "$tmp" || return 1 ;;
                    *)
                        rm -rf "$tmp" "$WORK/plain"
                        bm_unpack_tar "$WORK/dl/src" "$WORK/plain" || return 1
                        mv "$(dirname "$(find "$WORK/plain" -mindepth 2 -maxdepth 2 -name Makefile | head -n1)")" "$tmp" || return 1
                        ;;
                esac
                rm -f "$WORK/dl/src"
                ;;
        esac
    elif bm_src_from_git "$BM_GIT_URL" "$BM_TAG" "$tmp" 2>/dev/null; then
        bm_log "Valve source from $BM_GIT_URL tag $BM_TAG"
    else
        # The source package is large (several GB: it embeds the git history).
        for ch in $(bm_channels); do
            url="$BM_MIRROR_BASE/sources/$ch/$BM_PKGBASE-$BM_PKGVER-$BM_REL.src.tar.gz"
            bm_log "trying Valve source package $url"
            bm_fetch "$url" "$WORK/dl/src.tar.gz" || continue
            BM_SOURCE_URL=$url
            BM_SOURCE_SHA256=$(bm_sha256 "$WORK/dl/src.tar.gz")
            if bm_src_from_srcpkg "$WORK/dl/src.tar.gz" "$tmp"; then
                rm -f "$WORK/dl/src.tar.gz"
                break
            fi
            BM_SOURCE_URL=""
        done
        [ -n "$BM_SOURCE_URL" ] || return 1
    fi
    printf 'url=%s\nref=%s\nsha256=%s\n' "$BM_SOURCE_URL" "$BM_SOURCE_REF" "$BM_SOURCE_SHA256" >"$tmp/.ax20-source"
    rm -rf "$dest"
    mv "$tmp" "$dest" || return 1
    BM_VALVE_SRC=$dest
}

# bm_fetch_vmlinuz <dest> : the target kernel image, from VMLINUZ or the
# kernel package on the mirror.
bm_fetch_vmlinuz() {
    local pkg x
    if [ -n "$VMLINUZ" ] && [ -r "$VMLINUZ" ]; then
        cp "$VMLINUZ" "$1"
        return
    fi
    bm_fetch_package "$BM_PKGBASE" "$WORK/dl" || return 1
    pkg=$BM_PKG_FILE
    x="$WORK/kernel-pkg"
    bm_unpack_tar "$pkg" "$x" || return 1
    [ -f "$x/usr/lib/modules/$KVER/vmlinuz" ] || return 1
    mv "$x/usr/lib/modules/$KVER/vmlinuz" "$1"
    rm -rf "$x" "$pkg"
}

# bm_write_config <tree> : .config for KVER, in order: KERNEL_CONFIG, the
# slot's vmlinuz (IKCONFIG), Valve's config.x86_64 + config-neptune.
bm_write_config() {
    local tree=$1
    if [ -n "$KERNEL_CONFIG" ]; then
        cp "$KERNEL_CONFIG" "$tree/.config" && return 0
    fi
    if bm_fetch_vmlinuz "$WORK/vmlinuz" && "$tree/scripts/extract-ikconfig" "$WORK/vmlinuz" >"$tree/.config" 2>/dev/null && [ -s "$tree/.config" ]; then
        bm_log ".config extracted from the target kernel image"
        return 0
    fi
    if [ -f "$tree/.ax20-config/config.x86_64" ]; then
        cp "$tree/.ax20-config/config.x86_64" "$tree/.config"
        if [ -f "$tree/.ax20-config/config-neptune" ]; then
            (cd "$tree" && scripts/kconfig/merge_config.sh -m .config .ax20-config/config-neptune >/dev/null) || return 1
        fi
        bm_log ".config rebuilt from the source package's config files"
        return 0
    fi
    bm_warn "no kernel configuration available (set KERNEL_CONFIG or VMLINUZ)"
    return 1
}

# bm_prepare_tree <src-tree> <how> : copy a source tree, configure it for
# KVER and produce Module.symvers. Used by steps 3 and 4.
bm_prepare_tree() {
    local src=$1 tree="$WORK/prepared" rel
    rm -rf "$tree"
    rsync -a --exclude=.git "$src/" "$tree/" || return 1
    bm_write_config "$tree" || return 1
    bm_make -C "$tree" -s olddefconfig >/dev/null || return 1
    # KERNELRELEASE pins vermagic to KVER regardless of localversion files or
    # git state (the -g<commit> suffix comes from CONFIG_LOCALVERSION_AUTO).
    rel=$(bm_make -C "$tree" -s KERNELRELEASE="$KVER" kernelrelease) || return 1
    if [ "$rel" != "$KVER" ]; then
        bm_warn "prepared tree reports $rel, expected $KVER"
        return 1
    fi
    bm_make -C "$tree" -j"$JOBS" KERNELRELEASE="$KVER" modules_prepare || return 1
    if [ ! -s "$tree/Module.symvers" ]; then
        if [ "$BM_FULL_BUILD" != 1 ]; then
            bm_warn "Module.symvers missing and BM_FULL_BUILD=0"
            return 1
        fi
        # No published Module.symvers: build the kernel once to get it.
        bm_log "building vmlinux and modules once for Module.symvers (slow: tens of minutes)"
        bm_make -C "$tree" -j"$JOBS" KERNELRELEASE="$KVER" vmlinux modules || return 1
        find "$tree" -name '*.o' -delete
    fi
    printf '%s\n' "$KVER" >"$tree/version"
    bm_install_headers_dir "$tree"
}

# Step 3.
bm_headers_from_valve_source() {
    bm_source_valve || {
        bm_log "Valve source for $KVER not available"
        return 1
    }
    BM_HEADER_SOURCE=3
    BM_HEADER_DESC="valve-source+modules_prepare"
    BM_HEADER_URL=$BM_SOURCE_URL
    BM_HEADER_SHA256=$BM_SOURCE_SHA256
    bm_prepare_tree "$BM_VALVE_SRC"
}

# bm_trees_match <tree-a> <tree-b> <path...> : every listed path (files, or
# directories compared recursively) is byte-identical in both trees.
bm_trees_match() {
    local a=$1 b=$2 p f rc=0
    shift 2
    for p in "$@"; do
        if [ -d "$a/$p" ] || [ -d "$b/$p" ]; then
            if [ "$( (cd "$a/$p" 2>/dev/null && find . -type f | sort) | tr '\n' ' ')" != "$( (cd "$b/$p" 2>/dev/null && find . -type f | sort) | tr '\n' ' ')" ]; then
                bm_warn "file set differs under $p"
                rc=1
                continue
            fi
            for f in $(cd "$a/$p" && find . -type f | sort); do
                if [ "$(bm_sha256 "$a/$p/$f")" != "$(bm_sha256 "$b/$p/$f")" ]; then
                    bm_warn "differs from Valve: $p/${f#./}"
                    rc=1
                fi
            done
        elif [ -f "$a/$p" ] && [ -f "$b/$p" ]; then
            if [ "$(bm_sha256 "$a/$p")" != "$(bm_sha256 "$b/$p")" ]; then
                bm_warn "differs from Valve: $p"
                rc=1
            fi
        else
            bm_warn "missing in one tree: $p"
            rc=1
        fi
    done
    return "$rc"
}

# Step 4.
bm_headers_from_stable() {
    local stable="$CACHE_DIR/stable-src/v$BM_BASE" valve="$CACHE_DIR/valve-src/$KVER" paths p
    [ -f "$valve/.ax20-source" ] || valve="$CACHE_DIR/valve-sparse/$KVER"
    if [ ! -f "$valve/.ax20-source" ]; then
        bm_warn "linux-stable fallback refused: no cached Valve source to verify the touched files against"
        return 1
    fi
    if [ ! -f "$stable/Makefile" ]; then
        mkdir -p "$CACHE_DIR/stable-src"
        bm_git clone --quiet --depth 1 --branch "v$BM_BASE" "$BM_STABLE_GIT_URL" "$stable" || return 1
    fi
    paths=$(printf '%s\n' "$BM_ENTRIES" | bm_entries_column 2)
    for p in $(printf '%s\n' "$BM_ENTRIES" | bm_entries_column 1); do
        paths="$paths $(bm_patch_touched_files "$PATCHES_DIR/$p" | tr '\n' ' ')"
    done
    # shellcheck disable=SC2086
    bm_trees_match "$valve" "$stable" $paths || {
        bm_warn "linux-stable v$BM_BASE differs from Valve's tree in the touched files; refusing"
        return 1
    }
    BM_HEADER_SOURCE=4
    BM_HEADER_DESC="linux-stable+modules_prepare"
    BM_HEADER_URL="$BM_STABLE_GIT_URL#v$BM_BASE"
    BM_HEADER_SHA256=""
    BM_TREE_SRC=$stable
    BM_SOURCE_URL="$BM_STABLE_GIT_URL"
    BM_SOURCE_REF="v$BM_BASE@$(bm_git -C "$stable" rev-parse HEAD 2>/dev/null)"
    bm_prepare_tree "$stable"
}

bm_resolve_headers() {
    bm_headers_from_cache && return 0
    bm_headers_from_mirror && return 0
    bm_headers_from_valve_source && return 0
    bm_headers_from_stable && return 0
    return 1
}

# ------------------------------------------------- patch, build, verify --
# bm_make_worktree <src> <dest> : hard-linked copy (cheap); patch(1) writes
# a new file per patched path, so the cached source is never modified.
bm_make_worktree() {
    rm -rf "$2"
    rsync -a --exclude=.git --exclude=.ax20-config --link-dest="$1" "$1/" "$2/"
}

# bm_patch_state <tree> <patch> : applies | upstream | conflict
# A patch whose "Valve-Upstream:" tag is not newer than the target's tag is
# upstream without looking at the tree.
bm_patch_state() {
    local since
    since=$(bm_patch_valve_upstream "$2")
    if [ -n "$since" ] && bm_tag_ge "$BM_TAG" "$since"; then
        echo upstream
    elif (cd "$1" && bm_git apply --check -p1 --exclude='Documentation/*' "$2") >/dev/null 2>&1; then
        echo applies
    elif (cd "$1" && bm_git apply --check --reverse -p1 --exclude='Documentation/*' "$2") >/dev/null 2>&1; then
        echo upstream
    else
        echo conflict
    fi
}

# bm_apply_patches <tree> : apply every listed patch in file-name order on one
# tree. Sets BM_PATCH_STATUS ("<patch> <applied|already-upstream>" lines) and
# BM_SUPERSEDED (modules whose patches are all already upstream).
bm_apply_patches() {
    local tree=$1 p f state k
    BM_PATCH_STATUS=""
    for p in $(printf '%s\n' "$BM_ENTRIES" | bm_entries_column 1); do
        state=$(bm_patch_state "$tree" "$PATCHES_DIR/$p")
        case "$state" in
            upstream)
                bm_log "$p is already in the $KVER source; skipping it"
                BM_PATCH_STATUS="$BM_PATCH_STATUS$p already-upstream
"
                continue
                ;;
            conflict) bm_die "$p does not apply to the $KVER source (neither forward nor reverse)" ;;
        esac
        for f in $(bm_patch_touched_files "$PATCHES_DIR/$p"); do
            # break the hard link to the cache before patching
            if [ -f "$tree/$f" ]; then
                cp -p "$tree/$f" "$tree/$f.ax20" && mv -f "$tree/$f.ax20" "$tree/$f"
            fi
        done
        bm_log "applying $p"
        # Documentation/ hunks are excluded: the sparse source tree has only the
        # M= directories, and docs do not change the built module.
        (cd "$tree" && bm_git apply -p1 --exclude='Documentation/*' "$PATCHES_DIR/$p") || bm_die "applying $p failed"
        BM_PATCH_STATUS="$BM_PATCH_STATUS$p applied
"
    done
    bm_include_overlay "$tree" "$tree.include" || bm_die "cannot stage the patched headers"
    BM_SUPERSEDED=""
    for k in $(printf '%s\n' "$BM_ENTRIES" | bm_entries_column 3); do
        if bm_module_superseded "$k"; then
            bm_log "every patch for $k is already upstream: not building it (superseded)"
            BM_SUPERSEDED="$BM_SUPERSEDED $k"
        fi
    done
}

# bm_module_superseded <ko> : all patches listed for the module are upstream.
bm_module_superseded() {
    local p
    for p in $(printf '%s\n' "$BM_ENTRIES" | awk -F'\t' -v k="$1" '$3 == k { print $1 }'); do
        printf '%s' "$BM_PATCH_STATUS" | grep -qx "$p already-upstream" || return 1
    done
    return 0
}

# bm_is_superseded <ko>
bm_is_superseded() {
    case " $BM_SUPERSEDED " in *" $1 "*) return 0 ;; esac
    return 1
}

# bm_mdir_needed <mdir> : at least one module of the dir must be built.
bm_mdir_needed() {
    local k
    for k in $(printf '%s\n' "$BM_ENTRIES" | bm_kos_for_mdir "$1"); do
        bm_is_superseded "$k" || return 0
    done
    return 1
}

# bm_include_overlay <tree> <dir> : copy the include/ headers changed by the
# applied patches to <dir> (laid out like include/). Sets BM_INCLUDE_OVERLAY
# to <dir>, or to "" when no applied patch changes a header.
bm_include_overlay() {
    local tree=$1 dir=$2 p f
    BM_INCLUDE_OVERLAY=""
    rm -rf "$dir"
    for p in $(printf '%s' "${BM_PATCH_STATUS:-}" | awk '$2 == "applied" { print $1 }'); do
        for f in $(bm_patch_touched_files "$PATCHES_DIR/$p"); do
            case "$f" in include/*) ;; *) continue ;; esac
            [ -f "$tree/$f" ] || continue
            mkdir -p "$dir/$(dirname "${f#include/}")" || return 1
            cp -p "$tree/$f" "$dir/${f#include/}" || return 1
            BM_INCLUDE_OVERLAY=$dir
        done
    done
    [ -z "$BM_INCLUDE_OVERLAY" ] || bm_log "patched headers searched first: $(cd "$dir" && find . -type f | sed 's|^\./||' | tr '\n' ' ')"
}

# bm_make_args <tree> <mdir> : make arguments for one M= dir, one per line.
# Only the listed .ko files are built (kbuild single targets), not every
# module the directory's Makefile configures. Patched headers go ahead of the
# kernel's include/ through NOSTDINC_FLAGS, the only flags kbuild puts before
# LINUXINCLUDE; the top Makefile sets it to just -nostdinc.
bm_make_args() {
    local k
    printf '%s\n' -C "$BM_HEADERS_DIR" "M=$1/$2" "-j$JOBS"
    [ -z "${BM_INCLUDE_OVERLAY:-}" ] || printf '%s\n' "NOSTDINC_FLAGS=-nostdinc -I$BM_INCLUDE_OVERLAY"
    for k in $(printf '%s\n' "$BM_ENTRIES" | bm_kos_for_mdir "$2"); do
        bm_is_superseded "$k" || printf '%s.ko\n' "$k"
    done
}

bm_build_mdirs() {
    local tree=$1 m old_ifs
    for m in $(printf '%s\n' "$BM_ENTRIES" | bm_entries_column 2); do
        bm_mdir_needed "$m" || continue
        bm_log "make M=$m $(printf '%s\n' "$BM_ENTRIES" | bm_kos_for_mdir "$m" | tr '\n' ' ')"
        old_ifs=$IFS
        IFS='
'
        # shellcheck disable=SC2046
        set -- $(bm_make_args "$tree" "$m")
        IFS=$old_ifs
        bm_make "$@" || bm_die "build of M=$m failed"
    done
}

# bm_find_ko <dir> <name> : built object for a module name (- and _ agnostic).
bm_find_ko() {
    local alt
    alt=$(printf '%s' "$2" | tr '_-' '-_')
    find "$1" -type f \( -name "$2.ko" -o -name "$alt.ko" \) | head -n1
}

# bm_symbol_check <undefined-file> <modversions-file> <symvers-file...>
# undefined: one symbol per line (nm -u). modversions: "0xCRC<TAB>symbol"
# (modprobe --dump-modversions; empty without CONFIG_MODVERSIONS).
# Fails listing every symbol not exported by the target kernel or its
# modules, and every CRC that disagrees with Module.symvers.
bm_symbol_check() {
    local undef=$1 vers=$2
    shift 2
    awk -v ignore="$BM_SYMBOL_IGNORE" '
        FILENAME == ARGV[1] { next }
        FILENAME == ARGV[2] { if ($2 != "") want[$2] = $1; next }
        { crc[$2] = $1 }
        END {
            bad = 0
            while ((getline s < ARGV[1]) > 0) {
                if (s == "" || s ~ ignore) continue
                if (!(s in crc)) { print "undefined symbol not exported by the target kernel: " s; bad = 1 }
            }
            for (s in want) {
                if (!(s in crc)) { print "versioned symbol missing from Module.symvers: " s; bad = 1; continue }
                if (crc[s] != "0x00000000" && tolower(crc[s]) != tolower(want[s])) {
                    print "CRC mismatch for " s ": module " want[s] ", kernel " crc[s]; bad = 1
                }
            }
            exit bad
        }
    ' "$undef" "$vers" "$@"
}

# bm_render_build_info <module-dir> : BUILD-INFO on stdout (key=value).
bm_render_build_info() {
    local dir=$1 p f
    printf '# BUILD-INFO written by %s build/build-modules.sh\n' ally-x20-steamos
    printf 'format=1\n'
    printf 'kver=%s\n' "$KVER"
    printf 'vermagic=%s\n' "$BM_VERMAGIC"
    printf 'header_source=%s\n' "$BM_HEADER_SOURCE"
    printf 'header_source_name=%s\n' "$BM_HEADER_DESC"
    if [ "$BM_HEADER_SOURCE" = 1 ]; then
        printf 'header_origin=%s\n' "${BM_HEADER_ORIGIN:-}"
        printf 'header_origin_name=%s\n' "${BM_HEADER_ORIGIN_DESC:-}"
    fi
    printf 'header_url=%s\n' "${BM_HEADER_URL:-}"
    printf 'header_sha256=%s\n' "${BM_HEADER_SHA256:-}"
    printf 'channel=%s\n' "${BM_CHANNEL_USED:-$CHANNEL}"
    printf 'source_url=%s\n' "${BM_SOURCE_URL:-}"
    printf 'source_ref=%s\n' "${BM_SOURCE_REF:-}"
    printf 'source_sha256=%s\n' "${BM_SOURCE_SHA256:-}"
    for p in $(printf '%s\n' "$BM_ENTRIES" | bm_entries_column 1); do
        printf 'patch.%s=%s\n' "$p" "$(bm_sha256 "$PATCHES_DIR/$p")"
        printf 'patch.%s.status=%s\n' "$p" "$(printf '%s' "${BM_PATCH_STATUS:-}" | awk -v p="$p" '$1 == p { print $2; exit }')"
    done
    for f in "$dir"/*.ko.zst; do
        [ -f "$f" ] || continue
        printf 'module.%s=%s\n' "$(basename "$f" .ko.zst)" "$(bm_sha256 "$f")"
    done
    for f in ${BM_SUPERSEDED:-}; do
        printf 'module.%s=superseded\n' "$f"
    done
    printf 'ax20_commit=%s\n' "${AX20_COMMIT:-unknown}"
    printf 'build_date=%s\n' "${BUILD_DATE:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
    printf 'container_image=%s\n' "${CONTAINER_IMAGE:-none}"
    printf 'container_digest=%s\n' "${CONTAINER_IMAGE_DIGEST:-none}"
}

# bm_collect <tree> <stage-dir> : verify and compress every listed module.
bm_collect() {
    local tree=$1 stage=$2 m k ko work vm symvers
    mkdir -p "$stage" || return 1
    work="$WORK/ko"
    mkdir -p "$work"
    symvers="$BM_HEADERS_DIR/Module.symvers"
    BM_VERMAGIC=""
    for m in $(printf '%s\n' "$BM_ENTRIES" | bm_entries_column 2); do
        [ -f "$tree/$m/Module.symvers" ] && symvers="$symvers $tree/$m/Module.symvers"
    done
    for m in $(printf '%s\n' "$BM_ENTRIES" | bm_entries_column 2); do
        for k in $(printf '%s\n' "$BM_ENTRIES" | bm_kos_for_mdir "$m"); do
            bm_is_superseded "$k" && continue
            ko=$(bm_find_ko "$tree/$m" "$k")
            [ -n "$ko" ] || bm_die "M=$m did not produce $k.ko"
            cp "$ko" "$work/$k.ko"
            if bm_have strip; then
                strip --strip-debug "$work/$k.ko" || bm_die "strip $k.ko failed"
            fi
            vm=$(modinfo -F vermagic "$work/$k.ko")
            bm_vermagic_ok "$vm" "$KVER" || bm_die "$k.ko vermagic '$vm' does not match $KVER"
            if [ -n "$BM_VERMAGIC" ] && [ "$vm" != "$BM_VERMAGIC" ]; then
                bm_die "$k.ko vermagic '$vm' differs from other modules ('$BM_VERMAGIC')"
            fi
            BM_VERMAGIC=$vm
            nm -u "$work/$k.ko" | awk '{ print $NF }' >"$work/$k.undef"
            modprobe --dump-modversions "$work/$k.ko" >"$work/$k.vers" 2>/dev/null || : >"$work/$k.vers"
            # shellcheck disable=SC2086
            bm_symbol_check "$work/$k.undef" "$work/$k.vers" $symvers >&2 \
                || bm_die "$k.ko does not link against the $KVER kernel"
            zstd -q -19 -f "$work/$k.ko" -o "$stage/$k.ko.zst" || bm_die "zstd $k.ko failed"
            bm_log "built $k.ko.zst ($vm)"
        done
    done
}

bm_main() {
    local stage
    bm_parse_args "$@"
    bm_parse_kver "$KVER" || bm_die "cannot parse kernel version '$KVER' (expected <x.y.z>-<valveN>-<rel>-neptune[-<series>][-g<commit>])"
    BM_ENTRIES=$(bm_list_entries "$PATCHES_DIR") || bm_die "malformed modules list in $PATCHES_DIR"
    [ -n "$BM_ENTRIES" ] || bm_die "no modules listed in $PATCHES_DIR/modules*.list"
    printf '%s\n' "$BM_ENTRIES" | bm_check_patch_scope "$PATCHES_DIR" || bm_die "patch/list consistency check failed"
    mkdir -p "$CACHE_DIR" "$OUT_DIR" || bm_die "cannot create $CACHE_DIR or $OUT_DIR"
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/ax20-build.XXXXXX") || bm_die "mktemp failed"
    if [ "${BM_KEEP_WORK:-0}" != 1 ]; then
        trap 'rm -rf "$WORK"' EXIT
    fi
    BM_TREE_SRC=""
    bm_log "kernel $KVER ($BM_PKGBASE $BM_PKGVER-$BM_REL, tag $BM_TAG${BM_GITHASH:+, commit $BM_GITHASH})"
    bm_resolve_headers || bm_die "no usable kernel headers for $KVER (tried: cache, Valve headers package, Valve source, linux-stable)"
    bm_log "headers: source $BM_HEADER_SOURCE ($BM_HEADER_DESC) at $BM_HEADERS_DIR"
    if [ -z "$BM_TREE_SRC" ]; then
        bm_source_valve_sparse || bm_die "the Valve source for $KVER is needed to patch the module directories and is unavailable"
        BM_TREE_SRC=$BM_VALVE_SRC
    fi
    bm_make_worktree "$BM_TREE_SRC" "$WORK/tree" || bm_die "cannot create a work tree"
    bm_apply_patches "$WORK/tree"
    bm_build_mdirs "$WORK/tree"
    stage="$OUT_DIR/.$KVER.tmp"
    rm -rf "$stage"
    bm_collect "$WORK/tree" "$stage"
    bm_render_build_info "$stage" >"$stage/BUILD-INFO"
    rm -rf "${OUT_DIR:?}/${KVER:?}"
    mv "$stage" "$OUT_DIR/$KVER" || bm_die "cannot move results into $OUT_DIR/$KVER"
    bm_log "done: $OUT_DIR/$KVER"
    cat "$OUT_DIR/$KVER/BUILD-INFO"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -eu
    bm_main "$@"
fi
