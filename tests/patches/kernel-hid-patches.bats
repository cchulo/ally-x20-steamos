#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# Static checks for the hid-asus-ally kernel patches (patches/kernel/0010-0015)
# and patches/kernel/modules-hid.list. Nothing here needs a kernel tree.
load '../test_helper'

PATCH_DIR="$REPO_ROOT/patches/kernel"
LIST="$PATCH_DIR/modules-hid.list"

hid_patches() {
    ls "$PATCH_DIR"/001[0-9]-hid-asus-ally-*.patch 2>/dev/null
}

@test "the six hid-asus-ally patches exist" {
    run hid_patches
    assert_success
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 6 ] || {
        echo "$output"
        false
    }
}

@test "patches are git format-patch files (From line, From:, Subject:, diff --git)" {
    for p in $(hid_patches); do
        head -n 1 "$p" | grep -Eq '^From [0-9a-f]{40} Mon Sep 17 00:00:00 2001$' || {
            echo "bad first line: $p"
            false
        }
        grep -Eq '^From: .+ <.+@.+>$' "$p" || {
            echo "no From: in $p"
            false
        }
        grep -Eq '^Subject: \[PATCH\] HID: asus-ally: ' "$p" || {
            echo "no Subject: in $p"
            false
        }
        grep -q '^diff --git a/' "$p" || {
            echo "no diff in $p"
            false
        }
    done
}

@test "patches only touch drivers/hid/ and Documentation/" {
    for p in $(hid_patches); do
        bad="$(grep '^diff --git ' "$p" | awk '{print $3; print $4}' | sed -e 's#^[ab]/##' |
            grep -vE '^(drivers/hid/|Documentation/)' || true)"
        [ -z "$bad" ] || {
            echo "$p touches: $bad"
            false
        }
    done
}

@test "patch bodies cite where they were derived from" {
    for p in $(hid_patches); do
        grep -q '^Derived from:' "$p" || {
            echo "no 'Derived from:' in $p"
            false
        }
    done
}

@test "no invented sign-offs or attribution trailers" {
    for p in $(hid_patches) "$LIST"; do
        run grep -niE '^(signed-off-by|co-authored-by|co-developed-by|reviewed-by|tested-by|acked-by):|generated with|claude|anthropic|chatgpt|copilot' "$p"
        [ "$status" -ne 0 ] || {
            echo "$p: $output"
            false
        }
    done
}

@test "modules-hid.list is <patch>\\t<M= dir>\\t<ko> and references existing patches" {
    [ -f "$LIST" ]
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        n=$((n + 1))
        fields="$(printf '%s\n' "$line" | awk -F '\t' '{print NF}')"
        [ "$fields" -eq 3 ] || {
            echo "not 3 tab-separated fields: $line"
            false
        }
        patch="$(printf '%s\n' "$line" | cut -f1)"
        dir="$(printf '%s\n' "$line" | cut -f2)"
        ko="$(printf '%s\n' "$line" | cut -f3)"
        [ -f "$PATCH_DIR/$patch" ] || {
            echo "missing patch: $patch"
            false
        }
        [ "$dir" = "drivers/hid" ] || {
            echo "unexpected M= dir: $dir"
            false
        }
        [ "$ko" = "hid-asus-ally.ko" ] || {
            echo "unexpected module: $ko"
            false
        }
    done <"$LIST"
    [ "$n" -eq 6 ]
}

@test "every hid-asus-ally patch is listed in modules-hid.list" {
    for p in $(hid_patches); do
        cut -f1 "$LIST" | grep -Fxq "$(basename "$p")" || {
            echo "not listed: $(basename "$p")"
            false
        }
    done
}

@test "0010 registers the Steam-visible LED name behind steam_led_name" {
    p="$(ls "$PATCH_DIR"/0010-*.patch)"
    grep -q '^+#define ALLY_RGB_LED_NAME_STEAM "go_s:rgb:joystick_rings"' "$p"
    grep -q '^+module_param(steam_led_name, bool, 0444);' "$p"
    grep -q '^+	{ .color_index = LED_COLOR_ID_RED, .channel = 0 },' "$p"
}

@test "0011 documents its ABI" {
    p="$(ls "$PATCH_DIR"/0011-*.patch)"
    grep -q '^diff --git a/Documentation/ABI/testing/sysfs-driver-hid-asus-ally ' "$p"
    for attr in effect effect_index speed speed_range direction direction_index enabled enabled_index mode mode_index; do
        grep -q "^+What:		/sys/class/leds/<led>/$attr\$" "$p" || {
            echo "undocumented: $attr"
            false
        }
    done
}

@test "0012 reports 0xa0 as one plain KEY_PROG2, with no Steam chord" {
    p="$(ls "$PATCH_DIR"/0012-*.patch)"
    grep -q '^+#define ALLY_X20_KEY_RIGHT 0xa0' "$p"
    # reported on the Ally X gamepad input and on the config input
    grep -q '^+		input_report_key(ally_x->input, KEY_PROG2, data\[1\] == ALLY_X20_KEY_RIGHT);' "$p"
    grep -q '^+		input_report_key(cfg->input, KEY_PROG2, data\[1\] == ALLY_X20_KEY_RIGHT);' "$p"
    [ "$(grep -c '^+	input_set_capability(input\(_dev\)\?, EV_KEY, KEY_PROG2);' "$p")" -eq 2 ]
    # InputPlumber owns the mapping: no chord, no qam_mode path, 0xa6 untouched
    run grep -E '^\+.*(update_qam_btn|BTN_MODE|BTN_A|KEY_F16)' "$p"
    assert_failure
}

@test "0011 sends Solid through the Aura report by default, rgb_static_mode selects the rest" {
    p="$(ls "$PATCH_DIR"/0011-*.patch)"
    grep -q '^+static int rgb_static_mode = ALLY_RGB_STATIC_AURA;' "$p"
    grep -q '^+module_param_cb(rgb_static_mode, &rgb_static_mode_ops, &rgb_static_mode, 0644);' "$p"
    grep -q '^Solid dropout\.' "$p"
    grep -q '^### Solid dropout' "$PATCH_DIR/README-hid.md"
}

@test "0013 tears down per interface and serialises drvdata against raw_event" {
    p="$(ls "$PATCH_DIR"/0013-*.patch)"
    grep -q '^+static DEFINE_SPINLOCK(ally_drvdata_lock);' "$p"
    grep -q '^+	if (ep == ROG_ALLY_CFG_INTF_IN) {' "$p"
    grep -q '^+		drvdata.ally_x = NULL;' "$p"
}

@test "0014 scales rumble magnitudes to the MCU range 0..100 and is listed for the build" {
    p="$(ls "$PATCH_DIR"/0014-*.patch)"
    [ -f "$p" ]
    grep -q '^Subject: ' "$p"
    grep -qE '100' "$p"
    grep -q '^0014-' "$PATCH_DIR/modules-hid.list"
}

@test "0015 defers the X20 top-right key release and is listed for the build" {
    p="$(ls "$PATCH_DIR"/0015-*.patch)"
    [ -f "$p" ]
    grep -q '^Subject: ' "$p"
    grep -q 'ALLY_X20_KEY_HOLD_MS' "$p"
    grep -q 'cancel_delayed_work_sync(&ally_x->x20_key_release)' "$p"
    grep -q '^0015-' "$PATCH_DIR/modules-hid.list"
}
