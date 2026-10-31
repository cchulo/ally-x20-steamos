# hid-asus-ally patches (0010–0013)

Four patches to Valve's `hid-asus-ally` driver. Together they make the ROG
Xbox Ally X20 joystick-ring RGB show up in Steam's Customization menu, expose
the MCU's Aura effects through sysfs, make the X20 top-right (capture) button
report a key, and fix use-after-free bugs when the driver's two interfaces
unbind. They all produce one rebuilt module, `hid-asus-ally.ko`
(see [`modules-hid.list`](modules-hid.list)).

## Source tree: Valve's, not linux-stable

`drivers/hid/hid-asus-ally.c` **is not in mainline or linux-stable**. In
`v7.2.7` the Ally support is limited to the N-KEY quirks in `hid-asus.c`, and
nothing there registers a joystick-ring LED. The driver comes from Valve's
kernel (Luke Jones' out-of-tree Ally series carried in `linux-integration`).
These patches therefore apply to:

| | |
|---|---|
| Repository | Valve `linux-integration` (public mirror: `https://github.com/evlaV/linux-integration`) |
| Tag | `7.2.7-valve2`, commit `31504582a07316ae0e8a8fb3b8fdc39d94842816` |
| Matches | `uname -r` = `7.2.7-valve2-1-neptune-72-g31504582a073` (the `g…` suffix is this commit) |

`git apply --check` against linux-stable `v7.2.7` fails for all three
patches with `drivers/hid/hid-asus-ally.c: No such file or directory`. The
build for these patches has to fetch Valve's source (the `linux-neptune-*`
source package or the tag above), **not** linux-stable as
X20-STEAMOS-PLAN.md §3 assumes for the audio module. Whoever writes
`build/build-modules.sh` should resolve the kernel source per patch set.

## Module

| | |
|---|---|
| Kconfig | `CONFIG_HID_ASUS_ALLY` (tristate). Depends on `USB_HID`, `LEDS_CLASS`, `LEDS_CLASS_MULTICOLOR`. Selects `POWER_SUPPLY` |
| Makefile | `drivers/hid/Makefile`: `obj-$(CONFIG_HID_ASUS_ALLY) += hid-asus-ally.o` |
| Build | `make -C <valve-src> M=drivers/hid modules` after `make modules_prepare` with the device's `/proc/config.gz`. This also rebuilds the other `drivers/hid` modules. Only `hid-asus-ally.ko` is installed |
| Runtime deps | Imports `validate_mcu_fw_version()` from `hid-asus.ko` (namespace `HID_ASUS`), so `hid-asus` must be loaded first. modprobe handles this through `depends:`. The stock `hid-asus.ko` is reused unchanged: no patch touches `hid-asus.c`, and building it in the same tree with the same `.config` gives the same symbol CRCs. Also imports namespace `ASUS_WMI` |
| Binds | `0b05:1abe` (Ally) and `0b05:1b4c` (Ally X). The X20's N-KEY reportedly enumerates as `0b05:1b4c` too, so no ID is added (TODO(hw)) |

`TODO(hw)`: confirm `zcat /proc/config.gz | grep -E 'HID_ASUS(_ALLY)?='`
shows `=m` for both on the stock X20 kernel.

## 0010 — `hid-asus-ally-alias-LED-to-go_s-and-fix-mc_subled.patch`

**Fixes**
- The Steam client enumerates only `go:rgb:joystick_rings`,
  `go_s:rgb:joystick_rings` and `valve-leds`. The driver registered
  `ally:rgb:joystick_rings`. The LED is now `go_s:rgb:joystick_rings`,
  controlled by the read-only module parameter `steam_led_name` (default `1`).
  `hid-asus-ally.steam_led_name=0` restores the old name.
- The channel layout was 4 × `LED_COLOR_ID_RGB` subleds holding packed
  `0xRRGGBB` values (12 allocated, 4 used). led-class-multicolor clamps each
  `multi_intensity` value to `max_brightness` (255), so only blue could ever
  be set. Steam's three-value write (`R G B`) was rejected with `-EINVAL`.
  Resume also re-applied already-scaled colours as intensities. The patch
  changes this to 3 subleds (red, green, blue, channels 0–2, 0–255), with the
  colour broadcast to the MCU's four ring zones.
- The lock and work item are now initialised before LED registration.

**Why one name and not both:** two class devices for one LED would have
separate `brightness`, `multi_intensity` and triggers that overwrite each
other. The LED core has no alias mechanism. A module parameter keeps the old
path available for tools that hardcode it (HueSync and similar).

**Derived from:** kndclark/ally_module `hid-asus.c`; ValveSoftware/SteamOS
#2371 and #2260; `drivers/hid/hid-lenovo-go-s.c` (reference
`go_s:rgb:joystick_rings` registration).

## 0011 — `hid-asus-ally-add-effect-speed-mode-sysfs.patch`

**Adds** these attributes on the LED: `effect`/`effect_index` (monocolor breathe
chroma rainbow strobe, `static` as an alias), `speed`/`speed_range` (0–100),
`direction`/`direction_index` (forward reverse), `enabled`/`enabled_index`
(false true), and `mode`/`mode_index` (always `custom`, to match the Go S ABI).
The ABI is documented in `Documentation/ABI/testing/sysfs-driver-hid-asus-ally`,
inside the patch.

**How it is wired**
- `monocolor` (Steam's "Solid") is sent as the Aura static effect
  `0x5a 0xb3 00 00 R G B 00 00`, latched with `EC_MODE_LED_SET` (`0x5a 0xb5`).
  `EC_MODE_LED_APPLY` (`0x5a 0xb4`) follows only when the effect changed. The
  colour is scaled by brightness in software, and the hardware level stays at
  Valve's base value. The per-zone `xpad_cmd_set_leds` report is no longer
  sent by default. See [Solid dropout](#solid-dropout) and `rgb_static_mode`.
- Animated effects send `0x5a 0xb3 00 <effect> R G B <speed> <dir>`, then the
  existing `EC_MODE_LED_SET` (`0x5a 0xb5`), then `EC_MODE_LED_APPLY`
  (`0x5a 0xb4`), all through `asus_dev_set_report()`. Brightness maps to the
  0–3 hardware level on report `0x5d 0xba 0xc5 0xc4 <level>`, which is sent
  only when it changes.
- The state persists across suspend and re-probe. On suspend the MCU is left
  running the selected effect.

**Derived from:** kndclark/ally_module `hid-asus.c` (effect report layout,
B3→B5→B4 ordering, speed bytes, brightness mapping); hhd-dev/hhd
`device/rog_ally/hid.py` (solid colour, zone numbering); seerge/g-helper
`app/USB/Aura.cs` (Windows-side solid colour on the Ally); asusctl
`asusd/src/aura_laptop/mod.rs` (meaning of apply); SteamOS #2371; z13ctl
protocol notes (g-helper-derived Aura bytes); hid-lenovo-go-s ABI (attribute
names).

### Solid dropout

**Symptom (X20, Steam → Settings → Customization → Joystick Lights).** With
Effect = Solid, both rings light up, then the right ring goes dark a moment
later. With Breathe or any other animated effect, both rings stay lit and
animate.

**Cause.** The first version of 0011 drove monocolor through two mechanisms.
On an effect change the work item sent the Aura static report (`0xb3` zone
`0x00`), `0xb5` and `0xb4`. On every update it then sent the per-zone
`xpad_cmd_set_leds` report (`0x5a 0xd1 0x08 0x0c` + 4 × RGB). So the last
thing the MCU received for Solid was always `0xd1 0x08`. The animated effects
send only the Aura reports, and they light both rings. The only difference
between the two paths is the trailing `0xd1 0x08` report. On the X20 it leaves
only the left ring lit (TODO(hw): confirm with the test script below).

**Protocol facts and sources**

| Fact | Source |
|---|---|
| Solid colour is `0x5a 0xb3 <zone> 0x00 R G B <speed> <dir>`, with `0x00` for both speed and direction on static | hhd `rgb_command()` (`hid.py`); g-helper `AuraMessage()` |
| Zone `0x00` means "all". hhd's default zone (`main`) is `0x00`, and it addresses ring halves as `0x01` left_left, `0x02` left_right, `0x03` right_left, `0x04` right_right | hhd `rgb_command()`; asusctl `AuraZone` (None=0, Key1–4 = 1–4) |
| asusctl lists the Ally (RC71L/RC72L) with `basic_zones: []`, so one zone-0 report covers the rings | asusctl `rog-aura/data/aura_support.ron` |
| g-helper (Windows) sends `0xb3` zone 0, then `0xb5` set, then `0xb4` apply | g-helper `Aura.ApplyAura()` |
| hhd sends `0xb5` + `0xb4` only on a mode change. Colour updates in the same mode are `0xb3` alone | hhd `process_events()` |
| ally_module sends `0xb3` + `0xb5` on every update. `0xb4` is sent only when its `apply` attribute is written | ally_module `asus_usb_rgb_send_zone_effect()`, `asus_usb_rgb_commit()` |
| asusctl: "Changes won't persist unless apply is set". Its per-key/direct path sends only effect + set | asusctl `aura_laptop/mod.rs` |
| None of hhd, g-helper, ally_module or asusctl sends `0xd1 0x08` for the rings. Only Valve's `hid-asus-ally` does, as its "software mode" | the four sources above; Valve `ally_rgb_do_work()` |

The proposed hypothesis, that zone `0x00` reaches only the first ring, does
not hold. Breathe through zone `0x00` lights both rings on the X20, and every
working client uses zone `0x00` for solid.

**Fix.** Monocolor now goes only through the Aura report:
`0xb3` zone 0, effect 0, with the colour already scaled by brightness, then
`0xb5`. `0xb4` is added only when the effect changed, which avoids an
apply (possibly a flash write) on every brightness-slider step. No
`0xd1 0x08` is sent by default.

**`rgb_static_mode`** (int, `0644`, writable at runtime through
`/sys/module/hid_asus_ally/parameters/rgb_static_mode`, or set with
`options hid-asus-ally rgb_static_mode=N`). It takes effect on the next write
to the LED (`effect`, `multi_intensity` or `brightness`).

| Value | Monocolor sends | Notes |
|---|---|---|
| `0` (default) | `0xb3` zone `0x00`, `0xb5` (+`0xb4` on effect change) | what g-helper, hhd and ally_module do |
| `1` | `0xb3` for zones `0x01`–`0x04`, then `0xb5` (+`0xb4`) | hhd's quad-zone addressing |
| `2` | `0xd1 0x08` per-zone report only | Valve's original software mode. No Aura report, so an animated effect may keep running |
| `3` | Aura on effect change, then `0xd1 0x08` on every update | first-version behaviour, reproduces the bug |

**Device test.** `sudo vm/guest/test-rgb-solid.sh` replays Steam's writes
(breathe → monocolor + colour + brightness, a colour-only change, and the
reverse write order) for modes 0–3, with 3 s between steps. It asks after
each step whether both rings are lit, prints a summary and restores the
previous state. Report the mode(s) with "y" on every step.

## 0012 — `hid-asus-ally-report-X20-top-right-key-0xa0.patch`

**Fixes:** the X20's top-right button (red, labelled for capture; ovenham's
table calls it "Quick Access") sends `5a a0` / `5a 00` on the N-KEY
interface, and the driver only knew `0xa6`.
- `0xa0` reports **`KEY_PROG2`**, one plain key, in both `qam_mode` settings
  and on both the "ASUS ROG Ally X Gamepad" and the "ASUS ROG Ally Config"
  input devices. No other Ally button reports `KEY_PROG2`, so userspace can
  tell it apart from `0xa6` (top-left Armoury Crate: `KEY_F16`, or
  `BTN_MODE` with `qam_mode=1`) and `0x38`/`0x93` (`KEY_PROG1`, or the
  Xbox+A chord with `qam_mode=1`).
- No synthetic chord. InputPlumber sets `qam_mode=0` and owns the mapping:
  our capability map turns `KEY_PROG2` into Steam's screenshot
  (`docs/inputplumber.md` §6).
- The first version of 0012 (PR #4) reported `KEY_F16` for `0xa0`, the same
  key as `0xa6`, and the Xbox+A chord with `qam_mode=1`. Under InputPlumber
  both top buttons then did the same thing (Steam+X), which is what the owner
  saw on 2026-10-31.
- The right place is `hid-asus-ally`, not `hid-asus`. `asus_probe()` returns
  `-ENODEV` for the Ally endpoints `0x83`/`0x87`/`0x04` when
  `CONFIG_HID_ASUS_ALLY` is reachable, so `hid-asus`'s `0xa6` keymap never sees
  these reports.

**Derived from:** ovenham/rog-ally-x20-steamos-speaker-qam-fix (button table:
Armoury Crate top left = `0xa6`, right-side button = `0xa0`;
`tools/x20-buttons.sh`, N-KEY ID `0b05:1b4c`); hhd
`src/hhd/device/rog_ally/base.py` (`0xa0` grouped with the right button
`0x38`/`0x93`); `hid-asus.c` in the same tree.

## 0013 — `hid-asus-ally-fix-use-after-free-on-interface-unbind.patch`

**Field report.** With the PR #20 build loaded, a live
`modprobe -r hid_asus_ally && modprobe hid-asus-ally` while InputPlumber
held the gamepad evdev hard-rebooted the X20. The journal had nothing after
InputPlumber's `event11: No such device`, and pstore was empty. The same
reload had worked twice with the previous build.

**Audit of the 0010/0011 LED paths: nothing conclusive.**
- `ally_rgb_set()` is the LED core's `brightness_set` and may run in atomic
  context. It only takes `led->lock` and schedules work. It never calls
  `asus_dev_set_report()`.
- `ally_rgb_remove()` sets `removed` under the lock, calls
  `cancel_work_sync()`, then unregisters the class device. The `LED_OFF` that
  `led_classdev_unregister()` sends cannot queue work any more. The effect,
  speed, direction and enabled attributes are removed first and queue work
  only through the same guarded helper.
- The `0xb4`-only-on-effect-change logic runs only in the work item.
- The `rgb_static_mode` setter only stores an int.
- PR #20 changed no teardown or probe code; its diff is limited to the work
  function, the send helpers and resume.
- The pattern matches hid-playstation: a flag cleared under the lock,
  `cancel_work_sync()`, and devm LEDs left to devres.

**What was found instead: a Valve bug, present before this series.** These
paths had no defect in 0010/0011, but `ally_hid_remove()` tears down
*every* part (`led_rgb_dev`, `ally_x`, `gamepad_cfg`) on *each* of the two
interfaces. Each part is devm memory of the interface that created it, and
the shared static `drvdata` pointers are never cleared. On rmmod the device
bound last unbinds first. If that is the Ally X interface, `ally_x` is freed
while the configuration interface is still bound. Two things then use freed
memory:
- `ally_raw_event()` dispatches every `0x5a` vendor report to
  `ally_x_raw_event()` in interrupt context.
- The configuration interface's remove calls `ally_x_remove()`
  (`spin_lock`, `cancel_work_sync`) on the freed object.

Whether that crashes depends on reuse of the freed memory, so the result
varies from run to run. A crash in interrupt context leaves no trace in the
journal. This fits the report, but it is not proven to be its cause.

**Fix.**
- `remove()` tears down only its own interface's parts and clears their
  pointers.
- A spinlock serialises `raw_event`'s use of `ally_x`, `gamepad_cfg` and
  `gamepad_cfg->input` against probe and remove.
- probe never publishes an `ERR_PTR`.
- The Ally X probe clears `gamepad_cfg->input` before unregistering it.
- The rumble callback ignores a cleared `ally_x`.

`TODO(hw)`: repeat the live reload ten or more times with InputPlumber
running.

## Xbox button light

The X20's Xbox button glows green on Windows and is dark on Linux. The stock
driver registers no LED for it, and these patches do not add one: no public
source documents the command. hhd (which supports the X20 and the RC73
Xbox Allys), kndclark/ally_module, g-helper, asusctl and InputPlumber
control only the joystick rings. A comment in hhd's X20 path says the X20 has no
dynamic-lighting interface. On the Ally X, hhd disables that interface
(HID application `0x00590001`, the LampArray usage page) after wake. g-helper's Ally power mask
(`0x5a 0xd1 0x09 0x01 <mask>`) has only the ring ("keyboard") bits.
`xpad`'s LED class device covers only Xbox 360 pads.

`vm/guest/xbox-led.sh on|off|brightness <0-100>|color R G B` writes to a
`/sys/class/leds/*xbox_button*` device if a later driver provides one.
Otherwise it sends an experimental probe to the N-KEY hidraw node: the Aura
static report for one zone, `5a b3 <zone> 00 R G B 00 00`, then `5a b5`
(set only, no apply, so nothing is written to MCU flash). The default is
zone 5, the Aura "logo" zone in asusctl and ally_module. Try
`--zone 5`…`8`. Zones 0–4 are the rings.

`TODO(hw)`: run the probe for zones 5–8. If none lights the button, capture
USB traffic on Windows (USBPcap) while Armoury Crate or Game Bar changes the
button light. Once the report is known, add a `go_s:white:xbox_button` (or
`:rgb:`) LED class device behind a module parameter.

## Validation status

| Check | Result |
|---|---|
| `git apply --check` 0010 → 0011 → 0012 → 0013 in sequence on `7.2.7-valve2` | pass |
| `git apply --check` 0012 alone on `7.2.7-valve2` | pass |
| `git apply --check` 0011 without 0010 | fails (expected, depends on 0010) |
| `git apply --check` on linux-stable `v7.2.7` | fails: the file does not exist there (see above) |
| Compiled | by CI (`build-modules.yml`) against `7.2.7-valve2`. The Solid fix was only apply-checked locally |
| Run on hardware | 0010/0011 v1: yes, on an X20. Steam drives the rings, and Solid showed the dropout above. The Solid fix (`rgb_static_mode`) has not been run on hardware yet |

## Hardware TODOs

- `TODO(hw)` `ls /sys/class/leds/`: does the X20 expose only the rings
  (`go_s:rgb:joystick_rings` after the patch), or also a separate Xbox-button
  LED? The driver registers exactly one multicolor LED. A second node would
  need a further patch.
- `TODO(hw)` whether Steam's Customization menu lists and drives the rings
  (colour and brightness), and whether Steam also writes `effect`, `speed`,
  `mode` or `profile`. `profile` is not implemented.
- `TODO(hw)` which attributes Valve's udev rule
  (`/usr/lib/udev/rules.d/70-steam-jupiter-leds.rules`) makes writable for
  `deck`. The new attributes are `0644` (root-writable only) unless the rule
  covers them.
- `TODO(hw)` that `0x5a 0xb3` (not `0x5d 0xb3`, as the old suspend helper
  uses) drives the X20 rings, that the five effect bytes match their names, the
  speed and direction encodings, and whether the 0–3 level is stored in MCU
  flash.
- `TODO(hw)` hidraw capture: the top-right button sends only `5a a0` and the
  top-left Armoury Crate button `5a a6`; `lsusb` shows `0b05:1b4c`; one press
  gives exactly one `KEY_PROG2` press/release on "ASUS ROG Ally X Gamepad".
- `TODO(hw)` the X20's MCU firmware version against `ROG_ALLY_X_MIN_MCU`
  (313) in `hid-asus.c`, which this series does not change.

## 0014: rumble magnitudes 0..100 (in the build since 2026-10-31)

[`0014-hid-asus-ally-scale-rumble-and-vibration-intensity-to-0-100.patch`](0014-hid-asus-ally-scale-rumble-and-vibration-intensity-to-0-100.patch)
scales `FF_RUMBLE` magnitudes to the report's 0..100 range (the driver sends
0..127) and lets `gamepad_vibration_intensity` take 0..100. Measured on the
X20: a weak-motor value of 127 makes the MCU push white noise through the
speaker amps, 100 does not, so the out-of-range scaling was the cause of the
"static during rumble" reports (docs/rumble-analysis.md §7). See
[`docs/rumble-analysis.md`](../../docs/rumble-analysis.md) §6b for why and
for the steps to promote it.

## 0015: hold the X20 top-right key for 250 ms (in the build since 2026-10-31)

[`0015-hid-asus-ally-hold-X20-top-right-key-for-250-ms.patch`](0015-hid-asus-ally-hold-X20-top-right-key-for-250-ms.patch)
keeps `KEY_PROG2` (the capture button, patch 0012) pressed for 250 ms via a
delayed work item and ignores the MCU's own release, which arrives 1 ms after
the press however long the button is held. InputPlumber's Steam Deck target
fakes `Screenshot` as a Guide+R1 chord spread over 160 ms and drops the R1
release when the key goes up before the chord has started; the virtual pad
then holds R1 until the real bumper is pressed, so the Xbox button became
Steam+R1 (a screenshot) after every capture press. Confirmed on the X20 and
in InputPlumber 0.78.0 `steam_deck.rs` (`write_event()` clears queued events
for a button when a press for it fires). See [docs/inputplumber.md](../../docs/inputplumber.md) §6.
