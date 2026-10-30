#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ally-x20-steamos — ROG Xbox Ally X20 support for stock SteamOS.
#
# Dispatcher only. Each sub-command lives in cmd/<name>.sh and defines
# cmd_<name_with_underscores>; `help` lists them from their "# summary:" line.
set -eu

AX20_SRC=$(cd "$(dirname "$(readlink "$0" 2>/dev/null || printf '%s' "$0")")" && pwd)
export AX20_SRC
# shellcheck source=lib/common.sh
. "$AX20_SRC/lib/common.sh"

usage() {
    cat <<USAGE
usage: $AX20_NAME [global options] <command> [args]

Global options:
  --root <dir>   operate on a fixture/mounted root instead of / (tests, other slot)
  --dry-run      print actions without performing them
  --verbose      debug logging
  --yes          assume yes on confirmations
  --i-know       proceed even if the root filesystem has been made writable
  --version      print version and exit
  -h, --help     this help

Run '$AX20_NAME help' for the list of commands.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            [ $# -ge 2 ] || die "--root needs a directory"
            AX20_ROOT=$2
            shift 2
            ;;
        --root=*)
            AX20_ROOT=${1#--root=}
            shift
            ;;
        --dry-run)
            AX20_DRY_RUN=1
            shift
            ;;
        --verbose | -v)
            AX20_VERBOSE=1
            shift
            ;;
        --yes | -y)
            AX20_ASSUME_YES=1
            shift
            ;;
        --i-know)
            AX20_I_KNOW=1
            shift
            ;;
        --version)
            ax20_version
            exit 0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*) die 2 "unknown global option: $1 (see --help)" ;;
        *) break ;;
    esac
done
case "${AX20_ROOT:-}" in */) AX20_ROOT=${AX20_ROOT%/} ;; esac
export AX20_ROOT AX20_DRY_RUN AX20_VERBOSE AX20_ASSUME_YES AX20_I_KNOW

if [ $# -eq 0 ]; then
    usage >&2
    exit 2
fi

cmd=$1
shift
case "$cmd" in
    *[!a-z0-9-]*) die 2 "unknown command: $cmd" ;;
esac
cmd_file="$AX20_SRC/cmd/$cmd.sh"
[ -f "$cmd_file" ] || die 2 "unknown command: $cmd (run '$AX20_NAME help')"
# shellcheck disable=SC1090
. "$cmd_file"
fn="cmd_$(printf '%s' "$cmd" | tr '-' '_')"
declare -F "$fn" >/dev/null 2>&1 || die "cmd/$cmd.sh does not define $fn"
"$fn" "$@"
