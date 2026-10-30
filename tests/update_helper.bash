# SPDX-License-Identifier: GPL-2.0-only
# Fixture builders for the update-survival suites (slots, rauc, apply, policy).
# Load after test_helper:  load '../test_helper'; load '../update_helper'

# fixture_partsets <active A|B> : /dev/disk/by-partsets symlinks like udev makes.
fixture_partsets() {
    local active=$1 other d p n
    [ "$active" = A ] && other=B || other=A
    d="$AX20_ROOT/dev/disk/by-partsets"
    mkdir -p "$d/A" "$d/B" "$d/self" "$d/other" "$d/shared"
    for p in efi rootfs var; do
        case "$p" in efi) n=2 ;; rootfs) n=4 ;; var) n=6 ;; esac
        ln -sfn "../../../nvme0n1p$n" "$d/A/$p"
        ln -sfn "../../../nvme0n1p$((n + 1))" "$d/B/$p"
        ln -sfn "$(readlink "$d/$active/$p")" "$d/self/$p"
        ln -sfn "$(readlink "$d/$other/$p")" "$d/other/$p"
    done
    ln -sfn ../../../nvme0n1p1 "$d/shared/esp"
}

# fixture_grub [path] : a stage-2 grub.cfg shaped like SteamOS's.
fixture_grub() {
    local p="$AX20_ROOT${1:-/efi/EFI/steamos/grub.cfg}"
    mkdir -p "$(dirname "$p")"
    printf '%s\n' \
        'set timeout=0' \
        'menuentry "SteamOS" {' \
        '	search --no-floppy --fs-uuid --set=root 293b8cff-e33d-4aad-9385-d4be2891df75' \
        '	steamenv_boot	linux /boot/vmlinuz-linux-neptune console=tty1 rd.luks=0 quiet splash amd_iommu=off' \
        '	initrd	/boot/amd-ucode.img /boot/initramfs-linux-neptune.img' \
        '}' >"$p"
}

# fixture_bls <path> : a systemd-boot (BLS) entry.
fixture_bls() {
    local p="$AX20_ROOT$1"
    mkdir -p "$(dirname "$p")"
    printf '%s\n' \
        'title SteamOS' \
        'linux /steamos/vmlinuz-linux-neptune' \
        'initrd /steamos/initramfs-linux-neptune.img' \
        'options root=PARTUUID=1234 quiet splash' >"$p"
}

# fixture_initrd [path] : a minimal newc cpio header (enough for validation).
fixture_initrd() {
    local p="$AX20_ROOT${1:-/efi/EFI/steamos/ally-x20-steamos-acpi.img}"
    mkdir -p "$(dirname "$p")"
    printf '070701%s' "00000000000000000000000000000000000000000000000000000000" >"$p"
}

# fixture_rauc_conf [with-handlers:1|0] : SteamOS-like /etc/rauc/system.conf.
fixture_rauc_conf() {
    local p="$AX20_ROOT/etc/rauc/system.conf"
    mkdir -p "$(dirname "$p")"
    {
        printf '%s\n' '[system]' 'compatible=steamos-amd64' 'bootloader=custom' 'mountprefix=/run/rauc' ''
        if [ "${1:-1}" = 1 ]; then
            printf '%s\n' '[handlers]' 'bootloader-custom-backend=/usr/lib/rauc/bootloader-custom-backend.sh' \
                'post-install=/usr/lib/rauc/post-install.sh' ''
        fi
        printf '%s\n' '[slot.rootfs.0]' 'device=/dev/disk/by-partsets/A/rootfs' 'type=raw' 'bootname=A'
    } >"$p"
}

# fake_src [cmd-to-omit...] : a copy of the checkout layout under
# $BATS_TEST_TMPDIR/src with the given cmd/*.sh files left out (so tests do
# not depend on self-update/rebuild from other packages). Sets FAKE_CLI.
fake_src() {
    local s="$BATS_TEST_TMPDIR/src" f n skip o
    mkdir -p "$s/cmd"
    cp "$REPO_ROOT/ally-x20-steamos.sh" "$s/"
    cp "$REPO_ROOT/VERSION" "$s/"
    ln -sfn "$REPO_ROOT/lib" "$s/lib"
    ln -sfn "$REPO_ROOT/overlay" "$s/overlay"
    ln -sfn "${AX20_COMPONENTS_DIR:-$REPO_ROOT/components}" "$s/components"
    for f in "$REPO_ROOT"/cmd/*.sh; do
        n=$(basename "$f" .sh)
        skip=0
        for o in "$@"; do [ "$o" = "$n" ] && skip=1; done
        [ "$skip" = 1 ] || ln -sfn "$f" "$s/cmd/$n.sh"
    done
    FAKE_CLI="$s/ally-x20-steamos.sh"
    export FAKE_CLI
}

# tree_digest <dir> : one digest over every path + content under dir.
tree_digest() {
    (cd "$1" && find . \( -type f -o -type l -o -type d \) -print | LC_ALL=C sort | while IFS= read -r p; do
        if [ -L "$p" ]; then
            printf '%s -> %s\n' "$p" "$(readlink "$p")"
        elif [ -f "$p" ]; then
            printf '%s %s\n' "$p" "$(cksum <"$p")"
        else
            printf '%s/\n' "$p"
        fi
    done) | cksum
}
