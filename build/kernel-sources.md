# Kernel sources and the module build

How `build/build-modules.sh` finds headers and sources for a SteamOS kernel,
and how to run it on the device, on a PC, and in CI. Background: plan §3 and
§4.5. User-facing behaviour: [`docs/kernel-modules.md`](../docs/kernel-modules.md).

## The kernel version string

The build is keyed by the full `uname -r` of the target kernel, for example

```
7.2.7-valve2-2-neptune-72-g31504582a073
│     │      │ │          └ CONFIG_LOCALVERSION_AUTO: Valve git commit (12 hex digits)
│     │      │ └ localversion.20-pkgname  (pkgbase linux-neptune-72)
│     │      └ localversion.10-pkgrel     (pkgrel 2)
│     └ Valve tag suffix                  (tag 7.2.7-valve2)
└ upstream base
```

From it the script derives the package `linux-neptune-72` at version
`7.2.7.valve2-2` (`pkgver=${_tag//-/.}` in Valve's PKGBUILD), the headers
package `linux-neptune-72-headers`, and the git tag `7.2.7-valve2`. The
`-g<commit>` suffix is part of vermagic: a KVER without it builds modules
that the kernel rejects, so always pass the complete `uname -r`.

## Package mirror layout

Base: `https://steamdeck-packages.steamos.cloud/archlinux-mirror/`

| What | URL |
|---|---|
| repo database (tar.xz, despite the name) | `<repo>/os/x86_64/<repo>.db` |
| kernel package | `<repo>/os/x86_64/linux-neptune-72-7.2.7.valve2-2-x86_64.pkg.tar.zst` |
| headers package | `<repo>/os/x86_64/linux-neptune-72-headers-7.2.7.valve2-2-x86_64.pkg.tar.zst` |
| source package | `sources/<repo>/linux-neptune-72-7.2.7.valve2-2.src.tar.gz` |

Repos that carry kernels: `jupiter-main`, `jupiter-rel`, `jupiter-staging`,
dated snapshots such as `jupiter-staging-2026-10-29`, and per-release
`jupiter-3.x`. There is no `jupiter-beta` repo today. Each database entry
(`<name>-<version>/desc`) has `%FILENAME%`, `%NAME%`, `%VERSION%`,
`%SHA256SUM%`; the script picks the exact name and version and checks the
downloaded file's SHA-256 against `%SHA256SUM%`. The database only lists
the newest build of each package, so an older pkgrel (for example
`7.2.7.valve2-1` once `-2` is out) is no longer found there. That case
falls through to the source steps.

The headers package contains
`usr/lib/modules/<uname -r>/build/{.config,Module.symvers,version,Makefile,scripts,include,...}`
but **no driver `.c` files**. The source package is several GB: it embeds
the whole git history as a bare repository (`archlinux-linux-neptune/`)
next to `PKGBUILD`, `config.x86_64` and `config-neptune`.

### Finding the current kernel of a channel

```sh
repo=jupiter-main
curl -fsSL "https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/x86_64/$repo.db" \
  | tar -tJf - | grep -E '^linux-neptune-[0-9]+-headers-.*/$'
```

The full `uname -r` (with `-g<commit>`) is the directory name inside the
headers package:

```sh
curl -fsSL "https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/x86_64/<headers file>" \
  | zstd -dc | tar -tf - | grep -m1 -oE 'usr/lib/modules/[^/]+' | cut -d/ -f4
```

On the device itself: `uname -r`, or `ls /usr/lib/modules` for the other
slot. Add new versions to `build/kernels.txt` so CI builds them.

## Header resolution order (BUILD-INFO `header_source`)

1. **Cache** — `CACHE_DIR/headers/<kver>/` from an earlier run; BUILD-INFO
   also records `header_origin` (the step that originally produced it).
2. **Valve headers package** from the mirror: the repo given by `CHANNEL`
   first, then `jupiter-main jupiter-rel jupiter-staging` (`BM_ALL_CHANNELS`).
3. **Valve source** + `make modules_prepare`. The source is the evlaV
   GitHub mirror of `gitlab.steamos.cloud/jupiter/linux-integration`
   (`https://github.com/evlaV/linux-integration.git`, tag `<base>-valveN`,
   whose commit must equal the `-g<commit>` suffix), or the mirror's
   `.src.tar.gz`, or `KERNEL_SRC_URL`. The `.config` comes from
   `KERNEL_CONFIG`, else `scripts/extract-ikconfig` on the target kernel
   image (`VMLINUZ`, or the `linux-neptune-*` package from the mirror;
   SteamOS enables `CONFIG_IKCONFIG`), else Valve's `config.x86_64` merged
   with `config-neptune`. `KERNELRELEASE=<kver>` pins vermagic. With no
   published `Module.symvers` the kernel is built once to produce it
   (tens of minutes; `BM_FULL_BUILD=0` disables this).
4. **linux-stable `v<base>`** — only when every file the patches touch, and
   every file under each `M=` directory, is byte-identical to the cached
   Valve tree; otherwise the build fails. This never works for
   `M=drivers/hid`: `hid-asus-ally.c` exists only in Valve's tree.

Steps 1 and 2 provide no `.c` files, so the `M=` directories come from a
blobless sparse checkout of the exact Valve tag (the first two path
components of each `M=` dir, so relative includes like `../../codecs`
resolve), cached in `CACHE_DIR/valve-sparse/<kver>`.

## What the script then does

1. Reads every `patches/kernel/modules*.list` (`<patch>\t<M= dir>\t<ko>`).
   Every file a patch touches must be under its `M=` dir, otherwise a
   headers-based build would silently ignore it.
2. Hard-link copies the source into a work tree and applies the patches in
   file-name order with `git apply`. A patch that only applies in reverse
   is already in Valve's tree: it is skipped and recorded as
   `patch.<file>.status=already-upstream`. A module whose patches are all
   upstream is not built and is recorded as `module.<name>=superseded`.
   A patch that applies neither way fails the build.
3. `make -C <headers> M=<work>/<dir> modules` for each distinct dir.
4. For each listed module: `strip --strip-debug`, `modinfo -F vermagic`
   must start with KVER, every `nm -u` symbol must be exported in
   `Module.symvers` (headers plus the M= dirs' own), and CRCs from
   `modprobe --dump-modversions` must match (SteamOS 7.2 kernels have
   `CONFIG_MODVERSIONS` off, so only presence is checked there).
5. `zstd -19` into `OUT_DIR/<kver>/<name>.ko.zst` and writes `BUILD-INFO`
   (kver, vermagic, header source and URL/sha256, source URL/ref, patch
   hashes and status, module hashes, repo commit, date, container digest).

## Refreshing the container image pins

`build/Containerfile` pins the Arch base image by digest and the package
set by Arch Linux Archive date. Keep the compiler close to the one Valve
used (`CONFIG_CC_VERSION_TEXT` in the headers' `.config`; 7.2.7-valve2 was
built with GCC 16.1.1).

```sh
# newest digest of archlinux:base-devel
tok=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/archlinux:pull" | jq -r .token)
curl -fsSI -H "Authorization: Bearer $tok" \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  https://registry-1.docker.io/v2/library/archlinux/manifests/base-devel | grep -i docker-content-digest
```

Put the digest in `ARG ARCH_IMAGE`, set `ARG ARCH_ARCHIVE_DATE` to the
image's build date (`YYYY/MM/DD`, a day that exists on
archive.archlinux.org), rebuild, and run the build for every kernel in
`build/kernels.txt` before committing.

## Running the build

### On the device (SteamOS, rootless podman)

SteamOS ships podman. Nothing is installed on the host; the image and its
layers live in `~/.local/share/containers` (on `/home`, survives updates).

```sh
sudo ally-x20-steamos rebuild                 # cache -> release asset -> container
sudo ally-x20-steamos rebuild --source container --kver "$(uname -r)"
```

Run as root (boot service, `sudo`), podman is rootful and keeps its images
in `/var/lib/containers`; the build runs as uid 1000 inside the container.
Caches: `/var/lib/ally-x20-steamos/cache/{build,artifacts,build-out}`.
The image can also be used by hand as the `deck` user:

```sh
cd /var/lib/ally-x20-steamos/src
podman build -t localhost/ally-x20-steamos-build -f build/Containerfile build
mkdir -p ~/ax20-build/{cache,out}
podman run --rm --userns=keep-id --security-opt label=disable \
  -v "$PWD:/src:ro" -v ~/ax20-build/cache:/cache -v ~/ax20-build/out:/out \
  -v "/usr/lib/modules/$(uname -r)/vmlinuz:/vmlinuz:ro" -e VMLINUZ=/vmlinuz \
  -e KVER="$(uname -r)" -e CHANNEL=jupiter-main -e HOME=/tmp \
  localhost/ally-x20-steamos-build
```

### On a PC (Fedora or any Linux with podman)

Same `podman` commands as above with any `KVER` (no `VMLINUZ` needed when
the mirror still carries that kernel). `--security-opt label=disable`
avoids relabelling the checkout under SELinux. Without a container, on a
Linux host with `base-devel bc kmod zstd xz cpio pahole python git curl
rsync` equivalents:

```sh
KVER=7.2.7-valve2-2-neptune-72-g31504582a073 build/build-modules.sh \
  --out-dir build/out --cache-dir build/cache
```

`build/out/` and `build/cache/` are git-ignored.

### In CI

`.github/workflows/build-modules.yml` builds every line of
`build/kernels.txt` (or the `kver` input of a manual run) in this
container on `ubuntu-latest`, uploads `modules-<kver>.tar.zst`, its
`.sha256` and `BUILD-INFO-<kver>` as artifacts, and on `v*` tags attaches
them to the GitHub release. Devices download
`https://github.com/cchulo/ally-x20-steamos/releases/latest/download/modules-<kver>.tar.zst`
(override with `AX20_MODULES_RELEASE_URL`). The workflow skips the build
while no `patches/kernel/modules*.list` exists.

## Disk and time

| Path | Size (approx.) | Time |
|---|---|---|
| step 2 headers package | 90 MB download, 320 MB unpacked | ~1 min |
| sparse Valve checkout of the M= dirs | tens of MB | <1 min |
| `make M=sound/soc/amd`, `M=drivers/hid` | | a few minutes |
| step 3 via the `.src.tar.gz` | 3.4 GB download, ~8 GB unpacked | long |
| step 3 full kernel build for Module.symvers | ~15 GB | 20-60 min |

TODO(vm): measure these on the X20 and in the VM.
