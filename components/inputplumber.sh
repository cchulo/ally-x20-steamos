# SPDX-License-Identifier: GPL-2.0-only
# components/inputplumber.sh — X20 controller on the stock InputPlumber daemon
# (X20-STEAMOS-PLAN.md §1.2, §5 probes, §6 VM check 5; docs/inputplumber.md).
#
# What it installs (all through the manifest):
#   /etc/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml
#       the upstream PR #756 profile, verbatim for daemons >= 0.82.0, or the
#       stock-adapted copy (overlay .../50-rog_xbox_ally_x20.stock.yaml) for
#       older ones. The file name is the upstream one on purpose: InputPlumber
#       sorts device configs by file name and, for equal names, prefers
#       /etc/inputplumber/devices.d over /usr/share/inputplumber/devices.
#   /etc/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml
#       only with the stock-adapted profile (corrected Xbox Ally button map
#       under our own id).
#   /etc/udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb
#       DMI match -> USE_INPUTPLUMBER=1 (autostart, like upstream).
#   /etc/systemd/system/inputplumber.service.d/50-ally-x20-steamos.conf
#       FALLBACK ONLY: ExecStart= override to our build of upstream.

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="InputPlumber X20 profile + hwdb autostart for the stock daemon (optional upstream build fallback)"

# Where build/build-inputplumber.sh puts the fallback build. One variable so
# it can move under /var/lib if /opt turns out not to be writable/persistent
# on SteamOS. TODO(vm): confirm /opt is on writable storage (plan §5.1b).
AX20_INPUTPLUMBER_OPT_REL="${AX20_INPUTPLUMBER_OPT_REL:-${AX20_OPT_REL}/inputplumber}"
# Oldest daemon that understands the verbatim upstream profile
# (config.imu.mount_matrix + new axis convention landed in 0.82.0).
AX20_INPUTPLUMBER_PROFILE_MIN="0.82.0"
# Oldest daemon the stock-adapted profile is written for (has the Xbox Ally
# hidraw driver, aly2 rework and source event filters). Anything older needs
# the fallback build.
AX20_INPUTPLUMBER_STOCK_MIN="0.78.0"
# 1 = force the fallback build even when the stock daemon is new enough.
AX20_INPUTPLUMBER_FALLBACK="${AX20_INPUTPLUMBER_FALLBACK:-0}"
# auto = run systemd-hwdb/udevadm/systemctl only on a live system (empty
# AX20_ROOT); never = skip; always = run even with a root prefix (tests use
# this with stub commands on PATH).
AX20_INPUTPLUMBER_SYSTEM_STEPS="${AX20_INPUTPLUMBER_SYSTEM_STEPS:-auto}"
export AX20_INPUTPLUMBER_OPT_REL AX20_INPUTPLUMBER_FALLBACK

_IP_STOCK_DEVICES=/usr/share/inputplumber/devices
_IP_STOCK_BIN=/usr/bin/inputplumber
_IP_PROFILE_DEST=/etc/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml
_IP_CAPMAP_DEST=/etc/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml
_IP_HWDB_DEST=/etc/udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb
_IP_DROPIN_DEST=/etc/systemd/system/inputplumber.service.d/50-ally-x20-steamos.conf
_IP_DROPIN_SRC=systemd/inputplumber.service.d/50-ally-x20-steamos.conf

# _ip_semver <text> : first X.Y.Z in the text (drops "inputplumber " prefixes
# and pacman "-pkgrel" suffixes). Returns 2 when there is none.
_ip_semver() {
    local v
    v=$(printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    [ -n "$v" ] || return "$PROBE_UNKNOWN"
    printf '%s\n' "$v"
}

# inputplumber_stock_version : print the stock daemon's version (X.Y.Z).
# Sources, first hit wins:
#   1. /usr/share/inputplumber/VERSION   fixture marker (never on a real system)
#   2. `/usr/bin/inputplumber --version` live system only (clap prints
#                                        "inputplumber 0.78.0"); binaries in a
#                                        fixture or slot root are not executed
#   3. pacman local db desc %VERSION%    SteamOS keeps it in /usr/lib/holo/pacmandb
#                                        (TODO(vm): confirm), Arch in /var/lib/pacman
# Returns 2 (unknown) when nothing is found.
inputplumber_stock_version() {
    local f bin out="" d desc
    f=$(ax20_path /usr/share/inputplumber/VERSION)
    if [ -f "$f" ]; then
        out=$(cat "$f")
    fi
    bin=$(ax20_path "$_IP_STOCK_BIN")
    if [ -z "$out" ] && [ -z "$AX20_ROOT" ] && [ -x "$bin" ]; then
        out=$("$bin" --version 2>/dev/null || true)
    fi
    if [ -z "$out" ]; then
        for d in /usr/lib/holo/pacmandb/local /var/lib/pacman/local; do
            for desc in "$(ax20_path "$d")"/inputplumber-[0-9]*/desc; do
                [ -f "$desc" ] || continue
                out=$(sed -n '/^%VERSION%$/{n;p;}' "$desc")
                [ -n "$out" ] && break 2
            done
        done
    fi
    _ip_semver "$out"
}

# inputplumber_probe : 0 = stock /usr/share/inputplumber/devices already has
# an RC74XA profile (superseded), 1 = still needed, 2 = no stock InputPlumber.
inputplumber_probe() {
    local dir
    dir=$(ax20_path "$_IP_STOCK_DEVICES")
    [ -d "$dir" ] || return "$PROBE_UNKNOWN"
    if [ -n "$(grep -rlF -- "$AX20_BOARD" "$dir" 2>/dev/null | head -n1)" ]; then
        return "$PROBE_YES"
    fi
    return "$PROBE_NO"
}

# inputplumber_probe_daemon_version : 0 = the stock daemon is new enough for
# the profile we ship for it (no fallback build needed), 1 = too old,
# 2 = version unknown.
inputplumber_probe_daemon_version() {
    local v
    v=$(inputplumber_stock_version) || return "$PROBE_UNKNOWN"
    probe_version_ge "$v" "$AX20_INPUTPLUMBER_STOCK_MIN"
}

# inputplumber_fallback_wanted : true when the user forces the fallback or the
# stock daemon is known to be too old. An unknown version does not trigger it.
inputplumber_fallback_wanted() {
    local rc=0
    [ "$AX20_INPUTPLUMBER_FALLBACK" = 1 ] && return 0
    inputplumber_probe_daemon_version || rc=$?
    [ "$rc" = "$PROBE_NO" ]
}

# inputplumber_fallback_bin : path (without root prefix) of our build.
inputplumber_fallback_bin() {
    printf '%s/bin/inputplumber\n' "$AX20_INPUTPLUMBER_OPT_REL"
}

inputplumber_fallback_ready() {
    [ -x "$(ax20_path "$(inputplumber_fallback_bin)")" ]
}

# inputplumber_fallback_active : the ExecStart drop-in will be in place.
inputplumber_fallback_active() {
    inputplumber_fallback_wanted && inputplumber_fallback_ready
}

# inputplumber_variant : "upstream" (verbatim PR #756 profile) or "stock"
# (adapted for daemons older than AX20_INPUTPLUMBER_PROFILE_MIN).
inputplumber_variant() {
    local v
    if inputplumber_fallback_active; then
        printf 'upstream\n'
        return 0
    fi
    if v=$(inputplumber_stock_version) && ax20_version_ge "$v" "$AX20_INPUTPLUMBER_PROFILE_MIN"; then
        printf 'upstream\n'
        return 0
    fi
    printf 'stock\n'
}

inputplumber_files() {
    local rc=0
    inputplumber_probe >/dev/null 2>&1 || rc=$?
    # No stock InputPlumber at all: nothing would read our files.
    [ "$rc" = "$PROBE_UNKNOWN" ] && return 0
    if [ "$(inputplumber_variant)" = upstream ]; then
        printf 'inputplumber/devices.d/50-rog_xbox_ally_x20.yaml\t%s\t0644\n' "$_IP_PROFILE_DEST"
    else
        printf 'inputplumber/devices.d/50-rog_xbox_ally_x20.stock.yaml\t%s\t0644\n' "$_IP_PROFILE_DEST"
        printf 'inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml\t%s\t0644\n' "$_IP_CAPMAP_DEST"
    fi
    printf 'udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb\t%s\t0644\n' "$_IP_HWDB_DEST"
}

# _ip_system_steps : should we touch the running system (hwdb, udev, systemd)?
_ip_system_steps() {
    case "$AX20_INPUTPLUMBER_SYSTEM_STEPS" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [ -z "$AX20_ROOT" ]
}

_ip_enabled_marker() {
    printf '%s/inputplumber/service-enabled-by-%s\n' "$(ax20_state_dir)" "$AX20_NAME"
}

# _ip_install_dropin : render the ExecStart override and install it.
_ip_install_dropin() {
    local tmp rc=0
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-inputplumber-dropin.XXXXXX") || die "cannot create temp file"
    sed -e "s#@AX20_INPUTPLUMBER_OPT@#${AX20_INPUTPLUMBER_OPT_REL}#g" \
        "$AX20_SRC/overlay/$_IP_DROPIN_SRC" >"$tmp" || rc=1
    if [ "$rc" = 0 ]; then
        manifest_install_file "$tmp" "$_IP_DROPIN_DEST" inputplumber 0644 shared || rc=1
    fi
    rm -f "$tmp"
    return "$rc"
}

_ip_apply_fallback() {
    if ! inputplumber_fallback_wanted; then
        if manifest_has "$_IP_DROPIN_DEST"; then
            log_warn "inputplumber: the stock daemon is new enough but the fallback ExecStart drop-in is still installed ($_IP_DROPIN_DEST); remove it with: $AX20_NAME uninstall --superseded"
        fi
        return 0
    fi
    if ! inputplumber_fallback_ready; then
        log_warn "inputplumber: fallback daemon wanted but $(inputplumber_fallback_bin) is missing; build it with build/build-inputplumber.sh and re-run apply. Keeping the stock daemon."
        return 0
    fi
    log_info "inputplumber: selecting fallback daemon $(inputplumber_fallback_bin) via $_IP_DROPIN_DEST"
    _ip_install_dropin
}

# _ip_reload : make the running system pick up the new files.
_ip_reload() {
    local marker
    if ! _ip_system_steps; then
        log_info "inputplumber: root prefix in use; skipping systemd-hwdb update, udevadm trigger and systemctl (they run on the live system)"
        return 0
    fi
    # TODO(vm): this writes /etc/udev/hwdb.bin. Check whether SteamOS already
    # has one and whether systemd-hwdb-update.service regenerates it after an
    # A/B update; a stale /etc copy would shadow /usr/lib/udev/hwdb.bin.
    if ax20_have systemd-hwdb; then
        ax20_run systemd-hwdb update || log_warn "inputplumber: systemd-hwdb update failed"
    else
        log_warn "inputplumber: systemd-hwdb not found; hwdb entry takes effect after the next hwdb rebuild"
    fi
    if ax20_have udevadm; then
        ax20_run udevadm trigger --action=change --subsystem-match=dmi \
            || log_warn "inputplumber: udevadm trigger failed"
    fi
    if ! ax20_have systemctl; then
        log_warn "inputplumber: systemctl not found; start inputplumber.service yourself"
        return 0
    fi
    if manifest_has "$_IP_DROPIN_DEST"; then
        ax20_run systemctl daemon-reload || log_warn "inputplumber: systemctl daemon-reload failed"
    fi
    if systemctl is-enabled --quiet inputplumber.service 2>/dev/null; then
        # Restart so device configs are re-read for already-present devices.
        ax20_run systemctl restart inputplumber.service \
            || log_warn "inputplumber: restarting inputplumber.service failed"
    else
        # Stock SteamOS enables the unit; record that we did it so removal
        # can undo exactly this.
        marker=$(_ip_enabled_marker)
        if ax20_run systemctl enable --now inputplumber.service; then
            if [ "$AX20_DRY_RUN" != 1 ]; then
                mkdir -p "$(dirname "$marker")"
                printf 'inputplumber.service enabled by %s\n' "$AX20_NAME" | ax20_atomic_write "$marker"
            fi
        else
            log_warn "inputplumber: systemctl enable --now inputplumber.service failed"
        fi
    fi
}

inputplumber_apply() {
    local rc=0 v
    inputplumber_probe || rc=$?
    case "$rc" in
        "$PROBE_UNKNOWN")
            log_warn "inputplumber: stock InputPlumber not found ($_IP_STOCK_DEVICES missing); nothing to do"
            return 0
            ;;
        "$PROBE_YES")
            log_warn "inputplumber: stock InputPlumber already ships an $AX20_BOARD profile; ours in /etc has the same file name and takes precedence. Run '$AX20_NAME uninstall --superseded' to use the stock one."
            ;;
    esac
    v=$(inputplumber_stock_version) || v=unknown
    log_info "inputplumber: stock daemon $v, profile variant: $(inputplumber_variant)"
    _ip_apply_fallback || return 1
    _ip_reload
    return 0
}

inputplumber_remove() {
    local marker
    marker=$(_ip_enabled_marker)
    if [ -f "$marker" ]; then
        if _ip_system_steps && ax20_have systemctl; then
            ax20_run systemctl disable inputplumber.service || log_warn "inputplumber: systemctl disable failed"
        fi
        ax20_run rm -f "$marker"
    fi
    if _ip_system_steps; then
        log_info "inputplumber: after removal run: systemd-hwdb update; systemctl daemon-reload; systemctl restart inputplumber.service"
    fi
    return 0
}
