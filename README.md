# ally-x20-steamos

Out-of-tree support for the **ASUS ROG Xbox Ally X20** (board `RC74XA`) on
**stock SteamOS**. No custom distribution, no Anatase, no HHD. Everything is
built from source, survives SteamOS A/B updates, is fully reversible, and is
testable in a VM before it ever touches the device.

> **AI-assisted.** The code, patches, tests and documentation in this
> repository were written with AI assistance (Claude) under the owner's
> direction, and reviewed and tested by the owner on a single ROG Xbox Ally
> X20. It ships patched kernel modules and an ACPI table override: read what
> you run, back up what matters to you, and use it at your own risk. Issues
> and reports are welcome.
>
> **Use at your own discretion.** This is a hobby project by one owner for
> one device. The owner is not responsible for a broken, bricked or
> warranty-voided Ally X20, lost data, or anything else that follows from
> using it. If you are not comfortable with patched kernel modules, boot
> entry edits and an ACPI override on your handheld, wait for official
> SteamOS support for the X20 instead, or use a distribution that already
> targets it, such as [Anatase](https://github.com/anatase-org/anatase),
> if you absolutely need Linux on it today.

**New here? Read the [user guide](docs/user-guide.md)**: what it fixes and
what not yet, how to install, check, update and remove it, and how to report
a problem.

## Install and update

**Install** (Desktop Mode, Konsole). Clone, check out the newest release,
read what you are about to run as root, then install:

```sh
git clone https://github.com/cchulo/ally-x20-steamos.git
cd ally-x20-steamos
git checkout "$(git tag -l 'v*' --sort=-version:refname | head -n1)"   # newest release
sudo ./ally-x20-steamos.sh install
```

`install` copies the release to `/var/lib/ally-x20-steamos/src`, pins the
release signing key, applies every component and prints a status. Reboot
when it asks. The clone in your home directory can be deleted afterwards:
everything runs from `/var/lib/ally-x20-steamos/src` from now on.

**Update** to the newest release. Run this from the installed copy, not
from a clone in your home directory (a clone updates only itself):

```sh
cd /var/lib/ally-x20-steamos/src
sudo ./ally-x20-steamos.sh self-update --check   # is there a new release?
sudo ./ally-x20-steamos.sh self-update           # fetch it, verify the signature, re-apply
```

What an update consists of: the code comes from the signed git tag
(`self-update` fetches tags and checks out the newest signed `vX.Y.Z`), and
the patched kernel modules come from that release's GitHub assets, which
`self-update` stages for the running kernel right after re-applying (since
v0.1.8; on v0.1.7 run `sudo ./ally-x20-steamos.sh rebuild` once after
updating). **Reboot after every update**: new modules only load at boot,
and nothing here reloads them live. `self-update --rollback` returns to the
previous release. If `self-update` rejects every tag (installs made before
v0.1.4 have placeholder keys and code that does not understand them),
repeat the **Install** steps from a fresh clone: re-running `install` is
safe and moves the installed copy to that release.

**Supported: SteamOS stable only.** The project is developed and tested
against the SteamOS **stable** channel, and release module builds exist
only for its kernels. On the beta, preview or main channel it may work in
part: a component that cannot be applied is skipped while the others are
installed, a kernel patch that does not apply leaves that driver stock
while the others are still built, and `status` shows what was left out and
why. Using those channels is your own decision and your own risk: **no
support is provided for anything other than SteamOS stable.**

**Check** that everything is active: `sudo ./ally-x20-steamos.sh status`.
**Remove** it: `sudo ./ally-x20-steamos.sh uninstall`. Details, including
SteamOS updates and troubleshooting: [user guide](docs/user-guide.md),
[docs/install.md](docs/install.md), [docs/self-update.md](docs/self-update.md).

> **Status: first release.** Tested by the owner on one X20 (BIOS
> `RC74XA.303`, SteamOS 3.9.5, kernel `7.2.7-valve2`). Other BIOS, SteamOS or
> kernel versions may behave differently.
> [`docs/hardware-data.md`](docs/hardware-data.md) lists what is still
> unconfirmed on the hardware. The design is in
> [`X20-STEAMOS-PLAN.md`](X20-STEAMOS-PLAN.md).

## What it fixes

| Gap on stock SteamOS | Fix | Component / docs |
|---|---|---|
| **Speakers silent.** Two TI TAS2783 amps on AMD SoundWire; the BIOS flags the machine as DMIC-only, the kernel has no link layout, the driver asks for a firmware name linux-firmware does not ship, and there is no UCM profile. | ACPI table override as an early initrd (pure-Python tool, no `iasl`), a rebuilt `snd-soc-acpi-amd-match` (plus the amp driver and SoundWire helpers with four fixes backported from Valve 7.2.10), firmware download keyed on the `SPEAKER_ID` UEFI variable, UCM overlay | `audio`, `modules` · [docs/audio.md](docs/audio.md) |
| **Controller not matched** by the bundled InputPlumber 0.78; top-right (action) button dead; rumble weak at 100 % and strong rumble makes the speakers hiss. | Upstream X20 profile as a `devices.d` drop-in (adapted to the stock daemon's schema) with an X20 button map (action button → Quick Access, Armoury Crate and Xbox → Steam button; `buttons layout legacy` brings back the earlier layout) + hwdb autostart + the controller's mode settings re-sent after every resume; `0xa0` → `KEY_PROG2` in the rebuilt `hid-asus-ally`, which also scales rumble to the MCU's 0-100 range | `inputplumber`, `modules` · [docs/inputplumber.md](docs/inputplumber.md) |
| **Joystick ring RGB** missing from Steam's Customization menu. | `hid-asus-ally` registers the LED under a name Steam knows, with a fixed R/G/B channel layout and effect/speed attributes | `modules` · [docs/rgb.md](docs/rgb.md) |
| **Xbox button light** dark on Linux. | `xbox-led on\|off\|brightness\|breathe` sends the controller the reports Armoury Crate uses (captured on Windows, verified on the X20); the driver keeps on/off; a udev rule re-sends brightness/breathe at boot and a systemd unit after resume; no Steam menu for it | `xboxled`, `modules` · [docs/rgb.md](docs/rgb.md#xbox-button-light) |
| **HDR not detected** (panel metadata lives in a DisplayID 2 block). | libdisplay-info 0.3.0 + DisplayID 2 backport via `ld.so.conf.d` (Desktop Mode); gamescope Lua display profile for the panel, loaded by stock gamescope (Game Mode); optional custom gamescope behind a stock-fallback wrapper | `hdr` · [docs/hdr.md](docs/hdr.md) |
| **No power profiles in Steam's Performance menu.** steamos-manager 26.4.1 has no X20 device file. | The upstream steamos-manager RC74XA entry, merged into `/usr/share/steamos-manager/devices` by a boot-time bind mount of a copy in `/run` (nothing written to `/usr`, steps aside once SteamOS ships it): Low power / Balanced / Performance hold the APU at about 12 / 16-21 / 25-30 W on battery. No TDP slider on purpose: BIOS `RC74XA.303` ignores PPT writes (`power tdp-slider on` to re-test; the mainline `asus-armoury` RC74XA table is still built) | `power`, `modules` · [docs/power.md](docs/power.md) |
| **Built-in headphones and speakers are stereo only**, so games send a stereo mix. | A user service puts an 8-channel PipeWire sink in front of the built-in output in use and convolves it with a head-related impulse response set; it becomes the default by priority, no default is forced. Four heads, each as `-dry` (fronts unfiltered) and `-full`; `-dry` is recommended on both outputs (by the owner's ear, `-full` makes the fronts sound quieter on the speakers and may suit headphones for sharper positioning). Each output has its own profile: headphones default to `sadie-d2-dry`, speakers to `sadie-d2-dry` with crosstalk cancellation (60 µs, 50 %), which is generated on the device and applies to the speakers only. `surround set <headphones\|speakers> <profile>` switches on the fly, the new filter starting before the old one stops, and `user` takes your own HeSuVi file | `surround` · [docs/surround.md](docs/surround.md) |
| **SD Express card never mounts; Steam's Format button fails on it.** The card is a PCIe/NVMe device and stock's automount rule only matches `mmcblk*\|sd*`; `format-device.sh` rejects nvme nodes. | One udev rule that hands the card's partitions to the stock `block-device-event.sh` / `holo-automount.sh` (udisks mount at `/run/media/deck/<label>`), matched by the slot's PCIe root port because the card and the SSD swap `nvmeN` names between boots; `sdexpress format` runs the stock format sequence (GPT, ext4 casefold, owned by deck) | `sdexpress` · [docs/sdexpress.md](docs/sdexpress.md) |
| **SteamOS updates wipe out-of-tree changes.** | RAUC pre/post-install handlers, boot service, user notifier; `block`/`degrade` policy when modules cannot be built for an incoming kernel | `update` · [docs/update-survival.md](docs/update-survival.md) |

Audio plays through the hardware sinks as on stock SteamOS. The headphone
virtual surround and speaker DSP were removed on 2026-11-01 after a
level-matched A/B on the device; `apply` removes them from older installs
([docs/audio-dsp-history.md](docs/audio-dsp-history.md)).

## Principles

- **Only add files, never edit stock ones.** Everything goes through drop-in
  directories with an `ally-x20-steamos`/`x20` marker in the name and is
  recorded in a manifest. Two documented exceptions (the slot's GRUB boot
  entry and the RAUC handler registration) are saved first and restored
  byte-for-byte.
- **Nothing under `/usr`, ever.** `steamos-readonly` is never toggled; a
  policy test fails the build if the string appears.
- **Survives updates.** State lives in `/var/lib/ally-x20-steamos`, a symlink
  into the shared `/home` partition (SteamOS has a separate 256 MiB `var`
  per slot). A RAUC hook and a boot service re-derive `/etc` drop-ins, the
  boot entry and the kernel modules for a freshly staged slot.
- **One failure does not take the rest down.** A component that cannot be
  applied is skipped and recorded; the others are applied. A kernel patch
  that does not apply leaves its module stock; the other modules are built.
  Release builds stay strict: a release never ships a partial module set.
- **Never a broken boot.** Patched modules load only when the running kernel
  matches the build; otherwise stock behaviour. A custom gamescope that does
  not accept the session's flags execs the stock one.
- **Reversible from any state.** The standalone POSIX uninstaller works from
  a partial manifest, mid-update, from the other slot, or from recovery
  media, and refuses a deny-list of paths even if the manifest is crafted.
- **Probes, never auto-removal.** When a SteamOS update ships a fix natively
  the component is reported `superseded` and you choose to run
  `uninstall --superseded`.

## CLI

Install and update steps are at the top ([Install and update](#install-and-update)).
There is also a `bootstrap.sh` one-liner; [docs/install.md](docs/install.md)
explains why cloning and reading first is preferred.


```
ally-x20-steamos.sh [--root <dir>] [--dry-run] [--verbose] [--yes] [--i-know] <command>
```

| Command | Purpose |
|---|---|
| `install` | bootstrap: clone to `/var/lib/ally-x20-steamos/src`, pin keys, `apply`, `status` |
| `apply [--slot <mount>] [--only <c>] [--missing-only] [--verify-only]` | (re)install components here or into a mounted slot; idempotent. A component that fails is skipped, the others are applied, exit code 4 |
| `status [--json] [--verbose]` | per component `active` / `partial` / `stock` / `superseded` / `n/a` and what the last apply did to it, kernel, policy |
| `probe [--notify]` | "has SteamOS caught up?" per component |
| `rebuild [--kver <v>] [--strict]` | fetch or build the patched kernel modules (cache → release asset → container build; a container build may be partial on an unsupported kernel) |
| `self-update [--channel stable\|beta] [--check] [--rollback]` | signed-tag update of the checkout, migrations, re-apply |
| `buttons status\|layout [deck\|legacy]` | what the two top buttons do: `deck` (default) = action button opens Quick Access, Armoury Crate is the Steam button; `legacy` = Armoury Crate opens Quick Access, action button takes a screenshot |
| `power status\|tdp-slider [on\|off]` | power profiles; the TDP slider test switch (default off) |
| `surround status\|list\|set <headphones\|speakers> <profile>\|xtc off\|xtc <delay_us> <strength_pct>\|prepare` | virtual 7.1 surround for the built-in outputs: pick a profile per output, set the speakers' crosstalk cancellation, generate and check its tested settings for the speakers' profile (as the user, no sudo; kept across updates) |
| `sdexpress status\|format [--label <l>] [--full] [--validate]\|mount\|root-port [<bdf>]` | the SD Express slot: automount state, format a card like Steam does (root; the card is found by PCIe root port, never by `nvmeN`) |
| `xbox-led on\|off\|brightness <0-3>\|breathe on\|off\|restore\|node` | the Xbox button light (root; kept across reboots: on/off by the patched driver, brightness/breathe by component `xboxled`) |
| `update-policy show\|block\|degrade [--once]` | what an update does if modules cannot be built |
| `boot-entry show\|set\|clear\|apply\|restore` | the boot-entry exception (early initrd, cmdline args) |
| `audit [--json]` | manifest vs filesystem: modified, missing, unexpected |
| `uninstall [--superseded] [--component <c>] [--force] [--keep-state] [--reboot]` | remove what we added, restore saved originals |
| `components`, `version`, `help` | introspection |

Exit codes of `install`, `apply` and `self-update`: `0` done, `1` error,
`2` usage, `3` (`self-update`) offline, `4` done except for components that
failed and were skipped. The outcome per component of the last run is kept
in `/var/lib/ally-x20-steamos/state/last-apply.json`
([schema](docs/architecture.md#statelast-applyjson)).

`boot`, `notify` and `rauc-handler` are internal entry points for the systemd
units and RAUC. Every command accepts `--root <dir>` and runs unchanged
against a fixture tree, which is how the test suite works.

## Repository layout

```
ally-x20-steamos.sh   CLI dispatcher            lib/          common, manifest, probes, component, retired, slots, rauc, modules, selfupdate, status, lastapply, notify
cmd/                  one file per command      components/   audio, hdr, inputplumber, modules, power, sdexpress, surround, update, xboxled
overlay/              files installed on the device (manifest-tracked)   uninstall/   standalone POSIX uninstaller
patches/kernel/       0001-0008 ASoC (audio), 0010-0015 hid-asus-ally, 0020 asus-armoury   patches/{gamescope,libdisplay-info}/
build/                Containerfile, build-modules.sh, build-hdr.sh, build-inputplumber.sh, kernel-sources.md
acpi/                 patch-acp-flag.py (DSDT flag patch + early initrd), dump-dsdt.md, fixtures/, tests/
firmware/             tas2783.lock, fetch-tas2783.sh, speaker-id.map       keys/        release signing key (OpenPGP)   
vm/                   run-steamos-vm.sh, setup-fedora-host.sh, guest/ scripts, test LED module, ci/
migrations/           idempotent self-update migrations                     tests/       bats suites (shell), fixtures
docs/                 user and developer documentation (index: docs/README.md)
.github/workflows/    test.yml (lint + unit, Ubuntu + macOS bash 3.2), build-modules.yml, vm-tests.yml
```

## Developing

```sh
make check      # shellcheck + shfmt + SPDX headers, then bats + pytest
make test       # tests only
./ally-x20-steamos.sh --root /tmp/fixture status   # everything runs against a fixture root
```

Requirements on a dev host: bash (3.2 is enough; SteamOS has 5), `bats-core`,
`shellcheck`, `shfmt`, `jq`, `python3` + `pytest`. Compiling kernel modules,
the HDR stack and the VM runs need an x86 Linux host with KVM and podman
(see [docs/vm-testing.md](docs/vm-testing.md) and `vm/setup-fedora-host.sh`).
Read [docs/contributing.md](docs/contributing.md) before opening a PR.

## Roadmap

Milestones 1 to 8 of the plan exist as code and run on the owner's X20;
v0.1.0 is the first release, with CI-built module artifacts attached to
the GitHub release. Still open: the `TODO(hw)` items in
[docs/hardware-data.md](docs/hardware-data.md), a real SteamOS A/B update on
the device, the VM round-trip tests, and the optional Decky plugin.

## FAQ and gotchas

Things the owner ran into that you may run into too.

**Which button opens Quick Access, and how do I take a screenshot?**
In versions after v0.1.11 the action button (top right) opens Steam's Quick Access
menu, as the right-hand button does on a Steam Deck, and Armoury Crate (top
left) is a second Steam button, like the Xbox button
([issue #68](https://github.com/cchulo/ally-x20-steamos/issues/68)). No
button takes a screenshot by itself any more: hold the Xbox button and press
R1. Up to v0.1.11 Armoury Crate opened Quick Access and the top-right button
took a screenshot; `sudo ./ally-x20-steamos.sh buttons layout legacy` brings
that back, and `buttons layout deck` returns to the default. Armoury Crate
is planned to open a settings screen of this project later. Details:
[docs/inputplumber.md](docs/inputplumber.md#6-x20-buttons).

**My battery stops charging at 80 % and Steam shows no charge limit.**
The limit lives in the controller's EC and survives reboots and operating
systems; Armoury Crate's Battery Care on Windows sets it, and so does
Steam's charge-limit setting (Settings → Power). After a reboot the kernel
attribute reads 0 until something writes it, so Steam shows no limit while
the EC still enforces the old one. Check with
`sudo ./ally-x20-steamos.sh power status` (`charge_limit=`), clear it with
`echo 100 | sudo tee /sys/class/power_supply/BAT1/charge_control_end_threshold`,
or set the value you want in Steam. Nothing in ally-x20-steamos writes a
limit. Details: [docs/power.md](docs/power.md).

**Should I add the SD Express card to `/etc/fstab`?**
No. The `sdexpress` component mounts it at `/run/media/deck/<label>` by
itself. If you added an fstab line for the card earlier, remove it before
you run `sdexpress format`: the format does not check for it and would run
on a card that is still in use. Steps:
[docs/sdexpress.md](docs/sdexpress.md#do-not-mount-the-card-through-etcfstab).

**Can I use a Dolby Atmos for Headphones profile for the virtual surround?**
Yes, as the `user` profile. The file is not shipped, because it is not ours
to redistribute; you supply it:

1. Get an Atmos impulse response file for HeSuVi: a `.wav` with 14 channels
   at 48 kHz. The owner's came from the HRIR collection at
   <https://airtable.com/appayGNkn3nSuXkaz/shruimhjdSakUPg2m/tbloLjoZKWJDnLtTc>
   (look for the Atmos entry and download its 14-channel 48 kHz `.wav`).
2. Copy it to the device, into `~/.config/ally-x20-steamos/surround-user/`.
   From another computer:
   `ssh deck@<device> mkdir -p .config/ally-x20-steamos/surround-user` and
   `scp atmos.wav deck@<device>:.config/ally-x20-steamos/surround-user/`.
3. On the device: `./ally-x20-steamos.sh surround set headphones user`,
   and `./ally-x20-steamos.sh surround set speakers user` if you want it on
   the speakers too. Each output has its own profile.
4. `./ally-x20-steamos.sh surround status` shows `user` with the file name.
   If it shows `user -> sadie-d2-dry` instead, the note under it says what is
   wrong with the file.
5. For the speakers: `./ally-x20-steamos.sh surround prepare` generates the
   twelve tested crosstalk-cancellation settings for your file (about 2 s
   each on the X20 for a file of about 5000 samples) and shows which are
   usable; `surround xtc <delay_us> <strength_pct>` picks one.

Any other HeSuVi file works the same way; the first `.wav` in that folder,
in lexical order, is used. Details: [docs/surround.md](docs/surround.md#your-own-file).

**`self-update` says no release tag is signed by a pinned key.**
Installs made from releases before v0.1.4 pinned placeholder keys, and their
`self-update` does not understand them. Clone fresh, check out the newest
tag and run `sudo ./ally-x20-steamos.sh install` again (see
[Install and update](#install-and-update)); it pins the real key and
moves the installed copy. From then on `self-update` works.

**I ran `self-update`, but after a reboot a new command is "unknown".**
You ran it from a clone in your home directory, which updated that clone
only. The device uses `/var/lib/ally-x20-steamos/src`; run `self-update`
(and everything else) from there.

**I updated, but a change to a kernel driver is not active.**
Reboot first; modules only load at boot. If it is still the old driver,
the staged module build was not refreshed. Since v0.1.8 `self-update`
refreshes it (and refuses a build made from other patches, cached or not);
on v0.1.7 run `sudo ./ally-x20-steamos.sh rebuild`, then reboot.
`sudo ./ally-x20-steamos.sh status` says whether the staged modules match
the installed release.

**The Xbox button light is dark after every reboot.**
The driver rewrites the controller's LED power mask at every boot. Since
v0.1.7 the light is part of that mask: `sudo ./ally-x20-steamos.sh xbox-led on`
lights it and keeps it on across reboots. Its brightness and breathing
(`xbox-led brightness 0-3`, `xbox-led breathe on|off`) are separate
controller commands and reset at reboot. Older versions' `xbox-led on` also
switched the rings' sleep animation on by accident; v0.1.7 fixes that, and a
reboot restores the driver's setting.

**The Xbox button light is dark after suspend/resume.**
The controller is reinitialised while the device sleeps and comes back with
the light dark, and a resume produces no udev event, so up to v0.1.9 nothing
re-sent the brightness
([issue #63](https://github.com/cchulo/ally-x20-steamos/issues/63)). Later
versions run `ally-x20-steamos-xbox-led-resume.service` after every resume;
`sudo ./ally-x20-steamos.sh apply` installs it. Until then,
`sudo ./ally-x20-steamos.sh xbox-led restore` (or any `brightness` value)
relights it.

**The gamepad (or the sticks) stop working after suspend/resume.**
Seen now and then on the X20 ([issue #63](https://github.com/cchulo/ally-x20-steamos/issues/63)).
`sudo systemctl restart inputplumber.service` brings it back. The cause: the
controller sometimes loses its mode settings while the device sleeps.
Versions after v0.1.9 restarted InputPlumber 3 s after every resume, which
re-sends them. Versions after v0.1.10 re-send the two settings directly, so
Steam no longer sees the controller drop on every wake;
`sudo ./ally-x20-steamos.sh apply` installs it. If the sticks still stay
dead, put `restart=always` into
`/etc/ally-x20-steamos/inputplumber-resume.conf`
([docs/inputplumber.md](docs/inputplumber.md)).

**The joystick rings are dark from power-on until the Steam login screen.**
Expected. Steam stores the ring colour and brightness and re-applies them
when it starts; the controller is not asked to light the rings on its own.

**With the Solid effect only the left ring stays lit.**
An older module build mixed two report types for Solid. Current builds send
Solid as the controller's own static effect, which keeps both rings lit. If
you still see it, update, or try the other strategies through the
`rgb_static_mode` module parameter
([docs/rgb.md](docs/rgb.md#solid-colour-if-one-ring-goes-dark)).

**`apply` warns that `libdisplay-info.so.3` is not built yet.**
Desktop Mode HDR needs a build step the installer does not run for you
(`build/build-hdr.sh`, [docs/hdr.md](docs/hdr.md)). Game Mode HDR works
without it. Everything else is unaffected.

**Steam's Performance tab has no TDP slider, and Manual GPU Clock fails.**
Both on purpose or unfixable for now: BIOS `RC74XA.303` ignores every power
limit it is sent (the three power profiles work), and this APU rejects a
manual GPU clock. [docs/power.md](docs/power.md).

**Is it safe to run `apply` repeatedly?** Yes. It only rewrites what differs
and the boot service and update handler run it themselves.

**Can I use the SteamOS beta, preview or main channel?** You can, but it is
not supported. Only SteamOS **stable** is. On the other channels the kernel
and the system are newer than what this project was written and tested
for, so parts of it may not fit. What happens then: a component that cannot
be applied is skipped and the rest is installed (`install` and `apply` end
with exit code 4 and a list of what failed); a kernel patch that does not
apply leaves that driver as SteamOS ships it while the other drivers are
still patched (`status` shows `modules: partial` and lists each driver).
Whatever stops working there is on you; going back to stable is the fix
this project offers. Set `update-policy degrade` on those channels, because
the default `block` holds back a SteamOS update whose kernel only gets a
partial driver build. Details:
[docs/kernel-modules.md](docs/kernel-modules.md#supported-kernels).

**`install` or `apply` said a component failed. What now?** The other
components were installed. `sudo ./ally-x20-steamos.sh status` shows the
`LAST APPLY` column and, under the table, the reason for each failure; the
same is kept in `/var/lib/ally-x20-steamos/state/last-apply.json`. Fix the
cause and run `apply` again, or remove the half-installed component with
`uninstall --component <name>`.

**`rebuild` fails with `no space left on device`.** The driver build runs
in a podman container, and root's podman storage is under `/var`, a small
partition on SteamOS. Point podman at `/home` for that command with
`CONTAINERS_STORAGE_CONF`:
[docs/kernel-modules.md](docs/kernel-modules.md#podman-storage). (Reported
by a user on SteamOS 3.10.1 preview; not reproduced by the owner.)

**`self-update` says the checkout has local modifications.** It refuses to
update over any edited, added or removed file in
`/var/lib/ally-x20-steamos/src` and never discards them. If you changed the
patch set by hand (for example to get a build on a preview kernel), put the
files back first: `git -C /var/lib/ally-x20-steamos/src status` lists them.
[docs/self-update.md](docs/self-update.md#local-modifications).

## Credits

This project stands on other people's work. Patches taken from elsewhere
keep their original author and trailers; each patch's "Derived from:"
section and the docs linked below name the exact commits.

**Kernel code**

- **Valve's SteamOS kernel**,
  [linux-integration](https://github.com/evlaV/linux-integration) (public
  mirror of `gitlab.steamos.cloud/jupiter/linux-integration`): every module
  is rebuilt from its `7.2.7-valve2` tree. Patches 0003-0006 are backported
  from `7.2.10-valve1` and keep their author, **Matthew Schwartz**
  (`9a0dabd2637d`, `021e9da34c58`, `5ce75814c28a`, `2ce1d48892f3`).
  Patches 0007 and 0008, the fixes for silent speakers after a resume, come
  from the same tag and keep their author, **Andrey Golovko**
  (`2700598cc20c`, `5c9979eb1917`). Patches
  0001 and 0002 match his RC74XA commits `5f7b3941a10f` and `045b13e03d29`
  in the same release, and the firmware naming in
  [firmware/README.md](firmware/README.md) follows `8ba654cb1c44`.
- **Luke D. Jones**: the `hid-asus-ally` driver (his out-of-tree ROG Ally
  series carried in Valve's kernel), which patches 0010-0015 change.
- **Mainline Linux**: patch 0020 is `148794d9f0d2` "platform/x86:
  asus-armoury: Add XBOX ROG Ally X 20 Tunables" by **Derek J. Clark**,
  reviewed and merged by **Ilpo Järvinen** (also Valve's `cf069f36e48d`).
  The `hid-asus-ally` patches follow patterns from `hid-lenovo-go-s.c` (the
  `go_s:rgb:joystick_rings` LED ABI), `hid-playstation.c`, `hid-nintendo.c`,
  `hid-microsoft.c` and `hid-asus.c`.
- [anatase-org/kernel-anatase](https://github.com/anatase-org/kernel-anatase)
  (`7.2.7-an22`): the same audio commits backported to 7.2.7, used to
  cross-check 0001-0003.

**Userspace**

- [ShadowBlip/InputPlumber](https://github.com/ShadowBlip/InputPlumber)
  (GPL-3.0-or-later): the X20 device profile (PR #756) and the
  `ally_type2.yaml` capability map (v0.83.0) we ship, and the report and
  button-chord code behind patches 0014 and 0015.
- [steamos-manager](https://gitlab.steamos.cloud/holo/steamos-manager)
  (Valve, MIT): the RC74XA device entry (`bfbb261ed6b2`) and the device file
  format.
- **Head-related impulse responses** behind the `surround` profiles: the
  **SADIE II** database (University of York AudioLab; Armstrong, Thresh,
  Murphy, Kearney, 2018; Apache-2.0), the **HUTUBS** database (TU Berlin
  Audio Communication Group, Huawei, Sennheiser; Brinkmann et al., 2019;
  CC BY 4.0) and the **MIT Media Lab KEMAR** measurements (Gardner and
  Martin, 1995), as SOFA files from [sofacoustics.org](https://sofacoustics.org).
  The filter graph is **PipeWire**'s `sink-virtual-surround-7.1-hesuvi.conf`
  and the channel layout is **HeSuVi**'s. The speaker variants (crosstalk
  cancellation) are derived from these files on the device. Details:
  [overlay/surround/NOTICE.md](overlay/surround/NOTICE.md).
- [ValveSoftware/gamescope](https://github.com/ValveSoftware/gamescope)
  (BSD-2-Clause): PR #2493 by **Matthew Schwartz**, the X20 display profile
  and the DisplayID 2 HDR patches ([docs/hdr.md](docs/hdr.md)).
- [libdisplay-info](https://gitlab.freedesktop.org/emersion/libdisplay-info)
  (MIT): the DisplayID 2 backport onto 0.3.0 is eight upstream commits, by
  **Simon Ser** (seven) and **Bernd Kuhls** (one).
- [alsa-project/alsa-ucm-conf](https://github.com/alsa-project/alsa-ucm-conf)
  (BSD-3-Clause): the TAS2783 UCM files, from `182d0122a7d9` (PR #812).
- **Texas Instruments**: the TAS2783 speaker tuning files, published in
  [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/ti/audio/tas2783)
  under `LICENCE.ti-tspa` and downloaded at install time by
  `firmware/fetch-tas2783.sh` from a pinned commit; never redistributed
  here ([firmware/README.md](firmware/README.md)).

**Findings and references**

- [hungarianhc/rog-ally-x20-steamos-speakers](https://github.com/hungarianhc/rog-ally-x20-steamos-speakers):
  the first working X20 speaker setup on SteamOS (link layout, ACP flag
  diagnosis, initrd override, `SPEAKER_ID` supplier mapping, firmware pins).
- [ovenham/rog-ally-x20-steamos-speaker-qam-fix](https://github.com/ovenham/rog-ally-x20-steamos-speaker-qam-fix):
  the X20 button codes (Armoury Crate `0xa6`, action button `0xa0`), the proposed
  ACP config quirk and speaker findings.
- [stoneharborent/aquarius-os PR #40](https://github.com/stoneharborent/aquarius-os/pull/40):
  a clear write-up of the four speaker problems and matching patches.
- [hhd-dev/hhd](https://github.com/hhd-dev/hhd): Ally button codes, RGB
  commands and rumble reports;
  [hhd-dev/adjustor](https://github.com/hhd-dev/adjustor): the TDP tables
  and PPT write order we compared against ([docs/power.md](docs/power.md)).
- [kndclark/ally_module](https://github.com/kndclark/ally_module) and
  ValveSoftware/SteamOS issues
  [#2260](https://github.com/ValveSoftware/SteamOS/issues/2260) and
  [#2371](https://github.com/ValveSoftware/SteamOS/issues/2371): the
  joystick-ring LED name, channel layout and effect reports.
- [seerge/g-helper](https://github.com/seerge/g-helper),
  [asusctl](https://gitlab.com/asus-linux/asusctl) and the
  [z13ctl protocol notes](https://dahui.github.io/z13ctl/protocol): ASUS
  Aura lighting commands.
- [anatase-org/anatase](https://github.com/anatase-org/anatase) (UCM-only
  audio setup) and [ublue-os/bazzite](https://github.com/ublue-os/bazzite)
  (audio defaults on the Ally family, the `amd_pmf` power-limit workaround):
  references for the audio and power decisions.
- [NicoWayne95/anatase-x20-hdr-fix](https://github.com/NicoWayne95/anatase-x20-hdr-fix):
  the libdisplay-info backport approach for Desktop Mode HDR.
- [60plus/SteamOS_Nvidia_Installer](https://github.com/60plus/SteamOS_Nvidia_Installer):
  the custom gamescope with stock fallback pattern.
- [icedream/steamos-permanent-mods](https://github.com/icedream/steamos-permanent-mods)
  (RAUC hook) and
  [ryanrudolfoba/vangogh_oc_fix](https://github.com/ryanrudolfoba/vangogh_oc_fix)
  (`/etc` carry-over): surviving SteamOS updates.
- [Hooandee/panel-de-control issue #1012](https://github.com/Hooandee/panel-de-control/issues/1012):
  independent confirmation that TDP changes have no effect on the X20.

Licensing of the files kept under their original license:
[LICENSE.md](LICENSE.md).

## License

GPL-2.0-only, with per-file exceptions listed in [`LICENSE.md`](LICENSE.md).
