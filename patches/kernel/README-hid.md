# hid-asus-ally patches (0010–0012)

Three patches to Valve's `hid-asus-ally` driver. Together they make the ROG
Xbox Ally X20 joystick-ring RGB show up in Steam's Customization menu, expose
the MCU's Aura effects through sysfs, and make the X20 Quick Access button
work. They all produce one rebuilt module, `hid-asus-ally.ko`
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
- `monocolor` keeps the driver's existing per-zone path
  (`xpad_cmd_set_leds`), so behaviour is unchanged until an effect is chosen.
- Animated effects send `0x5a 0xb3 00 <effect> R G B <speed> <dir>`, then the
  existing `EC_MODE_LED_SET` (`0x5a 0xb5`), then `EC_MODE_LED_APPLY`
  (`0x5a 0xb4`), all through `asus_dev_set_report()`. Brightness maps to the
  0–3 hardware level on report `0x5d 0xba 0xc5 0xc4 <level>`, which is sent
  only when it changes.
- The state persists across suspend and re-probe. On suspend the MCU is left
  running the selected effect.

**Derived from:** kndclark/ally_module `hid-asus.c` (effect report layout,
B3→B5→B4 ordering, speed bytes, brightness mapping); SteamOS #2371; z13ctl
protocol notes (g-helper-derived Aura bytes); hid-lenovo-go-s ABI (attribute
names).

## 0012 — `hid-asus-ally-map-X20-quick-access-0xa0.patch`

**Fixes:** the X20 Quick Access button sends `5a a0` / `5a 00` on the N-KEY
interface, and the driver only knew `0xa6`.
- `qam_mode=0`: `0xa0` reports `KEY_F16`, the same key as `0xa6`.
- `qam_mode=1` (the driver default on Ally X class devices): `0xa0` emits
  Steam's Quick Access chord (Xbox+A), the path already used for `0x38`/`0x93`.
  Copying `0xa6` there would give a bare `BTN_MODE`, which the X20's Xbox
  button already sends.
- The right place is `hid-asus-ally`, not `hid-asus`. `asus_probe()` returns
  `-ENODEV` for the Ally endpoints `0x83`/`0x87`/`0x04` when
  `CONFIG_HID_ASUS_ALLY` is reachable, so `hid-asus`'s `0xa6` keymap never sees
  these reports.

**Derived from:** ovenham/rog-ally-x20-steamos-speaker-qam-fix (button table,
`tools/x20-buttons.sh`, N-KEY ID `0b05:1b4c`); `hid-asus.c` in the same tree.

## Validation status

| Check | Result |
|---|---|
| `git apply --check` 0010 → 0011 → 0012 in sequence on `7.2.7-valve2` | pass |
| `git apply --check` 0012 alone on `7.2.7-valve2` | pass |
| `git apply --check` 0011 without 0010 | fails (expected, depends on 0010) |
| `git apply --check` on linux-stable `v7.2.7` | fails: the file does not exist there (see above) |
| Compiled | **no**, apply-check only. No x86 kernel build was available |
| Run on hardware | **no** |

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
- `TODO(hw)` hidraw capture: Quick Access sends only `5a a0`, `lsusb` shows
  `0b05:1b4c`, and with `qam_mode=1` one press opens Steam's Quick Access
  menu exactly once.
- `TODO(hw)` the X20's MCU firmware version against `ROG_ALLY_X_MIN_MCU`
  (313) in `hid-asus.c`, which this series does not change.
