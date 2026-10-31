# Release signing keys

`self-update` installs a stable release only if its tag is signed by one of
the keys here **as pinned on the device** (`install` copies this directory
to `/var/lib/ally-x20-steamos/keys`; see [docs/self-update.md](../docs/self-update.md)).

Status: **TODO(owner)**. Both files are placeholders, so verification
currently fails closed: every update is refused unless the user passes
`--insecure-skip-verify`.

Use either an SSH key (simplest) or an OpenPGP key. Both may be present;
a tag verified by either is accepted.

## SSH key (recommended)

```sh
# once, on the owner's machine (keep the private key offline / on a hardware key)
ssh-keygen -t ed25519 -C "ally-x20-steamos release key" -f ~/.ssh/ally-x20-steamos-release

# pin the public key
printf '%s namespaces="git" %s\n' "owner@example.invalid" \
    "$(cat ~/.ssh/ally-x20-steamos-release.pub)" >> keys/allowed_signers

# sign a release
git -c gpg.format=ssh -c user.signingkey=~/.ssh/ally-x20-steamos-release \
    tag -s v0.2.0 -m "ally-x20-steamos v0.2.0"
git push origin v0.2.0
```

Replace `owner@example.invalid` with the owner's address. Verify locally with
`git -c gpg.ssh.allowedSignersFile=keys/allowed_signers verify-tag v0.2.0`.

## OpenPGP key

```sh
gpg --quick-gen-key "Owner <owner@example.invalid>" ed25519 sign 2y
gpg --armor --export <KEYID> > keys/release-signing.asc
git -c user.signingkey=<KEYID> tag -s v0.2.0 -m "ally-x20-steamos v0.2.0"
```

Only `*.asc` files containing `-----BEGIN PGP PUBLIC KEY BLOCK-----` are
imported; the placeholder `release-signing.asc` (comments only) is ignored.

## Rules

- Commit public keys only. Never a private key.
- Tags must be annotated and signed (`git tag -s`); lightweight tags are
  never accepted.
- Rotating a key: ship the new key in a release that is still signed with
  the old one, then users run `sudo ally-x20-steamos.sh install --repin-keys`.
- Beta-branch commits may be signed too (`git commit -S`); users opt into
  checking them with `self-update --channel beta --verify-commits`.
