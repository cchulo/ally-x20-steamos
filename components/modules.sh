# SPDX-License-Identifier: GPL-2.0-only
# components/modules.sh — version-gated substitution of the patched kernel
# modules (X20-STEAMOS-PLAN.md §3, §4.2c). See docs/kernel-modules.md.
#
# Files: the load-or-fallback helper (state dir, never /usr) and a modprobe.d
# drop-in generated at apply time from patches/kernel/modules*.list, so the
# install hooks always match the module lists.
#
# No depmod: the hooks are read by modprobe from modprobe.d on every call,
# our .ko files live outside /lib/modules, and depmod would have to write
# modules.dep under the read-only /usr/lib/modules.

# shellcheck source=lib/modules.sh
. "$AX20_SRC/lib/modules.sh"

# shellcheck disable=SC2034  # read by lib/component.sh
COMPONENT_DESCRIPTION="patched kernel modules (ASoC match table, hid-asus-ally), loaded only for a matching kernel"

modules_files() {
    printf 'bin/load-or-fallback\t%s\t0755\tshared\n' "$AX20_HELPER_REL"
}

# The fix strings each stock module would contain once Valve ships our
# patches (plan §5 probes table).
_modules_fix_strings() {
    printf 'snd-soc-acpi-amd-match\t%s\n' "$AX20_BOARD"
    printf 'hid-asus-ally\tgo_s:rgb:joystick_rings\n'
}

modules_apply() {
    local tmp
    modules_ensure_base_dir
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-modprobe.XXXXXX") || return 1
    if ! modules_render_modprobe_conf >"$tmp"; then
        rm -f "$tmp"
        log_error "cannot generate the modprobe.d drop-in from the module lists"
        return 1
    fi
    manifest_install_file "$tmp" "$AX20_MODPROBE_CONF_REL" modules 0644 shared
    rm -f "$tmp"
    if [ -n "$AX20_ROOT" ]; then
        log_debug "fixture root: no module reload needed"
    fi
    return 0
}

# modules_probe : 0 when every stock module already contains its fix,
# 1 when one is missing, 2 when the stock modules dir for the kernel is
# absent (nothing to inspect).
modules_probe() {
    local kver rc mod str any_unknown=0
    kver=$(probe_running_kver)
    [ -d "$(ax20_path "/usr/lib/modules/$kver")" ] || return "$PROBE_UNKNOWN"
    while IFS="$(printf '\t')" read -r mod str; do
        rc=0
        probe_stock_module_contains "$mod" "$str" "$kver" || rc=$?
        case "$rc" in
            0) ;;
            1) return "$PROBE_NO" ;;
            *) any_unknown=1 ;;
        esac
    done <<EOF
$(_modules_fix_strings)
EOF
    [ "$any_unknown" = 0 ] || return "$PROBE_UNKNOWN"
    return "$PROBE_YES"
}

# _modules_files_ok : helper and modprobe.d drop-in are installed unmodified.
_modules_files_ok() {
    manifest_verify "$AX20_HELPER_REL" && manifest_verify "$AX20_MODPROBE_CONF_REL"
}

# modules_status : active | stock | superseded | n/a
#   superseded  stock modules carry the fixes, or our build for this kernel
#               found every patch already upstream
#   active      hooks installed and patched modules staged for this kernel
#   stock       hooks installed but nothing staged for this kernel (pending
#               rebuild) or kernel lockdown blocks unsigned modules; or not
#               installed
#   n/a         not installed and the probe cannot tell
modules_status() {
    local kver rc
    kver=$(probe_running_kver)
    rc=0
    modules_probe >/dev/null 2>&1 || rc=$?
    if [ "$rc" = "$PROBE_YES" ] || modules_all_superseded "$kver"; then
        printf 'superseded\n'
        return 0
    fi
    if _modules_files_ok; then
        if modules_available "$kver" && ! modules_lockdown_active; then
            printf 'active\n'
        else
            printf 'stock\n'
        fi
        return 0
    fi
    if component_installed modules || [ "$rc" != "$PROBE_UNKNOWN" ]; then
        printf 'stock\n'
    else
        printf 'n/a\n'
    fi
}

# modules_status_detail : one human-readable line explaining the status.
modules_status_detail() {
    local kver
    kver=$(probe_running_kver)
    if modules_lockdown_active; then
        printf 'kernel lockdown is active: unsigned modules cannot load, stock modules in use\n'
    elif modules_all_superseded "$kver"; then
        printf 'Valve kernel %s already contains every patch\n' "$kver"
    elif ! _modules_files_ok; then
        printf 'modprobe hooks not installed\n'
    elif modules_available "$kver"; then
        printf 'patched modules staged for %s\n' "$kver"
    else
        printf 'pending rebuild: no patched modules for %s yet (run: %s rebuild)\n' "$kver" "$AX20_NAME"
    fi
}
