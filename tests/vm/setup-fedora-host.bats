#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# vm/setup-fedora-host.sh in --dry-run with stubbed rpm/getent/id/podman.
load '../test_helper'

SETUP="$REPO_ROOT/vm/setup-fedora-host.sh"

setup() {
    bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    printf 'ID=fedora\nVERSION_ID=43\n' >"$BATS_TEST_TMPDIR/os-release"
    export AX20_OS_RELEASE="$BATS_TEST_TMPDIR/os-release"
    export AX20_VM_DIR="$BATS_TEST_TMPDIR/vms"
    export AX20_VM_KVM_DEV="$BATS_TEST_TMPDIR/kvm"
    : >"$AX20_VM_KVM_DEV"
    chmod 666 "$AX20_VM_KVM_DEV"
    # rpm: packages listed in $RPM_HAVE are installed
    cat >"$bin/rpm" <<'S'
#!/bin/sh
case " $RPM_HAVE " in *" $2 "*) exit 0 ;; esac
exit 1
S
    cat >"$bin/getent" <<'S'
#!/bin/sh
exit 0
S
    cat >"$bin/id" <<'S'
#!/bin/sh
case "$1" in
    -u) echo 1000 ;;
    -un) echo tester ;;
    -nG) echo "tester $ID_GROUPS" ;;
esac
S
    cat >"$bin/podman" <<'S'
#!/bin/sh
echo true
S
    chmod +x "$bin"/*
    export PATH="$bin:$PATH"
}

@test "dry-run installs only missing packages and adds missing groups" {
    RPM_HAVE="qemu-kvm podman" ID_GROUPS="kvm" run "$SETUP" --dry-run
    assert_success
    assert_output_contains "+ sudo dnf install -y qemu-img edk2-ovmf"
    case "$output" in *"dnf install -y qemu-kvm"* | *" podman "*"dnf"*) false ;; esac
    assert_output_contains "+ sudo usermod -aG libvirt tester"
    case "$output" in *"usermod -aG kvm"*) false ;; esac
    assert_output_contains "+ mkdir -p $AX20_VM_DIR/cache"
    assert_output_contains "Log out and back in"
    [ ! -e "$AX20_VM_DIR" ]
}

@test "second run with everything present changes nothing" {
    all=$(sed -n 's/^SETUP_PACKAGES="\(.*\)"$/\1/p' "$SETUP")
    mkdir -p "$AX20_VM_DIR"/cache "$AX20_VM_DIR"/disks "$AX20_VM_DIR"/snapshots "$AX20_VM_DIR"/logs "$AX20_VM_DIR"/run
    RPM_HAVE="$all" ID_GROUPS="kvm libvirt" run "$SETUP" --dry-run
    assert_success
    assert_output_contains "packages: all present"
    assert_output_contains "kvm: $AX20_VM_KVM_DEV is usable by tester"
    case "$output" in *"+ "*) false ;; esac
}

@test "refuses non-Fedora without --force" {
    printf 'ID=ubuntu\n' >"$AX20_OS_RELEASE"
    run "$SETUP" --dry-run --skip-packages
    assert_failure 2
    run "$SETUP" --dry-run --skip-packages --force
    assert_success
}

@test "known digest for recovery-4 is recorded" {
    run grep -E 'steamdeck-recovery-4.img.bz2\) echo "[0-9a-f]{64}"' "$SETUP"
    assert_success
}

@test "bad --image is rejected" {
    run "$SETUP" --image nope
    assert_failure 2
}
