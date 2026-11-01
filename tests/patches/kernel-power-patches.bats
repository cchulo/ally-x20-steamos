#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# Static checks for the asus-armoury power-limits patch (patches/kernel/0020)
# and patches/kernel/modules-power.list. Nothing here needs a kernel tree.
load '../test_helper'

PATCH_DIR="$REPO_ROOT/patches/kernel"
LIST="$PATCH_DIR/modules-power.list"
P="$PATCH_DIR/0020-asus-armoury-add-ROG-Xbox-Ally-X20-RC74XA-power-limits.patch"

power_patches() {
    ls "$PATCH_DIR"/002[0-9]-*.patch 2>/dev/null
}

@test "exactly one power patch (0020) exists" {
    run power_patches
    assert_success
    [ "$output" = "$P" ]
}

@test "0020 is the mainline commit, author and trailers kept" {
    head -n 1 "$P" | grep -qx 'From 148794d9f0d29e25283978302c41533b81b20b8c Mon Sep 17 00:00:00 2001'
    grep -qx 'From: "Derek J. Clark" <derekjohn.clark@gmail.com>' "$P"
    grep -qx 'Subject: \[PATCH\] platform/x86: asus-armoury: Add XBOX ROG Ally X 20 Tunables' "$P"
    grep -qx 'Signed-off-by: Derek J. Clark <derekjohn.clark@gmail.com>' "$P"
    grep -q '^Derived from: torvalds/linux 148794d9f0d2 ' "$P"
    grep -q '^ally-x20-steamos: backport of mainline commit$' "$P"
}

@test "0020 names Valve's 7.2.10-valve1 as upstream in its description" {
    [ "$(awk '/^---$/ { exit } /^Valve-Upstream: / { print $2 }' "$P")" = 7.2.10-valve1 ]
}

@test "0020 only touches drivers/platform/x86/asus-armoury.h and only adds lines" {
    run git apply --numstat "$P"
    assert_success
    [ "$output" = "$(printf '26\t0\tdrivers/platform/x86/asus-armoury.h')" ]
}

@test "0020 adds the mainline RC74XA power limits (AC and DC, SPL/SPPT/FPPT)" {
    grep -qx '+			DMI_MATCH(DMI_BOARD_NAME, "RC74XA"),' "$P"
    added=$(sed -n 's/^+\t\t\t\t\.\(ppt_[a-z0-9_]*\) = \([0-9]*\),$/\1=\2/p' "$P" | tr '\n' ' ')
    # AC: min/max only; DC: min/def/max (mainline torvalds/linux 148794d9f0d2)
    [ "$added" = "ppt_pl1_spl_min=7 ppt_pl1_spl_max=35 ppt_pl2_sppt_min=13 ppt_pl2_sppt_max=45 ppt_pl3_fppt_min=19 ppt_pl3_fppt_max=55 ppt_pl1_spl_min=7 ppt_pl1_spl_def=17 ppt_pl1_spl_max=35 ppt_pl2_sppt_min=13 ppt_pl2_sppt_def=21 ppt_pl2_sppt_max=45 ppt_pl3_fppt_min=19 ppt_pl3_fppt_def=26 ppt_pl3_fppt_max=55 " ] || {
        echo "$added"
        false
    }
}

@test "0020 applies to the RC73XA tail of Valve's 7.2.7-valve2 table" {
    # The hunk context is the end of the RC73XA entry and the table end, as
    # in 7.2.7-valve2 (blob 322bfa647c2d).
    grep -qx 'index 322bfa647c2d..3b46a05e2453 100644' "$P"
    grep -qx '@@ -2400,6 +2400,32 @@ static const struct dmi_system_id power_limits\[\] = {' "$P"
    tmp="$BATS_TEST_TMPDIR/t"
    mkdir -p "$tmp/drivers/platform/x86"
    {
        printf 'x\n%.0s' $(seq 1 2399)
        printf '\t\t\t},\n\t\t},\n\t},\n\t{}\n};\n\n#endif /* _ASUS_ARMOURY_H_ */\n'
    } >"$tmp/drivers/platform/x86/asus-armoury.h"
    (cd "$tmp" && git init -q . && git apply --check "$P")
}

@test "modules-power.list builds asus-armoury.ko from drivers/platform/x86 for 0020" {
    [ -f "$LIST" ]
    [ "$(grep -cv '^[[:space:]]*\(#\|$\)' "$LIST")" -eq 1 ]
    grep -qxF "$(basename "$P")$(printf '\t')drivers/platform/x86$(printf '\t')asus-armoury.ko" "$LIST"
}

@test "lib/modules.sh and build-modules.sh see asus-armoury in the module set" {
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/modules.sh"
    run modules_list_names
    assert_success
    printf '%s\n' "$output" | grep -qx asus-armoury
    # shellcheck disable=SC1091
    . "$REPO_ROOT/build/build-modules.sh"
    [ "$(bm_list_entries "$PATCH_DIR" | bm_kos_for_mdir drivers/platform/x86)" = asus-armoury ]
    printf '%s\n' "$(bm_list_entries "$PATCH_DIR")" | bm_check_patch_scope "$PATCH_DIR"
}

@test "the generated modprobe.d drop-in has exactly one asus-armoury install hook" {
    make_root >/dev/null
    source_libs
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/modules.sh"
    run modules_render_modprobe_conf
    assert_success
    [ "$(printf '%s\n' "$output" | grep -c '^install asus-armoury ')" -eq 1 ]
    # one install line per module, never two for the same name
    [ -z "$(printf '%s\n' "$output" | awk '/^install / { print $2 }' | sort | uniq -d)" ]
}

@test "no invented sign-offs or attribution trailers in the list" {
    run grep -niE 'signed-off-by|co-authored-by|generated with|claude|anthropic|chatgpt|copilot' "$LIST"
    assert_failure
}
