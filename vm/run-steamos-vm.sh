#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/run-steamos-vm.sh — boot SteamOS under QEMU (KVM/HVF/TCG) for testing.
#
# Usage: vm/run-steamos-vm.sh [mode] [options]
#
# Modes (default --run):
#   --install                 boot the recovery image with an empty target disk
#   --run                     boot the installed base disk
#   --snapshot <name>         boot overlay <name> (qcow2 backed by the base disk;
#                             created on first use, kept between runs)
#   --restore <name>          recreate overlay <name> from the base disk (clean
#                             state), then boot it
#   --list-snapshots          list overlays and exit
#
# Options:
#   --vm-dir <dir>            VM state dir (default ~/vms/ally-x20-steamos)
#   --disk <file>             base disk (default <vm-dir>/disks/steamos.qcow2)
#   --disk-size <size>        size for a new base disk (default 64G)
#   --disk-bus nvme|virtio    how the system disk is attached (default nvme)
#   --recovery <file>         recovery image (default newest <vm-dir>/cache/*.img)
#   --smbios / --no-smbios    inject X20 DMI strings (default on)
#   --smbios-vendor <s>       type 1 manufacturer (sys_vendor)   default "ASUS"
#   --smbios-product <s>      type 1 product (product_name)       default "ROG Xbox Ally X20"
#   --smbios-board-vendor <s> type 2 manufacturer (board_vendor)  default "ASUSTeK COMPUTER INC."
#   --smbios-board <s>        type 2 product (board_name)         default "RC74XA"
#   --acpitable <file>        extra ACPI table (default acpi/fixtures/x20-dsdt.aml if present)
#   --no-acpitable            do not add any ACPI table
#   --edid <file>             X20 EDID blob: sets the virtual GPU's preferred mode
#                             and exposes the blob via fw_cfg (see vm/README.md)
#   --edid-mode <WxH>         override the mode parsed from the EDID
#   --usb-passthrough <v:p>   pass a host USB device through (repeatable)
#   --ssh-port <port>         host port forwarded to guest :22 (default 2222)
#   --offline                 user-mode network without outside access (restrict=on)
#   --headless                no display window (CI)
#   --display <spec>          explicit QEMU -display value
#   --accel auto|kvm|hvf|tcg  accelerator (default auto: kvm -> hvf -> tcg)
#   --cpus <n> / --mem <size> guest resources (default 4 / 8G)
#   --tpm                     attach a swtpm TPM 2.0 (optional, needs swtpm)
#   --print-cmd               print the QEMU command line (shell-quoted) and exit
#   --print-args              print one QEMU argument per line and exit
#   -h, --help                this help
#
# Environment overrides (mostly for tests): AX20_VM_DIR, AX20_QEMU,
# AX20_QEMU_IMG, AX20_OVMF_CODE, AX20_OVMF_VARS, AX20_VM_OS, AX20_VM_ARCH,
# AX20_VM_KVM_DEV, AX20_VM_HVF_SUPPORT.
#
# After accelerator selection the script exports AX20_VM_ACCEL and
# AX20_VM_SLOW (1 under tcg) and writes them to <vm-dir>/accel.env so test
# harnesses can skip slow suites.
#
# --print-cmd / --print-args are pure: they create no files and do not need
# qemu installed. tests/vm/run-steamos-vm.bats relies on that.
set -eu

VM_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VM_REPO_ROOT=$(cd "$VM_SCRIPT_DIR/.." && pwd)

vm_log() { printf 'run-steamos-vm: %s\n' "$*" >&2; }
vm_warn() { printf 'run-steamos-vm: WARNING: %s\n' "$*" >&2; }
vm_die() {
    printf 'run-steamos-vm: error: %s\n' "$*" >&2
    exit 2
}

vm_usage() {
    sed -n '3,/^set -eu/p' "${BASH_SOURCE[0]}" | sed -e '/^set -eu/d' -e 's/^# \{0,1\}//'
}

vm_defaults() {
    VM_MODE=run
    VM_WANT_INSTALL=0
    VM_DIR=${AX20_VM_DIR:-${HOME:-/tmp}/vms/ally-x20-steamos}
    VM_DISK=
    VM_DISK_SIZE=64G
    VM_DISK_BUS=nvme
    VM_RECOVERY=
    VM_SNAPSHOT=
    VM_RESTORE=0
    VM_SMBIOS=1
    # Defaults follow the upstream InputPlumber X20 match (PR #756):
    #   dmi_data: { board_name: RC74XA, sys_vendor: ASUS }
    #   hwdb:     dmi:*svnASUS:*rnRC74XA:*
    # sys_vendor = SMBIOS type 1 manufacturer, product_name = type 1 product,
    # board_vendor = type 2 manufacturer, board_name = type 2 product.
    # TODO(hw): confirm all four strings with `cat /sys/class/dmi/id/*` on an X20.
    VM_SMBIOS_VENDOR="ASUS"
    VM_SMBIOS_PRODUCT="ROG Xbox Ally X20"
    VM_SMBIOS_VERSION="1.0"
    VM_SMBIOS_BOARD_VENDOR="ASUSTeK COMPUTER INC."
    VM_SMBIOS_BOARD="RC74XA"
    VM_ACPITABLE=
    VM_ACPITABLE_SET=0
    VM_NO_ACPITABLE=0
    VM_EDID=
    VM_EDID_MODE=
    VM_USB=
    VM_SSH_PORT=2222
    VM_OFFLINE=0
    VM_HEADLESS=0
    VM_DISPLAY=
    VM_ACCEL=auto
    VM_CPUS=4
    VM_MEM=8G
    VM_TPM=0
    VM_PRINT=
    VM_LIST=0
    VM_QEMU=${AX20_QEMU:-qemu-system-x86_64}
    VM_QEMU_IMG=${AX20_QEMU_IMG:-qemu-img}
    VM_CMD=()
}

# vm_parse_args "$@" : fill VM_* from the command line.
vm_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --install) VM_MODE=install VM_WANT_INSTALL=1 ;;
            --run) VM_MODE=run ;;
            --snapshot)
                [ $# -ge 2 ] || vm_die "--snapshot needs a name"
                VM_MODE=snapshot VM_SNAPSHOT=$2
                shift
                ;;
            --restore)
                [ $# -ge 2 ] || vm_die "--restore needs a name"
                VM_MODE=snapshot VM_SNAPSHOT=$2 VM_RESTORE=1
                shift
                ;;
            --list-snapshots) VM_LIST=1 ;;
            --vm-dir | --disk | --disk-size | --disk-bus | --recovery | --smbios-vendor | --smbios-product | \
                --smbios-board-vendor | --smbios-board | --acpitable | --edid | --edid-mode | \
                --usb-passthrough | --ssh-port | --display | --accel | --cpus | --mem)
                [ $# -ge 2 ] || vm_die "$1 needs a value"
                case "$1" in
                    --vm-dir) VM_DIR=$2 ;;
                    --disk) VM_DISK=$2 ;;
                    --disk-size) VM_DISK_SIZE=$2 ;;
                    --disk-bus) VM_DISK_BUS=$2 ;;
                    --recovery) VM_RECOVERY=$2 ;;
                    --smbios-vendor) VM_SMBIOS_VENDOR=$2 ;;
                    --smbios-product) VM_SMBIOS_PRODUCT=$2 ;;
                    --smbios-board-vendor) VM_SMBIOS_BOARD_VENDOR=$2 ;;
                    --smbios-board) VM_SMBIOS_BOARD=$2 ;;
                    --acpitable) VM_ACPITABLE=$2 VM_ACPITABLE_SET=1 ;;
                    --edid) VM_EDID=$2 ;;
                    --edid-mode) VM_EDID_MODE=$2 ;;
                    --usb-passthrough) VM_USB="${VM_USB:+$VM_USB }$2" ;;
                    --ssh-port) VM_SSH_PORT=$2 ;;
                    --display) VM_DISPLAY=$2 ;;
                    --accel) VM_ACCEL=$2 ;;
                    --cpus) VM_CPUS=$2 ;;
                    --mem) VM_MEM=$2 ;;
                esac
                shift
                ;;
            --smbios) VM_SMBIOS=1 ;;
            --no-smbios) VM_SMBIOS=0 ;;
            --no-acpitable) VM_NO_ACPITABLE=1 ;;
            --offline) VM_OFFLINE=1 ;;
            --headless) VM_HEADLESS=1 ;;
            --tpm) VM_TPM=1 ;;
            --print-cmd) VM_PRINT=cmd ;;
            --print-args) VM_PRINT=args ;;
            -h | --help)
                vm_usage
                exit 0
                ;;
            *) vm_die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done
}

vm_validate() {
    case "$VM_ACCEL" in auto | kvm | hvf | tcg) ;; *) vm_die "--accel must be auto|kvm|hvf|tcg" ;; esac
    case "$VM_DISK_BUS" in nvme | virtio) ;; *) vm_die "--disk-bus must be nvme|virtio" ;; esac
    case "$VM_SSH_PORT" in '' | *[!0-9]*) vm_die "--ssh-port must be a number" ;; esac
    case "$VM_CPUS" in '' | *[!0-9]*) vm_die "--cpus must be a number" ;; esac
    case "$VM_SNAPSHOT" in
        */* | .*) vm_die "snapshot name must be a plain name" ;;
    esac
    local u
    for u in $VM_USB; do
        printf '%s\n' "$u" | grep -Eq '^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$' \
            || vm_die "--usb-passthrough wants vid:pid in hex (e.g. 045e:0b12), got: $u"
    done
    if [ -n "$VM_EDID_MODE" ]; then
        printf '%s\n' "$VM_EDID_MODE" | grep -Eq '^[0-9]+x[0-9]+$' || vm_die "--edid-mode wants WxH"
    fi
    if [ "$VM_ACPITABLE_SET" = 1 ] && [ ! -f "$VM_ACPITABLE" ]; then
        vm_die "ACPI table not found: $VM_ACPITABLE"
    fi
    if [ -n "$VM_EDID" ] && [ ! -f "$VM_EDID" ]; then
        vm_die "EDID file not found: $VM_EDID"
    fi
    if [ "$VM_WANT_INSTALL" = 1 ] && [ -n "$VM_SNAPSHOT" ]; then
        vm_die "--install cannot be combined with --snapshot/--restore"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Accelerator selection
# ---------------------------------------------------------------------------

# vm_kvm_usable : /dev/kvm (or AX20_VM_KVM_DEV) exists and is read/writable.
vm_kvm_usable() {
    local dev=${AX20_VM_KVM_DEV:-/dev/kvm}
    [ -e "$dev" ] && [ -r "$dev" ] && [ -w "$dev" ]
}

vm_host_os() { printf '%s\n' "${AX20_VM_OS:-$(uname -s)}"; }
vm_host_arch() { printf '%s\n' "${AX20_VM_ARCH:-$(uname -m)}"; }

# vm_hvf_usable : Intel macOS with the Hypervisor framework. HVF on Apple
# Silicon only runs arm64 guests, so x86 SteamOS falls back to tcg there.
vm_hvf_usable() {
    [ "$(vm_host_os)" = Darwin ] || return 1
    case "$(vm_host_arch)" in x86_64 | amd64) ;; *) return 1 ;; esac
    local hv=${AX20_VM_HVF_SUPPORT:-}
    [ -n "$hv" ] || hv=$(sysctl -n kern.hv_support 2>/dev/null || echo 0)
    [ "$hv" = 1 ]
}

vm_kvm_possible() {
    [ "$(vm_host_os)" = Linux ] || return 1
    case "$(vm_host_arch)" in x86_64 | amd64) ;; *) return 1 ;; esac
    vm_kvm_usable
}

# vm_detect_accel : print kvm, hvf or tcg.
vm_detect_accel() {
    if vm_kvm_possible; then
        echo kvm
    elif vm_hvf_usable; then
        echo hvf
    else
        echo tcg
    fi
}

# vm_resolve_accel : set VM_ACCEL_RESOLVED and AX20_VM_SLOW, warn on tcg.
vm_resolve_accel() {
    local a=$VM_ACCEL
    case "$a" in
        auto)
            a=$(vm_detect_accel)
            if [ "$a" = tcg ] && [ "$(vm_host_os)" = Linux ] && [ -e "${AX20_VM_KVM_DEV:-/dev/kvm}" ]; then
                vm_warn "${AX20_VM_KVM_DEV:-/dev/kvm} exists but is not read/writable; add yourself to the kvm group and log in again"
            fi
            ;;
        kvm) vm_kvm_possible || vm_die "--accel kvm requested but KVM is not usable (Linux x86-64 with read/write ${AX20_VM_KVM_DEV:-/dev/kvm})" ;;
        hvf) vm_hvf_usable || vm_die "--accel hvf requested but this is not an Intel Mac with kern.hv_support=1" ;;
        tcg) ;;
    esac
    VM_ACCEL_RESOLVED=$a
    if [ "$a" = tcg ]; then
        AX20_VM_SLOW=1
        vm_warn "using tcg (software emulation): expect 10-20x slower boots and updates; AX20_VM_SLOW=1 so slow tests skip"
    else
        AX20_VM_SLOW=0
    fi
    AX20_VM_ACCEL=$a
    export AX20_VM_ACCEL AX20_VM_SLOW
    vm_log "accelerator: $a (requested: $VM_ACCEL)"
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# vm_find_ovmf : set VM_OVMF_CODE / VM_OVMF_VARS_TEMPLATE (empty if not found).
# Pairs are tried in order; CODE and VARS must come from the same build.
vm_find_ovmf() {
    VM_OVMF_CODE=${AX20_OVMF_CODE:-}
    VM_OVMF_VARS_TEMPLATE=${AX20_OVMF_VARS:-}
    if [ -n "$VM_OVMF_CODE" ]; then
        [ -n "$VM_OVMF_VARS_TEMPLATE" ] || vm_die "AX20_OVMF_CODE set without AX20_OVMF_VARS"
        return 0
    fi
    local pair code vars
    for pair in \
        /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /usr/share/edk2-ovmf/x64/OVMF_CODE.fd:/usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
        /opt/homebrew/share/qemu/edk2-x86_64-code.fd:/opt/homebrew/share/qemu/edk2-i386-vars.fd \
        /usr/local/share/qemu/edk2-x86_64-code.fd:/usr/local/share/qemu/edk2-i386-vars.fd; do
        code=${pair%%:*}
        vars=${pair#*:}
        if [ -f "$code" ] && [ -f "$vars" ]; then
            VM_OVMF_CODE=$code
            VM_OVMF_VARS_TEMPLATE=$vars
            return 0
        fi
    done
    return 0
}

# vm_resolve_paths : compute every file the command line references.
vm_resolve_paths() {
    [ -n "$VM_DISK" ] || VM_DISK="$VM_DIR/disks/steamos.qcow2"
    VM_BASE_VARS="${VM_DISK%.qcow2}.vars.fd"
    if [ "$VM_MODE" = snapshot ]; then
        VM_BOOT_DISK="$VM_DIR/snapshots/$VM_SNAPSHOT.qcow2"
        VM_BOOT_VARS="$VM_DIR/snapshots/$VM_SNAPSHOT.vars.fd"
    else
        VM_BOOT_DISK=$VM_DISK
        VM_BOOT_VARS=$VM_BASE_VARS
    fi
    if [ "$VM_MODE" = install ] && [ -z "$VM_RECOVERY" ]; then
        local f
        # shellcheck disable=SC2012  # newest-first by mtime; names are ours
        f=$(ls -t "$VM_DIR"/cache/*.img 2>/dev/null | head -n 1 || true)
        VM_RECOVERY=${f:-$VM_DIR/cache/steamos-recovery.img}
    fi
    if [ "$VM_NO_ACPITABLE" = 1 ]; then
        VM_ACPITABLE=
    elif [ "$VM_ACPITABLE_SET" = 0 ] && [ -f "$VM_REPO_ROOT/acpi/fixtures/x20-dsdt.aml" ]; then
        VM_ACPITABLE="$VM_REPO_ROOT/acpi/fixtures/x20-dsdt.aml"
    fi
    VM_RUN_DIR="$VM_DIR/run"
    VM_LOG_DIR="$VM_DIR/logs"
}

# ---------------------------------------------------------------------------
# EDID
# ---------------------------------------------------------------------------

# vm_edid_preferred_mode <file> : print WxH of the first detailed timing
# descriptor (bytes 54-71 of the base block). Fails if there is none, which
# happens for panels that only describe timings in a DisplayID extension.
vm_edid_preferred_mode() {
    local f=$1 bytes
    # shellcheck disable=SC2207  # od output is a plain list of numbers
    bytes=($(od -An -v -tu1 -j 0 -N 72 "$f" 2>/dev/null))
    [ "${#bytes[@]}" -ge 72 ] || return 1
    # header 00 ff ff ff ff ff ff 00
    [ "${bytes[0]}" = 0 ] && [ "${bytes[1]}" = 255 ] && [ "${bytes[7]}" = 0 ] || return 1
    local clk=$((bytes[54] + bytes[55] * 256))
    [ "$clk" -gt 0 ] || return 1
    local h=$((bytes[56] + (bytes[58] >> 4) * 256))
    local v=$((bytes[59] + (bytes[61] >> 4) * 256))
    [ "$h" -gt 0 ] && [ "$v" -gt 0 ] || return 1
    printf '%sx%s\n' "$h" "$v"
}

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

vm_smbios_escape() {
    # QEMU option values escape a literal comma as ",,".
    printf '%s' "${1//,/,,}"
}

vm_add() { VM_CMD+=("$@"); }

# vm_build_cmd : fill VM_CMD. Pure: reads VM_* only, touches no files.
vm_build_cmd() {
    VM_CMD=("$VM_QEMU" -name ally-x20-steamos -machine q35)
    case "$VM_ACCEL_RESOLVED" in
        kvm | hvf) vm_add -accel "$VM_ACCEL_RESOLVED" -cpu host ;;
        tcg) vm_add -accel tcg,thread=multi -cpu max ;;
    esac
    vm_add -smp "$VM_CPUS" -m "$VM_MEM"

    # UEFI firmware: read-only code + a writable per-disk copy of the vars
    # (SteamOS writes its boot entries there).
    vm_add -drive "if=pflash,format=raw,readonly=on,file=${VM_OVMF_CODE:-OVMF_CODE.fd}"
    vm_add -drive "if=pflash,format=raw,file=$VM_BOOT_VARS"

    vm_add -device virtio-rng-pci
    vm_add -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0

    # Disks. The SteamOS installer expects an NVMe target (it hard-codes
    # nvme0n1 in repair_device.sh), so the system disk is NVMe by default.
    local sysdev=nvme
    [ "$VM_DISK_BUS" = virtio ] && sysdev=virtio-blk-pci
    local sysdev_args="drive=sysdisk,bootindex=1"
    [ "$sysdev" = nvme ] && sysdev_args="$sysdev_args,serial=AX20VMDISK"
    if [ "$VM_MODE" = install ]; then
        # snapshot=on keeps the downloaded recovery image pristine.
        vm_add -drive "if=none,id=recovery,format=raw,snapshot=on,file=$VM_RECOVERY"
        vm_add -device virtio-blk-pci,drive=recovery,bootindex=0
    fi
    vm_add -drive "if=none,id=sysdisk,format=qcow2,discard=unmap,file=$VM_BOOT_DISK"
    vm_add -device "$sysdev,$sysdev_args"

    # Network: user mode with ssh forwarded to localhost only.
    local net="user,id=net0,hostfwd=tcp:127.0.0.1:$VM_SSH_PORT-:22"
    [ "$VM_OFFLINE" = 1 ] && net="$net,restrict=on"
    vm_add -netdev "$net" -device virtio-net-pci,netdev=net0

    # Display.
    local gpu display os
    os=$(vm_host_os)
    if [ "$VM_HEADLESS" = 1 ]; then
        gpu=virtio-vga
        display=none
    elif [ "$os" = Darwin ]; then
        gpu=virtio-vga
        display=cocoa
    else
        gpu=virtio-vga-gl
        display=gtk,gl=on
    fi
    [ -n "$VM_DISPLAY" ] && display=$VM_DISPLAY
    if [ -n "$VM_EDID" ] || [ -n "$VM_EDID_MODE" ]; then
        local mode=$VM_EDID_MODE
        if [ -z "$mode" ]; then
            mode=$(vm_edid_preferred_mode "$VM_EDID") \
                || vm_die "no detailed timing in the EDID base block; pass --edid-mode WxH"
        fi
        gpu="$gpu,edid=on,xres=${mode%x*},yres=${mode#*x}"
    fi
    vm_add -device "$gpu" -display "$display"
    if [ -n "$VM_EDID" ]; then
        # The raw blob is readable in the guest at
        # /sys/firmware/qemu_fw_cfg/by_name/opt/ally-x20-steamos/edid/raw
        # (qemu_fw_cfg module) for drm.edid_firmware= experiments.
        vm_add -fw_cfg "name=opt/ally-x20-steamos/edid,file=$VM_EDID"
    fi

    # DMI strings so InputPlumber / hwdb / kernel DMI quirks match as on hardware.
    if [ "$VM_SMBIOS" = 1 ]; then
        vm_add -smbios "type=1,manufacturer=$(vm_smbios_escape "$VM_SMBIOS_VENDOR"),product=$(vm_smbios_escape "$VM_SMBIOS_PRODUCT"),version=$(vm_smbios_escape "$VM_SMBIOS_VERSION")"
        vm_add -smbios "type=2,manufacturer=$(vm_smbios_escape "$VM_SMBIOS_BOARD_VENDOR"),product=$(vm_smbios_escape "$VM_SMBIOS_BOARD")"
    fi

    if [ -n "$VM_ACPITABLE" ]; then
        vm_add -acpitable "file=$VM_ACPITABLE"
    fi

    local u
    for u in $VM_USB; do
        vm_add -device "usb-host,bus=xhci.0,vendorid=0x${u%%:*},productid=0x${u#*:}"
    done

    if [ "$VM_TPM" = 1 ]; then
        vm_add -chardev "socket,id=chrtpm,path=$VM_RUN_DIR/swtpm.sock"
        vm_add -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0
    fi

    vm_add -monitor "unix:$VM_RUN_DIR/monitor.sock,server=on,wait=off"
    vm_add -serial "file:$VM_LOG_DIR/serial.log"
    vm_add -pidfile "$VM_RUN_DIR/qemu.pid"
}

vm_print() {
    local a
    if [ "$VM_PRINT" = args ]; then
        for a in "${VM_CMD[@]}"; do printf '%s\n' "$a"; done
    else
        local first=1
        for a in "${VM_CMD[@]}"; do
            [ "$first" = 1 ] || printf ' '
            first=0
            printf '%q' "$a"
        done
        printf '\n'
    fi
}

# ---------------------------------------------------------------------------
# Side effects (never reached with --print-*)
# ---------------------------------------------------------------------------

vm_need() { command -v "$1" >/dev/null 2>&1 || vm_die "$1 not found (run vm/setup-fedora-host.sh)"; }

vm_list_snapshots() {
    local f
    for f in "$VM_DIR"/snapshots/*.qcow2; do
        [ -f "$f" ] || continue
        printf '%s\n' "$(basename "$f" .qcow2)"
    done
}

vm_prepare() {
    vm_need "$VM_QEMU"
    [ -n "$VM_OVMF_CODE" ] || vm_die "OVMF firmware not found; install edk2-ovmf/ovmf or set AX20_OVMF_CODE and AX20_OVMF_VARS"
    mkdir -p "$VM_DIR/disks" "$VM_DIR/snapshots" "$VM_RUN_DIR" "$VM_LOG_DIR"
    if [ -f "$VM_LOG_DIR/serial.log" ]; then
        mv -f "$VM_LOG_DIR/serial.log" "$VM_LOG_DIR/serial.prev.log"
    fi
    case "$VM_MODE" in
        install)
            [ -f "$VM_RECOVERY" ] || vm_die "recovery image not found: $VM_RECOVERY (vm/setup-fedora-host.sh --download)"
            if [ ! -f "$VM_DISK" ]; then
                vm_need "$VM_QEMU_IMG"
                "$VM_QEMU_IMG" create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE" >&2
            fi
            [ -f "$VM_BASE_VARS" ] || cp "$VM_OVMF_VARS_TEMPLATE" "$VM_BASE_VARS"
            ;;
        run)
            [ -f "$VM_DISK" ] || vm_die "no installed disk at $VM_DISK (run --install first)"
            [ -f "$VM_BASE_VARS" ] || cp "$VM_OVMF_VARS_TEMPLATE" "$VM_BASE_VARS"
            ;;
        snapshot)
            [ -f "$VM_DISK" ] || vm_die "no base disk at $VM_DISK (run --install first)"
            if [ "$VM_RESTORE" = 1 ]; then
                rm -f "$VM_BOOT_DISK" "$VM_BOOT_VARS"
                vm_log "restoring snapshot '$VM_SNAPSHOT' to the clean base"
            fi
            if [ ! -f "$VM_BOOT_DISK" ]; then
                vm_need "$VM_QEMU_IMG"
                "$VM_QEMU_IMG" create -f qcow2 -b "$VM_DISK" -F qcow2 "$VM_BOOT_DISK" >&2
            fi
            if [ ! -f "$VM_BOOT_VARS" ]; then
                if [ -f "$VM_BASE_VARS" ]; then
                    cp "$VM_BASE_VARS" "$VM_BOOT_VARS"
                else
                    cp "$VM_OVMF_VARS_TEMPLATE" "$VM_BOOT_VARS"
                fi
            fi
            ;;
    esac
    if [ "$VM_TPM" = 1 ]; then
        vm_need swtpm
        mkdir -p "$VM_DIR/tpm"
        swtpm socket --tpm2 --tpmstate "dir=$VM_DIR/tpm" \
            --ctrl "type=unixio,path=$VM_RUN_DIR/swtpm.sock" --daemon
    fi
    printf 'AX20_VM_ACCEL=%s\nAX20_VM_SLOW=%s\n' "$AX20_VM_ACCEL" "$AX20_VM_SLOW" >"$VM_DIR/accel.env"
}

vm_main() {
    vm_defaults
    vm_parse_args "$@"
    vm_validate
    vm_resolve_paths
    if [ "$VM_LIST" = 1 ]; then
        vm_list_snapshots
        return 0
    fi
    vm_resolve_accel
    vm_find_ovmf
    if [ -z "$VM_OVMF_CODE" ] && [ -n "$VM_PRINT" ]; then
        vm_warn "OVMF firmware not found; printing placeholders"
    fi
    vm_build_cmd
    if [ -n "$VM_PRINT" ]; then
        vm_print
        return 0
    fi
    vm_prepare
    vm_log "mode: $VM_MODE  disk: $VM_BOOT_DISK"
    vm_log "ssh:  ssh -p $VM_SSH_PORT deck@127.0.0.1   monitor: $VM_RUN_DIR/monitor.sock"
    exec "${VM_CMD[@]}"
}

# Allow tests to source the file for its functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    vm_main "$@"
fi
