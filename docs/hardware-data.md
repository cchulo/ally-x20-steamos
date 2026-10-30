# Hardware data still to collect on the X20

Everything in this repository was written before the first boot of stock
SteamOS on an X20. The commands in
[`X20-STEAMOS-PLAN.md` §7](../X20-STEAMOS-PLAN.md#7-hardware-side-data-to-collect-on-the-x20-first-boot-of-stock-steamos)
produce the facts below. Until they are filled in, the corresponding code is
marked `TODO(hw)`.

| Fact | Needed by | Status |
|---|---|---|
| `uname -r` and `/proc/config.gz` of the stock kernel | module build pins | pending |
| DSDT dump (`acpidump`) | `acpi/fixtures/`, ACPI override validation | pending |
| `/sys/class/leds/` entries | RGB patch (rings only vs rings + Xbox button) | pending |
| `SPEAKER_ID` UEFI variable value and format | firmware pair selection (JGX vs LS), `firmware/speaker-id.map` | pending: GUID `aa61eaaf-6e83-7523-b0d0-7df74bb24a81` and 0 = JGX / 1 = LS taken from hungarianhc, unconfirmed by us |
| `aplay -l`, `journalctl -k` for `acp|sof|soundwire|tas2783` | audio component probe baseline | pending |
| `inputplumber --version`, stock `devices/` listing, `sys_vendor` (upstream profile/hwdb expect `ASUS`), IMU axes vs. the converted matrix in `50-rog_xbox_ally_x20.stock.yaml` | InputPlumber profile variant, hwdb match ([docs/inputplumber.md](inputplumber.md)) | pending |
| N-KEY hidraw report for the Quick Access button (`0xa0` expected) | `hid-asus-ally` patch | pending |
| EDID of the internal panel (`AMS740LS02`) | HDR verification in VM | pending |
| `pipewire --version`, `libmysofa` presence, LV2/LADSPA plugins shipped | audio DSP chain | pending |
| Windows reference recording of the speakers | speaker chain tuning | pending |
| SoundWire peripherals: TAS2783 uids `0x8`/`0xB` on link 0, RT721 uid 0 on link 1 (`/sys/bus/soundwire/devices/`) | `patches/kernel/0001` | pending |
| DMI `board_vendor` / `board_name` (`ASUSTeK COMPUTER INC.` / `RC74XA` expected) and `acp-audio-config-flag` value | `patches/kernel/0002` | pending |
| Both amps audible, left/right correct with the 0001 layout | `patches/kernel/0001` | pending |
| `SND_SOC_ACPI_AMD_MATCH`, `SND_AMD_ACP_CONFIG`, `SND_SOC_ACPI_AMD_SDCA_QUIRKS` in `/proc/config.gz`; `snd-acp-config` in initramfs or not | module build / substitution | pending |
