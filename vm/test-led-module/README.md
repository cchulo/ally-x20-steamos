# ax20_test_led — VM-only fake joystick-ring LED

GPL-2.0-only. Plan §6 check 6.

Steam only discovers joystick-ring RGB through hard-coded LED class names
(`go:rgb:joystick_rings`, `go_s:rgb:joystick_rings`, `valve-leds`). A tmpfs
or bind mount cannot add an entry to `/sys/class/leds`, so the VM test uses
this tiny module instead. It registers `go_s:rgb:joystick_rings` through
`led-class-multicolor` with three subleds (red, green, blue), the same shape
our patched `hid-asus-ally` exposes, and logs every write to `dmesg`.

## Build

The module must be built against the exact kernel the VM runs. SteamOS has
no headers on the read-only root, so build in the module build container
(`build/Containerfile`, see the build package) or any box with the matching
`linux-neptune` headers:

```sh
make -C vm/test-led-module KDIR=/path/to/linux-<kver>/build
```

Never commit the `.ko` (`.gitignore` and `tests/policy` enforce this).

## Use in the VM

```sh
vm/fake-leds.sh load --ko ax20_test_led.ko   # insmod + check /sys/class/leds/go_s:rgb:joystick_rings
# Steam -> Settings -> Controller: the "Customization" / LED section should appear.
journalctl -k | grep ax20_test_led          # writes from Steam show up here
vm/fake-leds.sh unload
```

TODO(vm): confirm which file Steam probes first (`multi_index`,
`multi_intensity`, `brightness`) and whether it also requires a parent
HID device; if it does, this module needs a fake parent.
