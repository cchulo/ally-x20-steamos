# Capturing the Xbox button light command on Windows

The X20's joystick rings are controllable on Linux (`hid-asus-ally`), but the
Xbox button light stays dark: nothing public documents the MCU command for it
(hhd, asusctl, g-helper and ally_module only know the rings; anatase users
report the same). On the device the gamepad HID interface accepts a single
output report (`0x0d`, rumble), so the light is driven through one of the
vendor reports on the keyboard interface (`0x5a`, `0x5d`, `0x5e`, `0xa5`),
and guessing `0x5d` sub-commands blindly is unsafe (they configure the MCU).

The clean way to find it is a USB capture on Windows while Armoury Crate
changes the light. If you do not have Windows any more, ask a community
member with an X20 to run [`tools/windows/Capture-X20-XboxLed.ps1`](../tools/windows/Capture-X20-XboxLed.ps1):

1. Install USBPcap (https://desowin.org/usbpcap/) or tick "USBPcap" in the
   Wireshark installer; reboot.
2. Open an **administrator** PowerShell, then
   `Set-ExecutionPolicy -Scope Process Bypass` and run the script.
3. Follow the prompts: during the 45-second window turn the Xbox light off,
   on, to minimum and to maximum brightness (and change its colour if the
   option exists), noting the order.
4. Send back the zip it leaves on the Desktop (`x20-xboxled-capture-*.zip`).
   It contains only USB traffic to the controller plus the typed notes.

What we then do with it: find the `SET_REPORT`/interrupt-OUT frames to the
`0B05:1B4C` device that line up with each action, diff the bytes between
"off/on/min/max", and add the command to `hid-asus-ally` as a second LED
class device (`go_s:white:xbox_button` or `:rgb:` if it turns out to be RGB),
exposed through `vm/guest/xbox-led.sh` and, later, Steam's Customization page
if Steam supports a second LED.
