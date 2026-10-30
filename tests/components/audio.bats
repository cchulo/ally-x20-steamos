#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/audio.sh: probes, UCM overlay, firmware fetch, ACPI glue.
load '../test_helper'

UCM=/usr/share/alsa/ucm2
OVL=/var/lib/ally-x20-steamos/ucm2
FW=/var/lib/ally-x20-steamos/firmware
KMOD_DIR=kernel/sound/soc/amd/acp

setup() {
    make_root >/dev/null
    export AX20_KVER="7.2.7-valve2-1-neptune-72"
    source_libs
    # Fake linux-firmware checkout + a lock file matching it.
    export AX20_FIRMWARE_SOURCE_DIR="$BATS_TEST_TMPDIR/linux-firmware"
    local d="$AX20_FIRMWARE_SOURCE_DIR/ti/audio/tas2783" f
    mkdir -p "$d"
    for f in 1954-0-0-0x8 1954-0-0-0xB 1954-1-0-0x8 1954-1-0-0xB; do
        printf 'tuning %s\n' "$f" >"$d/$f.bin"
    done
    export AX20_FIRMWARE_LOCK="$BATS_TEST_TMPDIR/tas2783.lock"
    write_lock "$AX20_FIRMWARE_LOCK"
    unset AX20_SPEAKER_SUPPLIER AX20_ACPI_BUILD_TOOL
    component_load audio
}

sha() { ax20_sha256 "$1"; }

write_lock() {
    local d="$AX20_FIRMWARE_SOURCE_DIR/ti/audio/tas2783"
    {
        printf '# test lock\ncommit %s\n' 0123456789abcdef0123456789abcdef01234567
        printf 'url https://example.invalid/%%PATH%%?id=%%COMMIT%%\n'
        printf 'file JGX ti/audio/tas2783/1954-0-0-0x8.bin 1954-0-0x8.bin %s\n' "$(sha "$d/1954-0-0-0x8.bin")"
        printf 'file JGX ti/audio/tas2783/1954-0-0-0xB.bin 1954-0-0xB.bin %s\n' "$(sha "$d/1954-0-0-0xB.bin")"
        printf 'file LS  ti/audio/tas2783/1954-1-0-0x8.bin 1954-0-0x8.bin %s\n' "$(sha "$d/1954-1-0-0x8.bin")"
        printf 'file LS  ti/audio/tas2783/1954-1-0-0xB.bin 1954-0-0xB.bin %s\n' "$(sha "$d/1954-1-0-0xB.bin")"
    } >"$1"
}

# A small stock UCM tree with the shapes that matter: a top-level file, plain
# directories, the conf.d relative symlink, and the two merge directories.
stock_ucm() {
    fixture_file "$UCM/ucm.conf" "stock ucm.conf"
    fixture_file "$UCM/lib/generic.conf" "stock generic"
    fixture_file "$UCM/USB-Audio/USB-Audio.conf" "stock usb"
    fixture_file "$UCM/sof-soundwire/sof-soundwire.conf" "stock sof-soundwire"
    fixture_file "$UCM/sof-soundwire/HiFi.conf" "stock HiFi"
    fixture_file "$UCM/sof-soundwire/rt721.conf" "stock rt721"
    fixture_file "$UCM/codecs/rt721/init.conf" "stock rt721 init"
    mkdir -p "$AX20_ROOT$UCM/conf.d/amd-soundwire"
    ln -s ../../sof-soundwire/sof-soundwire.conf "$AX20_ROOT$UCM/conf.d/amd-soundwire/amd-soundwire.conf"
}

# DSDT fragment: _DSD string, NUL, BytePrefix 0x0A, value.
fake_dsdt() {
    mkdir -p "$(dirname "$AX20_ROOT$1")"
    printf 'DSDT\001\002junk\015acp-audio-config-flag\000\012%b\244more' "$2" >"$AX20_ROOT$1"
}

stock_module() {
    fixture_file "/usr/lib/modules/$AX20_KVER/$KMOD_DIR/snd-soc-acpi-amd-match.ko" "$1"
}

stock_lacks_everything() {
    stock_ucm
    mkdir -p "$AX20_ROOT/usr/lib/firmware/ti/audio/tas2783"
    fixture_file /usr/lib/firmware/ti/audio/tas2783/1954-1-0-0x8.bin.zst "generic name only"
    stock_module "acp70_rt721_l1u0_tas2783x2_l1u8b"
    fake_dsdt /sys/firmware/acpi/tables/DSDT '\020'
    fixture_file /proc/asound/cards " 0 [Generic        ]: HDA-Intel - HD-Audio Generic"
}

stock_has_everything() {
    stock_ucm
    fixture_file "$UCM/sof-soundwire/tas2783.conf" "stock tas2783"
    fixture_file "$UCM/codecs/tas2783/init.conf" "stock tas2783 init"
    fixture_file /usr/lib/firmware/1954-0-0x8.bin.zst "z"
    fixture_file /usr/lib/firmware/1954-0-0xB.bin "b"
    stock_module "...acp70_tas2783x2_l0u8b_rt721_l1u0..."
    fake_dsdt /sys/firmware/acpi/tables/DSDT '\020'
    fixture_file /proc/asound/cards " 1 [amdsoundwire   ]: amd-soundwire - amd-soundwire"
}

speaker_id() { # <value bytes as printf %b escapes>
    local d="$AX20_ROOT/sys/firmware/efi/efivars"
    mkdir -p "$d"
    printf "\007\000\000\000$1" >"$d/SPEAKER_ID-aa61eaaf-6e83-7523-b0d0-7df74bb24a81"
}

tree_listing() { (cd "$AX20_ROOT" && find . | LC_ALL=C sort); }

# ------------------------------------------------------------------ probes --

@test "probe: stock lacks everything -> needed, every sub-probe needed" {
    stock_lacks_everything
    run audio_probe
    [ "$status" -eq 1 ]
    run audio_probe_details
    assert_success
    [ "$output" = "$(printf 'layout=needed\nacpi=needed\nucm=needed\nfirmware=needed')" ]
}

@test "probe: stock has everything -> superseded" {
    stock_has_everything
    run audio_probe
    [ "$status" -eq 0 ]
    run audio_probe_details
    [ "$output" = "$(printf 'layout=superseded\nacpi=superseded\nucm=superseded\nfirmware=superseded')" ]
    [ "$(component_status audio)" = superseded ]
}

@test "probe: partial (UCM and layout landed, firmware and ACPI not) -> needed" {
    stock_lacks_everything
    fixture_file "$UCM/sof-soundwire/tas2783.conf" "stock tas2783"
    stock_module "RC74XA"
    run audio_probe
    [ "$status" -eq 1 ]
    run audio_probe_details
    assert_output_contains "layout=superseded"
    assert_output_contains "ucm=superseded"
    assert_output_contains "firmware=needed"
    assert_output_contains "acpi=needed"
}

@test "probe: one firmware name missing is still needed" {
    stock_has_everything
    rm "$AX20_ROOT/usr/lib/firmware/1954-0-0xB.bin"
    run audio_probe_firmware
    [ "$status" -eq 1 ]
}

@test "probe firmware: four-field kernels are served by stock linux-firmware links" {
    stock_lacks_everything
    fixture_file "/usr/lib/modules/$AX20_KVER/kernel/sound/soc/codecs/snd-soc-tas2783-sdw.ko" "x%04X-%X-%1X-0x%1X.binx"
    run audio_probe_firmware
    [ "$status" -eq 1 ]
    local n
    for n in 1954-0-0-0x8 1954-0-0-0xB 1954-1-0-0x8 1954-1-0-0xB; do
        fixture_file "/usr/lib/firmware/$n.bin.zst" z
    done
    run audio_probe_firmware
    [ "$status" -eq 0 ]
    # an older driver still wants the bare names
    fixture_file "/usr/lib/modules/$AX20_KVER/kernel/sound/soc/codecs/snd-soc-tas2783-sdw.ko" "x%04X-%1X-%s%1X.binx"
    run audio_probe_firmware
    [ "$status" -eq 1 ]
}

@test "probe: empty fixture root -> unknown everywhere, never superseded" {
    run audio_probe
    [ "$status" -eq 2 ]
    run audio_probe_details
    [ "$output" = "$(printf 'layout=unknown\nacpi=unknown\nucm=unknown\nfirmware=unknown')" ]
}

@test "probe acpi: unknown without live files, unknown while our override is active, superseded when BIOS clears the flag" {
    stock_has_everything
    rm "$AX20_ROOT/proc/asound/cards"
    run audio_probe_acpi
    [ "$status" -eq 2 ]
    fixture_file /proc/asound/cards " 1 [amdsoundwire   ]: amd-soundwire"
    mkdir -p "$AX20_ROOT/var/lib/ally-x20-steamos/acpi"
    cp "$AX20_ROOT/sys/firmware/acpi/tables/DSDT" "$AX20_ROOT/var/lib/ally-x20-steamos/acpi/DSDT.patched.aml"
    run audio_probe_acpi
    [ "$status" -eq 2 ]
    rm "$AX20_ROOT/var/lib/ally-x20-steamos/acpi/DSDT.patched.aml"
    fake_dsdt /sys/firmware/acpi/tables/DSDT '\000'
    fixture_file /proc/asound/cards " 0 [Generic ]: HDA"
    run audio_probe_acpi
    [ "$status" -eq 0 ]
}

@test "audio_dsdt_flag reads ByteConst and ZeroOp encodings" {
    fake_dsdt /t1.aml '\020'
    [ "$(audio_dsdt_flag "$AX20_ROOT/t1.aml")" = 16 ]
    printf 'xx\015acp-audio-config-flag\000\000yy' >"$AX20_ROOT/t2.aml"
    [ "$(audio_dsdt_flag "$AX20_ROOT/t2.aml")" = 0 ]
    printf 'no flag here' >"$AX20_ROOT/t3.aml"
    run audio_dsdt_flag "$AX20_ROOT/t3.aml"
    assert_failure
}

# ------------------------------------------------------------- UCM overlay --

@test "apply builds a UCM overlay that mirrors stock and adds the tas2783 profile" {
    stock_lacks_everything
    run component_apply audio
    assert_success
    # top level: plain relative symlinks that resolve to the stock entries
    [ -L "$AX20_ROOT$OVL/ucm.conf" ]
    [ "$(readlink "$AX20_ROOT$OVL/ucm.conf")" = "../../../../usr/share/alsa/ucm2/ucm.conf" ]
    [ "$(cat "$AX20_ROOT$OVL/ucm.conf")" = "stock ucm.conf" ]
    [ -L "$AX20_ROOT$OVL/conf.d" ]
    [ "$(cat "$AX20_ROOT$OVL/conf.d/amd-soundwire/amd-soundwire.conf")" = "stock sof-soundwire" ]
    [ -L "$AX20_ROOT$OVL/USB-Audio" ]
    # merge directories are real, their stock children are links one level deeper
    [ -d "$AX20_ROOT$OVL/sof-soundwire" ] && ! [ -L "$AX20_ROOT$OVL/sof-soundwire" ]
    [ "$(readlink "$AX20_ROOT$OVL/sof-soundwire/HiFi.conf")" = "../../../../../usr/share/alsa/ucm2/sof-soundwire/HiFi.conf" ]
    [ "$(cat "$AX20_ROOT$OVL/sof-soundwire/HiFi.conf")" = "stock HiFi" ]
    [ "$(cat "$AX20_ROOT$OVL/codecs/rt721/init.conf")" = "stock rt721 init" ]
    # our files are real files, byte-identical to the vendored upstream copies
    [ -f "$AX20_ROOT$OVL/sof-soundwire/tas2783.conf" ] && ! [ -L "$AX20_ROOT$OVL/sof-soundwire/tas2783.conf" ]
    cmp "$REPO_ROOT/overlay/ucm2/sof-soundwire/tas2783.conf" "$AX20_ROOT$OVL/sof-soundwire/tas2783.conf"
    cmp "$REPO_ROOT/overlay/ucm2/codecs/tas2783/init.conf" "$AX20_ROOT$OVL/codecs/tas2783/init.conf"
    # session environment and modprobe hook
    grep -qx "ALSA_CONFIG_UCM2=$OVL" "$AX20_ROOT/etc/environment.d/90-ally-x20-steamos-ucm.conf"
    grep -q '^install snd_soc_tas2783_sdw ' "$AX20_ROOT/etc/modprobe.d/ally-x20-steamos-audio.conf"
    # stock tree untouched
    [ "$(cat "$AX20_ROOT$UCM/sof-soundwire/HiFi.conf")" = "stock HiFi" ]
    ! [ -e "$AX20_ROOT$UCM/sof-soundwire/tas2783.conf" ]
}

@test "apply prefers the stock tas2783 profile once SteamOS ships it" {
    stock_has_everything
    component_apply audio
    [ -L "$AX20_ROOT$OVL/sof-soundwire/tas2783.conf" ]
    [ "$(cat "$AX20_ROOT$OVL/sof-soundwire/tas2783.conf")" = "stock tas2783" ]
    [ -L "$AX20_ROOT$OVL/codecs/tas2783/init.conf" ]
}

@test "apply switches our file to a stock link after a SteamOS update adds it" {
    stock_lacks_everything
    component_apply audio
    [ -f "$AX20_ROOT$OVL/sof-soundwire/tas2783.conf" ] && ! [ -L "$AX20_ROOT$OVL/sof-soundwire/tas2783.conf" ]
    fixture_file "$UCM/sof-soundwire/tas2783.conf" "stock tas2783"
    component_apply audio
    [ -L "$AX20_ROOT$OVL/sof-soundwire/tas2783.conf" ]
    [ "$(manifest_entry_get "$(manifest_entry "$OVL/sof-soundwire/tas2783.conf")" kind)" = symlink ]
}

@test "apply drops overlay links whose stock entry disappeared" {
    stock_lacks_everything
    component_apply audio
    manifest_has "$OVL/USB-Audio"
    rm -rf "$AX20_ROOT$UCM/USB-Audio"
    component_apply audio
    ! [ -L "$AX20_ROOT$OVL/USB-Audio" ]
    ! manifest_has "$OVL/USB-Audio"
}

@test "overlay directories we create are all tracked, even nested ones" {
    stock_lacks_everything
    rm -rf "$AX20_ROOT$UCM/codecs"
    component_apply audio
    [ "$(manifest_entry_get "$(manifest_entry "$OVL/codecs")" kind)" = dir ]
    [ "$(manifest_entry_get "$(manifest_entry "$OVL/codecs/tas2783")" kind)" = dir ]
    speaker_id '\001\000\000\000'
    component_apply audio
    for d in "$FW" "$FW/ti" "$FW/ti/audio" "$FW/ti/audio/tas2783"; do
        [ "$(manifest_entry_get "$(manifest_entry "$d")" kind)" = dir ]
    done
}

@test "no stock UCM tree: overlay and ALSA_CONFIG_UCM2 are skipped" {
    run component_apply audio
    assert_success
    ! [ -e "$AX20_ROOT$OVL" ]
    ! [ -e "$AX20_ROOT/etc/environment.d/90-ally-x20-steamos-ucm.conf" ]
}

# ---------------------------------------------------------------- firmware --

@test "real tas2783.lock parses: pinned commit, two suppliers, two requested names" {
    FW_LOCK="$REPO_ROOT/firmware/tas2783.lock"
    run fw_lock_validate
    assert_success
    [ "$(fw_lock_get commit)" = a2dcb924f0897368b0b4f305cbf9808cdda90ce0 ]
    [ "$(fw_lock_suppliers | tr '\n' ' ')" = "JGX LS " ]
    [ "$(fw_lock_requests | tr '\n' ' ')" = "1954-0-0x8.bin 1954-0-0xB.bin " ]
    [ "$(fw_lock_files LS | wc -l | tr -d ' ')" = 2 ]
    [ "$(fw_url "$(fw_lock_get url)" ti/audio/tas2783/1954-1-0-0x8.bin "$(fw_lock_get commit)")" \
        = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/ti/audio/tas2783/1954-1-0-0x8.bin?id=a2dcb924f0897368b0b4f305cbf9808cdda90ce0" ]
    [ -n "$(fw_lock_get mirror)" ]
}

@test "malformed lock files are rejected" {
    printf 'commit abc\nurl x\nfile LS ti/a.bin a.bin deadbeef\n' >"$BATS_TEST_TMPDIR/bad.lock"
    FW_LOCK="$BATS_TEST_TMPDIR/bad.lock"
    run fw_lock_validate
    assert_failure
    assert_output_contains "commit"
    assert_output_contains "bad sha256"
    printf 'commit %s\nurl x\nfile LS ../../etc/x a.bin %s\n' "$(printf '%040d' 0)" "$(printf '%064d' 0)" >"$BATS_TEST_TMPDIR/bad2.lock"
    FW_LOCK="$BATS_TEST_TMPDIR/bad2.lock"
    run fw_lock_validate
    assert_failure
    assert_output_contains "unsafe path"
}

@test "SPEAKER_ID: 4-byte attribute prefix is skipped, little-endian value read" {
    speaker_id '\001\000\000\000'
    [ "$(fw_speaker_id)" = 1 ]
    speaker_id '\002\001\000\000'
    [ "$(fw_speaker_id)" = 258 ]
    speaker_id '\000'
    [ "$(fw_speaker_id)" = 0 ]
    [ "$(fw_supplier_for_id 0)" = JGX ]
    [ "$(fw_supplier_for_id 1)" = LS ]
    run fw_supplier_for_id 7
    assert_failure
}

@test "SPEAKER_ID: missing or truncated variable is not a value" {
    run fw_speaker_id
    assert_failure
    mkdir -p "$AX20_ROOT/sys/firmware/efi/efivars"
    printf '\007\000\000\000' >"$AX20_ROOT/sys/firmware/efi/efivars/SPEAKER_ID-0000"
    run fw_speaker_id
    assert_failure
}

@test "apply installs the LS pair from SPEAKER_ID=1 under the requested names" {
    stock_lacks_everything
    speaker_id '\001\000\000\000'
    run component_apply audio
    assert_success
    [ -f "$AX20_ROOT$FW/ti/audio/tas2783/1954-1-0-0x8.bin" ]
    [ "$(readlink "$AX20_ROOT$FW/1954-0-0x8.bin")" = ti/audio/tas2783/1954-1-0-0x8.bin ]
    [ "$(readlink "$AX20_ROOT$FW/1954-0-0xB.bin")" = ti/audio/tas2783/1954-1-0-0xB.bin ]
    [ "$(cat "$AX20_ROOT$FW/1954-0-0x8.bin")" = "tuning 1954-1-0-0x8" ]
    # four-field names for kernels that read SPEAKER_ID themselves
    [ "$(readlink "$AX20_ROOT$FW/1954-1-0-0xB.bin")" = ti/audio/tas2783/1954-1-0-0xB.bin ]
    ! [ -e "$AX20_ROOT$FW/ti/audio/tas2783/1954-0-0-0x8.bin" ]
    [ "$(audio_kernel_cmdline)" = "firmware_class.path=$FW" ]
}

@test "supplier override wins over SPEAKER_ID and is remembered" {
    stock_lacks_everything
    speaker_id '\001\000\000\000'
    AX20_SPEAKER_SUPPLIER=JGX component_apply audio
    [ "$(readlink "$AX20_ROOT$FW/1954-0-0x8.bin")" = ti/audio/tas2783/1954-0-0-0x8.bin ]
    [ "$(cat "$AX20_ROOT$FW/supplier")" = JGX ]
    # the boot service re-applies without the variable: the override sticks
    component_apply audio
    [ "$(readlink "$AX20_ROOT$FW/1954-0-0x8.bin")" = ti/audio/tas2783/1954-0-0-0x8.bin ]
    run fw_resolve_supplier NOPE
    assert_failure
}

@test "fetch script CLI: --supplier against a fixture root" {
    run "$REPO_ROOT/firmware/fetch-tas2783.sh" --root "$AX20_ROOT/" --supplier LS
    assert_success
    [ "$(readlink "$AX20_ROOT$FW/1954-0-0xB.bin")" = ti/audio/tas2783/1954-1-0-0xB.bin ]
    grep -q "\"path\":\"$FW/1954-0-0xB.bin\"" "$AX20_ROOT/var/lib/ally-x20-steamos/manifest"
    run "$REPO_ROOT/firmware/fetch-tas2783.sh" --bogus
    [ "$status" -eq 64 ]
}

@test "unknown supplier: every file is fetched, no requested name is guessed" {
    stock_lacks_everything
    run component_apply audio
    assert_success
    assert_output_contains "speaker supplier unknown"
    [ -f "$AX20_ROOT$FW/ti/audio/tas2783/1954-0-0-0x8.bin" ]
    [ -f "$AX20_ROOT$FW/ti/audio/tas2783/1954-1-0-0xB.bin" ]
    ! [ -e "$AX20_ROOT$FW/1954-0-0x8.bin" ]
    ! [ -L "$AX20_ROOT$FW/1954-0-0x8.bin" ]
    # the four-field names are unambiguous and linked anyway
    [ -L "$AX20_ROOT$FW/1954-0-0-0x8.bin" ]
    [ -L "$AX20_ROOT$FW/1954-1-0-0xB.bin" ]
}

@test "sha256 mismatch: nothing is installed and apply carries on" {
    stock_lacks_everything
    speaker_id '\001\000\000\000'
    printf 'tampered\n' >"$AX20_FIRMWARE_SOURCE_DIR/ti/audio/tas2783/1954-1-0-0xB.bin"
    run fw_fetch
    assert_failure
    assert_output_contains "sha256 mismatch for ti/audio/tas2783/1954-1-0-0xB.bin"
    ! [ -e "$AX20_ROOT$FW/ti/audio/tas2783/1954-1-0-0xB.bin" ]
    ! [ -L "$AX20_ROOT$FW/1954-0-0xB.bin" ]
    run component_apply audio
    assert_success
    assert_output_contains "firmware not installed"
    [ -f "$AX20_ROOT$OVL/sof-soundwire/tas2783.conf" ]
}

@test "missing source file is a fetch failure" {
    rm "$AX20_FIRMWARE_SOURCE_DIR/ti/audio/tas2783/1954-0-0-0x8.bin"
    run fw_fetch JGX
    assert_failure
    assert_output_contains "lacks ti/audio/tas2783/1954-0-0-0x8.bin"
}

@test "sysfs firmware_class path is never written on a fixture root" {
    stock_lacks_everything
    mkdir -p "$AX20_ROOT/sys/module/firmware_class/parameters"
    : >"$AX20_ROOT/sys/module/firmware_class/parameters/path"
    component_apply audio
    [ ! -s "$AX20_ROOT/sys/module/firmware_class/parameters/path" ]
}

# ------------------------------------------------------- manifest behaviour --

@test "manifest round-trip: every written path is recorded, verifies, and removal restores the root" {
    stock_lacks_everything
    speaker_id '\001\000\000\000'
    local before after p kind
    before=$(tree_listing | grep -v '^./var/lib/ally-x20-steamos/manifest')
    component_apply audio
    for p in $(manifest_paths audio); do
        manifest_verify "$p" || {
            echo "drift: $p"
            false
        }
    done
    [ "$(component_status audio)" = active ]
    # everything new outside the manifest file itself is in the manifest
    (cd "$AX20_ROOT" && find ./etc ./var/lib/ally-x20-steamos/ucm2 ./var/lib/ally-x20-steamos/firmware \( -type f -o -type l \)) \
        | sed 's#^\.##' | while read -r p; do
            manifest_has "$p" || {
                echo "untracked: $p"
                false
            }
        done
    # simulate the uninstaller: newest first, files/links, then empty dirs
    manifest_entries_reverse | while read -r line; do
        p=$(manifest_entry_get "$line" path)
        kind=$(manifest_entry_get "$line" kind)
        [ "$kind" = dir ] || rm -f "$AX20_ROOT$p"
    done
    manifest_entries_reverse | while read -r line; do
        p=$(manifest_entry_get "$line" path)
        kind=$(manifest_entry_get "$line" kind)
        [ "$kind" != dir ] || rmdir "$AX20_ROOT$p"
    done
    after=$(tree_listing | grep -v '^./var/lib/ally-x20-steamos/manifest')
    [ "$before" = "$after" ]
}

@test "apply is idempotent" {
    stock_lacks_everything
    speaker_id '\000\000\000\000'
    component_apply audio
    local n1 m1
    n1=$(wc -l <"$AX20_ROOT/var/lib/ally-x20-steamos/manifest")
    m1=$(tree_listing)
    component_apply audio
    [ "$(wc -l <"$AX20_ROOT/var/lib/ally-x20-steamos/manifest")" = "$n1" ]
    [ "$(tree_listing)" = "$m1" ]
    [ "$(manifest_paths audio | sort | uniq -d)" = "" ]
}

@test "dry-run writes nothing" {
    stock_lacks_everything
    speaker_id '\001\000\000\000'
    fixture_file /sys/class/dmi/id/board_name RC74XA
    mkdir -p "$AX20_ROOT/efi/EFI/steamos"
    local before
    before=$(tree_listing)
    AX20_DRY_RUN=1 run component_apply audio
    assert_success
    assert_output_contains "[dry-run]"
    [ "$(tree_listing)" = "$before" ]
    ! [ -e "$AX20_ROOT/var/lib/ally-x20-steamos/manifest" ]
}

# --------------------------------------------------------------- ACPI glue --

fake_acpi_tool() { # <exit code>
    export AX20_ACPI_BUILD_TOOL="$BATS_TEST_TMPDIR/build-override.sh"
    cat >"$AX20_ACPI_BUILD_TOOL" <<EOF
#!/usr/bin/env bash
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in --out) out=\$2; shift 2 ;; *) printf '%s\n' "\$1" >>"$BATS_TEST_TMPDIR/tool-args"; shift ;; esac
done
[ "$1" = 0 ] || exit $1
printf 'cpio' >"\$out/ally-x20-steamos-acpi.img"
printf 'aml' >"\$out/DSDT.patched.aml"
printf 'orig' >"\$out/DSDT.orig.aml"
printf 'tool=fake\n' >"\$out/BUILD-INFO"
EOF
    chmod +x "$AX20_ACPI_BUILD_TOOL"
    # the tool path is captured when the component is sourced
    AUDIO_ACPI_TOOL=$AX20_ACPI_BUILD_TOOL
}

acpi_device() {
    fixture_file /sys/class/dmi/id/board_name RC74XA
    mkdir -p "$AX20_ROOT/efi/EFI/steamos"
    fake_dsdt /sys/firmware/acpi/tables/DSDT '\020'
}

@test "ACPI: override is built, copied to the ESP and handed to slot_set_early_initrd" {
    stock_lacks_everything
    acpi_device
    fake_acpi_tool 0
    slot_set_early_initrd() { printf '%s %s\n' "$1" "$2" >"$BATS_TEST_TMPDIR/slot-call"; }
    run component_apply audio
    assert_success
    [ "$(cat "$AX20_ROOT/efi/EFI/steamos/ally-x20-steamos-acpi.img")" = cpio ]
    [ -f "$AX20_ROOT/var/lib/ally-x20-steamos/acpi/ally-x20-steamos-acpi.img" ]
    [ -f "$AX20_ROOT/var/lib/ally-x20-steamos/acpi/BUILD-INFO" ]
    [ "$(manifest_entry_get "$(manifest_entry /efi/EFI/steamos/ally-x20-steamos-acpi.img)" slot)" = esp ]
    [ "$(cat "$BATS_TEST_TMPDIR/slot-call")" = "active /efi/EFI/steamos/ally-x20-steamos-acpi.img" ]
    # the live table is read by the tool itself (no --dsdt), so it can use its cache
    ! [ -e "$BATS_TEST_TMPDIR/tool-args" ]
}

@test "ACPI: without lib/slots.sh the boot entry step is reported pending" {
    stock_lacks_everything
    acpi_device
    fake_acpi_tool 0
    run component_apply audio
    assert_success
    assert_output_contains "boot entry step pending"
    [ -f "$AX20_ROOT/efi/EFI/steamos/ally-x20-steamos-acpi.img" ]
}

@test "ACPI: fixture DSDT is used only on fixture roots without a live table" {
    stock_lacks_everything
    acpi_device
    rm "$AX20_ROOT/sys/firmware/acpi/tables/DSDT"
    fake_acpi_tool 0
    printf 'fixture dsdt' >"$BATS_TEST_TMPDIR/x20-dsdt.aml"
    AUDIO_ACPI_FIXTURE_DSDT="$BATS_TEST_TMPDIR/x20-dsdt.aml"
    run component_apply audio
    assert_success
    grep -qx -- --dsdt "$BATS_TEST_TMPDIR/tool-args"
    grep -qx -- "$BATS_TEST_TMPDIR/x20-dsdt.aml" "$BATS_TEST_TMPDIR/tool-args"
}

@test "ACPI: 'no override needed' and failures install nothing and do not fail apply" {
    stock_lacks_everything
    acpi_device
    fake_acpi_tool 3
    run component_apply audio
    assert_success
    assert_output_contains "no override needed"
    ! [ -e "$AX20_ROOT/efi/EFI/steamos/ally-x20-steamos-acpi.img" ]
    fake_acpi_tool 2
    run component_apply audio
    assert_success
    assert_output_contains "override build failed (exit 2)"
    ! [ -e "$AX20_ROOT/efi/EFI/steamos/ally-x20-steamos-acpi.img" ]
}

@test "ACPI: skipped on other boards and when the tool is absent" {
    stock_lacks_everything
    acpi_device
    fixture_file /sys/class/dmi/id/board_name RC71L
    fake_acpi_tool 0
    run component_apply audio
    assert_output_contains "is not RC74XA"
    ! [ -e "$AX20_ROOT/efi/EFI/steamos/ally-x20-steamos-acpi.img" ]
    fixture_file /sys/class/dmi/id/board_name RC74XA
    AUDIO_ACPI_TOOL="$BATS_TEST_TMPDIR/nope.sh"
    run component_apply audio
    assert_output_contains "ACPI step pending"
}

@test "ACPI: nothing is rebuilt while our override is active and installed" {
    stock_lacks_everything
    acpi_device
    fake_acpi_tool 0
    component_apply audio
    cp "$AX20_ROOT/var/lib/ally-x20-steamos/acpi/DSDT.patched.aml" "$AX20_ROOT/sys/firmware/acpi/tables/DSDT"
    fake_acpi_tool 2 # would fail if called
    run component_apply audio
    assert_success
    assert_output_contains "override active and installed"
}
