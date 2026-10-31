#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# vm/guest/*, vm/fake-leds.sh and vm/test-led-module: pure logic only.
# Syntax and style of the scripts are covered by `make lint` (shellcheck/shfmt).
load '../test_helper'

ES="$REPO_ROOT/vm/guest/measure-etc-survival.sh"

# make_tree <dir> : a small stock-like /etc.
make_tree() {
    mkdir -p "$1/etc/modprobe.d" "$1/etc/udev/rules.d" "$1/etc/systemd/system" "$1/etc/keep"
    printf 'a\n' >"$1/etc/stock"
    printf 'b\n' >"$1/etc/gone"
    printf 'c\n' >"$1/etc/mod"
    printf 'k\n' >"$1/etc/keep/file"
    ln -s stock "$1/etc/link"
}

@test "snapshot records type and digest; compare classifies two fixture trees" {
    a="$BATS_TEST_TMPDIR/a"
    b="$BATS_TEST_TMPDIR/b"
    make_tree "$a"
    make_tree "$b"
    rm "$b/etc/gone"
    printf 'changed\n' >"$b/etc/mod"
    printf 'new\n' >"$b/etc/added"
    rm "$b/etc/link"
    ln -s mod "$b/etc/link"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/a.tsv"
    "$ES" snapshot "$b/etc" /etc >"$BATS_TEST_TMPDIR/b.tsv"
    grep -q "^/etc/keep	d	-$" "$BATS_TEST_TMPDIR/a.tsv"
    grep -q "^/etc/link	l	stock$" "$BATS_TEST_TMPDIR/a.tsv"
    grep -Eq "^/etc/stock	f	[0-9a-f]{64}$" "$BATS_TEST_TMPDIR/a.tsv"

    run "$ES" compare "$BATS_TEST_TMPDIR/a.tsv" "$BATS_TEST_TMPDIR/b.tsv"
    assert_success
    assert_output_contains "same	/etc/stock"
    assert_output_contains "same	/etc/keep/file"
    assert_output_contains "changed	/etc/mod"
    assert_output_contains "changed	/etc/link"
    assert_output_contains "removed	/etc/gone"
    assert_output_contains "added	/etc/added"
}

@test "identical trees compare as all same" {
    a="$BATS_TEST_TMPDIR/a"
    make_tree "$a"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/1.tsv"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/2.tsv"
    run bash -c '"$1" compare "$2" "$3" | grep -v "^same	"' _ "$ES" "$BATS_TEST_TMPDIR/1.tsv" "$BATS_TEST_TMPDIR/2.tsv"
    assert_failure 1
}

@test "before/after on a fixture root emits the etc-survival table" {
    r="$BATS_TEST_TMPDIR/root"
    make_tree "$r"
    run "$ES" before --root "$r"
    assert_success
    [ -f "$r/etc/ally-x20-steamos-probe.d/marker-plain" ]
    [ -L "$r/etc/ally-x20-steamos-probe.d/marker-symlink" ]
    [ -f "$r/etc/modprobe.d/ally-x20-steamos-probe.conf" ]
    [ -f "$r/etc/systemd/system/ally-x20-steamos-probe.marker" ]
    # drop-in dirs that do not exist are not created
    [ ! -e "$r/etc/rauc" ]
    [ -f "$r/var/lib/ally-x20-steamos-probe/before.tsv" ]

    # "update": lose a drop-in marker and a nested marker, change stock files
    rm "$r/etc/udev/rules.d/99-ally-x20-steamos-probe.rules"
    rm -r "$r/etc/ally-x20-steamos-probe.d/subdir"
    rm "$r/etc/gone"
    printf 'z\n' >>"$r/etc/mod"
    printf '/etc/modprobe.d/ally-x20-steamos-probe.conf\n' >"$BATS_TEST_TMPDIR/restored"

    run "$ES" after --root "$r" --restored "$BATS_TEST_TMPDIR/restored"
    assert_success
    assert_output_contains "| path | survives update? | restored by hook/service? | notes |"
    assert_output_contains '| `/etc/ally-x20-steamos-probe.d/marker-plain` | yes | - | marker |'
    assert_output_contains '| `/etc/ally-x20-steamos-probe.d/subdir/marker-nested` | no | - | marker |'
    assert_output_contains '| `/etc/udev/rules.d/99-ally-x20-steamos-probe.rules` | no | - | marker |'
    assert_output_contains '| `/etc/modprobe.d/ally-x20-steamos-probe.conf` | yes | yes | marker |'
    assert_output_contains "1 changed, 1 removed, 0 added"
    assert_output_contains '`/etc/gone`'

    run "$ES" before --root "$r"
    assert_failure 2

    run "$ES" cleanup --root "$r"
    assert_success
    [ ! -e "$r/etc/ally-x20-steamos-probe.d" ]
    [ ! -e "$r/etc/modprobe.d/ally-x20-steamos-probe.conf" ]
    [ ! -e "$r/var/lib/ally-x20-steamos-probe" ]
    [ -f "$r/etc/stock" ]
}

@test "table --all lists stock paths too" {
    a="$BATS_TEST_TMPDIR/a"
    make_tree "$a"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/1.tsv"
    rm "$a/etc/gone"
    "$ES" snapshot "$a/etc" /etc >"$BATS_TEST_TMPDIR/2.tsv"
    run "$ES" table "$BATS_TEST_TMPDIR/1.tsv" "$BATS_TEST_TMPDIR/2.tsv" --all
    assert_success
    assert_output_contains '| `/etc/gone` | no | - | stock |'
    assert_output_contains '| `/etc/stock` | yes | - | stock |'
}

@test "roundtrip-test parses manifest paths and skips when the CLI lacks install" {
    # shellcheck disable=SC1091
    . "$REPO_ROOT/vm/guest/roundtrip-test.sh"
    m="$BATS_TEST_TMPDIR/manifest"
    printf '%s\n' '{"path":"/etc/modprobe.d/ally-x20-steamos.conf","component":"audio","kind":"file"}' \
        '{"component":"rgb","path":"/var/lib/ally-x20-steamos/x","kind":"file"}' >"$m"
    run rt_manifest_paths "$m"
    assert_success
    assert_output_contains "/etc/modprobe.d/ally-x20-steamos.conf"
    assert_output_contains "/var/lib/ally-x20-steamos/x"

    printf '%s\n' '^/etc/ld\.so\.cache$' >"$BATS_TEST_TMPDIR/ex"
    run rt_filter "$BATS_TEST_TMPDIR/ex" < <(printf '/etc/ld.so.cache\tf\tx\n/etc/keep\tf\ty\n')
    assert_success
    assert_output_contains "/etc/keep"
    case "$output" in *ld.so.cache*) false ;; esac

    # A CLI without install/uninstall: exit 77 (skip) before touching anything.
    fake="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$fake"
    printf '#!/bin/sh\necho "help version components"\n' >"$fake/ally-x20-steamos.sh"
    chmod +x "$fake/ally-x20-steamos.sh"
    run "$REPO_ROOT/vm/guest/roundtrip-test.sh" --repo "$fake" --out "$BATS_TEST_TMPDIR/rt"
    assert_failure 77
    assert_output_contains "skipping"
    [ ! -e "$BATS_TEST_TMPDIR/rt" ]
}

@test "fake-leds tree builds a sysfs-shaped fixture" {
    run "$REPO_ROOT/vm/fake-leds.sh" tree "$BATS_TEST_TMPDIR/r"
    assert_success
    d="$BATS_TEST_TMPDIR/r/sys/class/leds/ally:rgb:joystick_rings"
    [ "$(cat "$d/max_brightness")" = 255 ]
    [ "$(wc -w <"$d/multi_index" | tr -d ' ')" = 12 ]
    run "$REPO_ROOT/vm/fake-leds.sh" tree "$BATS_TEST_TMPDIR/r" --name go_s:rgb:joystick_rings --layout patched
    assert_success
    [ "$(cat "$BATS_TEST_TMPDIR/r/sys/class/leds/go_s:rgb:joystick_rings/multi_index")" = "red green blue" ]
}

@test "test LED module sources exist with the Steam LED name and GPL license" {
    src="$REPO_ROOT/vm/test-led-module/ax20_test_led.c"
    [ -f "$src" ]
    [ -f "$REPO_ROOT/vm/test-led-module/Makefile" ]
    [ -f "$REPO_ROOT/vm/test-led-module/README.md" ]
    head -n 1 "$src" | grep -q 'SPDX-License-Identifier: GPL-2.0-only'
    head -n 3 "$REPO_ROOT/vm/test-led-module/Makefile" | grep -q 'SPDX-License-Identifier: GPL-2.0-only'
    grep -q '"go_s:rgb:joystick_rings"' "$src"
    grep -q 'MODULE_LICENSE("GPL")' "$src"
    grep -q 'led_classdev_multicolor_register' "$src"
    grep -q 'LED_COLOR_ID_RED' "$src"
    grep -q 'LED_COLOR_ID_GREEN' "$src"
    grep -q 'LED_COLOR_ID_BLUE' "$src"
    grep -q '^obj-m := ax20_test_led.o' "$REPO_ROOT/vm/test-led-module/Makefile"
}

@test "collect-hardware-data packs a tarball without root" {
    run "$REPO_ROOT/vm/guest/collect-hardware-data.sh" --no-sudo --out "$BATS_TEST_TMPDIR/out"
    assert_success
    tarball=$(printf '%s\n' "$output" | tail -n 1)
    [ -f "$tarball" ]
    tar -tzf "$tarball" | grep -q 'dmi.txt$'
    tar -tzf "$tarball" | grep -q 'acpidump.txt$'
}

MSC="$REPO_ROOT/vm/guest/measure-speaker-chain.sh"

# float_wav <path> <size-field> <samples...> : stereo IEEE-float WAV;
# size-field "ok" writes the real data size, anything else is used as is.
float_wav() {
    python3 - "$@" <<'PY'
import struct, sys
path, size_field, vals = sys.argv[1], sys.argv[2], [float(v) for v in sys.argv[3:]]
data = struct.pack('<%df' % len(vals), *vals)
size = len(data) if size_field == 'ok' else int(size_field, 0)
fmt = struct.pack('<HHIIHH', 3, 2, 48000, 48000 * 8, 8, 32)
body = b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', size) + data
open(path, 'wb').write(b'RIFF' + struct.pack('<I', len(body)) + body)
PY
}

@test "measure-speaker-chain: generate writes the 3-segment 7.1 file at -1 dBFS" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    run "$MSC" generate "$BATS_TEST_TMPDIR/t.wav" 0.2
    assert_success
    run "$MSC" analyze "$BATS_TEST_TMPDIR/t.wav"
    assert_success
    assert_output_contains "8 ch, 48000 Hz, 16-bit PCM, 0.60 s"
    assert_output_contains "channel 4: peak -1.00 dBFS"
    assert_output_contains "overall: peak -1.00 dBFS, clipped 0.000% of samples"
}

@test "measure-speaker-chain: analyze reports overs in a float recording" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    float_wav "$BATS_TEST_TMPDIR/f.wav" ok 0.5 -0.25 1.5 0.1 -1.0 0.2 0.25 0.3
    run "$MSC" analyze "$BATS_TEST_TMPDIR/f.wav"
    assert_success
    assert_output_contains "2 ch, 48000 Hz, float32"
    assert_output_contains "channel 1: peak +3.52 dBFS"
    assert_output_contains "clipped 2 of 4 (50.000%)"
    assert_output_contains "overall: peak +3.52 dBFS, clipped 25.000% of samples"
}

@test "measure-speaker-chain: unfinished header is read to the end; silence fails" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    float_wav "$BATS_TEST_TMPDIR/u.wav" 0xFFFFFFFF 0.5 0.5 0.5 0.5
    run "$MSC" analyze "$BATS_TEST_TMPDIR/u.wav"
    assert_success
    assert_output_contains "overall: peak -6.02 dBFS"
    float_wav "$BATS_TEST_TMPDIR/z.wav" ok 0 0 0 0
    run "$MSC" analyze "$BATS_TEST_TMPDIR/z.wav"
    assert_failure 3
    assert_output_contains "digital silence"
    run "$MSC" frobnicate
    assert_failure 2
    run "$MSC" --point
    assert_failure
}
