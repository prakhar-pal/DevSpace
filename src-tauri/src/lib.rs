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
    // Inject the Claude hook once per connect (idempotent). Best-effort: a hook
    // failure should not block opening the terminal.
    let _ = hooks::inject(state.runner.as_ref(), &id);
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
            let _ = close_handle.emit(&format!("pty-closed:{close_pod}"), ());
            sessions.close(&close_pod);
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

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .manage(AppState {
            runner: runner.clone(),
            sessions: Arc::new(pty::SessionRegistry::new()),
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
            let notify_handle = app.handle().clone();
            if let Err(e) = notify::serve(move |pod_id, message| {
                use tauri_plugin_notification::NotificationExt;
                let _ = notify_handle
                    .notification()
                    .builder()
                    .title(format!("DevSpace: {pod_id}"))
                    .body(&message)
                    .show();
                let _ = notify_handle.emit("pod-badge", pod_id);
            }) {
                eprintln!("notifications disabled: {e}");
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
