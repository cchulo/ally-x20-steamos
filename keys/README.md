# Release signing keys

`self-update` installs a stable release only if its tag is signed by one of
the keys here **as pinned on the device** (`install` copies this directory
to `/var/lib/ally-x20-steamos/keys`; see [docs/self-update.md](../docs/self-update.md)).

Status: `release-signing.asc` is the owner's OpenPGP key (ed25519,
fingerprint `786B 5C9C 5199 A907 58C0 106A 951A 981E 25C1 5FA1`); every
`v*` tag from v0.1.0 on is signed with it. `allowed_signers` is still a placeholder (no SSH key). Devices installed
from a release before v0.1.4 have placeholder pins; `install` and
`self-update` replace those with the real key on their own (trust on first
use, [docs/self-update.md](../docs/self-update.md)).

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

Only `*.asc` files with a line starting `-----BEGIN PGP PUBLIC KEY BLOCK-----`
are imported; a placeholder made of comments is ignored.

## Rules

- Commit public keys only. Never a private key.
- Tags must be annotated and signed (`git tag -s`); lightweight tags are
  never accepted.
- Rotating a key: ship the new key in a release that is still signed with
  the old one, then users run `sudo ally-x20-steamos.sh install --repin-keys`.
- Beta-branch commits may be signed too (`git commit -S`); users opt into
  checking them with `self-update --channel beta --verify-commits`.
