#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# release-notes.sh [--file CHANGELOG.md] <version> — print the release notes
# of one version: its section of CHANGELOG.md, without the heading, followed
# by the line about the attached module build.
#
#   scripts/release-notes.sh v0.2.0        # or 0.2.0
#   scripts/release-notes.sh "$(cat VERSION)"
#
# The release job (.github/workflows/build-modules.yml) uses this for the
# GitHub release of a tag. Exit status 1 when the version has no section or
# an empty one, so a release without notes fails instead of going out with a
# placeholder; 2 on a usage error.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
file="$here/CHANGELOG.md"
version=""
while [ $# -gt 0 ]; do
    case "$1" in
        --file)
            [ $# -ge 2 ] || {
                echo "release-notes: --file needs a path" >&2
                exit 2
            }
            file=$2
            shift 2
            ;;
        -h | --help)
            sed -n '3,13s/^# \{0,1\}//p' "$0"
            exit 0
            ;;
        -*)
            echo "release-notes: unknown option $1" >&2
            exit 2
            ;;
        *)
            [ -z "$version" ] || {
                echo "release-notes: one version only" >&2
                exit 2
            }
            version=$1
            shift
            ;;
    esac
done
[ -n "$version" ] || {
    echo "usage: release-notes.sh [--file CHANGELOG.md] <version>" >&2
    exit 2
}
version=${version#v}
case "$version" in
    '' | *[!0-9.]*)
        echo "release-notes: '$version' is not a version like 0.2.0" >&2
        exit 2
        ;;
esac
[ -f "$file" ] || {
    echo "release-notes: $file not found" >&2
    exit 1
}

# The section runs from "## v<version>" (optionally followed by a date in
# parentheses) to the next "## " heading. Blank lines at both ends go.
notes=$(awk -v want="v$version" '
    /^## / {
        if (inside) exit
        head = $2
        if (head == want) { inside = 1; next }
    }
    inside { print }
' "$file" | sed -e '/./,$!d' | awk '
    { lines[NR] = $0 }
    /[^[:space:]]/ { last = NR }
    END { for (i = 1; i <= last; i++) print lines[i] }
')

if [ -z "$notes" ]; then
    echo "release-notes: CHANGELOG.md has no section '## v$version' with text in it." >&2
    echo "Add one before releasing (docs/contributing.md, \"Release notes\")." >&2
    exit 1
fi
printf '%s\n\n%s\n' "$notes" "Patched kernel modules: see BUILD-INFO-* for sources and hashes."
