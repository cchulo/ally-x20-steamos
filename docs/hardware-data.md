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
| `SPEAKER_ID` UEFI variable value and format | firmware pair selection (JGX vs LS) | pending |
| `aplay -l`, `journalctl -k` for `acp|sof|soundwire|tas2783` | audio component probe baseline | pending |
| `inputplumber --version`, stock `devices/` listing | devices.d profile key compatibility | pending |
| N-KEY hidraw report for the Quick Access button (`0xa0` expected) | `hid-asus-ally` patch | pending |
| EDID of the internal panel (`AMS740LS02`) | HDR verification in VM | pending |
| `pipewire --version`, `libmysofa` presence, LV2/LADSPA plugins shipped | audio DSP chain | pending |
| Windows reference recording of the speakers | speaker chain tuning | pending |
| UCM route names for jack/speaker (`pw-dump` device `Route` params) and whether unplug sets `available = no` | audio DSP router (`x20-route-core.lua`) | pending |
| WirePlumber profile in use (`systemctl --user cat wireplumber`) | audio DSP loader fragment | pending |
| Speaker positions/orientation on the chassis | XTC stretch goal (`docs/xtc-notes.md`) | pending |
