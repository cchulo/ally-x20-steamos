#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/sdexpress.sh against fixture roots (docs/sdexpress.md): the card
# is found by the slot's PCIe root port whichever nvmeN name it has this
# boot, the rendered udev rule hands its partitions to the stock automount
# scripts, and the probe reads the stock automount rule.
load '../test_helper'

RULE=/etc/udev/rules.d/99-ally-x20-steamos-sdexpress.rules
CONF=/etc/ally-x20-steamos/sdexpress.conf
STOCK_RULE=/usr/lib/udev/rules.d/99-holo-automount.rules
CARD_PORT=0000:00:02.2
SSD_PORT=0000:00:02.1

setup() {
    make_root >/dev/null
    mkdir -p "$AX20_ROOT/etc/udev/rules.d" "$AX20_ROOT/sys/class/block"
    export AX20_BLOCK_SYS="$AX20_ROOT/sys/class/block"
    unset AX20_SDEXPRESS_SYSTEM_STEPS
    source_libs
    component_load sdexpress
}

# nvme_dev <name> <root-port> <endpoint> [model] [sectors] : one NVMe
# namespace in the fixture sysfs, as the X20 lays it out:
#   /sys/devices/pci0000:00/<port>/<ep>/nvme/<ctrl>/<name>
# plus the /sys/class/block/<name> symlink; <name>/device -> the controller.
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

# The device as measured on 2026-11-05: the SSD behind 00:02.1, the card
# behind 00:02.2; the nvmeN names depend on the order the kernel found them.
ssd_as() { nvme_dev "$1" "$SSD_PORT" 0000:61:00.0 'WD_BLACK SN850X 4000GB' 7814037168; }
card_as() { nvme_dev "$1" "$CARD_PORT" 0000:62:00.0 'ST51271_WDC SanDisk SD Express SDSQXFN   ' 956301312; }

stock_rule_mmc() {
    fixture_file "$STOCK_RULE" 'KERNEL!="mmcblk*|sd*",          GOTO="holo_automount_end"
ENV{ID_FS_USAGE}!="filesystem", GOTO="holo_automount_end"
ACTION=="add",    RUN+="/bin/systemd-run --no-block --collect /usr/lib/hwsupport/block-device-event.sh add %k"
ACTION=="remove", RUN+="/bin/systemd-run --no-block --collect /usr/lib/hwsupport/block-device-event.sh remove %k"
LABEL="holo_automount_end"
'
}

stock_rule_nvme() {
    fixture_file "$STOCK_RULE" '# nvme is not matched here: see below
KERNEL!="mmcblk*|sd*|nvme*", GOTO="holo_automount_end"
ACTION=="add", RUN+="/bin/systemd-run --no-block --collect /usr/lib/hwsupport/block-device-event.sh add %k"
LABEL="holo_automount_end"
'
}

# udevadm_stub <dir> : records its calls.
udevadm_stub() {
    mkdir -p "$1"
    printf '#!/bin/sh\necho "udevadm $*" >>"%s/calls"\nexit 0\n' "$1" >"$1/udevadm"
    chmod +x "$1/udevadm"
    : >"$1/calls"
}

manifest_count() { grep -c "\"path\":\"$1\"" "$AX20_ROOT/var/lib/ally-x20-steamos/manifest"; }

# ------------------------------------------------------------------- card --
@test "files: nothing (the rule is rendered by apply)" {
    run component_files sdexpress
    assert_success
    [ -z "$output" ]
}

@test "disk: the card is found behind 00:02.2 when it is nvme1n1 (inserted after boot)" {
    ssd_as nvme0n1
    card_as nvme1n1
    run sdexpress_disk
    assert_success
    assert_equal "$output" nvme1n1
}

@test "disk: and when it is nvme0n1 (reboot with the card in; the SSD moved to nvme1n1)" {
    card_as nvme0n1
    ssd_as nvme1n1
    run sdexpress_disk
    assert_success
    assert_equal "$output" nvme0n1
    assert_equal "$(sdexpress_partition nvme0n1)" nvme0n1p1
}

@test "disk: SSD only, no card" {
    ssd_as nvme0n1
    run sdexpress_disk
    assert_failure 1
    [ -z "$output" ]
}

@test "disk: model is trimmed, size is GiB from 512-byte sectors" {
    ssd_as nvme0n1
    card_as nvme1n1
    assert_equal "$(sdexpress_disk_model nvme1n1)" 'ST51271_WDC SanDisk SD Express SDSQXFN'
    assert_equal "$(sdexpress_disk_size nvme1n1)" 456
    assert_equal "$(sdexpress_disk_size nvme0n1)" 3726
}

# -------------------------------------------------------------- root port --
@test "root port: default without a conf file" {
    assert_equal "$(sdexpress_root_port)" "$CARD_PORT"
    assert_equal "$(sdexpress_root_port_origin)" default
}

@test "root port: conf override is honoured and reported" {
    fixture_file "$CONF" 'root_port=0000:00:02.3
'
    assert_equal "$(sdexpress_root_port)" 0000:00:02.3
    assert_equal "$(sdexpress_root_port_origin)" "from $CONF"
    nvme_dev nvme1n1 0000:00:02.3 0000:63:00.0
    card_as nvme0n1
    assert_equal "$(sdexpress_disk)" nvme1n1
}

@test "root port: junk in the conf falls back to the default" {
    fixture_file "$CONF" 'root_port=nvme0n1
'
    assert_equal "$(sdexpress_root_port)" "$CARD_PORT"
    fixture_file "$CONF" 'root_port=0000:00:02.2; rm -rf /
'
    assert_equal "$(sdexpress_root_port)" "$CARD_PORT"
    assert_equal "$(sdexpress_root_port_origin)" default
}

@test "write_conf rejects anything that is not a PCI address" {
    run sdexpress_write_conf nvme1n1
    assert_failure 2
    [ ! -e "$AX20_ROOT$CONF" ]
    run sdexpress_write_conf '0000:00:02.2 extra'
    assert_failure 2
}

# ------------------------------------------------------------------ probe --
@test "probe: stock rule matches mmcblk/sd only -> still needed" {
    stock_rule_mmc
    run component_probe sdexpress
    [ "$status" -eq 1 ]
    assert_equal "$(component_status sdexpress)" stock
}

@test "probe: stock rule matches nvme -> superseded" {
    stock_rule_nvme
    run component_probe sdexpress
    [ "$status" -eq 0 ]
    assert_equal "$(component_status sdexpress)" superseded
}

@test "probe: no stock automount rule -> unknown, status n/a" {
    run component_probe sdexpress
    [ "$status" -eq 2 ]
    assert_equal "$(component_status sdexpress)" n/a
}

@test "probe: a commented nvme mention in the stock rule does not count" {
    fixture_file "$STOCK_RULE" '# TODO nvme: KERNEL=="nvme*"
KERNEL!="mmcblk*|sd*", GOTO="holo_automount_end"
RUN+="/usr/lib/hwsupport/block-device-event.sh add %k"
LABEL="holo_automount_end"
'
    run component_probe sdexpress
    [ "$status" -eq 1 ]
}

# ------------------------------------------------------------------ apply --
@test "apply renders the rule with the root port, records it, status active, idempotent" {
    stock_rule_mmc
    run component_apply sdexpress
    assert_success
    [ -f "$AX20_ROOT$RULE" ]
    manifest_has "$RULE"
    grep -q 'DEVPATH!="\*/0000:00:02.2/\*", GOTO="ally_x20_sdexpress_end"' "$AX20_ROOT$RULE"
    ! grep -q '@ROOT_PORT' "$AX20_ROOT$RULE"
    assert_equal "$(component_status sdexpress)" active
    sha1=$(ax20_sha256 "$AX20_ROOT$RULE")
    run component_apply sdexpress
    assert_success
    assert_equal "$(ax20_sha256 "$AX20_ROOT$RULE")" "$sha1"
    assert_equal "$(manifest_count "$RULE")" 1
}

@test "rule: every non-comment line is what the stock automount rule does, limited to the slot" {
    stock_rule_mmc
    component_apply sdexpress
    r="$AX20_ROOT$RULE"
    body=$(grep -v '^[[:space:]]*#' "$r" | grep -v '^$')
    assert_equal "$(printf '%s\n' "$body" | wc -l | tr -d ' ')" 8
    assert_equal "$(printf '%s\n' "$body" | sed -n 1p)" 'SUBSYSTEM!="block", GOTO="ally_x20_sdexpress_end"'
    assert_equal "$(printf '%s\n' "$body" | sed -n 2p)" 'DEVPATH!="*/0000:00:02.2/*", GOTO="ally_x20_sdexpress_end"'
    assert_equal "$(printf '%s\n' "$body" | sed -n 3p)" 'KERNEL=="nvme*n[0-9]", ENV{ID_DRIVE_FLASH_SD}="1", ENV{ID_DRIVE_MEDIA_FLASH_SD}="1", ENV{ID_DRIVE_MEDIA_FLASH}="1"'
    assert_equal "$(printf '%s\n' "$body" | sed -n 4p)" 'KERNEL!="nvme*n[0-9]p[0-9]*", GOTO="ally_x20_sdexpress_end"'
    assert_equal "$(printf '%s\n' "$body" | sed -n 5p)" 'ENV{ID_FS_USAGE}!="filesystem", GOTO="ally_x20_sdexpress_end"'
    assert_equal "$(printf '%s\n' "$body" | sed -n 6p)" 'ACTION=="add", RUN+="/bin/systemd-run --no-block --collect /usr/lib/hwsupport/block-device-event.sh add %k"'
    assert_equal "$(printf '%s\n' "$body" | sed -n 7p)" 'ACTION=="remove", RUN+="/bin/systemd-run --no-block --collect /usr/lib/hwsupport/block-device-event.sh remove %k"'
    assert_equal "$(printf '%s\n' "$body" | sed -n 8p)" 'LABEL="ally_x20_sdexpress_end"'
}

@test "rule: never names a specific nvmeN device outside comments (names swap between boots)" {
    stock_rule_mmc
    component_apply sdexpress
    ! grep -v '^[[:space:]]*#' "$AX20_ROOT$RULE" | grep -Eq 'nvme[0-9]'
    ! grep -v '^[[:space:]]*#' "$REPO_ROOT/overlay/udev/rules.d/99-ally-x20-steamos-sdexpress.rules.in" | grep -Eq 'nvme[0-9]'
}

@test "write_conf then apply re-renders the rule with the new port" {
    stock_rule_mmc
    component_apply sdexpress
    run sdexpress_write_conf 0000:00:02.3
    assert_success
    manifest_has "$CONF"
    grep -q '^root_port=0000:00:02.3$' "$AX20_ROOT$CONF"
    run component_apply sdexpress
    assert_success
    grep -q 'DEVPATH!="\*/0000:00:02.3/\*"' "$AX20_ROOT$RULE"
    ! grep -v '^#' "$AX20_ROOT$RULE" | grep -q '0000:00:02.2'
    assert_equal "$(manifest_count "$RULE")" 1
    assert_equal "$(component_status sdexpress)" active
}

@test "apply skips udevadm on a fixture root" {
    stock_rule_mmc
    udevadm_stub "$BATS_TEST_TMPDIR/stub"
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" run component_apply sdexpress
    assert_success
    [ ! -s "$BATS_TEST_TMPDIR/stub/calls" ]
}

@test "apply with AX20_SDEXPRESS_SYSTEM_STEPS=always reloads udev (stub), remove too" {
    stock_rule_mmc
    udevadm_stub "$BATS_TEST_TMPDIR/stub"
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" AX20_SDEXPRESS_SYSTEM_STEPS=always run component_apply sdexpress
    assert_success
    grep -qx 'udevadm control --reload' "$BATS_TEST_TMPDIR/stub/calls"
    : >"$BATS_TEST_TMPDIR/stub/calls"
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" AX20_SDEXPRESS_SYSTEM_STEPS=always run component_remove_hook sdexpress
    assert_success
    grep -qx 'udevadm control --reload' "$BATS_TEST_TMPDIR/stub/calls"
}

@test "apply with a superseding stock rule still installs and warns" {
    stock_rule_nvme
    run component_apply sdexpress
    assert_success
    assert_output_contains 'already handles nvme'
    [ -f "$AX20_ROOT$RULE" ]
    assert_equal "$(component_status sdexpress)" superseded
}

@test "mount_present on a fixture root does nothing and never fails" {
    ssd_as nvme0n1
    card_as nvme1n1
    run sdexpress_mount_present
    assert_success
}

# ---------------------------------------------------------- probe details --
@test "probe details: stock rule, root port, the card, how to format" {
    stock_rule_mmc
    ssd_as nvme0n1
    card_as nvme1n1
    run sdexpress_probe_details
    assert_success
    assert_output_contains "stock automount rule: mmcblk/sd only ($STOCK_RULE)"
    assert_output_contains 'root port: 0000:00:02.2 (default)'
    assert_output_contains 'card: /dev/nvme1n1 ST51271_WDC SanDisk SD Express SDSQXFN 456 GiB'
    assert_output_contains "format: 'ally-x20-steamos sdexpress format'"
    assert_output_contains 'rejects nvme'
    [[ "$output" != *"nvme0n1"* ]]
}

@test "probe details: no card, no stock rule, conf override" {
    ssd_as nvme0n1
    fixture_file "$CONF" 'root_port=0000:00:02.3
'
    run sdexpress_probe_details
    assert_success
    assert_output_contains 'stock automount rule: not found under /usr/lib/udev/rules.d'
    assert_output_contains "root port: 0000:00:02.3 (from $CONF)"
    assert_output_contains 'card: none under that root port'
}
