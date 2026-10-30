#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/ci/vm-ci.sh — steps of the VM test job, shared by
# .github/workflows/vm-tests.yml and manual runs on the Fedora box.
#
# Usage: vm/ci/vm-ci.sh <step> [args]
#   fetch <tag> <vm-dir>     download the base image release assets with gh,
#                            verify SHA256SUMS, unpack into <vm-dir>/disks
#   boot <vm-dir>            start overlay "ci" (fresh from the base) headless
#                            in the background; QEMU output in <vm-dir>/logs
#   wait-ssh [seconds]       wait until the guest answers ssh (default 900)
#   ssh <command...>         run a command in the guest
#   push-repo <dir>          copy a checkout to ~/ally-x20-steamos in the guest
#   roundtrip <out-dir>      run vm/guest/roundtrip-test.sh, fetch its logs;
#                            exit 77 when the CLI cannot install yet
#   collect <out-dir>        run collect-hardware-data.sh, fetch the tarball
#   shutdown <vm-dir>        ACPI power-off via the monitor, then kill after 60s
#
# Environment: AX20_VM_SSH_KEY_FILE (default ~/.ssh/ax20_vm), AX20_VM_SSH_PORT
# (2222), AX20_VM_USER (deck), AX20_VM_ACCEL (kvm).
set -eu

CI_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$CI_DIR/../.." && pwd)
PORT=${AX20_VM_SSH_PORT:-2222}
GUSER=${AX20_VM_USER:-deck}
KEY=${AX20_VM_SSH_KEY_FILE:-${HOME:-/root}/.ssh/ax20_vm}
GREPO="ally-x20-steamos"

die() {
    printf 'vm-ci: error: %s\n' "$*" >&2
    exit 2
}
log() { printf 'vm-ci: %s\n' "$*" >&2; }

sha256_check() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c "$1"
    else
        shasum -a 256 -c "$1"
    fi
}

gssh() {
    ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
        "$GUSER@127.0.0.1" "$@"
}

# gfetch <remote-path> <local-dir> : copy a guest file/dir out via tar.
gfetch() {
    mkdir -p "$2"
    gssh "tar -C \"\$(dirname '$1')\" -cf - \"\$(basename '$1')\"" | tar -C "$2" -xf -
}

step=${1:-}
[ $# -gt 0 ] && shift
case "$step" in
    fetch)
        [ $# -eq 2 ] || die "fetch <tag> <vm-dir>"
        tag=$1 vmdir=$2
        dl="$vmdir/download"
        mkdir -p "$dl" "$vmdir/disks"
        gh release download "$tag" --dir "$dl" --clobber
        (cd "$dl" && sha256_check SHA256SUMS)
        # shellcheck disable=SC2012  # part names are ours: steamos-base.tar.zst.part-aa...
        ls "$dl"/steamos-base.tar.zst.part-* | sort | xargs cat | zstd -dc | tar -C "$vmdir/disks" -xf -
        rm -rf "$dl"
        ls -l "$vmdir/disks"
        ;;
    boot)
        [ $# -eq 1 ] || die "boot <vm-dir>"
        vmdir=$1
        mkdir -p "$vmdir/logs"
        "$REPO/vm/run-steamos-vm.sh" --vm-dir "$vmdir" --disk "$vmdir/disks/steamos-base.qcow2" \
            --restore ci --headless --accel "${AX20_VM_ACCEL:-kvm}" --ssh-port "$PORT" \
            >"$vmdir/logs/qemu.log" 2>&1 &
        log "qemu started (pid $!), log: $vmdir/logs/qemu.log"
        ;;
    wait-ssh)
        limit=${1:-900}
        start=$(date +%s)
        until gssh true 2>/dev/null; do
            [ $(($(date +%s) - start)) -lt "$limit" ] || die "no ssh after ${limit}s"
            sleep 5
        done
        log "ssh up after $(($(date +%s) - start))s"
        ;;
    ssh) gssh "$@" ;;
    push-repo)
        [ $# -eq 1 ] || die "push-repo <dir>"
        gssh "rm -rf ~/$GREPO && mkdir -p ~/$GREPO"
        tar -C "$1" --exclude=./worktrees --exclude=./.git -cf - . | gssh "tar -C ~/$GREPO -xf -"
        ;;
    roundtrip)
        [ $# -eq 1 ] || die "roundtrip <out-dir>"
        rc=0
        gssh "cd ~/$GREPO && sudo -n ./vm/guest/roundtrip-test.sh --repo ~/$GREPO --out ~/ax20-ci/roundtrip" || rc=$?
        gfetch "ax20-ci/roundtrip" "$1" 2>/dev/null || log "no roundtrip logs to fetch"
        exit "$rc"
        ;;
    collect)
        [ $# -eq 1 ] || die "collect <out-dir>"
        mkdir -p "$1"
        t=$(gssh "cd && ./$GREPO/vm/guest/collect-hardware-data.sh --out ax20-ci" | tail -n 1)
        gssh "cat '$t'" >"$1/$(basename "$t")"
        ;;
    shutdown)
        [ $# -eq 1 ] || die "shutdown <vm-dir>"
        vmdir=$1
        sock="$vmdir/run/monitor.sock"
        pidf="$vmdir/run/qemu.pid"
        if [ -S "$sock" ]; then
            python3 - "$sock" <<'PY' || true
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(b"system_powerdown\n")
s.close()
PY
        fi
        if [ -f "$pidf" ]; then
            pid=$(cat "$pidf")
            i=0
            while kill -0 "$pid" 2>/dev/null && [ $i -lt 60 ]; do
                sleep 1
                i=$((i + 1))
            done
            kill "$pid" 2>/dev/null || true
        fi
        ;;
    -h | --help | '') sed -n '3,/^set -eu/p' "$0" | sed -e '/^set -eu/d' -e 's/^# \{0,1\}//' ;;
    *) die "unknown step: $step" ;;
esac
