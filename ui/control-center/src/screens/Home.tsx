// SPDX-License-Identifier: GPL-2.0-only
// Home: version, kernel and module state, and one tile per component.
import { useState } from "react";
import type { Status } from "../backend";
import { Icon } from "../icons";
import { Tile } from "../Tile";

const STATE_WORD: Record<string, string> = {
  active: "Active",
  stock: "Not applied",
  superseded: "In SteamOS",
  off: "Off",
  "n/a": "Unknown",
  error: "Error",
};

function updateLine(s: Status): string {
  const c = s.last_update_check;
  if (!c) return "Updates: never checked";
  switch (c.result) {
    case "available":
      return `Update available: ${c.ref}`;
    case "available-unverified":
      return `Update ${c.ref} is not signed by a pinned key`;
    case "fetch-failed":
      return "Updates: last check could not reach the server";
    default:
      return "Up to date";
  }
}

export function Home({ status, error, onOpenUpdate }: { status: Status | null; error: string | null; onOpenUpdate: () => void }) {
  const [detail, setDetail] = useState<string>("");

  if (error) {
    return (
      <div className="notice notice-error" role="alert">
        <strong>Cannot read the status.</strong>
        <span>{error}</span>
        <span>Press Y to try again.</span>
      </div>
    );
  }
  if (!status) return <div className="notice">Reading status…</div>;

  return (
    <>
      <button type="button" className="banner" data-focusable data-autofocus="" onClick={onOpenUpdate}>
        <span>{updateLine(status)}</span>
        <Icon name="chevron" size={20} />
      </button>

      <section className="group" aria-label="System">
        <h2>System</h2>
        <div className="mode-row">
          <Tile variant="mode" icon="version" label={`v${status.version}`} state="Version" muted onFocus={() => setDetail(`ally-x20-steamos ${status.version} (${status.commit || "no commit"})`)} />
          <Tile variant="mode" icon="kernel" label={status.kernel.running.split("-")[0]} state="Kernel" muted onFocus={() => setDetail(`Running kernel: ${status.kernel.running}`)} />
          <Tile
            variant="mode"
            icon="modules"
            label={status.kernel.modules_staged ? "Staged" : "Missing"}
            state="Modules"
            selected={!status.kernel.modules_staged}
            muted={status.kernel.modules_staged}
            onFocus={() =>
              setDetail(
                status.kernel.modules_staged
                  ? "Patched kernel modules are staged for the running kernel."
                  : "No patched modules for the running kernel yet: the stock modules are in use. Apply (Update screen) or reboot retries.",
              )
            }
          />
          <Tile
            variant="mode"
            icon="policy"
            label={status.update_policy}
            state="Policy"
            muted
            onFocus={() => setDetail(`SteamOS update policy: ${status.update_policy}${status.pending_reboot_check ? "; a reboot check is pending" : ""}`)}
          />
        </div>
      </section>

      <section className="grid" aria-label="Components">
        {status.components.map((c) => (
          <Tile
            key={c.name}
            icon={c.name}
            label={c.name}
            state={STATE_WORD[c.status] ?? c.status}
            muted={c.status === "superseded" || c.status === "off"}
            onFocus={() => setDetail(`${c.name}: ${c.description}`)}
          />
        ))}
      </section>

      <p className="detail" aria-live="polite">
        {detail}
      </p>
    </>
  );
}
