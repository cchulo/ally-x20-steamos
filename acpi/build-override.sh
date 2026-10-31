#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# acpi/build-override.sh — build the ACPI table-upgrade early initrd that
# clears acp-audio-config-flag on the ROG Xbox Ally X20 (plan §1.1 item 1).
#
#   find the table (Linux, unless --table) -> patch -> verify -> diff -> mkinitrd
#
# On the X20 the flag is NOT in the DSDT: it sits in an SSDT (OEM ID "AMD",
# OEM table ID "OEMACP", /sys/firmware/acpi/tables/SSDT8 on BIOS 303). The
# script therefore scans DSDT and every SSDT* for the property name and
# patches whichever table carries it; the kernel's table upgrade matches the
# replacement by signature + OEM ID + OEM table ID, so only that table is
# replaced.
#
# Usage: acpi/build-override.sh --out <dir> [--table <file>] [--value N] [--all]
#        (--dsdt <file> is accepted as an alias of --table)
#
# Writes into <dir>:
#   ally-x20-steamos-acpi.img  uncompressed newc cpio, kernel/firmware/acpi/<SIG>.aml
#   TABLE.patched.aml          the patched table inside the image
#   TABLE.orig.aml             the unpatched input (kept so a rebuild works
#                              while the override is active)
#   BUILD-INFO                 key=value provenance (see acpi/README.md)
# and prints "<sha256>  <image path>" as the last line of stdout.
#
# It never installs anything; putting the image in front of the initrd chain
# is the audio component's job.
#
# Exit codes: 0 built, 2 invalid table, 3 no override needed (the input
# already has the flag at the target value) or flag not patchable,
# 4 I/O error (no readable table), 5 cached original is from another BIOS
# version, 64 usage.
#
# Paths under /sys honour AX20_ROOT (fixture root) like the rest of the tool.
set -eu

PYTHON="${PYTHON:-python3}"
ACPI_DIR=$(cd "$(dirname "$0")" && pwd)
TOOL="${ACPI_DIR}/patch-acp-flag.py"
IMG_NAME="ally-x20-steamos-acpi.img"

die() {
    code=$1
    shift
    printf 'build-override: %s\n' "$*" >&2
    exit "$code"
}

info() { printf 'build-override: %s\n' "$*" >&2; }

usage() {
    grep '^# Usage:' "$0" | sed 's/^# //' >&2
    exit 64
}

root_path() { printf '%s%s\n' "${AX20_ROOT:-}" "$1"; }

tool() { "$PYTHON" "$TOOL" "$@"; }

sha256_of() {
    "$PYTHON" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

# json_field <table> <python expression over the inspect --json dict "r">
json_field() {
    tool inspect --json "$1" | "$PYTHON" -c 'import json,sys; r=json.load(sys.stdin); print(eval(sys.argv[1]))' "$2"
}

flag_values() {
    json_field "$1" '",".join("0x%x" % s["value"] if s["value"] is not None else "?" for s in r["sites"])'
}

# Prints the current BIOS version, or "unknown".
bios_version() {
    f=$(root_path /sys/class/dmi/id/bios_version)
    if [ -r "$f" ]; then
        tr -d '\n' <"$f"
    else
        printf 'unknown'
    fi
}

# info_get <BUILD-INFO> <key>
info_get() {
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -n 1
}

# find_live_table : print the sysfs table (DSDT or SSDT*) that carries the
# property; nothing printed when none does. A cheap substring grep narrows
# the candidates, then the tool decides (an exact AML string, so a decoy
# such as "acp-audio-config-flag-x" does not count). Unreadable files are
# skipped (root is needed for /sys/firmware/acpi/tables).
find_live_table() {
    dir=$(root_path /sys/firmware/acpi/tables)
    found=""
    for t in "$dir/DSDT" "$dir"/SSDT*; do
        [ -r "$t" ] || continue
        LC_ALL=C grep -aq -- "acp-audio-config-flag" "$t" 2>/dev/null || continue
        case "$(flag_state "$t")" in
            0 | 1)
                found=$t
                break
                ;;
        esac
    done
    [ -n "$found" ] && printf '%s\n' "$found"
    return 0
}

out=""
dsdt=""
value=0
all_flag=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            [ $# -ge 2 ] || usage
            out=$2
            shift 2
            ;;
        --table | --dsdt)
            [ $# -ge 2 ] || usage
            dsdt=$2
            shift 2
            ;;
        --value)
            [ $# -ge 2 ] || usage
            value=$2
            shift 2
            ;;
        --all)
            all_flag="--all"
            shift
            ;;
        -h | --help) usage ;;
        *) usage ;;
    esac
done
[ -n "$out" ] || usage
command -v "$PYTHON" >/dev/null 2>&1 || die 4 "$PYTHON not found"
mkdir -p "$out" || die 4 "cannot create $out"

img="${out}/${IMG_NAME}"
patched="${out}/TABLE.patched.aml"
orig="${out}/TABLE.orig.aml"
buildinfo="${out}/BUILD-INFO"
tmp="${out}/.build-override.$$"
mkdir "$tmp" || die 4 "cannot create $tmp"
trap 'rm -rf "$tmp"' EXIT

# ------------------------------------------------------------------ input --
# verify exit status: 0 = flag already at target, 1 = needs patching.
flag_state() {
    set +e
    tool verify --value "$value" "$1" >/dev/null 2>&1
    rc=$?
    set -e
    echo "$rc"
}

cur_bios=$(bios_version)
if [ -n "$dsdt" ]; then
    [ -r "$dsdt" ] || die 4 "cannot read $dsdt"
    cp "$dsdt" "$tmp/input.aml"
    source_desc="$dsdt"
else
    if [ -z "${AX20_ROOT:-}" ] && [ "$(uname -s)" != "Linux" ]; then
        die 64 "reading the live ACPI tables needs Linux; pass --table <file> (see acpi/dump-dsdt.md)"
    fi
    tables_dir=$(root_path /sys/firmware/acpi/tables)
    [ -r "$tables_dir/DSDT" ] || die 4 "cannot read $tables_dir/DSDT (run as root, or pass --table <file>)"
    sysfs=$(find_live_table)
    [ -n "$sysfs" ] || die 3 "acp-audio-config-flag not found in any table under $tables_dir (DSDT, SSDT*)"
    cat "$sysfs" >"$tmp/live.aml" 2>/dev/null \
        || die 4 "cannot read $sysfs (run as root, or pass --table <file>)"
    info "acp-audio-config-flag lives in $(basename "$sysfs")"
    st=$(flag_state "$tmp/live.aml")
    if [ "$st" = 0 ] && [ -f "$patched" ] && cmp -s "$tmp/live.aml" "$patched"; then
        # Our override is active, so sysfs shows our own table. Rebuild from
        # the original we saved, unless the BIOS changed underneath it.
        [ -f "$orig" ] || die 4 "override active but $orig is missing; boot without the override and rebuild"
        old_bios=$(info_get "$buildinfo" bios_version)
        if [ -n "$old_bios" ] && [ "$old_bios" != "$cur_bios" ]; then
            die 5 "BIOS changed ($old_bios -> $cur_bios) since $orig was dumped; remove the override, reboot and rebuild"
        fi
        info "override active; rebuilding from saved $orig"
        cp "$orig" "$tmp/input.aml"
        source_desc="$orig (saved; live table is our override)"
    else
        cp "$tmp/live.aml" "$tmp/input.aml"
        source_desc="$sysfs"
    fi
fi

st=$(flag_state "$tmp/input.aml")
case "$st" in
    0) die 3 "acp-audio-config-flag is already $value in $source_desc; no override needed" ;;
    1) ;;
    2) die 2 "$source_desc is not a valid ACPI table" ;;
    *) die 3 "acp-audio-config-flag not found in $source_desc" ;;
esac

# ----------------------------------------------------------------- build --
before=$(flag_values "$tmp/input.aml")
# shellcheck disable=SC2086
tool patch $all_flag --value "$value" -o "$tmp/patched.aml" "$tmp/input.aml" >&2 \
    || die "$?" "patch failed"
tool verify --value "$value" "$tmp/patched.aml" >&2 || die "$?" "patched table failed verification"
tool diff --check-expected "$tmp/input.aml" "$tmp/patched.aml" >&2 \
    || die 2 "patched table differs outside the expected bytes"
tool mkinitrd -o "$tmp/image.img" "$tmp/patched.aml" >&2 || die "$?" "mkinitrd failed"
tool list "$tmp/image.img" | grep -Eq ' kernel/firmware/acpi/(DSDT|SSDT)\.aml$' \
    || die 2 "image does not contain kernel/firmware/acpi/<DSDT|SSDT>.aml"
after=$(flag_values "$tmp/patched.aml")

in_sha=$(sha256_of "$tmp/input.aml")
aml_sha=$(sha256_of "$tmp/patched.aml")
img_sha=$(sha256_of "$tmp/image.img")
{
    echo "tool=acpi/build-override.sh"
    echo "tool_version=$(tool --version | sed 's/^[^ ]* //')"
    echo "built_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "input=$source_desc"
    echo "input_sha256=$in_sha"
    echo "patched_aml_sha256=$aml_sha"
    echo "output=$IMG_NAME"
    echo "output_sha256=$img_sha"
    echo "flag_value_before=$before"
    echo "flag_value_after=$after"
    echo "table_signature=$(json_field "$tmp/input.aml" 'r["header"]["signature"]')"
    echo "table_source=$(basename "$source_desc" | cut -d' ' -f1)"
    echo "oem_id=$(json_field "$tmp/input.aml" 'r["header"]["oem_id"]')"
    echo "oem_table_id=$(json_field "$tmp/input.aml" 'r["header"]["oem_table_id"]')"
    echo "oem_revision_before=$(json_field "$tmp/input.aml" '"0x%08x" % r["header"]["oem_revision"]')"
    echo "oem_revision_after=$(json_field "$tmp/patched.aml" '"0x%08x" % r["header"]["oem_revision"]')"
    echo "bios_version=$cur_bios"
} >"$tmp/BUILD-INFO"

# Publish: originals first, the image last so a reader never sees a new image
# with stale provenance.
cp "$tmp/input.aml" "$orig.new" && mv "$orig.new" "$orig"
mv "$tmp/patched.aml" "$patched"
mv "$tmp/BUILD-INFO" "$buildinfo"
mv "$tmp/image.img" "$img"
chmod 0644 "$orig" "$patched" "$buildinfo" "$img"
info "built $img (flag $before -> $after)"
printf '%s  %s\n' "$img_sha" "$img"
