# Updating ally-x20-steamos itself

ally-x20-steamos runs from a git checkout at `/var/lib/ally-x20-steamos/src`
(created by `install`, see [install.md](install.md)). `self-update` moves
that checkout to a newer version, runs migrations and re-applies. It never
discards local edits and never installs a release whose signature it
cannot verify, unless you explicitly tell it to. Plan reference: §4.4.

```sh
sudo ally-x20-steamos.sh self-update                    # stable (default, or the remembered channel)
sudo ally-x20-steamos.sh self-update --channel beta     # follow the beta branch
sudo ally-x20-steamos.sh self-update --check            # only report; writes state/last-update-check
sudo ally-x20-steamos.sh self-update --rollback         # back to the commit before the last update
```

## When it runs

- Manually, as above.
- **Before every module rebuild**: `ally-x20-steamos.sh rebuild` and the
  RAUC pre-install handler call `self-update` first, best-effort, so a fix
  pushed for a new Valve kernel is picked up during the SteamOS update that
  introduces that kernel. Exit code `3` means origin was unreachable; those
  callers carry on with the installed version.
- The boot service runs `self-update --check --max-age 86400 --notify` at
  most once a day: it only reports (a notification when a new release
  exists, see [notifications.md](notifications.md)) and never installs.
  Opt out with `sudo touch /var/lib/ally-x20-steamos/state/no-update-check`.

## Channels

| channel | follows | verification |
|---|---|---|
| `stable` (default) | the newest `vX.Y.Z` tag (version sort). Tags with a `-` suffix (`v1.2.0-rc1`) are ignored | the tag object must be signed by a pinned key; unsigned or unknown-key tags are skipped with a warning, so the newest **signed** tag wins |
| `beta` | the `beta` branch, fast-forward only | none by default; `--verify-commits` requires the tip commit to be signed by a pinned key |

An explicit `--channel` is remembered in `state/update-channel` and used by
later runs (including `rebuild` and the boot-time check). Updates never go
backwards: if HEAD already contains the selected tag (or beta tip), nothing
happens. Switching from beta back to stable therefore takes effect at the
first release tag that is not already contained in your beta checkout.

The stable channel leaves the checkout on a detached HEAD at the tag; beta
keeps a local `beta` branch. If the local `beta` branch has diverged from
`origin/beta` (someone committed in the checkout), self-update refuses
instead of rewriting it.

## Local modifications

If `git status --porcelain` in the checkout shows anything (edited,
staged or untracked files), self-update stops and lists them. It never
runs `reset --hard`, `stash` or `clean`. Commit your change on a branch,
move it elsewhere, or remove it, then retry.

## Signing and the pinned key

Release tags are signed by the project owner, with either an OpenPGP key or
an SSH key. The public half lives in [`keys/`](../keys/README.md):

- `keys/*.asc`: ASCII-armored OpenPGP public keys (used via a throwaway
  `GNUPGHOME` that contains only these keys, with `git verify-tag`);
- `keys/allowed_signers`: SSH keys in `ssh-keygen` allowed-signers format
  (used via `gpg.ssh.allowedSignersFile`).

`install` copies them into `/var/lib/ally-x20-steamos/keys` ("pinning").
`self-update` verifies against that pinned copy only, never against the
`keys/` of the checkout or of the incoming tag, so a release cannot bring
its own key. A re-install keeps the existing pin; `install --repin-keys`
replaces it. Key rotation: publish a release whose `keys/` contains the new
key while still signing it with the old key, and ask users to run
`sudo ally-x20-steamos.sh install --repin-keys` after updating.

Besides the signature, the tag object's embedded name must match the tag
ref, so an old signed tag cannot be replayed under a newer name.

Fail-closed: while no real key is pinned (the repository currently ships
placeholders, `TODO(owner)`), every stable update is refused. For
development, or before the owner has published a key,
`--insecure-skip-verify` accepts unsigned tags and prints a loud warning.
`--check` still reports new tags in that state, flagged
`available-unverified`.

## Rollback

Before moving, self-update records the current commit in
`state/self-update.prev`. `self-update --rollback` checks that commit out
(detached), records the commit it left in the same file, and re-applies.
Running `--rollback` twice therefore returns to where you started.
Migrations are not undone (they are written to be harmless for older
versions too).

## Migrations

After checking out a new version, self-update (and `install`) run every
`migrations/[0-9]*.sh` of the **new** checkout in lexical order, each at
most once per device. Applied migrations are listed in
`state/migrations.done` as `<name>\t<ts>\t<commit>`. A failing migration
stops the run, is not recorded, and is retried by the next self-update;
`apply` is not run in that case. How to write one: [`migrations/README.md`](../migrations/README.md).

## Files

| file under `/var/lib/ally-x20-steamos/state/` | written by | content |
|---|---|---|
| `self-update.prev` | update / rollback | commit id to roll back to |
| `migrations.done` | migrations | `<name>\t<ts>\t<commit>` per applied migration |
| `update-channel` | `--channel` | `stable` or `beta` |
| `last-update-check` | `--check` | `<iso-ts>\t<epoch>\t<result>\t<tag-or-commit>`; result is `up-to-date`, `available`, `available-unverified` or `fetch-failed` |
| `no-update-check` | you | presence disables `--check` |

## Exit codes

`0` updated or nothing to do; `1` refused or failed (message explains);
`2` usage error; `3` origin unreachable (offline).

## Where the trusted keys come from

`install` copies `keys/` from the checkout it was run from into
`/var/lib/ally-x20-steamos/keys` ("pinning"). Later self-updates verify
against the pinned copy only, so a fetched release cannot bring its own key.
If `install` was never run (a developer running the CLI straight from a
clone), `su_keys_dir` falls back to the checkout's own `keys/` with a
warning: that is trust-on-first-clone, acceptable for development, and the
warning is there so it is never mistaken for the pinned case.
