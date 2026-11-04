# Capturing the Xbox button light command on Windows

**Done (2026-11-04).** A community member ran the script below with Armoury
Crate 3.1.5 on BIOS `RC74XA.303` and performed off, on, off, on, minimum,
maximum, breathe
([issue #47](https://github.com/cchulo/ally-x20-steamos/issues/47), thank you). Only the first pcap had the controller (`0B05:1B4C`); the
others were a dock. The frames that lined up with each action:

| Time | Action | Bytes (64-byte report, rest zero) | Transport |
|---|---|---|---|
| 6.0 s, 18.1 s | off | `5a d1 09 01 0f` | `SET_REPORT` feature, interface 2 |
| 10.5 s, 21.9 s | on | `5a d1 09 01 1f` | same |
| 27.5 s | minimum | `5d d1 20 01 02`, `01`, `00` (slider dragged down) | interrupt OUT `0x04` |
| 32.3 s | maximum | `5d d1 20 01 01`, `02`, `03` | same |
| 36.6 s | breathe | `5a d1 21 02 01 08`, then `5d d1 20 01 03` | feature, then interrupt OUT |
| 41.3 s | steady | `5a d1 21 02 00 08`, then `5d d1 20 01 03` | same |

Each on/off was followed by Armoury re-sending the ring colour
(`5a b3 00 00 ff 78`, `5a b4`, `5a b5`). The commands are implemented in
`ally-x20-steamos xbox-led` ([rgb.md](rgb.md#xbox-button-light)) and were
confirmed on an X20 the same day: all three work and the rings keep their
colour. The rest of this page is the procedure, kept for reference.

## Background

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
`0B05:1B4C` device that line up with each action and diff the bytes between
the actions. USBPcap files are plain pcap with link type 249; without
Wireshark, a 40-line Python parser (27-byte USBPcap header, then the setup
packet or payload) is enough to list them.
