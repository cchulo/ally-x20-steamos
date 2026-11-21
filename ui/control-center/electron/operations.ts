// SPDX-License-Identifier: GPL-2.0-only
// The closed list of what the UI may ask for, and the one command line that
// carries it out. No Electron import here, so this file is unit-tested with
// plain node (operations.test.ts).
//
// Keep in step with overlay/bin/control-center-helper and
// overlay/sudoers.d/zz-ally-x20-steamos-control-center
// (tests/components/controlcenter.bats compares the three lists).
import { spawn as nodeSpawn, type ChildProcess, type SpawnOptions } from "node:child_process";
import { createInterface } from "node:readline";

export const SUDO = "/usr/bin/sudo";
export const HELPER = "/etc/ally-x20-steamos/control-center-helper";
export const OPERATIONS = ["status", "check", "update", "apply", "rollback"] as const;
export type Operation = (typeof OPERATIONS)[number];

export type LogStream = "stdout" | "stderr";
export interface LogLine {
  op: Operation;
  stream: LogStream;
  line: string;
}
export interface RunResult {
  /** Exit status of the helper; -1 if it was killed by a signal. */
  code: number;
  stdout: string;
}

/** The operation as one of our own constants, or null. */
export function knownOperation(op: unknown): Operation | null {
  if (typeof op !== "string") return null;
  return OPERATIONS.find((known) => known === op) ?? null;
}

/** The argument vector for an operation. Only constants, never the caller's string. */
export function helperCommand(op: Operation): { file: string; args: string[] } {
  return { file: SUDO, args: ["-n", HELPER, op] };
}

type Spawn = (file: string, args: readonly string[], options: SpawnOptions) => ChildProcess;

/**
 * Run one helper operation. `requested` is whatever the page sent; anything
 * that is not one of the five words is rejected before a process exists.
 * There is no shell: `spawn` gets an argument vector and `shell: false`.
 */
export function runHelper(requested: unknown, onLine: (l: LogLine) => void, spawn: Spawn = nodeSpawn): Promise<RunResult> {
  const op = knownOperation(requested);
  if (op === null) return Promise.reject(new Error("unknown operation"));
  const { file, args } = helperCommand(op);
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, {
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
      // The helper wipes its environment anyway; give sudo the minimum.
      env: { PATH: "/usr/bin:/usr/sbin:/bin:/sbin", LANG: "C" },
      cwd: "/",
      windowsHide: true,
    });
    let stdout = "";
    const pump = (stream: LogStream, source: NodeJS.ReadableStream | null) => {
      if (!source) return;
      createInterface({ input: source, crlfDelay: Infinity }).on("line", (line) => {
        if (stream === "stdout") stdout += line + "\n";
        // `status` prints one JSON document; the page gets it as the result.
        if (!(op === "status" && stream === "stdout")) onLine({ op, stream, line });
      });
    };
    pump("stdout", child.stdout);
    pump("stderr", child.stderr);
    child.once("error", (e) => reject(new Error(`cannot start ${file}: ${e.message}`)));
    child.once("close", (code) => resolve({ code: code ?? -1, stdout }));
  });
}
