# SPDX-License-Identifier: GPL-2.0-only
# summary: virtual 7.1 surround for the built-in outputs: status | list | set <headphones|speakers> <profile> | xtc off|<delay_us> <strength_pct> | plain hidden|shown | prepare
#
# A thin wrapper around the helper of component surround
# (/etc/ally-x20-steamos/surround/x20-surround, overlay/bin/x20-surround.py).
# Runs as the user, not as root: the choice of profile, the generated
# speaker variants and PipeWire belong to the user (docs/surround.md).

# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

_surround_usage() {
    cat <<USAGE
usage: $AX20_NAME surround <command>

  status      the profile chosen per output, the crosstalk setting, the
              output in use, what runs
  list        the profiles
  set <headphones|speakers> <profile>
              choose the profile of one output. Each output has its own
              profile and is always named. It takes effect within a few
              seconds, the new filter starting before the old one stops,
              and is kept across reboots and SteamOS updates
  xtc off | xtc <delay_us> <strength_pct>
              crosstalk cancellation for the speakers (never the
              headphones): delay 20 to 300 microseconds, strength 5 to 95
              percent. Default: 60 50
  plain hidden|shown
              whether the plain "Speakers" and "Headphones" stay in other
              programs' output lists. Default: hidden; "stereo" then shows
              up as its own entry, for example "Speakers (Stereo)"
  prepare     generate the twelve tested crosstalk settings (60/80/100/120
              microseconds, 30/50/70 percent) for the speakers' profile and
              print each one's level trim and whether it is usable. Do this
              after you put your own .wav in place

Profiles: stereo (no surround); sadie-d2, hutubs-pp1, mit-kemar and
mit-kemar-large, each as -dry (fronts unfiltered; sadie-d2-dry is the
default for the headphones and for the speakers) and -full (every channel filtered); and user: the
first .wav file, in lexical order, in ~/.config/$AX20_NAME/surround-user/
(a 14-channel 48 kHz HeSuVi file).

With crosstalk cancellation the speakers play a variant of the profile's
file that is generated on the device and kept in
~/.cache/$AX20_NAME/surround/. A setting whose variant fails its check is
not played; the profile then plays as it is and 'status' says why.

Run it without sudo. Needs the surround component ('$AX20_NAME apply').
See docs/surround.md.
USAGE
}

# _surround_helper : the installed helper, or the checkout's copy (so
# `status` and `list` also work before the component is applied).
_surround_helper() {
    local installed
    installed=$(ax20_path "${AX20_EARLY_REL}/surround/x20-surround")
    if [ -x "$installed" ]; then
        printf '%s\n' "$installed"
    else
        printf '%s\n' "$AX20_SRC/overlay/bin/x20-surround.py"
    fi
}

# _surround_installed : the installed helper is there. This command runs as
# the user, who cannot read the root-owned manifest, so the manifest cannot
# be what decides it.
_surround_installed() {
    [ -x "$(ax20_path "${AX20_EARLY_REL}/surround/x20-surround")" ]
}

# _surround_print_status : the component's status line. The full check needs
# the manifest; without read access to it, say only whether the helper is
# installed.
_surround_print_status() {
    local m
    m=$(ax20_manifest_file)
    if [ ! -e "$m" ] || [ -r "$m" ]; then
        printf 'status: %s\n' "$(component_status surround)"
    elif _surround_installed; then
        printf "status: installed (run 'sudo %s status' for the full check)\n" "$AX20_NAME"
    else
        printf 'status: not installed\n'
    fi
}

cmd_surround() {
    component_load surround
    case "${1:-}" in
        -h | --help | help)
            _surround_usage
            return 0
            ;;
        '')
            _surround_usage >&2
            return 2
            ;;
        status | list | set | xtc | prepare | plain) ;;
        *)
            log_error "unknown surround command: $1"
            _surround_usage >&2
            return 2
            ;;
    esac
    if ! ax20_have python3; then
        log_error "surround: python3 not found"
        return 1
    fi
    if { [ "$1" = set ] || [ "$1" = xtc ] || [ "$1" = plain ]; } && ! _surround_installed; then
        log_error "surround is not installed; run 'sudo $AX20_NAME apply --only surround' first"
        return 1
    fi
    if [ "$1" = status ]; then
        _surround_print_status
    fi
    if [ "$AX20_DRY_RUN" = 1 ] && [ "$1" != status ] && [ "$1" != list ]; then
        printf '[dry-run] surround %s\n' "$*" >&2
        return 0
    fi
    python3 "$(_surround_helper)" "$@"
}
