// SPDX-License-Identifier: GPL-2.0-only
// Focus navigation for a controller: every element with [data-focusable]
// can be reached with the arrow keys or the D-pad / left stick; A (or
// Enter) activates it, B (or Escape/Backspace) goes back, Y refreshes,
// LB/RB switch screens. Movement is spatial: the nearest focusable element
// in the pressed direction wins.
import { useEffect, useRef } from "react";

export type Direction = "up" | "down" | "left" | "right";

export interface NavHandlers {
  onBack(): void;
  onRefresh(): void;
  onShoulder(delta: -1 | 1): void;
}

function focusables(): HTMLElement[] {
  return Array.from(document.querySelectorAll<HTMLElement>("[data-focusable]")).filter(
    (el) => !el.hasAttribute("disabled") && el.offsetParent !== null,
  );
}

/** Move focus one step. Exported for tests and for the keyboard handler. */
export function moveFocus(dir: Direction): void {
  const all = focusables();
  if (all.length === 0) return;
  const cur = document.activeElement as HTMLElement | null;
  if (!cur || !all.includes(cur)) {
    (all.find((el) => el.hasAttribute("data-autofocus")) ?? all[0]).focus();
    return;
  }
  const a = cur.getBoundingClientRect();
  const ax = a.left + a.width / 2;
  const ay = a.top + a.height / 2;
  let best: HTMLElement | null = null;
  let bestScore = Infinity;
  for (const el of all) {
    if (el === cur) continue;
    const b = el.getBoundingClientRect();
    const dx = b.left + b.width / 2 - ax;
    const dy = b.top + b.height / 2 - ay;
    // along = distance in the pressed direction, across = sideways offset
    const along = dir === "left" ? -dx : dir === "right" ? dx : dir === "up" ? -dy : dy;
    const across = Math.abs(dir === "left" || dir === "right" ? dy : dx);
    if (along <= 1) continue;
    const score = along + across * 3;
    if (score < bestScore) {
      bestScore = score;
      best = el;
    }
  }
  if (best) {
    best.focus();
    best.scrollIntoView({ block: "nearest", inline: "nearest" });
  }
}

// Standard Gamepad API mapping (https://w3c.github.io/gamepad/#remapping).
const BTN = { a: 0, b: 1, y: 3, lb: 4, rb: 5, up: 12, down: 13, left: 14, right: 15 };
const REPEAT_DELAY_MS = 380;
const REPEAT_RATE_MS = 110;
const STICK_THRESHOLD = 0.55;

export function useControllerNav(handlers: NavHandlers): void {
  const h = useRef(handlers);
  h.current = handlers;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const dirs: Record<string, Direction> = {
        ArrowUp: "up",
        ArrowDown: "down",
        ArrowLeft: "left",
        ArrowRight: "right",
      };
      if (dirs[e.key]) {
        e.preventDefault();
        moveFocus(dirs[e.key]);
      } else if (e.key === "Escape" || e.key === "Backspace") {
        e.preventDefault();
        h.current.onBack();
      } else if (e.key === "F5" || e.key === "y") {
        e.preventDefault();
        h.current.onRefresh();
      } else if (e.key === "PageUp" || e.key === "PageDown") {
        e.preventDefault();
        h.current.onShoulder(e.key === "PageUp" ? -1 : 1);
      }
      // Enter and Space activate the focused <button> natively.
    };
    window.addEventListener("keydown", onKey);

    // Gamepad polling. `held` remembers when a control went down and when
    // it last repeated, so directions auto-repeat and buttons fire once.
    const held = new Map<string, { since: number; last: number }>();
    let raf = 0;
    const press = (key: string, down: boolean, now: number, repeat: boolean, fire: () => void) => {
      const st = held.get(key);
      if (!down) {
        held.delete(key);
      } else if (!st) {
        held.set(key, { since: now, last: now });
        fire();
      } else if (repeat && now - st.since > REPEAT_DELAY_MS && now - st.last > REPEAT_RATE_MS) {
        st.last = now;
        fire();
      }
    };
    const poll = (now: number) => {
      raf = requestAnimationFrame(poll);
      if (!document.hasFocus()) return;
      const pads = navigator.getGamepads ? navigator.getGamepads() : [];
      for (const pad of pads) {
        if (!pad) continue;
        const b = (i: number) => pad.buttons[i]?.pressed ?? false;
        const x = pad.axes[0] ?? 0;
        const y = pad.axes[1] ?? 0;
        const id = pad.index;
        press(`${id}u`, b(BTN.up) || y < -STICK_THRESHOLD, now, true, () => moveFocus("up"));
        press(`${id}d`, b(BTN.down) || y > STICK_THRESHOLD, now, true, () => moveFocus("down"));
        press(`${id}l`, b(BTN.left) || x < -STICK_THRESHOLD, now, true, () => moveFocus("left"));
        press(`${id}r`, b(BTN.right) || x > STICK_THRESHOLD, now, true, () => moveFocus("right"));
        press(`${id}a`, b(BTN.a), now, false, () => (document.activeElement as HTMLElement | null)?.click());
        press(`${id}b`, b(BTN.b), now, false, () => h.current.onBack());
        press(`${id}y`, b(BTN.y), now, false, () => h.current.onRefresh());
        press(`${id}lb`, b(BTN.lb), now, false, () => h.current.onShoulder(-1));
        press(`${id}rb`, b(BTN.rb), now, false, () => h.current.onShoulder(1));
      }
    };
    raf = requestAnimationFrame(poll);

    return () => {
      window.removeEventListener("keydown", onKey);
      cancelAnimationFrame(raf);
    };
  }, []);
}
