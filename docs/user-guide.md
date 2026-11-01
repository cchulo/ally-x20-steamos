# User guide: ally-x20-steamos on your ROG Xbox Ally X20

This page is for owners of an **ASUS ROG Xbox Ally X20** who run
**SteamOS** and want the things that do not work out of the box to work.
You do not need to be a developer, but you will type a few commands in a
terminal. Developer documentation starts at the [README](../README.md).

## What this is

ally-x20-steamos is a set of scripts that fixes the X20's hardware gaps on
stock SteamOS: it adds files and patched drivers next to SteamOS instead of
replacing it, keeps them working across SteamOS updates, and can remove
everything again. It is not a custom SteamOS image and not a Decky plugin.

**Honest status:** tested on one device only, with BIOS `RC74XA.303`,
SteamOS 3.9.5 and kernel `7.2.7-valve2`. Other BIOS versions, SteamOS
versions or kernels may behave differently. It ships patched kernel modules
and an ACPI table override, so read what you run and use it at your own
risk.

## What it fixes

| On stock SteamOS | With ally-x20-steamos |
|---|---|
| The speakers are silent ("Dummy Output" or HDMI only). | Both speakers play. Steam's audio output list shows just **Speakers** (plus headphones, HDMI or Bluetooth when connected). |
| The Armoury Crate button (top left) and the capture button (top right) do nothing. | **Armoury Crate** opens Steam's **Quick Access** menu. **Capture** takes a **screenshot**. |
| Rumble at 100 % feels weak, and strong rumble makes the speakers hiss. | Rumble uses its full range, and the static from the speakers during strong rumble is gone. |
| The joystick-ring lights cannot be changed from Steam. | **Settings → Customization** in Game Mode shows the joystick-ring lighting (colour and brightness). |
| Game Mode does not detect HDR on the OLED screen and only offers 60 and 120 Hz. | **HDR** is available in Game Mode, and the refresh rate can be set anywhere from 30 to 120 Hz. |
| Steam's **Performance** tab has no power profile switch. | **Low power**, **Balanced** and **Performance** profiles are there (about 12, 16-21 and 25-30 W for the processor on battery). Balanced is the default. |
| Steam's controller screens show a generic handheld outline. | They show the Xbox Ally X, which has the same shell, screen and controls. |

## What it does not do yet

- **No TDP slider.** On BIOS `RC74XA.303` the firmware ignores every power
  limit it is sent, so a slider would move and change nothing. Use the
  three power profiles instead. Details, and how to re-test after a BIOS
  update: [power.md](power.md).
- **The Xbox button light stays dark.** Nobody has found out yet how to
  switch it on from Linux ([rgb.md](rgb.md)).
- **HDR in Desktop Mode** needs an extra build step that the installer does
  not run for you ([hdr.md](hdr.md)). Game Mode HDR works without it.
- **Bluetooth and USB headsets** are left as SteamOS sets them up: their
  volume levels and sound are not changed.
- **Manual GPU clock** in the Performance tab fails on this processor.
  Everything else in that tab works.
- **Surviving SteamOS updates** is built in and covered by automated tests,
  but it has not yet been through many real SteamOS updates. If something
  stops working after an update, see [Troubleshooting](#troubleshooting).
- Some details are still unconfirmed on the hardware, for example the
  long-press actions of the two extra buttons and the motion sensor axes.
  Developers keep the list in [hardware-data.md](hardware-data.md).

## What it changes on your system

- **Nothing under `/usr`.** That is SteamOS's read-only system image. The
  project never turns read-only mode off.
- Its own files go to `/var/lib/ally-x20-steamos` (the downloaded copy of
  this project, built drivers, logs and saved originals) and
  `/etc/ally-x20-steamos` (files needed early at boot: the patched drivers
  for the running kernel, the speaker tuning files).
- Small configuration files with `ally-x20-steamos` or `x20` in their name
  in standard places: `/etc/modprobe.d`, systemd units in `/etc/systemd`,
  the controller profile for InputPlumber, the audio profile, the HDR
  display profile.
- **Patched kernel modules** (speakers, controller and lights, power) are
  loaded through modprobe hooks, and only when they were built for exactly
  the kernel you are running. Otherwise SteamOS's own drivers load, so a new
  kernel never fails to boot because of this project.
- An **ACPI table override** for the speakers, loaded as an early initrd.
  For that, the boot entry of the active SteamOS slot gets one extra line;
  the original is saved first.
- A **bind mount** over steamos-manager's device folder at boot, so Steam
  sees the power profiles. Nothing is written to `/usr`; the mount is gone
  after a reboot without the service.
- A hook in SteamOS's updater (RAUC) so the fixes are carried over to the
  new system after an update. The original updater configuration is saved
  first.

Every file is recorded in a list (the manifest), and **everything can be
removed** again, restoring the saved originals byte for byte (see
[Uninstall](#uninstall)).

## Before you start

- SteamOS's **read-only mode stays on** (the default). Do not run
  `steamos-readonly disable`; the installer refuses to run if you did.
- Set a password for the `deck` user so `sudo` works. In Desktop Mode, open
  Konsole and run `passwd` once. Never share this password with anyone,
  including in a bug report.
- Switch to **Desktop Mode** (Steam button → Power → Switch to Desktop) and
  open **Konsole**, the terminal app.
- Connect to the internet (Wi-Fi is fine). The installer downloads this
  project, the speaker tuning files and, if needed, kernel sources.
- Keep the device on the charger during the install.
- Optional: check your BIOS version with
  `cat /sys/class/dmi/id/bios_version`. It was tested with `RC74XA.303`.

## Install

In Konsole:

```sh
git clone https://github.com/cchulo/ally-x20-steamos.git
cd ally-x20-steamos
git checkout "$(git tag -l 'v*' --sort=-version:refname | head -n1)"   # newest release
sudo ./ally-x20-steamos.sh install
```

The `git checkout` line selects the newest release instead of the
development version. The installer copies the project to
`/var/lib/ally-x20-steamos/src` and runs everything from there; you can
delete the `ally-x20-steamos` folder in your home directory afterwards.

How long it takes:

- **A few minutes** when a prebuilt driver package exists for your kernel.
  Each release on GitHub carries one for the kernels it supports.
- **Roughly 10 to 30 minutes** (more on a slow connection) when there is
  none, for example right after a SteamOS update with a new kernel. The
  device then builds the drivers itself in a container (podman, which
  SteamOS ships). If Valve has not published the build files for that
  kernel, it can take up to an hour.

When it finishes it prints a status table. **Reboot** when it tells you to
(the drivers and the speaker fix take effect on the next boot), then go back
to Game Mode.

More detail, installer options and a one-line install (not recommended):
[install.md](install.md).

## After install: what to check

The commands in the rest of this guide run from the installed copy. Open
Konsole and go there first:

```sh
cd /var/lib/ally-x20-steamos/src
./ally-x20-steamos.sh status
```

The status shows the version, the running kernel and whether patched
drivers are ready for it, then one line per part:

| Status | Meaning |
|---|---|
| `active` | installed and working as installed |
| `stock` | not in place right now (for example after an update); the boot service puts it back |
| `superseded` | SteamOS now has its own fix; you can remove ours (see [Updating](#updating)) |
| `n/a` | cannot be checked on this machine |
| `error` | something went wrong; see [Troubleshooting](#troubleshooting) |

Then, in Game Mode:

- **Speakers:** play a video or a game. Steam's audio output (Settings →
  Audio) should show **Speakers**.
- **Buttons:** press Armoury Crate (top left): Quick Access opens. Press
  capture (top right): a screenshot is taken.
- **Lights:** Settings → Customization has the joystick-ring lighting.
- **Power:** Quick Access → Performance (the battery icon) has the power
  profile switch (Low power, Balanced, Performance) and no TDP slider.
- **HDR:** Settings → Display offers HDR.

## Updating

**SteamOS updates.** Install them as usual. SteamOS updates by writing a
new system to its second slot; ally-x20-steamos hooks into that and carries
its files over. After the reboot you get one notification. If the update
brought a new kernel, the speakers, buttons and lights run on SteamOS's own
drivers for a while: the patched drivers are downloaded or built in the
background, a notification asks for one more reboot, and then everything is
back. By default, an update whose new kernel cannot get patched drivers may
be held back so you do not lose the speakers; Steam then reports that the
update failed, and the notification after the next boot explains how to
let it through. Details: [update-survival.md](update-survival.md).

**When SteamOS catches up.** If a SteamOS update ships its own fix for
something, the status shows that part as `superseded` and you get a
notification. Nothing is removed automatically. To remove our copy:

```sh
cd /var/lib/ally-x20-steamos/src
sudo ./ally-x20-steamos.sh uninstall --superseded
```

**Updating ally-x20-steamos itself.**

```sh
cd /var/lib/ally-x20-steamos/src
sudo ./ally-x20-steamos.sh self-update --check   # is there a new release?
sudo ./ally-x20-steamos.sh self-update           # install it
sudo ./ally-x20-steamos.sh self-update --rollback   # go back if the new one misbehaves
```

`self-update` only installs releases signed with the project's key, and it
refuses to run if you changed files in the installed copy. If it says it
cannot verify a release, install the new release the same way as the first
time instead: clone (or `git pull` in your clone), check out the newest tag,
and run `sudo ./ally-x20-steamos.sh install` again. Re-running `install` is
safe; it moves the installed copy to that release and re-applies.
Details: [self-update.md](self-update.md).

## Uninstall

```sh
cd /var/lib/ally-x20-steamos/src
sudo ./ally-x20-steamos.sh uninstall --dry-run   # show what would happen, change nothing
sudo ./ally-x20-steamos.sh uninstall --reboot    # remove everything, then reboot
```

If the installed copy is broken or deleted, the standalone uninstaller
still works:

```sh
sudo sh /var/lib/ally-x20-steamos/uninstall.sh --yes
```

This removes every file the project added, restores the saved boot entry
and updater configuration byte for byte, drops the bind mount, and deletes
`/var/lib/ally-x20-steamos`. A file you edited yourself is left in place
and reported. After the reboot your X20 is back to stock SteamOS, including
silent speakers. Details: [uninstall.md](uninstall.md).

## Troubleshooting

Start every time with:

```sh
cd /var/lib/ally-x20-steamos/src
./ally-x20-steamos.sh status --verbose
```

**No sound after a SteamOS update.** Most likely the new kernel has no
patched drivers yet. If `modules staged for it` says no, or a rebuild is
pending, fetch or build them now and reboot:

```sh
sudo ./ally-x20-steamos.sh rebuild
sudo reboot
```

If the drivers are there but sound is still missing, re-apply and reboot:

```sh
sudo ./ally-x20-steamos.sh apply
sudo reboot
```

**Joystick-ring lights missing in Customization, or the buttons do the
wrong thing.** These depend on the patched `hid-asus-ally` driver. Check
that the driver hooks are installed and what the loader decided at boot:

```sh
cat /etc/modprobe.d/ally-x20-steamos-modules.conf   # one "install ..." line per patched driver
journalctl -b -t ally-x20-steamos                   # "loaded patched" or why it fell back to stock
ls /sys/class/leds/                                 # go_s:rgb:joystick_rings means the patched driver is loaded
```

If the hooks file is missing, or the log says it fell back to the stock
driver, re-apply the drivers, force a fresh copy for your kernel and
reboot:

```sh
sudo ./ally-x20-steamos.sh apply --only modules
sudo ./ally-x20-steamos.sh rebuild --force
sudo reboot
```

If the buttons are still wrong, re-apply the controller profile too:
`sudo ./ally-x20-steamos.sh apply --only inputplumber`, then reboot.

**Power profiles missing in the Performance tab.** Run
`sudo ./ally-x20-steamos.sh power status`, then restart Steam or reboot
([power.md](power.md) has more checks).

**Collecting information for a bug report.**

```sh
./ally-x20-steamos.sh status --verbose > ~/ax20-status.txt
journalctl -b -t ally-x20-steamos > ~/ax20-journal.txt
journalctl -b -u ally-x20-steamos > ~/ax20-boot-service.txt
journalctl -k -b | grep -iE 'acp|sof|soundwire|tas2783|asus' > ~/ax20-kernel.txt
bash vm/guest/collect-hardware-data.sh --out ~   # optional: a read-only hardware report (tarball)
```

All of these only read; nothing is changed. Look through the files before
you post them.

### Reporting a problem

Open an issue at
<https://github.com/cchulo/ally-x20-steamos/issues> and include:

- what you did, what you expected and what happened;
- your BIOS version (`cat /sys/class/dmi/id/bios_version`), SteamOS
  version (Settings → System) and `uname -r`;
- the output of `status --verbose` and the log files above.

**Never post your sudo password**, and do not paste the output of commands
you do not recognise from this guide.

## Credits

This project builds on the work of many people: Valve's kernel and
steamos-manager developers, the mainline Linux, InputPlumber, hhd and
libdisplay-info authors, and the X20 owners who found and published the
first fixes. The full list with links is in the
[README's Credits section](../README.md#credits).
