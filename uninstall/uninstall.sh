#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# ally-x20-steamos standalone uninstaller.
#
# This file is copied to /var/lib/ally-x20-steamos/uninstall.sh at install
# time and must keep working when the git checkout is gone, when the
# manifest is partial, when the system is mid-update, from the other slot
# (--root <mountpoint>) and from SteamOS recovery media. Therefore:
#   * POSIX sh only (dash/busybox compatible), no bash-isms;
#   * dependencies: coreutils (rm, mv, cp, mkdir, rmdir, readlink, mktemp),
#     awk, sed, grep, find and a sha256 tool (sha256sum or shasum);
#   * the whole script is parsed before anything runs (main at the end), so it
#     can delete itself safely;
#   * nothing outside the manifest is touched, a deny-list is applied even to
#     manifest entries, and stock-file restores are hash-verified.
#
# Usage: uninstall.sh [--root DIR] [--component NAME]... [--dry-run] [--force]
#                     [--keep-state] [--reboot] [--yes] [--quiet]
#   --root DIR        operate on a mounted root (other slot, recovery) instead of /
#   --component NAME  only remove this component (repeatable); default: everything
#   --dry-run         print every action, change nothing
#   --force           also remove manifest files whose content no longer matches
#                     what we wrote (never anything outside the manifest)
#   --keep-state      keep /var/lib/ally-x20-steamos (manifest, modules, logs)
#   --reboot          reboot when done (live root only)
#   --yes             no confirmation prompt
# Exit codes: 0 done, 1 finished with skipped items (see log), 2 usage/fatal.

NAME="ally-x20-steamos"
TOKEN_RE='ally-x20-steamos|x20'
MARK_BEGIN="# >>> ally-x20-steamos"
MARK_END="# <<< ally-x20-steamos"
US=$(printf '\036')

ROOT=""
DRY=0
FORCE=0
KEEP_STATE=0
REBOOT=0
YES=0
QUIET=0
COMPONENTS=""
SKIPPED=0
REMOVED=0

log() { [ "$QUIET" = 1 ] || printf '%s: %s\n' "$NAME-uninstall" "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$NAME-uninstall" "$*" >&2; }
fatal() {
    printf '%s: error: %s\n' "$NAME-uninstall" "$*" >&2
    exit 2
}
act() {
    # act <description> <cmd...> : run or print.
    desc=$1
    shift
    if [ "$DRY" = 1 ]; then
        printf '[dry-run] %s\n' "$desc"
        return 0
    fi
    log "$desc"
    "$@"
}

rpath() {
    # rpath </abs/path> : prefix with ROOT.
    printf '%s%s\n' "$ROOT" "$1"
}

sha256_of() {
    # Read via stdin: GNU sha256sum escapes file names containing a
    # backslash or newline and prefixes the digest line with "\".
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 <"$1" | cut -d' ' -f1
    else
        fatal "no sha256 tool available"
    fi
}

# ------------------------------------------------------------- manifest --
# Parse the JSON-lines manifest with awk into records separated by the ASCII
# unit separator (0x1e; a tab would be collapsed by `read` when a field is
# empty):  kind US sha256 US created_dir US component US path
# A tiny sequential tokenizer; only the subset our writer emits is supported
# (flat object, string/bool/number values, \" \\ \t \n escapes).
parse_manifest() {
    awk '
    function unescape_string(s, pos,    out, c) {
        out = ""
        while (pos <= length(s)) {
            c = substr(s, pos, 1)
            if (c == "\\") {
                pos++
                c = substr(s, pos, 1)
                if (c == "n") c = "\n"
                else if (c == "t") c = "\t"
                out = out c
            } else if (c == "\"") {
                P = pos + 1
                return out
            } else {
                out = out c
            }
            pos++
        }
        P = pos
        return out
    }
    function skip_ws(s,    c) {
        while (P <= length(s)) {
            c = substr(s, P, 1)
            if (c != " " && c != "\t") break
            P++
        }
    }
    {
        line = $0
        if (line ~ /^[ \t]*$/) next
        P = index(line, "{")
        if (!P) next
        P++
        delete f
        while (P <= length(line)) {
            skip_ws(line)
            c = substr(line, P, 1)
            if (c == "}") break
            if (c == ",") { P++; continue }
            if (c != "\"") break
            key = unescape_string(line, P + 1)
            skip_ws(line)
            if (substr(line, P, 1) != ":") break
            P++
            skip_ws(line)
            c = substr(line, P, 1)
            if (c == "\"") {
                val = unescape_string(line, P + 1)
            } else {
                match(substr(line, P), /^[A-Za-z0-9.+-]+/)
                val = substr(line, P, RLENGTH)
                P += RLENGTH
            }
            f[key] = val
        }
        if (f["path"] == "") next
        printf "%s\036%s\036%s\036%s\036%s\n", f["kind"], f["sha256"], f["created_dir"], f["component"], f["path"]
    }' "$1"
}

reverse_lines() {
    awk '{ l[NR] = $0 } END { for (i = NR; i >= 1; i--) print l[i] }'
}

component_selected() {
    # component_selected <name> : true when no filter or name is in the filter.
    [ -z "$COMPONENTS" ] && return 0
    case " $COMPONENTS " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# ------------------------------------------------------------ deny-list --
# denied <path> : prints a reason and returns 0 when the path must never be
# touched, even if the manifest lists it. Applied before any other check.
denied() {
    p=$1
    case "$p" in
        '' | /)
            echo "root"
            return 0
            ;;
        /usr | /usr/*)
            echo "under /usr"
            return 0
            ;;
        /boot | /boot/*)
            echo "under /boot"
            return 0
            ;;
        /etc/fstab | /etc/passwd | /etc/shadow | /etc/group | /etc/hostname | /etc/machine-id)
            echo "system file"
            return 0
            ;;
        /etc/rauc | /etc/rauc/*)
            echo "rauc config (only the delimited block is restored)"
            return 0
            ;;
        /etc/systemd/system/*.wants | /etc/systemd/system/*.target | /etc/systemd/system/multi-user.target.wants/*)
            case "$p" in *ally-x20-steamos*) ;; *)
                echo "stock systemd unit wiring"
                return 0
                ;;
            esac
            ;;
        /home/*/.steam | /home/*/.steam/* | /home/*/.local/share/Steam | /home/*/.local/share/Steam/*)
            echo "Steam data"
            return 0
            ;;
        /efi | /efi/* | /esp | /esp/*)
            case "$p" in *ally-x20-steamos*) ;; *)
                echo "ESP outside our own files"
                return 0
                ;;
            esac
            ;;
        /dev/* | /proc/* | /sys/* | /run/*)
            echo "virtual filesystem"
            return 0
            ;;
    esac
    if ! printf '%s' "$p" | grep -Eiq "$TOKEN_RE"; then
        echo "path does not contain an $NAME/x20 marker"
        return 0
    fi
    return 1
}

# dir_denied <path> : directories we created may be removed (empty only) even
# without the marker, but never these: top-level system directories, the
# users' home directories, stock systemd/udev/rauc/ESP roots. Drop-in
# directories such as /etc/modprobe.d are NOT protected: if the manifest says
# we created one it did not exist on that system, and removing it when empty
# is exactly the byte-identical restoration we promise.
dir_denied() {
    p=$1
    case "$p" in
        /home/*/*) return 1 ;;
        '' | / | /etc | /var | /var/lib | /home | /home/* | /opt | /usr | /usr/* | /boot | /boot/* | /efi | /esp | /efi/EFI | /esp/loader | /esp/loader/entries | /etc/systemd | /etc/systemd/system | /etc/systemd/user | /etc/udev | /etc/rauc | /dev* | /proc* | /sys* | /run*)
            return 0
            ;;
    esac
    return 1
}

# ------------------------------------------------------------- removal --
remove_file() {
    # remove_file <path> <sha>
    real=$(rpath "$1")
    if [ -L "$real" ]; then
        warn "skip $1: expected a regular file but found a symlink"
        SKIPPED=$((SKIPPED + 1))
        return
    fi
    if [ ! -e "$real" ]; then
        log "already gone: $1"
        return
    fi
    if [ ! -f "$real" ]; then
        warn "skip $1: not a regular file"
        SKIPPED=$((SKIPPED + 1))
        return
    fi
    cur=$(sha256_of "$real")
    if [ "$cur" != "$2" ] && [ "$FORCE" != 1 ]; then
        warn "skip $1: content changed since we wrote it (use --force to remove anyway)"
        SKIPPED=$((SKIPPED + 1))
        return
    fi
    act "rm $1" rm -f "$real" && REMOVED=$((REMOVED + 1))
}

remove_symlink() {
    # remove_symlink <path> <target>
    real=$(rpath "$1")
    if [ ! -L "$real" ]; then
        if [ -e "$real" ]; then
            warn "skip $1: expected a symlink but found something else"
            SKIPPED=$((SKIPPED + 1))
        else
            log "already gone: $1"
        fi
        return
    fi
    tgt=$(readlink "$real")
    if [ "$tgt" != "$2" ] && [ "$FORCE" != 1 ]; then
        warn "skip $1: symlink target changed ($tgt, expected $2); use --force"
        SKIPPED=$((SKIPPED + 1))
        return
    fi
    # rm on a symlink never follows it.
    act "rm symlink $1" rm -f "$real" && REMOVED=$((REMOVED + 1))
}

remove_dir() {
    real=$(rpath "$1")
    [ -d "$real" ] || return 0
    if [ -L "$real" ]; then
        warn "skip dir $1: is a symlink"
        SKIPPED=$((SKIPPED + 1))
        return
    fi
    if [ -n "$(find "$real" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
        log "keep $1: not empty"
        return
    fi
    act "rmdir $1" rmdir "$real" && REMOVED=$((REMOVED + 1))
}

# --------------------------------------------------------- boot entries --
# lib/slots.sh modifies the slot's boot entry (stage-2 grub.cfg on the efi
# partition, or a BLS entry on the ESP) by prepending marker comments
#   # ally-x20-steamos: boot entry modified by ...
#   # ally-x20-steamos-args: <kernel args appended to the kernel line>
#   # ally-x20-steamos-initrd: <early initrd token inserted first>
#   # ally-x20-steamos-noeol: 0|1   (original had no final newline)
#   # ally-x20-steamos-orig-sha256: <sha256 of the original entry>
# and only appending the args / inserting the initrd token. The original is
# therefore recoverable from the live file alone, which matters when the
# saved copy is gone (state dir deleted, factory reset wiped /var but not
# the efi partitions). entry_strip mirrors _slots_strip in lib/slots.sh;
# keep the two in step.
ENTRY_GRUB=/efi/EFI/steamos/grub.cfg
ENTRY_GRUB_DIR=/efi/EFI/steamos
ENTRY_BLS_DIR=/esp/loader/entries
ENTRY_MARK="# $NAME"
HANDLED_ENTRIES=""  # entries the backup pass looked at (newline separated)
RESTORED_ENTRIES="" # entries restored, or that a dry run would restore

# entry_mark_get <real-file> <key> : value of one marker line (may be empty).
entry_mark_get() {
    sed -n "s/^$ENTRY_MARK-$2: //p" "$1" | head -n 1
}

# entry_is_modified <real-file> : carries the lib/slots.sh marker.
entry_is_modified() {
    [ -f "$1" ] && grep -q "^$ENTRY_MARK-args:" "$1" 2>/dev/null
}

# entry_format </abs/path> : grub | bls (empty when neither).
entry_format() {
    case "$1" in
        *.cfg) echo grub ;;
        *.conf) echo bls ;;
    esac
}

# in_list <item> <newline-separated list>
in_list() {
    printf '%s\n' "$2" | grep -Fxq -- "$1"
}

# entry_strip <real-file> <grub|bls> : print the entry without our edits.
entry_strip() {
    awk -v fmt="$2" -v mark="$ENTRY_MARK" \
        -v args="$(entry_mark_get "$1" args)" \
        -v ref="$(entry_mark_get "$1" initrd)" \
        -v noeol="$(entry_mark_get "$1" noeol)" '
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

# entry_regenerate </abs/path> : rebuild the original entry from the marker
# data and write it in place (temp file on the same filesystem, rename,
# sync). The result is checked against the recorded orig-sha256; a mismatch
# still writes the stripped entry (it no longer carries anything of ours)
# but says so, like slots_entry_restore. Never touches a file without our
# marker.
entry_regenerate() {
    rp=$1
    real=$(rpath "$rp")
    RESTORED_ENTRIES="$RESTORED_ENTRIES
$rp"
    if [ -L "$real" ] || ! entry_is_modified "$real"; then
        log "restore $rp: no $NAME marker; leaving it alone"
        return 0
    fi
    fmt=$(entry_format "$rp")
    if [ -z "$fmt" ]; then
        warn "restore $rp: unknown boot entry format; not regenerating"
        SKIPPED=$((SKIPPED + 1))
        return 1
    fi
    want=$(entry_mark_get "$real" orig-sha256)
    stripped=$(mktemp "${TMPDIR:-/tmp}/$NAME-entry.XXXXXX") || fatal "mktemp failed"
    if ! entry_strip "$real" "$fmt" >"$stripped"; then
        rm -f "$stripped"
        warn "restore $rp: could not strip our edits; left unchanged"
        SKIPPED=$((SKIPPED + 1))
        return 1
    fi
    got=$(sha256_of "$stripped")
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
        match="matches the recorded original digest"
    elif [ -n "$want" ]; then
        match="differs from the recorded original digest"
    else
        match="no original digest recorded"
    fi
    if [ "$DRY" = 1 ]; then
        rm -f "$stripped"
        printf '[dry-run] regenerate %s from the %s marker (%s)\n' "$rp" "$NAME" "$match"
        return 0
    fi
    tmp=$(mktemp "$real.XXXXXX") || {
        rm -f "$stripped"
        fatal "mktemp failed next to $rp"
    }
    if ! cat "$stripped" >"$tmp"; then
        rm -f "$stripped" "$tmp"
        warn "restore $rp: cannot write $tmp; left unchanged"
        SKIPPED=$((SKIPPED + 1))
        return 1
    fi
    rm -f "$stripped"
    # vfat has no modes; elsewhere keep the live file's.
    chmod --reference="$real" "$tmp" 2>/dev/null || chmod 0644 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$real"; then
        rm -f "$tmp"
        warn "restore $rp: cannot rename into place; left unchanged"
        SKIPPED=$((SKIPPED + 1))
        return 1
    fi
    if command -v sync >/dev/null 2>&1; then sync 2>/dev/null || true; fi
    REMOVED=$((REMOVED + 1))
    if [ -n "$want" ] && [ "$got" != "$want" ]; then
        warn "regenerated entry $rp differs from the recorded original digest (changed since we modified it?); keeping the stripped version"
    else
        log "restore $rp: regenerated the original entry from the $NAME marker ($match)"
    fi
    return 0
}

# entry_candidates : root-relative paths of the boot entries lib/slots.sh may
# have modified, whether or not a backup exists for them.
entry_candidates() {
    [ -f "$(rpath "$ENTRY_GRUB")" ] && printf '%s\n' "$ENTRY_GRUB"
    for f in "$(rpath "$ENTRY_BLS_DIR")"/*.conf; do
        [ -f "$f" ] && printf '%s\n' "${f#"$ROOT"}"
    done
    return 0
}

# restore_orphan_entries : boot entries that carry our marker but had no
# backup record at all (the state dir is gone) are regenerated from the
# marker. Part of component "update", which owns the boot entry.
restore_orphan_entries() {
    component_selected update || return 0
    list=$(entry_candidates)
    old_ifs=$IFS
    IFS='
'
    for rp in $list; do
        IFS=$old_ifs
        in_list "$rp" "$HANDLED_ENTRIES" && continue
        entry_is_modified "$(rpath "$rp")" || continue
        warn "boot entry $rp carries the $NAME marker but no saved original exists; regenerating the original entry from the marker"
        entry_regenerate "$rp"
    done
    IFS=$old_ifs
}

# entry_referencing </abs/image-path> : print the boot entry that still
# points at this early initrd through our marker (none: return 1). An entry
# a dry run would restore does not count.
entry_referencing() {
    img=$1
    list=$(entry_candidates)
    old_ifs=$IFS
    IFS='
'
    for rp in $list; do
        IFS=$old_ifs
        real=$(rpath "$rp")
        entry_is_modified "$real" || continue
        if [ "$DRY" = 1 ] && in_list "$rp" "$RESTORED_ENTRIES"; then continue; fi
        ref=$(entry_mark_get "$real" initrd)
        [ -n "$ref" ] || continue
        case "$(entry_format "$rp")" in
            grub)
                # shellcheck disable=SC2016  # a literal GRUB variable
                case "$ref" in
                    '${cmdpath}/'*) abs="$ENTRY_GRUB_DIR/${ref#'${cmdpath}/'}" ;;
                    *) continue ;;
                esac
                ;;
            bls) abs="/esp$ref" ;;
            *) continue ;;
        esac
        if [ "$abs" = "$img" ]; then
            IFS=$old_ifs
            printf '%s\n' "$rp"
            return 0
        fi
    done
    IFS=$old_ifs
    return 1
}

# ------------------------------------------------------------- backups --
# Saved originals live in <state>/backup/<id>/ with:
#   original   the stock file bytes as they were before we touched them
#   meta       key=value lines: path=, sha256= (of original), type=file|block
# type=file  : restore byte-for-byte (only if 'original' still hashes to sha256)
# type=block : remove our delimited block from the live file; if the result
#              equals 'original' nothing else to do, otherwise keep the
#              stripped file (Valve may have changed it since) and say so.
# A boot entry carrying the lib/slots.sh marker whose saved copy is missing,
# corrupt or older than the entry is regenerated from the marker instead
# (entry_regenerate).
# Backups are restored before the manifest walk so a restored stock file is
# never mistaken for one of ours.
restore_backups() {
    bdir=$(rpath "/var/lib/$NAME/backup")
    [ -d "$bdir" ] || return 0
    for d in "$bdir"/*/; do
        [ -d "$d" ] || continue
        d=${d%/}
        borig="$d/original"
        bpath=""
        bsha=""
        btype=""
        bcomp=""
        if [ -f "$d/meta" ]; then
            # Generic layout: original + meta (path=, sha256=, type=, component=).
            bpath=$(sed -n 's/^path=//p' "$d/meta" | head -n 1)
            bsha=$(sed -n 's/^sha256=//p' "$d/meta" | head -n 1)
            btype=$(sed -n 's/^type=//p' "$d/meta" | head -n 1)
            bcomp=$(sed -n 's/^component=//p' "$d/meta" | head -n 1)
        elif [ -f "$d/entry-path" ]; then
            # lib/slots.sh layout: backup/<slot>/<entry file>, <file>.sha256, entry-path.
            bpath=$(head -n 1 "$d/entry-path")
            borig="$d/$(basename "$bpath")"
            [ -f "$borig.sha256" ] && bsha=$(head -n 1 "$borig.sha256")
            btype="file"
            bcomp="update"
        elif [ "$(basename "$d")" = rauc ] && [ -f "$d/system.conf" ]; then
            # lib/rauc.sh layout: backup/rauc/system.conf (+ .sha256); our
            # change is the delimited block.
            bpath=/etc/rauc/system.conf
            borig="$d/system.conf"
            [ -f "$borig.sha256" ] && bsha=$(head -n 1 "$borig.sha256")
            btype="block"
            bcomp="update"
        else
            continue
        fi
        [ -n "$bpath" ] || {
            warn "backup $d has no path=; skipped"
            SKIPPED=$((SKIPPED + 1))
            continue
        }
        if [ -n "$bcomp" ] && ! component_selected "$bcomp"; then
            continue
        fi
        case "$bpath" in
            /*) ;;
            *)
                warn "backup $d: relative path refused"
                SKIPPED=$((SKIPPED + 1))
                continue
                ;;
        esac
        case "$bpath" in
            /usr/* | /dev/* | /proc/* | /sys/* | /run/*)
                warn "backup $d: refusing to restore under $bpath"
                SKIPPED=$((SKIPPED + 1))
                continue
                ;;
        esac
        real=$(rpath "$bpath")
        HANDLED_ENTRIES="$HANDLED_ENTRIES
$bpath"
        case "$btype" in
            block)
                if [ ! -f "$real" ]; then
                    log "backup $bpath: live file missing, nothing to strip"
                    continue
                fi
                if ! grep -Fq "$MARK_BEGIN" "$real"; then
                    log "backup $bpath: no $NAME block present"
                    continue
                fi
                tmp=$(mktemp "$real.XXXXXX") || fatal "mktemp failed next to $bpath"
                awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
                    index($0, b) == 1 { skip = 1; next }
                    index($0, e) == 1 { skip = 0; next }
                    !skip { print }' "$real" >"$tmp"
                if [ "$DRY" = 1 ]; then
                    rm -f "$tmp"
                    printf '[dry-run] strip %s block from %s\n' "$NAME" "$bpath"
                    continue
                fi
                if [ -f "$borig" ] && [ "$(sha256_of "$tmp")" = "$(sha256_of "$borig")" ]; then
                    log "restore $bpath: stripped block, identical to saved original"
                else
                    warn "restore $bpath: stripped our block, but the result differs from the saved original (file changed upstream?); keeping the stripped version"
                fi
                chmod --reference="$real" "$tmp" 2>/dev/null || true
                mv -f "$tmp" "$real"
                REMOVED=$((REMOVED + 1))
                ;;
            file | '')
                # A boot entry modified by lib/slots.sh can always be rebuilt
                # from its marker, so an unusable saved copy is not fatal.
                marked=0
                [ -L "$real" ] || ! entry_is_modified "$real" || marked=1
                if [ ! -f "$borig" ]; then
                    if [ "$marked" = 1 ]; then
                        warn "backup $bpath: saved original missing; regenerating the original entry from the $NAME marker"
                        entry_regenerate "$bpath"
                        continue
                    fi
                    warn "backup $bpath: saved original missing; cannot restore (regenerate it from the stock template with the CLI if available)"
                    SKIPPED=$((SKIPPED + 1))
                    continue
                fi
                if [ -n "$bsha" ] && [ "$(sha256_of "$borig")" != "$bsha" ]; then
                    if [ "$marked" = 1 ]; then
                        warn "backup $bpath: saved original is corrupt (hash mismatch); regenerating the original entry from the $NAME marker"
                        entry_regenerate "$bpath"
                        continue
                    fi
                    warn "backup $bpath: saved original is corrupt (hash mismatch); not restoring"
                    SKIPPED=$((SKIPPED + 1))
                    continue
                fi
                if [ "$marked" = 1 ]; then
                    want=$(entry_mark_get "$real" orig-sha256)
                    if [ -n "$want" ] && [ "$(sha256_of "$borig")" != "$want" ]; then
                        # The saved copy predates a stock regeneration of the
                        # entry; the stripped live entry is the faithful original.
                        warn "backup $bpath: saved original is older than the current entry; regenerating instead"
                        entry_regenerate "$bpath"
                        continue
                    fi
                fi
                if [ -f "$real" ] && [ "$(sha256_of "$real")" = "$(sha256_of "$borig")" ]; then
                    log "restore $bpath: already identical to saved original"
                    continue
                fi
                if [ -f "$real" ] && ! grep -q "ally-x20-steamos" "$real"; then
                    # Not ours any more (SteamOS regenerated it, e.g. after an
                    # update): never overwrite a stock file we did not modify.
                    log "restore $bpath: current file carries no $NAME change; leaving it alone"
                    continue
                fi
                RESTORED_ENTRIES="$RESTORED_ENTRIES
$bpath"
                if [ "$DRY" = 1 ]; then
                    printf '[dry-run] restore %s from backup\n' "$bpath"
                    continue
                fi
                mkdir -p "$(dirname "$real")"
                tmp=$(mktemp "$real.XXXXXX") || fatal "mktemp failed next to $bpath"
                cp "$borig" "$tmp"
                [ -f "$real" ] && chmod --reference="$real" "$tmp" 2>/dev/null
                mv -f "$tmp" "$real"
                if command -v sync >/dev/null 2>&1; then sync 2>/dev/null || true; fi
                log "restore $bpath: restored byte-for-byte from backup"
                REMOVED=$((REMOVED + 1))
                ;;
            *)
                warn "backup $d: unknown type '$btype'"
                SKIPPED=$((SKIPPED + 1))
                ;;
        esac
    done
}

# ------------------------------------------------------ live mounts --
# release_power_mount : component power bind-mounts a copy of steamos-manager's
# device files from /run/ally-x20-steamos over
# /usr/share/steamos-manager/devices (no file under /usr is written). Stop
# its unit and drop our mount layers before the files go, so steamos-manager
# sees the stock directory again. Live root only; a mount never survives a
# reboot, and another slot or recovery media has none. Only layers whose
# source is under /ally-x20-steamos/ are unmounted, never anyone else's.
POWER_MOUNT_POINT=/usr/share/steamos-manager/devices
POWER_UNIT="$NAME-power-devices.service"
power_mount_ours() {
    [ -r /proc/self/mountinfo ] || return 1
    awk -v mp="$POWER_MOUNT_POINT" -v tok="/$NAME/" '
        $5 == mp { top = $4 }
        END { exit !(top != "" && index(top, tok) > 0) }' /proc/self/mountinfo
}
release_power_mount() {
    [ -n "$ROOT" ] && return 0
    component_selected power || return 0
    if [ "$DRY" = 1 ]; then
        power_mount_ours && printf '[dry-run] stop %s and unmount %s\n' "$POWER_UNIT" "$POWER_MOUNT_POINT"
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$POWER_UNIT" 2>/dev/null || true
    fi
    n=0
    while power_mount_ours && [ "$n" -lt 8 ]; do
        n=$((n + 1))
        log "umount $POWER_MOUNT_POINT (our bind mount)"
        umount "$POWER_MOUNT_POINT" 2>/dev/null || umount -l "$POWER_MOUNT_POINT" 2>/dev/null || break
    done
    if power_mount_ours; then
        warn "our bind mount on $POWER_MOUNT_POINT is still there; it goes away at the next reboot"
    fi
    return 0
}

# -------------------------------------------------------- post actions --
post_actions() {
    [ -n "$ROOT" ] && return 0 # only on the live root
    [ "$DRY" = 1 ] && return 0
    if command -v depmod >/dev/null 2>&1; then depmod -a 2>/dev/null || true; fi
    if command -v ldconfig >/dev/null 2>&1; then ldconfig 2>/dev/null || true; fi
    if command -v systemd-hwdb >/dev/null 2>&1; then systemd-hwdb update 2>/dev/null || true; fi
    if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload 2>/dev/null || true; fi
}

usage() {
    sed -n '/^# Usage:/,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --root | --slot)
                [ $# -ge 2 ] || fatal "$1 needs a directory"
                ROOT=${2%/}
                shift 2
                ;;
            --root=*)
                ROOT=${1#--root=}
                ROOT=${ROOT%/}
                shift
                ;;
            --component)
                [ $# -ge 2 ] || fatal "--component needs a name"
                COMPONENTS="$COMPONENTS $2"
                shift 2
                ;;
            --dry-run)
                DRY=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --keep-state)
                KEEP_STATE=1
                shift
                ;;
            --reboot)
                REBOOT=1
                shift
                ;;
            --yes | -y)
                YES=1
                shift
                ;;
            --quiet | -q)
                QUIET=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) fatal "unknown option: $1" ;;
        esac
    done
    COMPONENTS=${COMPONENTS# }
    [ -z "$ROOT" ] || [ -d "$ROOT" ] || fatal "--root $ROOT is not a directory"
    if [ -z "$ROOT" ] && [ "$DRY" != 1 ] && [ "$(id -u)" != 0 ]; then
        fatal "must run as root on the live system (or use --dry-run)"
    fi

    state=$(rpath "/var/lib/$NAME")
    manifest="$state/manifest"
    if [ ! -f "$manifest" ]; then
        warn "no manifest at $manifest (nothing installed, or the state dir is gone); only backups and marked boot entries can be restored"
    fi

    if [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then
        if [ -n "$COMPONENTS" ]; then
            printf 'About to remove %s components [%s] from %s. Continue? [y/N] ' "$NAME" "$COMPONENTS" "${ROOT:-/}"
        else
            printf 'About to remove everything %s installed on %s. Continue? [y/N] ' "$NAME" "${ROOT:-/}"
        fi
        read -r ans || ans=n
        case "$ans" in y | Y | yes | YES) ;; *) fatal "aborted" ;; esac
    fi

    # 0. Live mounts (component power) go before the files behind them.
    release_power_mount

    # 1. Restore saved originals (boot entry, rauc block), then boot entries
    #    that still carry our marker without any backup record (state dir
    #    gone, e.g. after a factory reset): before the manifest walk, so the
    #    early initrd an entry points at is removed only once nothing
    #    references it any more.
    restore_backups
    restore_orphan_entries

    # 2. Files and symlinks, newest first; 3. directories, deepest first.
    dirs=""
    if [ -f "$manifest" ]; then
        tmpl=$(mktemp "${TMPDIR:-/tmp}/$NAME-uninstall.XXXXXX") || fatal "mktemp failed"
        parse_manifest "$manifest" | reverse_lines >"$tmpl"
        # shellcheck disable=SC2034  # created_dir is informational here
        while IFS="$US" read -r kind sha created comp path; do
            [ -n "$path" ] || continue
            component_selected "$comp" || continue
            case "$path" in
                /*) ;;
                *)
                    warn "refuse relative manifest path: $path"
                    SKIPPED=$((SKIPPED + 1))
                    continue
                    ;;
            esac
            case "$path" in
                *../* | */..)
                    warn "refuse path with ..: $path"
                    SKIPPED=$((SKIPPED + 1))
                    continue
                    ;;
            esac
            case "$kind" in
                dir)
                    if dir_denied "$path"; then
                        log "keep dir $path: protected location"
                        continue
                    fi
                    dirs="$dirs
$path"
                    ;;
                file | symlink)
                    if reason=$(denied "$path"); then
                        warn "REFUSED $path: $reason (manifest entry ignored)"
                        SKIPPED=$((SKIPPED + 1))
                        continue
                    fi
                    case "$kind:$path" in
                        file:/efi/* | file:/esp/*)
                            if ref_by=$(entry_referencing "$path"); then
                                warn "skip $path: boot entry $ref_by still loads it as early initrd (restore the entry first: uninstall component update too, or run a full uninstall)"
                                SKIPPED=$((SKIPPED + 1))
                                continue
                            fi
                            ;;
                    esac
                    if [ "$kind" = file ]; then
                        remove_file "$path" "$sha"
                    else
                        remove_symlink "$path" "$sha"
                    fi
                    ;;
                *)
                    warn "skip $path: unknown kind '$kind'"
                    SKIPPED=$((SKIPPED + 1))
                    ;;
            esac
        done <"$tmpl"
        rm -f "$tmpl"
        # Deepest directories first.
        printf '%s\n' "$dirs" | grep -v '^$' | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2- \
            | while IFS= read -r d; do remove_dir "$d"; done
    fi

    # 4. Update the manifest: drop the entries of the components we handled
    #    (all of them on a full run) so a re-run is a no-op and `audit` stays
    #    truthful. Skipped entries are kept so they remain visible.
    if [ -f "$manifest" ] && [ "$DRY" != 1 ]; then
        keep=$(mktemp "$manifest.XXXXXX") || fatal "mktemp failed"
        parse_manifest "$manifest" | awk -F"$US" -v comps=" $COMPONENTS " -v all="$([ -z "$COMPONENTS" ] && echo 1 || echo 0)" '
            { if (all == 1 || index(comps, " " $4 " ") > 0) print $5 }' >"$keep.handled"
        # Re-emit original lines whose path is not handled, or was skipped (still exists).
        while IFS= read -r line; do
            lp=$(printf '%s\n' "$line" | parse_manifest - 2>/dev/null | cut -d "$US" -f5)
            [ -n "$lp" ] || continue
            if grep -Fxq -- "$lp" "$keep.handled" && [ ! -e "$(rpath "$lp")" ] && [ ! -L "$(rpath "$lp")" ]; then
                continue
            fi
            printf '%s\n' "$line"
        done <"$manifest" >"$keep"
        rm -f "$keep.handled"
        mv -f "$keep" "$manifest"
    fi

    # 5. State directory.
    if [ -z "$COMPONENTS" ] && [ "$KEEP_STATE" != 1 ]; then
        if [ "$SKIPPED" -gt 0 ]; then
            warn "keeping $state because $SKIPPED item(s) were skipped; re-run with --force or inspect the log"
        else
            if [ -L "$state" ]; then
                # State lives in the shared /home partition behind a symlink.
                starget=$(readlink "$state")
                case "$starget" in
                    /home/.ally-x20-steamos | ../../home/.ally-x20-steamos)
                        act "rm -rf /home/.ally-x20-steamos" rm -rf "$(rpath /home/.ally-x20-steamos)"
                        ;;
                    *) warn "state symlink points at unexpected $starget; leaving its target alone" ;;
                esac
                act "rm symlink /var/lib/$NAME" rm -f "$state"
            else
                act "rm -rf $state" rm -rf "$state"
            fi
            real=$(rpath "/opt/$NAME")
            if [ -d "$real" ]; then act "rm -rf /opt/$NAME" rm -rf "$real"; fi
        fi
    fi

    post_actions

    log "done: $REMOVED removed, $SKIPPED skipped"
    if [ "$REBOOT" = 1 ] && [ -z "$ROOT" ] && [ "$DRY" != 1 ]; then
        log "rebooting"
        systemctl reboot
    elif [ -z "$ROOT" ] && [ "$DRY" != 1 ]; then
        log "reboot recommended"
    fi
    [ "$SKIPPED" -eq 0 ]
}

main "$@"
