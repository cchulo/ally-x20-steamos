# InputPlumber (controller, buttons, IMU, LED rings)

Component: [`components/inputplumber.sh`](../components/inputplumber.sh).
Plan: [`X20-STEAMOS-PLAN.md`](../X20-STEAMOS-PLAN.md) §1.2, §5 (probes), §6
check 5. The Quick Access `0xa0` kernel fix is a separate patch (modules
component) and is not covered here.

All facts below were checked on **2026-10-30** unless a different date is
given.

## 1. What SteamOS ships

| Channel (Valve package mirror) | `inputplumber` | Built |
|---|---|---|
| `extra-3.9` (SteamOS 3.9.x, the X20's target) | **0.78.0-1** | 2026-07-21 |
| `extra-main` | 0.78.0-1 | 2026-07-21 |
| `jupiter-3.8` | 0.78.0-1 | 2026-08-07 |
| `extra-staging` (not released yet) | 0.83.1-1 | 2026-10-27 |

Source: the pacman databases at
`https://steamdeck-packages.steamos.cloud/archlinux-mirror/<repo>/os/x86_64/<repo>.db`
(`extra-3.9.db`, `extra-main.db`, `jupiter-3.8.db`, `extra-staging.db`). The
plan said the package lives in the `jupiter` repo; for 3.9 it is in `extra`.

We downloaded `extra-3.9/os/x86_64/inputplumber-0.78.0-1-x86_64.pkg.tar.zst`
and checked:

- `/usr/share/inputplumber/devices/` has `50-rog_ally.yaml`,
  `50-rog_ally_x.yaml` and `50-rog_xbox_ally.yaml`. No file mentions `RC74XA`.
- `inputplumber.service` is byte-identical to upstream:
  `Type=dbus`, `BusName=org.shadowblip.InputPlumber`,
  `Environment=LOG_LEVEL=info`, `ExecStart=/usr/bin/inputplumber` (no
  arguments), `ProtectSystem=full`, `WantedBy=multi-user.target`.
- `ally_type2.yaml` (`id: aly2`) and `50-rog_xbox_ally.yaml` are identical
  to upstream tag `v0.78.0`, so the package is unpatched upstream 0.78.0.
- `inputplumber --version` uses clap's default output
  (`#[command(author, version, ...)]` in `src/cli/mod.rs`), so it prints
  `inputplumber 0.78.0`.

**Confidence: high** that SteamOS 3.9 currently ships 0.78.0. The open
point is whether the image on a given X20 was built from these repos
(`TODO(hw)`: `inputplumber --version` in the plan's §7 checklist). Once Valve
promotes 0.83.1 from staging, the stock package will ship its own X20
profile and the probe will report `superseded`.

## 2. Upstream X20 support

- PR [ShadowBlip/InputPlumber#756](https://github.com/ShadowBlip/InputPlumber/pull/756),
  "feat(Hardware Support): add ASUS ROG Xbox Ally X20", merged 2026-10-21
  (merge commit `9b717089dadd6b2e922df0326016c815b664aa62`). It adds
  `rootfs/usr/share/inputplumber/devices/50-rog_xbox_ally_x20.yaml` and one
  hwdb entry. It matches `board_name: RC74XA` with `sys_vendor: ASUS` (the
  older Allys use `ASUSTeK COMPUTER INC.`), reuses the Xbox Ally sources
  (hidraw `0b05:1b4c` interfaces 2 and 5, evdev `0b05:1b4c`, `bmi323-imu`,
  LED `ally:rgb:joystick_rings`) and `capability_map_id: aly2`. The IMU mount
  matrix is `x: [-1,0,0]`, `y: [0,0,1]`, `z: [0,-1,0]`.
- Release [v0.83.0](https://github.com/ShadowBlip/InputPlumber/releases/tag/v0.83.0),
  2026-10-21, commit `4ed1f50c7801e4f91fd17ce1a7b2b9d8d8b82e69`.
  [v0.83.1](https://github.com/ShadowBlip/InputPlumber/releases/tag/v0.83.1),
  2026-10-26, commit `b2fb40900506d329925d5a3f1bca54adf85f1279`, contains
  bug fixes only. The X20 profile (blob `24bd3e61…`) and `ally_type2.yaml`
  (blob `9ab261dd…`) are identical in both.
- Upstream license: `Cargo.toml` says `GPL-3.0-or-later`. Arch/SteamOS
  package metadata says `GPL-3.0-only`. We keep the upstream files under
  GPL-3.0-or-later (see [`LICENSE.md`](../LICENSE.md)).

### Schema

Device configs use `version: 1` and `kind: CompositeDevice`
(`schema/composite_device_v1.json`). Capability maps use `kind: CapabilityMap`
with `version: 1` or `2`. Input profiles use `kind: DeviceProfile`
(`device_profile_v1.json`). Between 0.78.0 and 0.83.0 the JSON schema only
gained keys: `cpu_model` in matches, and `sample_rate`, `accel_correction`
and `gyro_correction` in the IMU config. Serde does not deny unknown fields,
so newer keys are ignored silently. The behaviour differences that matter
for the X20 are:

| | ≤ 0.81.x (stock 0.78.0) | ≥ 0.82.0 |
|---|---|---|
| IMU mount matrix read from | `iio.mount_matrix` only (`config.imu.mount_matrix` is parsed but ignored by the BMI driver) | `config.imu.mount_matrix` (upstream commit `e56713be40`, "Refactor iio_imu driver") |
| Mount-matrix axis convention | old | new: upstream commit `ace01953cb` changed the target axes. For every handheld it re-verified, new = L·old with L = [[1,0,0],[0,0,-1],[0,1,0]] |
| `aly2` button map | older labels: L4/R4 on `LeftPaddle2/RightPaddle2`, long presses on `LeftTop/RightTop` | corrected in `b5df0525f1` (first in 0.79.0) |
| `events: include/exclude` on sources | supported (since 2025-02, `efe0f03164`) | supported |
| `/etc/inputplumber/devices.d`, `capability_maps.d` | read | read (`src/config/path.rs` unchanged) |

### How the daemon loads configs (`src/config/path.rs`, `src/input/manager.rs`)

- Device configs are read from `./rootfs/usr/share/inputplumber/devices`,
  then `/etc/inputplumber/devices.d`, then `<XDG data dir>/inputplumber/devices`
  (normally `/usr/share/inputplumber/devices`). All `*.yaml` files are sorted
  **by file name across all directories**. For equal names, the directory
  order above decides, so `/etc` wins over `/usr/share`. When a device
  appears, the first config whose `matches` fit the system and whose
  `source_devices` fit the device creates the composite device. That is why
  our file keeps the upstream name `50-rog_xbox_ally_x20.yaml`: if a later
  stock package ships the same file, ours takes precedence until it is
  removed (`uninstall --superseded`). A different name could let either file
  win depending on sort order.
- Capability maps are read from `<XDG data dir>/inputplumber/capability_maps`,
  then `/etc/inputplumber/capability_maps.d`, sorted the same way, and
  inserted into a map keyed by `id`. Later files win. We use a distinct id
  (`ally_x20_steamos_aly2`) so the stock `aly2` is left alone.
- The base data dir is the first `$XDG_DATA_DIRS/inputplumber` that exists,
  falling back to `/usr/share/inputplumber`. The fallback drop-in uses this
  to point the upstream build at its own data files.

### Autostart (hwdb)

Upstream ships `/usr/lib/udev/hwdb.d/60-inputplumber-autostart.hwdb` with
`dmi:` modalias matches that set `USE_INPUTPLUMBER=1`, and
`/usr/lib/udev/rules.d/90-inputplumber-autostart.rules`:

```
ENV{USE_INPUTPLUMBER}=="1", TAG+="uaccess", TAG+="systemd", ENV{SYSTEMD_WANTS}+="inputplumber.service"
```

The property is `USE_INPUTPLUMBER`, not `ID_INPUT_PLUMBER`. The X20 line
from PR #756 is `dmi:*svnASUS:*rnRC74XA:*`. The stock 0.78.0 package has the
same rule but no X20 line. (`59-inputplumber.hwdb` is a different file: it
holds keyboard scancode fixes and `ID_INPUT_UNIFIED`, nothing for the X20.)

## 3. What we add

| File | When | Why |
|---|---|---|
| `/etc/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml` | always, if stock InputPlumber exists | Uses one of two sources. With a stock daemon ≥ 0.82.0, or when the fallback build is active, it is the verbatim upstream profile ([overlay](../overlay/inputplumber/devices.d/50-rog_xbox_ally_x20.yaml); a test checks the git blob hash). Otherwise it is [`50-rog_xbox_ally_x20.stock.yaml`](../overlay/inputplumber/devices.d/50-rog_xbox_ally_x20.stock.yaml). |
| `/etc/inputplumber/capability_maps.d/ally-x20-steamos-aly2.yaml` | with the stock-adapted profile | upstream v0.83.0 `ally_type2.yaml` under id `ally_x20_steamos_aly2` |
| `/etc/udev/hwdb.d/60-ally-x20-steamos-inputplumber.hwdb` | always, if stock InputPlumber exists | autostart entry from PR #756 |
| `/etc/systemd/system/inputplumber.service.d/50-ally-x20-steamos.conf` | fallback only | `ExecStart=` reset to our build, `XDG_DATA_DIRS` set to its data |

The stock-adapted profile differs from upstream in two places only:

1. The IMU matrix moves under `iio:` and is converted to the old axis
   convention: old = Lᵀ·new = `x: [-1,0,0]`, `y: [0,-1,0]`, `z: [0,0,-1]`.
   This is the 0.78.0 ROG Ally X matrix (`[1,0,0],[0,-1,0],[0,0,-1]`) with x
   flipped, which matches how the upstream X20 and Ally X matrices differ.
   **TODO(hw)**: verify on a real X20, for example with the Steam controller
   gyro test.
2. `capability_map_id: ally_x20_steamos_aly2`, so it gets the corrected
   button map on a 0.78.0 daemon.

After installing the files, `apply` runs these steps on a live system. It
skips them for `--root`/`--slot` prefixes.

1. `systemd-hwdb update`
2. `udevadm trigger --action=change --subsystem-match=dmi`
3. `systemctl daemon-reload`, only when the fallback drop-in is installed.
4. If the unit is already enabled (stock SteamOS), `systemctl restart inputplumber.service`. Otherwise `systemctl enable --now inputplumber.service`, and a marker in `/var/lib/ally-x20-steamos/inputplumber/` records that we enabled it, so removal disables it again. If a command is missing, apply logs a warning and continues.

**TODO(vm)**: `systemd-hwdb update` writes `/etc/udev/hwdb.bin`. If that
file did not exist before, it now shadows `/usr/lib/udev/hwdb.bin` and can
go stale after an A/B update unless `systemd-hwdb-update.service` refreshes
it. Measure this in the VM and record it in `docs/etc-survival.md`.

## 4. Probes and status

- `inputplumber_probe` returns:
  - `0` (superseded) if any file under stock `/usr/share/inputplumber/devices/` contains `RC74XA`;
  - `1` if none does;
  - `2` if that directory does not exist (status `n/a`, and apply installs nothing).
- `inputplumber_stock_version` checks, in order:
  - the fixture marker `/usr/share/inputplumber/VERSION`;
  - `/usr/bin/inputplumber --version`, on a live system only;
  - the pacman local db, `/usr/lib/holo/pacmandb/local` (**TODO(vm)**: confirm this is SteamOS's location) or `/var/lib/pacman/local`.

  It prints `X.Y.Z`.
- `inputplumber_probe_daemon_version` returns `0` if the stock daemon is
  ≥ 0.78.0, the oldest daemon the adapted profile is written for. It returns
  `1` if the daemon is older, which selects the fallback, and `2` if the
  version is unknown, which does not select the fallback.

When the probe reports `superseded`, apply still runs but warns. Our `/etc`
copy shadows the stock profile until you run
`ally-x20-steamos uninstall --superseded`.

## 5. Fallback: our own upstream build

The fallback is used only when `AX20_INPUTPLUMBER_FALLBACK=1` is set or the
stock daemon is older than 0.78.0. It also needs a build to exist. If one is
missing, apply warns and keeps the stock daemon.

```sh
build/build-inputplumber.sh            # podman (default), docker, or --engine host
AX20_INPUTPLUMBER_FALLBACK=1 ally-x20-steamos apply
```

The build script works like this:

- **Source:** it clones tag **v0.83.1** and refuses to build unless the tag
  resolves to commit `b2fb4090…`. It then applies any `patches/inputplumber/*.patch`.
- **Build:** it runs `cargo build --release --locked` in `rust:1.92-bookworm`,
  the same Rust as upstream's Dockerfile, with `libclang-dev` and
  `libudev-dev` installed.
- **Output:** it installs `bin/inputplumber`, `share/inputplumber/` and a
  `BUILD-INFO` file (tag, commit, toolchain, sha256, date) into
  `/opt/ally-x20-steamos/inputplumber/`, replacing the previous build atomically.

The location comes from one variable, `AX20_INPUTPLUMBER_OPT_REL`. It can
move under `/var/lib/ally-x20-steamos/` if `/opt` turns out not to be
persistent (**TODO(vm)**, plan §5.1b).

The drop-in keeps the stock unit's arguments (there are none) and changes only
`ExecStart` and `XDG_DATA_DIRS`. The D-Bus policy, polkit rules and udev rules
stay stock. Removing the drop-in and running `systemctl daemon-reload` and
`systemctl restart inputplumber` brings back the stock daemon.

## 6. How to verify (VM check 5 / on the X20)

```sh
systemctl status inputplumber.service
journalctl -u inputplumber -b | grep -iE 'x20|RC74XA|Found a matching|Failed to parse'
inputplumber devices          # expect "ASUS ROG Xbox Ally X20"
busctl tree org.shadowblip.InputPlumber
udevadm info /sys/class/dmi/id | grep USE_INPUTPLUMBER   # expect USE_INPUTPLUMBER=1
cat /sys/class/dmi/id/{sys_vendor,board_name}             # TODO(hw): expect "ASUS" / "RC74XA"
ally-x20-steamos status
```

In the VM, inject `-smbios type=1,manufacturer=ASUS -smbios type=2,product=RC74XA`
so the DMI match fires. Run the fallback path once with
`AX20_INPUTPLUMBER_FALLBACK=1`, and check that `systemctl show -p ExecStart
inputplumber` points into `/opt/ally-x20-steamos/inputplumber/`.

## 7. How to remove

`ally-x20-steamos uninstall` (or `uninstall --superseded` once the probe
says so) removes exactly the files listed above via the manifest. If we
enabled the unit, the `inputplumber_remove` hook disables it again. Then run:

```sh
systemd-hwdb update
systemctl daemon-reload
systemctl restart inputplumber.service
```

The fallback build in `/opt/ally-x20-steamos/inputplumber/` is a cache and
can be deleted with `rm -rf`.
