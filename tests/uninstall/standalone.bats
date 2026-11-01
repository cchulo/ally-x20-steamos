#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# The self-contained uninstaller against every broken state from plan §5.2 rule 6.
load '../test_helper'

UNINSTALL="$REPO_ROOT/uninstall/uninstall.sh"

setup() {
    make_root >/dev/null
    source_libs
    SRC="$BATS_TEST_TMPDIR/payload"
    printf 'ours\n' >"$SRC"
    STATE="$AX20_ROOT/var/lib/ally-x20-steamos"
}

run_uninstall() {
    run sh "$UNINSTALL" --root "$AX20_ROOT" --yes "$@"
}

install_demo() {
    manifest_install_file "$SRC" /etc/modprobe.d/ally-x20-steamos.conf modules 0644
    manifest_install_file "$SRC" /etc/environment.d/90-ally-x20-steamos-ucm.conf audio 0644
    manifest_install_file "$SRC" /etc/ally-x20-steamos/load-or-fallback modules 0755
    manifest_install_symlink /var/lib/ally-x20-steamos/bin/gamescope /home/deck/.local/bin/ally-x20-steamos-gamescope hdr home
}

@test "full uninstall removes files, symlinks, created dirs and the state dir" {
    install_demo
    [ -f "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos.conf" ]
    run_uninstall
    assert_success
    [ ! -e "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos.conf" ]
    [ ! -e "$AX20_ROOT/etc/environment.d/90-ally-x20-steamos-ucm.conf" ]
    [ ! -L "$AX20_ROOT/home/deck/.local/bin/ally-x20-steamos-gamescope" ]
    [ ! -d "$AX20_ROOT/home/deck/.local/bin" ]  # created by us, now empty
    [ ! -d "$STATE" ]
    [ -d "$AX20_ROOT/etc" ]
}

@test "the system is byte-identical after install + uninstall" {
    mkdir -p "$AX20_ROOT/etc/modprobe.d" "$AX20_ROOT/usr/lib" "$AX20_ROOT/home/deck"
    fixture_file /etc/modprobe.d/stock.conf "stock"
    fixture_file /etc/fstab "fstab"
    fixture_file /usr/lib/libdisplay-info.so.1 "lib"
    rmdir "$STATE" # a clean system has no state dir; install creates it
    before=$(cd "$AX20_ROOT" && find . | sort | xargs -I{} sh -c 'test -f "{}" && sha256sum "{}" || echo "{}"' | sha256sum)
    install_demo
    run_uninstall
    assert_success
    after=$(cd "$AX20_ROOT" && find . | sort | xargs -I{} sh -c 'test -f "{}" && sha256sum "{}" || echo "{}"' | sha256sum)
    [ "$before" = "$after" ]
}

@test "running twice is a no-op" {
    install_demo
    run_uninstall
    assert_success
    run_uninstall
    assert_success
    assert_output_contains "no manifest"
}

@test "dry-run prints actions and changes nothing" {
    install_demo
    run_uninstall --dry-run
    assert_success
    assert_output_contains "[dry-run] rm /etc/modprobe.d/ally-x20-steamos.conf"
    assert_output_contains "[dry-run] rm -rf"
    [ -f "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos.conf" ]
    [ -f "$STATE/manifest" ]
}

@test "modified file is skipped without --force, removed with it; state dir kept when anything skipped" {
    install_demo
    printf 'edited by user\n' >"$AX20_ROOT/etc/modprobe.d/ally-x20-steamos.conf"
    run_uninstall
    assert_failure 1
    assert_output_contains "content changed"
    [ -f "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos.conf" ]
    [ -d "$STATE" ]
    # The skipped entry is still in the manifest, the removed ones are gone.
    grep -q 'ally-x20-steamos.conf' "$STATE/manifest"
    ! grep -q '90-ally-x20-steamos-ucm.conf' "$STATE/manifest"
    run_uninstall --force
    assert_success
    [ ! -e "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos.conf" ]
    [ ! -d "$STATE" ]
}

@test "partial manifest (interrupted install): missing files are tolerated" {
    install_demo
    rm "$AX20_ROOT/etc/environment.d/90-ally-x20-steamos-ucm.conf"
    run_uninstall
    assert_success
    assert_output_contains "already gone"
    [ ! -d "$STATE" ]
}

@test "symlinks are removed without following their target" {
    mkdir -p "$STATE/bin"
    printf 'target\n' >"$STATE/bin/gamescope"
    manifest_install_symlink /var/lib/ally-x20-steamos/bin/gamescope /home/deck/.local/bin/ally-x20-steamos-gamescope hdr home
    run_uninstall --keep-state
    assert_success
    [ ! -L "$AX20_ROOT/home/deck/.local/bin/ally-x20-steamos-gamescope" ]
    [ -f "$STATE/bin/gamescope" ]
}

@test "a symlink whose target changed is skipped unless --force" {
    manifest_install_symlink /a /home/deck/.config/ally-x20-steamos-link hdr home
    ln -sfn /b "$AX20_ROOT/home/deck/.config/ally-x20-steamos-link"
    run_uninstall --keep-state
    assert_failure 1
    [ -L "$AX20_ROOT/home/deck/.config/ally-x20-steamos-link" ]
    run_uninstall --keep-state --force
    assert_success
    [ ! -L "$AX20_ROOT/home/deck/.config/ally-x20-steamos-link" ]
}

@test "directories are removed only when we created them and they are empty" {
    manifest_install_file "$SRC" /etc/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml inputplumber
    fixture_file /etc/inputplumber/devices.d/user-added.yaml "keep me"
    run_uninstall
    assert_success
    [ ! -e "$AX20_ROOT/etc/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml" ]
    [ -f "$AX20_ROOT/etc/inputplumber/devices.d/user-added.yaml" ]
    [ -d "$AX20_ROOT/etc/inputplumber/devices.d" ]
    assert_output_contains "not empty"
}

@test "protected system directories are never removed even if the manifest says we created them" {
    manifest_record /etc/systemd/system audio dir "" shared false
    manifest_record /etc audio dir "" shared false
    manifest_record /home/deck audio dir "" home false
    manifest_record /esp/loader/entries audio dir "" esp false
    mkdir -p "$AX20_ROOT/etc/systemd/system" "$AX20_ROOT/home/deck" "$AX20_ROOT/esp/loader/entries"
    run_uninstall
    assert_success
    [ -d "$AX20_ROOT/etc/systemd/system" ]
    [ -d "$AX20_ROOT/etc" ]
    [ -d "$AX20_ROOT/home/deck" ]
    [ -d "$AX20_ROOT/esp/loader/entries" ]
}

@test "every ancestor directory we created is recorded and removed again" {
    mkdir -p "$AX20_ROOT/home/deck"
    manifest_install_file "$SRC" /home/deck/.config/pipewire/pipewire.conf.d/50-x20-headphones.conf audio_dsp 0644 home
    manifest_has /home/deck/.config
    manifest_has /home/deck/.config/pipewire
    manifest_has /home/deck/.config/pipewire/pipewire.conf.d
    run_uninstall
    assert_success
    [ ! -d "$AX20_ROOT/home/deck/.config" ]
    [ -d "$AX20_ROOT/home/deck" ]
}

@test "deny-list: crafted manifest entries are refused and reported" {
    fixture_file /usr/lib/ally-x20-steamos-evil.so "stock"
    fixture_file /etc/fstab "fstab"
    fixture_file /home/deck/.steam/ally-x20-steamos-x "steam"
    fixture_file /etc/rauc/system.conf "rauc"
    fixture_file /efi/EFI/steamos/steamcl.efi "loader"
    fixture_file /etc/no-marker.conf "x"
    for p in /usr/lib/ally-x20-steamos-evil.so /etc/fstab /home/deck/.steam/ally-x20-steamos-x /etc/rauc/system.conf /efi/EFI/steamos/steamcl.efi /etc/no-marker.conf; do
        manifest_record "$p" evil file "$(ax20_sha256 "$AX20_ROOT$p")" shared false
    done
    manifest_record "../etc/ally-x20-steamos-rel" evil file 0 shared false
    manifest_record "/etc/ally-x20-steamos/../fstab" evil file 0 shared false
    run_uninstall --force
    assert_failure 1
    for p in /usr/lib/ally-x20-steamos-evil.so /etc/fstab /home/deck/.steam/ally-x20-steamos-x /etc/rauc/system.conf /efi/EFI/steamos/steamcl.efi /etc/no-marker.conf; do
        [ -f "$AX20_ROOT$p" ]
        assert_output_contains "REFUSED $p"
    done
    assert_output_contains "relative manifest path"
    assert_output_contains "path with .."
    [ -d "$STATE" ]
}

@test "our own ESP file is allowed" {
    manifest_install_file "$SRC" /efi/EFI/steamos/ally-x20-steamos-acpi.img audio 0644 esp
    run_uninstall
    assert_success
    [ ! -e "$AX20_ROOT/efi/EFI/steamos/ally-x20-steamos-acpi.img" ]
}

@test "--component removes only that component and keeps the manifest for the rest" {
    install_demo
    run_uninstall --component audio
    assert_success
    [ ! -e "$AX20_ROOT/etc/environment.d/90-ally-x20-steamos-ucm.conf" ]
    [ -f "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos.conf" ]
    [ -d "$STATE" ]
    ! grep -q '90-ally-x20-steamos-ucm' "$STATE/manifest"
    grep -q 'modprobe.d/ally-x20-steamos.conf' "$STATE/manifest"
    # Remaining manifest is still parseable by the library.
    [ "$(manifest_paths modules | wc -l | tr -d ' ')" = 4 ] # 2 files + 2 created dirs
}

@test "backups of type=file are restored byte-for-byte, hash verified" {
    fixture_file /esp/loader/entries/steamos-A.conf "title SteamOS A
options root=/dev/sda2 ally-x20-steamos-modified initrd=/EFI/steamos/ally-x20-steamos-acpi.img"
    mkdir -p "$STATE/backup/boot-entry-A"
    printf 'title SteamOS A\noptions root=/dev/sda2\n' >"$STATE/backup/boot-entry-A/original"
    printf 'path=/esp/loader/entries/steamos-A.conf\nsha256=%s\ntype=file\ncomponent=update\n' "$(ax20_sha256 "$STATE/backup/boot-entry-A/original")" >"$STATE/backup/boot-entry-A/meta"
    run_uninstall
    assert_success
    assert_output_contains "restored byte-for-byte"
    [ "$(cat "$AX20_ROOT/esp/loader/entries/steamos-A.conf")" = "$(printf 'title SteamOS A\noptions root=/dev/sda2')" ]
}

@test "corrupt backup is not restored; missing original is reported" {
    fixture_file /esp/loader/entries/steamos-A.conf "live"
    mkdir -p "$STATE/backup/b1" "$STATE/backup/b2"
    printf 'orig' >"$STATE/backup/b1/original"
    printf 'path=/esp/loader/entries/steamos-A.conf\nsha256=0000\ntype=file\n' >"$STATE/backup/b1/meta"
    printf 'path=/esp/loader/entries/steamos-B.conf\nsha256=1111\ntype=file\n' >"$STATE/backup/b2/meta"
    run_uninstall
    assert_failure 1
    assert_output_contains "corrupt"
    assert_output_contains "saved original missing"
    [ "$(cat "$AX20_ROOT/esp/loader/entries/steamos-A.conf")" = live ]
}

@test "backups of type=block strip only our delimited block" {
    orig='[system]
compatible=steamos-amd64
bootloader=grub
'
    fixture_file /etc/rauc/system.conf "${orig}# >>> ally-x20-steamos
[handlers]
post-install=/var/lib/ally-x20-steamos/src/overlay/rauc/post-install.hook
# <<< ally-x20-steamos
"
    mkdir -p "$STATE/backup/rauc"
    printf '%s' "$orig" >"$STATE/backup/rauc/original"
    printf 'path=/etc/rauc/system.conf\nsha256=%s\ntype=block\n' "$(ax20_sha256 "$STATE/backup/rauc/original")" >"$STATE/backup/rauc/meta"
    run_uninstall
    assert_success
    assert_output_contains "identical to saved original"
    [ "$(cat "$AX20_ROOT/etc/rauc/system.conf")" = "$(printf '%s' "$orig")" ]
}

@test "type=block keeps upstream changes when the stripped file differs from the original" {
    fixture_file /etc/rauc/system.conf "[system]
compatible=steamos-amd64
new-valve-key=1
# >>> ally-x20-steamos
[handlers]
post-install=/x
# <<< ally-x20-steamos
"
    mkdir -p "$STATE/backup/rauc"
    printf '[system]\ncompatible=steamos-amd64\n' >"$STATE/backup/rauc/original"
    printf 'path=/etc/rauc/system.conf\nsha256=%s\ntype=block\n' "$(ax20_sha256 "$STATE/backup/rauc/original")" >"$STATE/backup/rauc/meta"
    run_uninstall
    assert_success
    assert_output_contains "differs from the saved original"
    [ "$(cat "$AX20_ROOT/etc/rauc/system.conf")" = "$(printf '[system]\ncompatible=steamos-amd64\nnew-valve-key=1')" ]
}

@test "backups under /usr are refused" {
    mkdir -p "$STATE/backup/evil"
    printf 'x' >"$STATE/backup/evil/original"
    printf 'path=/usr/bin/gamescope\nsha256=%s\ntype=file\n' "$(ax20_sha256 "$STATE/backup/evil/original")" >"$STATE/backup/evil/meta"
    run_uninstall
    assert_failure 1
    assert_output_contains "refusing to restore under /usr"
    [ ! -e "$AX20_ROOT/usr/bin/gamescope" ]
}

@test "works when the git checkout is gone (standalone copy from the state dir)" {
    install_demo
    cp "$UNINSTALL" "$STATE/uninstall.sh"
    run sh "$STATE/uninstall.sh" --root "$AX20_ROOT" --yes
    assert_success
    [ ! -d "$STATE" ]
}

@test "manifest paths with escaped quotes, backslashes and tabs round-trip through the awk parser" {
    weird='/etc/ally-x20-steamos/we"ird\pa	th.conf'
    mkdir -p "$AX20_ROOT/etc/ally-x20-steamos"
    printf 'x' >"$AX20_ROOT$weird"
    manifest_record "$weird" audio file "$(ax20_sha256 "$AX20_ROOT$weird")" shared false
    run_uninstall
    assert_success
    [ ! -e "$AX20_ROOT$weird" ]
}

@test "refuses to run on the live root without root privileges, except dry-run" {
    if [ "$(id -u)" = 0 ]; then skip "running as root"; fi
    run sh "$UNINSTALL" --yes
    assert_failure 2
    assert_output_contains "must run as root"
}

@test "--root must be a directory; unknown options are rejected" {
    run sh "$UNINSTALL" --root "$BATS_TEST_TMPDIR/nope" --yes
    assert_failure 2
    run sh "$UNINSTALL" --bogus
    assert_failure 2
}

@test "state dir behind the /home symlink is removed together with its target" {
    rm -rf "$STATE"
    mkdir -p "$AX20_ROOT/home/deck"
    ax20_state_dir_ensure >/dev/null
    [ -L "$STATE" ]
    install_demo
    [ -f "$AX20_ROOT/home/.ally-x20-steamos/manifest" ]
    run_uninstall
    assert_success
    [ ! -L "$STATE" ] && [ ! -e "$STATE" ]
    [ ! -e "$AX20_ROOT/home/.ally-x20-steamos" ]
    [ -d "$AX20_ROOT/home/deck" ]
}

@test "a state symlink pointing somewhere unexpected is removed but its target is left alone" {
    rm -rf "$STATE"
    mkdir -p "$AX20_ROOT/srv/elsewhere"
    ln -s /srv/elsewhere "$STATE"
    run_uninstall
    assert_success
    assert_output_contains "unexpected"
    [ -d "$AX20_ROOT/srv/elsewhere" ]
    [ ! -L "$STATE" ]
}

@test "lib/slots.sh backup layout (backup/<slot>/<file> + .sha256 + entry-path) is restored" {
    orig='menuentry SteamOS {
	steamenv_boot	linux /boot/vmlinuz console=tty1 quiet
	initrd	/boot/amd-ucode.img /boot/initramfs.img
}
'
    fixture_file /efi/EFI/steamos/grub.cfg "# ally-x20-steamos: boot entry modified by ally-x20-steamos
menuentry SteamOS {
	steamenv_boot	linux /boot/vmlinuz console=tty1 quiet firmware_class.path=/etc/ally-x20-steamos/firmware
	initrd	\${cmdpath}/ally-x20-steamos-acpi.img /boot/amd-ucode.img /boot/initramfs.img
}
"
    mkdir -p "$STATE/backup/B"
    printf '%s' "$orig" >"$STATE/backup/B/grub.cfg"
    ax20_sha256 "$STATE/backup/B/grub.cfg" >"$STATE/backup/B/grub.cfg.sha256"
    printf '/efi/EFI/steamos/grub.cfg\n' >"$STATE/backup/B/entry-path"
    run_uninstall
    assert_success
    assert_output_contains "restored byte-for-byte"
    [ "$(cat "$AX20_ROOT/efi/EFI/steamos/grub.cfg")" = "$(printf '%s' "$orig")" ]
}

@test "slots layout: a regenerated stock entry without our marker is left alone" {
    fixture_file /efi/EFI/steamos/grub.cfg "menuentry NewSteamOS { linux /boot/vmlinuz-new }"
    mkdir -p "$STATE/backup/B"
    printf 'old original\n' >"$STATE/backup/B/grub.cfg"
    ax20_sha256 "$STATE/backup/B/grub.cfg" >"$STATE/backup/B/grub.cfg.sha256"
    printf '/efi/EFI/steamos/grub.cfg\n' >"$STATE/backup/B/entry-path"
    run_uninstall
    assert_success
    assert_output_contains "carries no ally-x20-steamos change; leaving it alone"
    [ "$(cat "$AX20_ROOT/efi/EFI/steamos/grub.cfg")" = "menuentry NewSteamOS { linux /boot/vmlinuz-new }" ]
}

@test "lib/rauc.sh backup layout (backup/rauc/system.conf) strips the block" {
    orig='[system]
compatible=steamos-amd64

[handlers]
post-install=/usr/lib/rauc/post-install.sh
'
    fixture_file /etc/rauc/system.conf "${orig}# >>> ally-x20-steamos managed block (sep=0); original saved as ...
[handlers]
pre-install=/var/lib/ally-x20-steamos/libexec/rauc-pre-install.hook
post-install=/var/lib/ally-x20-steamos/libexec/rauc-post-install.hook
# <<< ally-x20-steamos
"
    mkdir -p "$STATE/backup/rauc"
    printf '%s' "$orig" >"$STATE/backup/rauc/system.conf"
    ax20_sha256 "$STATE/backup/rauc/system.conf" >"$STATE/backup/rauc/system.conf.sha256"
    run_uninstall
    assert_success
    assert_output_contains "identical to saved original"
    [ "$(cat "$AX20_ROOT/etc/rauc/system.conf")" = "$(printf '%s' "$orig")" ]
}
