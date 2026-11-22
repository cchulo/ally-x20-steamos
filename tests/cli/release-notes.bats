#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# scripts/release-notes.sh and CHANGELOG.md: the GitHub release of a tag
# takes its text from the version's section of the changelog, so the version
# in VERSION must have one.
load '../test_helper'

NOTES="$REPO_ROOT/scripts/release-notes.sh"
FOOT='Patched kernel modules: see BUILD-INFO-* for sources and hashes.'

changelog() {
    cat >"$BATS_TEST_TMPDIR/CHANGELOG.md" <<'TXT'
# Changelog

intro text

## v1.2.0 (2030-01-02)

- second thing
  - nested

A paragraph.

## v1.1.10 (2030-01-01)

- tenth

## v1.1.1

- first

## v1.0.0 (2029-12-31)

TXT
}

@test "the version in VERSION has release notes in CHANGELOG.md" {
    v=$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")
    run "$NOTES" "$v"
    assert_success
    [ "$(printf '%s\n' "$output" | tail -n 1)" = "$FOOT" ]
    # more than the footer: at least one line of notes
    [ "$(printf '%s\n' "$output" | grep -c .)" -ge 2 ]
}

@test "CHANGELOG.md: newest first, one section per version, none empty" {
    heads=$(sed -n 's/^## \(v[0-9][0-9.]*\).*/\1/p' "$REPO_ROOT/CHANGELOG.md")
    [ -n "$heads" ]
    [ "$(printf '%s\n' "$heads" | sort -u | wc -l)" -eq "$(printf '%s\n' "$heads" | wc -l)" ]
    [ "$heads" = "$(printf '%s\n' "$heads" | sort -t. -k1,1Vr -k2,2nr -k3,3nr)" ] \
        || [ "$heads" = "$(printf '%s\n' "$heads" | sed 's/^v//' | sort -t. -k1,1nr -k2,2nr -k3,3nr | sed 's/^/v/')" ]
    for h in $heads; do
        run "$NOTES" "$h"
        assert_success
    done
}

@test "prints the section without its heading, trimmed, plus the module line" {
    changelog
    run "$NOTES" --file "$BATS_TEST_TMPDIR/CHANGELOG.md" v1.2.0
    assert_success
    [ "$output" = "- second thing
  - nested

A paragraph.

$FOOT" ]
}

@test "the version may be given without the v, and v1.1.1 is not v1.1.10" {
    changelog
    run "$NOTES" --file "$BATS_TEST_TMPDIR/CHANGELOG.md" 1.1.1
    assert_success
    [ "$output" = "- first

$FOOT" ]
    run "$NOTES" --file "$BATS_TEST_TMPDIR/CHANGELOG.md" 1.1.10
    assert_output_contains '- tenth'
}

@test "a version without a section, or with an empty one, fails with a pointer" {
    changelog
    run "$NOTES" --file "$BATS_TEST_TMPDIR/CHANGELOG.md" v9.9.9
    [ "$status" -eq 1 ]
    assert_output_contains "has no section '## v9.9.9'"
    assert_output_contains 'docs/contributing.md'
    run "$NOTES" --file "$BATS_TEST_TMPDIR/CHANGELOG.md" v1.0.0
    [ "$status" -eq 1 ]
}

@test "usage errors are 2" {
    run "$NOTES"
    [ "$status" -eq 2 ]
    run "$NOTES" v1 v2
    [ "$status" -eq 2 ]
    run "$NOTES" 'v1; id'
    [ "$status" -eq 2 ]
    run "$NOTES" --bogus v1
    [ "$status" -eq 2 ]
    run "$NOTES" --help
    assert_success
}

@test "the release job takes its notes from the script and never ships a placeholder" {
    w="$REPO_ROOT/.github/workflows/build-modules.yml"
    grep -q 'scripts/release-notes.sh "\$TAG"' "$w"
    grep -q -- '--notes-file' "$w"
    run grep -c -- '--notes "' "$w"
    [ "$output" = 0 ]
}

@test "the test workflow skips Markdown and VERSION, except Markdown that is installed or tested" {
    w="$REPO_ROOT/.github/workflows/test.yml"
    for trigger in push pull_request; do
        block=$(awk -v t="  $trigger:" '$0 == t { on = 1; next } on && /^  [a-z_]+:/ { on = 0 } on && /^[a-z]/ { on = 0 } on' "$w")
        got=$(printf '%s\n' "$block" | sed -n "s/^      - '\\(.*\\)'\$/\\1/p" | tr '\n' ' ')
        [ "$got" = "** !**.md !VERSION overlay/** patches/** vm/** " ]
    done
}

@test "a version bump is still checked: the release-notes workflow runs on VERSION and CHANGELOG.md" {
    w="$REPO_ROOT/.github/workflows/release-notes.yml"
    [ "$(grep -c "      - 'VERSION'" "$w")" -eq 2 ]
    [ "$(grep -c "      - 'CHANGELOG.md'" "$w")" -eq 2 ]
    grep -q 'scripts/release-notes.sh "$(tr -d' "$w"
}
