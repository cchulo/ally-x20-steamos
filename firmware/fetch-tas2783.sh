#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# firmware/fetch-tas2783.sh — fetch, verify and install the TAS2783 amplifier
# tuning files for the ROG Xbox Ally X20 (plan §1.1 problem 3).
#
# Usage: firmware/fetch-tas2783.sh [--root <dir>] [--dry-run]
#                                  [--supplier auto|JGX|LS] [--lock <file>]
#                                  [--map <file>] [--source-dir <dir>]
#
# What it does
#   1. Parses firmware/tas2783.lock (pinned linux-firmware commit + sha256).
#   2. Picks the speaker supplier: --supplier / AX20_SPEAKER_SUPPLIER, else a
#      previously saved override, else the SPEAKER_ID UEFI variable mapped
#      through firmware/speaker-id.map.
#   3. Downloads every file of that supplier (all suppliers when unknown) from
#      git.kernel.org, falling back to the mirrors in the lock file, verifies
#      the sha256 and installs it, manifest-tracked, as
#      /var/lib/ally-x20-steamos/firmware/<path in linux-firmware>.
#   4. Links the four-field names newer kernels request
#      (/var/lib/ally-x20-steamos/firmware/1954-<spkid>-0-0x8.bin, ...) for
#      every installed file, and, when the supplier is known, the bare names
#      v7.2.7 requests (1954-0-0x8.bin, ...). Both suppliers share the bare
#      names, so with an unknown supplier those are not created: guessing
#      would load the wrong speaker tuning.
#
# The kernel finds the files through firmware_class.path, which the audio
# component sets (modprobe hook, sysfs at apply time, kernel cmdline via the
# boot-entry step). See firmware/README.md.
#
# AX20_FIRMWARE_SOURCE_DIR=<dir> copies <dir>/<path in linux-firmware>
# instead of downloading (tests, offline installs from a linux-firmware
# checkout). The digest is verified either way.
#
# Sourceable: when sourced it only defines fw_* functions (the audio
# component uses them); fw_main runs only when the file is executed.

if [ -z "${AX20_SRC:-}" ]; then
    AX20_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    export AX20_SRC
fi
# shellcheck source=lib/common.sh
. "$AX20_SRC/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$AX20_SRC/lib/manifest.sh"

FW_COMPONENT="${FW_COMPONENT:-audio}"
FW_STATE_REL="${AX20_STATE_REL}/firmware"
FW_EFIVARS_REL=/sys/firmware/efi/efivars
FW_LOCK="${AX20_FIRMWARE_LOCK:-$AX20_SRC/firmware/tas2783.lock}"
FW_MAP="${AX20_SPEAKER_ID_MAP:-$AX20_SRC/firmware/speaker-id.map}"
# Saved --supplier override (manifest-tracked, so uninstall removes it).
FW_SUPPLIER_FILE_REL="${FW_STATE_REL}/supplier"

# _fw_lines <file> : non-comment, non-blank lines with whitespace squeezed.
_fw_lines() {
    [ -f "$1" ] || return 1
    sed -e 's/#.*$//' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' "$1" | grep -v '^$' || true
}

# fw_lock_get <key> : values of "<key> <value>" lines, in file order.
fw_lock_get() {
    _fw_lines "$FW_LOCK" | awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print }'
}

# fw_lock_files [supplier] : "<supplier> <path> <request> <sha256>" lines.
fw_lock_files() {
    _fw_lines "$FW_LOCK" | awk -v s="${1:-}" '$1 == "file" && (s == "" || $2 == s) { print $2, $3, $4, $5 }'
}

# fw_lock_suppliers : distinct supplier names in lock order.
fw_lock_suppliers() {
    fw_lock_files | awk '!seen[$1]++ { print $1 }'
}

# fw_lock_requests : distinct requested names (what the driver asks for).
fw_lock_requests() {
    fw_lock_files | awk '!seen[$3]++ { print $3 }'
}

# fw_lock_validate : 0 if the lock file is well formed, 1 otherwise (logged).
fw_lock_validate() {
    local commit n=0 bad=0 sup path req sha
    [ -f "$FW_LOCK" ] || {
        log_error "firmware lock file missing: $FW_LOCK"
        return 1
    }
    commit=$(fw_lock_get commit | head -n1)
    if [ "${#commit}" -ne 40 ] || [ -n "$(printf '%s' "$commit" | tr -d '0-9a-f')" ]; then
        log_error "firmware lock: 'commit' must be a 40-character hex sha"
        bad=1
    fi
    [ -n "$(fw_lock_get url | head -n1)" ] || {
        log_error "firmware lock: no 'url' line"
        bad=1
    }
    while read -r sup path req sha; do
        [ -n "$sup" ] || continue
        n=$((n + 1))
        if [ -z "$sha" ] || [ "${#sha}" -ne 64 ] || [ -n "$(printf '%s' "$sha" | tr -d '0-9a-f')" ]; then
            log_error "firmware lock: bad sha256 for $path"
            bad=1
        fi
        case "$path" in
            /* | *..* | '') log_error "firmware lock: unsafe path '$path'" && bad=1 ;;
        esac
        case "$req" in
            */* | *..* | '') log_error "firmware lock: unsafe requested name '$req'" && bad=1 ;;
        esac
    done <<EOF
$(fw_lock_files)
EOF
    [ "$n" -gt 0 ] || {
        log_error "firmware lock: no 'file' lines"
        bad=1
    }
    return "$bad"
}

# fw_speaker_id_file : the SPEAKER_ID-<guid> efivar under the root, if any.
# The GUID is matched by glob so a BIOS update that changes it still works.
fw_speaker_id_file() {
    local d f
    d=$(ax20_path "$FW_EFIVARS_REL")
    [ -d "$d" ] || return 1
    for f in "$d"/SPEAKER_ID-*; do
        [ -f "$f" ] || continue
        printf '%s\n' "$f"
        return 0
    done
    return 1
}

# shellcheck disable=SC2120  # the optional [file] argument is used by tests
# fw_speaker_id [file] : decimal value of the SPEAKER_ID efivar. efivarfs
# files start with a 4-byte little-endian attribute word; the value follows
# (1, 2 or 4+ bytes, little-endian; only the first 4 are read).
fw_speaker_id() {
    local f=${1:-} size width v
    [ -n "$f" ] || f=$(fw_speaker_id_file) || return 1
    [ -r "$f" ] || return 1
    size=$(wc -c <"$f" | tr -d ' ')
    case "$size" in
        '' | 0 | 1 | 2 | 3 | 4) return 1 ;;
        5) width=1 ;;
        6 | 7) width=2 ;;
        *) width=4 ;;
    esac
    # Assemble little-endian by hand so the result does not depend on the
    # host byte order of od.
    v=$(od -An -v -tu1 -j4 -N"$width" "$f" | awk '{ for (i = 1; i <= NF; i++) b[n++] = $i }
        END { v = 0; for (i = n - 1; i >= 0; i--) v = v * 256 + b[i]; if (n) print v }')
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}

# fw_supplier_for_id <value> : supplier name from the map, or fail.
fw_supplier_for_id() {
    local s
    s=$(_fw_lines "$FW_MAP" | awk -v id="$1" '$1 == id { print $2; exit }')
    [ -n "$s" ] || return 1
    printf '%s\n' "$s"
}

# fw_is_supplier <name> : true if the lock knows it.
fw_is_supplier() {
    fw_lock_suppliers | grep -Fxq -- "$1"
}

# fw_resolve_supplier [requested] : print the supplier to install, or
# "unknown". Order: argument / AX20_SPEAKER_SUPPLIER, saved override,
# SPEAKER_ID via the map.
fw_resolve_supplier() {
    local want=${1:-${AX20_SPEAKER_SUPPLIER:-auto}} saved id sup
    if [ "$want" != auto ]; then
        if fw_is_supplier "$want"; then
            printf '%s\n' "$want"
            return 0
        fi
        log_error "unknown speaker supplier '$want' (known: $(fw_lock_suppliers | tr '\n' ' '))"
        return 1
    fi
    saved=$(ax20_path "$FW_SUPPLIER_FILE_REL")
    if [ -f "$saved" ]; then
        sup=$(tr -d ' \n' <"$saved")
        if fw_is_supplier "$sup"; then
            log_debug "speaker supplier from saved override: $sup"
            printf '%s\n' "$sup"
            return 0
        fi
    fi
    if id=$(fw_speaker_id); then
        if sup=$(fw_supplier_for_id "$id") && fw_is_supplier "$sup"; then
            log_info "SPEAKER_ID=$id -> $sup speakers"
            printf '%s\n' "$sup"
            return 0
        fi
        log_warn "SPEAKER_ID=$id is not in $(basename "$FW_MAP"); pass --supplier"
    else
        log_warn "SPEAKER_ID UEFI variable not found under $FW_EFIVARS_REL"
    fi
    printf 'unknown\n'
}

# fw_url <template> <path> <commit>
fw_url() {
    printf '%s\n' "$1" | sed -e "s#%PATH%#$2#g" -e "s#%COMMIT%#$3#g"
}

# _fw_get <url> <out>
_fw_get() {
    if ax20_have curl; then
        curl -fsSL --retry 2 --connect-timeout 15 -o "$2" "$1"
    elif ax20_have wget; then
        wget -q -O "$2" "$1"
    else
        log_error "neither curl nor wget is available"
        return 1
    fi
}

# fw_download <path> <out> : fetch one file (source dir, primary, mirrors).
fw_download() {
    local path=$1 out=$2 commit tpl url
    if [ -n "${AX20_FIRMWARE_SOURCE_DIR:-}" ]; then
        [ -f "$AX20_FIRMWARE_SOURCE_DIR/$path" ] || {
            log_error "firmware source dir lacks $path"
            return 1
        }
        cp "$AX20_FIRMWARE_SOURCE_DIR/$path" "$out"
        return $?
    fi
    commit=$(fw_lock_get commit | head -n1)
    while IFS= read -r tpl; do
        [ -n "$tpl" ] || continue
        url=$(fw_url "$tpl" "$path" "$commit")
        log_debug "fetch $url"
        if _fw_get "$url" "$out"; then
            return 0
        fi
        log_warn "download failed: $url"
    done <<EOF
$(fw_lock_get url)
$(fw_lock_get mirror)
EOF
    return 1
}

# fw_mkdir_tracked <abs-dir> : create a directory chain and record every
# directory we create in the manifest (manifest_install_* only records the
# immediate parent), so uninstall can remove them all once empty.
fw_mkdir_tracked() {
    local d=$1
    [ -d "$(ax20_path "$d")" ] && return 0
    case "$d" in
        / | . | '') return 0 ;;
    esac
    fw_mkdir_tracked "$(dirname "$d")" || return 1
    [ "$(ax20_mkdir_p "$(ax20_path "$d")")" = created ] || return 0
    manifest_record "$d" "$FW_COMPONENT" dir "" shared false
}

# fw_install_one <path> <sha256> : download, verify, install (manifest).
# Skips the download when the installed copy already verifies.
fw_install_one() {
    local path=$1 sha=$2 dest real tmp got
    dest="$FW_STATE_REL/$path"
    real=$(ax20_path "$dest")
    if [ -f "$real" ] && manifest_has "$dest" && [ "$(ax20_sha256 "$real")" = "$sha" ]; then
        log_debug "firmware up to date: $path"
        return 0
    fi
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] fetch %s -> %s (sha256 %s)\n' "$path" "$dest" "$sha" >&2
        return 0
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-fw.XXXXXX") || return 1
    if ! fw_download "$path" "$tmp"; then
        rm -f "$tmp"
        log_error "could not fetch $path"
        return 1
    fi
    got=$(ax20_sha256 "$tmp")
    if [ "$got" != "$sha" ]; then
        rm -f "$tmp"
        log_error "sha256 mismatch for $path: expected $sha, got $got"
        return 1
    fi
    fw_mkdir_tracked "$(dirname "$dest")" || {
        rm -f "$tmp"
        return 1
    }
    manifest_install_file "$tmp" "$dest" "$FW_COMPONENT" 0644 shared
    rm -f "$tmp"
    log_info "firmware installed: $dest"
}

# fw_link_requested <path> <request> : <state>/firmware/<request> -> <path>
# (relative, so the link also resolves inside a mounted slot or fixture root).
fw_link_requested() {
    local path=$1 req=$2 link real
    link="$FW_STATE_REL/$req"
    real=$(ax20_path "$link")
    if [ -L "$real" ] && [ "$(readlink "$real")" = "$path" ] && manifest_has "$link"; then
        return 0
    fi
    manifest_install_symlink "$path" "$link" "$FW_COMPONENT" shared
}

# fw_save_supplier <supplier> : remember an explicit override for later
# applies (boot service), manifest-tracked.
fw_save_supplier() {
    local tmp
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] save supplier override %s\n' "$1" >&2
        return 0
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-sup.XXXXXX") || return 1
    printf '%s\n' "$1" >"$tmp"
    manifest_install_file "$tmp" "$FW_SUPPLIER_FILE_REL" "$FW_COMPONENT" 0644 shared
    rm -f "$tmp"
}

# fw_fetch [supplier|auto] : the whole flow. 0 on success (including the
# "supplier unknown, downloaded everything, no links" case), 1 on failure.
fw_fetch() {
    local want=${1:-${AX20_SPEAKER_SUPPLIER:-auto}} sup s path req sha rc=0
    fw_lock_validate || return 1
    sup=$(fw_resolve_supplier "$want") || return 1
    if [ "$want" != auto ] && [ "${FW_SAVE_OVERRIDE:-1}" = 1 ]; then
        fw_save_supplier "$sup" || return 1
    fi
    while read -r s path req sha; do
        [ -n "$s" ] || continue
        if [ "$sup" = unknown ] || [ "$sup" = "$s" ]; then
            fw_install_one "$path" "$sha" || rc=1
            # Kernels with "ASoC: tas2783-sdw: use the BIOS speaker ID in the
            # firmware name" (Valve 7.2.10-valve1+) request the four-field
            # name itself at the firmware root; it is unambiguous, so link it
            # even when the supplier is unknown.
            [ "$rc" = 0 ] && [ "$AX20_DRY_RUN" != 1 ] && { fw_link_requested "$path" "$(basename "$path")" || rc=1; }
        fi
    done <<EOF
$(fw_lock_files)
EOF
    [ "$rc" = 0 ] || return 1
    if [ "$sup" = unknown ]; then
        log_warn "speaker supplier unknown: downloaded every tuning file but linked none of the requested names (both suppliers share them). Re-run with --supplier JGX|LS; speakers stay silent until then"
        return 0
    fi
    while read -r s path req sha; do
        [ -n "$s" ] || continue
        fw_link_requested "$path" "$req" || return 1
    done <<EOF
$(fw_lock_files "$sup")
EOF
    log_info "TAS2783 tuning for $sup speakers linked under $FW_STATE_REL"
    return 0
}

fw_usage() {
    sed -n 's/^# Usage: //p; s/^#  *\(\[--.*\)$/    \1/p' "${BASH_SOURCE[0]}" >&2
}

fw_main() {
    local supplier=auto
    while [ $# -gt 0 ]; do
        case "$1" in
            --root)
                [ $# -ge 2 ] || die 64 "--root needs a directory"
                AX20_ROOT=${2%/}
                shift 2
                ;;
            --dry-run)
                AX20_DRY_RUN=1
                shift
                ;;
            --supplier)
                [ $# -ge 2 ] || die 64 "--supplier needs JGX|LS|auto"
                supplier=$2
                shift 2
                ;;
            --lock)
                [ $# -ge 2 ] || die 64 "--lock needs a file"
                FW_LOCK=$2
                shift 2
                ;;
            --map)
                [ $# -ge 2 ] || die 64 "--map needs a file"
                FW_MAP=$2
                shift 2
                ;;
            --source-dir)
                [ $# -ge 2 ] || die 64 "--source-dir needs a directory"
                AX20_FIRMWARE_SOURCE_DIR=$2
                shift 2
                ;;
            -h | --help)
                fw_usage
                return 0
                ;;
            *)
                fw_usage
                return 64
                ;;
        esac
    done
    export AX20_ROOT AX20_DRY_RUN
    # shellcheck disable=SC2119  # no arguments to forward
    require_root
    fw_fetch "$supplier"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -eu
    fw_main "$@"
fi
