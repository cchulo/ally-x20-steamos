#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Every source/script file must carry an SPDX header in its first 3 lines.
# Files listed in scripts/spdx-exceptions.txt (one path per line) are skipped
# because they keep their original license verbatim (see LICENSE.md).
set -eu
cd "$(dirname "$0")/.."
exceptions=scripts/spdx-exceptions.txt
rc=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in *.md | *.txt | *.yaml | *.conf) continue ;; esac
    if [ -f "$exceptions" ] && grep -Fxq -- "$f" "$exceptions"; then
        continue
    fi
    if ! head -n 3 "$f" | grep -q 'SPDX-License-Identifier:'; then
        echo "missing SPDX header: $f" >&2
        rc=1
    fi
done < <(git ls-files --cached --others --exclude-standard -- '*.sh' '*.bash' '*.bats' '*.py' '*.lua' '*.c' '*.h' 'Makefile' 'cmd/*' 'lib/*' 'components/*' 'overlay/bin/*' 'overlay/rauc/*' 'overlay/systemd/*.service' '.github/workflows/*.yml' 'build/Containerfile' | sort -u)
exit $rc
