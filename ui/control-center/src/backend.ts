// SPDX-License-Identifier: GPL-2.0-only
// The one place the UI talks to the outside. Under Tauri every operation is
// `sudo -n /etc/ally-x20-steamos/control-center-helper <op>` (src-tauri/src/main.rs);
// in a plain browser (`npm run dev`) a mock answers, so the UI can be
// developed without a device. The UI itself never opens a network connection.

/** The closed list of the helper (overlay/bin/control-center-helper). */
export const OPERATIONS = ["status", "check", "update", "apply", "rollback"] as const;
export type Operation = (typeof OPERATIONS)[number];

export type LogStream = "stdout" | "stderr" | "ui";
export interface LogLine {
  op: Operation;
  stream: LogStream;
  line: string;
}
export interface RunResult {
  /** Exit status of the helper (the CLI's; 64/69/75/77 are the helper's own refusals). */
  code: number;
  stdout: string;
}

/** `ally-x20-steamos status --json` (lib/status.sh). */
export interface ComponentStatus {
  name: string;
  status: string;
  description: string;
}
export interface Status {
  name: string;
  version: string;
  commit: string;
  generated: string;
  kernel: { running: string; modules_staged: boolean };
  update_policy: string;
  pending_reboot_check: boolean;
  last_update_check: { ts: string; result: string; ref: string } | null;
  components: ComponentStatus[];
}

export interface Backend {
  kind: "tauri" | "mock";
  run(op: Operation, onLine: (l: LogLine) => void): Promise<RunResult>;
  quit(): void;
}

const inTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

const tauriBackend: Backend = {
  kind: "tauri",
  async run(op, onLine) {
    const { invoke } = await import("@tauri-apps/api/core");
    const { listen } = await import("@tauri-apps/api/event");
    const stop = await listen<LogLine>("helper-log", (e) => {
      if (e.payload.op === op) onLine(e.payload);
    });
    try {
      return await invoke<RunResult>("run_helper", { op });
    } finally {
      stop();
    }
  },
  quit() {
    void import("@tauri-apps/api/core").then(({ invoke }) => invoke("quit"));
  },
};

// ---------------------------------------------------------------- mock --

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const mockState = { version: "0.1.11", commit: "1134bae", previous: "0.1.10", available: "v0.1.12" as string | null };

function mockStatus(): Status {
  return {
    name: "ally-x20-steamos",
    version: mockState.version,
    commit: mockState.commit,
    generated: new Date().toISOString(),
    kernel: { running: "6.16.12-valve3-1-neptune-616", modules_staged: true },
    update_policy: "block",
    pending_reboot_check: false,
    last_update_check: mockState.available
      ? { ts: new Date().toISOString(), result: "available", ref: mockState.available }
      : { ts: new Date().toISOString(), result: "up-to-date", ref: "v" + mockState.version },
    components: [
      { name: "audio", status: "active", description: "speakers: ACPI override, UCM overlay, amp firmware" },
      { name: "controlcenter", status: "active", description: "Control Center: root helper and passwordless sudo rule (opt-in)" },
      { name: "hdr", status: "active", description: "HDR in Desktop and Game Mode" },
      { name: "inputplumber", status: "superseded", description: "controller profile (stock SteamOS now ships it)" },
      { name: "modules", status: "active", description: "patched kernel modules for the running kernel" },
      { name: "power", status: "active", description: "Steam power profiles for the X20" },
      { name: "sdexpress", status: "stock", description: "SD Express slot automount" },
      { name: "update", status: "active", description: "survive SteamOS updates" },
      { name: "xboxled", status: "active", description: "Xbox button light settings" },
    ],
  };
}

const mockScripts: Record<Exclude<Operation, "status">, () => string[]> = {
  check: () =>
    mockState.available
      ? [`update available: ${mockState.available} (current v${mockState.version})`]
      : [`up to date (v${mockState.version})`],
  update: () => {
    if (!mockState.available) return [`already up to date (v${mockState.version} contains v${mockState.version})`];
    const to = mockState.available;
    mockState.previous = mockState.version;
    mockState.version = to.slice(1);
    mockState.available = null;
    return [
      `ally-x20-steamos: checked out ${to} (previous: 1134bae0c2d1)`,
      "ally-x20-steamos: applying component: audio",
      "ally-x20-steamos: applying component: modules",
      "ally-x20-steamos: applying component: update",
      "ally-x20-steamos: applied: audio controlcenter hdr modules power update xboxled",
      `updated to ${to}`,
    ];
  },
  apply: () => [
    "ally-x20-steamos: applying component: audio",
    "ally-x20-steamos: applying component: hdr",
    "ally-x20-steamos: applying component: modules",
    "ally-x20-steamos: applied: audio controlcenter hdr modules power update xboxled",
  ],
  rollback: () => {
    const cur = mockState.version;
    mockState.version = mockState.previous;
    mockState.previous = cur;
    mockState.available = null;
    return [
      "ally-x20-steamos: checked out previous commit",
      "ally-x20-steamos: applied: audio controlcenter hdr modules power update xboxled",
      "rolled back (run self-update --rollback again to undo)",
    ];
  },
};

const mockBackend: Backend = {
  kind: "mock",
  async run(op, onLine) {
    if (op === "status") {
      await sleep(150);
      return { code: 0, stdout: JSON.stringify(mockStatus()) };
    }
    const lines = mockScripts[op]();
    for (const line of lines) {
      await sleep(350);
      onLine({ op, stream: line.startsWith("ally-x20-steamos:") ? "stderr" : "stdout", line });
    }
    return { code: 0, stdout: lines.join("\n") };
  },
  quit() {
    console.info("mock backend: quit requested");
  },
};

export const backend: Backend = inTauri ? tauriBackend : mockBackend;

/** Run `status` and parse it. Throws with a readable message on failure. */
export async function fetchStatus(): Promise<Status> {
  const r = await backend.run("status", () => {});
  if (r.code !== 0) throw new Error(explainExit(r.code));
  return JSON.parse(r.stdout) as Status;
}

/** What a non-zero exit status of the helper means, in words. */
export function explainExit(code: number): string {
  switch (code) {
    case 1:
      return "sudo refused or the command failed. Is the controlcenter component enabled? (ally-x20-steamos apply --only controlcenter)";
    case 3:
      return "could not reach the update server (offline?)";
    case 64:
      return "the helper does not know this operation (UI and helper versions differ)";
    case 69:
      return "ally-x20-steamos is not installed at /var/lib/ally-x20-steamos/src";
    case 75:
      return "another update, apply or rollback is still running";
    case 77:
      return "the helper refused: files of the installation are not owned by root or are writable by others";
    default:
      return `failed with exit status ${code}`;
  }
}
