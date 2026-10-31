# SPDX-License-Identifier: GPL-2.0-only
# lib/slots.sh — SteamOS A/B slots and the boot-entry exception (plan §4,
# §5.2 rule 3a and rule 9).
#
# What SteamOS actually looks like (researched; see docs/update-survival.md):
#
#   esp       shared   /esp     stage-1 chainloader (steamcl.efi) and the
#                               per-image bootconf files /esp/SteamOS/conf/{A,B}.conf
#                               (managed by steamos-bootconf; no kernel cmdline in them)
#   efi-A/B   per slot /efi     stage-2 GRUB: /efi/EFI/steamos/{grubx64.efi,grub.cfg}
#   rootfs-A/B per slot /       read-only image; kernel + initramfs live in /boot here
#   var-A/B   per slot /var     NOT shared. RAUC's stock post-install rsyncs the
#                               booted /var into the other slot's var (minus a few
#                               excludes) before the reboot. /etc is an overlay
#                               whose upper dir is /var/lib/overlays/etc/upper.
#   home      shared   /home
#
#   /dev/disk/by-partsets/{A,B,self,other,shared}/<part> are udev symlinks
#   to the partitions above.
#
# The "boot entry" we modify is therefore the stage-2 grub.cfg on the slot's
# own efi partition (format "grub"). Its menuentry looks like
#   steamenv_boot linux /boot/vmlinuz-linux-neptune console=tty1 ...
#   initrd /boot/amd-ucode.img /boot/initramfs-linux-neptune.img
# A systemd-boot/BLS layout (/esp/loader/entries/*.conf, format "bls") is
# also understood, because the plan assumed it and it costs little; stock
# SteamOS does not use it.
#
# Edit contract (rule 9):
#   * the unmodified entry is saved to backup/<slot>/ with its sha256 before
#     the first change, and refreshed whenever we find it unmodified again
#     (e.g. after steamos-finalize-install regenerated it);
#   * our change is reversible by construction: we prepend marker comments
#     and only append cmdline args / insert one initrd token. Before writing,
#     the rendered file is stripped again in memory and must reproduce the
#     original byte-for-byte, otherwise nothing is written;
#   * writes go to a temp file on the same filesystem, then rename;
#   * the early initrd is validated (exists, non-empty, newc cpio) before
#     the entry points at it;
#   * restore uses the hash-verified backup; without a usable backup the
#     original is regenerated from the marker data ("template" = the entry
#     minus our deterministic edits).

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"

SLOTS_BACKUP_REL="${AX20_STATE_REL}/backup"
SLOTS_DESIRED_REL="${AX20_STATE_REL}/state/boot-entry.conf"
SLOTS_GRUB_CFG_REL="/efi/EFI/steamos/grub.cfg"
SLOTS_GRUB_DIR_REL="/efi/EFI/steamos"
SLOTS_BLS_DIR_REL="/esp/loader/entries"
SLOTS_PARTSETS_REL="/dev/disk/by-partsets"
SLOTS_MARK="# ${AX20_NAME}"

# ------------------------------------------------------------ slot naming --

# slots_valid_name <name> : A or B (SteamOS also has "dev", which we never touch).
slots_valid_name() {
    case "$1" in A | B) return 0 ;; esac
    return 1
}

# slots_other <A|B>
slots_other() {
    case "$1" in
        A) printf 'B\n' ;;
        B) printf 'A\n' ;;
        *) die "not an A/B slot: '$1'" ;;
    esac
}

# _slots_link <set> <part> : readlink of a partset symlink (empty if absent).
_slots_link() {
    local l
    l=$(ax20_path "$SLOTS_PARTSETS_REL/$1/$2")
    [ -L "$l" ] || return 1
    readlink "$l"
}

# slots_active : print A or B for the booted slot.
# Order: AX20_SLOT override (tests, and the RAUC handler operating on a
# mounted other slot) -> /dev/disk/by-partsets self vs A/B -> steamos-bootconf
# this-image (live system only).
slots_active() {
    local self part a b out
    if [ -n "${AX20_SLOT:-}" ]; then
        slots_valid_name "$AX20_SLOT" || die "AX20_SLOT must be A or B, got '$AX20_SLOT'"
        printf '%s\n' "$AX20_SLOT"
        return 0
    fi
    for part in rootfs efi var; do
        self=$(_slots_link self "$part") || continue
        a=$(_slots_link A "$part" || true)
        b=$(_slots_link B "$part" || true)
        if [ -n "$a" ] && [ "$self" = "$a" ]; then
            printf 'A\n'
            return 0
        fi
        if [ -n "$b" ] && [ "$self" = "$b" ]; then
            printf 'B\n'
            return 0
        fi
    done
    if [ -z "$AX20_ROOT" ] && ax20_have steamos-bootconf; then
        out=$(steamos-bootconf this-image 2>/dev/null || true)
        if slots_valid_name "$out"; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    log_debug "cannot determine the active slot"
    return 1
}

# slots_inactive : the slot an update would be written to.
slots_inactive() {
    local a
    a=$(slots_active) || return 1
    slots_other "$a"
}

# ------------------------------------------------------- entry discovery --

# slots_entry_path <slot> : root-relative path of the slot's boot entry.
# AX20_BOOT_ENTRY overrides (tests, unusual layouts). For grub the entry is
# the cfg on the efi partition mounted at /efi under AX20_ROOT, which is the
# slot's own efi both on the booted system and inside a composite slot root
# built by slots_mount_composite.
slots_entry_path() {
    local slot=$1 f
    slots_valid_name "$slot" || die "slots_entry_path: bad slot '$slot'"
    if [ -n "${AX20_BOOT_ENTRY:-}" ]; then
        printf '%s\n' "$AX20_BOOT_ENTRY"
        return 0
    fi
    if [ -f "$(ax20_path "$SLOTS_GRUB_CFG_REL")" ]; then
        printf '%s\n' "$SLOTS_GRUB_CFG_REL"
        return 0
    fi
    for f in "$(ax20_path "$SLOTS_BLS_DIR_REL")"/*-"$slot".conf "$(ax20_path "$SLOTS_BLS_DIR_REL")"/*_"$slot".conf; do
        if [ -f "$f" ]; then
            printf '%s\n' "${f#"$AX20_ROOT"}"
            return 0
        fi
    done
    return 1
}

# slots_entry_format <root-relative-path> : grub | bls
slots_entry_format() {
    case "$1" in
        *.cfg) printf 'grub\n' ;;
        *.conf) printf 'bls\n' ;;
        *) die "unknown boot entry format: $1" ;;
    esac
}

# slots_entry_is_modified <real-file>
slots_entry_is_modified() {
    grep -q "^${SLOTS_MARK}-args:" "$1" 2>/dev/null
}

# _slots_mark_get <real-file> <key>
_slots_mark_get() {
    sed -n "s/^${SLOTS_MARK}-$2: //p" "$1" | head -n1
}

# ------------------------------------------------------------ initrd -----

# slots_initrd_validate <abs-path> : the early initrd must exist, be
# non-empty and be an uncompressed newc cpio (the kernel only scans those for
# ACPI table upgrades).
slots_initrd_validate() {
    local f magic
    f=$(ax20_path "$1")
    [ -f "$f" ] || {
        log_error "early initrd missing: $1"
        return 1
    }
    [ -s "$f" ] || {
        log_error "early initrd is empty: $1"
        return 1
    }
    magic=$(dd if="$f" bs=6 count=1 2>/dev/null)
    case "$magic" in
        070701 | 070702) return 0 ;;
    esac
    log_error "early initrd is not an uncompressed newc cpio: $1"
    return 1
}

# slots_initrd_ref <format> <abs-path> : how the entry refers to the initrd.
#   grub: files on the slot's efi partition are addressed through GRUB's
#         $cmdpath (the directory grubx64.efi was loaded from); the menuentry
#         sets root to the rootfs, so a plain path would not resolve.
#         TODO(vm): confirm $cmdpath is "(hdX,gptN)/EFI/steamos" under steamcl.
#   bls:  paths are relative to the ESP root.
slots_initrd_ref() {
    local fmt=$1 p=$2
    case "$fmt" in
        grub)
            case "$p" in
                "$SLOTS_GRUB_DIR_REL"/*) printf '%s/%s\n' "\${cmdpath}" "${p#"$SLOTS_GRUB_DIR_REL"/}" ;;
                *) die "early initrd must live in $SLOTS_GRUB_DIR_REL for a grub entry: $p" ;;
            esac
            ;;
        bls)
            case "$p" in
                /esp/*) printf '%s\n' "${p#/esp}" ;;
                *) die "early initrd must live on the ESP for a BLS entry: $p" ;;
            esac
            ;;
        *) die "unknown entry format $fmt" ;;
    esac
}

# --------------------------------------------------------- render / strip --

# _slots_render <format> <real-file> <args> <initrd-ref> <orig-sha> <slot>
# Print the modified entry. Fails (rc 1) if no kernel line was found.
_slots_render() {
    local fmt=$1 f=$2 args=$3 ref=$4 sha=$5 slot=$6 noeol=0
    [ -n "$(tail -c1 "$f")" ] && noeol=1
    printf '%s: boot entry modified by %s (plan §5.2 rule 3a); original saved in %s/%s/\n' \
        "$SLOTS_MARK" "$AX20_NAME" "$SLOTS_BACKUP_REL" "$slot"
    printf '%s-args: %s\n' "$SLOTS_MARK" "$args"
    printf '%s-initrd: %s\n' "$SLOTS_MARK" "$ref"
    printf '%s-noeol: %s\n' "$SLOTS_MARK" "$noeol"
    printf '%s-orig-sha256: %s\n' "$SLOTS_MARK" "$sha"
    awk -v fmt="$fmt" -v args="$args" -v ref="$ref" '
        function kw(n) { return (NF >= n) ? $n : "" }
        {
            line = $0
            if (fmt == "grub") {
                if (kw(1) == "linux" || kw(1) == "linuxefi" || kw(2) == "linux" || kw(2) == "linuxefi") {
                    if (args != "") line = line " " args
                    kernels++
                } else if (ref != "" && (kw(1) == "initrd" || kw(1) == "initrdefi" || kw(2) == "initrd" || kw(2) == "initrdefi")) {
                    k = (kw(1) ~ /^initrd/) ? kw(1) : kw(2)
                    i = index(line, k)
                    rest = substr(line, i + length(k))
                    match(rest, /^[ \t]+/)
                    line = substr(line, 1, i + length(k) - 1) substr(rest, 1, RLENGTH) ref " " substr(rest, RLENGTH + 1)
                    initrds++
                }
            } else {
                if (kw(1) == "options") {
                    if (args != "") line = line " " args
                    kernels++
                } else if (kw(1) == "linux") {
                    kernels++
                } else if (ref != "" && kw(1) == "initrd" && !done) {
                    print "initrd " ref
                    done = 1
                }
            }
            print line
        }
        END {
            if (!kernels) exit 1
            if (ref != "" && fmt == "bls" && !done) print "initrd " ref
            if (ref != "" && fmt == "grub" && !initrds) exit 2
        }
    ' "$f"
}

# _slots_strip <real-file> : print the entry without our edits.
_slots_strip() {
    local f=$1 fmt args ref noeol tmp
    args=$(_slots_mark_get "$f" args)
    ref=$(_slots_mark_get "$f" initrd)
    noeol=$(_slots_mark_get "$f" noeol)
    fmt=${2:-grub}
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-strip.XXXXXX")
    awk -v fmt="$fmt" -v args="$args" -v ref="$ref" -v mark="$SLOTS_MARK" '
        function kw(n) { return (NF >= n) ? $n : "" }
        function endswith(s, t) { return length(t) > 0 && length(s) >= length(t) && substr(s, length(s) - length(t) + 1) == t }
        index($0, mark ":") == 1 || index($0, mark "-") == 1 { next }
        {
            line = $0
            if (fmt == "grub") {
                if ((kw(1) ~ /^linux(efi)?$/ || kw(2) ~ /^linux(efi)?$/) && args != "" && endswith(line, " " args)) {
                    line = substr(line, 1, length(line) - length(args) - 1)
                } else if (ref != "" && (kw(1) ~ /^initrd(efi)?$/ || kw(2) ~ /^initrd(efi)?$/)) {
                    i = index(line, ref " ")
                    if (i > 0) line = substr(line, 1, i - 1) substr(line, i + length(ref) + 1)
                }
            } else {
                if (kw(1) == "options" && args != "" && endswith(line, " " args)) {
                    line = substr(line, 1, length(line) - length(args) - 1)
                } else if (ref != "" && line == "initrd " ref && !done) {
                    done = 1
                    next
                }
            }
            print line
        }
    ' "$f" >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    if [ "$noeol" = 1 ]; then
        # The original had no final newline; drop the one awk added.
        printf '%s' "$(cat "$tmp")"
    else
        cat "$tmp"
    fi
    rm -f "$tmp"
}

# _slots_write <real-dest> : stdin -> temp file next to dest -> rename.
# No chmod: the ESP/efi partitions are vfat. sync so a power cut right
# after an update cannot leave a half-written entry.
_slots_write() {
    local dest=$1 tmp
    if [ "$AX20_DRY_RUN" = 1 ]; then
        cat >/dev/null
        printf '[dry-run] write %s\n' "$dest" >&2
        return 0
    fi
    tmp="${dest}.${AX20_NAME}.tmp"
    if ! cat >"$tmp"; then
        rm -f "$tmp"
        log_error "cannot write $tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$dest"; then
        rm -f "$tmp"
        log_error "cannot rename into $dest"
        return 1
    fi
    if ax20_have sync; then sync 2>/dev/null || true; fi
    return 0
}

# --------------------------------------------------------------- backup --

slots_backup_dir() { ax20_path "$SLOTS_BACKUP_REL/$1"; }

# slots_backup_file <slot> : real path of the saved original (may not exist).
slots_backup_file() {
    local rel
    rel=$(slots_entry_path "$1") || return 1
    printf '%s/%s\n' "$(slots_backup_dir "$1")" "$(basename "$rel")"
}

# slots_backup_valid <slot> : backup exists and matches its recorded sha256.
slots_backup_valid() {
    local b
    b=$(slots_backup_file "$1") || return 1
    [ -f "$b" ] && [ -f "$b.sha256" ] || return 1
    [ "$(ax20_sha256 "$b")" = "$(cat "$b.sha256")" ]
}

# slots_entry_save <slot> : save the current, unmodified entry. Refuses to
# save an entry that carries our marker (that would not be the original).
# Idempotent; refreshes the backup when the stock entry changed.
slots_entry_save() {
    local slot=$1 rel real b dir
    rel=$(slots_entry_path "$slot") || die "no boot entry found for slot $slot"
    real=$(ax20_path "$rel")
    [ -f "$real" ] || die "boot entry missing: $rel"
    slots_entry_is_modified "$real" && die "refusing to back up $rel: it already carries $AX20_NAME changes"
    b=$(slots_backup_file "$slot")
    if [ -f "$b" ] && cmp -s "$real" "$b" && slots_backup_valid "$slot"; then
        return 0
    fi
    dir=$(dirname "$b")
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] save %s -> %s\n' "$rel" "$b" >&2
        return 0
    fi
    mkdir -p "$dir"
    cp -p "$real" "$b.tmp" && mv -f "$b.tmp" "$b"
    ax20_sha256 "$b" >"$b.sha256"
    printf '%s\n' "$rel" >"$dir/entry-path"
    log_info "saved original boot entry of slot $slot to ${b#"$AX20_ROOT"}"
}

# ------------------------------------------------------------ apply/restore --

# slots_entry_apply <slot> <args> [initrd-abs-path]
# Make the slot's entry carry <args> (appended to the kernel line) and the
# early initrd (first initrd). Idempotent: an entry that already carries the
# same change is left alone; a different earlier change is replaced.
slots_entry_apply() {
    local slot=$1 args=$2 initrd=${3:-} rel real fmt ref="" sha cur tmpd
    rel=$(slots_entry_path "$slot") || die "no boot entry found for slot $slot"
    real=$(ax20_path "$rel")
    [ -f "$real" ] || die "boot entry missing: $rel"
    fmt=$(slots_entry_format "$rel") || die "unsupported boot entry: $rel"
    if [ -n "$initrd" ]; then
        slots_initrd_validate "$initrd" || die "not pointing the boot entry at an invalid initrd"
        ref=$(slots_initrd_ref "$fmt" "$initrd") || die "unusable early initrd location: $initrd"
    fi
    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/ax20-slots.XXXXXX")
    # Work from the original: strip an existing change first.
    if slots_entry_is_modified "$real"; then
        if [ "$(_slots_mark_get "$real" args)" = "$args" ] && [ "$(_slots_mark_get "$real" initrd)" = "$ref" ]; then
            rm -rf "$tmpd"
            log_debug "boot entry of slot $slot already up to date"
            return 0
        fi
        _slots_strip "$real" "$fmt" >"$tmpd/orig" || {
            rm -rf "$tmpd"
            die "cannot strip existing change from $rel"
        }
    else
        slots_entry_save "$slot"
        cp "$real" "$tmpd/orig"
    fi
    sha=$(ax20_sha256 "$tmpd/orig")
    if ! _slots_render "$fmt" "$tmpd/orig" "$args" "$ref" "$sha" "$slot" >"$tmpd/new"; then
        rm -rf "$tmpd"
        die "no kernel/initrd line found in $rel; refusing to modify an unrecognised boot entry"
    fi
    # Reversibility self-check before anything touches the real entry.
    _slots_strip "$tmpd/new" "$fmt" >"$tmpd/check" || true
    if ! cmp -s "$tmpd/orig" "$tmpd/check"; then
        rm -rf "$tmpd"
        die "internal error: modified boot entry would not strip back to the original; not writing"
    fi
    cur=$(ax20_sha256 "$real")
    _slots_write "$real" <"$tmpd/new" || {
        rm -rf "$tmpd"
        die "writing $rel failed (previous content sha256 $cur is unchanged)"
    }
    rm -rf "$tmpd"
    log_info "boot entry of slot $slot updated ($rel)"
}

# slots_entry_restore <slot> : put back the original. Returns 0 when the
# entry is (now) unmodified.
slots_entry_restore() {
    local slot=$1 rel real fmt b tmpd want
    rel=$(slots_entry_path "$slot") || {
        log_warn "no boot entry found for slot $slot; nothing to restore"
        return 0
    }
    real=$(ax20_path "$rel")
    [ -f "$real" ] || die "boot entry missing: $rel"
    slots_entry_is_modified "$real" || return 0
    fmt=$(slots_entry_format "$rel") || die "unsupported boot entry: $rel"
    b=$(slots_backup_file "$slot")
    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/ax20-slots.XXXXXX")
    _slots_strip "$real" "$fmt" >"$tmpd/stripped" || true
    want=$(_slots_mark_get "$real" orig-sha256)
    if slots_backup_valid "$slot"; then
        if [ -n "$want" ] && [ "$(ax20_sha256 "$b")" != "$want" ]; then
            # The backup predates a stock regeneration of the entry; the
            # stripped current entry is the faithful original.
            log_warn "saved boot entry for slot $slot is older than the current one; regenerating instead"
            _slots_write "$real" <"$tmpd/stripped" || die "restore of $rel failed"
        else
            _slots_write "$real" <"$b" || die "restore of $rel failed"
            log_info "restored original boot entry of slot $slot from backup (sha256 verified)"
        fi
    else
        log_warn "no valid backup for slot $slot; regenerating the original entry from the template"
        _slots_write "$real" <"$tmpd/stripped" || die "restore of $rel failed"
        if [ -n "$want" ] && [ "$AX20_DRY_RUN" != 1 ] && [ "$(ax20_sha256 "$real")" != "$want" ]; then
            log_warn "regenerated entry for slot $slot differs from the recorded original digest"
        fi
    fi
    rm -rf "$tmpd"
    return 0
}

# ------------------------------------------------------- desired state --
# The audio component (ACPI override) declares what the boot entry should
# carry; the update component reconciles it on every apply (booted slot,
# post-install for the new slot, boot service). Format: shell-free
# key=value lines, args on one line.

slots_desired_file() { ax20_path "$SLOTS_DESIRED_REL"; }

# slots_desired_set <args> [initrd-abs-path]
slots_desired_set() {
    local f
    f=$(slots_desired_file)
    [ "$AX20_DRY_RUN" = 1 ] || mkdir -p "$(dirname "$f")"
    printf 'args=%s\ninitrd=%s\n' "$1" "${2:-}" | ax20_atomic_write "$f" 0644
}

# slots_desired_get <args|initrd>
slots_desired_get() {
    local f
    f=$(slots_desired_file)
    [ -f "$f" ] || return 1
    sed -n "s/^$1=//p" "$f" | head -n1
}

slots_desired_clear() {
    local f
    f=$(slots_desired_file)
    [ -f "$f" ] || return 0
    ax20_run rm -f "$f"
}

# slots_entry_in_sync <slot> : the entry matches the desired state.
slots_entry_in_sync() {
    local slot=$1 rel real args initrd ref=""
    rel=$(slots_entry_path "$slot") || return 0
    real=$(ax20_path "$rel")
    if ! [ -f "$(slots_desired_file)" ]; then
        ! slots_entry_is_modified "$real"
        return
    fi
    slots_entry_is_modified "$real" || return 1
    args=$(slots_desired_get args)
    initrd=$(slots_desired_get initrd)
    if [ -n "$initrd" ]; then
        ref=$(slots_initrd_ref "$(slots_entry_format "$rel")" "$initrd") || return 1
    fi
    [ "$(_slots_mark_get "$real" args)" = "$args" ] && [ "$(_slots_mark_get "$real" initrd)" = "$ref" ]
}

# slots_entry_reconcile <slot> : apply the desired state, or restore when
# nothing is desired any more. Missing entry = nothing to do (not SteamOS).
slots_entry_reconcile() {
    local slot=$1 args initrd
    slots_entry_path "$slot" >/dev/null 2>&1 || {
        log_debug "no boot entry for slot $slot; skipping"
        return 0
    }
    if [ -f "$(slots_desired_file)" ]; then
        args=$(slots_desired_get args)
        initrd=$(slots_desired_get initrd)
        slots_entry_apply "$slot" "$args" "$initrd"
    else
        slots_entry_restore "$slot"
    fi
}

# slot_set_early_initrd <slot|active> <initrd-abs-path> [kernel-args]
# Compatibility entry point for components (the audio component's ACPI
# override): record the desired boot-entry state and reconcile the slot's
# entry. Existing desired args are kept unless new ones are given. Returns
# non-zero (never dies) when the slot or the initrd cannot be resolved, so a
# component can log and carry on.
slot_set_early_initrd() {
    local slot=$1 initrd=$2 args=${3:-}
    if [ "$slot" = active ] || [ -z "$slot" ]; then
        slot=$(slots_active 2>/dev/null) || {
            log_warn "boot entry: cannot determine the booted slot; run '$AX20_NAME boot-entry set --initrd $initrd' later"
            return 1
        }
    fi
    slots_valid_name "$slot" || return 1
    slots_initrd_validate "$initrd" || {
        log_warn "boot entry: $initrd is not a valid uncompressed cpio; not referencing it"
        return 1
    }
    [ -n "$args" ] || args=$(slots_desired_get args 2>/dev/null || true)
    slots_desired_set "$args" "$initrd"
    slots_entry_reconcile "$slot"
}

# slot_set_cmdline_args <slot|active> <args> : request kernel args without
# touching the desired early initrd (used when no ACPI override is needed
# but firmware_class.path still is). Non-fatal like slot_set_early_initrd.
slot_set_cmdline_args() {
    local slot=$1 args=$2 initrd
    if [ "$slot" = active ] || [ -z "$slot" ]; then
        slot=$(slots_active 2>/dev/null) || {
            log_warn "boot entry: cannot determine the booted slot; run '$AX20_NAME boot-entry set --arg $args' later"
            return 1
        }
    fi
    slots_valid_name "$slot" || return 1
    initrd=$(slots_desired_get initrd 2>/dev/null || true)
    slots_desired_set "$args" "$initrd"
    slots_entry_reconcile "$slot"
}

# ---------------------------------------------------- composite slot root --
# Used by the RAUC post-install handler: build a view of the *other* slot
# at <dir> that looks like its booted root, so `apply --slot <dir>` writes
# where the next boot reads:
#   <dir>        other rootfs, read-only
#   <dir>/var    other var (rw)
#   <dir>/etc    overlay: lower = rootfs /etc, upper = var/lib/overlays/etc/upper
#   <dir>/efi    other efi (rw, vfat)
#   <dir>/esp, /home, /opt   bind mounts of the shared ones
# TODO(vm): compare with what `steamos-chroot --partset other` mounts
# (rootfs subvolume/options, overlay workdir name) and switch to it if it
# can hand us a mount instead of a chroot.

# slots_mount_composite <slot> <dir>
slots_mount_composite() {
    local slot=$1 dir=$2 dev
    slots_valid_name "$slot" || die "slots_mount_composite: bad slot '$slot'"
    dev=$(ax20_path "$SLOTS_PARTSETS_REL/$slot")
    [ -e "$dev/rootfs" ] && [ -e "$dev/var" ] && [ -e "$dev/efi" ] \
        || die "partset symlinks for slot $slot not found under $SLOTS_PARTSETS_REL"
    ax20_run mkdir -p "$dir"
    ax20_run mount -o ro "$dev/rootfs" "$dir" || return 1
    ax20_run mount "$dev/var" "$dir/var" || {
        slots_umount_composite "$dir"
        return 1
    }
    ax20_run mkdir -p "$dir/var/lib/overlays/etc/upper" "$dir/var/lib/overlays/etc/work"
    ax20_run mount -t overlay overlay \
        -o "lowerdir=$dir/etc,upperdir=$dir/var/lib/overlays/etc/upper,workdir=$dir/var/lib/overlays/etc/work" \
        "$dir/etc" || {
        slots_umount_composite "$dir"
        return 1
    }
    ax20_run mount "$dev/efi" "$dir/efi" || {
        slots_umount_composite "$dir"
        return 1
    }
    ax20_run mount --bind "$(ax20_path /esp)" "$dir/esp" || true
    ax20_run mount --bind "$(ax20_path /home)" "$dir/home" || true
    ax20_run mount --bind "$(ax20_path /opt)" "$dir/opt" || true
    return 0
}

# slots_umount_composite <dir> : best effort, innermost first.
slots_umount_composite() {
    local dir=$1 m
    for m in opt home esp efi etc var ""; do
        if [ "$AX20_DRY_RUN" = 1 ]; then
            printf '[dry-run] umount %s\n' "$dir/$m" >&2
            continue
        fi
        if ax20_have mountpoint && mountpoint -q "$dir/$m" 2>/dev/null; then
            umount "$dir/$m" 2>/dev/null || umount -l "$dir/$m" 2>/dev/null || true
        fi
    done
}
