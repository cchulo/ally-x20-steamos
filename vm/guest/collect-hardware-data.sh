#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/guest/collect-hardware-data.sh — run the plan §7 command list and pack
# the results into a tarball. Works in the VM (baseline) and on a real X20
# running stock SteamOS (first boot). Read-only: it never changes the system.
#
# Usage: collect-hardware-data.sh [--out DIR] [--no-sudo]
#   --out DIR    where the tarball goes (default: current directory)
#   --no-sudo    skip the commands that need root (acpidump, input devices)
#
# Every command's stdout+stderr goes to its own file in the tarball, with
# the exit status appended, so missing tools show up as data, not failures.
#
# Snippets passed to cap are single-quoted on purpose: the child bash expands them.
# shellcheck disable=SC2016
set -eu

die() {
    printf 'collect-hardware-data: error: %s\n' "$*" >&2
    exit 2
}

OUT=$PWD
USE_SUDO=1
while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            [ $# -ge 2 ] || die "--out needs a directory"
            OUT=$2
            shift
            ;;
        --no-sudo) USE_SUDO=0 ;;
        -h | --help)
            sed -n '3,/^set -eu/p' "$0" | sed -e '/^set -eu/d' -e '/shellcheck/d' -e 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

host=$(uname -n 2>/dev/null || echo unknown)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
name="ax20-hwdata-$host-$stamp"
mkdir -p "$OUT"
work=$(mktemp -d "${TMPDIR:-/tmp}/ax20-hwdata.XXXXXX")
trap 'rm -rf "$work"' EXIT
dir="$work/$name"
mkdir -p "$dir/acpi" "$dir/edid"

# priv : run as root (sudo -n when needed); fail cleanly if not allowed.
priv() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif [ "$USE_SUDO" = 1 ] && command -v sudo >/dev/null 2>&1; then
        sudo -n "$@"
    else
        echo "skipped: needs root ($*)"
        return 77
    fi
}

n=0
# cap <slug> <shell snippet> : run snippet with bash, save output + status.
cap() {
    n=$((n + 1))
    local f
    f=$(printf '%s/%02d-%s.txt' "$dir" "$n" "$1")
    {
        printf '$ %s\n' "$2"
        local rc=0
        bash -c "$2" 2>&1 || rc=$?
        printf '\n[exit %s]\n' "$rc"
    } >"$f"
}
export -f priv
export USE_SUDO

cap uname 'uname -a; uname -r'
cap kernel-config 'zcat /proc/config.gz'
cap os-release 'cat /etc/os-release'
cap acpidump "cd '$dir/acpi' && priv acpidump -b && ls -l"
cap leds 'ls -l /sys/class/leds/; for d in /sys/class/leds/*; do echo "== $d"; for f in multi_index multi_intensity max_brightness; do [ -e "$d/$f" ] && echo "$f: $(cat "$d/$f")"; done; done'
cap lsusb 'lsusb; lsusb -t'
cap dmi 'for f in sys_vendor product_name product_version product_sku product_family board_vendor board_name board_version bios_version bios_date; do printf "%s: %s\n" "$f" "$(cat /sys/class/dmi/id/$f 2>/dev/null)"; done; cat /sys/class/dmi/id/modalias'
cap alsa 'aplay -l; cat /proc/asound/cards'
cap audio-kmsg 'journalctl -k -b --no-pager | grep -iE "acp|sof|soundwire|tas2783"'
cap speaker-id 'efivar -l | grep -i speaker; ls /sys/firmware/efi/efivars/ | grep -i speaker'
cap ucm-firmware 'ls -l /usr/share/alsa/ucm2/sof-soundwire/; ls -l /lib/firmware/ti/'
cap input-devices 'priv cat /proc/bus/input/devices'
cap inputplumber 'inputplumber --version; systemctl status --no-pager inputplumber.service; ls /usr/share/inputplumber/devices/ | grep -i ally'
cap inputplumber-devices 'inputplumber devices; busctl tree org.shadowblip.InputPlumber'
cap edid "for e in /sys/class/drm/*/edid; do [ -s \"\$e\" ] || continue; c=\$(basename \"\$(dirname \"\$e\")\"); echo \"\$e\"; cat \"\$e\" > '$dir/edid/'\"edid-\$c.bin\"; done"
cap edid-decode "for f in '$dir'/edid/*.bin; do [ -f \"\$f\" ] || continue; echo \"== \$f\"; di-edid-decode \"\$f\" 2>&1 || edid-decode \"\$f\"; done"
cap gamescope-displayinfo 'gamescope --version; pkg-config --modversion libdisplay-info 2>/dev/null || ls -l /usr/lib/libdisplay-info.so*'
cap pipewire 'pipewire --version; ls -l /usr/lib/libmysofa.so*; strings /usr/lib/pipewire-0.3/libpipewire-module-filter-chain.so | grep -i sofa'
cap dsp-plugins 'ls /usr/lib/lv2 /usr/lib/ladspa'
cap lsmod 'lsmod'
cap cmdline 'cat /proc/cmdline; bootctl status --no-pager 2>/dev/null | head -n 40'
cap steamos-branch 'steamos-select-branch -c 2>/dev/null; cat /etc/steamos-release 2>/dev/null'

tarball="$OUT/$name.tar.gz"
tar -C "$work" -czf "$tarball" "$name"
printf '%s\n' "$tarball"
