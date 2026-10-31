# SPDX-License-Identifier: GPL-2.0-only
# summary: compare the manifest with the filesystem and report drift
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

# Directories where our drop-ins live; anything named *ally-x20-steamos* in
# them that is not in the manifest is reported as "unexpected".
AX20_AUDIT_DIRS="/etc/modprobe.d /etc/environment.d /etc/ld.so.conf.d /etc/systemd/system /etc/systemd/user /etc/udev/rules.d /etc/udev/hwdb.d /etc/inputplumber /etc/rauc /efi/EFI/steamos /esp/loader/entries"

cmd_audit() {
    local json=0 p rc word problems=0 entry kind d f home rel
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=1 ;;
            -h | --help)
                echo "usage: $AX20_NAME audit [--json]   (exit 0 clean, 1 drift found)"
                return 0
                ;;
            *) die 2 "unknown option: $1" ;;
        esac
        shift
    done
    [ "$json" = 1 ] && printf '['
    local first=1
    _audit_emit() {
        # _audit_emit <state> <path> <component>
        if [ "$json" = 1 ]; then
            [ "$first" = 1 ] || printf ','
            first=0
            printf '{"state":"%s","path":"%s","component":"%s"}' "$1" "$2" "$3"
        else
            printf '%-10s %s%s\n' "$1" "$2" "${3:+  [$3]}"
        fi
    }
    for p in $(manifest_paths); do
        entry=$(manifest_entry "$p")
        kind=$(manifest_entry_get "$entry" kind)
        rc=0
        manifest_verify "$p" || rc=$?
        case "$rc" in
            0) word=ok ;;
            1)
                word=modified
                problems=$((problems + 1))
                ;;
            2)
                word=missing
                problems=$((problems + 1))
                ;;
            *)
                word=unknown
                problems=$((problems + 1))
                ;;
        esac
        [ "$kind" = dir ] && [ "$word" = ok ] && continue
        _audit_emit "$word" "$p" "$(manifest_entry_get "$entry" component)"
    done
    # Unexpected files: ours by name, not in the manifest.
    for d in $AX20_AUDIT_DIRS; do
        [ -d "$(ax20_path "$d")" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rel=${f#"$AX20_ROOT"}
            manifest_has "$rel" || {
                _audit_emit unexpected "$rel" ""
                problems=$((problems + 1))
            }
        done < <(find "$(ax20_path "$d")" -maxdepth 2 \( -type f -o -type l \) -name "*$AX20_NAME*" 2>/dev/null)
    done
    for home in "$(ax20_path /home)"/*; do
        [ -d "$home/.config" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            rel=${f#"$AX20_ROOT"}
            manifest_has "$rel" || {
                _audit_emit unexpected "$rel" ""
                problems=$((problems + 1))
            }
        done < <(find "$home/.config" -maxdepth 4 \( -type f -o -type l \) \( -name "*$AX20_NAME*" -o -name "*x20-*" \) 2>/dev/null)
    done
    if [ "$json" = 1 ]; then
        printf ']\n'
    else
        if [ "$problems" = 0 ]; then
            log_info "audit clean: $(manifest_paths | wc -l | tr -d ' ') manifest entries verified"
        else
            log_warn "audit found $problems problem(s)"
        fi
    fi
    [ "$problems" = 0 ]
}
