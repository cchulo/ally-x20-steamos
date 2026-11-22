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
versions or kernels may behave differently. Only the SteamOS **stable**
channel is supported. It ships patched kernel modules and an ACPI table
override, so read what you run and use it at your own risk.

## What it fixes

| On stock SteamOS | With ally-x20-steamos |
|---|---|
| The speakers are silent ("Dummy Output" or HDMI only). | Both speakers play. Steam's audio output list shows one entry for them, **Speakers (Surround - SADIE D2 Dry)** (plus HDMI or Bluetooth when connected). |
| The Armoury Crate button (top left) and the action button (top right) do nothing. | The **action button** opens Steam's **Quick Access** menu, like the right-hand button of a Steam Deck. **Armoury Crate** is a second **Steam button**, like the Xbox button. A **screenshot** is Xbox button + R1. (Up to v0.1.11 Armoury Crate opened Quick Access and the action button took a screenshot; [you can switch back](#changing-what-the-top-buttons-do).) |
| Rumble at 100 % feels weak, and strong rumble makes the speakers hiss. | Rumble uses its full range, and the static from the speakers during strong rumble is gone. |
| The joystick-ring lights cannot be changed from Steam. | **Settings → Customization** in Game Mode shows the joystick-ring lighting (colour and brightness). |
| The Xbox button light is dark. | `sudo ./ally-x20-steamos.sh xbox-led on` lights it (green, as on Windows); `brightness 0-3` and `breathe on\|off` adjust it. All of it is kept across reboots. There is no Steam menu for it. |
| Game Mode does not detect HDR on the OLED screen and only offers 60 and 120 Hz. | **HDR** is available in Game Mode, and the refresh rate can be set anywhere from 30 to 120 Hz. |
| Steam's **Performance** tab has no power profile switch. | **Low power**, **Balanced** and **Performance** profiles are there (about 12, 16-21 and 25-30 W for the processor on battery). Balanced is the default. |
| The battery stops charging at 80 % although Steam shows no charge limit. | The battery charges to 100 %, or to the charge limit you set in Steam (Settings → Power), and that limit is kept across reboots. |
| Games only send stereo to the built-in headphone jack and speakers. | Games can send 7.1 and you hear it as virtual surround, on headphones in the jack and on the speakers. It is on after the install; [Sound](#sound-virtual-surround) shows how to pick another profile, use your own (for example Dolby Atmos for Headphones), or go back to plain stereo. |
| An SD Express card in the slot never shows up, and Steam's **Format** button fails on it. | The card mounts at `/run/media/deck/<label>` when inserted, like a microSD card, and can be added in Settings → Storage. Format it with `sudo ./ally-x20-steamos.sh sdexpress format` (Steam's button still fails for this slot: it runs a stock script that rejects NVMe devices). |
| Steam's controller screens show a generic handheld outline. | They show the Xbox Ally X, which has the same shell, screen and controls. |

## What it does not do yet

- **No TDP slider.** On BIOS `RC74XA.303` the firmware ignores every power
  limit it is sent, so a slider would move and change nothing. Use the
  three power profiles instead. Details, and how to re-test after a BIOS
  update: [power.md](power.md).
- **The Xbox button light has no menu.** It is switched from the command
  line only ([rgb.md](rgb.md#xbox-button-light)).
- **HDR in Desktop Mode** needs an extra build step that the installer does
  not run for you ([hdr.md](hdr.md)). Game Mode HDR works without it.
- **Bluetooth and USB headsets** are left as SteamOS sets them up: their
  volume levels and sound are not changed.
- **Manual GPU clock** in the Performance tab fails on this processor.
  Everything else in that tab works.
- **Surviving SteamOS updates** is built in and covered by automated tests,
  but it has not yet been through many real SteamOS updates. If something
  stops working after an update, see [Troubleshooting](#troubleshooting).
- **Virtual surround is new.** On the device so far: the speakers with the
  default profile and with the owner's own file, the volume range, and the
  profile commands. Not tried on the device yet: headphones through this
  component (the profiles were chosen in listening tests on headphones with
  a separate test tool), plugging headphones in and out, sleep, and whether
  Steam's list really drops the plain "Speakers" entry.
- Some details are still unconfirmed on the hardware, for example the
  long-press actions of the two extra buttons and the motion sensor axes.
  The button layout that came after v0.1.11 (action button = Quick Access,
  Armoury Crate = Steam button) was worked out from InputPlumber's source
  and has not been tried on a device yet.
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
- Two factory-reset fail-safes: a small clean-up script next to the boot
  entry, `/efi/EFI/steamos/ally-x20-steamos-cleanup.sh`, which puts the
  boot entry back to stock and removes the ACPI image, and a shutdown hook,
  `ally-x20-steamos-reset-cleanup.service`, which runs it on both slots when
  a factory reset is about to happen (see
  [Uninstall](#uninstall)).

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
  Audio) should show **Speakers (Surround - SADIE D2 Dry)** as the default,
  and the volume keys should reach full volume.
- **Battery:** on the charger above 80 %, it keeps charging.
- **Buttons:** press the action button (top right): Quick Access opens.
  Press Armoury Crate (top left) or the Xbox button: the Steam menu opens.
  Hold the Xbox button and press R1: a screenshot is taken.
- **Lights:** Settings → Customization has the joystick-ring lighting.
- **Power:** Quick Access → Performance (the battery icon) has the power
  profile switch (Low power, Balanced, Performance) and no TDP slider.
- **HDR:** Settings → Display offers HDR.

### Changing what the top buttons do

There are two layouts for the two buttons at the top of the screen:

| Layout | Action button (top right) | Armoury Crate (top left) | Screenshot |
|---|---|---|---|
| `deck` (default) | Quick Access menu | Steam button | Xbox button + R1 |
| `legacy` (versions up to v0.1.11) | screenshot | Quick Access menu | action button |

The Xbox button is the Steam button in both. To switch:

```sh
sudo ./ally-x20-steamos.sh buttons layout legacy   # or: deck
./ally-x20-steamos.sh buttons status               # shows the layout in use
```

The controller stops for a moment while the change is applied. The choice
is kept across reboots and updates. Armoury Crate is planned to open a
settings screen of this project in a later version; until then it is a
second Steam button, and because the controller only reports it when it is
released, use the Xbox button for Steam chords such as the screenshot.

## Everyday settings

Run these from the installed copy (`cd /var/lib/ally-x20-steamos/src`).
Commands with `sudo` ask for your password; the `surround` commands run
without it.

### Sound: virtual surround

After the install, sound from the built-in speakers and from headphones in
the jack goes through a virtual surround output. Steam's audio output list
shows it under a name like **Speakers (Surround - SADIE D2 Dry)**, and the
plain "Speakers" entry is gone. Leave Steam's output on **Default**: it
then follows you when you plug headphones in or out.

A game decides between stereo and 7.1 when it starts, so restart a game
after you change from stereo to surround or back.

| I want to | Command |
|---|---|
| see what is in use | `./ally-x20-steamos.sh surround status` |
| see the profiles | `./ally-x20-steamos.sh surround list` |
| pick a profile for the speakers | `./ally-x20-steamos.sh surround set speakers hutubs-pp1-dry` |
| pick a profile for headphones | `./ally-x20-steamos.sh surround set headphones mit-kemar-dry` |
| plain stereo on the speakers | `./ally-x20-steamos.sh surround set speakers stereo` (shows as **Speakers (Stereo)**) |
| go back to the default | `./ally-x20-steamos.sh surround set speakers sadie-d2-dry` |

Each output keeps its own profile, and a change takes effect within a few
seconds while a game is running.

**Which profile?** A profile is a recording of how sound reaches the two
ears of one head, so the one closest to your ears works best: try them.
Each comes as `-dry` and `-full`. **`-dry` is recommended** and is the
default on both outputs: music and other stereo sound stay as they are, and
only what is meant to be beside or behind you is processed. `-full`
processes everything; it places sounds more sharply on headphones, changes
the tone of everything, and on the speakers it makes the front sound
quieter.

**The speakers have one more setting.** From two speakers each ear also
hears the other speaker, which weakens the effect. A correction for that is
on by default (delay 60, strength 50):

```sh
./ally-x20-steamos.sh surround xtc 80 50     # another setting: delay, strength
./ally-x20-steamos.sh surround xtc off       # no correction
./ally-x20-steamos.sh surround xtc 60 50     # the default
./ally-x20-steamos.sh surround prepare       # list the tested settings for your profile
```

**Volume** works as before: the volume keys and Steam's slider go from
silent to full.

**If you want the plain outputs back in Steam's list:**
`./ally-x20-steamos.sh surround plain shown` (and `plain hidden` to undo).
Steam may need a restart before it lists them again.

#### Your own profile, for example Dolby Atmos for Headphones

Any HeSuVi impulse response file works: a `.wav` with 14 channels at
48 kHz. Such files are not included because they are not ours to pass on.
The owner's Atmos file came from the HRIR collection at
<https://airtable.com/appayGNkn3nSuXkaz/shruimhjdSakUPg2m/tbloLjoZKWJDnLtTc>.

1. Copy the file to the device, into
   `~/.config/ally-x20-steamos/surround-user/`. From another computer:

   ```sh
   ssh deck@<device> 'mkdir -p ~/.config/ally-x20-steamos/surround-user'
   scp atmos.wav deck@<device>:.config/ally-x20-steamos/surround-user/
   ```

   Keep one `.wav` in that folder. With several, the first in alphabetical
   order is used.
2. Select it for both outputs:

   ```sh
   ./ally-x20-steamos.sh surround set headphones user
   ./ally-x20-steamos.sh surround set speakers user
   ```

3. Prepare the speaker versions (about half a minute for a long file; the
   headphones need nothing):

   ```sh
   ./ally-x20-steamos.sh surround prepare
   ```

4. Check: `./ally-x20-steamos.sh surround status` shows `user` with your
   file's name, and Steam's list shows **Speakers (Surround - User)**. If it
   says `user -> sadie-d2-dry`, the note under it says what is wrong with
   the file.

More, including how it works: [surround.md](surround.md).

### Power and battery

**Power profiles.** Quick Access → Performance has **Low power**,
**Balanced** and **Performance** (about 12, 16-21 and 25-30 W for the
processor on battery). There is no TDP slider, on purpose: this BIOS
ignores it.

**Charging to 100 %.** Stock SteamOS on this device stops charging at about
80 % even with no charge limit set. With ally-x20-steamos the battery
charges to 100 %.

**A charge limit of your own.** Set it in Steam (Settings → Power). It is
respected and kept across reboots. Turning it off there goes back to
100 %.

```sh
sudo ./ally-x20-steamos.sh charge-limit status   # what is in force
sudo ./ally-x20-steamos.sh charge-limit 80       # last resort: a limit without Steam
sudo ./ally-x20-steamos.sh charge-limit follow   # back to the default
```

Once the battery has been full, the device itself may stop charging between
90 % and 100 % and resume later. That is its own battery protection and is
expected.

**Use the 65 W charger that came with the device.** With a charger that is
too weak, or a cable that does not carry the power, the device beeps and
rumbles every few seconds, because the connection keeps dropping and Steam
plays its charger sound each time.

More: [power.md](power.md).

### Buttons and the Xbox light

- The two top buttons: [Changing what the top buttons do](#changing-what-the-top-buttons-do).
- The Xbox button light: `sudo ./ally-x20-steamos.sh xbox-led on` (or
  `off`), `xbox-led brightness 0-3`, `xbox-led breathe on|off`. It is kept
  across reboots and sleep.

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

**If you factory-reset without uninstalling.** A factory reset wipes the
project's files but not the boot partitions, so the boot entry change and
the ACPI image would stay behind (harmless: stock drivers load, the speakers
stay silent). A reset started from Steam normally takes care of this by
itself: the shutdown hook restores both slots just before the reboot. If
anything is left afterwards, run:

```sh
sudo sh /efi/EFI/steamos/ally-x20-steamos-cleanup.sh
```

It restores the original boot entry, deletes the ACPI image and then itself;
add `--all-slots` to clean the other SteamOS slot as well, or `--dry-run` to
only see what it would do.

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

**No sound, or the sound is wrong, and you want plain SteamOS audio back
right now.** Stop the surround service; the plain speakers and headphones
take over at once:

```sh
systemctl --user stop ally-x20-steamos-surround.service
```

It starts again at the next login. To keep surround off, choose stereo for
both outputs (`surround set speakers stereo`, `surround set headphones
stereo`). If Steam's output list is empty or missing "Speakers" afterwards,
restart the audio services:
`systemctl --user restart pipewire pipewire-pulse wireplumber`.

**The battery stops at 80 %.** Run
`sudo ./ally-x20-steamos.sh charge-limit status`. `in_force` should be
100 %, or the limit you set in Steam. If it says about 80 %, run
`sudo ./ally-x20-steamos.sh apply --only chargelimit`.

**The device beeps and rumbles every few seconds on the charger.** The
charger or cable is too weak; see [Power and battery](#power-and-battery).

**Power profiles missing in the Performance tab.** Run
`sudo ./ally-x20-steamos.sh power status`, then restart Steam or reboot
([power.md](power.md) has more checks).

**Leftovers after a factory reset.** If you reset without uninstalling and
the shutdown hook did not run (for example the reset was started outside
Steam), run `sudo sh /efi/EFI/steamos/ally-x20-steamos-cleanup.sh`
(details under [Uninstall](#uninstall)).

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
