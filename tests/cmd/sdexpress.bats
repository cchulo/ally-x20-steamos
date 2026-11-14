#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# cmd/sdexpress.sh against fixture roots: status, the format sequence (dry
# run; the same commands stock format-device.sh runs for a microSD card),
# label checks, mount and root-port. The card is always the namespace behind
# the slot's root port, never an nvmeN name.
load '../test_helper'

RULE=/etc/udev/rules.d/99-ally-x20-steamos-sdexpress.rules
CONF=/etc/ally-x20-steamos/sdexpress.conf
STOCK_RULE=/usr/lib/udev/rules.d/99-holo-automount.rules
AUTOMOUNT=/usr/lib/hwsupport/holo-automount.sh
CARD_PORT=0000:00:02.2
SSD_PORT=0000:00:02.1

setup() {
    make_root >/dev/null
    mkdir -p "$AX20_ROOT/etc/udev/rules.d" "$AX20_ROOT/sys/class/block"
    export AX20_BLOCK_SYS="$AX20_ROOT/sys/class/block"
    unset AX20_SDEXPRESS_SYSTEM_STEPS
    fixture_file "$STOCK_RULE" 'KERNEL!="mmcblk*|sd*", GOTO="holo_automount_end"
ACTION=="add", RUN+="/bin/systemd-run --no-block --collect /usr/lib/hwsupport/block-device-event.sh add %k"
LABEL="holo_automount_end"
'
}

nvme_dev() {
    local name=$1 port=$2 ep=$3 model=${4:-SOME MODEL} sectors=${5:-2048}
    local ctrl=${name%n[0-9]} base
    base="$AX20_ROOT/sys/devices/pci0000:00/$port/$ep/nvme/$ctrl"
    mkdir -p "$base/$name"
    printf '%s\n' "$model" >"$base/model"
    printf '%s\n' "$sectors" >"$base/$name/size"
    ln -s "$base" "$base/$name/device"
    ln -s "$base/$name" "$AX20_ROOT/sys/class/block/$name"
}
ssd_as() { nvme_dev "$1" "$SSD_PORT" 0000:61:00.0 'WD_BLACK SN850X 4000GB' 7814037168; }
card_as() { nvme_dev "$1" "$CARD_PORT" 0000:62:00.0 'ST51271_WDC SanDisk SD Express SDSQXFN' 956301312; }

@test "no sub-command prints usage and exits 2" {
    run "$CLI" sdexpress
    assert_failure 2
    assert_output_contains 'usage:'
}

@test "unknown sub-command exits 2" {
    run "$CLI" sdexpress eject
    assert_failure 2
    assert_output_contains 'unknown sdexpress command'
}

@test "help lists the command with its summary" {
    run "$CLI" help
    assert_success
    assert_output_contains 'sdexpress'
    assert_output_contains 'SD Express slot'
}

@test "status before and after apply" {
    ssd_as nvme0n1
    card_as nvme1n1
    run "$CLI" sdexpress status
    assert_success
    assert_output_contains 'status: stock'
    assert_output_contains "rule: not installed ($RULE)"
    assert_output_contains 'card: /dev/nvme1n1 ST51271_WDC SanDisk SD Express SDSQXFN 456 GiB'
    run "$CLI" apply --only sdexpress
    assert_success
    run "$CLI" sdexpress status
    assert_success
    assert_output_contains 'status: active'
    assert_output_contains "rule: installed ($RULE)"
    assert_output_contains 'root port: 0000:00:02.2 (default)'
}

@test "format: no card -> fails with guidance before any command" {
    ssd_as nvme0n1
    run "$CLI" --dry-run --yes sdexpress format
    assert_failure 1
    assert_output_contains 'no SD Express card found under PCIe root port 0000:00:02.2'
    [[ "$output" != *"parted"* ]]
    [[ "$output" != *"dd "* ]]
}

@test "format: dry run prints the stock sequence on the card's node and never the SSD's" {
    ssd_as nvme0n1
    card_as nvme1n1
    run "$CLI" --dry-run --yes sdexpress format
    assert_success
    assert_output_contains "[dry-run] $AX20_ROOT$AUTOMOUNT remove nvme1n1p1"
    assert_output_contains "[dry-run] dd if=/dev/zero of=$AX20_ROOT/dev/nvme1n1 bs=512 count=1024 status=none"
    assert_output_contains '[dry-run] sync'
    assert_output_contains "[dry-run] parted --script $AX20_ROOT/dev/nvme1n1 mklabel gpt mkpart primary 0% 100%"
    assert_output_contains '[dry-run] udevadm settle'
    assert_output_contains "[dry-run] mkfs.ext4 -m 0 -O casefold -E nodiscard,root_owner=1000:1000 -L sdcard -F $AX20_ROOT/dev/nvme1n1p1"
    assert_output_contains "[dry-run] $AX20_ROOT$AUTOMOUNT add nvme1n1p1"
    [[ "$output" != *"nvme0n1"* ]]
    [[ "$output" != *"f3probe"* ]]
    # order: dd, parted, mkfs, automount add
    dd_line=$(printf '%s\n' "$output" | grep -n 'dd if=' | cut -d: -f1)
    parted_line=$(printf '%s\n' "$output" | grep -n 'parted --script' | cut -d: -f1)
    mkfs_line=$(printf '%s\n' "$output" | grep -n 'mkfs.ext4' | cut -d: -f1)
    add_line=$(printf '%s\n' "$output" | grep -n 'holo-automount.sh add' | cut -d: -f1)
    [ "$dd_line" -lt "$parted_line" ] && [ "$parted_line" -lt "$mkfs_line" ] && [ "$mkfs_line" -lt "$add_line" ]
}

@test "format: the card as nvme0n1 after a reboot targets nvme0n1, not the SSD at nvme1n1" {
    card_as nvme0n1
    ssd_as nvme1n1
    run "$CLI" --dry-run --yes sdexpress format
    assert_success
    assert_output_contains "parted --script $AX20_ROOT/dev/nvme0n1 mklabel gpt"
    [[ "$output" != *"nvme1n1"* ]]
}

@test "format: --label, --full and --validate reach mkfs and f3probe" {
    ssd_as nvme0n1
    card_as nvme1n1
    run "$CLI" --dry-run --yes sdexpress format --label games_1 --full --validate
    assert_success
    assert_output_contains "f3probe --destructive $AX20_ROOT/dev/nvme1n1"
    assert_output_contains "mkfs.ext4 -m 0 -O casefold -E discard,root_owner=1000:1000 -L games_1 -F $AX20_ROOT/dev/nvme1n1p1"
    run "$CLI" --dry-run --yes sdexpress format --label=sdx
    assert_success
    assert_output_contains '-L sdx -F'
}

@test "format: bad labels exit 2 before touching anything" {
    ssd_as nvme0n1
    card_as nvme1n1
    for bad in '' 'has space' 'seventeen-chars-x' 'a/b' 'ümlaut'; do
        run "$CLI" --dry-run --yes sdexpress format --label "$bad"
        assert_failure 2
        [[ "$output" != *"parted"* ]]
    done
    run "$CLI" --dry-run --yes sdexpress format --bogus
    assert_failure 2
}

@test "format: follows a recorded root port" {
    ssd_as nvme0n1
    nvme_dev nvme1n1 0000:00:02.3 0000:63:00.0 'OTHER SLOT' 4194304
    run "$CLI" --dry-run --yes sdexpress format
    assert_failure 1
    assert_output_contains 'no SD Express card found'
    run "$CLI" sdexpress root-port 0000:00:02.3
    assert_success
    run "$CLI" --dry-run --yes sdexpress format
    assert_success
    assert_output_contains "parted --script $AX20_ROOT/dev/nvme1n1 mklabel gpt"
    assert_output_contains 'behind root port 0000:00:02.3'
}

@test "root-port: show default, record, show override, reject junk" {
    run "$CLI" sdexpress root-port
    assert_success
    assert_equal "$output" '0000:00:02.2 (default)'
    run "$CLI" sdexpress root-port 0000:00:02.3
    assert_success
    grep -q '^root_port=0000:00:02.3$' "$AX20_ROOT$CONF"
    grep -q 'DEVPATH!="\*/0000:00:02.3/\*"' "$AX20_ROOT$RULE"
    run "$CLI" sdexpress root-port
    assert_success
    assert_equal "$output" "0000:00:02.3 (from $CONF)"
    run "$CLI" sdexpress root-port nvme1n1
    assert_failure 2
    assert_output_contains 'not a PCI address'
    run "$CLI" sdexpress root-port 0000:00:02.3 extra
    assert_failure 2
    grep -q '^root_port=0000:00:02.3$' "$AX20_ROOT$CONF"
}

@test "mount: needs a card" {
    ssd_as nvme0n1
    run "$CLI" sdexpress mount
    assert_failure 1
    assert_output_contains 'no SD Express card found'
    card_as nvme1n1
    run "$CLI" sdexpress mount
    assert_success
}

@test "uninstall --component sdexpress removes the rule and the conf" {
    run "$CLI" sdexpress root-port 0000:00:02.3
    assert_success
    [ -f "$AX20_ROOT$RULE" ] && [ -f "$AX20_ROOT$CONF" ]
    run "$CLI" --yes uninstall --component sdexpress --keep-state
    assert_success
    [ ! -e "$AX20_ROOT$RULE" ]
    [ ! -e "$AX20_ROOT$CONF" ]
}

# lsblk_stub <dir> <mountpoint> : lsblk that reports the card's partition
# mounted (MOUNTPOINTS) and its identifiers (UUID,LABEL,PARTUUID,PARTLABEL);
# anything else prints nothing.
lsblk_stub() {
    mkdir -p "$1"
    cat >"$1/lsblk" <<STUB
#!/bin/sh
case "\$*" in
    *MOUNTPOINTS*) printf '%s\n' '$2' ;;
    *UUID,LABEL*) printf '%s\n' '2a4b0c7e-1111-2222-3333-444444444444 sdcard 9f8e7d6c-aaaa-bbbb-cccc-dddddddddddd primary' ;;
esac
STUB
    chmod +x "$1/lsblk"
}

@test "format: refuses before dd while /etc/fstab references the card (UUID line, x-systemd.automount)" {
    ssd_as nvme0n1
    card_as nvme1n2
    fixture_file /etc/fstab '# <file system> <dir> <type> <options> <dump> <pass>
UUID=2a4b0c7e-1111-2222-3333-444444444444 /home/deck/sdcard ext4 defaults,nofail,x-systemd.automount 0 0
'
    lsblk_stub "$BATS_TEST_TMPDIR/stub" /home/deck/sdcard
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" AX20_SDEXPRESS_SYSTEM_STEPS=always run "$CLI" --dry-run --yes sdexpress format
    assert_failure 1
    assert_output_contains '/etc/fstab still references the card'
    assert_output_contains 'UUID=2a4b0c7e-1111-2222-3333-444444444444 /home/deck/sdcard'
    assert_output_contains 'Migrating from a hand-made fstab mount'
    [[ "$output" != *"dd if="* ]]
    [[ "$output" != *"parted"* ]]
}

@test "format: an fstab line naming the device node is refused too, unrelated lines are not" {
    ssd_as nvme0n1
    card_as nvme1n1
    fixture_file /etc/fstab 'UUID=aaaa-bbbb /home ext4 defaults 0 0
LABEL=other /mnt/x ext4 defaults 0 0
'
    run "$CLI" --dry-run --yes sdexpress format
    assert_success
    assert_output_contains 'parted --script'
    fixture_file /etc/fstab '/dev/nvme1n1p1 /home/deck/sdcard ext4 defaults 0 0
'
    run "$CLI" --dry-run --yes sdexpress format
    assert_failure 1
    assert_output_contains '/etc/fstab still references the card'
    [[ "$output" != *"dd if="* ]]
}

@test "format: a udisks mount is unmounted first; still mounted afterwards stops the format before dd" {
    ssd_as nvme0n1
    card_as nvme1n2
    lsblk_stub "$BATS_TEST_TMPDIR/stub" /run/media/deck/sdcard
    # Dry run: the umount is printed, then the sequence (no live re-check).
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" AX20_SDEXPRESS_SYSTEM_STEPS=always run "$CLI" --dry-run --yes sdexpress format
    assert_success
    assert_output_contains '[dry-run] umount /run/media/deck/sdcard'
    umount_line=$(printf '%s\n' "$output" | grep -n 'umount /run' | cut -d: -f1)
    dd_line=$(printf '%s\n' "$output" | grep -n 'dd if=' | cut -d: -f1)
    [ "$umount_line" -lt "$dd_line" ]
    # Real run with a umount stub that does nothing (the mount keeps coming
    # back): the re-check must stop before dd.
    printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/stub/umount"
    for t in parted mkfs.ext4 udevadm dd; do printf '#!/bin/sh\necho "RAN $0 $*"\nexit 0\n' >"$BATS_TEST_TMPDIR/stub/$t"; done
    chmod +x "$BATS_TEST_TMPDIR/stub"/*
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" AX20_SDEXPRESS_SYSTEM_STEPS=always run "$CLI" --yes sdexpress format
    assert_failure 1
    assert_output_contains 'still mounted at /run/media/deck/sdcard'
    [[ "$output" != *"RAN"* ]]
}
