#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/ci/make-base-image.sh — produce, once and by hand, the installed SteamOS
# base image that .github/workflows/vm-tests.yml boots. The recovery installer
# is a graphical, click-through flow, so this cannot be fully automated.
#
# Usage: vm/ci/make-base-image.sh <step> [--vm-dir DIR] [--out DIR] [--port N]
#   keygen     create the CI ssh key pair in <out> (ci_ed25519, ci_ed25519.pub)
#   install    boot the recovery image (vm/run-steamos-vm.sh --install) on a
#              fresh disk <vm-dir>/disks/steamos-base.qcow2; follow the prompts
#   prepare    over ssh (password login), authorise the CI key, allow
#              passwordless sudo for the CI user, opt into the beta branch
#              and run steamos-update; reboot the VM afterwards
#   package    compress disk + OVMF vars, split into <2 GiB release parts,
#              write SHA256SUMS and print the gh commands to publish them
#
# Defaults: --vm-dir ~/vms/ally-x20-steamos, --out <vm-dir>/ci-out, --port 2222.
# The full procedure is in docs/vm-testing.md ("Producing the CI base image").
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
VM_DIR=${AX20_VM_DIR:-${HOME:-/tmp}/vms/ally-x20-steamos}
OUT=
PORT=2222
PART_SIZE=1900M

die() {
    printf 'make-base-image: error: %s\n' "$*" >&2
    exit 2
}
say() { printf '%s\n' "$*"; }

step=${1:-}
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --vm-dir)
            VM_DIR=$2
            shift
            ;;
        --out)
            OUT=$2
            shift
            ;;
        --port)
            PORT=$2
            shift
            ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done
[ -n "$OUT" ] || OUT="$VM_DIR/ci-out"
DISK="$VM_DIR/disks/steamos-base.qcow2"
VARS="$VM_DIR/disks/steamos-base.vars.fd"

case "$step" in
    keygen)
        mkdir -p "$OUT"
        [ -f "$OUT/ci_ed25519" ] || ssh-keygen -t ed25519 -N '' -C ally-x20-steamos-ci -f "$OUT/ci_ed25519"
        say "public key: $OUT/ci_ed25519.pub"
        say "store the private key as the repository secret AX20_VM_SSH_KEY:"
        say "  gh secret set AX20_VM_SSH_KEY < $OUT/ci_ed25519"
        ;;
    install)
        [ ! -f "$DISK" ] || die "$DISK exists; remove it to start over"
        cat <<EOF
In the recovery desktop that opens:
  1. Run "Re-image Steam Deck" (wipe + install) and confirm. It targets the
     NVMe disk; the recovery image itself is attached read-only.
  2. When it asks to reboot, power the VM off instead.
Then:  vm/run-steamos-vm.sh --run --disk $DISK
  3. Finish first-boot setup, switch to Desktop Mode, open Konsole:
       passwd                          # set a password for deck
       sudo systemctl enable --now sshd
  4. Back on the host:  $0 prepare
EOF
        exec "$ROOT/vm/run-steamos-vm.sh" --install --disk "$DISK"
        ;;
    prepare)
        pub="$OUT/ci_ed25519.pub"
        [ -f "$pub" ] || die "no $pub; run '$0 keygen' first"
        say "logging in as deck on port $PORT (type the deck password when asked)"
        # shellcheck disable=SC2087  # expand the key locally on purpose
        ssh -t -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null deck@127.0.0.1 "
            set -e
            mkdir -p ~/.ssh && chmod 700 ~/.ssh
            grep -qxF '$(cat "$pub")' ~/.ssh/authorized_keys 2>/dev/null || echo '$(cat "$pub")' >> ~/.ssh/authorized_keys
            chmod 600 ~/.ssh/authorized_keys
            echo 'deck ALL=(ALL) NOPASSWD: ALL' | sudo sh -c 'umask 337; cat > /etc/sudoers.d/zz-ally-x20-steamos-ci'
            sudo systemctl enable sshd
            sudo steamos-select-branch beta
            sudo steamos-update check || true
            sudo steamos-update || true
            echo 'prepared; reboot the VM (sudo reboot), verify, then power it off'
        "
        ;;
    package)
        [ -f "$DISK" ] || die "no base disk at $DISK"
        [ -f "$VARS" ] || die "no OVMF vars at $VARS"
        command -v qemu-img >/dev/null || die "qemu-img not found"
        command -v zstd >/dev/null || die "zstd not found"
        mkdir -p "$OUT/pkg"
        rm -f "$OUT/pkg/"*
        say "compacting disk (qemu-img convert, drops unused clusters)"
        qemu-img convert -p -O qcow2 "$DISK" "$OUT/pkg/steamos-base.qcow2"
        cp "$VARS" "$OUT/pkg/steamos-base.vars.fd"
        say "compressing + splitting into $PART_SIZE parts"
        tar -C "$OUT/pkg" -cf - steamos-base.qcow2 steamos-base.vars.fd \
            | zstd -T0 -10 \
            | split -b "$PART_SIZE" - "$OUT/pkg/steamos-base.tar.zst.part-"
        rm -f "$OUT/pkg/steamos-base.qcow2" "$OUT/pkg/steamos-base.vars.fd"
        (cd "$OUT/pkg" && if command -v sha256sum >/dev/null; then sha256sum steamos-base.tar.zst.part-*; else shasum -a 256 steamos-base.tar.zst.part-*; fi >SHA256SUMS)
        tag="vm-base-$(date -u +%Y%m%d)"
        cat <<EOF

Parts in $OUT/pkg. To publish (pre-release, so it never shows as "latest"):
  gh release create $tag --prerelease --title "SteamOS VM base image $tag" \\
      --notes "Installed SteamOS base disk for vm-tests.yml; see docs/vm-testing.md" \\
      $OUT/pkg/*
Then set AX20_VM_BASE_TAG=$tag in vm/ci/base-image.conf (PR) or pass it as
the base_tag input of a manual vm-tests run.
EOF
        ;;
    -h | --help | '') sed -n '3,/^set -eu/p' "$0" | sed -e '/^set -eu/d' -e 's/^# \{0,1\}//' ;;
    *) die "unknown step: $step" ;;
esac
