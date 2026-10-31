# Joystick ring RGB

## What the fix does

Stock SteamOS registers the X20's joystick rings as
`/sys/class/leds/ally:rgb:joystick_rings`. The Steam client does not know that
name, and the LED's colour layout does not match what Steam writes, so
**Settings → Customization** has no RGB controls. ally-x20-steamos rebuilds
`hid-asus-ally` with five patches (`patches/kernel/0010`–`0014`, see
[`patches/kernel/README-hid.md`](../patches/kernel/README-hid.md)):

1. The rings are registered as `go_s:rgb:joystick_rings` (a name Steam knows),
   with a standard red/green/blue colour layout.
2. New sysfs attributes select the ring's built-in effects (breathe, strobe,
   colour cycle, rainbow), their speed and direction, and turn the rings
   on or off.
3. The X20's top-right (capture) button, vendor code `0xa0`, reports
   `KEY_PROG2`. InputPlumber maps it to Steam's screenshot
   ([`docs/inputplumber.md`](inputplumber.md) §6). This patch is not
   RGB-related but ships in the same module.
4. Unloading or reloading the module no longer uses freed memory. This
   patch is not RGB-related either.

The patched module only loads on the exact kernel it was built for. On any
other kernel the stock driver loads and the rings fall back to stock
behaviour (no Steam controls).

## How to verify

```sh
ls /sys/class/leds/
# expected: go_s:rgb:joystick_rings   (stock: ally:rgb:joystick_rings)

cat /sys/class/leds/go_s:rgb:joystick_rings/multi_index
# expected: red green blue            (stock: rgb rgb rgb rgb)

modinfo -F parm hid-asus-ally | grep steam_led_name
```

Then in Game Mode open **Settings → Customization**. A joystick-lighting
section should appear, and changing its colour or brightness should change
the rings.

## Using the effect attributes

Run as root, or as `deck` if Valve's udev rule covers the attribute:

```sh
L=/sys/class/leds/go_s:rgb:joystick_rings
cat $L/effect_index                 # monocolor breathe chroma rainbow strobe
echo 255 0 64 > $L/multi_intensity  # colour (R G B, 0-255 each)
echo 200 > $L/brightness            # 0-255
echo breathe > $L/effect            # or monocolor / chroma / rainbow / strobe
echo 80 > $L/speed                  # 0-100 (slow 0-33, normal 34-66, fast 67-100)
echo reverse > $L/direction         # forward / reverse (chroma, rainbow)
echo false > $L/enabled             # rings off, settings kept; "true" to restore
```

`chroma` and `rainbow` ignore `multi_intensity`. For animated effects,
brightness has four hardware steps. The selected effect is kept across
suspend.

## Solid colour: if one ring goes dark

If Effect = Solid in Steam lights both rings and the right one then goes
dark, the module is an older build that mixed two report types for Solid.
Current builds send Solid as the ring MCU's own static effect, and keep the
old strategies available for testing through the `rgb_static_mode` module
parameter (`0` default, `1` per-zone Aura, `2` per-zone LED report only,
`3` old behaviour). Find the mode that keeps both rings lit with:

```sh
sudo vm/guest/test-rgb-solid.sh            # tries modes 0 1 2 3, 3 s per step
echo 1 | sudo tee /sys/module/hid_asus_ally/parameters/rgb_static_mode  # switch by hand
```

To make a mode stick, add `options hid-asus-ally rgb_static_mode=N` to a
modprobe.d file. The details are in
[`README-hid.md`](../patches/kernel/README-hid.md#solid-dropout).

## Xbox button light

The Xbox button's green light is dark on Linux, and no driver exposes it. No
public source documents the command for it yet. `vm/guest/xbox-led.sh`
(`on`, `off`, `brightness <0-100>`, `color R G B`) uses an LED class device
if one ever appears. Otherwise it sends an experimental probe that treats
the button as one more Aura zone (`--zone 5` by default; try 5–8). See
[`README-hid.md`](../patches/kernel/README-hid.md#xbox-button-light).

## Turning it off

To keep the old LED name, so that tools hardcoding `ally:rgb:joystick_rings`
keep working (Steam then loses the controls again), add a modprobe option:

```
options hid-asus-ally steam_led_name=0
```

Uninstalling ally-x20-steamos restores the stock module.

## Not verified yet

Steam's Customization page drives the rings on an X20 with these patches.
Still open (`TODO(hw)`): which `rgb_static_mode` keeps both rings lit on
Solid (the default is the most likely one), how the Xbox-button light is
controlled, and which attributes Valve's udev rule makes writable for
`deck`. See [`hardware-data.md`](hardware-data.md).
