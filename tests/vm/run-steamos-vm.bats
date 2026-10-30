#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# vm/run-steamos-vm.sh: command-line generation and accelerator selection.
# Pure: --print-args never needs qemu or touches the VM dir.
load '../test_helper'

VM="$REPO_ROOT/vm/run-steamos-vm.sh"

setup() {
    export AX20_VM_DIR="$BATS_TEST_TMPDIR/vms"
    export AX20_OVMF_CODE="$BATS_TEST_TMPDIR/OVMF_CODE.fd"
    export AX20_OVMF_VARS="$BATS_TEST_TMPDIR/OVMF_VARS.fd"
    : >"$AX20_OVMF_CODE"
    : >"$AX20_OVMF_VARS"
    # Default host: Linux x86-64 with a usable fake /dev/kvm.
    export AX20_VM_OS=Linux AX20_VM_ARCH=x86_64
    export AX20_VM_KVM_DEV="$BATS_TEST_TMPDIR/kvm"
    : >"$AX20_VM_KVM_DEV"
    chmod 666 "$AX20_VM_KVM_DEV"
}

# has_arg <arg> : the exact argument appears in $output (one per line).
has_arg() {
    printf '%s\n' "$output" | grep -Fxq -- "$1" || {
        printf 'missing argument: %s\noutput:\n%s\n' "$1" "$output" >&2
        return 1
    }
}
lacks_arg_prefix() {
    if printf '%s\n' "$output" | grep -Fq -- "$1"; then
        printf 'unexpected argument: %s\noutput:\n%s\n' "$1" "$output" >&2
        return 1
    fi
}
# arg_after <flag> <value> : <value> follows <flag> somewhere.
arg_after() {
    printf '%s\n' "$output" | awk -v f="$1" -v v="$2" 'prev == f && $0 == v { ok = 1 } { prev = $0 } END { exit !ok }' || {
        printf 'expected %s %s\noutput:\n%s\n' "$1" "$2" "$output" >&2
        return 1
    }
}

@test "auto accel picks kvm when /dev/kvm is usable" {
    run "$VM" --print-args
    assert_success
    assert_output_contains "accelerator: kvm"
    arg_after -accel kvm
    arg_after -cpu host
}

@test "auto accel falls back to tcg, warns and marks AX20_VM_SLOW" {
    export AX20_VM_KVM_DEV="$BATS_TEST_TMPDIR/nokvm"
    run "$VM" --print-args
    assert_success
    assert_output_contains "accelerator: tcg"
    assert_output_contains "AX20_VM_SLOW=1"
    arg_after -accel tcg,thread=multi
    arg_after -cpu max
}

@test "unreadable /dev/kvm is reported and falls back to tcg" {
    chmod 000 "$AX20_VM_KVM_DEV"
    if [ -r "$AX20_VM_KVM_DEV" ]; then skip "running as root"; fi
    run "$VM" --print-args
    assert_success
    assert_output_contains "kvm group"
    arg_after -accel tcg,thread=multi
}

@test "auto accel picks hvf on an Intel Mac" {
    export AX20_VM_OS=Darwin AX20_VM_ARCH=x86_64 AX20_VM_HVF_SUPPORT=1
    run "$VM" --print-args
    assert_success
    arg_after -accel hvf
    arg_after -display cocoa
}

@test "Apple Silicon gets tcg even with hv_support" {
    export AX20_VM_OS=Darwin AX20_VM_ARCH=arm64 AX20_VM_HVF_SUPPORT=1
    run "$VM" --print-args
    assert_success
    arg_after -accel tcg,thread=multi
}

@test "explicit --accel kvm fails when KVM is missing" {
    export AX20_VM_KVM_DEV="$BATS_TEST_TMPDIR/nokvm"
    run "$VM" --accel kvm --print-args
    assert_failure 2
    assert_output_contains "KVM is not usable"
}

@test "invalid --accel value is rejected" {
    run "$VM" --accel xen --print-args
    assert_failure 2
}

@test "SMBIOS strings match InputPlumber's X20 DMI match by default" {
    run "$VM" --print-args
    assert_success
    has_arg "type=1,manufacturer=ASUS,product=ROG Xbox Ally X20,version=1.0"
    has_arg "type=2,manufacturer=ASUSTeK COMPUTER INC.,product=RC74XA"
}

@test "SMBIOS overrides escape commas; --no-smbios drops them" {
    run "$VM" --smbios-vendor "ASUSTeK COMPUTER INC." --smbios-board "A,B" --print-args
    assert_success
    has_arg "type=1,manufacturer=ASUSTeK COMPUTER INC.,product=ROG Xbox Ally X20,version=1.0"
    has_arg "type=2,manufacturer=ASUSTeK COMPUTER INC.,product=A,,B"
    run "$VM" --no-smbios --print-args
    assert_success
    lacks_arg_prefix "-smbios"
}

@test "acpitable flag only when the file exists" {
    run "$VM" --print-args
    assert_success
    if [ ! -f "$REPO_ROOT/acpi/fixtures/x20-dsdt.aml" ]; then
        lacks_arg_prefix "-acpitable"
    fi
    : >"$BATS_TEST_TMPDIR/t.aml"
    run "$VM" --acpitable "$BATS_TEST_TMPDIR/t.aml" --print-args
    assert_success
    arg_after -acpitable "file=$BATS_TEST_TMPDIR/t.aml"
    run "$VM" --acpitable "$BATS_TEST_TMPDIR/t.aml" --no-acpitable --print-args
    assert_success
    lacks_arg_prefix "-acpitable"
    run "$VM" --acpitable "$BATS_TEST_TMPDIR/missing.aml" --print-args
    assert_failure 2
}

@test "--install boots the recovery image read-only over an NVMe target" {
    mkdir -p "$AX20_VM_DIR/cache"
    : >"$AX20_VM_DIR/cache/steamdeck-recovery-4.img"
    run "$VM" --install --print-args
    assert_success
    has_arg "if=none,id=recovery,format=raw,snapshot=on,file=$AX20_VM_DIR/cache/steamdeck-recovery-4.img"
    has_arg "virtio-blk-pci,drive=recovery,bootindex=0"
    has_arg "if=none,id=sysdisk,format=qcow2,discard=unmap,file=$AX20_VM_DIR/disks/steamos.qcow2"
    has_arg "nvme,drive=sysdisk,bootindex=1,serial=AX20VMDISK"
    has_arg "if=pflash,format=raw,readonly=on,file=$AX20_OVMF_CODE"
    [ ! -e "$AX20_VM_DIR/disks" ] # pure: nothing created
}

@test "--run boots the base disk without the recovery image" {
    run "$VM" --run --disk-bus virtio --print-args
    assert_success
    lacks_arg_prefix "id=recovery"
    has_arg "virtio-blk-pci,drive=sysdisk,bootindex=1"
}

@test "--snapshot and --restore boot a named overlay with its own vars" {
    run "$VM" --snapshot clean --print-args
    assert_success
    has_arg "if=none,id=sysdisk,format=qcow2,discard=unmap,file=$AX20_VM_DIR/snapshots/clean.qcow2"
    has_arg "if=pflash,format=raw,file=$AX20_VM_DIR/snapshots/clean.vars.fd"
    run "$VM" --restore ci --print-args
    assert_success
    has_arg "if=none,id=sysdisk,format=qcow2,discard=unmap,file=$AX20_VM_DIR/snapshots/ci.qcow2"
    run "$VM" --restore ../evil --print-args
    assert_failure 2
    run "$VM" --install --snapshot x --print-args
    assert_failure 2
}

@test "--snapshot creates a qcow2 overlay backed by the base disk (stub qemu)" {
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$AX20_VM_DIR/disks"
    : >"$AX20_VM_DIR/disks/steamos.qcow2"
    cat >"$BATS_TEST_TMPDIR/bin/qemu-img" <<'S'
#!/bin/sh
printf '%s\n' "$*" >>"$AX20_VM_DIR/qemu-img.log"
for last; do :; done
: >"$last"
S
    cat >"$BATS_TEST_TMPDIR/bin/qemu-system-x86_64" <<'S'
#!/bin/sh
printf '%s\n' "$@" >"$AX20_VM_DIR/qemu.args"
S
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$VM" --snapshot t1 --headless
    assert_success
    grep -Fq -- "create -f qcow2 -b $AX20_VM_DIR/disks/steamos.qcow2 -F qcow2 $AX20_VM_DIR/snapshots/t1.qcow2" "$AX20_VM_DIR/qemu-img.log"
    [ -f "$AX20_VM_DIR/snapshots/t1.vars.fd" ]
    grep -Fxq "AX20_VM_ACCEL=kvm" "$AX20_VM_DIR/accel.env"
    grep -Fxq "AX20_VM_SLOW=0" "$AX20_VM_DIR/accel.env"
    grep -Fxq -- "-display" "$AX20_VM_DIR/qemu.args"
}

@test "ssh port forward, offline mode and headless display" {
    run "$VM" --ssh-port 2299 --offline --headless --print-args
    assert_success
    has_arg "user,id=net0,hostfwd=tcp:127.0.0.1:2299-:22,restrict=on"
    arg_after -display none
    has_arg "virtio-vga"
    run "$VM" --ssh-port abc --print-args
    assert_failure 2
}

@test "Linux desktop default uses virtio-vga-gl with gtk gl" {
    run "$VM" --print-args
    assert_success
    has_arg "virtio-vga-gl"
    arg_after -display gtk,gl=on
}

@test "usb passthrough is validated and mapped to usb-host" {
    run "$VM" --usb-passthrough 045e:0b12 --usb-passthrough 0b05:1abe --print-args
    assert_success
    has_arg "usb-host,bus=xhci.0,vendorid=0x045e,productid=0x0b12"
    has_arg "usb-host,bus=xhci.0,vendorid=0x0b05,productid=0x1abe"
    run "$VM" --usb-passthrough 45e:b12 --print-args
    assert_failure 2
}

@test "--edid sets the GPU preferred mode from the first detailed timing and exposes the blob" {
    # Minimal 128-byte EDID base block with a 1920x1080 detailed timing at byte 54.
    e="$BATS_TEST_TMPDIR/x20.edid"
    printf '\000\377\377\377\377\377\377\000' >"$e"
    head -c 46 /dev/zero >>"$e"
    # pixel clock 0x3a02, hactive 1920 = 0x780 (lo 0x80, hi nibble 7), vactive 1080 = 0x438
    printf '\002\072\200\030\161\070\055\100' >>"$e"
    head -c 66 /dev/zero >>"$e"
    run "$VM" --edid "$e" --print-args
    assert_success
    has_arg "virtio-vga-gl,edid=on,xres=1920,yres=1080"
    has_arg "name=opt/ally-x20-steamos/edid,file=$e"
    run "$VM" --edid "$e" --edid-mode 1080x1920 --headless --print-args
    assert_success
    has_arg "virtio-vga,edid=on,xres=1080,yres=1920"
}

@test "--edid without a detailed timing asks for --edid-mode" {
    e="$BATS_TEST_TMPDIR/empty.edid"
    printf '\000\377\377\377\377\377\377\000' >"$e"
    head -c 120 /dev/zero >>"$e"
    run "$VM" --edid "$e" --print-args
    assert_failure 2
    assert_output_contains "--edid-mode"
}

@test "--print-cmd prints a single shell-quoted line" {
    run "$VM" --print-cmd
    assert_success
    assert_output_contains "qemu-system-x86_64 -name ally-x20-steamos -machine q35"
}

@test "--tpm adds the swtpm emulator devices" {
    run "$VM" --tpm --print-args
    assert_success
    has_arg "tpm-tis,tpmdev=tpm0"
    has_arg "socket,id=chrtpm,path=$AX20_VM_DIR/run/swtpm.sock"
}

@test "unknown option exits 2; --help prints usage" {
    run "$VM" --bogus
    assert_failure 2
    run "$VM" --help
    assert_success
    assert_output_contains "--usb-passthrough"
}
