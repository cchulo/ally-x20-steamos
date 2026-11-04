# SPDX-License-Identifier: GPL-2.0-only
# lib/rauc.sh — register our RAUC handlers in /etc/rauc/system.conf
# (plan §4.6, §5.2 rule 3b: the second documented exception).
#
# RAUC reads exactly one system.conf (first of /etc/rauc, /run/rauc,
# /usr/lib/rauc) and has no conf.d, so registration needs a change to the
# stock file. The contract:
#   * the original is saved to backup/rauc/system.conf (+ .sha256) before
#     the first change, and refreshed whenever the stock file underneath
#     our blocks changed (a SteamOS update gives the new slot a fresh copy);
#   * the written file has exactly one [handlers] section and each key in
#     it once. RAUC's GKeyFile parser would merge a repeated group, but
#     steamos-atomupd-client (holoatomupd/client.py, get_rauc_config) reads
#     the same file with Python's configparser in strict mode, which
#     raises DuplicateSectionError and kills every `steamos-update` check.
#     So when the stock file has a [handlers] section our main block goes
#     right after its header, without a header of its own:
#         [handlers]
#         # >>> ally-x20-steamos managed block (sep=0); ...
#         # stock handlers are chained, see .../state/rauc-chain
#         pre-install=<our handler>
#         post-install=<our handler>
#         # <<< ally-x20-steamos
#     and each stock pre-install=/post-install= line of that section is
#     replaced in place by a small block that carries the original line as
#     a comment:
#         # >>> ally-x20-steamos stock handler, chained by the block above
#         #ally-x20-steamos-orig:post-install=/usr/lib/rauc/post-install.sh
#         # <<< ally-x20-steamos
#     When the stock file has no [handlers] section, one block carrying the
#     header is appended at the end (sep=1 in the begin line means the
#     original had no final newline). Stripping drops the block lines and
#     puts the #ally-x20-steamos-orig: lines back without the prefix, so
#     the result is the original byte-for-byte;
#   * any handler the stock file already defines is recorded in
#     state/rauc-chain and executed by our handlers (chaining, never
#     replacing). SteamOS defines post-install=/usr/lib/rauc/post-install.sh
#     (per icedream/steamos-permanent-mods), which rsyncs /var into the new
#     slot and re-installs GRUB there;
#   * registration renders the file from the stripped original and writes
#     only when the live file differs, so an older layout (block appended
#     at the end with a second [handlers]) is migrated by the next apply;
#   * removal restores the saved original byte-for-byte after verifying its
#     hash; if that is impossible the blocks are stripped instead, which is
#     byte-identical by construction. uninstall/uninstall.sh does the same
#     strip without this library.
#
# Note: SteamOS's post-install rsync excludes var/lib/overlays/etc/upper/rauc,
# so the new slot boots with a stock system.conf. The post-install handler
# re-registers into the new slot, and the boot service repairs it if not.

# shellcheck source=lib/common.sh
. "${AX20_SRC:-$(dirname "${BASH_SOURCE[0]}")/..}/lib/common.sh"

RAUC_CONF_REL="/etc/rauc/system.conf"
RAUC_BACKUP_REL="${AX20_STATE_REL}/backup/rauc/system.conf"
RAUC_CHAIN_REL="${AX20_STATE_REL}/state/rauc-chain"
RAUC_LIBEXEC_REL="${AX20_STATE_REL}/libexec"
RAUC_PRE_HANDLER_REL="${RAUC_LIBEXEC_REL}/rauc-pre-install.hook"
RAUC_POST_HANDLER_REL="${RAUC_LIBEXEC_REL}/rauc-post-install.hook"
RAUC_BEGIN="# >>> ${AX20_NAME}"
RAUC_END="# <<< ${AX20_NAME}"
# A stock handler line kept inside one of our blocks, prefix removed on strip.
RAUC_ORIG="#${AX20_NAME}-orig:"

rauc_conf_file() { ax20_path "$RAUC_CONF_REL"; }
rauc_backup_file() { ax20_path "$RAUC_BACKUP_REL"; }
rauc_chain_file() { ax20_path "$RAUC_CHAIN_REL"; }

# rauc_block_present [file]
rauc_block_present() {
    local f=${1:-$(rauc_conf_file)}
    [ -f "$f" ] && grep -Fq -- "$RAUC_BEGIN" "$f"
}

# rauc_strip_block <file> : print the file without our blocks; stock handler
# lines we commented out come back as they were. If the original had no
# final newline (begin line says "sep=1") the last newline is dropped too.
rauc_strip_block() {
    local f=$1 tmp rc=0
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-rauc.XXXXXX")
    awk -v b="$RAUC_BEGIN" -v e="$RAUC_END" -v p="$RAUC_ORIG" '
        index($0, b) == 1 { inblk = 1; if (index($0, "sep=1")) sep = 1; next }
        inblk && index($0, e) == 1 { inblk = 0; next }
        inblk && index($0, p) == 1 { print substr($0, length(p) + 1); next }
        inblk { next }
        { print }
        END { if (sep) exit 3 }
    ' "$f" >"$tmp" || rc=$?
    if [ "$rc" -eq 3 ]; then
        printf '%s' "$(cat "$tmp")"
    else
        cat "$tmp"
    fi
    rm -f "$tmp"
}

# rauc_handler_value <file> <key> : value of <key> in the stock [handlers]
# section (our blocks stripped first), last occurrence wins (GKeyFile
# semantics). Empty if unset.
rauc_handler_value() {
    local f=$1 key=$2
    [ -f "$f" ] || return 0
    rauc_strip_block "$f" | awk -v key="$key" '
        /^[ \t]*\[/ { g = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", g); next }
        g == "handlers" {
            line = $0
            sub(/^[ \t]+/, "", line)
            n = index(line, "=")
            if (n == 0) next
            k = substr(line, 1, n - 1); sub(/[ \t]+$/, "", k)
            if (k != key) next
            v = substr(line, n + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
            val = v
        }
        END { if (val != "") print val }
    '
}

# _rauc_resolve <value> : handler paths may be relative to system.conf's dir.
_rauc_resolve() {
    case "$1" in
        '') ;;
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$(dirname "$RAUC_CONF_REL")" "$1" ;;
    esac
}

# _rauc_has_handlers <file> : the stock file defines a [handlers] section.
_rauc_has_handlers() {
    grep -Eq '^[ \t]*\[handlers\][ \t]*$' "$1"
}

# rauc_render_block <pre-handler> <post-handler> <sep:0|1> [with-header:0|1]
# The main block; with-header=1 adds the [handlers] line (appended layout).
rauc_render_block() {
    [ "$3" = 1 ] && [ "${4:-1}" = 1 ] && printf '\n'
    printf '%s managed block (sep=%s); original saved as %s; remove with "%s uninstall"\n' \
        "$RAUC_BEGIN" "$3" "$RAUC_BACKUP_REL" "$AX20_NAME"
    printf '# stock handlers are chained, see %s\n' "$RAUC_CHAIN_REL"
    [ "${4:-1}" = 1 ] && printf '[handlers]\n'
    printf 'pre-install=%s\n' "$1"
    printf 'post-install=%s\n' "$2"
    printf '%s\n' "$RAUC_END"
}

# rauc_render <original-file> <pre-handler> <post-handler> : the registered
# file for this original, on stdout.
rauc_render() {
    local orig=$1 pre=$2 post=$3 sep=0
    [ -s "$orig" ] && [ -n "$(tail -c1 "$orig")" ] && sep=1
    if ! _rauc_has_handlers "$orig"; then
        cat "$orig"
        rauc_render_block "$pre" "$post" "$sep" 1
        return 0
    fi
    # ENVIRON instead of -v: awk would interpret backslashes in -v values.
    AX20_RAUC_MAIN=$(rauc_render_block "$pre" "$post" "$sep" 0) \
    AX20_RAUC_STOCK_BEGIN="$RAUC_BEGIN stock handler, chained by the block above" \
    AX20_RAUC_END="$RAUC_END" AX20_RAUC_ORIG="$RAUC_ORIG" \
        awk '
        /^[ \t]*\[/ {
            g = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", g)
            print
            if (g == "handlers" && !done) { print ENVIRON["AX20_RAUC_MAIN"]; done = 1 }
            next
        }
        g == "handlers" {
            line = $0
            sub(/^[ \t]+/, "", line)
            n = index(line, "=")
            if (n) {
                k = substr(line, 1, n - 1); sub(/[ \t]+$/, "", k)
                if (k == "pre-install" || k == "post-install") {
                    print ENVIRON["AX20_RAUC_STOCK_BEGIN"]
                    print ENVIRON["AX20_RAUC_ORIG"] $0
                    print ENVIRON["AX20_RAUC_END"]
                    next
                }
            }
        }
        { print }
    ' "$orig"
}

# rauc_registered [pre] [post] : our block is present and the live file is
# exactly what we would write for the stock file underneath it, so an older
# layout counts as not registered and gets migrated.
rauc_registered() {
    local f pre=${1:-$RAUC_PRE_HANDLER_REL} post=${2:-$RAUC_POST_HANDLER_REL} tmpd rc=0
    f=$(rauc_conf_file)
    rauc_block_present "$f" || return 1
    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/ax20-rauc.XXXXXX")
    rauc_strip_block "$f" >"$tmpd/orig"
    rauc_render "$tmpd/orig" "$pre" "$post" >"$tmpd/new"
    cmp -s "$f" "$tmpd/new" || rc=1
    rm -rf "$tmpd"
    return "$rc"
}

# rauc_backup_valid : saved original exists and matches its digest.
rauc_backup_valid() {
    local b
    b=$(rauc_backup_file)
    [ -f "$b" ] && [ -f "$b.sha256" ] && [ "$(ax20_sha256 "$b")" = "$(cat "$b.sha256")" ]
}

# rauc_chain_get <pre-install|post-install> : the stock handler to chain.
rauc_chain_get() {
    local f
    f=$(rauc_chain_file)
    [ -f "$f" ] || return 0
    sed -n "s/^$1=//p" "$f" | head -n1
}

# _rauc_write_chain <original-file> <pre> <post>
_rauc_write_chain() {
    local orig=$1 ours_pre=$2 ours_post=$3 pre post f
    pre=$(_rauc_resolve "$(rauc_handler_value "$orig" pre-install)")
    post=$(_rauc_resolve "$(rauc_handler_value "$orig" post-install)")
    # Never chain to ourselves (would recurse).
    [ "$pre" = "$ours_pre" ] && pre=""
    [ "$post" = "$ours_post" ] && post=""
    f=$(rauc_chain_file)
    [ "$AX20_DRY_RUN" = 1 ] || mkdir -p "$(dirname "$f")"
    printf 'pre-install=%s\npost-install=%s\n' "$pre" "$post" | ax20_atomic_write "$f" 0644
}

# rauc_register [pre-handler] [post-handler] : idempotent.
rauc_register() {
    local pre=${1:-$RAUC_PRE_HANDLER_REL} post=${2:-$RAUC_POST_HANDLER_REL}
    local f b tmpd
    f=$(rauc_conf_file)
    if ! [ -f "$f" ]; then
        log_warn "$RAUC_CONF_REL not found; not a SteamOS root? skipping RAUC registration"
        return 0
    fi
    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/ax20-rauc.XXXXXX")
    if rauc_block_present "$f"; then
        rauc_strip_block "$f" >"$tmpd/orig"
    else
        cp "$f" "$tmpd/orig"
    fi
    # Save / refresh the original.
    b=$(rauc_backup_file)
    if ! { [ -f "$b" ] && cmp -s "$b" "$tmpd/orig" && rauc_backup_valid; }; then
        if [ "$AX20_DRY_RUN" = 1 ]; then
            printf '[dry-run] save %s -> %s\n' "$RAUC_CONF_REL" "$RAUC_BACKUP_REL" >&2
        else
            mkdir -p "$(dirname "$b")"
            cp "$tmpd/orig" "$b.tmp" && mv -f "$b.tmp" "$b"
            ax20_sha256 "$b" >"$b.sha256"
            log_info "saved original $RAUC_CONF_REL to $RAUC_BACKUP_REL"
        fi
    fi
    _rauc_write_chain "$tmpd/orig" "$pre" "$post"
    rauc_render "$tmpd/orig" "$pre" "$post" >"$tmpd/new"
    if cmp -s "$f" "$tmpd/new"; then
        rm -rf "$tmpd"
        return 0
    fi
    # Self-check: stripping must give the original back.
    rauc_strip_block "$tmpd/new" >"$tmpd/check"
    if ! cmp -s "$tmpd/orig" "$tmpd/check"; then
        rm -rf "$tmpd"
        die "internal error: rauc block would not strip back to the original; not writing"
    fi
    ax20_atomic_write "$f" 0644 <"$tmpd/new"
    rm -rf "$tmpd"
    log_info "registered RAUC handlers in $RAUC_CONF_REL"
    _rauc_reload
}

# rauc_unregister : restore the original. Idempotent.
rauc_unregister() {
    local f b tmpd
    f=$(rauc_conf_file)
    if ! rauc_block_present "$f"; then
        ax20_run rm -f "$(rauc_chain_file)"
        return 0
    fi
    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/ax20-rauc.XXXXXX")
    rauc_strip_block "$f" >"$tmpd/stripped"
    b=$(rauc_backup_file)
    if rauc_backup_valid && cmp -s "$b" "$tmpd/stripped"; then
        ax20_atomic_write "$f" 0644 <"$b"
        log_info "restored original $RAUC_CONF_REL from backup (sha256 verified)"
    else
        if rauc_backup_valid; then
            log_warn "saved $RAUC_CONF_REL differs from the stock file under our block (SteamOS updated it); removing only our block"
        else
            log_warn "no valid backup of $RAUC_CONF_REL; removing only our block"
        fi
        ax20_atomic_write "$f" 0644 <"$tmpd/stripped"
    fi
    rm -rf "$tmpd"
    ax20_run rm -f "$(rauc_chain_file)"
    _rauc_reload
}

# _rauc_reload : RAUC reads system.conf at service start.
# TODO(vm): check whether SteamOS starts rauc.service on demand (D-Bus
# activation) so that try-restart is enough and never interrupts an install.
_rauc_reload() {
    [ -z "$AX20_ROOT" ] || return 0
    [ "$AX20_DRY_RUN" = 1 ] && return 0
    if ax20_have systemctl; then
        systemctl try-restart rauc.service >/dev/null 2>&1 || true
    fi
}

# rauc_incoming_kver : kernel version of the image being installed, for the
# pre-install gate. AX20_INCOMING_KVER overrides (tests, manual runs).
# TODO(vm): SteamOS bundles carry rootfs.img.caibx (a casync index), not a
# mountable image, so before installation the kernel version may not be
# readable at all. We look for an explicit hint in the bundle manifest and
# meta sections; when there is none the gate cannot run and post-install +
# the boot service take over (documented in docs/update-survival.md).
rauc_incoming_kver() {
    local bundle v
    if [ -n "${AX20_INCOMING_KVER:-}" ]; then
        printf '%s\n' "$AX20_INCOMING_KVER"
        return 0
    fi
    bundle=${RAUC_BUNDLE_MOUNT_POINT:-${RAUC_UPDATE_SOURCE:-}}
    [ -n "$bundle" ] && [ -f "$bundle/manifest.raucm" ] || return 1
    v=$(sed -nE 's/^[[:space:]]*(kernel|kver|kernel-version|linux-version)[[:space:]]*=[[:space:]]*//p' \
        "$bundle/manifest.raucm" | head -n1)
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}
