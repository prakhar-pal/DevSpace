mod devpod;
mod hooks;
mod notify;
mod poller;
mod pty;

use std::sync::Arc;
use tauri::{Emitter, Manager};

use devpod::{CommandRunner, DevpodCli};

pub struct AppState {
    pub runner: Arc<dyn CommandRunner>,
    pub sessions: Arc<pty::SessionRegistry>,
    pub notify_token: String,
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
    notify::log(&format!("connect_pty: pod={id} (injecting hook + opening ssh)"));
    std::thread::spawn(move || {
        match hooks::inject(inject_runner.as_ref(), &inject_id, &inject_token) {
            Ok(()) => notify::log(&format!("inject: hook written to pod={inject_id}")),
            Err(e) => notify::log(&format!("inject: FAILED pod={inject_id}: {e}")),
        }
    });
    let out_handle = app.clone();
    let out_pod = id.clone();
    let close_handle = app.clone();
    let close_pod = id.clone();
    let sessions = state.sessions.clone();
    let res = state.sessions.ensure(
        &id,
        move |bytes| {
            let _ = out_handle.emit(&format!("pty-output:{out_pod}"), bytes);
        },
        move || {
            notify::log(&format!("session closed (reader EOF) pod={close_pod}"));
            // Remove the dead session BEFORE signalling the frontend, so a
            // reconnect triggered by `pty-closed` can't race `ensure` against a
            // still-present (but dead) session and silently no-op.
            sessions.close(&close_pod);
            let _ = close_handle.emit(&format!("pty-closed:{close_pod}"), ());
        },
    );
    notify::log(&format!("connect_pty: ensure returned ok={} pod={id}", res.is_ok()));
    res
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
        .plugin(tauri_plugin_notification::init())
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
            // Request notification authorization so DevSpace appears in System
            // Settings → Notifications and can show banners (the user may need
            // to set its style to Banners — it registered as "None").
            {
                use tauri_plugin_notification::NotificationExt;
                match app.notification().request_permission() {
                    Ok(state) => notify::log(&format!("notification permission: {state:?}")),
                    Err(e) => notify::log(&format!("notification permission request failed: {e}")),
                }
            }
            // Empty token means RNG was unavailable — leave notifications off.
            notify::log(&format!("startup: notifications_enabled={}", !notify_token.is_empty()));
            if !notify_token.is_empty() {
                let notify_handle = app.handle().clone();
                match notify::serve(notify_token.clone(), move |pod_id, message| {
                    notify::log(&format!("callback: pod={pod_id} message={message}"));
                    // Native notification, attributed to DevSpace (controllable
                    // in System Settings → Notifications, where DevSpace appears).
                    {
                        use tauri_plugin_notification::NotificationExt;
                        if let Err(e) = notify_handle
                            .notification()
                            .builder()
                            .title(format!("DevSpace: {pod_id}"))
                            .body(&message)
                            .show()
                        {
                            notify::log(&format!("notification show failed: {e}"));
                        }
                    }
                    // Guaranteed-visible fallback that needs NO notification
                    // permission (works even when the OS suppresses banners, e.g.
                    // on this MDM Mac): bounce the dock icon for attention.
                    if let Some(win) = notify_handle.get_webview_window("main") {
                        let _ = win.request_user_attention(Some(tauri::UserAttentionType::Critical));
                    }
                    let _ = notify_handle.emit("pod-badge", pod_id);
                }) {
                    Ok(()) => notify::log("listener: bound on 127.0.0.1:17865"),
                    Err(e) => notify::log(&format!("listener: bind FAILED: {e}")),
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
