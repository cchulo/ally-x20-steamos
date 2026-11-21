# Control Center UI

A controller-driven panel for ally-x20-steamos: status on the Home screen;
check, update, apply and rollback on the Update screen. Design, security
model, decisions and what is still open:
[`docs/control-center.md`](../../docs/control-center.md).

**State: scaffold.** The page builds and runs in a browser against mock
data. The Electron shell compiles and its operation whitelist is
unit-tested. A Linux x64 AppImage was built once (123 MB). No window has
been opened anywhere: not on a development machine, not on the device.

Stack: Electron + React + TypeScript (Vite), packaged with
`electron-builder` as an AppImage, the same route Handheld Daemon takes.

## Layout

| path | what |
|---|---|
| `src/backend.ts` | the only link from the page to the outside: `run(op)` with `op` one of `status check update apply rollback`. In Electron it calls `window.controlCenter` (the preload); in a browser it answers from a mock. |
| `src/nav.ts` | focus navigation: arrow keys or D-pad/left stick move, A/Enter selects, B/Esc goes back, Y/F5 refreshes, LB/RB (PageUp/PageDown) switch screens |
| `src/screens/Home.tsx`, `src/screens/Update.tsx` | the two screens |
| `src/Tile.tsx`, `src/icons.tsx`, `src/styles.css` | tiles, icons, look |
| `electron/operations.ts` | the five operations and the command line `/usr/bin/sudo -n /etc/ally-x20-steamos/control-center-helper <op>`; `spawn` without a shell. No Electron import, so it is tested with plain node. |
| `electron/main.ts` | the main process: one locked-down window, IPC `helper:run` and `app:quit` |
| `electron/preload.ts` | exposes `window.controlCenter.run(op, onLine)` and `.quit()` through `contextBridge`, nothing else |
| `electron/operations.test.ts` | unit tests for the whitelist and the spawn call (`npm test`) |
| `assets/icon.png`, `scripts/make-icon.py` | the app icon and the script that draws it |

## Security settings of the shell

- `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`
  (and `app.enableSandbox()`), no `remote` module, no `<webview>`.
- The page is loaded from the app's own files with `loadFile`. Navigation,
  redirects and new windows are blocked; every permission request is
  denied; a request filter cancels any URL outside the app's `dist/`.
- The built page has a Content-Security-Policy of `default-src 'none'`
  with scripts, styles, images and fonts from its own files only and
  `connect-src 'none'` (added at build time in `vite.config.mts`).
- The main process accepts `helper:run` only from the top frame of its own
  window, checks the operation against its own constant list, and starts
  `sudo` with an argument vector. Nothing else the page sends reaches a
  process, the file system or the network.
- The UI opens no network connection and reads no files. Everything it
  knows comes from the helper's output.

## Develop in a browser (any OS)

Needs Node 20 or newer.

```sh
cd ui/control-center
npm install
npm run dev        # http://127.0.0.1:5173, mock backend ("mock data" in the header)
```

- The mock starts with an update available. The first Update ends as a
  **partial result** (exit status 4: `hdr` fails, the rest is applied), so
  the failure display can be seen; Apply afterwards succeeds.
- `http://127.0.0.1:5173/?legacy` gives a status without the per-component
  outcome fields, as a version before PR #79 prints it.
- A controller plugged into the PC works in the browser too (press a button
  once so the browser reports it).

## Build and test

```sh
npm run build      # page: type-check + bundle into dist/; shell: compile into dist-electron/
npm test           # node's test runner on the operation whitelist; opens no window
npm start          # build, then open the Electron window (needs a display)
```

Outside SteamOS the helper does not exist, so in `npm start` every
operation fails with a message in the window. That is expected; use the
browser for UI work.

## Package the AppImage

```sh
npm run dist       # release/ally-x20-control-center-<version>-x86_64.AppImage
```

- Target: Linux x64 AppImage (`build` section of `package.json`).
- This works on Linux and also cross-builds on macOS (done once on an
  arm64 Mac: 123 MB). `electron-builder` downloads the Linux build of
  Electron and its AppImage tools on the first run, into the user's cache
  directory (`~/.cache/electron*` on Linux, `~/Library/Caches/electron*` on
  macOS).
- There is no CI job for it yet, and the result has not been started.

On the device (untested, `TODO(hw)`):

```sh
sudo ./ally-x20-steamos.sh apply --only controlcenter   # helper + passwordless sudo rule (opt-in)
./ally-x20-control-center-0.1.0-x86_64.AppImage --appimage-extract-and-run
steamos-add-to-steam "$PWD/ally-x20-control-center-0.1.0-x86_64.AppImage"   # then start it from Game Mode
```

Check on the first start that it runs without `--no-sandbox`
(see "Risks" in the design document).

## Licenses

Code and icons in this directory: GPL-2.0-only, written and drawn for this
project. No ASUS asset (icon, logo, font, screenshot) is used; the layout
is inspired by handheld vendor panels in general. No icon set and no web
font is bundled: the page uses the system's fonts.

Nothing third-party is committed here. Dependencies are fetched by
`npm install` (versions pinned in `package-lock.json`):

| package | license | where it ends up |
|---|---|---|
| React, React DOM | MIT | bundled into the page |
| Electron (with Chromium and Node.js) | MIT; Chromium under BSD-3-Clause and the licenses listed in the `LICENSES.chromium.html` that Electron ships | inside the AppImage |
| electron-builder, Vite, `@vitejs/plugin-react`, TypeScript, type packages | MIT / Apache-2.0 | build tools only |

`npm audit` currently reports 6 moderate findings, all in
`electron-builder`'s own dependencies (a `minimatch` pattern-matching
issue). They are build-time tools and are not part of the packaged app.
