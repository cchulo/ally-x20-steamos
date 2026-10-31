# X20 speaker stack: how ours compares to other projects, and the loud-passage static

Status: research notes, 2026-10-31. Nothing here has been run on hardware by
this project. Each claim is marked:

- **[src]**: checked in the source code, patch or firmware file named next to it.
- **[inf]**: inference from the sources. Plausible, but not proven.
- **[ext]**: something another project or person reports.

## The problem

On the device (SteamOS 3.9.5, kernel `7.2.7-valve2-2`) our stack plays stereo
through both TAS2783 amps. In loud game passages (Resident Evil 2 action
scenes) the speakers give bursts of crackling, white-noise-like static. This
happens with our PipeWire DSP chain turned off, so the cause is below
PipeWire. Measured state:

| Control | Value |
|---|---|
| `Left/Right Spk Switch`, `Left/Right Spk2 Switch` | on |
| `tas2783-1/2 Amp Volume` | 20 of 20 (TLV 11 dB + 0.5 dB/step, so +21 dB) |
| `tas2783-1/2 Speaker Volume` | 200 of 200 (0 dB) |
| PipeWire sink volume | 0.60 |
| Kernel log | 20-line bursts of `sdw-master-0-0: Program transport params failed: -22` and `SDW0-PIN4-CAPTURE-SmartAmp: ASoC error (-22) at snd_soc_link_prepare()` each time the SmartAmp capture PCM is opened |
| Tuning firmware | loads; no "Failed to read preferred fw binary" |

## Sources compared

| Source | Version read |
|---|---|
| Ours | `origin/main` @ `5c32ab9`: `patches/kernel/0001`, `0002`, `firmware/`, `overlay/ucm2/`, `components/audio.sh`, `docs/audio.md` |
| linux-stable | `v7.2.7`: `sound/soc/codecs/tas2783-sdw.c`, `tas2783.h`, `include/sound/tas2781-tlv.h`, `sound/soc/sdw_utils/soc_sdw_ti_amp.c`, `drivers/soundwire/{stream,generic_bandwidth_allocation,amd_manager,bus}.c` |
| anatase-org/kernel-anatase | `patch-2-anatase.patch` at tags `7.2.7-an21`, `an22`, `an23`, `an26`, `an28` (split into single patches and diffed by subject) |
| Valve (mirror evlaV/linux-integration) | tag `7.2.10-valve1` (commit `1b214a39f3cb`). The `7.2/integration` branch has no newer audio commits than the tag (checked 2026-10-31). |
| Upstream | torvalds `master` (7.3), linux-next `master`, broonie `sound.git for-next`: history of the files above |
| hungarianhc/rog-ally-x20-steamos-speakers | `main` (pushed 2026-10-18): README, `ally-audio-fix.sh`, `patches/0001-…`, `ucm/tas2783.conf` |
| ovenham/rog-ally-x20-steamos-speaker-qam-fix | `main` (pushed 2026-10-21): README, `speaker-fix/`, `upstream/acp-config-rog-xbox-ally-x20.patch`, `plugin/py_modules/wake_fix.py` |
| stoneharborent/aquarius-os PR #40 | merged head `ac14387874cf`: `build_files/x20-audio/*.patch`, modprobe.d, `aquarius-x20-audio`, `tas2783.conf`, `docs/restart/handheld.md` |
| linux-firmware | `a2dcb924f089`: `ti/audio/tas2783/1954-{0,1}-0-0x{8,B}.bin`, parsed chunk by chunk |
| alsa-ucm-conf | `master` @ `d260eedd1900` |

## Differences, item by item

### Link layout (`amd-acp70-acpi-match.c`)

| | Ours (0001) | Valve `5f7b3941a10f` / anatase an22 | hungarianhc / ovenham | aquarius PR #40 | Upstream 7.3 / linux-next |
|---|---|---|---|---|---|
| Amp `_ADR`s | `0x0000380102000001`, `0x00003B0102000001` (link 0, uid 8 / 0xB) | same | same | same | **not present** |
| RT721 `_ADR` | `0x000130025D072101` (link 1, uid 0) | same | same | same | – |
| Amp endpoints | 1 each: `spk_l_endpoint`, `spk_r_endpoint` (aggregated, group 1, positions 0/1) | same | same | same | – |
| Amp feedback (capture) endpoint in the table | none (the table has no direction; see below) | none | none | none | – |
| `name_prefix` | `tas2783-1`, `tas2783-2`, `rt721` | same | same | same | – |
| RT721 endpoints | `jack_dmic_endpoints` (EP 0 UAJ + EP 2 DMIC) | same | same (plus a comment) | same (different array names) | – |
| Table position | before `acp70_rt721_only` | same | same | same | – |
| Result | blob `ee51de5f1fb3` | blob `ee51de5f1fb3` **[src]** | same hunk apart from a comment **[src]** | same data, renamed arrays **[src]** | – |

All four projects ship the same layout bytes. Our 0001 and Valve's commit
produce the same file blob **[src]**. The feedback capture DAI link does not
come from the layout table. `soc_sdw_utils` adds it because the TAS2783
`codec_info` entry declares a capture DAI, and on v7.2.7 nothing in the table
can turn it off **[src]**.

`CONFIG_SND_SOC_ACPI_AMD_SDCA_QUIRKS`: none of the RC74XA patches use it. No
project adds an SDCA quirk for this board **[src]**.

### ACP flag (`acp-config.c`)

| | Ours (0002, optional; we use the SSDT override) | Valve `045b13e03d29` / anatase | ovenham `upstream/` | aquarius |
|---|---|---|---|---|
| Match | `DMI_MATCH` board vendor + board name `RC74XA` | same (our hunk is byte-identical) | `DMI_PRODUCT_NAME "RC74XA"` | `DMI_EXACT_MATCH` board vendor + board name |

Upstream 7.3 / linux-next has other boards in this table but not RC74XA
(checked to 2026-10-16) **[src]**.

### Amp feedback / SmartAmp capture

| | Ours (stock v7.2.7) | Valve 7.2.10-valve1 / anatase an22 | Upstream 7.3 |
|---|---|---|---|
| Capture DAI link `SDW0-PIN4-CAPTURE-SmartAmp` | created | **dropped** by `9a0dabd2637d` "ASoC: sdw_utils: honor empty DisCo port lists when creating DAI links" (anatase: same hunks) | created. `cd4a294c4b2d` "soundwire: stream: validate slave port properties" (7.3-rc1) makes it fail earlier, in `hw_params` (`port 2 not supported for TX`) instead of `prepare` |
| hungarianhc / ovenham / aquarius | each lists the capture errors as a known, unexplained issue that "doesn't affect playback" **[ext]** | | |

Why `-22`, checked in v7.2.7 source:

1. Per Valve's commit message, the X20 BIOS sets `mipi-sdw-source-port-list = 0`
   for both TAS2783s, so the amps have no DisCo properties for source
   (capture) port 2.
2. `tas_sdw_hw_params()` uses port 2 for capture. `sdw_stream_add_slave()` in
   7.2.7 does not check that the port exists.
3. In `snd_soc_link_prepare()` → `sdw_prepare_stream()` →
   `sdw_program_params()` → `sdw_program_slave_port_params()`,
   `sdw_get_slave_dpn_prop()` returns NULL and the function returns
   `-EINVAL`. `_sdw_program_params()` logs `Program transport params failed`.

That is the burst, and it is fully explained.

The side effect that matters, checked in v7.2.7 source:

- The amp has one DAI for both directions. `tas_sdw_hw_params()` writes PDE23
  = PS0 (power on) for **either** direction.
- `tas_sdw_pcm_hw_free()` writes PDE23 = **PS3 (power off)** for **either**
  direction.
- So when the failed capture PCM is closed, the driver powers down the
  SmartAmp's power domain on both amps. That happens even if the playback
  stream on the same amps is running.
- Whether that ever overlaps active playback depends on when userspace opens
  the capture PCM **[inf]**. At card probe or profile activation the speaker
  stream is normally closed too.

### Firmware (tuning) naming and placement

| | Ours | hungarianhc / ovenham | aquarius | Valve 7.2.10-valve1 (`8ba654cb1c44`) |
|---|---|---|---|---|
| Source | linux-firmware `a2dcb924`, SHA-256 pinned | same commit and hashes | Fedora's `/usr/lib/firmware`, hashes from the image | linux-firmware root `Link:` names |
| Supplier choice | `SPEAKER_ID` EFI var, 0 = JGX, 1 = LS (`--supplier` override) | `SPEAKER_ID`, same mapping | `SPEAKER_ID` used directly as the file digit | `SPEAKER_ID` read by the driver and used as the file digit |
| Name the driver gets | `1954-0-0x8.bin` / `1954-0-0xB.bin` (plus four-field links) | `1954-0-0x{8,B}.bin` | `1954-0-0x{8,B}.bin` | `1954-<SPKID>-0-0x{8,B}.bin` first |
| Location | `/etc/ally-x20-steamos/firmware`, `firmware_class.path` via a modprobe `install` hook, sysfs or the cmdline | `/var/lib/ally-audio-fix`, `firmware_class.path` from a modprobe hook | `/run/aquarius-x20-firmware`, `firmware_class.path` from the loader | stock path |

Every project picks the same file for a given `SPEAKER_ID` (for `1`:
`1954-1-0-0x*.bin`) **[src]**. Our unit reports `SPEAKER_ID = 1` (LS).

What the tuning files contain (parsed, **[src]**: chunk headers per
`tas_fw_get_next_file()`):

| File | DDC name | `AMP_LEVEL` (`0x800003`) | `DVC_LVL` (`0x80001A`) |
|---|---|---|---|
| `1954-1-0-0x8.bin` (LS left) | `RC74_LS_SNDW_alpha10_GuanWei_20260415_V4` | `0x28`, so field 20 = max | `0x00` = 0 dB |
| `1954-1-0-0xB.bin` (LS right) | same | `0x28` | `0x00` |
| `1954-0-0-0x{8,B}.bin` (JGX) | `RC74_JGX_SNDW_alpha10_GuanWei_20260415_V4` | `0x28` | `0x00` |

The left and right files differ only in the page-0 registers `0x0a`, `0x0c`,
`0x0d` and `0x0f` (channel/slot setup) **[src]**.

So the measured `Amp Volume = 20` and `Speaker Volume = 200` are **exactly
what TI's tuning writes**. Our stack does not raise them, and neither does
UCM. Also note that the published tuning is labelled **"alpha10"** and dated
2026-04-15, half a year before launch **[src]**. Whether Windows ships a newer
tuning is unknown. I found no public information on what Armoury Crate or the
Windows driver programs.

### UCM / mixer defaults

| | Ours | hungarianhc / ovenham / aquarius | alsa-ucm-conf master |
|---|---|---|---|
| `sof-soundwire/tas2783.conf` | verbatim upstream | the same file (diffed) | unchanged since `182d0122a7d9` (2026-08-21) |
| `codecs/tas2783/init.conf` | shipped (inert with the stock dispatcher) | not shipped | `Left/Right Spk(2)` on |
| Volume csets | none | none | **none**. UCM never touches `Amp Volume` or `Speaker Volume` |
| alsa state / amixer / WirePlumber config | none | none (ovenham: `pactl suspend-sink 1/0` after wake) | – |

The kernel side caps `Speaker Volume` at 200 (0 dB):
`asoc_sdw_ti_amp_initial_settings()` calls `snd_soc_limit_volume(…, 200)`.
Nothing limits `Amp Volume` **[src]**. So the answer to "does UCM set
`Amp Volume` to max by design?" is no. Max is the driver's register default
(`tas2783_reg_default[]`: `{TAS2783_AMP_LEVEL, 0x28}`) and the tuning's value
**[src]**. A TI applications engineer's advice for related parts is that
`AMP_LEVEL` should not be changed in SmartAmp mode
([E2E](https://e2e.ti.com/support/audio-group/audio/f/audio-forum/981009/tas2563-question-of-tas2563-dvc_pcm-register)) **[ext]**.

Behaviour on v7.2.7 to know before running any amixer test (from Valve's
`021e9da34c58` commit message, consistent with the v7.2.7 code **[src]**):

- The register cache is dropped on every uninitialized re-attach.
- The X20 powers the link off when idle, so each amp is reset and re-initialized
  on every wake.
- `Amp Volume` / `Speaker Volume` reads and writes fail with `-EBUSY` while the
  amp is runtime-suspended.
- A value you set is lost the next time the link idles.

So **set it while audio is playing, and expect it to revert** after the sink
suspends.

### Extra kernel patches others carry and we do not

anatase `7.2.7-an22` ("Ally X20 Audio backports") adds 17 audio patches. These
are Valve's `7.2.10-valve1` audio commits (one carries a "Holo:" note).
an23–an28 add no further audio patches, only "add a quirk for the x20" in
`asus-nb-wmi` (sleep, not audio) **[src]**. Valve 7.2.10-valve1 additionally
has three tas2783 commits that anatase does not carry.

| Patch | Valve id | anatase | Upstream | Purpose | Relevant to static? |
|---|---|---|---|---|---|
| tas2783: do not treat read-only Controls as writable | `14ccd7d8175b` | yes | 7.3 | `regcache_sync()` aborted with `-ENODATA` on RO controls | no (resume robustness) |
| sdw_utils: prepare the stream again when resuming | `2700598cc20c` | yes | 7.3 (tas2783 variant "prepare the port again on the resume path") | silence after `SNDRV_PCM_IOCTL_RESUME` (ovenham's "silent after sleep") | no |
| tas2783: power the Function up before preparing the port | `5c9979eb1917` | yes | 7.3 | PDE23 PS0 in port PRE_PREP; silence after S0i3 | no (but it is the PDE23 handling) |
| tas2783: make multi-byte MBQ registers reachable | `e9c8c61fd80d` | yes | 7.3 | regmap `val_bits` fix, calibration writes rewritten | maybe (calibration write path) |
| tas2783: do not cache read-only Controls | `f2c5622fdb8c` | yes | 7.3 | volatile RO controls | no |
| tas2783: split a stereo stream across the two mono amps | `a15043a1338a` | yes | 7.3 | one channel per amp instead of mirror mode | see H6 |
| tas2783: add firmware download status check | `65eadd5b0e65` | yes | 7.3 | skip PRAM download on resume when the version matches | no |
| tas2783: use the BIOS speaker ID in the firmware name | `8ba654cb1c44` | yes | not yet | four-field firmware names | no (we rename) |
| sdw_utils: honor empty DisCo port lists | `9a0dabd2637d` | yes | not yet | removes the SmartAmp capture link on X20/PX13 | **yes, H4** |
| acp: RC74XA machine entry / acp-config RC74XA | `5f7b3941a10f` / `045b13e03d29` | yes | not yet | = our 0001/0002 | – |
| rt721 ×4 + "wait for PDEs to reach PS0" | `5a2dee1b1fc4`, `4f3e6e98e0b6`, `20a529f9c616`, `62bab7ea7ca9`, `e9ab1a3d0a95` | yes | partly | headset codec (no sound, abnormal sound after warm reboot from Windows, mic pop) | no (RT721 does not drive the speakers) |
| amd: ps: fix `snd_acp63_remove()` teardown ordering | – | yes | stable | UAF on unbind | no |
| tas2783: keep the volume settings across resets | `021e9da34c58` | **no** | not yet | volume controls usable while suspended; userspace values reapplied after every re-init; tuning value adopted otherwise | needed to make H3 tests stick |
| tas2783: load the firmware synchronously | `5ce75814c28a` | **no** | not yet | no 3 s async timeout; the download is ~1.2 s per amp on X20 | no |
| tas2783: refuse playback when the init writes failed | `2ce1d48892f3` | **no** | not yet | the X20 DisCo init table carries the per-amp posture; never play without it | indirect (wrong posture = wrong channel/mix) |

Applicability, checked with `git apply` on the v7.2.7 files **[src]**:

- `9a0dabd2637d` / anatase `0257` applies **on its own** to v7.2.7.
- The full anatase tas2783 stack plus Valve's three follow-ups applies in
  order on v7.2.7.
- Without the mono-split patch, `65eadd5b0e65`, `021e9da34c58` and
  `5ce75814c28a` no longer apply cleanly.
- The resulting `tas2783-sdw.c` is not byte-identical to Valve's
  (`f1c5fb76…`), because Valve also has upstream cleanups.

### The mono-split disagreement

- Our README, hungarianhc and ovenham say the mono split "silences the right
  amp" on the X20 **[ext]**. None shows logs.
- Valve's 7.2.10-valve1, whose X20 commits cite measurements on the device,
  ships the mono split together with the RC74XA layout **[src]**.
- On stock v7.2.7 each amp is in mirror mode: `ch_mask` 0x3, and
  `sdw_compute_slave_ports()` resets the offset for the next amp **[src]**.
  The per-amp posture from the BIOS DisCo init table then picks the side.
- Our claim should be treated as unverified until we test it.

## Hypotheses for the loud-passage static, ranked

The symptom only appears at high signal level. That points first at the amp's
analog and protection domain (clipping, supply brownout, the protection
algorithm's limiter). A SoundWire transport fault is less likely, because it
would not care how loud the signal is **[inf]**.

### H1: Speaker-protection state: UEFI calibration and/or the "alpha" tuning (most likely)

Evidence:

- After every tuning download the v7.2.7 driver reads `SmartAmpCalibrationData`
  or `CALI_DATA` (GUID `1f52d2a1-bb3a-457d-bc09-43a3f4310a92`).
- It writes R0, invR0, R0_low, power and TLIM into each amp by unique id
  (`tas2783_update_calibdata()`). If the variable is missing, it only logs
  `dev_dbg` **[src]**.
- Precedent on the predecessor ROG Xbox Ally X (RC73XA, TAS2781 HDA): audio
  dropouts were fixed by skipping UEFI calibration
  ([patch](https://patchew.org/linux/20260108093650.1142176-1-matthew.schwartz@linux.dev)).
  Users reported distortion and dropouts above about 70% volume that changed
  with the firmware variant
  ([LKML thread](https://lkml.iu.edu/2512.1/01179.html)) **[ext]**.
- The tuning in linux-firmware is an "alpha10" build **[src]**.

Tests, safest first:

```sh
# 1. Does calibration data exist, and what did the driver do with it?
ls /sys/firmware/efi/efivars/ | grep -iE 'SmartAmpCalibrationData|CALI_DATA'
journalctl -k -b | grep -iE 'cali|tas2783'
#    errors to look for: "calib data integrity check fail", "unique id not found in the calib data", "cali data too large"

# 2. See the calibration path on the next amp re-init (the link idles and re-inits on its own)
echo 'module snd_soc_tas2783_sdw +p' | sudo tee /sys/kernel/debug/dynamic_debug/control
#    stop all audio for ~10 s, then play again; look for "cali get N bytes", "calib data update done" or "No calibration data in UEFI."
journalctl -k -b | grep -iE 'cali'
echo 'module snd_soc_tas2783_sdw -p' | sudo tee /sys/kernel/debug/dynamic_debug/control
```

3. Diagnostic kernel change (only if test 1 shows calibration being applied).
   Rebuild `snd-soc-tas2783-sdw.ko` with a module parameter that skips
   `tas2783_update_calibdata()`, mirroring the RC73XA fix. Then compare RE2
   with `options snd_soc_tas2783_sdw skip_calib=1` against `skip_calib=0`.
   To revert, delete the options line. In `tas2783-sdw.c` (v7.2.7):

   ```c
   static bool skip_calib;
   module_param(skip_calib, bool, 0644);
   MODULE_PARM_DESC(skip_calib, "Do not apply UEFI speaker calibration (diagnostic)");
   ...
   	} else if (!skip_calib) {
   		tas2783_update_calibdata(tas_dev);
   	}
   ```

   This needs a new `modules.list` line (`sound/soc/codecs`,
   `snd-soc-tas2783-sdw.ko`). It is not written in this PR.

### H2: Supply or output headroom: clipping or brownout at +21 dBV

Evidence:

- `AMP_LEVEL` is at max (+21 dBV on the TAS27xx scale; on the TAS2770 that is
  15.9 V peak, and TI notes the levels "may not be achievable because of
  analog clipping") **[src]** for the register and the firmware value,
  **[ext]** for the dBV meaning on TAS2783.
- But that is the tuning's own value, so on Windows the same thing would have
  to be handled by the limiter or brownout protection in the same DSP image
  **[inf]**.

Tests:

```sh
# a. Level threshold: replay the same scene at sink volume 0.60, 0.45 and 0.30.
#    Static that disappears below a threshold = level-dependent (H1/H2).
#    Static at every level = transport or data (H4/H5).
wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.45

# b. Power: same scene on AC with a full battery, and on battery below ~30 %.
#    Worse on low battery points to brownout or the VBAT limiter.

# c. Reduce the analog gain 3 dB on both amps WHILE AUDIO IS PLAYING
#    (on v7.2.7 the value reverts when the link idles; see "UCM / mixer defaults"):
amixer -c amdsoundwire cset name='tas2783-1 Amp Volume' 14
amixer -c amdsoundwire cset name='tas2783-2 Amp Volume' 14
amixer -c amdsoundwire cget name='tas2783-1 Amp Volume'   # confirm it stuck
#    revert: set both back to 20, or just let the sink idle (> 5 s silence)
```

Test c is a diagnostic only. TI's guidance is not to change `AMP_LEVEL` in
SmartAmp mode, because the protection model assumes the tuned gain. To make
it persist, or to ship a lower gain, needs Valve's `021e9da34c58`.

### H3: Wrong or early tuning variant for this speaker

Evidence:

- `SPEAKER_ID = 1` maps to the LS files in every project and in Valve's driver
  (the file digit equals `SPEAKER_ID`) **[src]**. So a mapping bug in our
  stack is unlikely.
- The Ally X precedent shows variant mismatches producing exactly this class
  of symptom **[ext]**.

Tests:

```sh
cat /etc/ally-x20-steamos/firmware/supplier 2>/dev/null   # empty = automatic from SPEAKER_ID
readlink -f /etc/ally-x20-steamos/firmware/1954-0-0x8.bin /etc/ally-x20-steamos/firmware/1954-0-0xB.bin
sha256sum "$(readlink -f /etc/ally-x20-steamos/firmware/1954-0-0x8.bin)"   # LS left = 677e3d03…
```

Last resort, and risky: the other supplier's protection limits may not match
your speakers. Keep the volume low and the test short. Run
`sudo firmware/fetch-tas2783.sh --supplier JGX`, then reboot and compare. To
revert, run `sudo firmware/fetch-tas2783.sh --supplier LS` and reboot.

### H4: Feedback-capture misconfiguration and its PDE23 power-off

Evidence:

- The `-22` bursts are explained in source (empty `mipi-sdw-source-port-list`).
- On v7.2.7, closing the failed capture PCM writes PDE23 = PS3 on both amps
  **[src]**.
- This only causes trouble if it happens while the speaker stream runs
  **[inf]**. The bursts are tied to profile activation, not to loud passages,
  so this is ranked below H1–H3.
- The fix exists, and the other X20 kernels ship it (Valve, anatase).

Tests:

```sh
# Correlate: keep this running while you play the scene that crackles.
journalctl -kf -o short-monotonic | grep -E 'SmartAmp|transport params|tas2783'
#   static WITHOUT a burst at the same moment -> H4 is not the cause
```

Fix to try: add Valve `9a0dabd2637d` (anatase `0257`) as a new kernel patch.
It applies to v7.2.7 by itself **[src]**. It changes
`struct asoc_sdw_endpoint` in `include/sound/soc_sdw_utils.h`, so all its
users must be rebuilt and replaced together:

- `snd-soc-sdw-utils.ko` (`sound/soc/sdw_utils`)
- `snd-acp-sdw-legacy-mach.ko` and `snd-acp-sdw-sof-mach.ko` (`sound/soc/amd/acp`)

Expected result: no SmartAmp capture PCM, no `-22` bursts. To revert,
remove the modules from `modules.list` and reboot.

### H5: SoundWire bus errors (parity or bus clash)

Evidence:

- The AMD manager sets `SDW_MASTER_QUIRKS_CLEAR_INITIAL_{CLASH,PARITY}`.
- At runtime the core logs `Parity error detected` / `Bus clash detected`
  **[src]**.
- Nothing points at them yet. This is cheap to rule out.

```sh
journalctl -k -b | grep -iE 'parity|clash|sdw|soundwire' | grep -v 'transport params'
```

If these lines line up with the static, the problem is bus signal or clock.
That has no userspace knob: `amd_manager` has no module parameters **[src]**.

### H6: Missing follow-up kernel fixes, or mono vs mirror mode

Evidence:

- None of the 12 tas2783 commits in Valve 7.2.10-valve1 targets noise **[src]**.
- In mirror mode each amp receives both channels. If an amp's input stage
  sums L+R instead of selecting one side (the posture is not verified on our
  unit), peaks run up to +6 dB higher than in the mono-split configuration
  **[inf]**.

Tests:

```sh
speaker-test -D hw:amdsoundwire,2 -c 2 -t wav -l 1   # stop PipeWire's sink first, or use: pw-play with a hard-panned file
#   "Front Left" must come only from the left speaker, and "Front Right" only from the right one.
```

The strongest A/B test is to boot a SteamOS image with kernel
`7.2.10-valve1`. It carries all of Valve's fixes, including the mono split
and `9a0dabd2637d`. On that kernel our `modules` component reports
`superseded`. If the static persists there, it is the tuning or the hardware
(H1–H3), not our patches.

## Summary of what we do differently

- **Layout and ACP flag:** the same as everyone (byte-identical to Valve).
- **Firmware:** the same files for the same `SPEAKER_ID`. Only the directory
  differs.
- **UCM:** the same as everyone (verbatim upstream). Nobody sets volumes.
- **Kernel driver:** we run stock v7.2.7 `tas2783-sdw` and `soc_sdw_utils`.
  Valve and anatase run 9–12 later fixes, including the capture-link removal
  (`9a0dabd2637d`) and the volume/reset handling (`021e9da34c58`, Valve only).
  Upstream 7.3 has the first seven tas2783 fixes but not yet the X20-specific
  ones.

## Sources

- [anatase-org/kernel-anatase](https://github.com/anatase-org/kernel-anatase) (`patch-2-anatase.patch` at each tag)
- [evlaV/linux-integration](https://github.com/evlaV/linux-integration) tag `7.2.10-valve1`
- [hungarianhc/rog-ally-x20-steamos-speakers](https://github.com/hungarianhc/rog-ally-x20-steamos-speakers)
- [ovenham/rog-ally-x20-steamos-speaker-qam-fix](https://github.com/ovenham/rog-ally-x20-steamos-speaker-qam-fix)
- [stoneharborent/aquarius-os PR #40](https://github.com/stoneharborent/aquarius-os/pull/40)
- [linux-stable v7.2.7 tas2783-sdw.c](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/sound/soc/codecs/tas2783-sdw.c?h=v7.2.7)
- [linux-next "soundwire: stream: validate slave port properties"](https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/commit/?id=cd4a294c4b2dcdf86b87128ce4d2023fc016a285)
- [alsa-ucm-conf tas2783.conf](https://github.com/alsa-project/alsa-ucm-conf/blob/master/ucm2/sof-soundwire/tas2783.conf)
- [TAS2781 Ally X: skip UEFI calibration](https://patchew.org/linux/20260108093650.1142176-1-matthew.schwartz@linux.dev), [Ally X firmware-variant distortion reports](https://lkml.iu.edu/2512.1/01179.html)
- [TI TAS2770 AMP_LEVEL scale](https://www.ti.com/document-viewer/TAS2770/datasheet/GUID-B76298B6-119E-46CD-9DBD-F7AF30086665), [TI E2E on AMP_LEVEL in SmartAmp mode](https://e2e.ti.com/support/audio-group/audio/f/audio-forum/981009/tas2563-question-of-tas2563-dvc_pcm-register)
