#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# build/build-inputplumber.sh — FALLBACK ONLY (X20-STEAMOS-PLAN.md §1.2).
#
# Builds upstream InputPlumber at a pinned tag for the case where the stock
# SteamOS daemon is too old for the X20 profile (components/inputplumber.sh
# decides; see docs/inputplumber.md). Output layout under the opt dir:
#   bin/inputplumber            the daemon (selected by the ExecStart drop-in)
#   share/inputplumber/         devices/, capability_maps/, schema/ of the same tag
#   BUILD-INFO                  tag, commit, toolchain, sha256, date
# The output directory is replaced atomically; nothing outside it, the work
# dir and the container engine's storage is written.
#
# Usage: build/build-inputplumber.sh [--tag TAG --commit SHA] [--out DIR]
#            [--work DIR] [--engine podman|docker|host] [--image IMAGE] [--dry-run]
set -eu

AX20_SRC=$(cd "$(dirname "$0")/.." && pwd)
export AX20_SRC
# shellcheck source=lib/common.sh
. "$AX20_SRC/lib/common.sh"

# Pinned upstream release. v0.83.1 (2026-10-26) is v0.83.0 (X20 support, PR
# #756) plus bug fixes; the X20 profile and ally_type2 map are identical.
IP_REPO_URL="https://github.com/ShadowBlip/InputPlumber.git"
IP_TAG="v0.83.1"
IP_COMMIT="b2fb40900506d329925d5a3f1bca54adf85f1279"
# Same Rust as upstream's Dockerfile at that tag (rust:1.92); bookworm keeps
# the glibc requirement low. TODO(vm): pin by digest once verified.
IP_IMAGE="docker.io/library/rust:1.92-bookworm"
AX20_INPUTPLUMBER_OPT_REL="${AX20_INPUTPLUMBER_OPT_REL:-${AX20_OPT_REL}/inputplumber}"
OUT=""
WORK=""
ENGINE=""

usage() {
    sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            IP_TAG=$2
            shift 2
            ;;
        --commit)
            IP_COMMIT=$2
            shift 2
            ;;
        --out)
            OUT=$2
            shift 2
            ;;
        --work)
            WORK=$2
            shift 2
            ;;
        --engine)
            ENGINE=$2
            shift 2
            ;;
        --image)
            IP_IMAGE=$2
            shift 2
            ;;
        --dry-run)
            AX20_DRY_RUN=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die 64 "unknown argument: $1 (see --help)" ;;
    esac
done

[ -n "$OUT" ] || OUT=$(ax20_path "$AX20_INPUTPLUMBER_OPT_REL")
[ -n "$WORK" ] || WORK="$(ax20_state_dir)/build/inputplumber"
if [ -z "$ENGINE" ]; then
    if ax20_have podman; then
        ENGINE=podman
    elif ax20_have docker; then
        ENGINE=docker
    elif ax20_have cargo; then
        ENGINE=host
    else
        die "need podman, docker or a host Rust toolchain (cargo)"
    fi
fi
case "$ENGINE" in podman | docker | host) ;; *) die 64 "bad --engine '$ENGINE'" ;; esac

SRC="$WORK/src"
log_info "inputplumber build: $IP_TAG ($IP_COMMIT) via $ENGINE -> $OUT"

# 1. Source at the pinned tag, verified against the pinned commit.
if [ -d "$SRC/.git" ]; then
    ax20_run git -C "$SRC" fetch --depth 1 origin "refs/tags/$IP_TAG:refs/tags/$IP_TAG"
    ax20_run git -C "$SRC" checkout --force --detach "$IP_TAG"
    ax20_run git -C "$SRC" clean -fdx -e target
else
    ax20_run mkdir -p "$WORK"
    ax20_run git clone --depth 1 --branch "$IP_TAG" "$IP_REPO_URL" "$SRC"
fi
if [ "$AX20_DRY_RUN" != 1 ]; then
    head_commit=$(git -C "$SRC" rev-parse 'HEAD^{commit}')
    [ "$head_commit" = "$IP_COMMIT" ] \
        || die "tag $IP_TAG resolves to $head_commit, expected $IP_COMMIT; refusing to build"
fi

# 2. Optional source patches (GPL-3.0-or-later, see LICENSE.md).
patches=""
for p in "$AX20_SRC"/patches/inputplumber/*.patch; do
    [ -f "$p" ] || continue
    ax20_run git -C "$SRC" apply --index "$p"
    patches="$patches $(basename "$p")"
done

# 3. Build.
build_cmd='cargo build --release --locked && cargo --version > target/release/TOOLCHAIN && rustc --version >> target/release/TOOLCHAIN'
case "$ENGINE" in
    host)
        ax20_run sh -c "cd \"$SRC\" && $build_cmd"
        ;;
    *)
        ax20_run mkdir -p "$WORK/cargo-registry"
        ax20_run "$ENGINE" run --rm \
            -v "$SRC:/src:Z" -v "$WORK/cargo-registry:/usr/local/cargo/registry:Z" \
            -w /src "$IP_IMAGE" sh -ec \
            "apt-get update && apt-get install -y --no-install-recommends libclang-dev libudev-dev pkg-config && $build_cmd"
        ;;
esac

# 4. Stage and swap atomically.
stage="$OUT.new.$$"
if [ "$AX20_DRY_RUN" = 1 ]; then
    printf '[dry-run] stage %s/bin/inputplumber + share/inputplumber + BUILD-INFO into %s\n' "$SRC/target/release" "$OUT" >&2
    exit 0
fi
bin="$SRC/target/release/inputplumber"
[ -x "$bin" ] || die "build produced no binary at $bin"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/share"
cp "$bin" "$stage/bin/inputplumber"
chmod 0755 "$stage/bin/inputplumber"
cp -R "$SRC/rootfs/usr/share/inputplumber" "$stage/share/inputplumber"
{
    printf 'project=%s\n' "$IP_REPO_URL"
    printf 'tag=%s\n' "$IP_TAG"
    printf 'commit=%s\n' "$IP_COMMIT"
    printf 'patches=%s\n' "${patches# }"
    printf 'engine=%s\n' "$ENGINE"
    [ "$ENGINE" = host ] || printf 'image=%s\n' "$IP_IMAGE"
    sed 's/^/toolchain=/' "$SRC/target/release/TOOLCHAIN" 2>/dev/null || true
    printf 'sha256=%s\n' "$(ax20_sha256 "$stage/bin/inputplumber")"
    printf 'built=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'builder=%s %s\n' "$AX20_NAME" "$(ax20_version)"
} >"$stage/BUILD-INFO"
mkdir -p "$(dirname "$OUT")"
if [ -e "$OUT" ]; then
    rm -rf "$OUT.old"
    mv "$OUT" "$OUT.old"
fi
mv "$stage" "$OUT"
rm -rf "$OUT.old"
log_info "inputplumber build installed in $OUT; enable it with: AX20_INPUTPLUMBER_FALLBACK=1 $AX20_NAME apply"
