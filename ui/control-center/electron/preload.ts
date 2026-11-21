// SPDX-License-Identifier: GPL-2.0-only
// The page's whole view of the outside world: `window.controlCenter` with
// two functions. Runs sandboxed and context-isolated; it can only talk to
// the main process over the three channels below. The main process checks
// the operation again (electron/operations.ts); this file is not trusted
// to do so.
import { contextBridge, ipcRenderer, type IpcRendererEvent } from "electron";

interface LogLine {
  op: string;
  stream: "stdout" | "stderr";
  line: string;
}
interface RunResult {
  code: number;
  stdout: string;
}

contextBridge.exposeInMainWorld("controlCenter", {
  /** Run one helper operation; `onLine` gets its output lines as they arrive. */
  async run(op: string, onLine: (l: LogLine) => void): Promise<RunResult> {
    const listener = (_e: IpcRendererEvent, l: LogLine) => {
      if (l.op === op) onLine({ op: l.op, stream: l.stream, line: l.line });
    };
    ipcRenderer.on("helper:log", listener);
    try {
      return (await ipcRenderer.invoke("helper:run", op)) as RunResult;
    } finally {
      ipcRenderer.removeListener("helper:log", listener);
    }
  },
  /** Close the app. */
  quit(): void {
    ipcRenderer.send("app:quit");
  },
});
