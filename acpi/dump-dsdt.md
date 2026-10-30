# Dumping the X20 DSDT and testing the `acp-audio-config-flag` override

Background: [`README.md`](README.md) and
[`X20-STEAMOS-PLAN.md` §1.1](../X20-STEAMOS-PLAN.md#11-speakers-two-ti-tas2783-amps-on-amd-acp-soundwire).
You need the raw, binary DSDT (`DSDT` signature, length in the header equal
to the file size). Steps that only a real X20 can confirm are marked
`TODO(hw)`. Steps that need the VM are marked `TODO(vm)`.

## 1. Dump it

### From Windows (before wiping the device)

Use `acpidump.exe` from Intel's ACPICA project ("iASL Compiler and Windows
ACPI Tools" zip on the ACPICA downloads page). It is a small user-mode tool
and installs nothing.

Avoid RWEverything and similar tools: they load an unsigned kernel driver,
which HVCI/anti-cheat blocks, and you do not need one here.

From an **administrator** command prompt, in an empty folder:

```bat
acpidump.exe -b -n DSDT
```

This writes `dsdt.dat`, the raw table. `acpidump.exe -b` without `-n` dumps
every table (`dsdt.dat`, `ssdt*.dat`, `facp.dat`, ...). Keep them all: the
SSDTs help when disassembling. Copy `dsdt.dat` to
`acpi/fixtures/x20-dsdt.aml`. `TODO(hw)`

### From Linux (stock SteamOS or any live system)

The kernel exposes the tables it booted with. This needs root, and no
extra tools:

```sh
sudo cat /sys/firmware/acpi/tables/DSDT > x20-dsdt.aml
```

If ACPICA's tools are installed (`acpica-tools` / `acpica`), this works
too:

```sh
mkdir dump && cd dump && sudo acpidump -b      # writes dsdt.dat, ssdt*.dat, ...
```

`acpi/build-override.sh` reads the sysfs file itself when you do not pass
`--dsdt`.

**Caveat:** once our override is active, `/sys/firmware/acpi/tables/DSDT`
shows *our* table (flag 0, OEM revision +1), not the firmware's.
`build-override.sh` handles this: it keeps `DSDT.orig.aml` and rebuilds from
it, and refuses after a BIOS update. To dump the pristine table again,
boot once without the override. `TODO(vm)`: confirm that sysfs shows the
upgraded table.

## 2. Confirm the flag

Without iasl, using our tool:

```sh
./acpi/patch-acp-flag.py inspect acpi/fixtures/x20-dsdt.aml
```

Expected on the X20 (`TODO(hw)`): signature `DSDT`, checksum valid, and
one site: `ByteConst = 0x10 (16) [in Package(2) pair, _DSD nearby]`. Add
`--json` for machine-readable output. Exit 3 means the string was not found
in this table. It may live in an SSDT instead: run `inspect` on each
`ssdt*.dat`. The tool can patch an SSDT, but the image builder and
`build-override.sh` handle the DSDT case only.

With iasl (ACPICA), to see the ASL context:

```sh
iasl -e ssdt*.dat -d dsdt.dat       # writes dsdt.dsl; -e resolves external refs
grep -n -B8 -A2 'acp-audio-config-flag' dsdt.dsl
```

You should see something like this, under the ACP device (`_ADR` 5 on the
GPU's PCI bridge):

```asl
Name (_DSD, Package (0x02)
{
    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301"),
    Package (0x01)
    {
        Package (0x02) { "acp-audio-config-flag", 0x10 }
    }
})
```

If the value is a named object or a method result instead of a constant,
`patch` refuses (exit 3). The fallback is to edit the `.dsl`, raise the OEM
revision in `DefinitionBlock`, and rebuild it with `iasl -tc`.

## 3. Build the override

```sh
./acpi/build-override.sh --out out/ --dsdt acpi/fixtures/x20-dsdt.aml
./acpi/patch-acp-flag.py list out/ally-x20-steamos-acpi.img
```

Or do it step by step: `patch`, `verify`, `diff --check-expected`,
`mkinitrd` (see [`README.md`](README.md)). The image is an **uncompressed**
newc cpio. The kernel only looks for upgrade tables in the first,
uncompressed part of the initrd, so the image must come before the
(compressed) main initramfs.

## 4. Test in QEMU (`TODO(vm)`, plan §6 check 3)

The kernel only upgrades a table that matches one the firmware already
provides (same signature, OEM ID and OEM table ID, lower OEM revision). A
stock QEMU guest's DSDT is QEMU's own, so there is nothing to upgrade
until we inject the X20's table:

```sh
qemu-system-x86_64 ... \
    -smbios type=1,manufacturer="ASUSTeK COMPUTER INC.",product=RC74XA \
    -acpitable file=acpi/fixtures/x20-dsdt.aml
```

Inside the guest, put `ally-x20-steamos-acpi.img` in front of the initrd
(that is the `audio` component's job; for a manual test, add a second
`initrd` line in the boot entry, or run
`cat ally-x20-steamos-acpi.img initramfs.img > combined.img`), then reboot
and check:

```sh
dmesg | grep -i "ACPI: Table Upgrade"     # override [DSDT-<OEMID>-<TABLEID>]
cat /proc/sys/kernel/tainted              # bit 8 (A) = ACPI table overridden
sudo ./acpi/patch-acp-flag.py verify /sys/firmware/acpi/tables/DSDT
```

`TODO(vm)`: how QEMU and Linux treat a second table with the `DSDT`
signature added by `-acpitable` has not been tested. If the guest ignores
it, use an SSDT for the mechanism test. The synthetic generator can build
one, and `mkinitrd` packages it as `kernel/firmware/acpi/SSDT.aml`:

```sh
python3 acpi/fixtures/make-synthetic.py --signature SSDT -o ssdt.aml
./acpi/patch-acp-flag.py patch ssdt.aml -o ssdt.patched.aml
./acpi/patch-acp-flag.py mkinitrd ssdt.patched.aml -o ssdt-override.img
# boot with -acpitable file=ssdt.aml and ssdt-override.img as first initrd
dmesg | grep -i "ACPI: Table Upgrade"     # override [SSDT-AX20  -SYNTHDSD]
```

## 5. Test on the device (`TODO(hw)`)

1. `zcat /proc/config.gz | grep ACPI_TABLE_UPGRADE` must print
   `CONFIG_ACPI_TABLE_UPGRADE=y`. The upgrade is also disabled under kernel
   lockdown (Secure Boot with lockdown). `TODO(hw)`: confirm that
   `/sys/kernel/security/lockdown` reads `[none]` on stock SteamOS.
2. Install the image through the `audio` component, then reboot.
3. Check `dmesg | grep -i "ACPI: Table Upgrade"`, then
   `journalctl -k | grep -iE 'acp|sof|soundwire|tas2783'`. The SoundWire
   links should now be enumerated. Speaker output also needs the other
   three §1.1 fixes (machine layout, firmware names, UCM).
4. To undo it, remove the image from the boot entry. The firmware's table
   is back on the next boot.

## Alternative: kernel DMI quirk (not the default)

Plan §2 reserves
`patches/kernel/0002-ACPI-x86-quirk-ignore-acp-audio-config-flag-RC74XA.patch`.
That patch makes the ACP driver ignore the property when the DMI board is
`RC74XA`, like the proposed patch in the ovenham repository's `upstream/`
directory. It is the right long-term fix upstream, but this project does
not use it by default, because:

- it changes a built-in or stock module, so every SteamOS kernel update needs
  a matching rebuild before audio works again (plan §3, §4.6). The initrd
  override is independent of the kernel version, needs no build toolchain
  on the device, and survives kernel updates unchanged;
- the initrd is easy to inspect and remove, and it does nothing on a
  machine whose DSDT has a different OEM ID or OEM table ID;
- once upstream (and then SteamOS) carries a quirk or a fixed BIOS ships,
  `build-override.sh` exits 3 ("no override needed") on a DSDT with the
  flag already 0, and the `audio` probe can report the override as
  superseded.

A BIOS update stays a risk for the initrd approach: an override built from
an old DSDT would replace a newer firmware table with the same OEM IDs.
`build-override.sh` records `bios_version` in `BUILD-INFO` for this
reason, and the `audio` component must rebuild, or drop the image, when
the BIOS version changes. `TODO(hw)`: check whether ASUS bumps the DSDT OEM
revision in BIOS updates. If it does, a stale override no longer applies
on its own, because its revision is no longer higher.
