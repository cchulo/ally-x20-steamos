# SPDX-License-Identifier: GPL-2.0-only
# Git fixtures for tests/cmd/*.bats: an isolated git config and local bare
# "origin" repositories, so no test ever touches the network or the
# developer's own git/gpg configuration.

# git_isolate : private global git config with a fixed identity, no signing.
git_isolate() {
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_AUTHOR_NAME="Test Owner" GIT_AUTHOR_EMAIL="owner@example.invalid"
    export GIT_COMMITTER_NAME="Test Owner" GIT_COMMITTER_EMAIL="owner@example.invalid"
    cat >"$GIT_CONFIG_GLOBAL" <<'CFG'
[init]
	defaultBranch = main
[commit]
	gpgSign = false
[tag]
	gpgSign = false
[advice]
	detachedHead = false
CFG
}

# commit_all <dir> <message>
commit_all() {
    git -C "$1" add -A >/dev/null
    git -C "$1" commit --quiet -m "$2"
}

# make_bare_origin <work-dir> <bare-dir> : push everything in work to a new bare repo.
make_bare_origin() {
    git init --quiet --bare "$2"
    git -C "$1" remote add origin "$2" 2>/dev/null || git -C "$1" remote set-url origin "$2"
    git -C "$1" push --quiet origin --all
    git -C "$1" push --quiet origin --tags
}

# copy_repo_tree <dest> : the current repo's files (tracked + untracked, not
# ignored), without its git history.
copy_repo_tree() {
    mkdir -p "$1"
    (cd "$REPO_ROOT" && git ls-files -co --exclude-standard -z | xargs -0 tar cf -) | tar xf - -C "$1"
}

# head_of <repo> [rev]
head_of() { git -C "$1" rev-parse "${2:-HEAD}^{commit}"; }
