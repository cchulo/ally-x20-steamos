# SPDX-License-Identifier: GPL-2.0-only
# summary: the SD Express slot: status | format [--label <l>] [--full] [--validate] | mount | root-port [<bdf>]
#
# The card is always located by the slot's PCIe root port (component
# sdexpress), never by an nvmeN name and never from an argument: the names
# swap between boots on the X20 and a wrong one would erase the internal SSD.
# `format` runs the sequence stock format-device.sh uses for microSD cards
# (GPT, one partition, ext4 with casefold, owned by uid 1000), because that
# script rejects nvme nodes before reading any option, so Steam's Format
# button cannot work for this slot (docs/sdexpress.md).

# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

_sdexpress_usage() {
    cat <<USAGE
usage: $AX20_NAME sdexpress <command>

  status                      component state, stock rule, root port, the card
  format [--label <l>] [--full] [--validate]
                              erase the card and format it like Steam formats a
                              microSD card: GPT, one ext4 partition (casefold,
                              owned by deck), then mount it. Label: 1-16 chars
                              of A-Za-z0-9._- (default sdcard). --full issues
                              discards for the whole card; --validate runs
                              f3probe --destructive first (slow). Asks you to
                              type 'erase' unless --yes; --dry-run prints the
                              commands only.
  mount                       hand an inserted, formatted card to the stock
                              automount script (udisks mount under
                              /run/media/deck/<label>)
  root-port [<bdf>]           show the slot's PCIe root port, or record one
                              (e.g. 0000:00:02.2) and re-apply the rule

Needs root (except status, root-port without an argument, and --dry-run).
See docs/sdexpress.md.
USAGE
}

cmd_sdexpress() {
    component_load sdexpress
    case "${1:-}" in
        status) _sdexpress_cmd_status ;;
        format)
            shift
            _sdexpress_cmd_format "$@"
            ;;
        mount)
            shift
            _sdexpress_cmd_mount "$@"
            ;;
        root-port)
            shift
            _sdexpress_cmd_root_port "$@"
            ;;
        -h | --help | help) _sdexpress_usage ;;
        '')
            _sdexpress_usage >&2
            return 2
            ;;
        *)
            log_error "unknown sdexpress command: $1"
            _sdexpress_usage >&2
            return 2
            ;;
    esac
}

_sdexpress_cmd_status() {
    local disk
    printf 'status: %s\n' "$(component_status sdexpress)"
    sdexpress_probe_details
    if manifest_has "$SDEXPRESS_RULE_REL" && [ -f "$(ax20_path "$SDEXPRESS_RULE_REL")" ]; then
        printf 'rule: installed (%s)\n' "$SDEXPRESS_RULE_REL"
    else
        printf 'rule: not installed (%s)\n' "$SDEXPRESS_RULE_REL"
    fi
    if [ -z "$AX20_ROOT" ] && ax20_have lsblk && disk=$(sdexpress_disk); then
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "/dev/$disk" 2>/dev/null || true
    fi
}

# _sdexpress_require_card : print the card's disk name or die with guidance.
_sdexpress_require_card() {
    local disk
    disk=$(sdexpress_disk) || die "no SD Express card found under PCIe root port $(sdexpress_root_port) ($(sdexpress_root_port_origin)); insert a card, check '$AX20_NAME sdexpress status', or record the slot's port with '$AX20_NAME sdexpress root-port <bdf>'"
    printf '%s\n' "$disk"
}

# _sdexpress_automount <add|remove> <partition> : run the stock script, or
# print the call when dry-running on a root without it.
_sdexpress_automount() {
    local script
    script=$(ax20_path "$SDEXPRESS_AUTOMOUNT_SCRIPT")
    if [ -x "$script" ] || [ "$AX20_DRY_RUN" = 1 ]; then
        ax20_run "$script" "$1" "$2"
    else
        log_warn "sdexpress: $SDEXPRESS_AUTOMOUNT_SCRIPT not found; skipping holo-automount $1"
    fi
}

# _sdexpress_disk_mounts <disk> : every mountpoint on the card, one per line
# (live systems with lsblk only).
_sdexpress_disk_mounts() {
    [ -z "$AX20_ROOT" ] || return 0
    ax20_have lsblk || return 0
    lsblk -rno MOUNTPOINTS "/dev/$1" 2>/dev/null | grep -v '^$' || true
}

_sdexpress_confirm_erase() {
    local answer=""
    if [ "$AX20_ASSUME_YES" = 1 ] || [ "$AX20_DRY_RUN" = 1 ]; then
        return 0
    fi
    printf "This erases everything on /dev/%s (%s, %s GiB). Type 'erase' to continue: " "$1" "$2" "$3" >&2
    IFS= read -r answer || answer=""
    [ "$answer" = erase ] || die "aborted; nothing was changed"
}

_sdexpress_cmd_format() {
    local label=sdcard discard=nodiscard validate=0 disk part dev pdev model size mp tool
    while [ $# -gt 0 ]; do
        case "$1" in
            --label)
                [ $# -ge 2 ] || die 2 "--label needs a value"
                label=$2
                shift 2
                ;;
            --label=*)
                label=${1#--label=}
                shift
                ;;
            --full)
                discard=discard
                shift
                ;;
            --validate)
                validate=1
                shift
                ;;
            -h | --help)
                _sdexpress_usage
                return 0
                ;;
            *) die 2 "unknown sdexpress format option: $1" ;;
        esac
    done
    printf '%s\n' "$label" | grep -Eq '^[A-Za-z0-9._-]{1,16}$' \
        || die 2 "sdexpress format: label '$label' must be 1-16 characters of A-Za-z0-9._-"
    [ "$AX20_DRY_RUN" = 1 ] || require_root sdexpress format
    disk=$(_sdexpress_require_card)
    part=$(sdexpress_partition "$disk")
    dev=$(ax20_path "/dev/$disk")
    pdev=$(ax20_path "/dev/$part")
    model=$(sdexpress_disk_model "$disk" || echo '?')
    size=$(sdexpress_disk_size "$disk" || echo '?')
    if [ "$AX20_DRY_RUN" != 1 ]; then
        for tool in parted mkfs.ext4 udevadm lsblk; do
            ax20_have "$tool" || die "sdexpress format: $tool not found"
        done
        [ "$validate" = 0 ] || ax20_have f3probe || die "sdexpress format: --validate needs f3probe"
    fi
    log_info "sdexpress: card /dev/$disk ($model, $size GiB) behind root port $(sdexpress_root_port); label '$label', $discard"
    _sdexpress_confirm_erase "$disk" "$model" "$size"
    _sdexpress_automount remove "$part" || true
    _sdexpress_disk_mounts "$disk" | while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        ax20_run umount "$mp" || die "sdexpress format: cannot unmount $mp (close what uses it, or remove its fstab line)"
    done || return 1
    if [ "$validate" = 1 ]; then
        ax20_run f3probe --destructive "$dev" || die 14 "sdexpress format: f3probe found the card faulty or counterfeit; not formatting"
    fi
    # Same sequence as /usr/lib/hwsupport/format-device.sh for a microSD card.
    ax20_run dd if=/dev/zero of="$dev" bs=512 count=1024 status=none || die "sdexpress format: wiping the start of $dev failed"
    ax20_run sync
    ax20_run parted --script "$dev" mklabel gpt mkpart primary 0% 100% || die "sdexpress format: parted failed on $dev"
    ax20_run udevadm settle
    ax20_run mkfs.ext4 -m 0 -O casefold -E "$discard,root_owner=1000:1000" -L "$label" -F "$pdev" || die "sdexpress format: mkfs.ext4 failed on $pdev"
    ax20_run udevadm settle
    _sdexpress_automount add "$part" || log_warn "sdexpress: holo-automount.sh add $part failed; see: journalctl -t holo-automount"
    log_info "sdexpress: /dev/$part formatted as ext4 '$label'; expect it at /run/media/deck/$label (then add it in Steam: Settings > Storage)"
}

_sdexpress_cmd_mount() {
    [ $# -eq 0 ] || die 2 "usage: $AX20_NAME sdexpress mount"
    require_root sdexpress mount
    _sdexpress_require_card >/dev/null
    sdexpress_mount_present
}

_sdexpress_cmd_root_port() {
    case "${1:-}" in
        '')
            printf '%s (%s)\n' "$(sdexpress_root_port)" "$(sdexpress_root_port_origin)"
            return 0
            ;;
    esac
    [ $# -eq 1 ] || die 2 "usage: $AX20_NAME sdexpress root-port [<bdf>]"
    sdexpress_valid_bdf "$1" || die 2 "sdexpress root-port: '$1' is not a PCI address (expected dddd:bb:dd.f, e.g. $SDEXPRESS_ROOT_PORT_DEFAULT)"
    require_root sdexpress root-port "$1"
    ax20_check_readonly_root
    sdexpress_write_conf "$1"
    component_apply sdexpress || return 1
    log_info "sdexpress: root port $(sdexpress_root_port) ($(sdexpress_root_port_origin))"
}
