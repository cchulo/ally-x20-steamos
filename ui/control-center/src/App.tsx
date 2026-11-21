// SPDX-License-Identifier: GPL-2.0-only
// The panel: rail (screens, close) on the left, header, the current screen,
// and the footer with the controller hints.
import { useCallback, useEffect, useRef, useState } from "react";
import { backend, fetchStatus, type Status } from "./backend";
import { Icon } from "./icons";
import { moveFocus, useControllerNav } from "./nav";
import { Home } from "./screens/Home";
import { Update } from "./screens/Update";

type Screen = "home" | "update";
const SCREENS: { id: Screen; icon: string; label: string }[] = [
  { id: "home", icon: "home", label: "Home" },
  { id: "update", icon: "update", label: "Update" },
];

export function App() {
  const [screen, setScreen] = useState<Screen>("home");
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState<string | null>(null);
  const busy = useRef(false);

  const refresh = useCallback(() => {
    fetchStatus()
      .then((s) => {
        setStatus(s);
        setError(null);
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  }, []);

  useEffect(refresh, [refresh]);

  // Put the focus on the screen's first element whenever the screen changes.
  useEffect(() => {
    const t = setTimeout(() => {
      const el = document.querySelector<HTMLElement>("main [data-autofocus]") ?? document.querySelector<HTMLElement>("main [data-focusable]");
      if (el) el.focus();
      else moveFocus("down");
    }, 0);
    return () => clearTimeout(t);
  }, [screen, status === null, error]);

  useControllerNav({
    onBack: () => {
      if (busy.current) return; // never leave in the middle of an update
      if (screen !== "home") setScreen("home");
      else backend.quit();
    },
    onRefresh: refresh,
    onShoulder: (d) => {
      if (busy.current) return;
      const i = SCREENS.findIndex((s) => s.id === screen);
      setScreen(SCREENS[(i + d + SCREENS.length) % SCREENS.length].id);
    },
  });

  return (
    <div className="stage">
      <div className="panel" role="application" aria-label="Control Center">
        <header className="panel-header">
          <span className="panel-title">Control Center</span>
          <span className="panel-sub">
            {status ? `ally-x20-steamos ${status.version}` : ""}
            {backend.kind === "mock" ? " · mock data" : ""}
          </span>
        </header>

        <div className="panel-body">
          <nav className="rail" aria-label="Screens">
            {SCREENS.map((s) => (
              <button
                key={s.id}
                type="button"
                className={`rail-btn ${screen === s.id ? "is-current" : ""}`}
                data-focusable
                aria-label={s.label}
                aria-current={screen === s.id}
                onClick={() => setScreen(s.id)}
              >
                <Icon name={s.icon} size={24} />
              </button>
            ))}
            <span className="rail-gap" />
            <button type="button" className="rail-btn" data-focusable aria-label="Close" onClick={() => backend.quit()}>
              <Icon name="close" size={24} />
            </button>
          </nav>

          <main className="content">
            {screen === "home" ? (
              <Home status={status} error={error} onOpenUpdate={() => setScreen("update")} />
            ) : (
              <Update status={status} onChanged={refresh} onBusy={(b) => (busy.current = b)} />
            )}
          </main>
        </div>

        <footer className="panel-footer">
          <span className="hint">
            <kbd className="pad pad-y">Y</kbd> Refresh
          </span>
          <span className="hint">
            <kbd className="pad pad-b">B</kbd> {screen === "home" ? "Close" : "Back"}
          </span>
          <span className="hint">
            <kbd className="pad pad-a">A</kbd> Select
          </span>
        </footer>
      </div>
    </div>
  );
}
