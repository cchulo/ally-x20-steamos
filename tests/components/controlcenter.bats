#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
# components/controlcenter.sh, overlay/bin/control-center-helper and
# overlay/sudoers.d/zz-ally-x20-steamos-control-center (docs/control-center.md).
#
# The helper has no configuration, on purpose. To run it here, test_helper()
# writes a copy whose constant lines (CLI, TRUSTED_UID, TRUST_ANCHOR, LOCK,
# LOGGER) point into the fixture; everything below those lines is the
# shipped code. The unmodified file is tested too (it must refuse).
load '../test_helper'

HELPER=/etc/ally-x20-steamos/control-center-helper
SUDOERS=/etc/sudoers.d/zz-ally-x20-steamos-control-center
OVL="$REPO_ROOT/overlay"
SHIPPED="$OVL/bin/control-center-helper"

setup() {
    umask 022
    make_root >/dev/null
    source_libs
    unset AX20_CONTROLCENTER_SYSTEM_STEPS
    component_load controlcenter
    T="$BATS_TEST_TMPDIR/trust"
    FAKE_SRC="$T/state/src"
    STUB="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$FAKE_SRC" "$T/state/keys" "$STUB"
    chmod 755 "$T" "$T/state" "$FAKE_SRC" "$T/state/keys"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

tree_listing() { (cd "$AX20_ROOT" && find . -path ./var/lib/ally-x20-steamos -prune -o -print | sort); }

# visudo_stub <exit for -cf> [exit for -c] : records its calls.
visudo_stub() {
    cat >"$STUB/visudo" <<S
#!/bin/sh
echo "visudo \$*" >>"$STUB/calls"
case "\$1" in
    -cf) exit $1 ;;
    -c) exit ${2:-0} ;;
esac
exit 2
S
    chmod +x "$STUB/visudo"
    : >"$STUB/calls"
}

# fake_cli [exit code] : a stand-in for ally-x20-steamos.sh that records its
# arguments and its whole environment.
fake_cli() {
    cat >"$FAKE_SRC/ally-x20-steamos.sh" <<S
#!/bin/sh
printf '%s\n' "\$*" >>"$T/args"
env >"$T/env"
pwd >"$T/cwd"
echo "fake cli: \$*"
exit ${1:-0}
S
    chmod 755 "$FAKE_SRC/ally-x20-steamos.sh"
    printf 'key\n' >"$T/state/keys/release.asc"
    rm -f "$T/args" "$T/env"
}

# test_helper : the shipped helper with its constants pointed at the fixture.
test_helper() {
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/log"\n' "$T" >"$STUB/logger"
    chmod +x "$STUB/logger"
    sed -e "s|^CLI=.*|CLI=$FAKE_SRC/ally-x20-steamos.sh|" \
        -e "s|^TRUSTED_UID=.*|TRUSTED_UID=$(id -u)|" \
        -e "s|^TRUST_ANCHOR=.*|TRUST_ANCHOR=$T|" \
        -e "s|^LOCK=.*|LOCK=$T/lock|" \
        -e "s|^LOGGER=.*|LOGGER=$STUB/logger|" \
        "$SHIPPED" >"$BATS_TEST_TMPDIR/helper"
    chmod 755 "$BATS_TEST_TMPDIR/helper"
    H="$BATS_TEST_TMPDIR/helper"
}

# ---------------------------------------------------------------- component --

@test "files: only the helper is in the file list; the drop-in is installed by apply after visudo" {
    run component_files controlcenter
    assert_success
    [ "$output" = "$(printf 'bin/control-center-helper\t%s\t0755' "$HELPER")" ]
}

@test "probe: always needed; opt-in, so status is off until it is applied" {
    run component_probe controlcenter
    [ "$status" -eq 1 ]
    component_opt_in controlcenter
    [ "$(component_status controlcenter)" = off ]
}

@test "apply: helper 0755 and drop-in 0440, both recorded; visudo checked the source first" {
    visudo_stub 0
    PATH="$STUB:$PATH" run component_apply controlcenter
    assert_success
    [ "$(mode_of "$AX20_ROOT$HELPER")" = 755 ]
    [ "$(mode_of "$AX20_ROOT$SUDOERS")" = 440 ]
    cmp "$AX20_ROOT$HELPER" "$SHIPPED"
    cmp "$AX20_ROOT$SUDOERS" "$OVL/sudoers.d/zz-ally-x20-steamos-control-center"
    manifest_has "$HELPER"
    manifest_has "$SUDOERS"
    [ "$(manifest_paths controlcenter | grep -c -e control-center)" = 2 ]
    # fixture root: only the source file is checked, not the live configuration
    [ "$(cat "$STUB/calls")" = "visudo -cf $OVL/sudoers.d/zz-ally-x20-steamos-control-center" ]
    [ "$(component_status controlcenter)" = active ]
}

@test "apply is idempotent" {
    visudo_stub 0
    PATH="$STUB:$PATH" component_apply controlcenter
    PATH="$STUB:$PATH" run component_apply controlcenter
    assert_success
    [ -z "$(manifest_paths controlcenter | sort | uniq -d)" ]
    [ "$(mode_of "$AX20_ROOT$SUDOERS")" = 440 ]
}

@test "apply: visudo rejects the drop-in, nothing reaches /etc/sudoers.d" {
    visudo_stub 1
    PATH="$STUB:$PATH" run component_apply controlcenter
    assert_failure
    assert_output_contains "visudo rejected"
    [ ! -e "$AX20_ROOT/etc/sudoers.d" ]
    run manifest_has "$SUDOERS"
    assert_failure
}

@test "apply: no visudo on the system, nothing reaches /etc/sudoers.d" {
    ax20_have() { [ "$1" != visudo ] && command -v "$1" >/dev/null 2>&1; }
    run component_apply controlcenter
    assert_failure
    assert_output_contains "visudo not found"
    [ ! -e "$AX20_ROOT/etc/sudoers.d" ]
    run manifest_has "$SUDOERS"
    assert_failure
}

@test "apply on a live system: the whole configuration is checked afterwards" {
    visudo_stub 0 0
    PATH="$STUB:$PATH" AX20_CONTROLCENTER_SYSTEM_STEPS=always run component_apply controlcenter
    assert_success
    [ "$(sed -n 2p "$STUB/calls")" = "visudo -c" ]
    [ -f "$AX20_ROOT$SUDOERS" ]
}

@test "apply on a live system: the configuration fails with the drop-in, so it is taken out again" {
    visudo_stub 0 1
    PATH="$STUB:$PATH" AX20_CONTROLCENTER_SYSTEM_STEPS=always run component_apply controlcenter
    assert_failure
    assert_output_contains "removed it again"
    [ ! -e "$AX20_ROOT$SUDOERS" ]
    run manifest_has "$SUDOERS"
    assert_failure
}

@test "dry-run apply writes nothing" {
    visudo_stub 0
    before=$(tree_listing)
    PATH="$STUB:$PATH" run "$CLI" --root "$AX20_ROOT" --dry-run apply --only controlcenter
    assert_success
    [ "$(tree_listing)" = "$before" ]
    [ ! -s "$STUB/calls" ]
}

@test "apply --only controlcenter, then uninstall --component controlcenter restores the tree" {
    visudo_stub 0
    before=$(tree_listing)
    PATH="$STUB:$PATH" "$CLI" --root "$AX20_ROOT" apply --only controlcenter 2>/dev/null
    [ -f "$AX20_ROOT$SUDOERS" ]
    [ -x "$AX20_ROOT$HELPER" ]
    run "$CLI" --root "$AX20_ROOT" uninstall --component controlcenter --keep-state
    assert_success
    [ -z "$(manifest_paths controlcenter)" ]
    [ ! -e "$AX20_ROOT$SUDOERS" ]
    [ ! -e "$AX20_ROOT$HELPER" ]
    [ "$(tree_listing)" = "$before" ]
}

# ------------------------------------------------------------------ sudoers --

@test "sudoers: exactly the alias, its Defaults and one NOPASSWD rule for deck" {
    f="$OVL/sudoers.d/zz-ally-x20-steamos-control-center"
    h=$HELPER
    expected="Cmnd_Alias AX20_CONTROL_CENTER = $h status, $h check, $h update, $h apply, $h rollback
Defaults!AX20_CONTROL_CENTER env_reset, !setenv, secure_path=\"/usr/bin:/usr/sbin:/bin:/sbin\"
deck ALL=(root) NOPASSWD: AX20_CONTROL_CENTER"
    [ "$(grep -v '^#' "$f")" = "$expected" ]
}

@test "sudoers: no wildcard, no bare helper path (which would allow any argument), no ALL command" {
    rules=$(grep -v '^#' "$OVL/sudoers.d/zz-ally-x20-steamos-control-center")
    case "$rules" in *'*'* | *'?'* | *'['*) false ;; esac
    # every mention of the helper is followed by exactly one lower-case word
    [ "$(printf '%s\n' "$rules" | grep -o "$HELPER[^,]*" | grep -cvE "^$HELPER [a-z]+\$")" = 0 ]
    run grep -E 'NOPASSWD: *ALL|SETENV' <<<"$rules"
    assert_failure
}

@test "sudoers: the operations in the drop-in are the operations of the helper" {
    in_sudoers=$(grep '^Cmnd_Alias' "$OVL/sudoers.d/zz-ally-x20-steamos-control-center" | grep -o "$HELPER [a-z]*" | awk '{ print $2 }' | sort | tr '\n' ' ')
    in_helper=$(sed -n '/^case "\$1" in$/,/^esac$/p' "$SHIPPED" | sed -n 's/^    \([a-z]*\)).*/\1/p' | sort | tr '\n' ' ')
    [ -n "$in_helper" ]
    [ "$in_sudoers" = "$in_helper" ]
}

@test "the UI's operation lists (Rust shell, TypeScript) are the helper's" {
    in_helper=$(sed -n '/^case "\$1" in$/,/^esac$/p' "$SHIPPED" | sed -n 's/^    \([a-z]*\)).*/\1/p' | sort | tr '\n' ' ')
    ui="$REPO_ROOT/ui/control-center"
    in_rust=$(grep '^const OPERATIONS' "$ui/src-tauri/src/main.rs" | grep -o '"[a-z]*"' | tr -d '"' | sort | tr '\n' ' ')
    in_ts=$(grep '^export const OPERATIONS' "$ui/src/backend.ts" | grep -o '"[a-z]*"' | tr -d '"' | sort | tr '\n' ' ')
    [ "$in_rust" = "$in_helper" ]
    [ "$in_ts" = "$in_helper" ]
    grep -q '^const HELPER: &str = "/etc/ally-x20-steamos/control-center-helper";$' "$ui/src-tauri/src/main.rs"
}

@test "sudoers: file name has no dot (sudo skips those) and sorts after 'wheel' (last match wins)" {
    name=$(basename "$SUDOERS")
    case "$name" in *.* | *~) false ;; esac
    [ "$(printf '%s\n' wheel "$name" | LC_ALL=C sort | tail -n 1)" = "$name" ]
}

@test "sudoers: the real visudo accepts the file (skipped where there is none)" {
    command -v visudo >/dev/null 2>&1 || skip "no visudo on this host"
    run visudo -cf "$OVL/sudoers.d/zz-ally-x20-steamos-control-center"
    assert_success
}

# ------------------------------------------------------------------- helper --

@test "helper: POSIX sh, parses, and never uses eval or sources a file" {
    [ "$(head -n 1 "$SHIPPED")" = '#!/bin/sh' ]
    sh -n "$SHIPPED"
    run grep -nE '^[^#]*(\beval\b|^\. |[[:space:]]\. /|\bsource\b)' "$SHIPPED"
    assert_failure
}

@test "helper: each operation runs its fixed command line" {
    fake_cli
    test_helper
    for pair in "status=status --json" "check=self-update --check" "update=self-update" "apply=apply" "rollback=self-update --rollback"; do
        rm -f "$T/args"
        run "$H" "${pair%%=*}"
        assert_success
        [ "$(cat "$T/args")" = "${pair#*=}" ]
    done
}

@test "helper: output and exit status are the CLI's" {
    fake_cli 3
    test_helper
    run "$H" check
    [ "$status" -eq 3 ]
    assert_output_contains "fake cli: self-update --check"
}

@test "helper: anything but one known word is refused with 64 and the CLI is not started" {
    fake_cli
    test_helper
    for bad in 'status; id' '--root' '--root=/' 'status --json' 'self-update' 'STATUS' ' status' 'status ' '-h' '../status' '$(id)' '`id`' 'status|id' 'install' 'uninstall' ''; do
        run "$H" "$bad"
        [ "$status" -eq 64 ] || { echo "accepted: [$bad] ($status)"; false; }
    done
    run "$H" "$(printf 'status\nid')"
    [ "$status" -eq 64 ]
    [ ! -e "$T/args" ]
}

@test "helper: a second argument is refused, whatever it is" {
    fake_cli
    test_helper
    run "$H" status --json
    [ "$status" -eq 64 ]
    run "$H" --root / status
    [ "$status" -eq 64 ]
    run "$H" update --insecure-skip-verify
    [ "$status" -eq 64 ]
    run "$H" update --channel beta
    [ "$status" -eq 64 ]
    run "$H" apply --slot /
    [ "$status" -eq 64 ]
    run "$H"
    [ "$status" -eq 64 ]
    [ ! -e "$T/args" ]
}

@test "helper: the caller's environment does not reach the CLI" {
    fake_cli
    test_helper
    run env AX20_ROOT=/evil AX20_SRC=/evil AX20_DRY_RUN=1 AX20_ALLOW_UNPRIVILEGED=1 AX20_KVER=x \
        PATH="/evil:$PATH" BASH_ENV=/evil/rc ENV=/evil/rc LD_PRELOAD=/evil.so GIT_DIR=/evil \
        HOME=/evil IFS=x CDPATH=/evil "$H" status
    assert_success
    [ "$(cat "$T/args")" = "status --json" ]
    run grep -c evil "$T/env"
    [ "$output" = 0 ]
    run grep -E '^(AX20_|BASH_ENV=|ENV=|LD_PRELOAD=|GIT_|CDPATH=|SUDO_)' "$T/env"
    assert_failure
    grep -qx 'PATH=/usr/bin:/usr/sbin:/bin:/sbin' "$T/env"
    grep -qx 'HOME=/root' "$T/env"
    [ "$(cat "$T/cwd")" = / ]
}

@test "helper: the environment cannot move its constants either (shipped file, as an ordinary user)" {
    [ "$(id -u)" != 0 ] || skip "running as root"
    fake_cli
    run env CLI="$FAKE_SRC/ally-x20-steamos.sh" TRUSTED_UID="$(id -u)" TRUST_ANCHOR="$T" \
        LOGGER=/usr/bin/true AX20_SRC="$FAKE_SRC" AX20_ROOT="$T" "$SHIPPED" status
    [ "$status" -eq 77 ]
    assert_output_contains "must run as root through sudo"
    [ ! -e "$T/args" ]
}

@test "helper: every call and every refusal is logged with the caller" {
    fake_cli
    test_helper
    SUDO_USER=deck SUDO_UID=1000 run "$H" rollback
    assert_success
    grep -qx -- '-t ally-x20-steamos-control-center -- run (caller deck(1000)): self-update --rollback' "$T/log"
    SUDO_USER=deck SUDO_UID=1000 run "$H" 'status; id'
    grep -q -- 'refused (caller deck(1000)): unknown operation' "$T/log"
    # what was sent is not copied into the log, and a strange caller name is dropped
    run grep -c '; id' "$T/log"
    [ "$output" = 0 ]
    SUDO_USER='x$(id)' run "$H" status
    grep -q -- 'run (caller ?): status --json' "$T/log"
}

@test "helper: CLI missing is 69" {
    test_helper
    run "$H" status
    [ "$status" -eq 69 ]
}

@test "helper: a group- or world-writable file in the checkout is refused with 77" {
    fake_cli
    test_helper
    mkdir -p "$FAKE_SRC/lib"
    printf 'x\n' >"$FAKE_SRC/lib/common.sh"
    run "$H" status
    assert_success
    chmod 664 "$FAKE_SRC/lib/common.sh"
    run "$H" status
    [ "$status" -eq 77 ]
    assert_output_contains "$FAKE_SRC/lib/common.sh"
    chmod 646 "$FAKE_SRC/lib/common.sh"
    run "$H" status
    [ "$status" -eq 77 ]
    chmod 644 "$FAKE_SRC/lib/common.sh"
    chmod 775 "$FAKE_SRC/lib"
    run "$H" status
    [ "$status" -eq 77 ]
    [ "$(wc -l <"$T/args" | tr -d ' ')" = 1 ]
}

@test "helper: a writable directory above the checkout is refused with 77" {
    fake_cli
    test_helper
    chmod 777 "$T/state"
    run "$H" apply
    [ "$status" -eq 77 ]
    assert_output_contains "$T/state"
    chmod 755 "$T/state"
    chmod 775 "$T"
    run "$H" apply
    [ "$status" -eq 77 ]
    [ ! -e "$T/args" ]
}

@test "helper: writable pinned keys are refused with 77" {
    fake_cli
    test_helper
    chmod 666 "$T/state/keys/release.asc"
    run "$H" update
    [ "$status" -eq 77 ]
    [ ! -e "$T/args" ]
}

@test "helper: the state directory may be a symlink (as on SteamOS); the real path is checked" {
    fake_cli
    test_helper
    mkdir "$T/var"
    ln -s ../state "$T/var/link"
    sed -e "s|^CLI=.*|CLI=$T/var/link/src/ally-x20-steamos.sh|" "$H" >"$H.link"
    chmod 755 "$H.link"
    run "$H.link" status
    assert_success
    chmod 777 "$T/state"
    run "$H.link" status
    [ "$status" -eq 77 ]
}

@test "helper: a second changing operation is refused with 75 while one runs (needs flock)" {
    command -v flock >/dev/null 2>&1 || skip "no flock on this host"
    fake_cli
    test_helper
    (
        exec 9>"$T/lock"
        flock -n 9
        run "$H" apply
        [ "$status" -eq 75 ]
        # reading is not blocked
        run "$H" status
        [ "$status" -eq 0 ]
    )
}
