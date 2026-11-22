# SPDX-License-Identifier: GPL-2.0-only
# Fixtures for the Desktop Mode HDR library suites (tests/lib/hdr.bats,
# tests/cmd/hdr.bats). Load after test_helper, with the hdr component loaded:
#   load '../test_helper'; load '../hdr_helper'

# shellcheck disable=SC2034  # used by the suites that load this file
HDR_ART=hdr-libdisplay-info-0.3.0.tar.zst
# shellcheck disable=SC2034
HDR_TOP=libdisplay-info-0.3.0
HDR_REAL=libdisplay-info.so.0.3.0
# shellcheck disable=SC2034
HDR_STATE=/var/lib/ally-x20-steamos

# hdr_stock <version> : stock libdisplay-info as SteamOS packages it, plus a
# stock gamescope with the Lua helpers our profile needs.
hdr_stock() {
    local v=$1 minor
    minor=$(printf '%s' "$v" | cut -d. -f2)
    fixture_file "/usr/lib/libdisplay-info.so.$v" "ELF libdisplay-info $v"
    ln -sf "libdisplay-info.so.$v" "$AX20_ROOT/usr/lib/libdisplay-info.so.$minor"
    fixture_file /usr/bin/gamescope "ELF gamescope 3.16.30.1"
    fixture_file /usr/share/gamescope/scripts/00-gamescope/common/modegen.lua \
        "gamescope.modegen.adjust_front_porch = function(mode, vfp) end
gamescope.modegen.calc_vrefresh = function(mode, refresh) end"
    fixture_file /usr/share/gamescope/scripts/00-gamescope/common/util.lua \
        "function zero_index(index) return index + 1 end"
}

# hdr_fake_build <dir> [library-content] [key=value overrides...] : an
# artifact directory as build-hdr.sh --artifact-dir leaves it, with a
# BUILD-INFO that matches this checkout unless a key is overridden.
hdr_fake_build() {
    local d=$1 content=${2:-ELF backport v1} kv
    [ $# -le 2 ] || shift 2
    mkdir -p "$d"
    printf '%s' "$content" >"$d/$HDR_REAL"
    printf '#!/bin/sh\nexit 0\n' >"$d/di-edid-decode"
    chmod 0755 "$d/$HDR_REAL" "$d/di-edid-decode"
    cp "$REPO_ROOT/patches/libdisplay-info/LICENSE" "$d/LICENSE"
    hdr_write_build_info "$d/BUILD-INFO" \
        "component=libdisplay-info" \
        "build_id=$(hdr_build_id libdisplay-info)" \
        "built_at=2026-11-22T00:00:00Z" \
        "libdisplay_info_version=$(hdr_lock_get LDI_VERSION)" \
        "libdisplay_info_tag=$(hdr_lock_get LDI_TAG)" \
        "libdisplay_info_commit=$(hdr_lock_get LDI_COMMIT)" \
        "libdisplay_info_patches=$(hdr_patch_digests libdisplay-info)" \
        "libdisplay_info_soname=$(hdr_lock_get LDI_SONAME)" \
        "libdisplay_info_sha256=$(ax20_sha256 "$d/$HDR_REAL")" \
        "libdir=/var/lib/ally-x20-steamos/lib" \
        "container_image=test"
    for kv in "$@"; do
        case "$kv" in
            *=*)
                sed -i.bak "s|^${kv%%=*}=.*|$kv|" "$d/BUILD-INFO"
                rm -f "$d/BUILD-INFO.bak"
                ;;
        esac
    done
}

# hdr_fake_tarball <dest.tar.zst> [library-content] [overrides...] : the
# release asset and its .sha256.
hdr_fake_tarball() {
    local dest=$1 s="$BATS_TEST_TMPDIR/hdr-art.$$.$RANDOM"
    shift
    hdr_fake_build "$s/$HDR_TOP" "$@"
    mkdir -p "$(dirname "$dest")"
    tar -C "$s" -cf - "$HDR_TOP" | zstd -q -f -o "$dest"
    printf '%s  %s\n' "$(ax20_sha256 "$dest")" "$(basename "$dest")" >"$dest.sha256"
    rm -rf "$s"
}

# hdr_stub_bin : a directory of stub curl, podman, ldconfig and chown put
# first on PATH for CLI runs.
#   curl      serves $HDR_SRV/versioned/<name> for .../download/v<ver>/<name>
#             and $HDR_SRV/latest/<name> for .../latest/download/<name>;
#             a HEAD request succeeds unless $HDR_SRV/offline exists.
#             Every URL is appended to $HDR_SRV/curl.log.
#   podman    logs its arguments to $HDR_SRV/podman.log; `run` copies
#             $HDR_SRV/podman-artifact into the directory mounted at /out.
#   ldconfig  touches $HDR_SRV/ldconfig-ran.
hdr_stub_bin() {
    HDR_SRV="$BATS_TEST_TMPDIR/srv"
    HDR_BIN="$BATS_TEST_TMPDIR/stub-bin"
    export HDR_SRV
    mkdir -p "$HDR_SRV/versioned" "$HDR_SRV/latest" "$HDR_BIN"
    cat >"$HDR_BIN/curl" <<'STUB'
#!/bin/bash
dest="" url="" head=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) dest=$2 && shift ;;
        -I) head=1 ;;
        --max-time | --retry | --connect-timeout) shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
if [ "$head" = 1 ]; then
    [ ! -e "$HDR_SRV/offline" ]
    exit $?
fi
printf '%s\n' "$url" >>"$HDR_SRV/curl.log"
[ ! -e "$HDR_SRV/offline" ] || exit 6
case "$url" in
    */latest/download/*) f="$HDR_SRV/latest/${url##*/}" ;;
    *) f="$HDR_SRV/versioned/${url##*/}" ;;
esac
[ -f "$f" ] || exit 22
cp "$f" "$dest"
STUB
    cat >"$HDR_BIN/podman" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$HDR_SRV/podman.log"
out="" prev="" run=0
for a in "$@"; do
    [ "$a" = run ] && run=1
    if [ "$prev" = -v ]; then
        case "$a" in *:/out) out=${a%:/out} ;; esac
    fi
    prev=$a
done
case " $* " in *" image inspect "*) echo sha256:feedface ;; esac
if [ "$run" = 1 ] && [ -d "$HDR_SRV/podman-artifact" ]; then
    mkdir -p "$out/artifact"
    cp -R "$HDR_SRV/podman-artifact/." "$out/artifact/"
fi
[ ! -e "$HDR_SRV/podman-fails" ]
STUB
    printf '#!/bin/sh\ntouch "%s/ldconfig-ran"\n' "$HDR_SRV" >"$HDR_BIN/ldconfig"
    printf '#!/bin/sh\nexit 0\n' >"$HDR_BIN/chown"
    chmod 0755 "$HDR_BIN"/*
}

# hdr_cli <args...> : the real CLI on the fixture root with the stubs first
# on PATH.
hdr_cli() {
    run env PATH="$HDR_BIN:$PATH" "$CLI" --root "$AX20_ROOT" "$@"
}
