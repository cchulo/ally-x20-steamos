# SPDX-License-Identifier: GPL-2.0-only
# summary: list commands
cmd_help() {
    local f name summary
    printf 'usage: %s [global options] <command> [args]\n\nCommands:\n' "$AX20_NAME"
    for f in "$AX20_SRC"/cmd/*.sh; do
        name=$(basename "$f" .sh)
        summary=$(sed -n 's/^# summary: //p' "$f" | head -n1)
        printf '  %-16s %s\n' "$name" "$summary"
    done
    printf '\nGlobal options: see %s --help\n' "$AX20_NAME"
}
