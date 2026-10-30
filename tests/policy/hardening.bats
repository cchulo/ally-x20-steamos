#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# Repository-wide policy checks from X20-STEAMOS-PLAN.md §5.1b / §5.2.
load '../test_helper'

tracked_shell_files() {
    git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard -- '*.sh' '*.bash' '*.bats' 'cmd/*' 'lib/*' 'components/*' 'overlay/*' 'vm/*' 'build/*' |
        grep -v '^tests/policy/' | grep -v '\.md$' | grep -v '\.yaml$' | grep -v '\.conf$' | grep -v '\.lua$' || true
}

@test "nobody ever toggles steamos-readonly" {
    run bash -c 'cd "$1" && git grep -nE "steamos-readonly +(disable|enable)" -- . ":(exclude)tests/policy" ":(exclude)*.md"' _ "$REPO_ROOT"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
}

@test "nothing is ever written under /usr (no cp/install/ln targets in /usr)" {
    run bash -c 'cd "$1" && git grep -nE "(cp|install|ln|mv|tee) .*[ \"'"'"']/usr/" -- . ":(exclude)tests" ":(exclude)*.md" ":(exclude)build/Containerfile"' _ "$REPO_ROOT"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
}

@test "no pacman on the host" {
    run bash -c 'cd "$1" && git grep -nE "^[^#]*\bpacman +-[SU]" -- . ":(exclude)tests" ":(exclude)*.md" ":(exclude)build/Containerfile" ":(exclude)build/*.sh"' _ "$REPO_ROOT"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
}

@test "every tracked shell/python/lua source has an SPDX header" {
    run "$REPO_ROOT/scripts/check-spdx.sh"
    assert_success
}

@test "no prebuilt kernel modules or firmware blobs are tracked" {
    run bash -c 'cd "$1" && git ls-files | grep -E "\.(ko|ko\.zst|ko\.xz|bin|sofa)$"' _ "$REPO_ROOT"
    [ "$status" -ne 0 ] || { echo "tracked binaries: $output"; false; }
}

@test "shell sources avoid bash-4-only constructs (macOS dev hosts run bash 3.2)" {
    run bash -c 'cd "$1" && git grep -nE "^[^#]*(\bdeclare -A\b|\bmapfile\b|\breadarray\b|\$\{[a-zA-Z_]+(,,|\^\^)\})" -- "*.sh" "*.bash" "cmd/*" "lib/*" "components/*" ":(exclude)tests/policy"' _ "$REPO_ROOT"
    [ "$status" -ne 0 ] || { echo "$output"; false; }
}
