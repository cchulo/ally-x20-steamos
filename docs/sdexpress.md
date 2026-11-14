# SD Express slot

The ROG Xbox Ally X20 has an SD Express slot. On stock SteamOS an inserted
SD Express card shows up as an NVMe disk that nothing mounts, and Steam's
**Format** button fails on it. Component `sdexpress` makes the slot behave
like a microSD slot: the card is automounted by the same stock scripts
SteamOS uses for microSD cards, and `ally-x20-steamos sdexpress format`
formats it the way Steam's button would.

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
`--dry-run` prints the commands without running them; do that once and check
that every line names the card's node.

Afterwards the card is mounted at `/run/media/deck/<label>` and can be added
as a library in Steam → Settings → Storage.

**Why Steam's Format button cannot work.** It runs `format-device.sh`, which
rejects every device that is not `/dev/mmcblk[0-9]` or `/dev/sd[a-z]` before
reading any option, and the script lives under `/usr`, which this project
never touches. The button keeps failing for this slot; format from the CLI.

## Migrating from a hand-made fstab mount

If you mounted the card yourself through `/etc/fstab` (for example at
`/home/deck/sdcard` with `x-systemd.automount`) and added that path as a
Steam library:

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

The component never touches an existing mount, so nothing breaks while the
fstab line is still there; the card is simply mounted the old way.

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
- **The "MicroSD Card" label in Steam.** The SD flags on the disk node are a
  best-effort hint; whether Steam shows "MicroSD Card" or "External Drive"
  for the card has not been verified.
