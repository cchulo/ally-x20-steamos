# Hardware data still to collect on the X20

Everything in this repository was written before the first boot of stock
SteamOS on an X20. The commands in
[`X20-STEAMOS-PLAN.md` §7](../X20-STEAMOS-PLAN.md#7-hardware-side-data-to-collect-on-the-x20-first-boot-of-stock-steamos)
produce the facts below. Until they are filled in, the corresponding code is
marked `TODO(hw)`.

| Fact | Needed by | Status |
|---|---|---|
| `uname -r` and `/proc/config.gz` of the stock kernel | module build pins | **measured 2026-10-31**: `7.2.7-valve2-2-neptune-72-g31504582a073` on SteamOS 3.9.5 (build 20261023.100, channel `rel`); `CONFIG_ACPI_TABLE_UPGRADE=y`, `CONFIG_HID_ASUS_ALLY=m`, `CONFIG_SND_SOC_ACPI_AMD_MATCH=m`, `CONFIG_SND_AMD_ACP_CONFIG=m`, `CONFIG_SND_SOC_ACPI_AMD_SDCA_QUIRKS=y`, lockdown `[none]`, `MODULE_SIG_FORCE` unset; neither `snd-acp-config` nor `hid-asus-ally` is in the initramfs |
| DSDT dump (`acpidump`) | `acpi/fixtures/`, ACPI override validation | **measured 2026-10-31**: DSDT (66635 B, OEM `_ASUS_`/`Notebook`) has no `acp-audio-config-flag`; it is in SSDT8 (OEM `AMD`/`OEMACP`, 136873 B, OEM rev 1), one site, `ByteConst 0x10`; the tool patches it cleanly (3 bytes change). BIOS `RC74XA.303` (2026-09-23). Tables kept outside the repo until the owner decides whether vendor tables may be committed |
| `/sys/class/leds/` entries | RGB patch (rings only vs rings + Xbox button) | **measured 2026-10-31**: only `ally:rgb:joystick_rings` (plus keyboard lock LEDs); no Xbox-button LED |
| `SPEAKER_ID` UEFI variable value and format | firmware pair selection (JGX vs LS), `firmware/speaker-id.map` | **measured 2026-10-31**: `SPEAKER_ID-aa61eaaf-6e83-7523-b0d0-7df74bb24a81` = attributes `07 00 00 00` + value `01 00 00 00` → SPEAKER_ID 1 = LS per hungarianhc (mapping itself still single-sourced) |
| `aplay -l`, `journalctl -k` for `acp|sof|soundwire|tas2783` | audio component probe baseline | **measured 2026-10-31**: only card 0 `HD-Audio Generic` (HDMI); no SoundWire card; no tas2783 UCM or firmware shipped; stock modules contain no `RC74XA` |
| `inputplumber --version`, stock `devices/` listing, `sys_vendor`, IMU axes | devices.d profile key compatibility | **measured 2026-10-31**: 0.78.0; `inputplumber.service` disabled/inactive; stock devices `50-rog_ally.yaml`, `50-rog_ally_x.yaml`, `50-rog_xbox_ally.yaml`; `sys_vendor` = `ASUS`, DMI modalias `svnASUS:…:rnRC74XA:` matches our hwdb entry; Valve enables the daemon via `USE_INPUTPLUMBER=1` + `90-steam-inputplumber.rules`; IMU axes still to verify |
| N-KEY hidraw report for the Quick Access button (`0xa0` expected) | `hid-asus-ally` patch | pending |
| Rumble: felt strength of 0x0d magnitudes 90-127, which report pattern makes the speakers hiss (`vm/guest/hid-rumble-raw.py matrix`), report rate a game sends (`… usbmon`), whether the hiss stops with the speaker sink suspended | draft patch 0014, [rumble-analysis.md](rumble-analysis.md) §7 | pending |
| EDID of the internal panel (`AMS740LS02`) | HDR verification | **measured 2026-10-31**: `card0-eDP-1`, 384 bytes, SDC model 17665 (0x4501), name `AMS740LS02-0`, two DisplayID extension blocks |
| Panel EDID vendor/product (gamescope's X20 profile matches `SDC` / `0x4501`), `gamescope --version`, `ls /usr/lib/libdisplay-info.so*`, `ldconfig -p \| grep libdisplay-info` after apply | `components/hdr.sh` (profile, probe, ld.so.conf.d precedence) | pending |
| `pipewire --version`, `libmysofa` presence, LV2/LADSPA plugins shipped | audio DSP chain | **measured 2026-10-31**: PipeWire 1.6.8, WirePlumber 0.5.18, `libmysofa.so.1.3.3` and `libspa-filter-graph-plugin-sofa.so` present; LADSPA `caps.so`, `rnnoise`; LV2 core bundles only (no LSP) |
| Windows reference recording of the speakers | speaker chain tuning | pending |
| SoundWire peripherals: TAS2783 uids `0x8`/`0xB` on link 0, RT721 uid 0 on link 1 (`/sys/bus/soundwire/devices/`) | `patches/kernel/0001` | pending |
| DMI `board_vendor` / `board_name` (`ASUSTeK COMPUTER INC.` / `RC74XA` expected) and `acp-audio-config-flag` value | `patches/kernel/0002` | pending |
| Both amps audible, left/right correct with the 0001 layout | `patches/kernel/0001` | pending |
| No `SDW0-PIN4-CAPTURE-SmartAmp` PCM and no `Program transport params failed` in `journalctl -k`; `Amp Volume` change survives the sink suspending; card comes up with the tuning loaded synchronously | `patches/kernel/0003`–`0006` | pending |
| `SND_SOC_ACPI_AMD_MATCH`, `SND_AMD_ACP_CONFIG`, `SND_SOC_ACPI_AMD_SDCA_QUIRKS` in `/proc/config.gz`; `snd-acp-config` in initramfs or not | module build / substitution | pending |
| UCM route names for jack/speaker (`pw-dump` device `Route` params) and whether unplug sets `available = no` | audio DSP router (`x20-route-core.lua`) | pending |
| WirePlumber profile in use (`systemctl --user cat wireplumber`) | audio DSP loader fragment | pending |
| Speaker positions/orientation on the chassis | XTC stretch goal (`docs/xtc-notes.md`) | pending |
