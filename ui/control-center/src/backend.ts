// SPDX-License-Identifier: GPL-2.0-only
// The one place the UI talks to the outside. In the Electron shell every
// operation goes through `window.controlCenter` (electron/preload.ts) to the
// main process, which runs
// `sudo -n /etc/ally-x20-steamos/control-center-helper <op>`
// (electron/operations.ts). In a plain browser (`npm run dev`) a mock
// answers, so the UI can be developed without a device. The UI itself never
// opens a network connection.

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
  /**
   * Exit status of the helper, which is the CLI's: 0 done, 4 finished but
   * some components failed, 3 offline. 64/69/75/77 are the helper's own
   * refusals.
   */
  code: number;
  stdout: string;
}

/** Outcome of a component in the last apply run that touched it. */
export type ApplyOutcome = "applied" | "unchanged" | "failed" | "skipped" | "";

/** `ally-x20-steamos status --json` (lib/status.sh). */
export interface ComponentStatus {
  name: string;
  status: string;
  description: string;
  /** Only from versions that record apply outcomes (state/last-apply.json). */
  last_apply?: ApplyOutcome;
  last_apply_reason?: string;
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
  /** Only from versions that record apply outcomes; `result` is "ok" or "failed". */
  last_apply?: { file: string; when: string; command: string; result: string } | null;
  components: ComponentStatus[];
}

export interface Backend {
  kind: "electron" | "mock";
  run(op: Operation, onLine: (l: LogLine) => void): Promise<RunResult>;
  quit(): void;
}

/** What electron/preload.ts puts on `window`. */
interface Bridge {
  run(op: string, onLine: (l: LogLine) => void): Promise<RunResult>;
  quit(): void;
}
declare global {
  interface Window {
    controlCenter?: Bridge;
  }
}

const bridge = typeof window !== "undefined" ? window.controlCenter : undefined;

const electronBackend = (b: Bridge): Backend => ({
  kind: "electron",
  run: (op, onLine) => b.run(op, onLine),
  quit: () => b.quit(),
});

// ---------------------------------------------------------------- mock --

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Open the dev page with ?legacy to get a status without the apply-outcome
// fields, as a version before they existed prints it.
const legacy = typeof location !== "undefined" && new URLSearchParams(location.search).has("legacy");

const HDR_ERROR = "cannot create directory /etc/ld.so.conf.d";

const mockState = {
  version: "0.1.11",
  commit: "1134bae",
  previous: "0.1.10",
  available: "v0.1.12" as string | null,
  /** The example of a partial result: the next update fails for this component. */
  failNext: "hdr" as string | null,
  failed: null as string | null,
  lastCommand: "boot",
};

function mockStatus(): Status {
  const comps: ComponentStatus[] = [
    { name: "audio", status: "active", description: "speakers: ACPI override, UCM overlay, amp firmware" },
    { name: "controlcenter", status: "active", description: "Control Center: root helper and passwordless sudo rule (opt-in)" },
    { name: "hdr", status: "active", description: "HDR in Desktop and Game Mode" },
    { name: "inputplumber", status: "superseded", description: "controller profile (stock SteamOS now ships it)" },
    { name: "modules", status: "active", description: "patched kernel modules for the running kernel" },
    { name: "power", status: "active", description: "Steam power profiles for the X20" },
    { name: "sdexpress", status: "stock", description: "SD Express slot automount" },
    { name: "update", status: "active", description: "survive SteamOS updates" },
    { name: "xboxled", status: "active", description: "Xbox button light settings" },
  ];
  for (const c of comps) {
    if (c.name === mockState.failed) c.status = "stock";
    if (legacy) continue;
    if (c.name === mockState.failed) {
      c.last_apply = "failed";
      c.last_apply_reason = HDR_ERROR;
    } else if (c.name === "inputplumber") {
      c.last_apply = "skipped";
      c.last_apply_reason = "stock SteamOS provides this";
    } else {
      c.last_apply = c.name === "sdexpress" ? "" : "applied";
      c.last_apply_reason = "";
    }
  }
  const s: Status = {
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
    components: comps,
  };
  if (!legacy) {
    s.last_apply = {
      file: "/var/lib/ally-x20-steamos/state/last-apply.json",
      when: new Date().toISOString(),
      command: mockState.lastCommand,
      result: mockState.failed ? "failed" : "ok",
    };
  }
  return s;
}

/** The apply part every changing operation ends with; returns the exit status. */
function mockApply(lines: string[], command: string): number {
  mockState.lastCommand = command;
  mockState.failed = mockState.failNext;
  mockState.failNext = null;
  for (const c of ["audio", "controlcenter", "hdr", "modules", "power", "update", "xboxled"]) {
    lines.push(`ally-x20-steamos: applying component: ${c}`);
    if (c === mockState.failed) {
      lines.push(`ally-x20-steamos: error: ${HDR_ERROR}`);
      lines.push(`ally-x20-steamos: error: component ${c} failed to apply; continuing with the others`);
    }
  }
  if (mockState.failed) {
    lines.push(`ally-x20-steamos: failed: ${mockState.failed} (see state/last-apply.json)`);
    return 4;
  }
  lines.push("ally-x20-steamos: applied: audio controlcenter hdr modules power update xboxled");
  return 0;
}

const mockScripts: Record<Exclude<Operation, "status">, () => { lines: string[]; code: number }> = {
  check: () => ({
    lines: mockState.available
      ? [`update available: ${mockState.available} (current v${mockState.version})`]
      : [`up to date (v${mockState.version})`],
    code: 0,
  }),
  update: () => {
    if (!mockState.available) {
      return { lines: [`already up to date (v${mockState.version} contains v${mockState.version})`], code: 0 };
    }
    const to = mockState.available;
    mockState.previous = mockState.version;
    mockState.version = to.slice(1);
    mockState.available = null;
    const lines = [`ally-x20-steamos: checked out ${to} (previous: 1134bae0c2d1)`];
    const code = mockApply(lines, "self-update");
    lines.push(`updated to ${to}`);
    return { lines, code };
  },
  apply: () => {
    const lines: string[] = [];
    return { code: mockApply(lines, "apply"), lines };
  },
  rollback: () => {
    const cur = mockState.version;
    mockState.version = mockState.previous;
    mockState.previous = cur;
    mockState.available = null;
    const lines = ["ally-x20-steamos: checked out previous commit"];
    const code = mockApply(lines, "self-update");
    lines.push("rolled back (run self-update --rollback again to undo)");
    return { lines, code };
  },
};

const mockBackend: Backend = {
  kind: "mock",
  async run(op, onLine) {
    if (op === "status") {
      await sleep(150);
      return { code: 0, stdout: JSON.stringify(mockStatus()) };
    }
    const { lines, code } = mockScripts[op]();
    for (const line of lines) {
      await sleep(300);
      onLine({ op, stream: line.startsWith("ally-x20-steamos:") ? "stderr" : "stdout", line });
    }
    return { code, stdout: lines.join("\n") };
  },
  quit() {
    console.info("mock backend: quit requested");
  },
};

export const backend: Backend = bridge ? electronBackend(bridge) : mockBackend;

/** Run `status` and parse it. Throws with a readable message on failure. */
export async function fetchStatus(): Promise<Status> {
  const r = await backend.run("status", () => {});
  if (r.code !== 0) throw new Error(explainExit(r.code));
  return JSON.parse(r.stdout) as Status;
}

/** Exit status 4: the run finished, but one or more components failed and were skipped. */
export const EXIT_PARTIAL = 4;

export type RunOutcome = "ok" | "partial" | "failed";

export function outcomeOf(code: number): RunOutcome {
  return code === 0 ? "ok" : code === EXIT_PARTIAL ? "partial" : "failed";
}

/** Components whose last apply failed, when the status reports outcomes (else none). */
export function failedComponents(s: Status | null): ComponentStatus[] {
  return s ? s.components.filter((c) => c.last_apply === "failed") : [];
}

/** True if this status carries per-component apply outcomes at all. */
export function hasApplyOutcomes(s: Status | null): boolean {
  return s !== null && s.components.some((c) => c.last_apply !== undefined);
}

/** What a non-zero exit status of the helper means, in words. */
export function explainExit(code: number): string {
  switch (code) {
    case 1:
      return "sudo refused or the command failed. Is the controlcenter component enabled? (ally-x20-steamos apply --only controlcenter)";
    case 3:
      return "could not reach the update server (offline?)";
    case EXIT_PARTIAL:
      return "finished, but some components failed and were skipped";
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
