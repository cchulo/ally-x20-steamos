# Control Center UI

A controller-driven panel for ally-x20-steamos: status on the Home screen;
check, update, apply and rollback on the Update screen. Design, security
model and what is still open: [`docs/control-center.md`](../../docs/control-center.md).

**State: scaffold.** The web part builds and runs in a browser against mock
data. The Tauri shell compiles on macOS. Nothing has been built for Linux,
packaged, or shown on the device yet.

## Layout

| path | what |
|---|---|
| `src/backend.ts` | the only link to the outside: `run(op)` with `op` one of `status check update apply rollback`. Under Tauri it invokes the Rust command; in a browser it answers from a mock. |
| `src/nav.ts` | focus navigation: arrow keys or D-pad/left stick move, A/Enter selects, B/Esc goes back, Y/F5 refreshes, LB/RB (PageUp/PageDown) switch screens |
| `src/screens/Home.tsx`, `src/screens/Update.tsx` | the two screens |
| `src/Tile.tsx`, `src/icons.tsx`, `src/styles.css` | tiles, icons, look |
| `src-tauri/src/main.rs` | the shell: one window, `run_helper` (starts `sudo -n /etc/ally-x20-steamos/control-center-helper <op>`, streams its output as `helper-log` events) and `quit` |
| `src-tauri/capabilities/default.json` | the window may listen to events; no shell, file-system or HTTP plugin is built in |
| `scripts/make-icon.py` | draws `src-tauri/icons/icon.png` |

The UI opens no network connection and reads no files. Everything it knows
comes from the helper's output.

## Develop in a browser (any OS)

Needs Node 20 or newer.

```sh
cd ui/control-center
npm install
npm run dev        # http://127.0.0.1:5173, mock backend ("mock data" in the header)
npm run build      # type-check (tsc) and bundle into dist/
```

A controller plugged into the PC works in the browser too (press a button
once so the browser reports it).

## Run the Tauri shell

Needs a Rust toolchain. On Linux also the WebKitGTK 4.1 development files
(Arch: `webkit2gtk-4.1`; see <https://v2.tauri.app/start/prerequisites/>).
On macOS nothing extra.

```sh
npm run build                    # src-tauri embeds dist/
cd src-tauri
cargo check                      # compiles the shell
cargo test                       # the operation list
cd .. && npm run tauri dev       # window with hot reload
```

Outside SteamOS the helper does not exist, so every operation fails with a
message in the window. That is expected; use the browser for UI work.

## Build the AppImage (Linux only, not done yet)

```sh
npm run tauri build              # src-tauri/target/release/bundle/appimage/*.AppImage
```

The AppImage carries WebKitGTK, which SteamOS does not ship (about 70 MB
according to Tauri's documentation; not measured for this app). Build it on
the oldest distribution that has WebKitGTK 4.1: the glibc of the build host
becomes the minimum. A CI job for this does not exist yet.

On the device (untested, `TODO(hw)`):

```sh
sudo ./ally-x20-steamos.sh apply --only controlcenter   # helper + passwordless sudo rule (opt-in)
./ally-x20-control-center.AppImage --appimage-extract-and-run
steamos-add-to-steam "$PWD/ally-x20-control-center.AppImage"   # then start it from Game Mode
```

If the window stays black under gamescope, try
`WEBKIT_DISABLE_DMABUF_RENDERER=1`, then `WEBKIT_DISABLE_COMPOSITING_MODE=1`.

## Licences

Code and icons: GPL-2.0-only, written and drawn for this project. No ASUS
asset (icon, logo, font, screenshot) is used; the layout is inspired by
handheld vendor panels in general. No icon set and no web font is bundled:
the page uses the system's fonts.

Dependencies (see `package-lock.json` and `src-tauri/Cargo.lock`): React and
React DOM (MIT), `@tauri-apps/api` and Tauri (MIT or Apache-2.0), Vite and
`@vitejs/plugin-react` (MIT, build only), TypeScript (Apache-2.0, build only).
