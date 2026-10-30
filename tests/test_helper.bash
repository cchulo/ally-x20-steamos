# SPDX-License-Identifier: GPL-2.0-only
# Shared bats helper. Load with:  load '../test_helper'   (path relative to the .bats file)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AX20_SRC="$REPO_ROOT"
export PATH="$REPO_ROOT:$PATH"
CLI="$REPO_ROOT/ally-x20-steamos.sh"
export CLI

# make_root : create an empty fixture root and export AX20_ROOT to it.
make_root() {
    AX20_ROOT="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/ax20root.XXXXXX")"
    export AX20_ROOT
    mkdir -p "$AX20_ROOT/var/lib/ally-x20-steamos" "$AX20_ROOT/etc"
    printf '%s\n' "$AX20_ROOT"
}

# fixture_file <abs-path-in-root> [content] : create a file inside AX20_ROOT.
fixture_file() {
    local p="$AX20_ROOT$1"
    mkdir -p "$(dirname "$p")"
    printf '%s' "${2:-fixture}" >"$p"
}

# source_libs : load the shell libraries into the test shell.
source_libs() {
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/common.sh"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/manifest.sh"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/probes.sh"
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/component.sh"
}

# assert_success / assert_failure / assert_output_contains : tiny subset of
# bats-assert so we do not need a submodule.
# shellcheck disable=SC2154  # status/output are set by bats' run
assert_success() {
    if [ "$status" -ne 0 ]; then
        printf 'expected success, got status %s\noutput:\n%s\n' "$status" "$output" >&2
        return 1
    fi
}
assert_failure() {
    if [ "$status" -eq 0 ]; then
        printf 'expected failure, got success\noutput:\n%s\n' "$output" >&2
        return 1
    fi
    if [ -n "${1:-}" ] && [ "$status" -ne "$1" ]; then
        printf 'expected status %s, got %s\noutput:\n%s\n' "$1" "$status" "$output" >&2
        return 1
    fi
}
assert_output_contains() {
    case "$output" in
        *"$1"*) return 0 ;;
    esac
    printf 'expected output to contain: %s\noutput:\n%s\n' "$1" "$output" >&2
    return 1
}
assert_equal() {
    if [ "$1" != "$2" ]; then
        printf 'expected: %s\nactual:   %s\n' "$2" "$1" >&2
        return 1
    fi
}
