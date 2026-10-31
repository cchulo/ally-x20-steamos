# Joystick ring RGB

## What the fix does

Stock SteamOS registers the X20's joystick rings as
`/sys/class/leds/ally:rgb:joystick_rings`. The Steam client does not know that
name, and the LED's colour layout does not match what Steam writes, so
**Settings → Customization** has no RGB controls. ally-x20-steamos rebuilds
`hid-asus-ally` with three patches (`patches/kernel/0010`–`0012`, see
[`patches/kernel/README-hid.md`](../patches/kernel/README-hid.md)):

1. The rings are registered as `go_s:rgb:joystick_rings` (a name Steam knows),
   with a standard red/green/blue colour layout.
2. New sysfs attributes select the ring's built-in effects (breathe, strobe,
   colour cycle, rainbow), their speed and direction, and turn the rings
   on or off.
3. The X20 Quick Access button works. This patch is not RGB-related but
   ships in the same module.

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

## Turning it off

To keep the old LED name, so that tools hardcoding `ally:rgb:joystick_rings`
keep working (Steam then loses the controls again), add a modprobe option:

```
options hid-asus-ally steam_led_name=0
```

Uninstalling ally-x20-steamos restores the stock module.

## Not verified yet

These patches have not been run on an X20 (`TODO(hw)`): whether the X20 has
an LED besides the rings (for example on the Xbox button), whether Steam
writes the effect attributes, and which attributes Valve's udev rule makes
writable for `deck`. See [`hardware-data.md`](hardware-data.md).
