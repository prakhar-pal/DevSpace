mod devpod;
mod notify;
mod poller;

use std::sync::Arc;
use tauri::Emitter;

use devpod::{CommandRunner, DevpodCli};

pub struct AppState {
    pub runner: Arc<dyn CommandRunner>,
}

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let runner: Arc<dyn CommandRunner> = Arc::new(DevpodCli);

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .manage(AppState { runner: runner.clone() })
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
            greet,
            list_workspaces,
            start_workspace,
            stop_workspace,
            delete_workspace
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
