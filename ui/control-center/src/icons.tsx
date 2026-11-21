// SPDX-License-Identifier: GPL-2.0-only
// Every icon in this app is drawn here, by hand, for this project
// (GPL-2.0-only like the rest). Nothing is copied from ASUS software or
// from an icon set. 24x24 grid, 1.6 stroke, currentColor.
import type { ReactNode } from "react";

const paths: Record<string, ReactNode> = {
  home: (
    <>
      <path d="M4 11 12 4l8 7" />
      <path d="M6.5 9.5V19h11V9.5" />
      <path d="M10 19v-5h4v5" />
    </>
  ),
  update: (
    <>
      <path d="M12 4v10" />
      <path d="m8 10.5 4 4 4-4" />
      <path d="M5 16.5V19h14v-2.5" />
    </>
  ),
  check: (
    <>
      <circle cx="11" cy="11" r="6" />
      <path d="m15.5 15.5 4 4" />
    </>
  ),
  apply: (
    <>
      <path d="M19 12a7 7 0 1 1-2.2-5.1" />
      <path d="M19 5v4h-4" />
      <path d="m9.5 12 2 2 3.5-4" />
    </>
  ),
  rollback: (
    <>
      <path d="M5 12a7 7 0 1 0 2.2-5.1" />
      <path d="M5 5v4h4" />
      <path d="M12 8.5V12l2.5 1.5" />
    </>
  ),
  close: (
    <>
      <path d="M12 4v8" />
      <path d="M7.5 6.8a7 7 0 1 0 9 0" />
    </>
  ),
  chevron: <path d="m9 5 7 7-7 7" />,
  version: (
    <>
      <path d="M4 5h9l7 7-8 8-8-8z" />
      <circle cx="8.5" cy="9.5" r="1.3" />
    </>
  ),
  kernel: (
    <>
      <rect x="7" y="7" width="10" height="10" rx="1.5" />
      <path d="M10 4v3M14 4v3M10 17v3M14 17v3M4 10h3M4 14h3M17 10h3M17 14h3" />
    </>
  ),
  modules: (
    <>
      <path d="m12 3 8 4.5v9L12 21l-8-4.5v-9z" />
      <path d="m4 7.5 8 4.5 8-4.5M12 12v9" />
    </>
  ),
  policy: (
    <>
      <path d="M12 3 5 6v5.5c0 4.3 2.9 7.6 7 9.5 4.1-1.9 7-5.2 7-9.5V6z" />
      <path d="m9 12 2.2 2.2L15 10" />
    </>
  ),
  audio: (
    <>
      <path d="M4 9.5h3.5L12 6v12l-4.5-3.5H4z" />
      <path d="M15.5 9a4.5 4.5 0 0 1 0 6M18 6.5a8 8 0 0 1 0 11" />
    </>
  ),
  controlcenter: (
    <>
      <rect x="3.5" y="5" width="8" height="14" rx="1.5" />
      <path d="M15 8h5.5M15 12h5.5M15 16h5.5" />
    </>
  ),
  hdr: (
    <>
      <circle cx="12" cy="12" r="3.5" />
      <path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1" />
    </>
  ),
  inputplumber: (
    <>
      <path d="M7 8h10a4 4 0 0 1 4 4v1.5a3 3 0 0 1-5.4 1.8L15 14.5H9l-.6.8A3 3 0 0 1 3 13.5V12a4 4 0 0 1 4-4z" />
      <path d="M7.5 10.2v2.6M6.2 11.5h2.6" />
      <circle cx="16.3" cy="11.5" r="0.9" />
    </>
  ),
  power: (
    <>
      <path d="M13 3 6 13.5h5L10.5 21 18 10h-5z" />
    </>
  ),
  sdexpress: (
    <>
      <path d="M7 3.5h7l4 4V20.5H7z" />
      <path d="M10 6.5v3M12.5 6.5v3" />
    </>
  ),
  xboxled: (
    <>
      <circle cx="12" cy="12" r="7.5" />
      <circle cx="12" cy="12" r="3" />
    </>
  ),
  component: (
    <>
      <rect x="4.5" y="4.5" width="6.5" height="6.5" rx="1" />
      <rect x="13" y="4.5" width="6.5" height="6.5" rx="1" />
      <rect x="4.5" y="13" width="6.5" height="6.5" rx="1" />
      <rect x="13" y="13" width="6.5" height="6.5" rx="1" />
    </>
  ),
};


export function Icon({ name, size = 28 }: { name: string; size?: number }) {
  return (
    <svg
      className="icon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name] ?? paths.component}
    </svg>
  );
}
