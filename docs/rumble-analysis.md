# Rumble on the X20: report formats, magnitude scaling, and the speaker static

Research date: **2026-10-31**. Everything here comes from reading source code
and public pages. **None of it has been tested on an X20.** Each claim is
marked:

- **[source]**: read in the source at the commit listed under [Sources](#sources).
- **[inferred]**: a conclusion drawn from the source and the owner's
  observations, not verified.
- **[owner]**: observed by the owner on a real X20.

## 1. What the owner sees [owner]

Setup: ROG Xbox Ally X20 (N-KEY USB `0b05:1b4c`), SteamOS 3.9.5, kernel
`7.2.7-valve2` with our `hid-asus-ally` patches 0010-0013, stock
InputPlumber 0.78.0 with our X20 profile (`/etc/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml`,
the stock-adapted variant, see [inputplumber.md](inputplumber.md)).

1. In games (RE2, Cyberpunk), strong rumble makes the speakers hiss (white
   noise). The hiss stays with the ALSA speaker switches muted and with our
   PipeWire DSP off. It goes away when rumble is disabled in Steam. So the
   hiss is not in the audio samples.
2. Rumble sent through the kernel force-feedback path
   (`vm/guest/rumble-test.py`: `FF_RUMBLE` on "ASUS ROG Ally X Gamepad",
   steady or pulsed at 20 Hz, 25-100 %, with audio playing) never causes the
   hiss.
3. Through that same path, 100 % feels like about 25 %.

## 2. Short answer

- **The starting hypothesis is wrong for 0.78.0.** Stock InputPlumber
  0.78.0 never writes HID reports to the MCU. Its ROG Ally hidraw source has
  no output code at all. It only sets sysfs attributes. In a game, rumble
  goes game → Steam → InputPlumber's virtual Xbox Elite pad (uinput) →
  InputPlumber → `EVIOCSFF`/`EV_FF` on "ASUS ROG Ally X Gamepad" →
  `hid-asus-ally` → MCU. That is **the same kernel function the owner's test
  used** [source]. Only InputPlumber ≥ 0.83.0 writes raw reports, and only
  on `RC73XA`/`RC74XA` (§3.2).
- **The kernel scales rumble wrong. This is verified.** `hid-asus-ally`
  converts magnitudes with `/ 512`, which gives 0..127. The report's
  magnitudes are percentages, 0..100. InputPlumber 0.83, hhd, ally_module and
  `hid-microsoft.c` (same report block on the Xbox One S pad) all use
  0..100 [source]. So any request above about 78 % sends an out-of-range
  value (101..127). What the MCU does with those values is not documented.
  If it wraps them modulo 100, 65535 → 127 → 27 %, which would match "100 %
  feels like 25 %" [inferred]. Draft fix:
  [`patches/kernel/0014-…`](../patches/kernel/0014-hid-asus-ally-scale-rumble-and-vibration-intensity-to-0-100.patch).
- **The hiss itself is still unexplained.** Since both paths reach the same
  kernel code, what differs between a game and the test is the *pattern*
  sent to the motors, not the report format. Top hypothesis: the motor
  drive couples electrically into the speaker amplifiers (supply or ground
  noise picked up by the TAS2783 class-D amps, which stay powered when ALSA
  mutes them). Games trigger it with rapid magnitude updates, each one a new
  0x0d report that restarts the MCU's effect. The steady and 20 Hz test
  patterns did not [inferred]. §5 lists the alternatives and §7 a test that
  tells them apart.

## 3. Who sends what

### 3.1 The rumble report: byte layout

All implementations send the same 9-byte report, ID `0x0d`. It is the Xbox
wireless controller rumble block (`hid-microsoft.c`'s `struct xb1s_ff_report`,
report 3 on that pad), with a different report ID [source].

| byte | role | notes |
|---|---|---|
| 0 | report ID `0x0d` | |
| 1 | enable mask | `0x0f` = all four actuators. In the Xbox block: bit 0 weak/right, bit 1 strong/left, bits 2-3 the trigger motors |
| 2 | left trigger magnitude | 0..100 |
| 3 | right trigger magnitude | 0..100 |
| 4 | strong / left motor magnitude | 0..100 |
| 5 | weak / right motor magnitude | 0..100 |
| 6 | duration, 10 ms units | `0xff` = 2.55 s |
| 7 | start delay, 10 ms units | `0x00` |
| 8 | loop count | `0xeb` (235). With `0xff` duration, an effect plays about 10 minutes unless replaced |

Every report replaces the playing effect, so the MCU restarts the effect on
each one [inferred from the duration and loop fields; not documented].

### 3.2 Comparison

| implementation | report | transport | interface | strong/weak magnitude | trigger bytes 2-3 | enable | other |
|---|---|---|---|---|---|---|---|
| **Valve `hid-asus-ally` @ 7.2.7-valve2 (what runs now)** [source] | `0d 0f 00 00 SS WW ff 00 eb` | **SET_REPORT feature** (`hid_hw_raw_request(..., HID_FEATURE_REPORT, HID_REQ_SET_REPORT)`) | gamepad, EP `0x87` (interface 5) | **`magnitude / 512` → 0..127** (out of range above 78 %) | always 0 | `0x0f` | one report per `play_effect`, from a work item; no rate limit. Also sends the all-off report `0d 0f 00 00 00 00 ff 00 eb` to *both* interfaces at probe |
| same, with patch 0014 | same | same | same | `DIV_ROUND_CLOSEST(m * 100, 0xffff)` → 0..100 | 0 | `0x0f` | |
| Valve before `142c7546` (May 2026, not in 7.2.7-valve2) | strong/weak also copied into bytes 2-3 | feature | 5 | /512 | = strong/weak | `0x0f` | Valve removed the copy: "effectively double rumble intensity" on the Xbox Ally X |
| **InputPlumber 0.78.0 (stock SteamOS)** [source] | none: forwards `FF_RUMBLE` effects to the kernel evdev device | evdev | n/a | unchanged u16 (the kernel scales it) | n/a | n/a | the hidraw `RogAlly` source has an empty `SourceOutputDevice` impl |
| **InputPlumber 0.83.0/0.83.1** (our fallback build; upstream since commit `dbcd6c06`) [source] | `0d 0f LT RT SS WW ff 00 eb` | **output report** (hidapi `write()` on hidraw) | interface 5, opened only when `board_name` is `RC73XA` or `RC74XA` | `round(m / 65535 * 100)`, clamped to 100 | Steam Deck trigger-haptic pulses and `TriggerVibrationExtended` (0..100) | `0x0f` | On those boards the evdev source reports **no** FF output capability, so the kernel path is not used to play effects. The report is written on every change, and every 10 ms for trigger pulse trains |
| **hhd** (`eca609b0`) [source] | `0d 0f 00 00 WW SS ff 00 eb` | output report (`dev.write`) | the gamepad hidraw with application usages `0x000F0002`/`0x000F0021`/`0x00010005` (PID page = the rumble collection) | `min(100, m * 100)` | 0 | `0x0f` | **byte 4 = weak, byte 5 = strong**, the opposite of everyone else (harmless with equal values). X20 detected by DMI "ROG XBOX Ally X RC74X"; no X20-specific rumble code |
| kndclark/ally_module (`3422a5db`) [source] | `0d 0f 00 00 SS WW ff 00 eb` | feature | gamepad | `m * 100 / 65535` (`ALLY_FF_MAX_INTENSITY 100`) | 0 | `0x0f` | |
| `hid-microsoft.c`, Xbox One S pad (reference) [source] | `03 03 00 00 SS WW ff 00 ff` | output report | | `m * 100 / U16_MAX` | 0 | `0x03` | the block the Ally report is copied from |

**MCU vibration intensity** (separate setting, a gain on top of the
magnitudes): `5a d1 06 02 LL RR` (64-byte feature report, config interface,
EP `0x83`), 0..100 per side [source].

- Valve's driver keeps `0x64` (100) in its shadow copy but **never sends it
  at probe**. `apply_all`, which InputPlumber writes at startup, does not
  send it either. Its sysfs store rejects values above **64**, so 100 cannot
  be set back through sysfs. Patch 0014 lifts that limit.
- hhd sends 100 on the original Ally and **50 on the Ally X** ("ally x
  vibration motor is too strong").
- So the gain the X20 MCU uses under SteamOS is whatever its firmware (or
  Armoury Crate under Windows) last stored. That value is unknown and could
  also make rumble feel weak [inferred].

### 3.3 What is different on the X20

- InputPlumber lists `RC74XA` among the boards with "haptic trigger motors"
  (`HAPTIC_TRIGGER_BOARD_NAMES = ["RC73XA", "RC74XA"]`) [source]. The kernel
  never drives them: bytes 2-3 are always 0, but the enable mask `0x0f`
  enables them.
- None of the sources has X20-specific rumble bytes, a firmware-version
  switch for rumble, an "HD haptics" or audio-haptics command, or any command
  that touches audio [source]. hhd only re-initialises the controller after
  sleep on the X20 (it has no dynamic-lighting interface).
- Public pages (searched 2026-10-31): nothing on X20 rumble formats, MCU
  haptics modes, or rumble-related speaker noise under Linux or Windows.
  ASUS forum threads on the Ally X describe buzzing *motors* ("sounds like a
  bee"), fixed by a full shutdown, not speaker noise. g-helper and asusctl
  have nothing on Ally rumble.

## 4. The in-game path on 0.78.0, step by step [source]

1. The game rumbles Steam's virtual pad. Steam forwards it as `FF_RUMBLE`
   uploads and plays to InputPlumber's target "Microsoft X-Box One Elite pad"
   (uinput `045e:0b00`, with FF_RUMBLE, FF_PERIODIC and FF_GAIN).
2. `CompositeDevice::process_output_event` uploads the effect to **every**
   source device. The evdev source (`handler: event*`, every input node of
   `0b05:1b4c`) calls `EVIOCSFF` on each node that has FF. Later updates go
   through `update_effect` (another `EVIOCSFF` with the same id), and plays
   are forwarded as `EV_FF` events with the effect id translated.
3. In the kernel, `ff-memless` calls `ally_x_play_effect()` for each start
   and for each update of a playing effect. That sets `update_ff` and
   schedules the work item, which sends one feature SET_REPORT. Updates that
   arrive before the work runs are merged; nothing else limits the rate.
4. If Steam has switched InputPlumber to a Steam Deck target instead, Deck
   trackpad haptics arrive as `SteamDeckHaptics`. InputPlumber 0.78 plays each
   one as a 50 ms ("tick") or 150 ms ("click") rumble burst, which is a
   bursty on/off pattern.

So the test (`rumble-test.py`) and a game end in the same
`ally_x_play_effect()`, with the same `/ 512`. Only the update rate, the
magnitude changes over time, and (for Deck haptics) burst length differ.

## 5. Why does rumble make the speakers hiss? Hypotheses, most likely first

| # | hypothesis | for | against | how to test (§7) |
|---|---|---|---|---|
| 1 | **Electrical coupling.** Motor drive current, especially fast changes (each new 0x0d report restarts the effect and the motor current jumps), shows up on the supply or ground the TAS2783 amps share. A muted but powered class-D amp then plays it as hiss. | The hiss does not depend on audio samples: it stays with ALSA mute and DSP off [owner]. It appears only during *strong* in-game rumble [owner]. Games update rumble every frame. The owner's test only sent steady levels or 20 Hz pulses. | The steady 75 % test (`/512` → 96, the strongest level the kernel can reach if values above 100 misbehave) caused no hiss, so steady strength alone is not enough [owner]. | Matrix steps F, G, H (high report rates, varying magnitudes). Repeat with the speaker sink suspended so the amps power down: if the hiss goes away, it enters through the amps. `usbmon` during RE2 to see the real report rate and values. |
| 2 | **Out-of-range magnitudes (101..127)** put the MCU into undefined behaviour (wrap, clamp, or something else). | Verified that the kernel sends them [source]. Fits "100 % feels like 25 %" [owner] if the firmware wraps. Games often send full-scale rumble. | The test sent 127 at 100 % without hiss [owner], so 127 alone does not cause it. | `sweep` (90, 100, 101, 110, 127) and matrix A vs B vs I. |
| 3 | **Steam Deck haptics bursts.** If Steam drives InputPlumber's Deck target, trackpad haptics become 50/150 ms motor bursts. | Possible on SteamOS [source]. Bursts match a "strong rumble" feel. | The owner's profile targets `xbox-elite`. Whether Steam changes the target at runtime was not checked. | `busctl tree org.shadowblip.InputPlumber` during a game; InputPlumber debug log (§7.4). |
| 4 | **Trigger motors.** The enable mask `0x0f` turns on the X20's trigger actuators with magnitude 0. Their driver may idle noisily or behave differently on this firmware. | The X20 has trigger motors [source]. | They are enabled the same way in the test [source]. | Matrix D (enable `0x03`) and E (triggers only). |
| 5 | **InputPlumber writes raw reports in the wrong format** (the original hypothesis). | — | **Refuted for 0.78.0**: it writes no HID reports [source]. 0.83.x writes reports that match the spec (0..100). | Only relevant with the fallback 0.83.1 build. |
| 6 | **An MCU audio or haptics mode drives the speakers.** | — | No source has such a command [source]. The speakers hang off the ACP SoundWire TAS2783 amps, not off the MCU ([audio.md](audio.md)). | Ruled out if matrix A-I and §7.3 all stay quiet while a game still hisses. |

## 6. Fixes

### 6a. InputPlumber side

**No daemon patch is proposed.** Nothing in 0.78.0 is wrong for this issue:
it passes the effect through unchanged, and the scaling bug is in the
kernel. A daemon-side rate limit would be guessing until the test shows the
update rate matters (hypothesis 1). If it does, the limit belongs in the
kernel driver (one `delayed_work` with a minimum interval between 0x0d
reports), which covers every client, not only InputPlumber.

What the InputPlumber side can do today:

- **Use the upstream 0.83.1 path to test.** Run
  `AX20_INPUTPLUMBER_FALLBACK=1 ally-x20-steamos apply` (see
  [inputplumber.md](inputplumber.md)). On `RC74XA`, 0.83.1 drives rumble
  itself: output reports on interface 5, 0..100, trigger motors usable. It
  does not use the kernel FF path at all, so the scaling bug is avoided
  without a kernel rebuild. If the hiss stays with 0.83.1, the report format
  and scale are ruled out as the cause (hypotheses 2 and 5).
- **No profile change helps.** The profile's `events: include/exclude` only
  filters *input* events. FF uploads go to every source device regardless
  [source].

### 6b. Kernel side: magnitude scaling (patch 0014)

[`patches/kernel/0014-hid-asus-ally-scale-rumble-and-vibration-intensity-to-0-100.patch`](../patches/kernel/0014-hid-asus-ally-scale-rumble-and-vibration-intensity-to-0-100.patch)

- `ally_x_play_effect()`: replace `/ 512` with
  `DIV_ROUND_CLOSEST(m * 100, 0xffff)` (0xffff → 100, 0x8000 → 50).
- `gamepad_vibration_intensity_store()`: accept 0..100 instead of 0..64.

It applies with `git apply --check` on 7.2.7-valve2 plus 0010-0013. **It has
not been built or tested.** It sits in `drafts/` so the build does not pick
it up (`modules-hid.list` does not list it, and the tests only look at
`patches/kernel/*.patch`). To ship it:

1. Move it to `patches/kernel/`.
2. Add it to `modules-hid.list`.
3. Raise the patch count in `tests/patches/kernel-hid-patches.bats` from four
   to five.

Expected effect: 100 % becomes the strongest level. If hypothesis 2 is right,
it also gets *much* stronger than today's 100 %, so the owner should re-run
the evdev test after it. Stronger motors may then reproduce the hiss through
the kernel path too.

### 6c. Device test: `vm/guest/hid-rumble-raw.py`

Stdlib Python, run as root. It writes the 0x0d report straight to the N-KEY
hidraw node, bypassing the kernel FF code and InputPlumber, and prints every
report it sends. On exit, Ctrl-C included, it sends the all-off report on
both transports.

| command | what it does |
|---|---|
| `list` | N-KEY hidraw nodes with interface number, driver and USB address. Lists every FF-capable input node of `0b05:1b4c`: more than one means InputPlumber uploads to more than one, which is worth knowing. Shows the current `gamepad_vibration_intensity` |
| `send --strong N --weak N [--lt N --rt N] [--enable 0x0f] [--transport output\|feature] [--rate HZ --jitter N] [--raw "…"]` | one report, or one re-sent at a rate with random magnitude changes, like a game |
| `sweep --values 50 90 100 101 110 127` | strength steps, including out-of-range values |
| `matrix` | guided run of steps A-I below. Asks for strength (0-5) and hiss (y/n) after each and prints a summary |
| `intensity L R` | sets the MCU vibration intensity (0..100) directly |
| `usbmon [--seconds N]` | prints every 0x0d report on the USB bus with time deltas and the average rate. Run it while a game rumbles to see exactly what the MCU receives |
| `off` | all-off report |

Matrix steps:

| step | transport | bytes | rate | tests |
|---|---|---|---|---|
| A | feature | `0d 0f 00 00 7f 7f ff 00 eb` | once | what the kernel sends today at 100 % |
| B | feature | `0d 0f 00 00 64 64 ff 00 eb` | once | the kernel after 0014 |
| C | output | `0d 0f 00 00 64 64 ff 00 eb` | once | InputPlumber 0.83 / hhd transport |
| D | output | `0d 03 00 00 64 64 ff 00 eb` | once | trigger actuators disabled |
| E | output | `0d 0f 64 64 00 00 ff 00 eb` | once | trigger motors only |
| F | feature | `0d 0f 00 00 64 64 ff 00 eb` | 60 Hz | effect restarted every frame |
| G | feature | `0d 0f 00 00 46 46 ff 00 eb` ±30 | 250 Hz | game-like varying magnitude |
| H | output | same as G | 250 Hz | same, output transport |
| I | feature | `0d 0f 00 00 6e 6e ff 00 eb` | once | out of range (110) |

## 7. Procedure for the owner

Close the game. InputPlumber can keep running.

1. **Inventory**:
   `sudo python3 vm/guest/hid-rumble-raw.py list`.
   Expect interface 2 and interface 5 nodes, and one FF node ("ASUS ROG Ally
   X Gamepad").
2. **Scale**:
   `sudo python3 vm/guest/hid-rumble-raw.py sweep --transport feature`.
   If 101-127 feel weaker than 100, the firmware wraps or rejects
   out-of-range values, which confirms the scaling bug's effect.
3. **Hiss matrix**, with speakers muted (ALSA switches off, as before):
   `sudo python3 vm/guest/hid-rumble-raw.py matrix`.
   - If **only F/G/H** hiss: the update rate is the trigger (hypothesis 1).
   - If **A or I** hiss: out-of-range values are involved (hypothesis 2).
   - If **E** hisses: the trigger motors are involved (hypothesis 4).
   - If **nothing** hisses: see step 4.
4. **What the game really sends**:
   `sudo modprobe usbmon; sudo python3 vm/guest/hid-rumble-raw.py usbmon`,
   then play RE2 until it hisses. Note the rate (reports/s) and values. Feed
   them back into `send --rate R --strong S --weak W --transport feature`.
   For InputPlumber's side, add a drop-in with `Environment=LOG_LEVEL=debug`
   to `inputplumber.service`, restart it, and follow
   `journalctl -u inputplumber -f | grep -iE 'effect|rumble|haptic'`. Check
   the active target with `busctl tree org.shadowblip.InputPlumber`: a
   `deck` target means hypothesis 3 is in play.
5. **Amp path**: while a hissing pattern plays, suspend the speaker sink so
   the amps power down (`pactl list short sinks`, then
   `pactl suspend-sink <speaker sink> 1`, and `0` afterwards). If the hiss
   stops, it enters through the powered amplifier (hypothesis 1, hardware
   coupling). The mitigations would then be fewer or rate-limited rumble
   reports, lower MCU intensity (`intensity 50 50`, what hhd uses on the
   Ally X), or keeping the amps suspended while silent.
6. **Optional**: the fallback build test from §6a.

Please record the results in [hardware-data.md](hardware-data.md).

## Sources

- InputPlumber, `https://github.com/ShadowBlip/InputPlumber`:
  - `v0.78.0` = `082f67fba6aaff88441abdc482ae76b711ad2885`:
    `src/drivers/rog_ally/driver.rs`, `src/input/source/hidraw/rog_ally.rs`,
    `src/input/source/evdev/gamepad.rs` (`write_event`, `upload_effect`,
    `process_haptic_ff`), `src/input/composite_device/mod.rs`
    (`process_output_event`), `src/input/target/xpad.rs`.
  - `v0.83.1` = `b2fb40900506d329925d5a3f1bca54adf85f1279`:
    `src/drivers/rog_ally/{mod,driver,hid_report,event}.rs`,
    `src/input/source/hidraw/rog_ally.rs`,
    `src/input/source/evdev/gamepad.rs` (`get_output_capabilities`),
    `rootfs/usr/share/inputplumber/devices/50-rog_xbox_ally_x20.yaml`.
  - Commit `dbcd6c06918037f3ad406fb6e9aded4c194f7e58`, "feat: Add trigger
    haptics for the ROG Ally / Xbox Ally X" (first in 0.83.0). Its message
    says the layout was "verified against the vendor HID specification,
    usbmon captures, and the kernel hid-asus-ally driver".
  - PR #756 / `9b717089dadd6b2e922df0326016c815b664aa62`: the X20 profile.
    It has no rumble-specific content.
- hhd, `https://github.com/hhd-dev/hhd` @ `eca609b0f54a28ded7cae9a6b365a6b0fa232bd0`:
  `src/hhd/device/rog_ally/{__init__,base,const}.py` (`AllyXHidraw.consume`,
  `LIMIT_DEFAULTS`, `COMMIT_RESET`).
- Valve kernel, `https://github.com/evlaV/linux-integration` tag
  `7.2.7-valve2` = `31504582a07316ae0e8a8fb3b8fdc39d94842816`:
  - `drivers/hid/hid-asus-ally.c` (`struct ff_report`, `ally_x_play_effect`,
    `ally_x_work`, `ally_x_create`, `FORCE_FEEDBACK_OFF`, `ally_hid_init`,
    `_gamepad_apply_intensity`, `gamepad_vibration_intensity_store`,
    `_gamepad_apply_all`) and `hid-asus-ally.h` (`xpad_cmd_*`).
  - Commit `142c7546b8dd` "hid-asus-ally: Separate trigger rumble from main
    rumble".
  - `drivers/hid/hid-microsoft.c` (`struct xb1s_ff_report`,
    `ms_play_effect`).
  - Patches 0010-0013 do not touch the rumble code.
- kndclark/ally_module, `https://github.com/kndclark/ally_module` @
  `3422a5db9927150bfb5f1783456bbed5742ab896`: `hid-asus.c`
  (`ALLY_FF_MAX_INTENSITY`, `ally_x_play_effect`,
  `ally_set_vibration_intensity`).
- Web searches on 2026-10-31 for X20 / Ally X rumble, haptics and speaker
  noise found only ASUS forum threads about buzzing motors on the Ally X,
  for example `https://rog-forum.asus.com/t5/handheld-gaming/vibration-issue-sounding-like-a-bee/m-p/1036553`.

## 7. Measured on the X20 (2026-10-31): root cause confirmed

Raw reports written to the gamepad hidraw node with the speakers audible:

| report | result |
|---|---|
| `0d 0f 00 00 7f 00 ff 00 eb` (strong 127) | no noise |
| `0d 0f 00 00 00 64 ff 00 eb` (weak 100) | no noise |
| `0d 0f 00 00 00 7f ff 00 eb` (weak 127) | **white noise from the speakers** |

An out-of-range weak-motor magnitude (above the MCU's 0..100) makes the MCU
emit noise through the speaker amps; in-range values are silent. The stock
kernel path scales to 0..127, so every game that uses the weak motor above
about 80 % triggers it. Patch 0014 (0..100 scaling) is therefore promoted
from `drafts/` into the build. The earlier `rumble-test.py` never reproduced
the noise because it packed `struct ff_effect` with the union at offset 14
instead of 16, so the kernel only ever saw a strong-motor value.
