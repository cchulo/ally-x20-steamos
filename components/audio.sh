# SPDX-License-Identifier: GPL-2.0-only
# components/audio.sh — internal speakers (two TI TAS2783 amps on SoundWire)
# for the ROG Xbox Ally X20. Plan §1.1, problems 1, 3 and 4; problem 2 (the
# link-0 layout in snd-soc-acpi-amd-match) is the `modules` component.
#
# What this component installs (all manifest-tracked, component "audio"):
#   /etc/modprobe.d/ally-x20-steamos-audio.conf   firmware_class.path hook
#                                                 before the amp driver loads
#   /var/lib/ally-x20-steamos/ucm2/**             UCM overlay: relative symlinks
#                                                 to every stock entry + the
#                                                 upstream tas2783 profile
#   /etc/environment.d/90-ally-x20-steamos-ucm.conf  ALSA_CONFIG_UCM2=<overlay>
#   /etc/ally-x20-steamos/firmware/**         TAS2783 tuning (linux-firmware,
#                                                 pinned + sha256) and links
#                                                 under the requested names
#   /var/lib/ally-x20-steamos/acpi/*              ACPI override build outputs
#   /efi/EFI/steamos/ally-x20-steamos-acpi.img    early initrd (slot "esp")
#
# Interfaces used from other packages (all optional, guarded):
#   $AX20_SRC/acpi/build-override.sh --out <dir> [--table <file>]
#       (override with AX20_ACPI_BUILD_TOOL); exit 3 = no override needed.
#   slot_set_early_initrd <slot> <initrd-path>   from lib/slots.sh, called only
#       if defined; <slot> is $AX20_SLOT or "active", <initrd-path> is the
#       ESP image path without root prefix.
# Interface offered to the boot-entry step:
#   audio_kernel_cmdline  prints "firmware_class.path=<firmware dir>".

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="TAS2783 speakers: UCM profile overlay, amp tuning firmware, ACPI flag override"

# The boot-entry library is optional at load time (fixture roots, partial
# checkouts); when present its slot_set_early_initrd shim is used below.
if [ -f "$AX20_SRC/lib/slots.sh" ]; then
    # shellcheck source=lib/slots.sh
    . "$AX20_SRC/lib/slots.sh"
fi

# shellcheck source=firmware/fetch-tas2783.sh
. "$AX20_SRC/firmware/fetch-tas2783.sh"

AUDIO_UCM_STOCK_REL=/usr/share/alsa/ucm2
AUDIO_UCM_OVERLAY_REL="${AX20_STATE_REL}/ucm2"
AUDIO_UCM_SRC="$AX20_SRC/overlay/ucm2"
AUDIO_ENV_SRC=environment.d/90-ally-x20-steamos-ucm.conf
AUDIO_ENV_REL=/etc/environment.d/90-ally-x20-steamos-ucm.conf
AUDIO_MODPROBE_SRC=modprobe.d/ally-x20-steamos-audio.conf
AUDIO_MODPROBE_REL=/etc/modprobe.d/ally-x20-steamos-audio.conf
AUDIO_FW_REL="${AX20_EARLY_REL}/firmware" # must exist when the amp driver loads (before /var, /home)
AUDIO_STOCK_FW_REL=/usr/lib/firmware
AUDIO_FW_CLASS_PATH_REL=/sys/module/firmware_class/parameters/path
AUDIO_ACPI_IMG_NAME=ally-x20-steamos-acpi.img
AUDIO_ACPI_STATE_REL="${AX20_STATE_REL}/acpi"
AUDIO_ESP_DIR_REL=/efi/EFI/steamos
AUDIO_ESP_IMG_REL="${AUDIO_ESP_DIR_REL}/${AUDIO_ACPI_IMG_NAME}"
AUDIO_ACPI_TABLES_REL=/sys/firmware/acpi/tables
AUDIO_ACPI_FLAG_NAME=acp-audio-config-flag
AUDIO_CARDS_REL=/proc/asound/cards
AUDIO_ACPI_TOOL="${AX20_ACPI_BUILD_TOOL:-$AX20_SRC/acpi/build-override.sh}"
AUDIO_ACPI_FIXTURE_TABLE="${AX20_ACPI_FIXTURE_TABLE:-$AX20_SRC/acpi/fixtures/synthetic-dsdt.aml}"

# _audio_acpi_live_table : the live table (DSDT or an SSDT) that carries
# acp-audio-config-flag; on the X20 it is the AMD "OEMACP" SSDT, not the
# DSDT. Prints the path; fails when none is readable (needs root) or none
# carries the flag.
_audio_acpi_live_table() {
    local dir t
    dir=$(ax20_path "$AUDIO_ACPI_TABLES_REL")
    for t in "$dir/DSDT" "$dir"/SSDT*; do
        [ -r "$t" ] || continue
        if audio_dsdt_flag "$t" >/dev/null 2>&1; then
            printf '%s\n' "$t"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------- contract --

audio_files() {
    printf '%s\t%s\t0644\n' "$AUDIO_MODPROBE_SRC" "$AUDIO_MODPROBE_REL"
}

audio_kernel_cmdline() {
    printf 'firmware_class.path=%s\n' "$AUDIO_FW_REL"
}

audio_apply() {
    _audio_ucm_apply || return 1
    _audio_firmware_apply || return 1
    _audio_fw_class_path_apply
    _audio_acpi_apply
    return 0
}

audio_remove() {
    # Undo the runtime sysfs setting if it is still ours; files are removed
    # by the manifest-driven uninstall.
    local p cur
    [ -z "$AX20_ROOT" ] || return 0
    p=$(ax20_path "$AUDIO_FW_CLASS_PATH_REL")
    [ -w "$p" ] || return 0
    cur=$(cat "$p" 2>/dev/null || true)
    if [ "$cur" = "$AUDIO_FW_REL" ]; then
        _audio_sysfs_write "$p" "" || true
    fi
    return 0
}

# ---------------------------------------------------------------- probes --
# Each sub-probe follows the lib/probes.sh exit-code contract.

# layout: stock snd-soc-acpi-amd-match knows the RC74XA link-0 amp layout.
# Matched by the DMI board name or by the layout table name used by the
# patch (acp70_tas2783x2_l0...). TODO(hw): refine once upstream picks a name.
audio_probe_layout() {
    local rc
    probe_stock_module_contains snd-soc-acpi-amd-match "$AX20_BOARD"
    rc=$?
    [ "$rc" = "$PROBE_YES" ] && return "$PROBE_YES"
    [ "$rc" = "$PROBE_UNKNOWN" ] && return "$PROBE_UNKNOWN"
    probe_stock_module_contains snd-soc-acpi-amd-match tas2783x2_l0
}

# ucm: stock alsa-ucm-conf ships the TAS2783 speaker profile.
audio_probe_ucm() {
    [ -d "$(ax20_path "$AUDIO_UCM_STOCK_REL")" ] || return "$PROBE_UNKNOWN"
    probe_file_exists "$AUDIO_UCM_STOCK_REL/sof-soundwire/tas2783.conf"
}

# Format string of the four-field firmware name, present in the amp driver
# once it carries "ASoC: tas2783-sdw: use the BIOS speaker ID in the firmware
# name" (in Valve's 7.2.10-valve1; v7.2.7 only has "%04X-%1X-%s%1X.bin").
AUDIO_TAS2783_SPKID_FMT='%04X-%X-%1X-0x%1X.bin'

# _audio_stock_fw_has <name> : stock /usr/lib/firmware/<name>, plain or
# compressed (SteamOS: /lib -> usr/lib).
_audio_stock_fw_has() {
    local ext
    for ext in "" .zst .xz; do
        [ -e "$(ax20_path "$AUDIO_STOCK_FW_REL/$1$ext")" ] && return 0
    done
    return 1
}

# firmware: every name the stock driver requests exists in stock firmware.
# Four-field kernels request 1954-<spkid>-0-0x{8,B}.bin, which linux-firmware
# links at the firmware root; v7.2.7 requests the bare 1954-0-0x{8,B}.bin,
# which nothing ships.
audio_probe_firmware() {
    local name four=0 s path req sha
    [ -d "$(ax20_path "$AUDIO_STOCK_FW_REL")" ] || return "$PROBE_UNKNOWN"
    probe_stock_module_contains snd-soc-tas2783-sdw "$AUDIO_TAS2783_SPKID_FMT" >/dev/null 2>&1 && four=1
    if [ "$four" = 1 ]; then
        while read -r s path req sha; do
            [ -n "$s" ] || continue
            name=$(basename "$path")
            _audio_stock_fw_has "$name" || _audio_stock_fw_has "$path" || return "$PROBE_NO"
        done <<EOF
$(fw_lock_files)
EOF
        return "$PROBE_YES"
    fi
    for name in $(fw_lock_requests); do
        _audio_stock_fw_has "$name" || return "$PROBE_NO"
    done
    return "$PROBE_YES"
}

# acpi: the stock boot gets a SoundWire card although the BIOS flag says
# "DMIC only" (kernel quirk landed), or the BIOS no longer sets the flag.
# Only decidable on a live boot without our override: needs the live table and
# /proc/asound/cards; while our override is active it reports unknown.
audio_probe_acpi() {
    local cards table patched flag
    cards=$(ax20_path "$AUDIO_CARDS_REL")
    [ -r "$cards" ] || return "$PROBE_UNKNOWN"
    table=$(_audio_acpi_live_table) || return "$PROBE_UNKNOWN"
    patched=$(ax20_path "$AUDIO_ACPI_STATE_REL/TABLE.patched.aml")
    if [ -f "$patched" ] && cmp -s "$table" "$patched"; then
        return "$PROBE_UNKNOWN" # booted with our override: cannot tell
    fi
    flag=$(audio_dsdt_flag "$table") || return "$PROBE_UNKNOWN"
    [ "$flag" = 0 ] && return "$PROBE_YES" # BIOS fixed
    if grep -Eq 'amdsoundwire|amd-soundwire|sof-soundwire' "$cards"; then
        return "$PROBE_YES"
    fi
    return "$PROBE_NO"
}

# audio_dsdt_flag <aml> : decimal value of acp-audio-config-flag in an AML
# table (_DSD string followed by a ByteConst/ZeroOp/OneOp), or fail.
audio_dsdt_flag() {
    local off voff op val nul
    [ -f "$1" ] || return 1
    # First occurrence that is an exact AML string (name followed by NUL), so
    # a longer property name sharing the prefix is not mistaken for it.
    off=""
    for nul in $(LC_ALL=C grep -abo -- "$AUDIO_ACPI_FLAG_NAME" "$1" 2>/dev/null | cut -d: -f1); do
        if [ "$(od -An -v -tu1 -j $((nul + ${#AUDIO_ACPI_FLAG_NAME})) -N1 "$1" | tr -d ' ')" = 0 ]; then
            off=$nul
            break
        fi
    done
    [ -n "$off" ] || return 1
    # name, NUL terminator, then the data object
    voff=$((off + ${#AUDIO_ACPI_FLAG_NAME} + 1))
    op=$(od -An -v -tu1 -j "$voff" -N1 "$1" | tr -d ' ')
    case "$op" in
        10) # 0x0A BytePrefix
            val=$(od -An -v -tu1 -j $((voff + 1)) -N1 "$1" | tr -d ' ')
            ;;
        0) val=0 ;;    # ZeroOp
        1) val=1 ;;    # OneOp
        *) return 1 ;; # Word/DWord/other encodings: not expected here
    esac
    [ -n "$val" ] || return 1
    printf '%s\n' "$val"
}

AUDIO_SUBPROBES="layout acpi ucm firmware"

audio_probe_details() {
    local p rc
    for p in $AUDIO_SUBPROBES; do
        "audio_probe_$p" >/dev/null 2>&1
        rc=$?
        printf '%s=%s\n' "$p" "$(probe_result_word "$rc")"
    done
}

# Superseded only when every sub-probe says so; needed if any says needed.
audio_probe() {
    local p rc any_no=0 any_unknown=0
    for p in $AUDIO_SUBPROBES; do
        "audio_probe_$p" >/dev/null 2>&1
        rc=$?
        case "$rc" in
            0) ;;
            1) any_no=1 ;;
            *) any_unknown=1 ;;
        esac
    done
    [ "$any_no" = 1 ] && return "$PROBE_NO"
    [ "$any_unknown" = 1 ] && return "$PROBE_UNKNOWN"
    return "$PROBE_YES"
}

# ----------------------------------------------------------- UCM overlay --
# ALSA_CONFIG_UCM2 replaces the UCM directory (alsa-lib ucm_filename():
# "<env>/<dir>/<file>", no search path), and conf.d/ lookups are relative to
# that same directory, so stock files cannot be layered any other way. The
# overlay therefore mirrors the stock tree with relative symlinks and only
# turns the directories holding our files (sof-soundwire/, codecs/) into real
# directories. Every UCM include in the sof-soundwire family is absolute
# ("/sof-soundwire/..."), which alsa-lib resolves against ALSA_CONFIG_UCM2,
# i.e. through the overlay. See docs/audio.md.

# _audio_ucm_ours : our UCM files, relative to overlay/ucm2.
_audio_ucm_ours() {
    (cd "$AUDIO_UCM_SRC" 2>/dev/null && find . -type f -name '*.conf' | sed 's#^\./##' | sort)
}

# _audio_ucm_is_merge_dir <rel> : true if one of our files lives below rel.
_audio_ucm_is_merge_dir() {
    _audio_ucm_ours | grep -q "^$1/"
}

# _audio_updots <abs-dir> : "../" once per component of an absolute dir.
_audio_updots() {
    printf '%s\n' "$1" | awk -F/ '{ s = ""; for (i = 2; i <= NF; i++) if ($i != "") s = s "../"; print s }'
}

# _audio_drop_owned <abs-path> : remove a file/link we own (manifest) so a
# different kind can take its place.
_audio_drop_owned() {
    local real
    real=$(ax20_path "$1")
    manifest_has "$1" || return 0
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] rm %s\n' "$real" >&2
        return 0
    fi
    if [ -L "$real" ] || [ -f "$real" ]; then
        rm -f "$real"
    fi
    manifest_forget "$1"
}

# _audio_ucm_link <rel> : overlay/<rel> -> stock/<rel> (relative link).
_audio_ucm_link() {
    local rel=$1 link real target
    link="$AUDIO_UCM_OVERLAY_REL/$rel"
    real=$(ax20_path "$link")
    target="$(_audio_updots "$(dirname "$link")")${AUDIO_UCM_STOCK_REL#/}/$rel"
    if [ -L "$real" ] && [ "$(readlink "$real")" = "$target" ] && manifest_has "$link"; then
        return 0
    fi
    if [ -f "$real" ] && ! [ -L "$real" ]; then
        _audio_drop_owned "$link"
    fi
    manifest_install_symlink "$target" "$link" audio shared
}

# _audio_ucm_merge <rel-dir> : mirror stock/<rel-dir> into the overlay.
_audio_ucm_merge() {
    local rel=$1 stock entry name r
    stock=$(ax20_path "$AUDIO_UCM_STOCK_REL${rel:+/$rel}")
    for entry in "$stock"/*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=$(basename "$entry")
        r="${rel:+$rel/}$name"
        if [ -d "$entry" ] && _audio_ucm_is_merge_dir "$r"; then
            if [ -L "$(ax20_path "$AUDIO_UCM_OVERLAY_REL/$r")" ]; then
                _audio_drop_owned "$AUDIO_UCM_OVERLAY_REL/$r"
            fi
            fw_mkdir_tracked "$AUDIO_UCM_OVERLAY_REL/$r" || return 1
            _audio_ucm_merge "$r" || return 1
        else
            _audio_ucm_link "$r" || return 1
        fi
    done
}

# _audio_ucm_prune : forget links whose stock target disappeared (after a
# SteamOS update removed an entry).
_audio_ucm_prune() {
    local p real
    for p in $(manifest_paths audio | grep "^$AUDIO_UCM_OVERLAY_REL/"); do
        real=$(ax20_path "$p")
        if [ -L "$real" ] && ! [ -e "$real" ]; then
            log_info "UCM overlay: stock entry gone, dropping ${p#"$AUDIO_UCM_OVERLAY_REL"/}"
            _audio_drop_owned "$p"
        fi
    done
}

_audio_ucm_apply() {
    local stock f
    stock=$(ax20_path "$AUDIO_UCM_STOCK_REL")
    if ! [ -d "$stock" ]; then
        log_warn "UCM: $AUDIO_UCM_STOCK_REL not found; skipping the UCM overlay"
        return 0
    fi
    if [ -f "$stock/sof-soundwire/tas2783.conf" ]; then
        log_info "UCM: stock alsa-ucm-conf already has sof-soundwire/tas2783.conf; overlay links to it"
    fi
    fw_mkdir_tracked "$AUDIO_UCM_OVERLAY_REL" || return 1
    _audio_ucm_merge "" || return 1
    # Our files, only where stock has nothing (stock wins once it catches up).
    for f in $(_audio_ucm_ours); do
        if [ -e "$stock/$f" ]; then
            continue
        fi
        fw_mkdir_tracked "$(dirname "$AUDIO_UCM_OVERLAY_REL/$f")" || return 1
        manifest_install_file "$AUDIO_UCM_SRC/$f" "$AUDIO_UCM_OVERLAY_REL/$f" audio 0644 shared || return 1
    done
    [ "$AX20_DRY_RUN" = 1 ] || _audio_ucm_prune
    # Only point user sessions at the overlay once it is complete.
    if [ "$AX20_DRY_RUN" != 1 ] && ! [ -e "$(ax20_path "$AUDIO_UCM_OVERLAY_REL/ucm.conf")" ]; then
        log_warn "UCM: overlay has no ucm.conf (stock tree incomplete?); not setting ALSA_CONFIG_UCM2"
        return 0
    fi
    manifest_install_file "$AX20_SRC/overlay/$AUDIO_ENV_SRC" "$AUDIO_ENV_REL" audio 0644 shared
}

# --------------------------------------------------------------- firmware --

_audio_firmware_apply() {
    if ! fw_fetch "${AX20_SPEAKER_SUPPLIER:-auto}"; then
        log_warn "TAS2783 firmware not installed (offline or checksum failure); speakers stay silent until the next apply succeeds"
    fi
    return 0
}

# _audio_sysfs_write <file> <value> : dry-run aware write to a sysfs knob.
_audio_sysfs_write() {
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] write "%s" to %s\n' "$2" "$1" >&2
        return 0
    fi
    printf '%s' "$2" >"$1"
}

# Live systems only: make the current boot find the files without waiting
# for the next reboot. Never overrides a path set by someone else.
_audio_fw_class_path_apply() {
    local p cur
    if [ -n "$AX20_ROOT" ]; then
        log_debug "firmware_class.path: fixture/slot root, not touching sysfs"
        return 0
    fi
    p=$(ax20_path "$AUDIO_FW_CLASS_PATH_REL")
    [ -w "$p" ] || return 0
    cur=$(cat "$p" 2>/dev/null || true)
    if [ -z "$cur" ]; then
        _audio_sysfs_write "$p" "$AUDIO_FW_REL" \
            || log_warn "could not set $AUDIO_FW_CLASS_PATH_REL"
    elif [ "$cur" != "$AUDIO_FW_REL" ]; then
        log_warn "firmware_class.path is already '$cur'; TAS2783 tuning in $AUDIO_FW_REL will not be found"
    fi
    return 0
}

# ------------------------------------------------------------------ ACPI --

_audio_acpi_apply() {
    local board staging rc f esp args
    board=$(cat "$(ax20_path /sys/class/dmi/id/board_name)" 2>/dev/null || true)
    if [ "$board" != "$AX20_BOARD" ]; then
        log_info "ACPI: board '${board:-unknown}' is not $AX20_BOARD; skipping the ACPI override"
        return 0
    fi
    if ! [ -x "$AUDIO_ACPI_TOOL" ] || ! ax20_have python3; then
        log_info "ACPI: override tool or python3 not available; ACPI step pending"
        return 0
    fi
    args=""
    if ! _audio_acpi_live_table >/dev/null; then
        # The repository fixture is only ever used against a fixture/VM root:
        # loading another firmware's table on real hardware could break the
        # boot.
        if [ -n "$AX20_ROOT" ] && [ -f "$AUDIO_ACPI_FIXTURE_TABLE" ]; then
            args="--table $AUDIO_ACPI_FIXTURE_TABLE"
        else
            log_info "ACPI: no readable ACPI table carries $AUDIO_ACPI_FLAG_NAME (not root, or BIOS already fixed); ACPI step pending"
            return 0
        fi
    fi
    if [ -z "$args" ] && _audio_acpi_current; then
        log_info "ACPI: override active and installed; nothing to do"
        _audio_acpi_boot_entry
        return 0
    fi
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] build ACPI override with %s, install %s\n' "$AUDIO_ACPI_TOOL" "$AUDIO_ESP_IMG_REL" >&2
        return 0
    fi
    staging=$(mktemp -d "${TMPDIR:-/tmp}/ax20-acpi.XXXXXX") || return 0
    # Seed the tool's cache (it rebuilds from TABLE.orig.aml while our
    # override is active, and checks BUILD-INFO for BIOS changes).
    for f in TABLE.orig.aml TABLE.patched.aml BUILD-INFO; do
        [ -f "$(ax20_path "$AUDIO_ACPI_STATE_REL/$f")" ] && cp "$(ax20_path "$AUDIO_ACPI_STATE_REL/$f")" "$staging/$f"
    done
    # shellcheck disable=SC2086  # args is either empty or "--table <path>"
    AX20_ROOT="$AX20_ROOT" "$AUDIO_ACPI_TOOL" --out "$staging" $args >/dev/null
    rc=$?
    case "$rc" in
        0) ;;
        3)
            log_info "ACPI: acp-audio-config-flag already cleared by the BIOS; no override needed"
            # The kernel still has to find the amp firmware under our path.
            if declare -F slot_set_cmdline_args >/dev/null 2>&1; then
                slot_set_cmdline_args "${AX20_SLOT:-active}" "$(audio_kernel_cmdline)" \
                    || log_warn "ACPI: kernel args not updated (see message above)"
            fi
            rm -rf "$staging"
            return 0
            ;;
        5)
            log_warn "ACPI: the BIOS changed since the saved original table was dumped; boot once without the override (uninstall the audio component or remove the early initrd from the boot entry), then apply again"
            rm -rf "$staging"
            return 0
            ;;
        *)
            log_warn "ACPI: override build failed (exit $rc); keeping any previous override"
            rm -rf "$staging"
            return 0
            ;;
    esac
    if ! [ -s "$staging/$AUDIO_ACPI_IMG_NAME" ]; then
        log_warn "ACPI: tool produced no $AUDIO_ACPI_IMG_NAME"
        rm -rf "$staging"
        return 0
    fi
    for f in "$AUDIO_ACPI_IMG_NAME" TABLE.patched.aml TABLE.orig.aml BUILD-INFO; do
        [ -f "$staging/$f" ] || continue
        manifest_install_file "$staging/$f" "$AUDIO_ACPI_STATE_REL/$f" audio 0644 shared
    done
    esp=$(ax20_path "$AUDIO_ESP_DIR_REL")
    if [ -d "$esp" ]; then
        manifest_install_file "$staging/$AUDIO_ACPI_IMG_NAME" "$AUDIO_ESP_IMG_REL" audio 0644 esp
        _audio_acpi_boot_entry
    else
        log_warn "ACPI: $AUDIO_ESP_DIR_REL not present (ESP not mounted?); image kept in $AUDIO_ACPI_STATE_REL"
    fi
    rm -rf "$staging"
    return 0
}

# _audio_acpi_current : the live table is our patched table and the ESP image
# still verifies, so a rebuild would change nothing.
_audio_acpi_current() {
    local patched table
    patched=$(ax20_path "$AUDIO_ACPI_STATE_REL/TABLE.patched.aml")
    [ -f "$patched" ] || return 1
    table=$(_audio_acpi_live_table) || return 1
    cmp -s "$table" "$patched" || return 1
    manifest_verify "$AUDIO_ESP_IMG_REL" >/dev/null 2>&1
}

_audio_acpi_boot_entry() {
    if declare -F slot_set_early_initrd >/dev/null 2>&1; then
        slot_set_early_initrd "${AX20_SLOT:-active}" "$AUDIO_ESP_IMG_REL" "$(audio_kernel_cmdline)" \
            || log_warn "ACPI: boot entry not updated (see message above); the update component re-applies it on the next apply"
    else
        log_info "ACPI: boot entry step pending (lib/slots.sh slot_set_early_initrd not available)"
    fi
}
