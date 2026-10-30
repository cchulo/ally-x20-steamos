# SPDX-License-Identifier: GPL-2.0-only
# summary: list components and their one-line descriptions
# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

cmd_components() {
    local c
    for c in $(component_list); do
        printf '%-16s %s\n' "$c" "$(component_description "$c")"
    done
}
