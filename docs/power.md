# TDP limit and power profiles in Steam

Component `power` together with the `asus-armoury` patch in the `modules`
component. The goal: on stock SteamOS 3.9.5, Steam's Performance menu shows
its TDP limit slider and power profile switch for the ROG Xbox Ally X20 (board
`RC74XA`), with no Decky plugin and no replacement daemon. Steam talks to
Valve's own `steamos-manager`, which writes the firmware attributes of the
stock `asus-armoury` driver. We supply two things SteamOS does not have yet:
a kernel table entry and a steamos-manager device file.

## 1. The problem

On a stock SteamOS 3.9.5 X20 the Performance menu has no TDP slider and no
power profile control. Measured on the device on 2026-10-31 (kernel
`7.2.7-valve2-2-neptune-72-g31504582a073`, `steamos-manager` 26.4.1-2, DMI
`sys_vendor` `ASUS`, `board_name` `RC74XA`, `product_name`
`ROG XBOX Ally X RC74XA`):

| What | Measured |
|---|---|
| `asus_armoury` | loaded (stock `kernel/drivers/platform/x86/asus-armoury.ko.zst`), registers `/sys/class/firmware-attributes/asus-armoury/attributes/{ppt_pl1_spl,ppt_pl2_sppt,ppt_pl3_fppt,boot_sound,charge_mode,mcu_powersave}` |
| reading any `ppt_*/current_value` | `ENODEV`; the kernel logged `asus_armoury: No matching power limits found for this system` |
| platform profile | `/sys/firmware/acpi/platform_profile_choices` = `low-power balanced performance` (asus-wmi), current `balanced` |
| amdgpu hwmon | `power1_average` only, no `power1_cap`, so steamos-manager's `amdgpu_hwmon` TDP method cannot work here |
| steamos-manager device files | `/usr/share/steamos-manager/devices/rog-ally-series.toml` (RC71L, RC72LA, RC73XA) and `rog-xbox-ally.toml` (RC73YA): no RC74XA |
| D-Bus | no `com.steampowered.SteamOSManager1.TdpLimit1` interface |

## 2. Root cause

Two independent gaps; both must be closed.

**Kernel.** `asus-armoury` looks the machine up in its `power_limits[]` DMI
table (`drivers/platform/x86/asus-armoury.h`) to learn the min/max/default
of each PPT tunable. Valve's `7.2.7-valve2` table ends with RC71, RC72 and
RC73XA. Without a match `init_rog_tunables()` returns early, the attributes
are still registered, and every read of their values fails with `ENODEV`.
Mainline added RC74XA in `148794d9f0d2` ("platform/x86: asus-armoury: Add
XBOX ROG Ally X 20 Tunables", Derek J. Clark, 2026-10-18); Valve's
`7.2.10-valve1` carries the same change (`cf069f36e48d`).

**steamos-manager.** steamos-manager reads device descriptions only from
`/usr/share/steamos-manager/devices/*.toml` (`DEVICE_CONFIG_PATH` in
`steamos-manager/src/hardware.rs`; there is no `/etc` override directory).
A file matches when `dmi.sys_vendor` is equal and `dmi.board_name` or
`dmi.product_name` is equal. The stock 26.4.1 files only know the older
Allys, whose `sys_vendor` is `ASUSTeK COMPUTER INC.`; the X20 says `ASUS`.
With no match, steamos-manager creates no `TdpLimit1` and no
`PerformanceProfile1` interface, so Steam has nothing to show. Upstream added
the X20 in `bfbb261ed6b2` ("fix: Add XBox ROG Ally X 20", 2026-10-16), after
26.4.1 (2026-07-22). `/usr` is part of the read-only A/B image.

Both daemons read the device file: the system daemon (`steamos-manager.service`,
`/usr/lib/steamos-manager -r`, root) performs the writes (`SetTdpLimit`,
`SetPerformanceProfile`) through its own TDP manager; the per-user daemon
(`/usr/lib/steamos-manager`, started with the graphical session) exports the
`TdpLimit1` and `PerformanceProfile1` interfaces Steam uses. Each caches the
device file in a `OnceCell` at first use, so it is read once per daemon start.

## 3. The two fixes

### 3.1 Kernel: `0020` asus-armoury power limits (component `modules`)

`patches/kernel/0020-asus-armoury-add-ROG-Xbox-Ally-X20-RC74XA-power-limits.patch`
is the mainline commit with its author and trailers, applied to
`7.2.7-valve2` (details in
[patches/kernel/README.md](../patches/kernel/README.md#0020-asus-armoury-rc74xa-power-limits)).
`patches/kernel/modules-power.list` adds `asus-armoury.ko`
(`M=drivers/platform/x86`), so it is built, shipped and loaded exactly like
the audio and `hid-asus-ally` modules: the CI artifact and `rebuild` contain
`asus-armoury.ko.zst`, the generated
`/etc/modprobe.d/ally-x20-steamos-modules.conf` gets one more `install` hook,
and `load-or-fallback` loads our build for the matching kernel (stock
otherwise). See [kernel-modules.md](kernel-modules.md).

The values (watts):

| | min | default | max |
|---|---|---|---|
| AC `ppt_pl1_spl` (SPL) | 7 | (max) | 35 |
| AC `ppt_pl2_sppt` (sPPT) | 13 | (max) | 45 |
| AC `ppt_pl3_fppt` (fPPT) | 19 | (max) | 55 |
| DC `ppt_pl1_spl` | 7 | 17 | 35 |
| DC `ppt_pl2_sppt` | 13 | 21 | 45 |
| DC `ppt_pl3_fppt` | 19 | 26 | 55 |

The driver keeps `current_value` itself (it starts at the default, or the max
when there is none) and sends a write to the firmware through asus-wmi.

On Valve's `7.2.10-valve1` and later the patch is already in the tree, the
build records `module.asus-armoury=superseded`, and the stock module is used.
The `modules` probe also looks for `RC74XA` in the stock `asus-armoury.ko`.

### 3.2 steamos-manager: the device file shim (component `power`)

| Path | What |
|---|---|
| `/etc/ally-x20-steamos/steamos-manager/90-ally-x20-steamos-rc74xa.toml` | the RC74XA entry: upstream's values in the 26.4.1 schema |
| `/etc/ally-x20-steamos/steamos-manager-devices-shim` | POSIX sh helper, `start`/`stop`/`status` |
| `/etc/systemd/system/ally-x20-steamos-power-devices.service` | runs the helper (oneshot, `RemainAfterExit=yes`) |
| `/etc/systemd/system/multi-user.target.wants/…`, `/etc/systemd/system/steamos-manager.service.wants/…` | enable links |
| `/run/ally-x20-steamos/steamos-manager-devices/` | the merged copy (tmpfs, rebuilt every start, never in the manifest) |
| `/run/ally-x20-steamos/steamos-manager-devices.state` | last helper result: `mounted`, `stock-has-board`, `no-stock-dir`, `missing-config`, `foreign-mount` or `stopped` |

Everything except `/run` is recorded in the manifest.

The device entry (`overlay/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml`)
is upstream's RC74XA block: `dmi.sys_vendor = "ASUS"`,
`dmi.board_name = "RC74XA"`, `device = "rog_xbox_ally_x_20"` (`device` is a free
string in 26.4.1, not an enum), `variant = "RC74XA"`,
`friendly_name = "ROG Xbox Ally"`, `gpu_performance` and `gpu_power_profile`
on `amdgpu`, `tdp_limit` method `firmware_attribute` on attribute
`asus-armoury`, active in platform profile `performance`, and
`battery_charge_limit` method `acpi_sb`. Upstream main has since moved the
platform profile to a `[performance_profile.driver.acpi]` table; 26.4.1 does
not know it, so the file uses the 26.4.1 form
`[performance_profile] platform_profile_name = "asus-wmi"`,
`suggested_default = "performance"`.

### 3.3 The shim's lifecycle

`ally-x20-steamos-power-devices.service` is ordered `Before=steamos-manager.service
systemd-user-sessions.service display-manager.service graphical.target`, so it
has run before the system daemon starts and before any login can start the
session daemon. It is wanted by `multi-user.target` and by
`steamos-manager.service`, which also covers a D-Bus activation of the daemon
early in boot.

`start`:

1. Unmount our earlier layer on `/usr/share/steamos-manager/devices`, if any
   (identified in `/proc/self/mountinfo` by a source under
   `/ally-x20-steamos/`). A mount made by anything else is left alone and
   the helper does nothing (`foreign-mount`).
2. If a stock file (not one of ours) contains `"RC74XA"`, stop here
   (`stock-has-board`): SteamOS has caught up.
3. Copy every stock entry into `/run/ally-x20-steamos/steamos-manager-devices`
   and add our `.toml`.
4. `mount --bind` the copy over the stock directory and remount it read-only.

`stop` unmounts and deletes the copy. A reboot drops the mount too.

A bind mount writes nothing to `/usr`: the stock files are untouched and
come back as soon as the mount is gone, and `steamos-readonly` is never
used. Because the copy is rebuilt from the real stock directory at every
boot, files that a SteamOS update adds or changes show through unchanged.

`apply --only power` installs the files, creates the enable links,
`daemon-reload`s, restarts the unit, then `try-restart`s
`steamos-manager.service` and the session daemon
(`systemctl --user -M <user>@ try-restart steamos-manager.service`; the user is
`$SUDO_USER`, else `deck`, or `AX20_POWER_USER`). If the slider still does not
appear, restart Steam or reboot. Under `--root`/`--slot` no `systemctl` runs;
the unit starts at the next boot of that slot.

`uninstall --component power` (and a full uninstall) stops the unit, runs the
helper's `stop` in case the unit was not loaded, restarts both daemons so they
forget the X20, then removes the manifest entries. The standalone
`uninstall.sh` also stops the unit and unmounts our layers before it removes
files, without the checkout.

### 3.4 Why it is temporary, and what happens on updates

| Situation | What happens |
|---|---|
| SteamOS ships a steamos-manager with an RC74XA file (any schema) | at the next boot the helper finds `"RC74XA"` in a stock file and mounts nothing; `status` shows `power` as `superseded`; `uninstall --superseded` removes it. Apply skips the component on a system where it was never installed |
| A SteamOS update with a kernel that already has the limits (Valve `7.2.10-valve1`+) | `rebuild` records `asus-armoury` as superseded and the stock module loads |
| A SteamOS update with neither | the boot service re-applies drifted files as for every component; the module needs a rebuild for the new kernel ([update-survival.md](update-survival.md)) |
| A future steamos-manager with a different schema but still no RC74XA | our file may fail to parse; steamos-manager logs `Failed to read config file` and skips it (no crash). Upstream added RC74XA before its schema change, so this should not occur |

## 4. What appears in Steam

steamos-manager exposes, from the device file (26.4.1, `manager/user.rs`):

- **Power profile** (`PerformanceProfile1`): `AvailablePerformanceProfiles`
  from `/sys/class/platform-profile/<asus-wmi>/choices`
  (`low-power balanced performance`), `PerformanceProfile` read/write
  (written by the root daemon to that platform profile's `profile` file),
  `SuggestedDefaultPerformanceProfile` = `performance`. The interface is only
  created when the choices list is not empty.
- **TDP limit** (`TdpLimit1`): `TdpLimit`, `TdpLimitMin`, `TdpLimitMax`.
  Min and max are read from `ppt_pl1_spl/min_value` and `max_value` (7 and 35
  W). The interface is present only while the platform profile is
  `performance` (`[tdp_limit.firmware_attribute] performance_profile`, "until
  custom mode is added" upstream); switching the profile adds or removes it.
  So the slider appears when the profile is Performance, and is gone in
  Balanced or Low power, where the firmware's own limits apply.
- **GPU clock controls** (`gpu_performance`, `gpu_power_profile` on amdgpu), as
  on the other Allys. **Battery charge limit** via `acpi_sb`.

What Steam's UI does with these is up to the client: the TDP Limit slider and,
if the client offers it for this device, the profile selection.

Values are watts. A slider value *L* makes steamos-manager
(`FirmwareAttributeLimitManager::set_tdp_limit` in `power.rs`, via the root
daemon) check that *L* is inside the SPL min..max, then write:

| File (`…/asus-armoury/attributes/`) | Value |
|---|---|
| `ppt_pl1_spl/current_value` | *L* |
| `ppt_pl2_sppt/current_value` | max(*L*, `ppt_pl2_sppt/min_value`) = max(*L*, 13) |
| `ppt_pl3_fppt/current_value` | max(*L*, `ppt_pl3_fppt/min_value`) = max(*L*, 19) |

So all three limits follow the slider (sustained = short = fast boost),
except that sPPT and fPPT never go below their minimums. The slider reads
back `ppt_pl1_spl/current_value`.

## 5. Verify

```sh
# kernel: a number in watts, not "No such device"
cat /sys/class/firmware-attributes/asus-armoury/attributes/ppt_pl1_spl/current_value
cat /sys/class/firmware-attributes/asus-armoury/attributes/ppt_pl1_spl/{min,max}_value   # 7 35
journalctl -b -t ally-x20-steamos | grep asus-armoury                                     # "loaded patched asus-armoury"

# shim
systemctl status ally-x20-steamos-power-devices.service
/etc/ally-x20-steamos/steamos-manager-devices-shim status                                 # mounted
findmnt /usr/share/steamos-manager/devices
ls /usr/share/steamos-manager/devices/                                                    # stock files + 90-ally-x20-steamos-rc74xa.toml

# steamos-manager (as the deck user); TdpLimit1 only while the profile is "performance"
busctl --user get-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 \
    com.steampowered.SteamOSManager1.PerformanceProfile1 PerformanceProfile
busctl --user introspect com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 | grep TdpLimit

sudo ./ally-x20-steamos.sh status --verbose     # power: shim=..., asus_armoury=SPL N W (range 7..35 W)
```

Then open Steam's Performance menu (Quick Access, battery icon): select the
Performance profile if it is not already, move the TDP Limit slider, and watch
`ppt_pl1_spl/current_value` follow.

## 6. Needs the device (`TODO(hw)`)

- The patched `asus-armoury` loads at boot through the modprobe hook, and
  `asus_armoury` is not in the initramfs (otherwise the stock module wins).
- The firmware honours the writes: package power follows the slider
  (`power1_average`), on AC and on battery.
- `/sys/class/platform-profile/*/name` contains `asus-wmi` (steamos-manager
  looks the profile up by that name).
- The bind mount is in place before both daemons on a cold boot, including
  when the session daemon starts with Game Mode's autologin.
- Steam's client shows the slider for `device = "rog_xbox_ally_x_20"` (a name
  this Steam build may not know yet) and whether it offers the profile switch.
- Whether a `systemd-sysext` refresh or anything else re-mounts `/usr` and
  hides the bind mount.
