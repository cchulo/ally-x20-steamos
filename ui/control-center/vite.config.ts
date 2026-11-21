// SPDX-License-Identifier: GPL-2.0-only
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Fixed port: src-tauri/tauri.conf.json points `devUrl` at it.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 5173, strictPort: true, host: "127.0.0.1" },
  build: { target: "es2022", sourcemap: false },
});
