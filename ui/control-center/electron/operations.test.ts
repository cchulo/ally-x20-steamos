// SPDX-License-Identifier: GPL-2.0-only
// Run with `npm test` (node's built-in test runner; no window is opened).
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { test } from "node:test";
import type { ChildProcess, SpawnOptions } from "node:child_process";
import { HELPER, OPERATIONS, SUDO, helperCommand, knownOperation, runHelper, type LogLine } from "./operations";

interface Call {
  file: string;
  args: readonly string[];
  options: SpawnOptions;
}

/** A stand-in for child_process.spawn that records the call and plays back output. */
function fakeSpawn(out: string, err: string, code: number | null) {
  const calls: Call[] = [];
  const spawn = (file: string, args: readonly string[], options: SpawnOptions): ChildProcess => {
    calls.push({ file, args, options });
    const child = new EventEmitter() as ChildProcess;
    const stdout = new PassThrough();
    const stderr = new PassThrough();
    Object.assign(child, { stdout, stderr });
    setImmediate(() => {
      stdout.end(out);
      stderr.end(err);
      setImmediate(() => child.emit("close", code));
    });
    return child;
  };
  return { calls, spawn };
}

test("the list is exactly the five operations of the helper", () => {
  assert.deepEqual([...OPERATIONS], ["status", "check", "update", "apply", "rollback"]);
  assert.equal(SUDO, "/usr/bin/sudo");
  assert.equal(HELPER, "/etc/ally-x20-steamos/control-center-helper");
});

test("knownOperation accepts the five words and nothing else", () => {
  for (const op of OPERATIONS) assert.equal(knownOperation(op), op);
  const bad: unknown[] = [
    "", "status ", " status", "STATUS", "status; id", "status --json", "--root", "--root=/", "-h", "install",
    "uninstall", "self-update", "$(id)", "`id`", "status\nid", "../status", "constructor", "__proto__", "toString",
    0, 1, null, undefined, true, ["status"], { op: "status" }, { toString: () => "status" },
  ];
  for (const b of bad) assert.equal(knownOperation(b), null, JSON.stringify(b));
});

test("the command line is sudo -n <helper> <word>, built from constants", () => {
  for (const op of OPERATIONS) {
    assert.deepEqual(helperCommand(op), { file: "/usr/bin/sudo", args: ["-n", "/etc/ally-x20-steamos/control-center-helper", op] });
  }
});

test("runHelper spawns exactly that, without a shell, and returns status and output", async () => {
  const { calls, spawn } = fakeSpawn("line one\nline two\n", "ally-x20-steamos: applying component: audio\n", 0);
  const lines: LogLine[] = [];
  const r = await runHelper("apply", (l) => lines.push(l), spawn);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].file, "/usr/bin/sudo");
  assert.deepEqual(calls[0].args, ["-n", "/etc/ally-x20-steamos/control-center-helper", "apply"]);
  assert.equal(calls[0].options.shell, false);
  assert.deepEqual(calls[0].options.stdio, ["ignore", "pipe", "pipe"]);
  assert.deepEqual(Object.keys(calls[0].options.env ?? {}).sort(), ["LANG", "PATH"]);
  assert.deepEqual(r, { code: 0, stdout: "line one\nline two\n" });
  assert.deepEqual(
    lines.map((l) => `${l.op}/${l.stream}/${l.line}`).sort(),
    ["apply/stderr/ally-x20-steamos: applying component: audio", "apply/stdout/line one", "apply/stdout/line two"],
  );
});

test("runHelper passes the exit status through (4 = some components failed) and maps a signal to -1", async () => {
  const partial = fakeSpawn("", "ally-x20-steamos: error: component hdr failed to apply\n", 4);
  assert.equal((await runHelper("update", () => {}, partial.spawn)).code, 4);
  const killed = fakeSpawn("", "", null);
  assert.equal((await runHelper("check", () => {}, killed.spawn)).code, -1);
});

test("runHelper keeps the status JSON out of the log lines", async () => {
  const { spawn } = fakeSpawn('{\n  "name": "ally-x20-steamos"\n}\n', "", 0);
  const lines: LogLine[] = [];
  const r = await runHelper("status", (l) => lines.push(l), spawn);
  assert.equal(lines.length, 0);
  assert.equal(JSON.parse(r.stdout).name, "ally-x20-steamos");
});

test("runHelper refuses anything else before a process exists", async () => {
  const { calls, spawn } = fakeSpawn("", "", 0);
  for (const bad of ["status; id", "status --json", "--root", "", ["status"], null, { op: "apply" }]) {
    await assert.rejects(runHelper(bad, () => {}, spawn), /unknown operation/);
  }
  assert.equal(calls.length, 0);
});
