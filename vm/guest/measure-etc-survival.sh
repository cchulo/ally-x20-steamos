#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/guest/measure-etc-survival.sh — measure which /etc paths survive a
# SteamOS A/B update (plan §4.1, §6 check 4). Runs INSIDE the VM, as root.
#
# Usage:
#   measure-etc-survival.sh before [--root R] [--state DIR] [--no-dropin-markers]
#       Plant marker files, then record type+sha256 of every path under /etc.
#   (run `steamos-update` and reboot into the new slot)
#   measure-etc-survival.sh after  [--root R] [--state DIR] [--restored FILE] [--all]
#       Snapshot /etc again and print a Markdown table for docs/etc-survival.md.
#   measure-etc-survival.sh cleanup [--root R] [--state DIR]
#       Remove the marker files (and the state dir).
#   measure-etc-survival.sh snapshot <dir> <label>
#       Print the snapshot of <dir>, paths shown as <label>/...
#   measure-etc-survival.sh compare <before.tsv> <after.tsv>
#       Print status<TAB>path lines: same, changed, removed, added.
#   measure-etc-survival.sh table <before.tsv> <after.tsv> [--restored FILE] [--all]
#
# --root R runs against a fixture tree (R/etc, R/var/...) instead of /.
# --restored FILE lists paths (one per line) that our RAUC hook or boot
# service reported re-applying; they get "yes" in the "restored by" column.
# State (snapshots, marker list) lives under /var/lib/ally-x20-steamos-probe,
# because /var is shared by both slots and survives the update.
#
# Snapshot format, one line per path, sorted:  path<TAB>type<TAB>digest
#   type f: digest = sha256 of the content; l: link target; d: "-"
set -eu

ES_PROBE_DIR_REL=/etc/ally-x20-steamos-probe.d
ES_STATE_REL=/var/lib/ally-x20-steamos-probe

es_die() {
    printf 'measure-etc-survival: error: %s\n' "$*" >&2
    exit 2
}

es_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" 2>/dev/null | awk '{print $1}'
    else
        shasum -a 256 <"$1" 2>/dev/null | awk '{print $1}'
    fi
}

# es_snapshot <dir> <label> : print the snapshot of <dir>.
es_snapshot() {
    local dir=$1 label=$2 p rel d
    [ -d "$dir" ] || es_die "not a directory: $dir"
    (
        cd "$dir"
        find . -mindepth 1 -print 2>/dev/null | LC_ALL=C sort
    ) | while IFS= read -r p; do
        rel=${p#./}
        if [ -L "$dir/$rel" ]; then
            printf '%s/%s\tl\t%s\n' "$label" "$rel" "$(readlink "$dir/$rel")"
        elif [ -d "$dir/$rel" ]; then
            printf '%s/%s\td\t-\n' "$label" "$rel"
        elif [ -f "$dir/$rel" ]; then
            d=$(es_sha256 "$dir/$rel")
            printf '%s/%s\tf\t%s\n' "$label" "$rel" "${d:-unreadable}"
        else
            printf '%s/%s\to\t-\n' "$label" "$rel"
        fi
    done
}

# es_compare <before> <after> : status<TAB>path for every path in either.
es_compare() {
    awk -F '\t' '
        FNR == NR { b[$1] = $2 "\t" $3; next }
        {
            if ($1 in b) { print ((b[$1] == $2 "\t" $3) ? "same" : "changed") "\t" $1; seen[$1] = 1 }
            else print "added\t" $1
        }
        END { for (p in b) if (!(p in seen)) print "removed\t" p }
    ' "$1" "$2" | LC_ALL=C sort -t "$(printf '\t')" -k2,2
}

# es_markers_file <state> : the list of marker paths planted by "before".
es_markers_file() { printf '%s/markers\n' "$1"; }

# es_table <before> <after> <markers-file|""> <restored-file|""> <all 0|1>
es_table() {
    local before=$1 after=$2 markers=$3 restored=$4 all=$5 cmp
    cmp=$(es_compare "$before" "$after")
    printf '| path | survives update? | restored by hook/service? | notes |\n'
    printf '|---|---|---|---|\n'
    printf '%s\n' "$cmp" | awk -F '\t' -v markers="$markers" -v restored="$restored" -v all="$all" '
        BEGIN {
            if (markers != "") while ((getline l < markers) > 0) m[l] = 1
            if (restored != "") while ((getline l < restored) > 0) r[l] = 1
        }
        $2 == "" { next }
        {
            st = $1; p = $2
            if (!(p in m) && all != 1) {
                count[st]++
                if (st != "same" && n[st] < 200) list[st] = list[st] "\n  - `" p "`"
                if (st != "same") n[st]++
                next
            }
            surv = (st == "same") ? "yes" : (st == "changed") ? "yes (content changed)" : (st == "removed") ? "no" : "new after update"
            rest = (p in r) ? "yes" : "-"
            note = (p in m) ? "marker" : "stock"
            printf "| `%s` | %s | %s | %s |\n", p, surv, rest, note
        }
        END {
            if (all != 1) {
                printf "\nOther /etc paths: %d unchanged, %d changed, %d removed, %d added.\n", count["same"], count["changed"], count["removed"], count["added"]
                split("changed removed added", ks, " ")
                for (i = 1; i <= 3; i++) if (list[ks[i]] != "") printf "\n%s:%s\n", ks[i], list[ks[i]]
            }
        }
    '
}

# es_plant <root> <state> <dropins 0|1> : create markers, record their paths.
es_plant() {
    local root=$1 state=$2 dropins=$3 probe mf d f
    probe="$root$ES_PROBE_DIR_REL"
    mf=$(es_markers_file "$state")
    mkdir -p "$probe/subdir" "$state"
    printf 'ally-x20-steamos probe marker\n' >"$probe/marker-plain"
    printf 'nested marker\n' >"$probe/subdir/marker-nested"
    printf 'private marker\n' >"$probe/marker-mode600"
    chmod 600 "$probe/marker-mode600"
    ln -sf marker-plain "$probe/marker-symlink"
    {
        printf '%s\n' "$ES_PROBE_DIR_REL" "$ES_PROBE_DIR_REL/marker-plain" "$ES_PROBE_DIR_REL/subdir" \
            "$ES_PROBE_DIR_REL/subdir/marker-nested" "$ES_PROBE_DIR_REL/marker-mode600" "$ES_PROBE_DIR_REL/marker-symlink"
    } >"$mf"
    [ "$dropins" = 1 ] || return 0
    # One harmless file in every existing drop-in directory we plan to use, with
    # the suffix our real file will have (whitelists may be glob-based).
    for f in \
        /etc/modprobe.d/ally-x20-steamos-probe.conf \
        /etc/environment.d/99-ally-x20-steamos-probe.conf \
        /etc/ld.so.conf.d/99-ally-x20-steamos-probe.conf \
        /etc/udev/rules.d/99-ally-x20-steamos-probe.rules \
        /etc/udev/hwdb.d/99-ally-x20-steamos-probe.hwdb \
        /etc/systemd/system/ally-x20-steamos-probe.marker \
        /etc/inputplumber/devices.d/ally-x20-steamos-probe.marker \
        /etc/rauc/ally-x20-steamos-probe.marker \
        /etc/atomic-update.conf.d/ally-x20-steamos-probe.marker; do
        d=$(dirname "$f")
        [ -d "$root$d" ] || continue
        printf '# ally-x20-steamos /etc survival probe; safe to delete\n' >"$root$f"
        printf '%s\n' "$f" >>"$mf"
    done
}

es_cleanup() {
    local root=$1 state=$2 mf p
    mf=$(es_markers_file "$state")
    if [ -f "$mf" ]; then
        while IFS= read -r p; do
            case "$p" in
                "$ES_PROBE_DIR_REL"*) ;;
                */ally-x20-steamos-probe.*) rm -f "$root$p" ;;
            esac
        done <"$mf"
    fi
    rm -rf "$root$ES_PROBE_DIR_REL" "$state"
}

es_require_root() {
    [ -n "$1" ] && return 0
    [ "$(id -u)" = 0 ] || es_die "run as root (sudo) to read every file under /etc"
}

es_info() {
    local root=$1
    printf 'BUILD_ID=%s\n' "$(sed -n 's/^BUILD_ID=//p' "$root/etc/os-release" 2>/dev/null | tr -d '"')"
    printf 'KERNEL=%s\n' "$(uname -r)"
    printf 'DATE=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

es_main() {
    local cmd=${1:-} root="" state="" dropins=1 restored="" all=0
    [ $# -gt 0 ] && shift
    case "$cmd" in
        snapshot)
            [ $# -eq 2 ] || es_die "snapshot <dir> <label>"
            es_snapshot "$1" "$2"
            return 0
            ;;
        compare)
            [ $# -eq 2 ] || es_die "compare <before> <after>"
            es_compare "$1" "$2"
            return 0
            ;;
        table)
            [ $# -ge 2 ] || es_die "table <before> <after> [--restored F] [--all]"
            local b=$1 a=$2
            shift 2
            while [ $# -gt 0 ]; do
                case "$1" in
                    --restored)
                        restored=$2
                        shift
                        ;;
                    --all) all=1 ;;
                    *) es_die "unknown option: $1" ;;
                esac
                shift
            done
            es_table "$b" "$a" "" "$restored" "$all"
            return 0
            ;;
        before | after | cleanup) ;;
        -h | --help | '')
            sed -n '3,/^set -eu/p' "${BASH_SOURCE[0]}" | sed -e '/^set -eu/d' -e 's/^# \{0,1\}//'
            return 0
            ;;
        *) es_die "unknown command: $cmd" ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --root)
                root=${2%/}
                shift
                ;;
            --state)
                state=$2
                shift
                ;;
            --restored)
                restored=$2
                shift
                ;;
            --no-dropin-markers) dropins=0 ;;
            --all) all=1 ;;
            *) es_die "unknown option: $1" ;;
        esac
        shift
    done
    [ -n "$state" ] || state="$root$ES_STATE_REL"
    es_require_root "$root"
    case "$cmd" in
        before)
            [ ! -f "$state/before.tsv" ] || es_die "$state/before.tsv exists; run cleanup first"
            es_plant "$root" "$state" "$dropins"
            es_info "$root" >"$state/before.info"
            es_snapshot "$root/etc" /etc >"$state/before.tsv"
            printf 'recorded %s paths in %s; now update + reboot, then run: %s after\n' \
                "$(wc -l <"$state/before.tsv" | tr -d ' ')" "$state/before.tsv" "$0"
            ;;
        after)
            [ -f "$state/before.tsv" ] || es_die "no $state/before.tsv; run 'before' first"
            es_info "$root" >"$state/after.info"
            es_snapshot "$root/etc" /etc >"$state/after.tsv"
            printf '<!-- before: %s | after: %s -->\n\n' \
                "$(tr '\n' ' ' <"$state/before.info")" "$(tr '\n' ' ' <"$state/after.info")"
            es_table "$state/before.tsv" "$state/after.tsv" "$(es_markers_file "$state")" "$restored" "$all"
            ;;
        cleanup) es_cleanup "$root" "$state" ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    es_main "$@"
fi
