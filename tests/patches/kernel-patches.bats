#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# Static checks for patches/kernel/: format-patch shape, touched paths,
# no AI/co-author attribution, and modules.list consistency. No kernel tree
# is needed; `git apply --numstat` only parses the patch.
load '../test_helper'

KDIR="$REPO_ROOT/patches/kernel"

kernel_patches() {
    find "$KDIR" -maxdepth 1 -type f -name '*.patch' | sort
}

# touched_paths <patch> : every a/ and b/ path named in a diff --git header.
touched_paths() {
    awk '/^diff --git a\// { sub(/^a\//, "", $3); sub(/^b\//, "", $4); print $3; print $4 }' "$1" | sort -u
}

# outside_mdirs <patch> : files the patch touches that are under none of the
# M= dirs it is listed with in modules.list (include/ and Documentation/ are
# exempt).
outside_mdirs() {
    local f
    for f in $(touched_paths "$KDIR/$1" | grep -v -e '^include/' -e '^Documentation/'); do
        awk -F'\t' -v p="$1" -v f="$f" '$1 == p && index(f, $2 "/") == 1 { ok = 1 } END { if (!ok) print f }' "$KDIR/modules.list"
    done
}

@test "the speaker-audio patches exist" {
    [ -f "$KDIR/0001-ASoC-amd-acpi-add-RC74XA-link0-tas2783-layout.patch" ]
    [ -f "$KDIR/0002-ACPI-x86-quirk-ignore-acp-audio-config-flag-RC74XA.patch" ]
}

@test "the Valve 7.2.10-valve1 speaker-audio backports exist" {
    [ -f "$KDIR/0003-ASoC-sdw_utils-honor-empty-DisCo-port-lists.patch" ]
    [ -f "$KDIR/0004-ASoC-tas2783-sdw-keep-the-volume-settings-across-resets.patch" ]
    [ -f "$KDIR/0005-ASoC-tas2783-sdw-load-the-firmware-synchronously.patch" ]
    [ -f "$KDIR/0006-ASoC-tas2783-sdw-refuse-playback-when-init-writes-failed.patch" ]
}

@test "the Valve backports keep their author, name their source commit and a Valve-Upstream tag" {
    local p sha
    for p in "$KDIR"/000[3-6]-*.patch; do
        sha=$(head -n 1 "$p" | cut -d' ' -f2)
        grep -qx 'From: Matthew Schwartz <matthew.schwartz@linux.dev>' "$p" || {
            echo "author changed: $p"
            false
        }
        grep -q "^ally-x20-steamos: backport of Valve linux-integration commit\$" "$p" || {
            echo "no ally-x20-steamos note: $p"
            false
        }
        grep -qx "$sha (mirror" "$p" || {
            echo "note does not name the source commit $sha: $p"
            false
        }
        # the tag must sit in the description, where build-modules.sh reads it
        [ "$(awk '/^---$/ { exit } /^Valve-Upstream: / { print $2 }' "$p")" = 7.2.10-valve1 ] || {
            echo "no Valve-Upstream: 7.2.10-valve1 line: $p"
            false
        }
    done
}

@test "modules.list rebuilds every user of the struct changed by 0003, and tas2783 for 0004-0006" {
    local l="$KDIR/modules.list" p
    p=0003-ASoC-sdw_utils-honor-empty-DisCo-port-lists.patch
    grep -qxF "$p$(printf '\t')sound/soc/sdw_utils$(printf '\t')snd-soc-sdw-utils.ko" "$l"
    grep -qxF "$p$(printf '\t')sound/soc/amd/acp$(printf '\t')snd-acp-sdw-legacy-mach.ko" "$l"
    grep -qxF "$p$(printf '\t')sound/soc/amd/acp$(printf '\t')snd-acp-sdw-sof-mach.ko" "$l"
    for p in "$KDIR"/000[4-6]-*.patch; do
        grep -qxF "$(basename "$p")$(printf '\t')sound/soc/codecs$(printf '\t')snd-soc-tas2783-sdw.ko" "$l" || {
            echo "not listed for snd-soc-tas2783-sdw.ko: $p"
            false
        }
    done
}

@test "every kernel patch has git format-patch headers" {
    local p n=0
    for p in $(kernel_patches); do
        n=$((n + 1))
        head -n 1 "$p" | grep -q '^From [0-9a-f]\{40\} ' || {
            echo "bad first line: $p"
            false
        }
        grep -q '^From: .\+ <.\+@.\+>$' "$p" || {
            echo "no From: author line: $p"
            false
        }
        grep -q '^Subject: ' "$p" || {
            echo "no Subject: $p"
            false
        }
        grep -qx -- '---' "$p" || {
            echo "no --- separator: $p"
            false
        }
        grep -q '^diff --git a/' "$p" || {
            echo "no diff --git: $p"
            false
        }
    done
    [ "$n" -gt 0 ]
}

@test "every kernel patch parses with git apply --numstat" {
    local p
    for p in $(kernel_patches); do
        run git apply --numstat "$p"
        assert_success
        [ -n "$output" ] || {
            echo "empty numstat: $p"
            false
        }
    done
}

@test "kernel patches only touch sound/, drivers/, include/ or Documentation/" {
    local p f
    for p in $(kernel_patches); do
        for f in $(touched_paths "$p") $(git apply --numstat "$p" | cut -f3); do
            case "$f" in
                sound/* | drivers/* | include/* | Documentation/*) ;;
                *)
                    echo "$p touches $f"
                    false
                    ;;
            esac
        done
    done
}

@test "kernel patches cite their sources" {
    local p
    for p in $(kernel_patches); do
        grep -q '^Derived from:' "$p" || {
            echo "no 'Derived from:' section: $p"
            false
        }
    done
}

@test "kernel patches carry no AI or co-author attribution" {
    run bash -c 'grep -inE "(signed-off-by|co-authored-by|assisted-by|generated-by|helped-by): .*(claude|anthropic|openai|chatgpt|copilot|gpt-)|^(co-authored-by|assisted-by):|generated with|noreply@anthropic" "$@"' _ $(kernel_patches)
    [ "$status" -eq 1 ] || {
        echo "$output"
        false
    }
}

@test "modules.list is well-formed and references existing patches" {
    local line patch mdir ko rest n=0
    [ -f "$KDIR/modules.list" ]
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [ "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" -eq 3 ] || {
            echo "line $n: expected 3 tab-separated fields: $line"
            false
        }
        patch=$(printf '%s' "$line" | cut -f1)
        mdir=$(printf '%s' "$line" | cut -f2)
        ko=$(printf '%s' "$line" | cut -f3)
        [ -f "$KDIR/$patch" ] || {
            echo "line $n: missing patch $patch"
            false
        }
        case "$mdir" in
            sound/* | drivers/*) ;;
            *)
                echo "line $n: M= dir outside sound/ or drivers/: $mdir"
                false
                ;;
        esac
        case "$mdir" in */) echo "line $n: trailing slash in $mdir" && false ;; esac
        case "$ko" in
            *.ko) ;;
            *)
                echo "line $n: not a .ko name: $ko"
                false
                ;;
        esac
        # Every file the patch touches must live under one of the M= dirs the
        # patch is listed with; include/ headers are searched first for every
        # M= build (build-modules.sh), Documentation/ is not built.
        rest=$(outside_mdirs "$patch")
        [ -z "$rest" ] || {
            echo "line $n: $patch touches files outside its M= dirs: $rest"
            false
        }
    done <"$KDIR/modules.list"
    [ "$n" -gt 0 ]
}

@test "every kernel patch is listed in a modules*.list" {
    local p
    for p in $(kernel_patches); do
        cat "$KDIR"/modules*.list | cut -f1 | grep -qxF "$(basename "$p")" || {
            echo "not in any modules*.list: $p"
            false
        }
    done
}
