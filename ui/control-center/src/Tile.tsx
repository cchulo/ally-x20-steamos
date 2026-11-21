// SPDX-License-Identifier: GPL-2.0-only
import { Icon } from "./icons";

interface TileProps {
  icon: string;
  label: string;
  /** Short state word shown in the accent color above the label ("Active", "Off"). */
  state?: string;
  /** Dim the state word (nothing to act on). */
  muted?: boolean;
  selected?: boolean;
  disabled?: boolean;
  autoFocus?: boolean;
  /** "mode" = the wide row tiles with the label under the box, "grid" = square tiles. */
  variant?: "mode" | "grid";
  onSelect?: () => void;
  onFocus?: () => void;
}

export function Tile(p: TileProps) {
  const cls = ["tile", `tile-${p.variant ?? "grid"}`, p.selected ? "is-selected" : "", p.muted ? "is-muted" : ""]
    .filter(Boolean)
    .join(" ");
  return (
    <button
      type="button"
      className={cls}
      data-focusable
      data-autofocus={p.autoFocus ? "" : undefined}
      disabled={p.disabled}
      aria-pressed={p.selected}
      onClick={p.onSelect}
      onFocus={p.onFocus}
    >
      <span className="tile-box">
        <Icon name={p.icon} size={p.variant === "mode" ? 30 : 34} />
      </span>
      {p.state !== undefined && <span className="tile-state">{p.state}</span>}
      <span className="tile-label">{p.label}</span>
    </button>
  );
}
