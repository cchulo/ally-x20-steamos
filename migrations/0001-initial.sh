#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# migrations/0001-initial.sh — template; intentionally does nothing.
#
# Migrations run after self-update (and install) has checked out a new
# version, in lexical order, each at most once per device (tracked in
# /var/lib/ally-x20-steamos/state/migrations.done). See migrations/README.md.
set -eu
# shellcheck source=lib/common.sh
. "$AX20_SRC/lib/common.sh"

# Example shape of a real migration (always idempotent, always ax20_path):
#   old=$(ax20_path "$AX20_STATE_REL/old-name")
#   new=$(ax20_path "$AX20_STATE_REL/new-name")
#   if [ -e "$old" ] && [ ! -e "$new" ]; then ax20_run mv "$old" "$new"; fi
log_debug "migration 0001-initial: nothing to do"
