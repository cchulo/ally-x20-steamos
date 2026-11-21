// SPDX-License-Identifier: GPL-2.0-only
import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";

// The packaged page gets a strict Content-Security-Policy: scripts, styles,
// images and fonts only from the app's own files, no connections at all.
// It is added at build time only, because the dev server needs inline
// scripts and a WebSocket for hot reload.
const CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "object-src 'none'",
].join("; ");

const cspMeta: Plugin = {
  name: "control-center-csp",
  apply: "build",
  transformIndexHtml: () => [
    { tag: "meta", attrs: { "http-equiv": "Content-Security-Policy", content: CSP }, injectTo: "head-prepend" },
  ],
};

export default defineConfig({
  plugins: [react(), cspMeta],
  // Relative asset URLs: Electron loads dist/index.html from a file.
  base: "./",
  clearScreen: false,
  server: { port: 5173, strictPort: true, host: "127.0.0.1" },
  build: { target: "es2022", sourcemap: false, modulePreload: false },
});
