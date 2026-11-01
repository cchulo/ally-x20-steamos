# Audio: the X20's internal speakers

Component: `audio` (`components/audio.sh`). Kernel module side: `modules`.
Audio plays through the hardware sinks as on stock SteamOS (the headphone
virtual surround and speaker DSP were removed on 2026-11-01, see
[audio-dsp-history.md](audio-dsp-history.md)).

On stock SteamOS the X20 shows "Dummy Output" or HDMI only. The speakers are
two TI TAS2783 smart amps on the AMD audio coprocessor's (ACP 7.x) SoundWire
bus, next to an RT721 headset codec. Four separate problems keep them silent.

## The four problems

| # | Problem | Fixed by |
|---|---|---|
| 1 | The BIOS sets the ACPI property `acp-audio-config-flag = 0x10` ("legacy, DMIC only"), so Linux skips SoundWire/SOF. Windows ignores it. | `audio`: ACPI table override loaded as an early initrd (`acpi/build-override.sh`) |
| 2 | The kernel has no machine layout for amps on SoundWire link 0 + RT721 on link 1, so the card comes up headset-only. | `modules`: patched `snd-soc-acpi-amd-match` |
| 3 | The amp driver requests tuning files under a name linux-firmware does not ship, and the right pair depends on the speaker supplier (JGX or LS, from the `SPEAKER_ID` UEFI variable). | `audio`: `firmware/fetch-tas2783.sh` (see [`firmware/README.md`](../firmware/README.md)) |
| 4 | SteamOS's alsa-ucm-conf predates TAS2783, so PipeWire finds no speaker device. | `audio`: UCM overlay with upstream `sof-soundwire/tas2783.conf`, selected through `ALSA_CONFIG_UCM2` |

Beyond the four problems, the `modules` component also rebuilds the amp
driver and the SoundWire machine-driver helpers with four fixes from Valve's
`7.2.10-valve1` kernel; see [Kernel fixes from Valve 7.2.10](#kernel-fixes-from-valve-7210).

Valve's `7.2.10-valve1` kernel already contains the RC74XA link-0 layout, the
ACPI flag handling, the SPEAKER_ID-aware firmware names and those four fixes. On such a kernel
the `modules` component and the ACPI override become superseded, while the UCM
profile (alsa-ucm-conf) and possibly the firmware links are still needed until
SteamOS's userspace packages catch up. `status --verbose` shows each part
separately (see below).

## Kernel fixes from Valve 7.2.10

On the `7.2.7-valve2` kernel, the `modules` component also replaces these
modules (patches `0003`–`0006`, details in
[`patches/kernel/README.md`](../patches/kernel/README.md#00030006-valve-7210-valve1-backports)):

| Module | Fix | What you notice |
|---|---|---|
| `snd-soc-sdw-utils`, `snd-acp-sdw-legacy-mach`, `snd-acp-sdw-sof-mach` | no amp feedback capture link where the BIOS declares no capture port | The `SDW0-PIN4-CAPTURE-SmartAmp` PCM is gone, and with it the bursts of `Program transport params failed: -22` / `ASoC error (-22) at snd_soc_link_prepare()` in the kernel log each time PipeWire probes the card. Closing that failed PCM no longer powers the amps' SmartAmp domain off (PDE23 = PS3). |
| `snd-soc-tas2783-sdw` | volume settings kept across resets | `tas2783-1/2 Amp Volume` and `Speaker Volume` can be read and set while the speakers are idle (no more `-EBUSY`), and a value you set survives the SoundWire link idling, suspend and resume. Until you set one, the tuning firmware's value applies, as before. |
| `snd-soc-tas2783-sdw` | firmware loaded synchronously | The tuning file is loaded and downloaded before the amp is initialised, with no 3 s timeout that let an amp play without its init writes. A missing tuning file now fails the amp's init outright (`Failed to read fallback fw binary`). The file is still found through `firmware_class.path`. |
| `snd-soc-tas2783-sdw` | no playback without the init writes | If an amp's DisCo init writes fail, playback on it is refused (`error playback without init writes`) instead of playing with the wrong posture (wrong side or mix). |

The three SoundWire helper modules change a shared structure, so they are
always built and loaded as a set. All four fixes are in Valve's
`7.2.10-valve1`; on that kernel the modules are reported `superseded` and the
stock ones load. Hardware confirmation is `TODO(hw)` (below).

## What the component installs

Everything is recorded in the manifest and removed by `uninstall`.

| Path | What |
|---|---|
| `/etc/modprobe.d/ally-x20-steamos-audio.conf` | comments only: documents that `firmware_class.path` comes from the boot entry (and sysfs at apply time). It must never carry an `install` line: a second hook for `snd_soc_tas2783_sdw` competes with `ally-x20-steamos-modules.conf` and made the stock codec load on the X20 |
| `/etc/ally-x20-steamos/firmware/` | pinned, SHA-256-verified TAS2783 tunings plus links under the names the driver requests |
| `/var/lib/ally-x20-steamos/ucm2/` | UCM overlay (see below) |
| `/etc/environment.d/90-ally-x20-steamos-ucm.conf` | `ALSA_CONFIG_UCM2=/var/lib/ally-x20-steamos/ucm2`; written only after the overlay is complete |
| `/var/lib/ally-x20-steamos/acpi/` | `ally-x20-steamos-acpi.img`, `TABLE.patched.aml`, `TABLE.orig.aml`, `BUILD-INFO` from the ACPI tool |
| `/efi/EFI/steamos/ally-x20-steamos-acpi.img` | the early initrd on the active slot's ESP (manifest slot `esp`) |
| active slot's boot entry | early initrd added by `slot_set_early_initrd` from `lib/slots.sh` (the plan's documented exception; original saved by that library) |

The ACPI step only runs on board `RC74XA`, needs `python3` and the ACPI tool,
and is skipped (logged, never fatal) when anything is missing. It uses the
live `/sys/firmware/acpi/tables/DSDT`; the repository's
`acpi/fixtures/x20-dsdt.aml` is only used against a fixture or VM root, never
on hardware. While our override is active the tool rebuilds from the saved
`TABLE.orig.aml`; if the BIOS changed since (tool exit 5), apply asks you to
boot once without the override.

### Why the UCM overlay is a symlink tree

`ALSA_CONFIG_UCM2` **replaces** the UCM directory; alsa-lib builds every path
as `$ALSA_CONFIG_UCM2/<dir>/<file>` and has no search path
(`src/ucm/parser.c`, `ucm_filename()`). The `conf.d/<driver>/` lookups that
newer alsa-ucm-conf uses (`ucm2/ucm.conf`) are relative to that same
directory, so `conf.d` cannot layer a file on top of `/usr/share/alsa/ucm2`
either. The overlay therefore:

- links every top-level entry of `/usr/share/alsa/ucm2` with a **relative**
  symlink (`../../../../usr/share/alsa/ucm2/<entry>`), so it also resolves
  inside a mounted slot or a test root;
- turns only the directories that hold our files (`sof-soundwire/`,
  `codecs/`) into real directories whose stock children are again links;
- adds `sof-soundwire/tas2783.conf` and `codecs/tas2783/init.conf` (verbatim
  upstream, BSD-3-Clause, see `overlay/ucm2/UPSTREAM.md`) **only if stock does
  not have them**; once SteamOS ships them, the overlay links to stock;
- is refreshed on every `apply` (the boot service runs it after updates):
  new stock entries get linked, links to entries a SteamOS update removed are
  dropped.

The AMD card's driver is `amd-soundwire`; stock `conf.d/amd-soundwire/amd-soundwire.conf`
is a relative symlink to `sof-soundwire/sof-soundwire.conf`, and every include
in that family is absolute (`/sof-soundwire/HiFi.conf`,
`/sof-soundwire/${var:SpeakerCodecFile}.conf`), which alsa-lib resolves
against `ALSA_CONFIG_UCM2`, i.e. through our overlay. That is how the stock
`HiFi.conf` reaches our `tas2783.conf` for a card reporting `spk:tas2783`.

### Who sees ALSA_CONFIG_UCM2

On SteamOS, PipeWire and WirePlumber run as `systemd --user` services of the
`deck` user, in both Game Mode and Desktop Mode. The user manager imports
`/etc/environment.d/*.conf` when it starts, so a new login (or reboot) is
enough; no system-wide PipeWire is involved. Not covered: system services
such as `alsa-restore.service`/the udev `alsactl` rule, which run card
BootSequences as root with the stock UCM tree. That only matters for
`codecs/tas2783/init.conf`, which the stock `sof-soundwire.conf` does not
include anyway (see `overlay/ucm2/UPSTREAM.md`). To pick up the overlay
without logging out:

```sh
systemctl --user set-environment ALSA_CONFIG_UCM2=/var/lib/ally-x20-steamos/ucm2
systemctl --user restart wireplumber pipewire pipewire-pulse
```

No `modprobe.d` options are needed for SOF/SoundWire on ACP 7.x with this
layout: hungarianhc's working setup and aquarius-os PR #40 only replace
modules via install hooks (the `modules` component) and set
`firmware_class.path`.

## Verifying

After `apply` and a reboot:

```sh
aplay -l                      # a card "amdsoundwire" with a Speaker PCM
cat /proc/asound/cards
amixer -c amdsoundwire info | grep Components   # should include spk:tas2783
journalctl -k | grep -iE 'acp|sof|soundwire|tas2783|Table Upgrade'
#   "ACPI: Table Upgrade: override [DSDT-...]"      override loaded
#   no "Failed to read ... fw binary"               tuning found
#   no "Program transport params failed"            SmartAmp capture link gone (0003)
cat /sys/module/firmware_class/parameters/path  # /etc/ally-x20-steamos/firmware
systemctl --user show-environment | grep ALSA_CONFIG_UCM2
alsaucm -c amdsoundwire dump text | grep -A3 Speaker
wpctl status                  # a "Speaker" sink instead of Dummy Output
sudo ally-x20-steamos.sh status --verbose
```

`status --verbose` prints the sub-probes from `audio_probe_details`:

```
layout=needed|superseded|unknown     stock snd-soc-acpi-amd-match has the RC74XA link-0 layout
acpi=...                             stock boot gets a SoundWire card without our override
ucm=...                              stock alsa-ucm-conf has sof-soundwire/tas2783.conf
firmware=...                         stock firmware has every name the stock driver requests
```

The component is `superseded` only when all four say so. `acpi` reports
`unknown` while our override is active (it cannot tell what a stock boot would
do) and whenever the live table or `/proc/asound/cards` is unavailable.

## Turning it off

`sudo ally-x20-steamos.sh uninstall` removes every file listed above, using
the manifest, and restores the saved boot entry. To undo only the UCM part
for a test, unset the variable for the session (commands above with
`unset-environment`) and restart PipeWire.

## What only the hardware can confirm (`TODO(hw)`)

- The `SPEAKER_ID` value-to-supplier mapping (`firmware/speaker-id.map`;
  hungarianhc: 0 = JGX, 1 = LS; aquarius-os bench-proved only 1).
- That the speakers play without the `codecs/tas2783/init.conf`
  BootSequence (`Left Spk`/`Right Spk` DAPM switches on by default).
  hungarianhc reports working stereo on SteamOS 3.9.3 without it.
- Which card name/driver the kernel reports (`amdsoundwire`/`amd-soundwire`
  expected; the `acpi` probe also accepts `sof-soundwire`).
- The `layout` probe heuristic: upstream may name the layout table
  differently from `acp70_tas2783x2_l0u8b_rt721_l1u0`.
- The amps' feedback capture stream (`SDW0-PIN4-CAPTURE-SmartAmp`) fails to
  start per hungarianhc; no application uses it. With patch `0003` the PCM
  should no longer exist and the `-22` bursts should stop.
- That a mixer change to `Amp Volume` / `Speaker Volume` survives the sink
  suspending (`0004`), and that the card still comes up with the tuning
  firmware loaded synchronously (`0005`).

## Measured on the X20 (2026-10-31)

- The `acp-audio-config-flag` property is **not in the DSDT**. It lives in an
  SSDT (OEM `AMD`, table ID `OEMACP`, `SSDT8` on BIOS RC74XA.303) as one
  `ByteConst 0x10`. The tool scans all tables and the override ships that SSDT.
- Stock SteamOS 3.9.5 shows only the HDMI audio card; no TAS2783 UCM or
  firmware is present; `SPEAKER_ID` is 1 (LS supplier).
- `snd-acp-config` and `snd-soc-acpi-amd-match` are not in the initramfs, so
  the modprobe `install` hooks take effect on the first load.
