# acpi/ — ACPI side of the X20 speaker fix

Plan reference: [`X20-STEAMOS-PLAN.md` §1.1, problem 1](../X20-STEAMOS-PLAN.md#11-speakers-two-ti-tas2783-amps-on-amd-acp-soundwire).

The X20 BIOS publishes `acp-audio-config-flag = 0x10` (DMIC only) in a
`_DSD` device-properties package under the AMD ACP device. The Linux ACP/SOF
drivers honour it and skip SoundWire, so the TAS2783 amplifiers never probe.
Windows ignores the flag.

We give the kernel a corrected copy of the DSDT through the ACPI *table
upgrade* mechanism: an uncompressed cpio placed first in the initrd chain,
holding `kernel/firmware/acpi/DSDT.aml`. The kernel replaces a firmware table
whose signature, OEM ID and OEM table ID match and whose OEM revision is
lower than ours. No kernel rebuild, and it keeps working across SteamOS
kernel updates. [`dump-dsdt.md`](dump-dsdt.md) covers dumping, checking,
testing in QEMU and on the device, and the kernel-quirk alternative.

| file | role |
|---|---|
| `patch-acp-flag.py` | the tool: `inspect`, `patch`, `verify`, `diff`, `mkinitrd`, `list` (Python 3.9+, stdlib only, works on raw AML, no iasl) |
| `build-override.sh` | one-shot pipeline used by the `audio` component |
| `dump-dsdt.md` | how to get the DSDT and how to test the override |
| `fixtures/` | synthetic DSDT (committed, reproducible) and, later, the real X20 DSDT |
| `tests/` | pytest suite (`make test-python`) |

## How the patch works

The property name is an AML String (`0x0D "acp-audio-config-flag" 0x00`).
The value comes right after it as an integer object: `ZeroOp 0x00`,
`OneOp 0x01`, `ByteConst 0x0A xx`, `WordConst 0x0B xx xx`,
`DWordConst 0x0C xx*4` or `QWordConst 0x0E xx*8`. `patch`
rewrites the payload in place at the same width, so the table length and
every AML PkgLength stay valid. It then adds 1 to the OEM revision (header
offset 24, u32) and recomputes the checksum (offset 9) so the table sums to
0 mod 256. `diff --check-expected` proves that nothing else changed: on the
synthetic fixture exactly three bytes differ (checksum, OEM revision low
byte, flag value).

Refusals: a signature other than DSDT/SSDT, a bad length or checksum, the
string missing, more than one occurrence without `--all`, a value that is not
an integer constant (for example a named object), a value that does not fit
the existing width, or an OEM-revision overflow.

Exit codes (every subcommand): 0 ok; 1 `verify` flag not at the expected
value, or `diff` inputs differ; 2 invalid table or cpio; 3 flag not found,
ambiguous or not patchable; 4 I/O error; 64 usage error.

```sh
./acpi/patch-acp-flag.py inspect dsdt.aml                 # header + flag value(s)
./acpi/patch-acp-flag.py patch dsdt.aml -o dsdt.patched.aml
./acpi/patch-acp-flag.py verify dsdt.patched.aml          # exit 0 = checksum ok and flag 0
./acpi/patch-acp-flag.py diff --check-expected dsdt.aml dsdt.patched.aml
./acpi/patch-acp-flag.py mkinitrd dsdt.patched.aml -o acpi-override.img
./acpi/patch-acp-flag.py list acpi-override.img           # lsinitrd-style listing
```

`patch` is idempotent. If the flag already has the target value, `patch`
still writes the table but changes only the OEM revision and checksum, and
prints a warning. With `--if-needed` it prints `already patched`, writes
nothing and exits 0. `mkinitrd` refuses a table whose flag is not 0
(`--force` overrides). Its output is reproducible: every entry is owned by
root, mtime is `$SOURCE_DATE_EPOCH` or 0, inode numbers are fixed.

## Interface for the `audio` component

```
acpi/build-override.sh --out <dir> [--dsdt <file>] [--value N] [--all]
```

- Input: `--dsdt <file>` if given. Otherwise (Linux only) the live table at
  `/sys/firmware/acpi/tables/DSDT`, which needs root. Paths under `/sys`
  honour `AX20_ROOT` like the rest of the tool. If the live table is
  byte-identical to `<dir>/DSDT.patched.aml`, our override is already
  active, so the script rebuilds from the saved `<dir>/DSDT.orig.aml`
  instead. It refuses with exit 5 if the BIOS version changed since that
  original was saved.
- Pipeline: patch, verify, diff `--check-expected`, mkinitrd, list. The
  script installs nothing and does not touch the ESP or bootloader.
- Outputs, written into `<dir>` only after every step has passed:

  | file | content |
  |---|---|
  | `ally-x20-steamos-acpi.img` | uncompressed newc cpio: `kernel/`, `kernel/firmware/`, `kernel/firmware/acpi/` (0755) and `kernel/firmware/acpi/DSDT.aml` (0644) |
  | `DSDT.patched.aml` | the table inside the image |
  | `DSDT.orig.aml` | the unpatched input |
  | `BUILD-INFO` | `key=value` lines: `tool`, `tool_version`, `built_utc`, `input`, `input_sha256`, `patched_aml_sha256`, `output`, `output_sha256`, `flag_value_before`, `flag_value_after`, `oem_id`, `oem_table_id`, `oem_revision_before`, `oem_revision_after`, `bios_version` |

- stdout: the last line is `<sha256>  <dir>/ally-x20-steamos-acpi.img`.
  Progress goes to stderr.
- Exit codes: 0 built; 2 invalid input table; 3 no override needed (flag
  already at the target value, for example after a BIOS fix) or flag not
  patchable; 4 I/O error (no root for sysfs, missing file); 5 the saved
  original is stale after a BIOS update; 64 usage (also when no `--dsdt` is
  given on a non-Linux host).
- Environment: `PYTHON` (default `python3`), `AX20_ROOT`,
  `SOURCE_DATE_EPOCH`.

What the `audio` component must do with the image (not done here):

- Load it as the **first** initrd, uncompressed: either as a separate
  `initrd` line before the main initramfs, or concatenated in front of it.
  `TODO(hw)`: confirm how the SteamOS boot chain passes several initrds.
- Check that the running kernel has `CONFIG_ACPI_TABLE_UPGRADE=y`
  (`zcat /proc/config.gz`). `TODO(hw)`: confirm for
  `7.2.7-valve2-1-neptune`.
- After reboot, confirm `dmesg | grep -i "ACPI: Table Upgrade"` and that the
  kernel taint flag for an overridden ACPI table is set. Its probe should
  treat a stock DSDT with the flag already 0 (exit 3) as "superseded".
