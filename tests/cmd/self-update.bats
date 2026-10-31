#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-2.0-only
load '../test_helper'
load 'git_helper'

STATE=/var/lib/ally-x20-steamos

# Upstream = a copy of this repository with a stub `apply` that records the
# VERSION it ran with. v0.1.0 and v0.2.0 are unsigned annotated tags; v0.2.0
# adds a migration that counts its runs. The device checkout is a clone of
# v0.1.0 at <root>/var/lib/ally-x20-steamos/src, run through its own CLI.
setup() {
    make_root >/dev/null
    git_isolate
    W="$BATS_TEST_TMPDIR/upstream"
    copy_repo_tree "$W"
    cat >"$W/cmd/apply.sh" <<'A'
# SPDX-License-Identifier: GPL-2.0-only
# summary: test stub
cmd_apply() { cat "$AX20_SRC/VERSION" >>"$(ax20_path /var/lib/ally-x20-steamos/applied)"; }
A
    printf '0.1.0\n' >"$W/VERSION"
    git -C "$W" init --quiet
    commit_all "$W" "release 0.1.0"
    git -C "$W" tag -a v0.1.0 -m v0.1.0
    printf '0.2.0\n' >"$W/VERSION"
    cat >"$W/migrations/0002-test.sh" <<'M'
# SPDX-License-Identifier: GPL-2.0-only
printf 'x\n' >>"$AX20_ROOT/var/lib/ally-x20-steamos/mig-count"
M
    commit_all "$W" "release 0.2.0"
    git -C "$W" tag -a v0.2.0 -m v0.2.0
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    make_bare_origin "$W" "$ORIGIN"
    SRC="$AX20_ROOT$STATE/src"
    git clone --quiet --branch v0.1.0 "$ORIGIN" "$SRC"
    SU="$SRC/ally-x20-steamos.sh"
    V1=$(head_of "$W" v0.1.0)
    V2=$(head_of "$W" v0.2.0)
    mkdir -p "$AX20_ROOT$STATE/keys"
    cp "$W/keys/allowed_signers" "$AX20_ROOT$STATE/keys/"
}

# ssh_signing_key : create an SSH key, pin it, print the private key path.
ssh_signing_key() {
    ssh-keygen -q -t ed25519 -N '' -C test -f "$BATS_TEST_TMPDIR/signkey" >/dev/null
    printf 'owner@example.invalid namespaces="git" %s\n' "$(cat "$BATS_TEST_TMPDIR/signkey.pub")" \
        >"$AX20_ROOT$STATE/keys/allowed_signers"
    printf '%s\n' "$BATS_TEST_TMPDIR/signkey"
}

# new_release <tag> [git tag options...] : commit and tag in upstream, push.
new_release() {
    local tag=$1
    shift
    printf '%s\n' "${tag#v}" >"$W/VERSION"
    commit_all "$W" "release $tag"
    git -C "$W" "$@" tag -a "$tag" -m "$tag"
    git -C "$W" push --quiet origin main --tags
}

@test "refuses when no signing key is pinned (fail-closed)" {
    run "$SU" self-update
    assert_failure
    assert_output_contains "no release signing key is pinned"
    [ "$(head_of "$SRC")" = "$V1" ]
}

@test "unsigned tags are refused even with a key pinned" {
    ssh_signing_key >/dev/null
    run "$SU" self-update
    assert_failure
    assert_output_contains "not signed by a pinned key"
    [ "$(head_of "$SRC")" = "$V1" ]
}

@test "--insecure-skip-verify checks out the newest tag, migrates, applies, records prev" {
    run "$SU" self-update --insecure-skip-verify
    assert_success
    assert_output_contains "WARNING: --insecure-skip-verify"
    assert_output_contains "updated to v0.2.0"
    [ "$(head_of "$SRC")" = "$V2" ]
    [ "$(cat "$AX20_ROOT$STATE/state/self-update.prev")" = "$V1" ]
    [ "$(cat "$AX20_ROOT$STATE/applied")" = 0.2.0 ]
    [ "$(wc -l <"$AX20_ROOT$STATE/mig-count" | tr -d ' ')" = 1 ]
    cut -f1 "$AX20_ROOT$STATE/state/migrations.done" | grep -qx 0001-initial.sh
    cut -f1 "$AX20_ROOT$STATE/state/migrations.done" | grep -qx 0002-test.sh
    run "$SU" self-update --insecure-skip-verify
    assert_success
    assert_output_contains "already up to date"
}

@test "refuses to update over local modifications" {
    printf 'my edit\n' >>"$SRC/README.md"
    run "$SU" self-update --insecure-skip-verify
    assert_failure
    assert_output_contains "local modifications"
    assert_output_contains "README.md"
    [ "$(head_of "$SRC")" = "$V1" ]
    grep -q 'my edit' "$SRC/README.md"
}

@test "--rollback returns to the previous commit and re-applies; migrations run once" {
    run "$SU" self-update --insecure-skip-verify
    assert_success
    run "$SU" self-update --rollback
    assert_success
    [ "$(head_of "$SRC")" = "$V1" ]
    [ "$(tail -n1 "$AX20_ROOT$STATE/applied")" = 0.1.0 ]
    [ "$(cat "$AX20_ROOT$STATE/state/self-update.prev")" = "$V2" ]
    run "$SU" self-update --insecure-skip-verify
    assert_success
    [ "$(head_of "$SRC")" = "$V2" ]
    [ "$(wc -l <"$AX20_ROOT$STATE/mig-count" | tr -d ' ')" = 1 ]
}

@test "--rollback without a previous update fails clearly" {
    run "$SU" self-update --rollback
    assert_failure
    assert_output_contains "nothing to roll back"
}

@test "a failing migration stops the update and is retried next time" {
    cat >"$W/migrations/0003-fails.sh" <<'M'
# SPDX-License-Identifier: GPL-2.0-only
[ -e "$AX20_ROOT/fixed" ]
M
    new_release v0.3.0
    run "$SU" self-update --insecure-skip-verify --no-apply
    assert_failure
    assert_output_contains "migration 0003-fails.sh failed"
    ! cut -f1 "$AX20_ROOT$STATE/state/migrations.done" | grep -qx 0003-fails.sh
    touch "$AX20_ROOT/fixed"
    run "$SU" self-update --rollback --no-apply
    run "$SU" self-update --insecure-skip-verify --no-apply
    assert_success
    cut -f1 "$AX20_ROOT$STATE/state/migrations.done" | grep -qx 0003-fails.sh
}

@test "--check reports, writes the marker, notifies once, honours --max-age and the opt-out" {
    run "$SU" self-update --check --insecure-skip-verify --notify
    assert_success
    assert_output_contains "v0.2.0"
    [ "$(cut -f3,4 "$AX20_ROOT$STATE/state/last-update-check")" = "$(printf 'available-unverified\tv0.2.0')" ]
    [ "$(head_of "$SRC")" = "$V1" ] # --check never installs

    key=$(ssh_signing_key)
    new_release v0.3.0 -c gpg.format=ssh -c user.signingkey="$key" -c tag.gpgSign=true
    run "$SU" self-update --check --notify
    assert_success
    assert_output_contains "update available: v0.3.0"
    [ "$(cut -f3,4 "$AX20_ROOT$STATE/state/last-update-check")" = "$(printf 'available\tv0.3.0')" ]
    q="$AX20_ROOT$STATE/state/notifications.queue"
    [ "$(grep -c 'v0.3.0 is available' "$q")" = 1 ]
    run "$SU" self-update --check --notify
    [ "$(grep -c 'v0.3.0 is available' "$q")" = 1 ]

    before=$(cat "$AX20_ROOT$STATE/state/last-update-check")
    run "$SU" self-update --check --max-age 3600
    assert_success
    assert_output_contains "checked recently"
    [ "$(cat "$AX20_ROOT$STATE/state/last-update-check")" = "$before" ]

    touch "$AX20_ROOT$STATE/state/no-update-check"
    rm -f "$AX20_ROOT$STATE/state/last-update-check"
    run "$SU" self-update --check
    assert_success
    assert_output_contains "disabled"
    [ ! -e "$AX20_ROOT$STATE/state/last-update-check" ]
}

@test "SSH-signed tag: newest signed release wins, unsigned and replayed tags are ignored" {
    key=$(ssh_signing_key)
    new_release v0.3.0 -c gpg.format=ssh -c user.signingkey="$key" -c tag.gpgSign=true
    V3=$(head_of "$W" v0.3.0)
    new_release v0.4.0 # unsigned, newer
    # Replay: the signed v0.3.0 tag object published under a newer name.
    git -C "$ORIGIN" update-ref refs/tags/v0.9.0 "$(git -C "$W" rev-parse v0.3.0)"
    run "$SU" self-update
    assert_success
    assert_output_contains "updated to v0.3.0"
    assert_output_contains "tag v0.9.0 is not signed by a pinned key"
    assert_output_contains "tag v0.4.0 is not signed by a pinned key"
    [ "$(head_of "$SRC")" = "$V3" ]
}

@test "a release cannot bring its own key: only the pinned copy is trusted" {
    key=$(ssh_signing_key)
    # The signed release ships the matching key in keys/, but the pinned
    # copy on the device is still the placeholder.
    cp "$AX20_ROOT$STATE/keys/allowed_signers" "$W/keys/allowed_signers"
    cp "$SRC/keys/allowed_signers" "$AX20_ROOT$STATE/keys/allowed_signers"
    new_release v0.3.0 -c gpg.format=ssh -c user.signingkey="$key" -c tag.gpgSign=true
    run "$SU" self-update
    assert_failure
    assert_output_contains "no release signing key is pinned"
    [ "$(head_of "$SRC")" = "$V1" ]
}

@test "GPG-signed tag verifies against a pinned .asc key" {
    command -v gpg >/dev/null 2>&1 || skip "gpg not installed on this host"
    export GNUPGHOME
    GNUPGHOME=$(mktemp -d "${TMPDIR:-/tmp}/ax20t.XXXXXX")
    chmod 700 "$GNUPGHOME"
    if ! gpg --batch --quiet --passphrase '' --quick-gen-key 'Test Owner <owner@example.invalid>' ed25519 sign never 2>/dev/null; then
        gpgconf --kill all || true
        rm -rf "$GNUPGHOME"
        skip "gpg cannot generate a key on this host"
    fi
    gpg --batch --armor --export owner@example.invalid >"$AX20_ROOT$STATE/keys/release-signing.asc"
    new_release v0.3.0 -c user.signingkey=owner@example.invalid -c tag.gpgSign=true
    V3=$(head_of "$W" v0.3.0)
    gh=$GNUPGHOME
    unset GNUPGHOME # verification must use only the pinned key
    run "$SU" self-update
    GNUPGHOME=$gh gpgconf --kill all || true
    rm -rf "$gh"
    assert_success
    [ "$(head_of "$SRC")" = "$V3" ]
}

@test "beta channel fast-forwards the beta branch and remembers the channel" {
    git -C "$W" branch beta v0.2.0
    printf 'beta 1\n' >"$W/BETA"
    git -C "$W" checkout --quiet beta
    commit_all "$W" "beta 1"
    git -C "$W" push --quiet origin beta
    B1=$(head_of "$W")
    run "$SU" self-update --channel beta
    assert_success
    [ "$(head_of "$SRC")" = "$B1" ]
    [ "$(git -C "$SRC" symbolic-ref --short HEAD)" = beta ]
    [ "$(cat "$AX20_ROOT$STATE/state/update-channel")" = beta ]
    printf 'beta 2\n' >>"$W/BETA"
    commit_all "$W" "beta 2"
    git -C "$W" push --quiet origin beta
    run "$SU" self-update # channel remembered
    assert_success
    [ "$(head_of "$SRC")" = "$(head_of "$W")" ]
    [ "$(cat "$AX20_ROOT$STATE/state/self-update.prev")" = "$B1" ]
}

@test "beta refuses a diverged local beta branch and unsigned tips with --verify-commits" {
    git -C "$W" branch beta v0.2.0
    git -C "$W" push --quiet origin beta
    run "$SU" self-update --channel beta --verify-commits
    assert_failure
    assert_output_contains "not signed by a pinned key"
    run "$SU" self-update --channel beta
    assert_success
    printf 'local\n' >"$SRC/LOCAL"
    git -C "$SRC" add LOCAL
    git -C "$SRC" commit --quiet -m local
    git -C "$W" checkout --quiet beta
    printf 'upstream\n' >"$W/UP"
    commit_all "$W" "upstream"
    git -C "$W" push --quiet origin beta
    run "$SU" self-update --channel beta
    assert_failure
    assert_output_contains "diverged"
}

@test "offline (origin unreachable) exits 3 and changes nothing" {
    git -C "$SRC" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
    run "$SU" self-update --insecure-skip-verify
    assert_failure 3
    [ "$(head_of "$SRC")" = "$V1" ]
    run "$SU" self-update --check
    assert_failure 3
    [ "$(cut -f3 "$AX20_ROOT$STATE/state/last-update-check")" = fetch-failed ]
}

@test "not a git checkout: clear error" {
    src="$BATS_TEST_TMPDIR/plain"
    mkdir -p "$src"
    cp -R "$REPO_ROOT/ally-x20-steamos.sh" "$REPO_ROOT/VERSION" "$REPO_ROOT/lib" "$REPO_ROOT/cmd" "$src/"
    run "$src/ally-x20-steamos.sh" self-update
    assert_failure
    assert_output_contains "not a git checkout"
}

@test "--dry-run changes nothing" {
    run "$SU" --dry-run self-update --insecure-skip-verify
    assert_success
    [ "$(head_of "$SRC")" = "$V1" ]
    [ ! -e "$AX20_ROOT$STATE/state/self-update.prev" ]
    [ ! -e "$AX20_ROOT$STATE/applied" ]
}
