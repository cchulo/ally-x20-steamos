#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# ally-x20-steamos EFI clean-up: the fail-safe for the files we leave on a
# slot's efi partition.
#
# The update component copies this file to
#   /efi/EFI/steamos/ally-x20-steamos-cleanup.sh
# on every slot whose stage-2 grub.cfg lib/slots.sh modifies (the booted slot
# on `apply`, the other slot from the RAUC post-install handler). The efi
# partitions are not wiped by a SteamOS factory reset, so after one the
# marked grub.cfg and the ACPI early initrd survive while nothing else of
# ours does; running this file puts that directory back to stock:
#   sudo sh /efi/EFI/steamos/ally-x20-steamos-cleanup.sh
# The ally-x20-steamos-reset-cleanup.service unit runs it automatically at
# shutdown when a factory reset is pending.
#
# Rules (keep them):
#   * POSIX sh (dash clean); /efi is vfat without exec bits, so it is run as
#     `sh <path>`. The per-directory work needs only awk, mv, rm, sync and a
#     sha256 tool; --all-slots and --if-reset-pending also use mkdir, mount
#     and umount;
#   * it works on one directory: its own (derived from $0) or the one passed
#     as argument (with --all-slots: EFI/steamos of each slot's efi partition,
#     mounted privately). Nothing outside that directory is touched;
#   * inside it, only grub.cfg (and only when it carries our
#     "# ally-x20-steamos-args:" marker), ally-x20-steamos-acpi.img (only when
#     no remaining *.cfg there references it) and ally-x20-steamos-cleanup.sh
#     (unless --keep) are changed;
#   * grub.cfg is rebuilt from the marker exactly like uninstall/uninstall.sh
#     (entry_strip) and lib/slots.sh (_slots_strip) do; keep the three in
#     step. The result is compared to the recorded orig-sha256 (a mismatch is
#     reported but the stripped file is still written: it no longer carries
#     anything of ours), never written empty, and written via a temp file in
#     the same directory, rename, sync;
#   * the whole file is parsed before anything runs (main at the end), so it
#     can delete itself.
#
# Usage: sh ally-x20-steamos-cleanup.sh [--dry-run] [--keep] [DIR]
#        sh ally-x20-steamos-cleanup.sh --all-slots [--if-reset-pending] [--dry-run] [--keep]
#   DIR                 clean this directory instead of the one holding this file
#   --all-slots         clean EFI/steamos on both slots' efi partitions
#                       (/dev/disk/by-partsets/{A,B}/efi, mounted under /run)
#   --if-reset-pending  do nothing unless a SteamOS factory reset is pending
#                       (a *.cfg in efi/steamos/factory-reset/ on the ESP)
#   --dry-run           print what would change, change nothing (--all-slots
#                       still mounts the partitions to look at them)
#   --keep              do not delete ally-x20-steamos-cleanup.sh
#   -h, --help          this text
# Exit codes: 0 done or nothing to do, 1 something could not be cleaned,
# 2 usage error.

NAME="ally-x20-steamos"
MARK="# $NAME"
CFG_NAME="grub.cfg"
IMG_NAME="$NAME-acpi.img"
SELF_NAME="$NAME-cleanup.sh"
# Overridable for tests only.
PARTSETS=${AX20_CLEANUP_PARTSETS:-/dev/disk/by-partsets}
RUNDIR=${AX20_CLEANUP_RUNDIR:-/run/$NAME/efi-cleanup}
ESP=${AX20_CLEANUP_ESP:-/esp}
STATE=${AX20_CLEANUP_STATE:-/var/lib/$NAME}

DRY=0
KEEP=0
ALL=0
IF_RESET=0
DIR=""
RC=0
CHANGED=0
SUMMARY=""

say() { printf '%s: %s\n' "$NAME-cleanup" "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$NAME-cleanup" "$*" >&2; }
fatal() {
    printf '%s: error: %s\n' "$NAME-cleanup" "$*" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage: sh ally-x20-steamos-cleanup.sh [--dry-run] [--keep] [DIR]
       sh ally-x20-steamos-cleanup.sh --all-slots [--if-reset-pending] [--dry-run] [--keep]
Restores the stock grub.cfg from the ally-x20-steamos marker, deletes the
ACPI early initrd once nothing references it, then deletes this script.
  DIR                 clean this directory instead of the one holding this file
  --all-slots         clean EFI/steamos on both slots' efi partitions
  --if-reset-pending  do nothing unless a SteamOS factory reset is pending
  --dry-run           print what would change, change nothing
  --keep              do not delete ally-x20-steamos-cleanup.sh
Files without the ally-x20-steamos marker are never touched.
EOF
}

# sha256_stdin : digest of stdin (empty when no tool is available).
sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{ print $1 }'
    else
        cat >/dev/null
    fi
}

# mark_get <file> <key> : value of one marker line (may be empty).
mark_get() {
    awk -v p="$MARK-$2: " 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }' "$1"
}

# is_marked <file> : carries the lib/slots.sh marker.
is_marked() {
    awk -v p="$MARK-args:" 'index($0, p) == 1 { found = 1; exit } END { exit !found }' "$1" 2>/dev/null
}

# entry_strip <file> <grub|bls> : print the entry without our edits.
# The awk program is uninstall/uninstall.sh's entry_strip, unchanged.
entry_strip() {
    awk -v fmt="$2" -v mark="$MARK" \
        -v args="$(mark_get "$1" args)" \
        -v ref="$(mark_get "$1" initrd)" \
        -v noeol="$(mark_get "$1" noeol)" '
        function kw(n) { return (NF >= n) ? $n : "" }
        function endswith(s, t) { return length(t) > 0 && length(s) >= length(t) && substr(s, length(s) - length(t) + 1) == t }
        function emit(s) { if (n++) printf "\n"; printf "%s", s }
        index($0, mark ":") == 1 || index($0, mark "-") == 1 { next }
        {
            line = $0
            if (fmt == "grub") {
                if ((kw(1) ~ /^linux(efi)?$/ || kw(2) ~ /^linux(efi)?$/) && args != "" && endswith(line, " " args)) {
                    line = substr(line, 1, length(line) - length(args) - 1)
                } else if (ref != "" && (kw(1) ~ /^initrd(efi)?$/ || kw(2) ~ /^initrd(efi)?$/)) {
                    i = index(line, ref " ")
                    if (i > 0) line = substr(line, 1, i - 1) substr(line, i + length(ref) + 1)
                }
            } else {
                if (kw(1) == "options" && args != "" && endswith(line, " " args)) {
                    line = substr(line, 1, length(line) - length(args) - 1)
                } else if (ref != "" && line == "initrd " ref && !done) {
                    done = 1
                    next
                }
            }
            emit(line)
        }
        END { if (n && noeol != 1) printf "\n" }' "$1"
}

# restore_entry <file> : rebuild the original grub.cfg from the marker and
# write it in place. Sets MATCH. Returns 1 (file unchanged) on failure.
restore_entry() {
    re_f=$1
    re_want=$(mark_get "$re_f" orig-sha256)
    re_tmp="$re_f.$NAME.tmp"
    if [ "$DRY" = 1 ]; then
        re_got=$(entry_strip "$re_f" grub | sha256_stdin)
    else
        rm -f "$re_tmp"
        if ! entry_strip "$re_f" grub >"$re_tmp"; then
            rm -f "$re_tmp"
            warn "$re_f: could not strip our edits; left unchanged"
            return 1
        fi
        if [ ! -s "$re_tmp" ]; then
            rm -f "$re_tmp"
            warn "$re_f: stripping our edits leaves nothing; refusing to write an empty boot entry"
            return 1
        fi
        re_got=$(sha256_stdin <"$re_tmp")
    fi
    if [ -z "$re_got" ]; then
        MATCH="digest not checked: no sha256 tool"
    elif [ -z "$re_want" ]; then
        MATCH="no original digest recorded"
    elif [ "$re_got" = "$re_want" ]; then
        MATCH="matches the recorded original digest"
    else
        MATCH="differs from the recorded original digest"
    fi
    if [ "$DRY" = 1 ]; then
        printf '[dry-run] regenerate %s from the %s marker (%s)\n' "$re_f" "$NAME" "$MATCH"
        return 0
    fi
    if ! mv -f "$re_tmp" "$re_f"; then
        rm -f "$re_tmp"
        warn "$re_f: cannot rename the regenerated entry into place; left unchanged"
        return 1
    fi
    sync 2>/dev/null || true
    if [ -n "$re_got" ] && [ -n "$re_want" ] && [ "$re_got" != "$re_want" ]; then
        warn "$re_f: the regenerated entry differs from the recorded original digest (changed since it was modified?); wrote the stripped version anyway"
    else
        say "$re_f: regenerated the original entry ($MATCH)"
    fi
    return 0
}

# img_referenced <dir> <cfg-being-regenerated> : print the *.cfg in <dir>
# that still mentions the early initrd (none: return 1). In a dry run the
# entry that would be regenerated does not count.
img_referenced() {
    for ir_f in "$1"/*.cfg; do
        [ -f "$ir_f" ] || continue
        if [ "$DRY" = 1 ] && [ "$ir_f" = "$2" ]; then continue; fi
        if awk -v t="$IMG_NAME" 'index($0, t) { found = 1; exit } END { exit !found }' "$ir_f"; then
            printf '%s\n' "${ir_f##*/}"
            return 0
        fi
    done
    return 1
}

# rm_file <file>
rm_file() {
    if [ "$DRY" = 1 ]; then
        printf '[dry-run] rm %s\n' "$1"
        return 0
    fi
    rm -f "$1" || return 1
    say "removed $1"
}

# clean_dir <dir> <label> : the per-directory work. Appends to SUMMARY.
clean_dir() {
    cd_dir=$1
    cd_done=""
    cd_regen=""
    cd_cfg="$cd_dir/$CFG_NAME"
    if [ -f "$cd_cfg" ] && [ ! -L "$cd_cfg" ] && is_marked "$cd_cfg"; then
        if restore_entry "$cd_cfg"; then
            cd_regen=$cd_cfg
            cd_done="boot entry restored ($MATCH)"
            CHANGED=1
        else
            cd_done="boot entry NOT restored"
            RC=1
        fi
    fi
    cd_img="$cd_dir/$IMG_NAME"
    if [ -f "$cd_img" ] && [ ! -L "$cd_img" ]; then
        if cd_by=$(img_referenced "$cd_dir" "$cd_regen"); then
            warn "keeping $cd_img: $cd_by still references it"
            cd_done="${cd_done:+$cd_done, }early initrd kept ($cd_by references it)"
            RC=1
        elif rm_file "$cd_img"; then
            cd_done="${cd_done:+$cd_done, }early initrd removed"
            CHANGED=1
        else
            warn "cannot remove $cd_img"
            cd_done="${cd_done:+$cd_done, }early initrd NOT removed"
            RC=1
        fi
    fi
    cd_self="$cd_dir/$SELF_NAME"
    if [ "$KEEP" != 1 ] && [ -f "$cd_self" ] && [ ! -L "$cd_self" ]; then
        # Last: when this is the running file, sh keeps reading the open
        # (already parsed) copy.
        if rm_file "$cd_self"; then
            cd_done="${cd_done:+$cd_done, }clean-up script removed"
        else
            warn "cannot remove $cd_self"
            RC=1
        fi
    fi
    SUMMARY="${SUMMARY:+$SUMMARY; }$2: ${cd_done:-nothing to do}"
}

# mount_dev <device> <dir> : private rw mount (a second mount of a vfat
# partition that autofs already mounted shares its superblock).
mount_dev() {
    mkdir -p "$2" 2>/dev/null || return 1
    mount -t vfat -o rw,noatime "$1" "$2" 2>/dev/null
}

umount_dir() {
    umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null || warn "cannot unmount $1"
    rmdir "$1" 2>/dev/null || true
}

# reset_pending : a SteamOS factory reset is scheduled for the next boot
# (steamos-factory-reset-config leaves *.cfg in efi/steamos/factory-reset/
# on the ESP; the wipe happens in the initramfs). The ESP is mounted
# privately so the answer does not depend on the /esp automount.
reset_pending() {
    if [ -e "$PARTSETS/shared/esp" ]; then
        rp_mnt="$RUNDIR/esp"
        if ! mount_dev "$PARTSETS/shared/esp" "$rp_mnt"; then
            warn "cannot mount $PARTSETS/shared/esp; trying $ESP"
            rp_mnt=$ESP
        fi
    else
        rp_mnt=$ESP
    fi
    rp=1
    for rp_f in "$rp_mnt"/efi/steamos/factory-reset/*.cfg "$rp_mnt"/efi/steamos/factory-reset/*.CFG; do
        if [ -f "$rp_f" ]; then
            rp=0
            break
        fi
    done
    [ "$rp_mnt" = "$ESP" ] || umount_dir "$rp_mnt"
    return "$rp"
}

# all_slots : EFI/steamos on both slots' efi partitions.
all_slots() {
    as_any=0
    for as_slot in A B; do
        as_dev="$PARTSETS/$as_slot/efi"
        [ -e "$as_dev" ] || continue
        as_any=1
        as_mnt="$RUNDIR/efi-$as_slot"
        if ! mount_dev "$as_dev" "$as_mnt"; then
            warn "cannot mount $as_dev"
            rmdir "$as_mnt" 2>/dev/null || true
            SUMMARY="${SUMMARY:+$SUMMARY; }slot $as_slot: efi partition not mounted"
            RC=1
            continue
        fi
        if [ -d "$as_mnt/EFI/steamos" ]; then
            clean_dir "$as_mnt/EFI/steamos" "slot $as_slot"
        else
            SUMMARY="${SUMMARY:+$SUMMARY; }slot $as_slot: no EFI/steamos"
        fi
        umount_dir "$as_mnt"
    done
    if [ "$as_any" = 0 ]; then
        warn "no $PARTSETS/A/efi or B/efi; cleaning $SELF_DIR only"
        clean_dir "$SELF_DIR" "$SELF_DIR"
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY=1 ;;
            --keep) KEEP=1 ;;
            --all-slots) ALL=1 ;;
            --if-reset-pending) IF_RESET=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*) fatal "unknown option: $1 (see --help)" ;;
            *)
                [ -z "$DIR" ] || fatal "only one directory may be given"
                DIR=$1
                ;;
        esac
        shift
    done
    if [ -n "$DIR" ]; then
        [ "$ALL" = 0 ] || fatal "a directory and --all-slots exclude each other"
        [ -d "$DIR" ] || fatal "not a directory: $DIR"
    fi
    case "$0" in
        */*) SELF_DIR=${0%/*} ;;
        *) SELF_DIR=. ;;
    esac
    [ -n "$SELF_DIR" ] || SELF_DIR=/
    SELF_DIR=$(cd "$SELF_DIR" 2>/dev/null && pwd) || fatal "cannot resolve the directory of $0"

    if [ "$IF_RESET" = 1 ] && ! reset_pending; then
        printf '%s: no factory reset pending; nothing to do\n' "$NAME-cleanup"
        exit 0
    fi

    if [ "$ALL" = 1 ]; then
        all_slots
    else
        DIR=${DIR:-$SELF_DIR}
        DIR=$(cd "$DIR" 2>/dev/null && pwd) || fatal "cannot enter $DIR"
        clean_dir "$DIR" "$DIR"
    fi

    if [ "$CHANGED" = 1 ] && [ "$DRY" != 1 ] && [ "$IF_RESET" != 1 ] && [ -f "$STATE/manifest" ]; then
        warn "$NAME is still installed on this system; its boot service puts the boot entry back on the next boot. Use '$NAME uninstall' to remove it for good."
    fi
    printf '%s: %s\n' "$NAME-cleanup" "$SUMMARY"
    exit "$RC"
}

main "$@"
