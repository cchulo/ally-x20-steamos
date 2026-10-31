#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# build/build-libmysofa.sh — FALLBACK ONLY: build libmysofa from source.
#
# Needed only if a SteamOS release ships PipeWire's sofa plugin without the
# libmysofa shared library (audio_dsp_probe_sofa_support returns 1 with the
# plugin present). SteamOS 3.9's pipewire-audio 1.6.8 depends on libmysofa,
# so this is not expected to run. TODO(hw): confirm `ls /usr/lib/libmysofa.so*`.
#
# Output: build/out/libmysofa/var/lib/ally-x20-steamos/lib/libmysofa.so*
# (a DESTDIR tree). The library belongs in /var/lib/ally-x20-steamos/lib,
# which the hdr component's /etc/ld.so.conf.d/00-ally-x20-steamos.conf
# already puts on the dynamic loader path, so PipeWire finds it without
# anything changing on the read-only root. Staging it there (manifest +
# ldconfig) is done by the component that owns that directory.
#
# libmysofa is BSD-3-Clause (Copyright (c) 2016-2017 Symonics GmbH, Christian
# Hoene); its LICENSE is copied next to the library. Run inside the build
# container (build/Containerfile) or any Linux with cmake, a C compiler and
# zlib headers.
#
# usage: build/build-libmysofa.sh [--out DIR]
set -eu

LIBMYSOFA_REPO=https://github.com/hoene/libmysofa.git
LIBMYSOFA_TAG=v1.3.4 # same version as the Arch/SteamOS extra repository
LIBMYSOFA_COMMIT=7a0c07111a3d7230ec534e08925c24a7525f33c0
PREFIX=/var/lib/ally-x20-steamos

here=$(cd "$(dirname "$0")" && pwd)
out="$here/out/libmysofa"
case "${1:-}" in
    --out)
        [ $# -ge 2 ] || {
            echo "build-libmysofa: --out needs a directory" >&2
            exit 2
        }
        out=$2
        ;;
    '') ;;
    *)
        echo "usage: $0 [--out DIR]" >&2
        exit 2
        ;;
esac

for t in git cmake cc; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "build-libmysofa: $t is required (use the build container)" >&2
        exit 1
    }
done

work="$here/cache/libmysofa"
src="$work/src"
bld="$work/build"
if [ ! -d "$src/.git" ]; then
    mkdir -p "$work"
    git clone --quiet --branch "$LIBMYSOFA_TAG" --depth 1 "$LIBMYSOFA_REPO" "$src"
fi
git -C "$src" fetch --quiet --depth 1 origin "refs/tags/$LIBMYSOFA_TAG:refs/tags/$LIBMYSOFA_TAG" || true
git -C "$src" checkout --quiet "$LIBMYSOFA_TAG"
actual=$(git -C "$src" rev-parse HEAD)
if [ "$actual" != "$LIBMYSOFA_COMMIT" ]; then
    echo "build-libmysofa: $LIBMYSOFA_TAG resolves to $actual, expected $LIBMYSOFA_COMMIT; refusing" >&2
    exit 1
fi

rm -rf "$bld" "$out"
cmake -S "$src" -B "$bld" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_TESTS=OFF \
    -DBUILD_STATIC_LIBS=OFF \
    -DBUILD_SHARED_LIBS=ON
cmake --build "$bld" --parallel
DESTDIR="$out" cmake --install "$bld"
mkdir -p "$out$PREFIX/share/licenses/libmysofa"
cp "$src/LICENSE" "$out$PREFIX/share/licenses/libmysofa/LICENSE"

echo "libmysofa $LIBMYSOFA_TAG staged under $out$PREFIX/lib:"
ls -l "$out$PREFIX/lib"/libmysofa.so*
