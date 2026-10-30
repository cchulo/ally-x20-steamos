#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# vm/setup-fedora-host.sh — one-shot, idempotent setup of a Fedora x86-64 box
# as the KVM/podman host for ally-x20-steamos VM tests (plan §6.0).
#
# Usage: vm/setup-fedora-host.sh [options]
#   --download            also download + verify a SteamOS recovery image
#   --image <name>        latest (default: steamdeck-repair-latest, follows Valve's
#                         redirect) or recovery-4 (steamdeck-recovery-4.img.bz2, 2022)
#   --sha256 <hex>        expected sha256 of the downloaded archive (overrides
#                         the known values below)
#   --vm-dir <dir>        VM state dir (default ~/vms/ally-x20-steamos)
#   --skip-packages       do not run dnf
#   --force               continue on a non-Fedora host
#   --dry-run             print the changes instead of making them
#   -h, --help            this help
#
# Run it as your normal user; it calls sudo for dnf and usermod only. Safe to
# re-run: every step checks first and only acts on what is missing.
set -eu

SETUP_PACKAGES="qemu-kvm qemu-img edk2-ovmf virt-install libvirt podman git ShellCheck shfmt bats python3-pytest acpica-tools swtpm jq bzip2 unzip zstd curl openssh-clients"
# ShellCheck is the Fedora package name (capitalised); shfmt/jq/zstd are
# needed by `make check` and vm/ci/make-base-image.sh on top of the plan's list.

RECOVERY_BASE=https://steamdeck-images.steamos.cloud/recovery

# Known sha256 values of Valve's archives. Valve publishes no checksum file
# next to the images (checked 2026-10-30), so these were computed by us from a
# full download; see vm/README.md. A file not listed here is verified
# trust-on-first-use: its digest is recorded next to it and checked on
# every later run.
setup_known_sha256() {
    case "$1" in
        steamdeck-recovery-4.img.bz2) echo "ac9c58fdd319d46120444875172eb56382098634f2075729f51426ba5cb788c6" ;;
        steamdeck-oobe-repair-20260707.10-3.8.14.img.zip) echo "d54fbf0ad400d9c2a04501aaae68231e08ed5dadba8774348eca82c554eea494" ;;
        *) echo "" ;;
    esac
}

say() { printf '%s\n' "$*"; }
warn() { printf 'setup: WARNING: %s\n' "$*" >&2; }
die() {
    printf 'setup: error: %s\n' "$*" >&2
    exit 2
}

DRY_RUN=0
# run <cmd...> : execute, or print under --dry-run.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

usage() { sed -n '3,/^set -eu/p' "$0" | sed -e '/^set -eu/d' -e 's/^# \{0,1\}//'; }

DOWNLOAD=0
IMAGE=latest
WANT_SHA=
VM_DIR=${AX20_VM_DIR:-${HOME:-/tmp}/vms/ally-x20-steamos}
SKIP_PKGS=0
FORCE=0
NEED_RELOGIN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --download) DOWNLOAD=1 ;;
        --image)
            [ $# -ge 2 ] || die "--image needs a value"
            IMAGE=$2
            shift
            ;;
        --sha256)
            [ $# -ge 2 ] || die "--sha256 needs a value"
            WANT_SHA=$2
            shift
            ;;
        --vm-dir)
            [ $# -ge 2 ] || die "--vm-dir needs a value"
            VM_DIR=$2
            shift
            ;;
        --skip-packages) SKIP_PKGS=1 ;;
        --force) FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done
case "$IMAGE" in latest | recovery-4) ;; *) die "--image must be latest or recovery-4" ;; esac

[ "$(id -u)" != 0 ] || die "run as your normal user (the script uses sudo where needed)"
USER_NAME=$(id -un)

step_os() {
    local osr=${AX20_OS_RELEASE:-/etc/os-release} id=
    [ -f "$osr" ] && id=$(sed -n 's/^ID=//p' "$osr" | tr -d '"')
    if [ "$id" != fedora ]; then
        [ "$FORCE" = 1 ] || die "this is not Fedora (ID=${id:-unknown}); use --force to continue anyway"
        warn "not Fedora (ID=${id:-unknown}); continuing because of --force"
    fi
    case "$(uname -m)" in
        x86_64) ;;
        *) warn "host is $(uname -m): SteamOS needs x86-64, the VM will run under slow TCG" ;;
    esac
}

step_packages() {
    [ "$SKIP_PKGS" = 0 ] || {
        say "packages: skipped (--skip-packages)"
        return 0
    }
    local missing="" p
    for p in $SETUP_PACKAGES; do
        rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
    done
    if [ -z "$missing" ]; then
        say "packages: all present"
        return 0
    fi
    say "packages: installing$missing"
    # shellcheck disable=SC2086  # word splitting of the package list is intended
    run sudo dnf install -y $missing
}

step_groups() {
    local g
    for g in kvm libvirt; do
        if ! getent group "$g" >/dev/null 2>&1; then
            warn "group $g does not exist yet (package not installed?)"
            continue
        fi
        if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx "$g"; then
            say "groups: $USER_NAME already in $g"
        else
            run sudo usermod -aG "$g" "$USER_NAME"
            NEED_RELOGIN=1
        fi
    done
}

step_kvm() {
    local dev=${AX20_VM_KVM_DEV:-/dev/kvm}
    if [ ! -e "$dev" ]; then
        warn "$dev missing: enable VT-x/AMD-V (SVM) in the firmware setup and check 'lsmod | grep kvm'"
        return 0
    fi
    if [ -r "$dev" ] && [ -w "$dev" ]; then
        say "kvm: $dev is usable by $USER_NAME"
    elif [ "$NEED_RELOGIN" = 1 ]; then
        say "kvm: $dev present; usable after you log out and back in (new kvm group membership)"
    else
        warn "$dev present but not read/writable by $USER_NAME; check 'ls -l $dev' and kvm group membership"
    fi
}

step_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        warn "podman not installed"
        return 0
    fi
    local rootless
    if rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null); then
        say "podman: works as $USER_NAME (rootless=$rootless)"
    else
        warn "'podman info' failed as $USER_NAME; run it by hand to see why (subuid/subgid ranges?)"
    fi
}

step_dirs() {
    local d
    for d in cache disks snapshots logs run; do
        [ -d "$VM_DIR/$d" ] || run mkdir -p "$VM_DIR/$d"
    done
    say "vm dir: $VM_DIR"
}

# download_url : print the URL for $IMAGE, following Valve's "latest" redirect.
download_url() {
    case "$IMAGE" in
        recovery-4) echo "$RECOVERY_BASE/steamdeck-recovery-4.img.bz2" ;;
        latest)
            curl -fsSIL -o /dev/null -w '%{url_effective}' "$RECOVERY_BASE/steamdeck-repair-latest.img.zip"
            ;;
    esac
}

step_download() {
    [ "$DOWNLOAD" = 1 ] || return 0
    local url name dest got want img
    url=$(download_url) || die "could not resolve the $IMAGE recovery image URL"
    name=$(basename "$url")
    dest="$VM_DIR/cache/$name"
    say "download: $url"
    if [ "$DRY_RUN" = 1 ]; then
        printf '+ curl -fL -C - -o %s.part %s\n' "$dest" "$url"
        return 0
    fi
    if [ ! -f "$dest" ]; then
        curl -fL -C - -o "$dest.part" "$url"
        mv "$dest.part" "$dest"
    else
        say "download: $name already cached"
    fi
    want=$WANT_SHA
    [ -n "$want" ] || want=$(setup_known_sha256 "$name")
    [ -n "$want" ] || { [ -f "$dest.sha256" ] && want=$(cat "$dest.sha256"); } || true
    got=$(sha256_of "$dest")
    if [ -z "$want" ]; then
        printf '%s\n' "$got" >"$dest.sha256"
        warn "no known checksum for $name; recorded $got (trust on first use). Add it to setup_known_sha256 after checking it against vm/README.md"
    elif [ "$got" != "$want" ]; then
        mv "$dest" "$dest.bad"
        die "sha256 mismatch for $name: expected $want, got $got (moved to $dest.bad)"
    else
        say "download: sha256 OK ($got)"
        printf '%s\n' "$got" >"$dest.sha256"
    fi
    case "$name" in
        *.img.bz2)
            img="$VM_DIR/cache/${name%.bz2}"
            if [ ! -f "$img" ]; then
                say "extract: $img"
                bunzip2 -kc "$dest" >"$img.part"
                mv "$img.part" "$img"
            fi
            ;;
        *.img.zip)
            img="$VM_DIR/cache/${name%.zip}"
            if [ ! -f "$img" ]; then
                say "extract: $img"
                unzip -o -d "$VM_DIR/cache" "$dest"
            fi
            ;;
        *) img=$dest ;;
    esac
    say "recovery image: $img"
}

step_os
step_packages
step_groups
step_kvm
step_podman
step_dirs
step_download

cat <<EOF

Next steps
  $([ "$NEED_RELOGIN" = 1 ] && echo "0. Log out and back in (new kvm/libvirt group membership).")
  1. Recovery image:   vm/setup-fedora-host.sh --download        (if not done)
  2. Install SteamOS:  vm/run-steamos-vm.sh --install
                       (in the recovery desktop: "Re-image Steam Deck" / wipe+install; see vm/README.md)
  3. First boot:       vm/run-steamos-vm.sh --run
                       set the deck password (passwd), sudo systemctl enable --now sshd
  4. Clean snapshot:   vm/run-steamos-vm.sh --restore clean     (fresh overlay over the base disk)
  5. Tests in the VM:  see docs/vm-testing.md
EOF
