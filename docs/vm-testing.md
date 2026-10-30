# VM testing

ally-x20-steamos is validated on stock SteamOS under QEMU before it touches
an X20 (plan §6). Script reference and research notes:
[`vm/README.md`](../vm/README.md).

## Where the VM runs

SteamOS is x86-64 only and boots through UEFI with its own A/B layout, so it
needs a real x86 VM with OVMF. OrbStack/Lima "machines" cannot boot it.
`vm/run-steamos-vm.sh` picks the accelerator automatically (`kvm` → `hvf` →
`tcg`) and prints which one it got.

| host | accel | role | notes |
|---|---|---|---|
| GitHub Actions `ubuntu-latest` | KVM | automated arbiter | `.github/workflows/vm-tests.yml`, nightly + manual. Needs the base image release and the `AX20_VM_SSH_KEY` secret; skipped (not red) without them |
| Fedora x86 box | KVM | **primary local host** | `vm/setup-fedora-host.sh` once; VM runs, container module builds, update-survival and uninstall-from-broken-state suites |
| Legion Go 2 (SteamOS) | KVM | interactive debugging | run QEMU inside a distrobox (Arch/Fedora image with qemu + edk2-ovmf); nothing touches the host OS. Never run ally-x20-steamos itself on the Go 2 |
| Intel Mac | HVF | occasional | Homebrew `qemu`; `-display cocoa`, no GL, so no Game Mode |
| Apple Silicon Mac | TCG | last resort | 10–20× slower; `AX20_VM_SLOW=1` is set so slow suites skip. Fine for shell-level checks, a full update takes hours |

Everything that needs no VM (shell libraries + bats, ACPI tool + pytest,
overlay files, CI, docs) is developed on the Mac; VM runs happen on the
Fedora box; CI on the KVM runner decides.

## Daily loop on the Fedora box

```sh
vm/run-steamos-vm.sh --restore clean          # fresh overlay over the installed base
ssh -p 2222 deck@127.0.0.1                    # in another terminal
# copy the checkout in (or: vm/ci/vm-ci.sh push-repo .), run the checks below
```

`--snapshot <name>` keeps an overlay between runs (e.g. "after-update"),
`--restore <name>` throws it away. Every overlay has its own OVMF vars copy.

## What each VM check proves (plan §6)

| # | check | how | status |
|---|---|---|---|
| 1 | install/status/uninstall round-trip leaves the system byte-identical | `vm/guest/roundtrip-test.sh` (snapshots `/etc`, `/var/lib/ally-x20-steamos`, `/opt/ally-x20-steamos`, ESP entries, `~/.config`; all manifest paths gone); CI job `roundtrip` | script ready; exits 77 until the CLI has `install`/`uninstall` |
| 2 | module build produces `.ko` with matching vermagic; version-gated substitution | build package's container + `modinfo`/`lsmod` in the VM | needs the modules package |
| 3 | ACPI early-initrd override loads | `dmesg \| grep "ACPI: Table Upgrade"` after installing the audio component; `--acpitable` only for SSDT experiments (see vm/README.md) | needs the audio package + DSDT dump |
| 4 | A/B update survival, `/etc` carry-over, offline update, self-update/rollback | `vm/guest/measure-etc-survival.sh before/after` around `steamos-update` → [`docs/etc-survival.md`](etc-survival.md); `--offline` for the no-network case | survival probe ready |
| 5 | stock InputPlumber picks our profile via DMI `RC74XA` | default SMBIOS flags; `inputplumber devices`, `busctl tree org.shadowblip.InputPlumber`; `--usb-passthrough <vid:pid>` with a spare Xbox pad for a smoke test | SMBIOS ready; DMI strings TODO(hw) |
| 6 | Steam discovers the joystick-ring LED | `vm/fake-leds.sh build/load` (`vm/test-led-module`, registers `go_s:rgb:joystick_rings`) → Steam Customization section appears | module ready, not yet built against the VM kernel |
| 7 | probes on "stock lacks X" / "stock has X" | bats with fixture roots (`tests/`), `vm/fake-leds.sh tree` for LED fixtures | unit level, no VM needed |
| 8 | HDR: libdisplay-info sees the X20's HDR block; KWin/gamescope | `--edid <blob>` sets the mode and exposes the blob via fw_cfg; `di-edid-decode` on it; gamescope log | partial: custom EDID as the connector EDID needs a guest boot-entry change (vm/README.md) |

Hardware facts the VM cannot provide (TAS2783 audio, `SPEAKER_ID`, N-KEY
`0xa0`, real LED nodes) come from `vm/guest/collect-hardware-data.sh` run on
the X20; the same script on the VM gives a baseline to diff against.

## Slow tests

`run-steamos-vm.sh` exports `AX20_VM_ACCEL` and `AX20_VM_SLOW` and writes
them to `<vm-dir>/accel.env`. Suites that boot, update or rebuild should
`skip` when `AX20_VM_SLOW=1`; CI always runs on KVM.

## Producing the CI base image (once, by hand)

The recovery installer is a click-through desktop flow, so the base image is
made manually on the Fedora box and uploaded as a release:

```sh
vm/setup-fedora-host.sh --download
vm/ci/make-base-image.sh keygen       # CI ssh key; then: gh secret set AX20_VM_SSH_KEY < .../ci_ed25519
vm/ci/make-base-image.sh install      # wipe+install, first boot, passwd, enable sshd (prompts explain)
vm/run-steamos-vm.sh --run --disk ~/vms/ally-x20-steamos/disks/steamos-base.qcow2
vm/ci/make-base-image.sh prepare      # authorise key, CI sudoers drop-in, beta branch, steamos-update
# reboot the guest into the updated slot, check it, power off
vm/ci/make-base-image.sh package      # compact, zstd, split < 2 GiB, SHA256SUMS, prints gh release create
```

Then set `AX20_VM_BASE_TAG` in `vm/ci/base-image.conf`. The image contains
`/etc/sudoers.d/zz-ally-x20-steamos-ci` (passwordless sudo for `deck`) and the
CI public key; it is a test fixture, never a device image. Release assets
are limited to 2 GiB each, hence the split; the Actions cache (10 GB per
repository) is used when the image fits, otherwise each run downloads it.
