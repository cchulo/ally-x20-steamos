# SPDX-License-Identifier: GPL-2.0-only
# components/sdexpress.sh — make the ROG Xbox Ally X20's SD Express slot
# behave like a microSD slot on stock SteamOS (docs/sdexpress.md).
#
# An SD Express card is a PCIe/NVMe device. Stock SteamOS automounts
# removable media from one udev rule that only looks at mmcblk*|sd*, so the
# card is never mounted and Steam's Format button (format-device.sh) rejects
# its /dev/nvmeXnY node before any option is read. This component installs
# one udev rule that feeds the card's partitions to the stock scripts
# (/usr/lib/hwsupport/block-device-event.sh -> holo-automount.sh: fsck,
# udisks mount at /run/media/deck/<label>) and leaves formatting to
# `ally-x20-steamos sdexpress format`, which runs the same sequence
# format-device.sh would.
#
# The card is found by its PCIe root port, never by its nvmeN name: the
# kernel numbers NVMe controllers in probe order, and on the X20 the card and
# the internal SSD swap names between boots (measured 2026-11-05: card
# nvme1n1 when inserted after boot, nvme0n1 after a reboot with it present).
# The slot's root port 0000:00:02.2 (SSD: 0000:00:02.1) is a fixed SoC
# function.
#
# Files (all through the manifest):
#   /etc/udev/rules.d/99-ally-x20-steamos-sdexpress.rules   rendered from
#       overlay/udev/rules.d/99-ally-x20-steamos-sdexpress.rules.in
#   /etc/ally-x20-steamos/sdexpress.conf   optional root_port= override,
#       written by `sdexpress root-port <bdf>`

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="SD Express slot: automount the card through the stock holo-automount scripts (matched by PCIe root port, not nvmeN)"

SDEXPRESS_ROOT_PORT_DEFAULT="0000:00:02.2"
SDEXPRESS_RULE_NAME="99-${AX20_NAME}-sdexpress.rules"
SDEXPRESS_RULE_REL="/etc/udev/rules.d/${SDEXPRESS_RULE_NAME}"
SDEXPRESS_RULE_SRC="udev/rules.d/${SDEXPRESS_RULE_NAME}.in"
SDEXPRESS_CONF_REL="${AX20_EARLY_REL}/sdexpress.conf"
SDEXPRESS_STOCK_RULES_DIR=/usr/lib/udev/rules.d
SDEXPRESS_EVENT_SCRIPT=/usr/lib/hwsupport/block-device-event.sh
SDEXPRESS_AUTOMOUNT_SCRIPT=/usr/lib/hwsupport/holo-automount.sh
export SDEXPRESS_ROOT_PORT_DEFAULT SDEXPRESS_RULE_REL SDEXPRESS_CONF_REL SDEXPRESS_AUTOMOUNT_SCRIPT
# Where block devices are enumerated; tests point this at a fixture tree.
AX20_BLOCK_SYS="${AX20_BLOCK_SYS:-/sys/class/block}"
# auto = touch the running udev only on a live system (empty AX20_ROOT);
# never = skip; always = run even with a root prefix (tests, stub udevadm).
AX20_SDEXPRESS_SYSTEM_STEPS="${AX20_SDEXPRESS_SYSTEM_STEPS:-auto}"

# The rule is rendered by sdexpress_apply (root port), so nothing here.
sdexpress_files() {
    return 0
}

# sdexpress_valid_bdf <string> : a PCI address like 0000:00:02.2.
sdexpress_valid_bdf() {
    printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$'
}

# sdexpress_root_port_conf : the root_port= value from sdexpress.conf, or
# nothing (missing file, missing key, or a value that is not a BDF).
sdexpress_root_port_conf() {
    local f v=""
    f=$(ax20_path "$SDEXPRESS_CONF_REL")
    [ -f "$f" ] || return 0
    v=$(sed -n 's/^[[:space:]]*root_port[[:space:]]*=[[:space:]]*//p' "$f" | tail -n 1 | tr -d '[:space:]')
    [ -n "$v" ] || return 0
    sdexpress_valid_bdf "$v" || return 0
    printf '%s\n' "$v"
}

# sdexpress_root_port : the slot's PCIe root port (conf override or default).
sdexpress_root_port() {
    local v
    v=$(sdexpress_root_port_conf)
    printf '%s\n' "${v:-$SDEXPRESS_ROOT_PORT_DEFAULT}"
}

# sdexpress_root_port_origin : "default" or "from <conf path>".
sdexpress_root_port_origin() {
    if [ -n "$(sdexpress_root_port_conf)" ]; then
        printf 'from %s\n' "$SDEXPRESS_CONF_REL"
    else
        printf 'default\n'
    fi
}

# sdexpress_disk : print the whole-disk name (nvme0n1) of the NVMe namespace
# behind the slot's root port, or exit 1. Matches the resolved sysfs path,
# never the device number.
sdexpress_disk() {
    local port d real
    port=$(sdexpress_root_port)
    for d in "$AX20_BLOCK_SYS"/nvme*n[0-9]; do
        [ -e "$d" ] || continue
        real=$(readlink -f "$d") || continue
        case "$real" in
            */"$port"/*)
                printf '%s\n' "${d##*/}"
                return 0
                ;;
        esac
    done
    return 1
}

# sdexpress_partition <disk> : the first partition's name (nvme0n1p1).
sdexpress_partition() {
    printf '%sp1\n' "$1"
}

# sdexpress_disk_model <disk> : the controller's model string, trimmed.
sdexpress_disk_model() {
    local f
    f="$AX20_BLOCK_SYS/$1/device/model"
    [ -r "$f" ] || return 1
    sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$f"
}

# sdexpress_disk_size <disk> : size in GiB (the size attribute is in
# 512-byte sectors).
sdexpress_disk_size() {
    local f sectors
    f="$AX20_BLOCK_SYS/$1/size"
    [ -r "$f" ] || return 1
    sectors=$(tr -d '[:space:]' <"$f")
    case "$sectors" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s\n' $((sectors / 2097152))
}

# sdexpress_stock_rule : path (without root) of the stock udev rule that
# calls block-device-event.sh, or exit 1.
sdexpress_stock_rule() {
    local f
    for f in "$(ax20_path "$SDEXPRESS_STOCK_RULES_DIR")"/*.rules; do
        [ -f "$f" ] || continue
        if grep -q 'block-device-event.sh' "$f"; then
            printf '%s\n' "${f#"$AX20_ROOT"}"
            return 0
        fi
    done
    return 1
}

# _sdexpress_stock_rule_has_nvme <path-with-root> : a non-comment KERNEL
# match in the stock rule mentions nvme.
_sdexpress_stock_rule_has_nvme() {
    grep -v '^[[:space:]]*#' "$1" | grep -E 'KERNEL[!=]=' | grep -q 'nvme'
}

# sdexpress_probe : 0 = the stock automount rule already handles nvme
# (superseded), 1 = still needed, 2 = no stock automount rule found.
sdexpress_probe() {
    local rule
    rule=$(sdexpress_stock_rule) || return "$PROBE_UNKNOWN"
    if _sdexpress_stock_rule_has_nvme "$(ax20_path "$rule")"; then
        return "$PROBE_YES"
    fi
    return "$PROBE_NO"
}

# sdexpress_card_line : one line about the card behind the root port.
sdexpress_card_line() {
    local disk model size
    if ! disk=$(sdexpress_disk); then
        printf 'card: none under that root port\n'
        return 0
    fi
    model=$(sdexpress_disk_model "$disk" || echo '?')
    size=$(sdexpress_disk_size "$disk" || echo '?')
    printf 'card: /dev/%s %s %s GiB\n' "$disk" "$model" "$size"
}

# sdexpress_partition_mounts <disk> : mountpoints of the card's first
# partition, one per line (live systems only; empty otherwise).
sdexpress_partition_mounts() {
    [ -z "$AX20_ROOT" ] || return 0
    ax20_have findmnt || return 0
    findmnt -rn -o TARGET -S "/dev/$(sdexpress_partition "$1")" 2>/dev/null || true
}

# sdexpress_probe_details : lines for `probe`, `status --verbose` and
# `sdexpress status`.
sdexpress_probe_details() {
    local rule disk mounts
    if rule=$(sdexpress_stock_rule); then
        if _sdexpress_stock_rule_has_nvme "$(ax20_path "$rule")"; then
            printf 'stock automount rule: handles nvme (%s)\n' "$rule"
        else
            printf 'stock automount rule: mmcblk/sd only (%s)\n' "$rule"
        fi
    else
        printf 'stock automount rule: not found under %s\n' "$SDEXPRESS_STOCK_RULES_DIR"
    fi
    printf 'root port: %s (%s)\n' "$(sdexpress_root_port)" "$(sdexpress_root_port_origin)"
    sdexpress_card_line
    if disk=$(sdexpress_disk) && [ -z "$AX20_ROOT" ]; then
        mounts=$(sdexpress_partition_mounts "$disk" | tr '\n' ' ')
        if [ -n "$mounts" ]; then
            printf 'mounted: /dev/%s at %s\n' "$(sdexpress_partition "$disk")" "$mounts"
        else
            printf 'mounted: no (/dev/%s)\n' "$(sdexpress_partition "$disk")"
        fi
    fi
    printf "format: '%s sdexpress format' (Steam's Format button runs format-device.sh, which rejects nvme nodes)\n" "$AX20_NAME"
}

# sdexpress_render_rule : the rule with the root port filled in, on stdout.
sdexpress_render_rule() {
    local port
    port=$(sdexpress_root_port)
    sed -e "s|@ROOT_PORT_DEFAULT@|$SDEXPRESS_ROOT_PORT_DEFAULT|g" \
        -e "s|@ROOT_PORT@|$port|g" \
        "$AX20_SRC/overlay/$SDEXPRESS_RULE_SRC"
}

# _sdexpress_install_rendered <dest> : stdin -> manifest-tracked file.
_sdexpress_install_rendered() {
    local dest=$1 tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-sdexpress.XXXXXX") || die "cannot create a temporary file"
    cat >"$tmp"
    manifest_install_file "$tmp" "$dest" sdexpress 0644
    rm -f "$tmp"
}

# sdexpress_write_conf <bdf> : record the root port override.
sdexpress_write_conf() {
    local bdf=$1
    sdexpress_valid_bdf "$bdf" || die 2 "sdexpress: '$bdf' is not a PCI address (expected dddd:bb:dd.f, e.g. $SDEXPRESS_ROOT_PORT_DEFAULT)"
    printf '%s\n' \
        "# $AX20_NAME sdexpress settings. Managed by '$AX20_NAME sdexpress root-port';" \
        "# the PCIe root port of the SD Express slot (default $SDEXPRESS_ROOT_PORT_DEFAULT)." \
        "root_port=$bdf" \
        | _sdexpress_install_rendered "$SDEXPRESS_CONF_REL"
}

# _sdexpress_system_steps : touch the running udev only on a live system.
_sdexpress_system_steps() {
    case "$AX20_SDEXPRESS_SYSTEM_STEPS" in
        always) return 0 ;;
        never) return 1 ;;
    esac
    [ -z "$AX20_ROOT" ]
}

_sdexpress_udev_reload() {
    if ! _sdexpress_system_steps; then
        log_debug "sdexpress: root prefix in use; skipping udevadm reload"
        return 0
    fi
    if ax20_have udevadm; then
        ax20_run udevadm control --reload >/dev/null 2>&1 || log_warn "sdexpress: udevadm control --reload failed"
    fi
    return 0
}

# sdexpress_mount_present : if a card is present, its first partition is a
# block device with an ext4 filesystem and nothing is mounted from it, hand
# it to the stock automount script (udisks mount at /run/media/deck/<label>).
# An already-mounted partition (e.g. a hand-made fstab mount) is left alone.
# Never fails; returns 0 and logs what it did.
sdexpress_mount_present() {
    local disk part dev fstype script
    if ! _sdexpress_system_steps; then
        log_debug "sdexpress: root prefix in use; not mounting"
        return 0
    fi
    if ! disk=$(sdexpress_disk); then
        log_info "sdexpress: no card under root port $(sdexpress_root_port)"
        return 0
    fi
    part=$(sdexpress_partition "$disk")
    dev=$(ax20_path "/dev/$part")
    if [ ! -b "$dev" ]; then
        log_info "sdexpress: /dev/$disk has no first partition; format it with '$AX20_NAME sdexpress format'"
        return 0
    fi
    fstype=""
    if ax20_have lsblk; then
        fstype=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1 | tr -d '[:space:]')
    fi
    if [ "$fstype" != ext4 ]; then
        log_info "sdexpress: /dev/$part is ${fstype:-unformatted}, not ext4; holo-automount only mounts ext4 ('$AX20_NAME sdexpress format')"
        return 0
    fi
    if [ -n "$(sdexpress_partition_mounts "$disk")" ]; then
        log_info "sdexpress: /dev/$part is already mounted; leaving it alone"
        return 0
    fi
    script=$(ax20_path "$SDEXPRESS_AUTOMOUNT_SCRIPT")
    if [ ! -x "$script" ]; then
        log_warn "sdexpress: $SDEXPRESS_AUTOMOUNT_SCRIPT not found; reinsert the card to mount it"
        return 0
    fi
    if ax20_run "$script" add "$part"; then
        log_info "sdexpress: handed /dev/$part to holo-automount (see /run/media/deck)"
    else
        log_warn "sdexpress: holo-automount.sh add $part failed; see: journalctl -t holo-automount"
    fi
    return 0
}

sdexpress_apply() {
    local rc=0
    sdexpress_probe || rc=$?
    case "$rc" in
        "$PROBE_YES")
            log_warn "sdexpress: the stock automount rule already handles nvme; run '$AX20_NAME uninstall --superseded' to remove this rule"
            ;;
        "$PROBE_UNKNOWN")
            log_warn "sdexpress: no stock automount rule found under $SDEXPRESS_STOCK_RULES_DIR; installing the rule anyway"
            ;;
    esac
    sdexpress_render_rule | _sdexpress_install_rendered "$SDEXPRESS_RULE_REL"
    log_info "sdexpress: rule matches root port $(sdexpress_root_port) ($(sdexpress_root_port_origin))"
    _sdexpress_udev_reload
    sdexpress_mount_present
    return 0
}

# sdexpress_remove : reload udev; an existing mount is left alone (udisks
# owns it; it goes away with the card).
sdexpress_remove() {
    _sdexpress_udev_reload
    return 0
}
