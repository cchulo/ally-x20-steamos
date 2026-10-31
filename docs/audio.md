# Audio: the X20's internal speakers

Component: `audio` (`components/audio.sh`). Kernel module side: `modules`.
Headphone virtual surround and the speaker DSP chain: `audio_dsp`.

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

Valve's `7.2.10-valve1` kernel already contains the RC74XA link-0 layout, the
ACPI flag handling and the SPEAKER_ID-aware firmware names. On such a kernel
the `modules` component and the ACPI override become superseded, while the UCM
profile (alsa-ucm-conf) and possibly the firmware links are still needed until
SteamOS's userspace packages catch up. `status --verbose` shows each part
separately (see below).

## What the component installs

Everything is recorded in the manifest and removed by `uninstall`.

| Path | What |
|---|---|
| `/etc/modprobe.d/ally-x20-steamos-audio.conf` | `install snd_soc_tas2783_sdw` hook: sets `firmware_class.path` to our firmware dir right before the amp driver loads (never overrides an existing value) |
| `/var/lib/ally-x20-steamos/firmware/` | pinned, SHA-256-verified TAS2783 tunings plus links under the names the driver requests |
| `/var/lib/ally-x20-steamos/ucm2/` | UCM overlay (see below) |
| `/etc/environment.d/90-ally-x20-steamos-ucm.conf` | `ALSA_CONFIG_UCM2=/var/lib/ally-x20-steamos/ucm2`; written only after the overlay is complete |
| `/var/lib/ally-x20-steamos/acpi/` | `ally-x20-steamos-acpi.img`, `DSDT.patched.aml`, `DSDT.orig.aml`, `BUILD-INFO` from the ACPI tool |
| `/efi/EFI/steamos/ally-x20-steamos-acpi.img` | the early initrd on the active slot's ESP (manifest slot `esp`) |
| active slot's boot entry | early initrd added by `slot_set_early_initrd` from `lib/slots.sh` (the plan's documented exception; original saved by that library) |

The ACPI step only runs on board `RC74XA`, needs `python3` and the ACPI tool,
and is skipped (logged, never fatal) when anything is missing. It uses the
live `/sys/firmware/acpi/tables/DSDT`; the repository's
`acpi/fixtures/x20-dsdt.aml` is only used against a fixture or VM root, never
on hardware. While our override is active the tool rebuilds from the saved
`DSDT.orig.aml`; if the BIOS changed since (tool exit 5), apply asks you to
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
cat /sys/module/firmware_class/parameters/path  # /var/lib/ally-x20-steamos/firmware
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
  start per hungarianhc; no application uses it.
