// SPDX-License-Identifier: GPL-2.0-only
// Update: check, update, apply, rollback, with the output of the CLI below.
import { useEffect, useRef, useState } from "react";
import { backend, explainExit, failedComponents, hasApplyOutcomes, outcomeOf, type LogLine, type Operation, type Status } from "../backend";
import { Tile } from "../Tile";

type Action = Exclude<Operation, "status">;

const ACTIONS: { op: Action; icon: string; label: string; confirm: boolean; help: string }[] = [
  { op: "check", icon: "check", label: "Check", confirm: false, help: "Ask the release server whether a newer signed release exists. Changes nothing." },
  { op: "update", icon: "update", label: "Update", confirm: true, help: "Install the newest release signed by a pinned key, then apply it." },
  { op: "apply", icon: "apply", label: "Apply", confirm: false, help: "Re-install the files of every enabled component (repairs drift)." },
  { op: "rollback", icon: "rollback", label: "Rollback", confirm: true, help: "Go back to the version that was installed before the last update." },
];

interface Props {
  status: Status | null;
  /** Called after an operation that may have changed the status. */
  onChanged: () => void;
  /** Lets the app know an operation is running (B must not leave mid-update). */
  onBusy: (busy: boolean) => void;
}

export function Update({ status, onChanged, onBusy }: Props) {
  const [busy, setBusy] = useState<Action | null>(null);
  const [armed, setArmed] = useState<Action | null>(null);
  const [log, setLog] = useState<LogLine[]>([]);
  const [help, setHelp] = useState(ACTIONS[0].help);
  const logEnd = useRef<HTMLDivElement>(null);

  useEffect(() => {
    logEnd.current?.scrollIntoView({ block: "nearest" });
  }, [log]);

  const append = (l: LogLine) => setLog((prev) => [...prev.slice(-400), l]);

  const run = async (op: Action, needsConfirm: boolean) => {
    if (busy) return;
    if (needsConfirm && armed !== op) {
      setArmed(op);
      return;
    }
    setArmed(null);
    setBusy(op);
    onBusy(true);
    append({ op, stream: "ui", line: `$ ${op}` });
    try {
      const r = await backend.run(op, append);
      const outcome = outcomeOf(r.code);
      append({
        op,
        stream: "ui",
        line: outcome === "ok" ? "done" : outcome === "partial" ? `${explainExit(r.code)}; the rest was applied` : `failed: ${explainExit(r.code)}`,
      });
    } catch (e) {
      append({ op, stream: "ui", line: `failed: ${String(e)}` });
    } finally {
      setBusy(null);
      onBusy(false);
      onChanged();
    }
  };

  const check = status?.last_update_check;
  const failed = failedComponents(status);
  const skipped = status ? status.components.filter((c) => c.last_apply === "skipped") : [];

  return (
    <>
      <section className="group" aria-label="Update">
        <h2>
          Update
          <span className="group-note">
            {status ? `installed v${status.version}` : ""}
            {check?.result === "available" ? ` · ${check.ref} available` : ""}
          </span>
        </h2>
        <div className="mode-row">
          {ACTIONS.map((a, i) => (
            <Tile
              key={a.op}
              variant="mode"
              icon={a.icon}
              label={busy === a.op ? "Running…" : armed === a.op ? "A again" : a.label}
              selected={busy === a.op || armed === a.op}
              disabled={busy !== null && busy !== a.op}
              autoFocus={i === 0}
              onSelect={() => void run(a.op, a.confirm)}
              onFocus={() => {
                setHelp(a.help);
                if (armed && armed !== a.op) setArmed(null);
              }}
            />
          ))}
        </div>
      </section>

      <p className="detail" aria-live="polite">
        {armed ? "Press A again to confirm, or move away to cancel." : help}
      </p>

      {hasApplyOutcomes(status) && (failed.length > 0 || skipped.length > 0) && (
        <section className={`outcomes ${failed.length > 0 ? "is-alert" : ""}`} aria-label="Last apply">
          <h2>
            {failed.length > 0 ? `Last ${status?.last_apply?.command ?? "apply"}: ${failed.length} failed, the rest went through` : "Last apply"}
          </h2>
          <ul>
            {failed.map((c) => (
              <li key={c.name}>
                <span className="outcome-word outcome-failed">failed</span>
                <span className="outcome-name">{c.name}</span>
                <span className="outcome-reason">{c.last_apply_reason || "no reason recorded"}</span>
              </li>
            ))}
            {skipped.map((c) => (
              <li key={c.name}>
                <span className="outcome-word">skipped</span>
                <span className="outcome-name">{c.name}</span>
                <span className="outcome-reason">{c.last_apply_reason}</span>
              </li>
            ))}
          </ul>
        </section>
      )}

      <div className="log" data-focusable tabIndex={0} role="log" aria-label="Output">
        {log.length === 0 && <div className="log-empty">Output appears here.</div>}
        {log.map((l, i) => (
          <div key={i} className={`log-line log-${l.stream}`}>
            {l.line}
          </div>
        ))}
        <div ref={logEnd} />
      </div>
    </>
  );
}
