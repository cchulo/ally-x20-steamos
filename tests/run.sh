#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Run every bats suite under tests/. Usage: tests/run.sh [bats args] [paths]
set -eu
cd "$(dirname "$0")/.."
command -v bats >/dev/null 2>&1 || {
    echo "bats not installed (bats-core)" >&2
    exit 2
}
if [ $# -gt 0 ]; then
    exec bats "$@"
fi
exec bats --recursive tests
