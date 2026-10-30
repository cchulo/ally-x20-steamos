#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Runs shellcheck, shfmt (diff mode) and the SPDX header check over tracked sources.
set -eu
cd "$(dirname "$0")/.."
rc=0
shell_files() {
    # includes untracked files so new work is linted before it is added
    git ls-files --cached --others --exclude-standard -- '*.sh' '*.bash' 'cmd/*' 'lib/*' 'components/*' 'scripts/*' 'overlay/bin/*' 'overlay/rauc/*' 'vm/*.sh' 'build/*.sh' \
        | grep -vE '\.(md|txt|conf|yaml|yml|service|hook|lua|py)$' | sort -u
}
if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    shellcheck -x $(shell_files) || rc=1
    # bats files are bash too; shellcheck does not know the @test syntax, so
    # we run it with the bats shell dialect disabled checks only when asked.
else
    echo "lint: shellcheck not installed, skipping" >&2
fi
if command -v shfmt >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    [ -n "$(shell_files)" ] && shfmt -d -i 4 -ci -bn $(shell_files) || rc=1
else
    echo "lint: shfmt not installed, skipping" >&2
fi
./scripts/check-spdx.sh || rc=1
if command -v python3 >/dev/null 2>&1 && git ls-files --cached --others --exclude-standard -- '*.py' | grep -q .; then
    # shellcheck disable=SC2046
    python3 -m py_compile $(git ls-files --cached --others --exclude-standard -- '*.py') || rc=1
fi
exit $rc
