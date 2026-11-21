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
| UI (`ui/control-center/`): Home and Update screens, controller/keyboard focus, partial-update display | builds (`npm run build`); runs in a browser against a mock. Never shown on the device, never run under gamescope. |
| Electron shell (`ui/control-center/electron/`) | type-checks and compiles; the operation whitelist has unit tests (`npm test`). A Linux x64 AppImage was built once on a macOS host (123 MB) and **never started**: no window has been opened anywhere. |
| opening it from the Armoury Crate button, overlay over a running game | designed only (section 2) |
| packaging, installing the UI from the CLI, adding it to Steam | designed only (sections 1, 5) |

Contents: [1 stack](#1-stack) · [2 Game Mode](#2-how-it-appears-in-game-mode) ·
[3 architecture](#3-architecture) · [4 security](#4-security-of-the-privileged-path) ·
[5 roadmap](#5-scope-and-roadmap) · [6 decisions](#6-decisions) · [7 open questions](#7-open-questions) ·
[sources](#sources)

## 1. Stack

### Decision

**Electron + React + TypeScript (Vite), shipped as an AppImage.** The owner
decided this on 2026-11-20: "Let's just use what is already proven." It is
the stack Handheld Daemon ships for the same job on the same kind of device
[H1][H2].

| | |
|---|---|
| size | **123 MB** for the AppImage built from this branch (Electron 45, x64; built on a macOS host, never started). hhd-ui v3.4.2 is 131 MB [H1]. |
| web engine | Chromium, inside the AppImage. Nothing is needed from SteamOS's read-only `/usr`. |
| under gamescope | proven by HHD: a fullscreen Electron window; HHD's main process adds no Chromium switches [H2]. Not yet tried with **this** app. |
| controller | Chromium's Gamepad API, which the UI already uses (`src/nav.ts`). HHD additionally feeds events over stdin when it runs as an overlay [H3]; not needed for a full-screen app that Steam Input drives. |
| shell code | `electron/main.ts`, `electron/preload.ts`, `electron/operations.ts`, about 250 lines together |

Risks, plainly:

- **Size.** About 120 to 130 MB to download and keep on disk. Accepted with
  the decision.
- **AppImage needs FUSE 2 or extraction.** `fuse2` is in Valve's 3.9
  package repository [S3] and an open request asks Valve to drop it [S4];
  whether it is in the image is not confirmed. The launcher should
  therefore use `--appimage-extract-and-run` or a one-time extraction into
  the state directory. `TODO(hw)`: `pacman -Q fuse2`.
- **Chromium's sandbox inside an AppImage.** An AppImage cannot carry the
  setuid `chrome-sandbox` helper, so the renderer sandbox depends on
  unprivileged user namespaces. Steam's own runtime and Flatpak rely on
  them too, so they are expected to be available. `TODO(hw)`: confirm the
  app starts **without** `--no-sandbox`; if it only starts with that flag,
  the page loses one layer of isolation (the helper boundary is unaffected).
- **Electron releases move fast** (a new major about every eight weeks);
  the bundled Chromium has to be updated with the app. The page loads no
  remote content, which removes most of the usual exposure.
- **Not started anywhere yet.** The AppImage built once; nobody has seen
  the window.

### The alternative that was considered first: Tauri

Tauri v2 (Rust shell, system WebView) was the first recommendation because
it is smaller. It is recorded here because the owner asked for the
comparison; the first commit of this branch contains that scaffold.

- Tauri v2 on Linux links against WebKitGTK **4.1** [T1]. SteamOS does not
  ship it: "libwebkit2gtk-4.1.so.0 was missing" on SteamOS 3.9.2 [S1], and
  [S2] says the same. The package is in Valve's repository [S3] but
  installing it means writing to `/usr`.
- So only the AppImage form works, which bundles WebKitGTK [T3]: "70+ MB"
  per Tauri's documentation [T2], about half of Electron.
- Unproven, and only answerable on the device: no report was found of a
  Tauri app in Game Mode; the documented fixes for blank WebKitGTK windows
  target NVIDIA/Wayland [T4]; WebKitGTK's Gamepad API (libmanette [W1]) has
  one fixed [W2] and one open bug [W3]; transparent windows are unreliable
  on Linux [T8].
- Verdict: about 50 MB smaller, at the cost of two unknowns that could each
  end in "switch to Electron anyway". Rejected in favor of what is proven.

### Other options

| option | why not |
|---|---|
| Tauri as a Flatpak | needs the GNOME runtime (about 400 MB download for runtime 48 [F1]) [T6]; the sandbox needs `--device=input` for controllers [T7] and is in the way of `sudo` |
| Decky plugin | needs Decky Loader installed, which "sometimes … disappear[s] on SteamOS updates" [D1]; a `root` plugin flag gives the whole plugin root [D2], a weaker boundary than the helper |
| local web server + a browser | an HTTP port that can trigger root operations is a larger attack surface than a child process; no source found for using Steam's browser this way |

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
- HHD's Electron window in overlay mode is fullscreen and `transparent: true`
  [H2]; transparency is what a v3 overlay here would need too.

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
  to take, whether changing intercept mode needs polkit authorization for
  `deck`, and whether a `dbus:` mapping in our device profile is enough.
  The table above is upstream's file, not a measurement.

### What is realistic

| step | what the user gets | needs |
|---|---|---|
| **v1: a non-Steam shortcut** | "Control Center" in the Library (Non-Steam). Opens full-screen like a game; Steam Input gives it the controller, which Chromium's Gamepad API reads. It **replaces** the running game on screen (a shortcut is a normal app, not an overlay), so it is used from the Library, not mid-game. | the AppImage on disk; `steamos-add-to-steam <path>` once, as `deck` (it refuses to run as root) [V1]. `TODO(hw)`: whether that can be done without Desktop Mode. |
| v2: the button opens it | Armoury Crate short press launches or focuses the shortcut | a user service listening for the InputPlumber D-Bus event; a way to start a shortcut from outside Steam (`steam://rungameid/…` for non-Steam shortcuts is reported as unreliable; unverified) |
| v3: overlay over the game | the left-docked panel over a running game, as in the reference | the hhd pattern, which is known to work with an Electron window: property swap on Steam's window, InputPlumber intercept mode, a transparent window, a stable window class to find it by (`desktopName` is set for that). Touches Steam's own window state; highest risk. |

This slice builds toward v1. The panel is drawn left-docked already so
that v3 needs no redesign, but in v1 the area to its right is a plain
backdrop, not the game. The app holds a single-instance lock: starting it a
second time (later: from the button) raises the running panel.

## 3. Architecture

```
 deck (unprivileged)                              root
┌──────────────────────────────┐   sudo -n    ┌─────────────────────────────────────────────┐
│ Control Center               │ ───────────▶ │ /etc/ally-x20-steamos/control-center-helper │
│  React page (sandboxed)      │  one word    │   one word from a closed list               │
│   ── IPC ──▶ Electron main   │ ◀─────────── │   checks ownership, cleans the environment  │
│  no network, no file access  │ stdout/stderr│   exec ally-x20-steamos.sh <fixed arguments>│
└──────────────────────────────┘  exit status └─────────────────────────────────────────────┘
```

### The three ways to cross to root

| | (a) sudo + root-owned helper + NOPASSWD drop-in | (b) polkit (`pkexec` + rule) | (c) root daemon on a socket |
|---|---|---|---|
| new privileged code | one POSIX sh file, about 130 lines with comments | the same helper, plus a JavaScript rule | a long-running service, a protocol, peer-credential checks |
| files under `/usr` | none | a named action needs a policy file under `/usr/share/polkit-1/actions` (read-only here; from memory, not checked on SteamOS). Without it the rule has to match the generic `org.freedesktop.policykit.exec` action by program path | none |
| who may call | the user named in the drop-in | can be limited to the *active local session* (better than (a): an ssh login as `deck` would not qualify) | whoever can open the socket (mode/group) |
| arguments | sudo itself matches the full command line | passed through; the helper must check | parsed by our own code |
| running when idle | nothing | nothing | a root process, always |
| failure mode | a broken drop-in can lock sudo: prevented by `visudo -cf` before install | a broken rule is ignored | a bug is a root bug at all times |
| tested with stubs | yes (`sudo`, `visudo` are plain commands) | harder (needs polkitd) | needs a harness |

### Inside the UI process

Electron has two parts, and the split is a second, inner boundary:

| part | can do | file |
|---|---|---|
| the page (renderer) | draw, read the Gamepad API, call two functions on `window.controlCenter` | `src/` |
| preload | forward those two calls over IPC (`helper:run`, `app:quit`) and hand back output lines (`helper:log`) | `electron/preload.ts` |
| main process | check that the call comes from the top frame of its own window showing its own file, check the operation against its own list, start `sudo` | `electron/main.ts`, `electron/operations.ts` |

Settings (checked by a bats test that greps `main.ts`):
`contextIsolation: true`, `nodeIntegration: false`, `sandbox: true` plus
`app.enableSandbox()`, no `remote` module, `webviewTag: false`. Navigation,
redirects, new windows and `<webview>` are blocked; every permission
request is denied; a request filter cancels every URL that is not a file
inside the app's `dist/`; the page is loaded with `loadFile`, never from a
URL. The built page carries a CSP of `default-src 'none'` with scripts,
styles, images and fonts from its own files only and `connect-src 'none'`.
`sudo` is started with `spawn`, an argument vector and `shell: false`.

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
| `update` | `ally-x20-steamos self-update` | on the channel the device is set to (decision 3): for `stable`, checks out the newest release **signed by a pinned key**; then runs migrations and `apply`, stages modules | log lines; "updated to vX" or "already up to date" |
| `apply` | `ally-x20-steamos apply` | re-installs the files of the enabled components | log lines |
| `rollback` | `ally-x20-steamos self-update --rollback` | checks out the commit recorded before the last update, then `apply` | log lines |

- Exit status: the CLI's own, passed through unchanged. That includes
  **4, "finished, but some components failed"** (see
  [Partial updates](#partial-updates)). The helper's own refusals are 64
  (not exactly one known word), 69 (CLI missing), 75 (another changing
  operation is running), 77 (not root, or unsafe ownership/mode).
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

### Partial updates

Decision 3: an update is applied in place, on whatever channel the device
is set to, and **a component that cannot be applied does not stop the
rest**. That component fails, its error is reported, and the others go
through.

- The behavior itself is not in this branch. It comes with PR #79
  ("resilient apply", not merged when this was written): `apply` and
  `self-update` skip a failing component, exit with **4**, and record each
  component's outcome in `/var/lib/ally-x20-steamos/state/last-apply.json`.
  `status --json` then has `last_apply` (`file`, `when`, `command`,
  `result`: `ok` or `failed`) and, per component, `last_apply`
  (`applied`, `unchanged`, `failed`, `skipped` or empty) and
  `last_apply_reason`.
- The helper needs no change: it has no knowledge of exit codes and
  `exec`s the CLI, so 4 arrives at the UI as 4. A unit test of the Electron
  side covers the pass-through.
- The UI treats 4 as "finished, some components failed", not as an error:
  the log ends with that sentence, the Update screen lists every failed
  component with its reason (and skipped ones with theirs), and the Home
  screen marks the failed tiles and says how many failed in its top line.
- **Without #79** the fields are absent and the UI shows exactly what it
  showed before: no outcome list, tiles by status only. On such a version a
  failing component still makes `apply` exit 1, which the UI reports as a
  failure. Both shapes are in the mock (`?legacy` in the dev URL gives the
  old one).
- Not tested against the real #79 output: the field names above were read
  from that branch's `lib/status.sh` and documentation, and the mock
  imitates them.

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
| Only a fixed list of operations | The helper compares its single argument against five words and replaces it with constants (`set -- self-update --check`) before anything is executed. | bats: each word maps to its command line; more than 20 other inputs are refused |
| sudo allows no extra arguments | Each sudoers entry is the helper path **plus one word**. In sudoers, a command given with arguments matches only that exact argument list; a bare path would allow any. No wildcards. | bats: file content compared; no `*`, `?`, `[`; every mention of the helper is followed by exactly one word; list equals the helper's list |
| No user-controlled string reaches a shell | The argument is never expanded into a command, never passed to the CLI, never logged. The helper has no `eval` and sources nothing. The Electron main process starts `sudo` with `spawn`, an argument vector and no shell, and also picks the word from its own constants. | bats: `status; id`, `$(id)`, backticks, `--root /`, newline, extra arguments → exit 64 and the CLI is not started; `npm test` for the Electron list (7 tests, including objects, arrays and prototype names as input) |
| Clean environment and PATH | sudo: `env_reset`, `!setenv`, `secure_path`. Helper: sets `PATH` and `IFS` first, uses absolute paths for every tool, and starts the CLI with `env -i PATH=… HOME=/root LANG=C LC_ALL=C`. `AX20_ROOT`, `AX20_SRC`, `AX20_DRY_RUN`, `BASH_ENV`, `LD_PRELOAD`, `GIT_DIR` … never arrive. | bats: the CLI stand-in dumps its environment; none of 13 planted variables is in it |
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
  operations are serialized by the lock).

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
  ([self-update.md](self-update.md)). The helper cannot change the channel,
  and by decision 3 it does not force `stable`: the device's own setting
  decides.
- `deck` is in `wheel`. Whoever knows the `deck` password is root anyway;
  the drop-in adds nothing for them. It matters for code that runs as
  `deck` *without* knowing the password.
- sudo's rule cannot tell the UI from any other process of `deck`. polkit
  could restrict to the active local session (section 3).
- The Electron lockdown (section 3) protects the page from loading or
  running foreign content. It adds nothing against another process of
  `deck`, which can call `sudo` itself; the helper is the boundary.

### The drop-in cannot lock sudo

A sudoers file with a syntax error makes `sudo` refuse to run at all, and
on a device without a root password that is hard to recover from. So:

1. The drop-in is a **static file** in the repository
   (`overlay/sudoers.d/…`), not generated. The test suite runs the real
   `visudo -cf` on it wherever `visudo` exists.
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
- Per-component outcome of the last apply, with the reason for a failure,
  once the installed version reports it ([Partial updates](#partial-updates)).
- Missing for a usable v1: an AppImage build in CI and a place to download
  it from, a CLI command that fetches/places it and adds the shortcut, the
  first start on the device, a "reboot now" prompt after an update that
  needs one.

### Later

| feature | CLI today | machine-readable today | needed |
|---|---|---|---|
| project status | `status` | **`--json`** | nothing |
| drift report | `audit` | **`--json`** | a helper operation |
| update check | `self-update --check` | text; result also in `state/last-update-check` and in `status --json` (`last_update_check`) | fine as is |
| update / apply / rollback | `self-update`, `apply` | log text, exit status; per-component outcomes in `status --json` with PR #79 | progress as JSON lines would allow a progress bar |
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

## 6. Decisions

Made by the owner on 2026-11-20, after the first version of this page.

| # | question | decision |
|---|---|---|
| 1 | Tauri (smaller, unproven under gamescope) or Electron (larger, proven)? | **Electron.** "Let's just use what is already proven." Section 1. |
| 2 | Is `rollback` in the passwordless set? | **Yes, it stays.** The one-step downgrade it allows is accepted (section 4). |
| 3 | Should `update` through the helper force the stable channel? | **No.** It updates in place on whatever channel the device is set to. If part of an update cannot be applied, that component fails and the error is reported; the rest still goes through. Depends on PR #79 for the "rest goes through" part ([Partial updates](#partial-updates)). |
| 4 | Is the user `deck` hard-coded in the sudoers file? | **Yes.** The file stays static and explicit, which is also what lets the tests run `visudo` on it. |

## 7. Open questions

1. **Turn the component on by default later?** Now it is opt-in. Default-on
   would put a NOPASSWD rule on every install.
2. **Which press opens it?** Armoury Crate short press (`KeyF16`) looks
   free upstream; what this project's own profile does with it must be
   checked against [inputplumber.md](inputplumber.md) and on the device.
3. **Name.** "Control Center" is used here; the product name of the ASUS
   software is deliberately not.
4. **Where does the AppImage come from?** A release asset built by CI is
   the obvious answer (as with the kernel modules); it then needs the same
   trust story as `self-update` (a checksum in the signed tag, for example).

## Sources

Read on 2026-11-20. "Read from source" means the file was read at the
linked revision; nothing below was verified on an X20.

Tauri / WebKitGTK
- [T1] Tauri 2.0 alpha 3 notes (WebKitGTK 4.1): <https://v2.tauri.app/blog/tauri-2-0-0-alpha-3/>
- [T2] Tauri AppImage guide (size "2-6 MB … to 70+ MB", glibc of the build host): <https://v2.tauri.app/distribute/appimage/>
- [T3] Tauri bundler, AppImage (copies WebKit processes): <https://github.com/tauri-apps/tauri/blob/dev/crates/tauri-bundler/src/bundle/linux/appimage/linuxdeploy.rs>
- [T4] Tauri, Linux graphics workarounds: <https://v2.tauri.app/develop/debug/linux-graphics/>
- [T6] Tauri Flatpak guide: <https://v2.tauri.app/distribute/flatpak/>
- [T7] A Tauri Flatpak needing `--device=input`: <https://github.com/PhilipK/BoilR/pull/523>
- [T8] Transparent window bug on Linux: <https://github.com/tauri-apps/tauri/issues/14924>
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
- [H2] hhd-ui is React + Vite in Electron (`electron-builder`, Linux target AppImage; fullscreen, `transparent: true` in overlay mode, no Chromium switches): <https://github.com/hhd-dev/hhd-ui/blob/main/package.json>, <https://github.com/hhd-dev/hhd-ui/blob/main/electron/package.json>, <https://github.com/hhd-dev/hhd-ui/blob/main/electron/main.js>
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

Electron
- Security checklist (context isolation, sandbox, navigation, CSP): <https://www.electronjs.org/docs/latest/tutorial/security>
- electron-builder, AppImage target: <https://www.electron.build/appimage>

sudo
- sudoers(5), "Sudoers file format" (last match wins; arguments in a command specification; `@includedir` skips names with a `.`): <https://www.sudo.ws/docs/man/sudoers.man/>
