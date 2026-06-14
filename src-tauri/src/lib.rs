mod devpod;
mod hooks;
mod notify;
mod poller;
mod pty;

use std::sync::Arc;
use tauri::Emitter;

use devpod::{CommandRunner, DevpodCli};

pub struct AppState {
    pub runner: Arc<dyn CommandRunner>,
    pub sessions: Arc<pty::SessionRegistry>,
    pub notify_token: String,
}

/// Quote a string as an AppleScript string literal for `osascript -e`.
fn applescript_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        if c == '"' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

#[tauri::command]
fn list_workspaces(state: tauri::State<AppState>) -> Result<Vec<poller::WorkspaceView>, String> {
    poller::poll_once(state.runner.as_ref())
}

#[tauri::command]
fn start_workspace(state: tauri::State<AppState>, id: String) -> Result<(), String> {
    devpod::up(state.runner.as_ref(), &id)
}

#[tauri::command]
fn stop_workspace(state: tauri::State<AppState>, id: String) -> Result<(), String> {
    devpod::stop(state.runner.as_ref(), &id)
}

#[tauri::command]
fn delete_workspace(state: tauri::State<AppState>, id: String) -> Result<(), String> {
    devpod::delete(state.runner.as_ref(), &id)
}

#[tauri::command]
fn connect_pty(app: tauri::AppHandle, state: tauri::State<AppState>, id: String) -> Result<(), String> {
    // Reject hostile ids before doing anything (defense in depth; ssh_args also
    // passes the id after `--`).
    devpod::validate_id(&id)?;
    // Inject the Claude hook off the open path (idempotent, best-effort): it
    // makes two ssh round-trips, so doing it inline would delay the terminal
    // appearing. A hook failure must never block opening the terminal. The
    // per-run token is baked into the injected hook (we connect with plain ssh,
    // so it can't be passed via the environment).
    let inject_runner = state.runner.clone();
    let inject_id = id.clone();
    let inject_token = state.notify_token.clone();
    std::thread::spawn(move || {
        let _ = hooks::inject(inject_runner.as_ref(), &inject_id, &inject_token);
    });
    let out_handle = app.clone();
    let out_pod = id.clone();
    let close_handle = app.clone();
    let close_pod = id.clone();
    let sessions = state.sessions.clone();
    state.sessions.ensure(
        &id,
        move |bytes| {
            let _ = out_handle.emit(&format!("pty-output:{out_pod}"), bytes);
        },
        move || {
            // Remove the dead session BEFORE signalling the frontend, so a
            // reconnect triggered by `pty-closed` can't race `ensure` against a
            // still-present (but dead) session and silently no-op.
            sessions.close(&close_pod);
            let _ = close_handle.emit(&format!("pty-closed:{close_pod}"), ());
        },
    )
}

#[tauri::command]
fn write_pty(state: tauri::State<AppState>, id: String, data: Vec<u8>) -> Result<(), String> {
    state.sessions.write(&id, &data)
}

#[tauri::command]
fn resize_pty(state: tauri::State<AppState>, id: String, rows: u16, cols: u16) -> Result<(), String> {
    state.sessions.resize(&id, rows, cols)
}

#[tauri::command]
fn disconnect_pty(state: tauri::State<AppState>, id: String) {
    state.sessions.close(&id);
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let runner: Arc<dyn CommandRunner> = Arc::new(DevpodCli);
    // Fail closed: if the OS RNG is unavailable we run WITHOUT notifications
    // rather than with a predictable token. Empty token => listener not started.
    let notify_token = notify::random_token().unwrap_or_else(|e| {
        eprintln!("notifications disabled: {e}");
        String::new()
    });

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            runner: runner.clone(),
            sessions: Arc::new(pty::SessionRegistry::new()),
            notify_token: notify_token.clone(),
        })
        .setup(move |app| {
            let handle = app.handle().clone();
            poller::spawn_loop(
                runner.clone(),
                std::time::Duration::from_secs(10),
                move |views| {
                    let _ = handle.emit("workspaces-updated", views);
                },
            );
            // Empty token means RNG was unavailable — leave notifications off.
            if !notify_token.is_empty() {
                let notify_handle = app.handle().clone();
                if let Err(e) = notify::serve(notify_token.clone(), move |pod_id, message| {
                    // Deliver via `osascript display notification`. The Tauri
                    // notification plugin's macOS backend (mac-notification-sys /
                    // the deprecated NSUserNotification) is silently dropped for
                    // ad-hoc-signed dev builds; osascript renders regardless of
                    // code signature.
                    let title = applescript_quote(&format!("DevSpace: {pod_id}"));
                    let body = applescript_quote(&message);
                    let script = format!("display notification {body} with title {title}");
                    if let Err(e) = std::process::Command::new("osascript")
                        .arg("-e")
                        .arg(&script)
                        .status()
                    {
                        eprintln!("notification failed: {e}");
                    }
                    let _ = notify_handle.emit("pod-badge", pod_id);
                }) {
                    eprintln!("notifications disabled: {e}");
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_workspaces,
            start_workspace,
            stop_workspace,
            delete_workspace,
            connect_pty,
            write_pty,
            resize_pty,
            disconnect_pty
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
