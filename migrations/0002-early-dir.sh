#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Migration 0002: boot-time files moved from /var/lib/ally-x20-steamos
# (a symlink into /home, not mounted when udev loads modules) to
# /etc/ally-x20-steamos. Forget the old helper, staged modules and firmware
# tree so `apply` installs them at the new paths; the files themselves are
# removed when they are ours (manifest digest still matches).
set -eu
# shellcheck source=../lib/manifest.sh
. "$AX20_SRC/lib/manifest.sh"
old_helper="$AX20_STATE_REL/bin/load-or-fallback"
for p in $(manifest_paths modules) $(manifest_paths audio); do
    case "$p" in
        "$old_helper" | "$AX20_STATE_REL"/modules/* | "$AX20_STATE_REL"/firmware/*)
            real=$(ax20_path "$p")
            if manifest_verify "$p" >/dev/null 2>&1 || [ -L "$real" ]; then
                rm -f "$real" 2>/dev/null || true
            fi
            manifest_forget "$p"
            ;;
    esac
done
for d in "$AX20_STATE_REL/modules" "$AX20_STATE_REL/firmware" "$AX20_STATE_REL/bin"; do
    real=$(ax20_path "$d")
    [ -d "$real" ] && find "$real" -depth -type d -empty -delete 2>/dev/null || true
done
exit 0
