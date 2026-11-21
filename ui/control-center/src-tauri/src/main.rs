// SPDX-License-Identifier: GPL-2.0-only
//! Control Center shell: a window for the React UI and two commands.
//!
//! `run_helper` is the only way the UI can cause anything to happen outside
//! its window. It starts
//!
//!     sudo -n /etc/ally-x20-steamos/control-center-helper <operation>
//!
//! with `<operation>` taken from a fixed list (the same list the helper and
//! the sudoers drop-in have; see docs/control-center.md). No shell is
//! involved, nothing from the UI is passed on except the choice of the
//! operation, and this process never runs as root.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{BufRead, BufReader, Read};
use std::process::{Command, Stdio};
use std::thread;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

const SUDO: &str = "/usr/bin/sudo";
const HELPER: &str = "/etc/ally-x20-steamos/control-center-helper";
/// Keep in step with overlay/bin/control-center-helper and
/// overlay/sudoers.d/zz-ally-x20-steamos-control-center.
const OPERATIONS: [&str; 5] = ["status", "check", "update", "apply", "rollback"];

#[derive(Clone, Serialize)]
struct LogLine {
    op: &'static str,
    stream: &'static str,
    line: String,
}

#[derive(Serialize)]
struct RunResult {
    code: i32,
    stdout: String,
}

/// The operation as one of our own constants, or None.
fn known_operation(op: &str) -> Option<&'static str> {
    OPERATIONS.iter().copied().find(|known| *known == op)
}

/// Forward every line of `reader` to the UI as a `helper-log` event and
/// return everything that was read.
fn pump(app: &AppHandle, op: &'static str, stream: &'static str, reader: impl Read) -> String {
    let mut all = String::new();
    for line in BufReader::new(reader).lines() {
        let Ok(line) = line else { break };
        all.push_str(&line);
        all.push('\n');
        // `status` prints one JSON document; the UI gets it as the result.
        if op != "status" || stream != "stdout" {
            let _ = app.emit("helper-log", LogLine { op, stream, line });
        }
    }
    all
}

fn run_blocking(app: AppHandle, op: &'static str) -> Result<RunResult, String> {
    let mut child = Command::new(SUDO)
        .args(["-n", HELPER, op])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot start {SUDO}: {e}"))?;
    let stdout = child.stdout.take().ok_or("no stdout pipe")?;
    let stderr = child.stderr.take().ok_or("no stderr pipe")?;
    let err_app = app.clone();
    let err_thread = thread::spawn(move || pump(&err_app, op, "stderr", stderr));
    let out = pump(&app, op, "stdout", stdout);
    let _ = err_thread.join();
    let status = child
        .wait()
        .map_err(|e| format!("waiting for the helper failed: {e}"))?;
    Ok(RunResult {
        // Killed by a signal: no exit code.
        code: status.code().unwrap_or(-1),
        stdout: out,
    })
}

#[tauri::command]
async fn run_helper(app: AppHandle, op: String) -> Result<RunResult, String> {
    let op = known_operation(&op).ok_or_else(|| "unknown operation".to_string())?;
    tauri::async_runtime::spawn_blocking(move || run_blocking(app, op))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![run_helper, quit])
        .run(tauri::generate_context!())
        .expect("error while running the Control Center");
}

#[cfg(test)]
mod tests {
    use super::known_operation;

    #[test]
    fn only_the_five_operations_are_known() {
        for op in ["status", "check", "update", "apply", "rollback"] {
            assert_eq!(known_operation(op), Some(op));
        }
        for bad in [
            "",
            "status ",
            "status; id",
            "--root",
            "install",
            "STATUS",
            "status --json",
        ] {
            assert_eq!(known_operation(bad), None, "{bad:?}");
        }
    }
}
