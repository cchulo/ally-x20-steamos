# Power profiles in Steam (and why there is no TDP slider)

Component `power` together with the `asus-armoury` patch in the `modules`
component. On stock SteamOS 3.9.5, Steam's Performance menu shows the ASUS
power profiles (Low power, Balanced, Performance) for the ROG Xbox Ally X20
(board `RC74XA`), with no Decky plugin and no replacement daemon. Steam talks
to Valve's own `steamos-manager`, which switches the asus-wmi platform
profile. We supply a steamos-manager device file that SteamOS 3.9.5 does not
have yet, and a kernel table entry that is kept for a later BIOS.

The TDP limit slider is **intentionally not exposed**: the X20 firmware
(BIOS `RC74XA.303`) ignores every PPT limit write, so a slider would move
and change nothing. `ally-x20-steamos power tdp-slider on` brings it back
for testing after a BIOS update (section 7).

## 1. Status (measured 2026-10-31)

Measured by the owner on the X20 (RC74XA, BIOS `RC74XA.303`, SteamOS 3.9.5,
kernel `7.2.7-valve2` with our patched `asus-armoury` that has the RC74XA
power-limit table, steamos-manager 26.4.1 with our device file), under a
steady game load (Resident Evil 9). APU power is amdgpu hwmon
`power1_average`; battery draw is the battery's `current_now` x
`voltage_now`.

### 1.1 What works: the ASUS profiles

Steam's profile switch goes through steamos-manager to the asus-wmi platform
profile (`/sys/firmware/acpi/platform_profile`, asus-wmi
`throttle_thermal_policy`). The firmware applies its own power limits for
each profile, and they clearly cap package power:

| Steam / platform profile | ASUS name (`throttle_thermal_policy`) | APU (`power1_average`) | Battery draw |
|---|---|---|---|
| Low power (`low-power`) | Silent (2) | 12-13 W | 22 W |
| Balanced (`balanced`) | Balanced (0) | 16-21 W | 32 W |
| Performance (`performance`) | Turbo (1) | 25-30 W on battery; 34-35 W on the charger (45 W seen right after plugging in) | not recorded |

The presets follow the power source by themselves: the firmware keeps
separate AC and DC limits per profile (Turbo goes from 25-30 W on battery to
34-35 W on the charger without any write from us). The owner used the same
presets on Windows and accepts profiles without a slider.

The device entry suggests `balanced` as the default profile. Upstream says
`performance` with the comment "until custom mode is added", which goes with
its slider existing only in that profile; without a slider that reason is
gone. Balanced is the firmware's own boot profile, and on
battery, where the owner mostly plays, it runs the APU at 16-21 W instead
of Performance's 25-30 W. Performance is one tap away in Steam.

### 1.2 What does not work: TDP limits (PPT writes)

Every PPT write is **ignored** by this firmware, in every profile. Asking
for 10 W or 25 W leaves package power where the profile puts it:

| Profile | Requested PPT | APU (`power1_average`) |
|---|---|---|
| Balanced | 10 W or 25 W | 16-17 W (unchanged) |
| Silent (Low power) | 10 W or 25 W | 12-13 W (unchanged) |
| Turbo (Performance) | 10 W or 25 W | 29-30 W (unchanged) |

What was tried, all with the same result:

1. asus-armoury firmware attributes `ppt_pl1_spl`, `ppt_pl2_sppt`,
   `ppt_pl3_fppt` (what steamos-manager writes), with our patch 0020 loaded
   so the attributes accept values.
2. The legacy asus-wmi nodes `/sys/devices/platform/asus-nb-wmi/ppt_*` (what
   HHD writes).
3. Raw WMI `DEVS` calls through the asus-wmi debugfs interface, including
   with bit 16 of the argument set (see the DSDT note below).
4. HHD's write order: FPPT, then SPPT, then SPL, with 100 ms pauses.
5. Re-sending the thermal policy (`DEVS` 0x120075) after the PPT writes.
6. Unloading `amd_pmf` and `amdxdna` (Bazzite's fix for the same symptom on
   the Ally X).

WMI `DSTS` on the PPT device ids returns `0x10000` (present, value 0), so
the firmware gives no read-back; asus-armoury's `current_value` is only the
driver's cached copy of the last write.

steamos-manager's "Turn off TDP limit" writes the maximum (35 W) to all
three limits, so the boost limits (sPPT 45 W, fPPT 55 W) would be lost if
the writes did anything; with the writes ignored it is moot.

**DSDT observations** (reading of the RC74XA.303 DSDT, not a proof of what
the EC firmware does): the WMI PPT handlers write EC fields `SOLH`/`SOLL`,
`SPTH`/`SPTL` and `FPTH`/`FPTL` (by their names, high and low bytes of SPL,
sPPT and fPPT), and copy bit 16 of the WMI argument into an EC flag named
`MPMD` (perhaps a "manual power mode" switch). The thermal-policy handler
(0x120075) instead calls AMD's `ALIB` method with the `UTDP` function, which
programs the APU's limits directly. That would explain the measurements:
the profiles go through ALIB and work; the PPT handlers only hand values to
the EC, which on this BIOS does not pass them on, with or without `MPMD`.

**Independent confirmation:** Hooandee/panel-de-control issue #1012
(2026-10-26), "El ajuste de TDP no funciona en la Xbox RoG Ally X20", on
Anatase with kernel 7.2.7, same board: TDP changes have no effect.

So the device entry has no `[tdp_limit]`: steamos-manager exposes no
`TdpLimit1` interface and Steam shows no slider that does nothing.

### 1.3 GPU controls

- `[gpu_power_profile]` (amdgpu) is removed: this APU has no
  `pp_power_profile_mode`, and steamos-manager only logged
  `Error getting GPU power profile: ... No such file or directory`.
- `[gpu_performance]` (amdgpu) is kept as upstream has it. Steam's Manual
  GPU Clock fails with `EINVAL` through it on this APU; nothing else is
  affected, and a later kernel or steamos-manager may make it work.

### 1.4 Kernel patch 0020 stays

The patched `asus-armoury` (section 4.1) stays in the module build: it is
cheap, it makes the `ppt_*` attributes readable instead of `ENODEV`, and a
future BIOS may honour the writes. With `tdp_slider` off nothing reads the
attributes, so `apply` and `status` report a module problem only as
information.

## 2. The problem (stock SteamOS 3.9.5)

On a stock SteamOS 3.9.5 X20 the Performance menu has no power profile
control (and no TDP slider). Measured on the device on 2026-10-31 (kernel
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

## 3. Root cause

Two independent gaps. The steamos-manager one is what hides the profiles;
the kernel one only matters for the TDP slider, which the firmware ignores
anyway (section 1.2).

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

## 4. The fixes

### 4.1 Kernel: `0020` asus-armoury power limits (component `modules`)

Kept in the build although the slider is off (section 1.4): it is only
needed by `tdp_slider=on` and by anyone testing PPT writes by hand.

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

### 4.2 steamos-manager: the device file shim (component `power`)

| Path | What |
|---|---|
| `/etc/ally-x20-steamos/steamos-manager/90-ally-x20-steamos-rc74xa.toml` | the RC74XA entry, rendered by `apply`: upstream's values in the 26.4.1 schema, without `[tdp_limit]` (unless `tdp_slider=on`) and `[gpu_power_profile]` |
| `/etc/ally-x20-steamos/power.conf` | settings: `tdp_slider=off` (default) or `on` (section 7) |
| `/etc/ally-x20-steamos/steamos-manager-devices-shim` | POSIX sh helper, `start`/`stop`/`status` |
| `/etc/systemd/system/ally-x20-steamos-power-devices.service` | runs the helper (oneshot, `RemainAfterExit=yes`) |
| `/etc/systemd/system/multi-user.target.wants/…`, `/etc/systemd/system/steamos-manager.service.wants/…` | enable links |
| `/run/ally-x20-steamos/steamos-manager-devices/` | the merged copy (tmpfs, rebuilt every start, never in the manifest) |
| `/run/ally-x20-steamos/steamos-manager-devices.state` | last helper result: `mounted`, `stock-has-board`, `no-stock-dir`, `missing-config`, `foreign-mount` or `stopped` |

Everything except `/run` is recorded in the manifest.

The device entry (`overlay/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml`)
is upstream's RC74XA block: `dmi.sys_vendor = "ASUS"`,
`dmi.board_name = "RC74XA"`, `device = "rog_xbox_ally_x"` (upstream:
`rog_xbox_ally_x_20`; `device` is a free string in 26.4.1, not an enum, see
the table below), `variant = "RC74XA"`,
`friendly_name = "ROG Xbox Ally"`, `gpu_performance` on `amdgpu`, the
asus-wmi platform profile, and `battery_charge_limit` method `acpi_sb`.
Upstream main has since moved the platform profile to a
`[performance_profile.driver.acpi]` table; 26.4.1 does not know it, so the
file uses the 26.4.1 form
`[performance_profile] platform_profile_name = "asus-wmi"`.

Differences from upstream (the first three from the measurements in section 1):

| Upstream | Ours | Why |
|---|---|---|
| `[tdp_limit]` `firmware_attribute` on `asus-armoury`, in profile `performance` | left out; appended by `power tdp-slider on` | the firmware ignores PPT writes (1.2) |
| `[gpu_power_profile] driver = "amdgpu"` | left out | no `pp_power_profile_mode` on this APU (1.3) |
| `suggested_default = "performance"` ("until custom mode is added") | `balanced` | the firmware's boot profile, better on battery (1.1) |
| `device = "rog_xbox_ally_x_20"` | `device = "rog_xbox_ally_x"` | Steam artwork, see below |

**Why the Xbox Ally X device name.** The Steam client picks the handheld
artwork in its controller and layout screens from the `device` name of
this entry. The Steam client shipped with SteamOS 3.9.5
does not know `rog_xbox_ally_x_20`, the name upstream chose for the X20, and
falls back to a generic handheld silhouette (it looks like a Legion Go S).
It does know `rog_xbox_ally_x`, the Xbox Ally X, whose shell, screen and
controls the X20 shares, so with that name Steam draws the right device.
`variant = "RC74XA"` and the DMI match stay as upstream has them.
steamos-manager's own RC74XA entry (upstream `bfbb261ed6b2`, not yet in
26.4.1) uses the X20 name; once SteamOS ships it, our shim steps aside
(section 4.4) and the client will by then presumably know the X20 name.

`apply` renders the installed file from the overlay file plus, with
`tdp_slider=on`, the `[tdp_limit]` tables, and records it in the manifest
like every other file. Re-applying over an entry from an earlier release
(which had `[tdp_limit]` and `[gpu_power_profile]`) simply rewrites it, and
the unit restart makes the shim remount the copy with the new entry.

### 4.3 The shim's lifecycle

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
`$SUDO_USER`, else `deck`, or `AX20_POWER_USER`). If the profile switch still
does not appear (or, with `tdp_slider` on, the slider), restart Steam or
reboot. Under `--root`/`--slot` no `systemctl` runs;
the unit starts at the next boot of that slot.

`uninstall --component power` (and a full uninstall) stops the unit, runs the
helper's `stop` in case the unit was not loaded, restarts both daemons so they
forget the X20, then removes the manifest entries. The standalone
`uninstall.sh` also stops the unit and unmounts our layers before it removes
files, without the checkout.

### 4.4 Why it is temporary, and what happens on updates

| Situation | What happens |
|---|---|
| SteamOS ships a steamos-manager with an RC74XA file (any schema) | at the next boot the helper finds `"RC74XA"` in a stock file and mounts nothing; `status` shows `power` as `superseded`; `uninstall --superseded` removes it. Apply skips the component on a system where it was never installed. Steam then shows upstream's (inert) TDP slider in Performance (section 8) |
| A SteamOS update with a kernel that already has the limits (Valve `7.2.10-valve1`+) | `rebuild` records `asus-armoury` as superseded and the stock module loads |
| A SteamOS update with neither | the boot service re-applies drifted files as for every component; the module needs a rebuild for the new kernel ([update-survival.md](update-survival.md)) |
| A future steamos-manager with a different schema but still no RC74XA | our file may fail to parse; steamos-manager logs `Failed to read config file` and skips it (no crash). Upstream added RC74XA before its schema change, so this should not occur |

## 5. What appears in Steam

steamos-manager exposes, from the device file (26.4.1, `manager/user.rs`):

- **Power profile** (`PerformanceProfile1`): `AvailablePerformanceProfiles`
  from `/sys/class/platform-profile/<asus-wmi>/choices`
  (`low-power balanced performance`), `PerformanceProfile` read/write
  (written by the root daemon to that platform profile's `profile` file),
  `SuggestedDefaultPerformanceProfile` = `balanced`. The interface is only
  created when the choices list is not empty.
- **Battery charge limit** via `acpi_sb`.
- **GPU clock** (`gpu_performance` on amdgpu); Manual GPU Clock fails with
  `EINVAL` on this APU (section 1.3).
- **No TDP limit** (`TdpLimit1`), unless `tdp_slider` is on.

With `tdp_slider` on, the entry also has upstream's
`[tdp_limit] method = "firmware_attribute"`,
`[tdp_limit.firmware_attribute] attribute = "asus-armoury"`,
`performance_profile = "performance"`. Then `TdpLimit1` (`TdpLimit`,
`TdpLimitMin`, `TdpLimitMax` from `ppt_pl1_spl/min_value` and `max_value`,
7 and 35 W) exists only while the platform profile is `performance`
("until custom mode is added" upstream), so the slider appears in
Performance and is gone in Balanced or Low power. A slider value *L* makes
steamos-manager (`FirmwareAttributeLimitManager::set_tdp_limit` in
`power.rs`, via the root daemon) check that *L* is inside the SPL min..max,
then write:

| File (`…/asus-armoury/attributes/`) | Value |
|---|---|
| `ppt_pl1_spl/current_value` | *L* |
| `ppt_pl2_sppt/current_value` | max(*L*, `ppt_pl2_sppt/min_value`) = max(*L*, 13) |
| `ppt_pl3_fppt/current_value` | max(*L*, `ppt_pl3_fppt/min_value`) = max(*L*, 19) |

So all three limits follow the slider (sustained = short = fast boost),
except that sPPT and fPPT never go below their minimums. On BIOS
`RC74XA.303` none of this changes package power (section 1.2).

## 6. Verify

```sh
# shim
systemctl status ally-x20-steamos-power-devices.service
/etc/ally-x20-steamos/steamos-manager-devices-shim status                                 # mounted
findmnt /usr/share/steamos-manager/devices
ls /usr/share/steamos-manager/devices/                                                    # stock files + 90-ally-x20-steamos-rc74xa.toml
grep -c tdp_limit /usr/share/steamos-manager/devices/90-ally-x20-steamos-rc74xa.toml      # 0 (tdp_slider off)

# steamos-manager (as the deck user)
busctl --user get-property com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 \
    com.steampowered.SteamOSManager1.PerformanceProfile1 PerformanceProfile
busctl --user introspect com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 | grep -c TdpLimit   # 0

sudo ally-x20-steamos power status   # status, shim=..., tdp_slider=off (intentionally not exposed ...), asus_armoury=...
```

Then open Steam's Performance menu (Quick Access, battery icon): the power
profile switch is there and there is no TDP Limit slider. Switching the
profile changes `/sys/firmware/acpi/platform_profile` and package power
(section 7's loop shows it).

## 7. Re-testing the TDP slider after a BIOS update

```sh
sudo ally-x20-steamos power tdp-slider on    # adds [tdp_limit], restarts the shim and both daemons
sudo ally-x20-steamos power tdp-slider off   # back to profiles only (the default)
sudo ally-x20-steamos power tdp-slider       # prints tdp_slider=on|off
```

The setting lives in `/etc/ally-x20-steamos/power.conf` (`tdp_slider=on|off`,
a manifest entry of `power`, so re-applies and updates keep it and uninstall
removes it). `tdp-slider` re-renders
`/etc/ally-x20-steamos/steamos-manager/90-ally-x20-steamos-rc74xa.toml` and
then does what `apply --only power` does: restarts
`ally-x20-steamos-power-devices.service` (the shim remounts the copy with
the new entry) and `try-restart`s both steamos-manager daemons. Restart Steam
if the slider does not show; select the Performance profile, where the
slider lives.

Measure under a steady load (a game that keeps the GPU busy, not a menu):

```sh
# APU power (amdgpu hwmon) and battery draw, once a second
hw=$(dirname "$(grep -l '^amdgpu$' /sys/class/hwmon/hwmon*/name | head -n 1)")
bat=$(ls -d /sys/class/power_supply/BAT* | head -n 1)
while sleep 1; do
    printf '%-12s APU %5.1f W  battery %5.1f W\n' "$(cat /sys/firmware/acpi/platform_profile)" \
        "$(awk '{ print $1 / 1e6 }' "$hw/power1_average")" \
        "$(awk -v i="$(cat "$bat/current_now")" -v v="$(cat "$bat/voltage_now")" 'BEGIN { print i * v / 1e12 }')"
done

# the asus-armoury attributes steamos-manager writes (cached by the driver, not read back from the firmware)
a=/sys/class/firmware-attributes/asus-armoury/attributes
for x in ppt_pl1_spl ppt_pl2_sppt ppt_pl3_fppt; do
    printf '%s %s W (%s..%s)\n' "$x" "$(cat "$a/$x/current_value")" "$(cat "$a/$x/min_value")" "$(cat "$a/$x/max_value")"
done

# a manual write, without Steam: 10 W in Balanced should drop the APU well below 16 W if the firmware honours it
echo balanced | sudo tee /sys/firmware/acpi/platform_profile
echo 10 | sudo tee "$a/ppt_pl1_spl/current_value"
echo 13 | sudo tee "$a/ppt_pl2_sppt/current_value"
echo 19 | sudo tee "$a/ppt_pl3_fppt/current_value"
```

Compare with section 1.2. If package power follows the limit in some
profile, record the BIOS version (`cat /sys/class/dmi/id/bios_version`) and
the numbers in [hardware-data.md](hardware-data.md), and consider making
`tdp_slider` the default for that BIOS.

## 8. Upstream

- **HHD** maps the RC74X boards to the Xbox Ally X power table and writes
  the legacy `asus-nb-wmi` `ppt_*` nodes (attempt 2 in section 1.2), so it
  hits the same ignored writes on this BIOS.
- **steamos-manager** upstream (`bfbb261ed6b2`) ships the RC74XA entry with
  `[tdp_limit] method = "firmware_attribute"` (attempt 1). Once SteamOS
  includes it, our shim steps aside (section 4.4) and Steam will show the
  inert slider in Performance; nothing in this repository can then remove
  it without overriding a stock file, which we do not do.
- Both would benefit from a report with the measurements in section 1:
  to Valve (steamos-manager / SteamOS bug tracker: drop `[tdp_limit]` for
  RC74XA, or keep it with a firmware note, and drop `[gpu_power_profile]`)
  and to HHD (TDP control on the X20 has no effect on BIOS `RC74XA.303`).
  ASUS is the party that can make the PPT path work.

## 9. Needs the device (`TODO(hw)`)

- The bind mount is in place before both daemons on a cold boot, including
  when the session daemon starts with Game Mode's autologin.
- Whether a `systemd-sysext` refresh or anything else re-mounts `/usr` and
  hides the bind mount.
- That Steam picks up `SuggestedDefaultPerformanceProfile` = `balanced` on a
  fresh install (and what it does on an existing one).
- After a BIOS update: section 7.
