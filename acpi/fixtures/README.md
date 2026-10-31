# ACPI fixtures

| file | what | status |
|---|---|---|
| `synthetic-dsdt.aml` | 149-byte DSDT with `\_SB.ACP0._DSD` holding `"acp-audio-config-flag", 0x10` (ByteConst) plus a decoy `"acp-audio-config-flag-x"` property | committed |
| `make-synthetic.py` | regenerates it byte for byte; also builds the other integer widths, several ACP devices or an SSDT (`--width`, `--count`, `--signature`) | committed |
| `x20-dsdt.aml` | the real ROG Xbox Ally X20 (RC74XA) DSDT | **`TODO(hw)`**: not dumped yet |

Regenerate the synthetic fixture (the tests check that it matches):

```sh
python3 acpi/fixtures/make-synthetic.py -o acpi/fixtures/synthetic-dsdt.aml
```

## The real X20 DSDT (`TODO(hw)`)

Dump it from Windows before wiping the device, or from stock SteamOS, as
described in [`../dump-dsdt.md`](../dump-dsdt.md). Save the raw table as
`x20-dsdt.aml`. Then:

1. `./acpi/patch-acp-flag.py inspect acpi/fixtures/x20-dsdt.aml`. Record the
   OEM ID, OEM table ID, OEM revision, BIOS version and the flag site(s) in
   `docs/hardware-data.md`. Confirm it reports exactly one site, `0x10`,
   in a Package(2) pair, near `_DSD`. If not, the tool and its tests need
   adjusting before anyone relies on the override.
2. Add a pytest case that patches it and asserts `diff --check-expected`.
3. It is the table that `vm/run-steamos-vm.sh` passes to QEMU
   (`-acpitable file=acpi/fixtures/x20-dsdt.aml`, plan §6).

Before committing it, decide whether a vendor DSDT may be redistributed in
this repository. If it may not, keep it out of git and have the tests skip
when it is absent.
