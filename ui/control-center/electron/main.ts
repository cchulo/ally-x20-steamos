// SPDX-License-Identifier: GPL-2.0-only
// Control Center shell (Electron main process): one window for the React
// UI, and two IPC entry points.
//
// `helper:run` is the only way the page can cause anything to happen
// outside its window. It runs
//
//     /usr/bin/sudo -n /etc/ally-x20-steamos/control-center-helper <operation>
//
// with <operation> checked against a constant list (electron/operations.ts;
// the helper and the sudoers drop-in hold the same list, see
// docs/control-center.md). No shell, no other argument, and this process
// never runs as root.
//
// The page itself is locked down: sandboxed renderer, context isolation, no
// Node integration, a strict CSP (vite.config.ts), no navigation, no new
// windows, no permissions, and every request that is not one of the app's
// own files is cancelled.
import { app, BrowserWindow, ipcMain, session, type IpcMainInvokeEvent, type IpcMainEvent, type WebContents } from "electron";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { runHelper } from "./operations";

const DIST = join(__dirname, "..", "dist");
const INDEX = join(DIST, "index.html");
// Trailing slash: "…/dist/" must not match a sibling such as "…/dist-electron/".
const DIST_URL = pathToFileURL(DIST).href + "/";

let mainWindow: BrowserWindow | null = null;

/** True if the URL is one of the app's own files (file:// below dist/). */
function isAppUrl(url: string): boolean {
  return url.startsWith(DIST_URL) && !url.includes("..");
}

/** True if the message comes from the top frame of our window showing our page. */
function fromOurPage(e: IpcMainInvokeEvent | IpcMainEvent): boolean {
  const frame = e.senderFrame;
  return (
    mainWindow !== null &&
    !mainWindow.isDestroyed() &&
    e.sender === mainWindow.webContents &&
    frame !== null &&
    frame === mainWindow.webContents.mainFrame &&
    isAppUrl(frame.url)
  );
}

function lockDown(contents: WebContents): void {
  contents.on("will-navigate", (e) => e.preventDefault());
  contents.on("will-redirect", (e) => e.preventDefault());
  contents.on("will-attach-webview", (e) => e.preventDefault());
  contents.setWindowOpenHandler(() => ({ action: "deny" }));
}

function createWindow(): void {
  mainWindow = new BrowserWindow({
    title: "Control Center",
    fullscreen: true,
    frame: false,
    resizable: false,
    backgroundColor: "#05070a",
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      preload: join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      nodeIntegrationInWorker: false,
      nodeIntegrationInSubFrames: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      webviewTag: false,
      devTools: !app.isPackaged,
      spellcheck: false,
    },
  });
  mainWindow.removeMenu();
  mainWindow.once("ready-to-show", () => mainWindow?.show());
  mainWindow.on("closed", () => {
    mainWindow = null;
  });
  void mainWindow.loadFile(INDEX);
}

// A second start (later: the hardware button) raises the running panel.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  // Every renderer in a sandbox, whatever a window asks for.
  app.enableSandbox();

  app.on("second-instance", () => {
    if (!mainWindow) return;
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  });

  app.on("web-contents-created", (_e, contents) => lockDown(contents));

  ipcMain.handle("helper:run", (e, op: unknown) => {
    if (!fromOurPage(e)) throw new Error("not allowed");
    const sender = e.sender;
    // runHelper rejects anything that is not one of the five operations.
    return runHelper(op, (line) => {
      if (!sender.isDestroyed()) sender.send("helper:log", line);
    });
  });

  ipcMain.on("app:quit", (e) => {
    if (fromOurPage(e)) app.quit();
  });

  void app.whenReady().then(() => {
    const ses = session.defaultSession;
    // No network, no remote content: only the app's own files may load.
    ses.webRequest.onBeforeRequest((details, callback) => callback({ cancel: !isAppUrl(details.url) }));
    // No camera, microphone, notifications, ... The Gamepad API needs no permission.
    ses.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
    ses.setPermissionCheckHandler(() => false);
    createWindow();
  });

  app.on("window-all-closed", () => app.quit());
}
