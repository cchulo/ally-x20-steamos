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
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
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

# ------------------------------------------------------------- backups --
# Saved originals live in <state>/backup/<id>/ with:
#   original   the stock file bytes as they were before we touched them
#   meta       key=value lines: path=, sha256= (of original), type=file|block
# type=file  : restore byte-for-byte (only if 'original' still hashes to sha256)
# type=block : remove our delimited block from the live file; if the result
#              equals 'original' nothing else to do, otherwise keep the
#              stripped file (Valve may have changed it since) and say so.
# Backups are restored before the manifest walk so a restored stock file is
# never mistaken for one of ours.
restore_backups() {
    bdir=$(rpath "/var/lib/$NAME/backup")
    [ -d "$bdir" ] || return 0
    for d in "$bdir"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/meta" ] || continue
        bpath=$(sed -n 's/^path=//p' "$d/meta" | head -n 1)
        bsha=$(sed -n 's/^sha256=//p' "$d/meta" | head -n 1)
        btype=$(sed -n 's/^type=//p' "$d/meta" | head -n 1)
        bcomp=$(sed -n 's/^component=//p' "$d/meta" | head -n 1)
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
                if [ -f "$d/original" ] && [ "$(sha256_of "$tmp")" = "$bsha" ]; then
                    log "restore $bpath: stripped block, identical to saved original"
                else
                    warn "restore $bpath: stripped our block, but the result differs from the saved original (file changed upstream?); keeping the stripped version"
                fi
                chmod --reference="$real" "$tmp" 2>/dev/null || true
                mv -f "$tmp" "$real"
                REMOVED=$((REMOVED + 1))
                ;;
            file | '')
                if [ ! -f "$d/original" ]; then
                    warn "backup $bpath: saved original missing; cannot restore (regenerate it from the stock template with the CLI if available)"
                    SKIPPED=$((SKIPPED + 1))
                    continue
                fi
                if [ -n "$bsha" ] && [ "$(sha256_of "$d/original")" != "$bsha" ]; then
                    warn "backup $bpath: saved original is corrupt (hash mismatch); not restoring"
                    SKIPPED=$((SKIPPED + 1))
                    continue
                fi
                if [ -f "$real" ] && [ "$(sha256_of "$real")" = "$bsha" ]; then
                    log "restore $bpath: already identical to saved original"
                    continue
                fi
                if [ "$DRY" = 1 ]; then
                    printf '[dry-run] restore %s from backup\n' "$bpath"
                    continue
                fi
                mkdir -p "$(dirname "$real")"
                tmp=$(mktemp "$real.XXXXXX") || fatal "mktemp failed next to $bpath"
                cp "$d/original" "$tmp"
                [ -f "$real" ] && chmod --reference="$real" "$tmp" 2>/dev/null
                mv -f "$tmp" "$real"
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
        warn "no manifest at $manifest (nothing installed, or the state dir is gone); only backups can be restored"
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

    # 1. Restore saved originals (boot entry, rauc block).
    restore_backups

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
            act "rm -rf $state" rm -rf "$state"
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
