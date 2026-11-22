# SD Express slot

The ROG Xbox Ally X20 has an SD Express slot. On stock SteamOS an inserted
SD Express card shows up as an NVMe disk that nothing mounts, and Steam's
**Format** button fails on it. Component `sdexpress` makes the slot behave
like a microSD slot: the card is automounted by the same stock scripts
SteamOS uses for microSD cards, and `ally-x20-steamos sdexpress format`
formats it the way Steam's button would.

> **Not fully supported.** The SD Express slot has open problems on the X20:
> a card can be missing after a long sleep, cards cannot be swapped reliably
> while the device is on, and a restart has hung. The cause is not known
> yet; it may be the device's firmware, or kernel support for this slot that
> is not there yet. Use the slot knowing that, and keep nothing on the card
> that you cannot download again. Details and progress:
> [issue #89](https://github.com/cchulo/ally-x20-steamos/issues/89).

Measured on one X20 (BIOS `RC74XA.303`, SteamOS 3.7, 2026-11-05) with a
SanDisk SD Express card (`ST51271_WDC SanDisk SD Express SDSQXFN`, 456 GiB).

## What stock SteamOS does, and why the slot is left out

An SD Express card is a PCIe/NVMe device, not an MMC device. Four stock
pieces handle removable storage, and only the first one looks at the device
name:

| stock piece | what it does | device-name check |
|---|---|---|
| a udev rule under `/usr/lib/udev/rules.d` | on `add`/`remove` of a block device with a filesystem, runs `block-device-event.sh` through `systemd-run` | `KERNEL!="mmcblk*\|sd*"` skips everything else, so `nvmeXnYpZ` never reaches the scripts |
| `/usr/lib/hwsupport/block-device-event.sh add <part>` | takes a lock, `udevadm settle`, skips OS partitions (listed in `/efi/SteamOS/partsets/all`), and after boot skips `add` events for media detected more than 5 s ago | none |
| `/usr/lib/hwsupport/holo-automount.sh add <part>` | requires ext4, `fsck.ext4 -y`, mounts through udisks as user `deck` with `noatime,rw` (read-only when fsck fails) at `/run/media/deck/<label>`; `chmod 777` when deck cannot write; a legacy `/run/media/<name>` symlink for `mmcblk0p*` only | none that matters |
| `/usr/lib/hwsupport/format-device.sh` (Steam's **Format** button, via `steamos-format-device` and pkexec) | `dd` the first 512 KiB, `parted` GPT with one partition, `mkfs.ext4 -m 0 -O casefold -E nodiscard,root_owner=1000:1000`, then `holo-automount.sh add` | `case "$STORAGE_DEVICE" in /dev/mmcblk[0-9]) ... /dev/sd[a-z]) ... *) exit 19` before any option is parsed, so `--skip-validation` does not help (verified: exit 19) |

Nothing under `/usr` can be changed, so the component adds one udev rule
under `/etc/udev/rules.d` that feeds the card's partitions to the second and
third pieces unchanged, and replaces the fourth with a CLI command.

## nvmeN is not stable; the PCIe root port is

The kernel numbers NVMe controllers in the order it finds them, and that
order changes between boots on the X20:

| when | card | internal SSD |
|---|---|---|
| card inserted after boot | `/dev/nvme1n1` | `/dev/nvme0n1` |
| reboot with the card present | `/dev/nvme0n1` | `/dev/nvme1n1` |

The sysfs paths show what is stable:

```
card  /devices/pci0000:00/0000:00:02.2/0000:62:00.0/nvme/nvme0/nvme0n1   ID_PATH=pci-0000:62:00.0-nvme-1
SSD   /devices/pci0000:00/0000:00:02.1/0000:61:00.0/nvme/nvme1/nvme1n1   ID_PATH=pci-0000:61:00.0-nvme-1
```

The PCIe root port is a fixed function of the SoC: the slot hangs off
`0000:00:02.2`, the SSD off `0000:00:02.1`. Everything in this component
matches on the root port and nothing matches on `nvmeN`. `sdexpress format`
accepts no device argument for the same reason: a stale name would erase the
SSD. If a BIOS update moves the slot, record the new port with
`sdexpress root-port <bdf>` (it is rendered into the rule and re-applied).

## What is installed

| path | what |
|---|---|
| `/etc/udev/rules.d/99-ally-x20-steamos-sdexpress.rules` | rendered from `overlay/udev/rules.d/99-ally-x20-steamos-sdexpress.rules.in` with the root port filled in |
| `/etc/ally-x20-steamos/sdexpress.conf` | only after `sdexpress root-port <bdf>`: `root_port=` override |

The rule, in order:

1. Skip anything that is not a block device, or whose `DEVPATH` does not
   pass through the slot's root port.
2. On the whole-disk node (`nvme*n[0-9]`), set `ID_DRIVE_FLASH_SD`,
   `ID_DRIVE_MEDIA_FLASH_SD` and `ID_DRIVE_MEDIA_FLASH`. udisks classifies SD
   media from these, so Steam may show the card as "MicroSD Card" instead of
   "External Drive (label)". This is cosmetic and unverified.
3. On partitions (`nvme*n[0-9]p[0-9]*`) with `ID_FS_USAGE=filesystem`, run
   `block-device-event.sh add|remove %k` through `systemd-run`, exactly as
   the stock rule does for `mmcblk*`.

`apply` renders and installs the rule, reloads udev, and if a formatted,
unmounted card is already inserted hands it to `holo-automount.sh add` (the
`mount` subcommand does the same by hand). A partition that is already
mounted, for example through `/etc/fstab`, is left alone. `uninstall
--component sdexpress` removes the rule and the conf and reloads udev; an
existing mount stays until the card is removed.

## Formatting a card

```
sudo ./ally-x20-steamos.sh sdexpress format [--label <label>] [--full] [--validate]
```

It finds the card by root port (and refuses to run when none is there),
asks you to type `erase` (skipped with `--yes`), runs
`holo-automount.sh remove`, unmounts anything mounted from the card, then
the stock sequence:

```
dd if=/dev/zero of=/dev/<card> bs=512 count=1024 status=none
sync
parted --script /dev/<card> mklabel gpt mkpart primary 0% 100%
udevadm settle
mkfs.ext4 -m 0 -O casefold -E nodiscard,root_owner=1000:1000 -L <label> -F /dev/<card>p1
udevadm settle
/usr/lib/hwsupport/holo-automount.sh add <card>p1
```

`--full` uses `discard` instead of `nodiscard` (trims the whole card, as
Steam's "full format"). `--validate` runs `f3probe --destructive` first, as
Steam does by default; it is slow and exits 14 when the card fails. The
label defaults to `sdcard` and must be 1 to 16 characters of `A-Za-z0-9._-`.
**Give each card its own `--label`.** Two cards with the same label are
mounted at the same path, and Steam takes them for one library (seen on the
X20 on 2026-11-22, issue #89: a 512 GB card listed the games installed on a
1 TB card, both formatted with the default label).
`--dry-run` prints the commands without running them; do that once and check
that every line names the card's node.

**Do not format a card that is mounted through `/etc/fstab`.** The command
only knows the mounts the automount made. A card you mounted yourself with
an fstab line (especially with `x-systemd.automount`) is mounted again right
after the unmount, and the format then runs on a disk that is in use.
Measured on the X20 with v0.1.10: `dd` zeroed the first 512 KiB, `parted`
failed with "unable to inform the kernel of the change ... in use", and
`mkfs` never ran. The old filesystem survived that time, because it starts at
1 MiB and `parted` re-created the same partition, but nothing guarantees it.
Remove the fstab line first (next section); the command does not check for
it.

Afterwards the card is mounted at `/run/media/deck/<label>` and can be added
as a library in Steam → Settings → Storage.

**Why Steam's Format button cannot work.** It runs `format-device.sh`, which
rejects every device that is not `/dev/mmcblk[0-9]` or `/dev/sd[a-z]` before
reading any option, and the script lives under `/usr`, which this project
never touches. The button keeps failing for this slot; format from the CLI.

## Do not mount the card through /etc/fstab

With this component the card is mounted for you at `/run/media/deck/<label>`,
like a microSD card. An `/etc/fstab` line for the card is not needed and not
supported: the card and the SSD swap `nvmeN` names between boots, the two
mounts compete, and `sdexpress format` must not be run on a card mounted
that way (see above).

If you mounted the card yourself through `/etc/fstab` before (for example at
`/home/deck/sdcard` with `x-systemd.automount`) and added that path as a
Steam library, move to the automount:

1. In Steam → Settings → Storage, remove the library at the old path.
   Steam identifies libraries by path, so the old entry would otherwise
   point at a directory that is no longer a mountpoint.
2. Remove the card's line from `/etc/fstab`, then
   `sudo systemctl daemon-reload` and `sudo umount /home/deck/sdcard`
   (and `sudo systemctl stop home-deck-sdcard.automount` if systemd created
   an automount unit).
3. `sudo ./ally-x20-steamos.sh sdexpress mount`, or eject and reinsert the
   card. It appears at `/run/media/deck/<label>`.
4. Add the new path as a library in Steam → Settings → Storage.

The component never touches an existing mount, so while the fstab line is
still there the card is simply mounted the old way. Only `sdexpress format`
is unsafe in that state.

## Checking and debugging

```
sudo ./ally-x20-steamos.sh sdexpress status          # state, stock rule, root port, the card, lsblk
sudo ./ally-x20-steamos.sh sdexpress root-port       # 0000:00:02.2 (default) or the recorded override
udevadm info -q path -n /dev/nvme0n1                 # which root port is this device behind?
udevadm test /sys/class/block/nvme0n1p1 2>&1 | grep -iE 'sdexpress|RUN|ID_DRIVE'   # does the rule fire?
journalctl -t holo-automount -b                      # what the stock automount script did
journalctl -b | grep block-device-event              # the stock event script
findmnt /run/media/deck                              # udisks mounts
```

`status` reports the card as `card: /dev/nvmeXn1 <model> <N> GiB` whatever
its name this boot; `card: none under that root port` means no card is
inserted, or the slot is behind another port (check with `udevadm info -q
path` and record it with `sdexpress root-port`).

## Probe

The probe looks for the stock rule under `/usr/lib/udev/rules.d` that calls
`block-device-event.sh`:

| finding | probe | status |
|---|---|---|
| a non-comment `KERNEL` match in that rule mentions `nvme` | 0, superseded | `superseded`; remove with `uninstall --superseded` |
| the rule matches `mmcblk`/`sd` only | 1, needed | `active` once installed |
| no such rule | 2, unknown | `n/a` (the rule is still installed if you apply) |

## Not covered

- **Steam's Format button.** See above; it fails with "Unknown or
  unsupported device" for this slot and will keep doing so.
- **UHS-I fallback.** Plain microSD cards (and SD Express cards in UHS-I
  mode) appear as `mmcblk*`, which stock SteamOS already handles. The
  component leaves them alone.
- **Swapping cards while the device is on.** See the next section.
- **Keeping the card across a long sleep.** See the next section.

## Removal, insertion and sleep (issue #89)

Measured on the X20 on 2026-11-22: SteamOS 3.9.5, kernel
`7.2.7-valve2-2-neptune-72`, BIOS RC74XA.303, a SanDisk SD Express 1 TB and
a 512 GB card (both `15b7:5007`).

**The hardware.** The slot is a Genesys GL9767 reader (`17a0:9767`,
`sdhci-pci`) at `0000:62:00.0` behind the hotplug root port `0000:00:02.2`
(ACPI `\_SB.PCI0.GPP4`, with a power resource `PWSR`). With an SD Express
card the reader leaves the bus and the card takes its place at the same
address as an NVMe device. When the card goes, the reader comes back.

**Insertion and removal at the kernel level work, slowly.** Every pull and
insert of that day was seen by `pciehp`. After an insert the reader appears
within a second; the card replaced it as NVMe after 1, 16, 24 and 54 s on
different tries. A pull of a mounted card is a surprise removal: the kernel
logs `Buffer I/O error` and aborts the journal, and `fsck` repairs it at the
next mount. Earlier that day (in the first text of the issue) the slot also
stopped seeing cards until a reboot; that did not happen again.

**Steam keeps the library of a card that is gone.** Its `content_log.txt`
shows `Drive removed: /run/media/deck/<name>` at every removal and
`NotifyAddDrive: re-adding drive folder` plus `Mounted library folder` within
a second of every mount, so Steam sees both. In between it keeps the library
as an entry "External Drive ()" with 0 B (for a moment under the path
`/run/host/root/run/media/...`, the same mount as seen from inside Steam's
container). What did not change that:

| tried | result |
|---|---|
| `steam://removelibraryfolder/<path>`, as the stock mount script sent until Steam took drive handling over (library path, mount point, encoded and plain) | Steam logs `ExecuteSteamURL` and does nothing |
| SD flags on the card's NVMe controller (a temporary rule), so that udisks reports `flash_sd` for the drive instead of nothing; the flags this component sets on the disk node do not reach udisks | no change in Steam |

Not tried: a library at the top folder of the card, where Steam puts the
library of a card it adopts itself (ours is `<card>/SteamLibrary`, added by
hand). Bazzite's automount rule skips NVMe devices altogether, and Anatase's
documentation says of current Steam that unmounting drives does not work and
to shut down before taking a card out. So: **swapping cards while the device
is on is not supported**; insert and remove the card with the device off.

**After a long sleep the card can be gone.** Five sleeps were logged with a
card in:

| sleep | card after resume |
|---|---|
| 12 min, 12 min (2026-11-21), 9 s, 87 s (83 s of it in hardware sleep) | still there, still mounted |
| 2 h 9 min | `pciehp: Slot(0-1): Card not present` during resume, with the filesystem mounted; no device on the bus until the card was pulled and put back 3.5 min later |

Bazzite has the same report for the X20, after boot and after resume, with
an SD Express and a plain microSD card
([ublue-os/bazzite#6226](https://github.com/ublue-os/bazzite/issues/6226)),
so this is the platform and not this component. Whether it depends on how
long the device sleeps, and what brings the card back without touching it,
is not known.
