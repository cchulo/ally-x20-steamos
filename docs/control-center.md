# Control Center (design, first slice)

A controller-driven panel for Game Mode that shows the state of
ally-x20-steamos and updates it, so that nobody has to switch to Desktop
Mode or ssh in for `self-update`.

**Status of this page: design plus a first slice of code. Nothing here has
run on an X20.** Every statement about the device is marked `TODO(hw)`.
What exists, and how far it was tested, is in the table below; everything
else on this page is a plan.

| part | state |
|---|---|
| `controlcenter` component: root helper + sudoers drop-in | implemented, bats-tested on fixture roots (macOS; the real `visudo` accepts the drop-in). Not run on SteamOS. |
| opt-in components (`COMPONENT_OPT_IN=1`, status `off`) | implemented, bats-tested |
| UI (`ui/control-center/`): Home and Update screens, controller/keyboard focus | builds (`npm run build`); runs in a browser against a mock. Never shown on the device, never run under gamescope. |
| Tauri shell (`ui/control-center/src-tauri/`) | compiles on macOS (`cargo check`). No Linux build, no AppImage yet. |
| opening it from the Armoury Crate button, overlay over a running game | designed only (section 2) |
| packaging, installing the UI from the CLI, adding it to Steam | designed only (sections 1, 5) |

Contents: [1 stack](#1-stack) · [2 Game Mode](#2-how-it-appears-in-game-mode) ·
[3 architecture](#3-architecture) · [4 security](#4-security-of-the-privileged-path) ·
[5 roadmap](#5-scope-and-roadmap) · [6 open questions](#6-open-questions-for-the-owner) ·
[sources](#sources)

## 1. Stack

### What SteamOS gives us

- Tauri v2 on Linux links against WebKitGTK **4.1** (`libwebkit2gtk-4.1.so.0`) [T1].
- The SteamOS image does not contain it. A report from a Steam Deck on
  SteamOS 3.9.2 (2026-10): "libwebkit2gtk-4.1.so.0 was missing" [S1]; a
  third-party README says the same without naming a version [S2]. The
  package exists in Valve's pacman repository for 3.9
  (`webkit2gtk-4.1-2.52.5-2`) [S3], but installing it means writing to
  `/usr`, which this project never does (and a SteamOS update would remove
  it again).
- So a bare Tauri binary (2–6 MB [T2]) **cannot run on stock SteamOS**. The
  WebView has to come with the app.
- `TODO(hw)`: confirm on the X20 with `pacman -Q webkit2gtk-4.1 fuse2`.

### Options

| option | download | brings its own web engine | works under gamescope | controller input | verdict |
|---|---|---|---|---|---|
| **Tauri v2 AppImage** (React + TS) | 70+ MB [T2] | yes: the bundler copies WebKitGTK's processes and libraries into the AppImage [T3] | **unknown**: no report found of a Tauri app in Game Mode; the documented workarounds for blank windows (`WEBKIT_DISABLE_DMABUF_RENDERER=1`, then `WEBKIT_DISABLE_COMPOSITING_MODE=1`) are written for NVIDIA/Wayland [T4] | **unknown**: WebKitGTK's Gamepad API is built on libmanette [W1]; a "does not work" bug was fixed in 2024 [W2], another (axes but no buttons) is open [W3]. Fallback: read the pad in Rust with `gilrs` and send events to the page (a plugin doing this exists [T5]) | **recommended, with a device gate** (below) |
| Tauri v2 Flatpak | app small, but needs the GNOME runtime: about 400 MB download, 1 GB installed (figure for runtime 48 [F1]) | yes (runtime) [T6] | unknown; sandbox needs `--device=input` for pads [T7] and cannot run `sudo` without `flatpak-spawn --host` | as above | rejected: bigger than Electron, and the sandbox is in the way of the helper |
| **Electron AppImage** (same React UI) | 131 MB (hhd-ui v3.4.2, the closest comparable app) [H1] | yes (Chromium) | **yes, proven**: this is what Handheld Daemon ships [H2] | Chromium's Gamepad API works; HHD additionally feeds events over stdin [H3] | **fallback** if the gate fails |
| Decky plugin | under 1 MB | uses Steam's own CEF | yes | Steam's own focus system | rejected for now: needs Decky Loader installed, which "sometimes … disappear[s] on SteamOS updates" [D1]; a `root` plugin flag gives the whole plugin root [D2], which is a weaker boundary than the helper |
| local web server + a browser | under 1 MB + a browser | no | no source found for using Steam's browser this way | unknown | rejected: an HTTP port that can trigger root operations is a larger attack surface than a child process, for no gain |

### Recommendation

**Tauri v2 + React + TypeScript (Vite), shipped as an AppImage**, about
70 MB, roughly half of Electron. It is what the owner asked for and it is
feasible on paper, but two things are unproven and both can only be answered
on the device:

1. does a WebKitGTK window render under gamescope on the X20's AMD GPU, and
2. does the page receive controller input there.

So the first hardware session runs this gate before more is built on Tauri:

| check (`TODO(hw)`) | pass | if it fails |
|---|---|---|
| AppImage starts from Desktop Mode | window with the panel | try `--appimage-extract-and-run` (no FUSE needed); note whether `fuse2` is in the image [S3][S4] |
| started as a non-Steam shortcut in Game Mode | panel visible, not black | set `WEBKIT_DISABLE_DMABUF_RENDERER=1`, then `WEBKIT_DISABLE_COMPOSITING_MODE=1` [T4] |
| D-pad moves the focus, A selects | works through `navigator.getGamepads()` | keyboard path: a Steam Input layout that sends arrow keys/Enter/Esc (the UI already handles those); or `gilrs` in the Rust shell |
| all three fail | | **switch the shell to Electron** |

Switching is cheap by construction: the React app talks to its shell only
through `src/backend.ts` (one function, `run(op)`). An Electron shell would
replace `src-tauri/` (120 lines of Rust) with a main process of similar
size; no screen changes.

Risks of the recommendation, plainly:

- **Unverified under gamescope** (above). This is the main risk.
- **AppImage needs FUSE 2 or extraction.** `fuse2` is in Valve's 3.9
  repository [S3] and an open request asks Valve to drop it [S4]; whether
  it is in the image is not confirmed. The launcher should therefore always
  use `--appimage-extract-and-run` or a one-time extraction into the state
  directory.
- **The AppImage must be built on Linux**, on the oldest distribution that
  has WebKitGTK 4.1, because the glibc of the build host becomes the
  minimum [T2]. That is a CI job this slice does not contain.
- **Transparent windows are unreliable on Linux** in Tauri [T8]. The first
  version does not use one (section 2).
- Tauri's "truly portable AppImage" rework is still a draft [T9]; the
  current bundle leans on host libraries for everything that is not
  WebKitGTK/GTK.

## 2. How it appears in Game Mode

### What gamescope does (read from its source)

gamescope decides what a window is from X11 properties
(`src/steamcompmgr.cpp` [G1]); all are `CARDINAL` values:

| property | set on | meaning |
|---|---|---|
| `STEAM_GAME` | window | app id of the window |
| `STEAM_OVERLAY` | window | this is an overlay; drawn above the game |
| `STEAM_INPUT_FOCUS` | window | 1: the overlay takes keyboard and pointer; 2: pointer only |
| `GAMESCOPE_EXTERNAL_OVERLAY` | window | a display-only layer below the Steam overlay and above the game |
| `_NET_WM_WINDOW_OPACITY` | window | opacity; used only for the two overlay kinds |
| `GAMESCOPECTRL_BASELAYER_APPID` | root | which app ids Steam wants in front |

Two facts decide the design:

- A `GAMESCOPE_EXTERNAL_OVERLAY` window **never gets input focus** (its app
  id is forced to 0 and it is skipped as a focus candidate) [G1]. It is what
  MangoHud's `mangoapp` uses to draw a HUD [M1]. An interactive panel cannot
  be built from it alone.
- Input focus goes only to a `STEAM_OVERLAY` window with a non-zero
  `STEAM_INPUT_FOCUS` [G1]. There is one such slot, and Steam's own overlay
  normally holds it.

### How Handheld Daemon does it

Read from hhd's source [H3][H4]:

- The daemon runs as **root** (`hhd@.service` has no `User=`) [H5]. It finds
  gamescope's X displays, starts the Electron UI as the user on the right
  one, and sets the properties itself: on show, `STEAM_OVERLAY=1` and
  `STEAM_INPUT_FOCUS=1` on its own window **and 0 on Steam's window**; on
  hide, it puts Steam's values back.
- The controller does not reach the UI through Steam. hhd owns the
  controller devices (it is the input daemon), and while the overlay is open
  it sends button events to the Electron process over stdin; the page's own
  Gamepad API is muted.
- OpenGamepadUI's overlay mode does the same property swap and gets its
  input from InputPlumber's intercept mode [O1].

That is: a working overlay needs (a) a process that rewrites properties on
Steam's window and (b) controller input taken away from the game while the
panel is open. On this device (b) means InputPlumber, see below.

### The button

Upstream InputPlumber's map for this device (`ally_type2.yaml`, used by
`50-rog_xbox_ally_x20.yaml`) [I1]:

| key from the keyboard device | button | mapped to |
|---|---|---|
| `KeyF16` | Armoury Crate, short press | gamepad button `Keyboard` |
| `KeyF21` | Armoury Crate, long press | `LeftPaddle2` |
| `KeyProg1` | Xbox/Library, short | `QuickAccess` |
| `KeyF22` | Xbox/Library, long | `QuickAccess2` |

- InputPlumber has **no "run a command" target** [I2]. What it has is a
  D-Bus target device (`…/devices/target/dbus0`) that emits
  `InputEvent(s event, d value)` signals (`ui_guide`, `ui_quick`, `ui_osk`,
  …) when a profile maps to `dbus:` or when intercept mode is on [I3][I4].
- So "open on the Armoury Crate button" is: a small listener on the system
  bus that reacts to one event and starts or raises the panel; plus, for a
  real overlay, turning intercept mode on while the panel is open so the
  game does not see the D-pad.
- `TODO(hw)`: what the **SteamOS-shipped** InputPlumber and this project's
  own profile (`overlay/inputplumber/`, [inputplumber.md](inputplumber.md))
  do with the Armoury Crate short press today, whether that press is free
  to take, whether changing intercept mode needs polkit authorisation for
  `deck`, and whether a `dbus:` mapping in our device profile is enough.
  The table above is upstream's file, not a measurement.

### What is realistic

| step | what the user gets | needs |
|---|---|---|
| **v1: a non-Steam shortcut** | "Control Center" in the Library (Non-Steam). Opens full-screen like a game; Steam Input gives it the controller. It **replaces** the running game on screen (a shortcut is a normal app, not an overlay), so it is used from the Library, not mid-game. | the AppImage on disk; `steamos-add-to-steam <path>` once, as `deck` (it refuses to run as root) [V1]. `TODO(hw)`: whether that can be done without Desktop Mode. |
| v2: the button opens it | Armoury Crate short press launches or focuses the shortcut | a user service listening for the InputPlumber D-Bus event; a way to start a shortcut from outside Steam (`steam://rungameid/…` for non-Steam shortcuts is reported as unreliable; unverified) |
| v3: overlay over the game | the left-docked panel over a running game, as in the reference | the hhd pattern: property swap on Steam's window, InputPlumber intercept mode, a transparent window. Touches Steam's own window state; highest risk. |

This slice builds towards v1. The panel is drawn left-docked already so
that v3 needs no redesign, but in v1 the area to its right is a plain
backdrop, not the game.

## 3. Architecture

```
 deck (unprivileged)                              root
┌──────────────────────────────┐   sudo -n    ┌─────────────────────────────────────────────┐
│ Control Center               │ ───────────▶ │ /etc/ally-x20-steamos/control-center-helper │
│  React UI  ── run(op) ──▶    │  one word    │   one word from a closed list               │
│  Tauri shell (Rust)          │ ◀─────────── │   checks ownership, cleans the environment  │
│  no network, no file access  │ stdout/stderr│   exec ally-x20-steamos.sh <fixed arguments>│
└──────────────────────────────┘  exit status └─────────────────────────────────────────────┘
```

### The three ways to cross to root

| | (a) sudo + root-owned helper + NOPASSWD drop-in | (b) polkit (`pkexec` + rule) | (c) root daemon on a socket |
|---|---|---|---|
| new privileged code | one POSIX sh file, about 100 lines | the same helper, plus a JavaScript rule | a long-running service, a protocol, peer-credential checks |
| files under `/usr` | none | a named action needs a policy file under `/usr/share/polkit-1/actions` (read-only here; from memory, not checked on SteamOS). Without it the rule has to match the generic `org.freedesktop.policykit.exec` action by program path | none |
| who may call | the user named in the drop-in | can be limited to the *active local session* (better than (a): an ssh login as `deck` would not qualify) | whoever can open the socket (mode/group) |
| arguments | sudo itself matches the full command line | passed through; the helper must check | parsed by our own code |
| running when idle | nothing | nothing | a root process, always |
| failure mode | a broken drop-in can lock sudo: prevented by `visudo -cf` before install | a broken rule is ignored | a bug is a root bug at all times |
| tested with stubs | yes (`sudo`, `visudo` are plain commands) | harder (needs polkitd) | needs a harness |

**Chosen: (a)**, as the owner leaned. It is the smallest amount of
privileged code, sudo does half of the argument checking, and nothing runs
when the panel is closed. (b) is the alternative worth revisiting if the
"any process of `deck`, including an ssh session" scope of sudo turns out
to matter; the helper would stay as it is. (c) is rejected: most code,
always-on.

### Command surface

The whole interface between UI and root. Nothing else exists.

```
sudo -n /etc/ally-x20-steamos/control-center-helper <operation>
```

| operation | runs (as root, clean environment) | changes the system | output |
|---|---|---|---|
| `status` | `ally-x20-steamos status --json` | rewrites `state/status.json` only | one JSON document (shape: `lib/status.sh`) |
| `check` | `ally-x20-steamos self-update --check` | `git fetch`; writes `state/last-update-check` | one line of text; exit 3 = offline |
| `update` | `ally-x20-steamos self-update` | checks out the newest release **signed by a pinned key**, runs migrations and `apply`, stages modules | log lines; "updated to vX" or "already up to date" |
| `apply` | `ally-x20-steamos apply` | re-installs the files of the enabled components | log lines |
| `rollback` | `ally-x20-steamos self-update --rollback` | checks out the commit recorded before the last update, then `apply` | log lines |

- Exit status: the CLI's own. The helper's refusals are 64 (not exactly one
  known word), 69 (CLI missing), 75 (another changing operation is
  running), 77 (not root, or unsafe ownership/mode).
- stdout and stderr are the CLI's, unmodified; the UI shows them in its log.
- `update`, `apply` and `rollback` take a lock (`flock`) so two cannot run
  at once.
- **Reboot is not in the list.** The session user can already reboot
  without a password (`systemctl reboot` through logind, as Steam's own
  power menu does; `TODO(hw)` to confirm from Game Mode), so it does not
  need root and does not belong in the privileged surface.
- `status` does not strictly need root either (the CLI and `status.json`
  are world-readable). It is in the helper so the UI has one path; it can
  move out later.

## 4. Security of the privileged path

### What is installed

| path | owner, mode | role |
|---|---|---|
| `/etc/ally-x20-steamos/control-center-helper` | root:root 0755 | the helper (`overlay/bin/control-center-helper`) |
| `/etc/sudoers.d/zz-ally-x20-steamos-control-center` | root:root 0440 | the rule |

The rule, complete (comments left out):

```
Cmnd_Alias AX20_CONTROL_CENTER = /etc/ally-x20-steamos/control-center-helper status, /etc/ally-x20-steamos/control-center-helper check, /etc/ally-x20-steamos/control-center-helper update, /etc/ally-x20-steamos/control-center-helper apply, /etc/ally-x20-steamos/control-center-helper rollback
Defaults!AX20_CONTROL_CENTER env_reset, !setenv, secure_path="/usr/bin:/usr/sbin:/bin:/sbin"
deck ALL=(root) NOPASSWD: AX20_CONTROL_CENTER
```

### Requirements and how each is met

| requirement | how | checked by |
|---|---|---|
| Only a fixed list of operations | The helper compares its single argument against five words and replaces it with constants (`set -- self-update --check`) before anything is executed. | bats: each word maps to its command line; 20 other inputs are refused |
| sudo allows no extra arguments | Each sudoers entry is the helper path **plus one word**. In sudoers, a command given with arguments matches only that exact argument list; a bare path would allow any. No wildcards. | bats: file content compared; no `*`, `?`, `[`; every mention of the helper is followed by exactly one word; list equals the helper's list |
| No user-controlled string reaches a shell | The argument is never expanded into a command, never passed to the CLI, never logged. The helper has no `eval` and sources nothing. The Rust side starts `sudo` with an argument vector (no shell) and also picks the word from its own constants. | bats: `status; id`, `$(id)`, backticks, `--root /`, newline, extra arguments → exit 64 and the CLI is not started; `cargo test` for the Rust list |
| Clean environment and PATH | sudo: `env_reset`, `!setenv`, `secure_path`. Helper: sets `PATH` and `IFS` first, uses absolute paths for every tool, and starts the CLI with `env -i PATH=… HOME=/root LANG=C LC_ALL=C`. `AX20_ROOT`, `AX20_SRC`, `AX20_DRY_RUN`, `BASH_ENV`, `LD_PRELOAD`, `GIT_DIR` … never arrive. | bats: the CLI stand-in dumps its environment; none of 12 planted variables is in it |
| The helper cannot be reconfigured | Its paths are constants in the file. There is no option, no config file, no environment switch (the tests run a copy with the constant lines rewritten; the shipped file is also tested, with the same variables planted in the environment). | bats |
| Everything it executes is root-owned and not writable by `deck` | At every call, before running anything: each directory from the checkout up to `/` (on the **real** path, because `/var/lib/ally-x20-steamos` is a symlink into `/home/.ally-x20-steamos`), every file and directory inside the checkout including `.git`, and the pinned keys must be owned by root and not group- or world-writable. Otherwise exit 77. | bats: group-writable file, world-writable file, writable directory inside and above, writable key, symlinked state directory |
| `self-update` keeps signed-tag verification | `update` is plain `self-update`: the same code path as on the command line, against the keys pinned in `/var/lib/ally-x20-steamos/keys`. `--insecure-skip-verify`, `--channel` and `--no-apply` cannot be passed (exit 64). | bats: `update --insecure-skip-verify` → 64 |
| Every call is recorded | `logger -t ally-x20-steamos-control-center`: operation, `SUDO_USER`/`SUDO_UID`, and refusals. Read with `journalctl -t ally-x20-steamos-control-center`. | bats (stub logger) |
| A bad drop-in can never lock sudo | Below. | bats |

### What must hold on the device (ownership model)

Checked in the code, not on a device:

- `install` requires root (`require_root`), creates
  `/var/lib/ally-x20-steamos` → `/home/.ally-x20-steamos` and the subdirectories
  with `mkdir` as root, and clones the checkout into `…/src` with `git` as
  root (`cmd/install.sh`, `lib/selfupdate.sh`). `self-update` runs `git`
  as root in that checkout. So the tree is root-owned with root's umask
  (022) **by construction**.
- `/etc/ally-x20-steamos/` is created by `apply` as root; `/etc` on SteamOS
  is an overlay whose upper directory is under `/var/lib/overlays/etc/upper`.
- `TODO(hw)`: confirm with
  `stat -c '%U:%G %a %n' / /home /home/.ally-x20-steamos /home/.ally-x20-steamos/src /etc/ally-x20-steamos /etc/sudoers.d`
  and `find /home/.ally-x20-steamos/src /home/.ally-x20-steamos/keys ! -user root -o -perm /022`
  (expected: all `root:root`, 755 or stricter; the `find` prints nothing).
  In particular that `/home` itself is `root:root 755`.
- The helper does not rely on this being true: it checks at every call and
  refuses (77) if it is not. An installation that fails the check is not
  made "safe" by the helper, it is simply not usable from the UI until
  fixed (`sudo chown -R root:root`, or re-install).
- Known gap: the check covers the checkout and the keys, not the rest of
  the state directory (`state/`, `modules/`, `cache/`). Those are also
  created by root; `deck` cannot replace them because the directory above
  is checked. A later version can extend the `find`.

### What an attacker with the `deck` account gains

Any process running as `deck` (a game, a browser, a Decky plugin, an ssh
login) can, without the password:

- read the status (public anyway);
- make the device fetch from the project's git remote (`check`);
- install the newest release **that is signed by a key pinned on the
  device** (`update`). It cannot choose the version, the remote, the
  channel or the keys, and cannot skip verification;
- re-apply the installed components (`apply`), which is idempotent;
- switch to the version recorded before the last update (`rollback`), and
  back again. That is a one-step downgrade to code that was installed on
  this device before; it is the worst item on this list (an old release
  with a known bug could be brought back). It cannot reach older versions:
  each rollback swaps the same two commits;
- do any of these repeatedly (wasting time and flash writes; changing
  operations are serialised by the lock).

It **cannot** run another command as root, pass options, point the CLI at
another root (`--root`), another checkout or other keys, or change the
helper, the rule, the checkout or the keys (all root-owned and checked).

Honest limits:

- This is only as strong as `ally-x20-steamos` itself. A bug in `apply` or
  `self-update` that is reachable **without arguments and with a clean
  environment** is reachable through the helper. The surface is those five
  code paths.
- If the update channel was set to `beta` on the device (by root, earlier),
  `update` follows `beta`, where signatures are optional
  ([self-update.md](self-update.md)). The helper cannot change the channel;
  it also does not force `stable`. Open question 4.
- `deck` is in `wheel`. Whoever knows the `deck` password is root anyway;
  the drop-in adds nothing for them. It matters for code that runs as
  `deck` *without* knowing the password.
- sudo's rule cannot tell the UI from any other process of `deck`. polkit
  could restrict to the active local session (section 3).

### The drop-in cannot lock sudo

A sudoers file with a syntax error makes `sudo` refuse to run at all, and
on a device without a root password that is hard to recover from. So:

1. The drop-in is a **static file** in the repository
   (`overlay/sudoers.d/…`), not generated. CI runs the real `visudo -cf`
   on it wherever `visudo` exists.
2. `controlcenter_apply` runs `visudo -cf <source file>` **before** copying.
   No `visudo`, or a non-zero result: nothing is written to
   `/etc/sudoers.d` and the component fails. (This is why the drop-in is
   not in `controlcenter_files`: that list is copied before `_apply` runs.)
3. The copy is atomic (`manifest_install_file`: temp file, `chmod 0440`,
   `fsync`, rename). The temp name contains a dot, and sudo skips files
   with a dot in the name, so a half-written file is never read.
4. On a live system `visudo -c` then checks the whole configuration as sudo
   will read it (all files, owner, mode). If that fails, the drop-in is
   removed again and the component fails.
5. Two properties of the **file name** matter and are tested: no dot (or
   sudo ignores the file), and it sorts after `wheel`. sudo applies the
   **last** matching rule; SteamOS's `%wheel ALL=(ALL) ALL` asks for a
   password, and if it came later it would win and the helper would prompt.
   `TODO(hw)`: list `/etc/sudoers.d` on the device and confirm nothing
   sorts after `zz-ally-x20-steamos-control-center`, and that
   `/etc/sudoers` has `@includedir /etc/sudoers.d`.

### Surviving SteamOS updates

- Both files are under `/etc` and in the manifest, like every other
  component's files. The expectation in [etc-survival.md](etc-survival.md)
  is that the `/etc` overlay's upper directory is copied to the new slot;
  that page is still `TODO(vm)`, so this is **not measured**.
- Independent of that, the RAUC post-install handler runs
  `apply --slot <new slot>`, and the boot service runs
  `apply --missing-only`. Both re-install an opt-in component **once it
  has been installed** (it has manifest entries), and both go through
  `controlcenter_apply`, so the `visudo -cf` check runs again each time.
- With `apply --slot` the live-configuration check (step 4) is skipped,
  because the slot is not the running system; the source-file check is not.
- `uninstall --component controlcenter` removes the rule first, then the
  helper (newest manifest entry first).

### Opt-in

The component is **not installed by default**. `COMPONENT_OPT_IN=1`
(new in `lib/component.sh`) makes a plain `apply`, `install`, the boot
service and the update handlers skip it until it has been installed once:

```sh
sudo ./ally-x20-steamos.sh apply --only controlcenter      # turn on
sudo ./ally-x20-steamos.sh uninstall --component controlcenter   # turn off
```

`status` shows `off` for an opt-in component that is not installed. The UI
cannot turn it on by itself (it has no way to become root without it),
which is intended: a passwordless sudo rule should be a decision made once,
with the password.

## 5. Scope and roadmap

### First version

- Home: version, running kernel, whether patched modules are staged, update
  policy, one tile per component with its status.
- Update: check, update, apply, rollback, with the CLI's output as it runs.
  Update and rollback ask for a second press. B does not leave while an
  operation runs.
- Missing for a usable v1: the Linux build and AppImage (CI), a CLI command
  that downloads/places the AppImage and adds the shortcut, the device gate
  of section 1, a "reboot now" prompt after an update that needs one.

### Later

| feature | CLI today | machine-readable today | needed |
|---|---|---|---|
| project status | `status` | **`--json`** | nothing |
| drift report | `audit` | **`--json`** | a helper operation |
| update check | `self-update --check` | text; result also in `state/last-update-check` and in `status --json` (`last_update_check`) | fine as is |
| update / apply / rollback | `self-update`, `apply` | log text, exit status | progress as JSON lines would allow a progress bar |
| "has stock caught up?" | `probe` | text | `--json` |
| power profile, TDP slider on/off | `power` | text | `--json` for reading; **setting takes an argument**, so the helper needs a closed list per value (e.g. `power-tdp-slider-on`), never a free string |
| Xbox-button light | `xbox-led on|off|brightness 0-3|breathe on|off` | text | same: one helper word per allowed value |
| update policy | `update-policy block|degrade` | text | same |
| SD Express format | `sdexpress format` | text | probably never from the UI (destructive) |
| surround profile, button layout | no CLI yet | | design first |

The rule for growing the helper: **one word per allowed action, each
listed in the sudoers alias**; a value that cannot be enumerated (free
text, paths) does not go through the helper. A test already fails if the
helper's list and the sudoers list differ.

## 6. Open questions for the owner

1. **Tauri with the device gate, or Electron straight away?** Tauri is
   ~70 MB against ~130 MB and matches the request, but is unproven under
   gamescope; Electron is proven by HHD. The UI code is the same.
2. **Turn the component on by default later?** Now it is opt-in. Default-on
   would put a NOPASSWD rule on every install.
3. **Is `rollback` wanted in the passwordless set?** It is the one
   operation that lets a `deck` process downgrade (one step). It could
   stay CLI-only.
4. **Should `update` through the helper force the stable channel**, even
   when the device is set to beta?
5. **`deck` hard-coded in the rule.** SteamOS's user is always `deck`; a
   static file is what allows checking it in CI. A different user name
   would need a rendered file.
6. **Which press opens it?** Armoury Crate short press (`KeyF16`) looks
   free upstream; what this project's own profile does with it must be
   checked against [inputplumber.md](inputplumber.md) and on the device.
7. **Name.** "Control Center" is used here; the product name of the ASUS
   software is deliberately not.

## Sources

Read on 2026-11-20. "Read from source" means the file was read at the
linked revision; nothing below was verified on an X20.

Tauri / WebKitGTK
- [T1] Tauri 2.0 alpha 3 notes (WebKitGTK 4.1): <https://v2.tauri.app/blog/tauri-2-0-0-alpha-3/>
- [T2] Tauri AppImage guide (size "2-6 MB … to 70+ MB", glibc of the build host): <https://v2.tauri.app/distribute/appimage/>
- [T3] Tauri bundler, AppImage (copies WebKit processes): <https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-bundler/src/bundle/linux/appimage/linuxdeploy.rs>
- [T4] Tauri, Linux graphics workarounds: <https://v2.tauri.app/develop/debug/linux-graphics/>
- [T5] gilrs-based gamepad plugin for Tauri 2: <https://github.com/DeveloperMindset-com/tauri-plugin-gamepad>
- [T6] Tauri Flatpak guide: <https://v2.tauri.app/distribute/flatpak/>
- [T7] A Tauri Flatpak needing `--device=input`: <https://github.com/PhilipK/BoilR/pull/523>
- [T8] Transparent window bug on Linux: <https://github.com/tauri-apps/tauri/issues/14924>
- [T9] Portable AppImage rework (draft): <https://github.com/tauri-apps/tauri/pull/12491>
- [W1] WebKitGTK gamepad support uses libmanette: <https://lore.kernel.org/all/20220823203346.AAB3287BEE@busybox.osuosl.org/T/>; Arch package dependency: <https://archlinux.org/packages/extra/x86_64/webkit2gtk-4.1/>
- [W2] WebKit bug 258264, "[GTK] gamepad API does not work" (fixed 2024-01): <https://bugs.webkit.org/show_bug.cgi?id=258264>
- [W3] WebKit bug 298310 (axes but no button events): <https://bugs.webkit.org/show_bug.cgi?id=298310>
- [F1] GNOME runtime 48 size (forum post): <https://www.kubuntuforums.net/forum/current-supported-releases/kubuntu-25-04-plucky-puffin/688504-gnome-application-platform-version-48-fails-to-install>

SteamOS
- [S1] Missing `libwebkit2gtk-4.1.so.0` on SteamOS 3.9.2: <https://github.com/openOMSI-org/openOMSI/issues/2458>
- [S2] "SteamOS does not include `webkit2gtk-4.1`": <https://github.com/jdros15/Cirnodeck>
- [S3] Valve package repository for 3.9 (`webkit2gtk-4.1`, `fuse2`): <https://steamdeck-packages.steamos.cloud/archlinux-mirror/extra-3.9/os/x86_64/>
- [S4] Request to drop fuse2: <https://github.com/ValveSoftware/SteamOS/issues/2391>
- [V1] `steamos-add-to-steam` (mirror of the script): <https://gitlab.com/evlaV/steamdeck-kde-presets/-/raw/master/usr/bin/steamos-add-to-steam>

gamescope, overlays
- [G1] gamescope `src/steamcompmgr.cpp` at 3738994 (property names, focus rules): <https://github.com/ValveSoftware/gamescope/blob/3738994fd253a1c775821625a2c20beb4f879f16/src/steamcompmgr.cpp>
- [M1] MangoHud `mangoapp`: <https://github.com/flightlessmango/MangoHud/blob/master/src/app/main.cpp>
- [O1] OpenGamepadUI overlay mode: <https://github.com/ShadowBlip/OpenGamepadUI/blob/main/core/ui/card_ui_overlay_mode/card_ui_overlay_mode.gd>

Handheld Daemon
- [H1] hhd-ui release v3.4.2, `hhd-ui.AppImage` 131.2 MB: <https://github.com/hhd-dev/hhd-ui/releases/latest>
- [H2] hhd-ui is React + Vite in Electron: <https://github.com/hhd-dev/hhd-ui/blob/main/package.json>, <https://github.com/hhd-dev/hhd-ui/blob/main/electron/main.js>
- [H3] hhd overlay plugin at fd72e75 (`x11.py`, `overlay.py`, `controllers.py`, `base.py`): <https://github.com/hhd-dev/hhd/tree/fd72e7550e4f13b98678b63566d5d51f00f2464f/src/hhd/plugins/overlay>
- [H4] hhd installer (AppImage to `~/.local/bin/hhd-ui`; refuses SteamOS by default): <https://github.com/hhd-dev/hhd/blob/master/install.sh>
- [H5] `hhd@.service`: <https://github.com/hhd-dev/hhd/blob/master/usr/lib/systemd/system/hhd@.service>

InputPlumber (at 0f4b199)
- [I1] `ally_type2.yaml`, `50-rog_xbox_ally_x20.yaml`: <https://github.com/ShadowBlip/InputPlumber/tree/0f4b1995e9427463ac8af68ddcf316d07ca8a4dd/rootfs/usr/share/inputplumber>
- [I2] target device list: <https://github.com/ShadowBlip/InputPlumber/blob/0f4b1995e9427463ac8af68ddcf316d07ca8a4dd/src/input/target/mod.rs>
- [I3] D-Bus target device: <https://github.com/ShadowBlip/InputPlumber/blob/0f4b1995e9427463ac8af68ddcf316d07ca8a4dd/docs/dbus-interface/target_dbus.md>
- [I4] intercept mode: <https://github.com/ShadowBlip/InputPlumber/blob/0f4b1995e9427463ac8af68ddcf316d07ca8a4dd/docs/usage.md>

Decky
- [D1] Decky Loader README: <https://github.com/SteamDeckHomebrew/decky-loader/blob/main/README.md>
- [D2] Decky plugin flags (`root`): <https://wiki.deckbrew.xyz/plugin-dev/getting-started>

sudo
- sudoers(5), "Sudoers file format" (last match wins; arguments in a command specification; `@includedir` skips names with a `.`): <https://www.sudo.ws/docs/man/sudoers.man/>
