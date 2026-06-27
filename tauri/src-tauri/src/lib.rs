mod devpod;
mod hooks;
mod layout;
mod notify;
mod path_env;
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

/// Spawn `program args...` in the pod's PTY session, streaming output to the
/// `pty-output:<id>` event and emitting `pty-closed:<id>` (after removing the
/// session) when it ends. Shared by the interactive ssh terminal and the
/// streaming `devpod up` startup log.
fn spawn_pty_session(
    app: &tauri::AppHandle,
    sessions: &Arc<pty::SessionRegistry>,
    id: &str,
    program: &str,
    args: Vec<String>,
) -> Result<(), String> {
    let out_handle = app.clone();
    let out_pod = id.to_string();
    let close_handle = app.clone();
    let close_pod = id.to_string();
    let sessions_close = sessions.clone();
    sessions.ensure(
        id,
        program,
        &args,
        move |bytes| {
            let _ = out_handle.emit(&format!("pty-output:{out_pod}"), bytes);
        },
        move |session| {
            notify::log(&format!("session closed pod={close_pod}"));
            // Remove the dead session BEFORE signalling the frontend, so a
            // reconnect triggered by `pty-closed` can't race `ensure`.
            // We only emit the event if the session wasn't already explicitly closed
            // (i.e. close_only_if_matches returns Some(success), not None).
            if let Some(success) = sessions_close.close_only_if_matches(&close_pod, &session, true) {
                let _ = close_handle.emit(&format!("pty-closed:{close_pod}"), success);
            }
        },
    )
}

#[tauri::command]
fn start_workspace(app: tauri::AppHandle, state: tauri::State<AppState>, id: String) -> Result<(), String> {
    devpod::validate_id(&id)?;
    // Run `devpod up` in a PTY so it (a) doesn't block the UI and (b) streams
    // its build/start log to the same terminal view as the workspace.
    notify::log(&format!("start_workspace: devpod up pod={id}"));
    let args = vec![
        "up".into(),
        "--ide".into(),
        "none".into(),
        "--".into(),
        id.clone(),
    ];
    spawn_pty_session(&app, &state.sessions, &id, "devpod", args)
}

#[tauri::command]
fn stop_workspace(app: tauri::AppHandle, state: tauri::State<AppState>, id: String) -> Result<(), String> {
    devpod::validate_id(&id)?;
    // If the SSH terminal is still open (e.g. user clicked Stop in sidebar),
    // forcibly close it to free up the session key for the shutdown log.
    state.sessions.close(&id, false);
    
    // Run `devpod stop` in a PTY so its shutdown logs stream to the frontend
    notify::log(&format!("stop_workspace: devpod stop pod={id}"));
    let args = vec!["stop".into(), id.clone()];
    spawn_pty_session(&app, &state.sessions, &id, "devpod", args)
}

#[tauri::command]
fn delete_workspace(state: tauri::State<AppState>, id: String) -> Result<(), String> {
    devpod::validate_id(&id)?;
    let runner = state.runner.clone();
    std::thread::spawn(move || {
        let _ = devpod::delete(runner.as_ref(), &id);
    });
    Ok(())
}

#[tauri::command]
fn open_ide(state: tauri::State<AppState>, id: String, ide: String) -> Result<(), String> {
    devpod::validate_id(&id)?;
    if !ide.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err(format!("invalid ide: {ide:?}"));
    }
    let runner = state.runner.clone();
    std::thread::spawn(move || {
        let _ = runner.run(&["up", "--ide", &ide, "--", &id]);
    });
    Ok(())
}


#[tauri::command]
fn connect_pty(app: tauri::AppHandle, state: tauri::State<AppState>, id: String) -> Result<(), String> {
    devpod::validate_id(&id)?;
    // Inject the Claude hook off the open path (idempotent, best-effort): it
    // makes ssh round-trips, so doing it inline would delay the terminal. A hook
    // failure must never block opening the terminal.
    let inject_runner = state.runner.clone();
    let inject_id = id.clone();
    let inject_token = state.notify_token.clone();
    notify::log(&format!("connect_pty: pod={id} (injecting hook + opening ssh)"));
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(1000));
        match hooks::inject(inject_runner.as_ref(), &inject_id, &inject_token) {
            Ok(()) => notify::log(&format!("inject: hook written to pod={inject_id}")),
            Err(e) => notify::log(&format!("inject: FAILED pod={inject_id}: {e}")),
        }
    });
    let res = spawn_pty_session(&app, &state.sessions, &id, pty::SSH_PROGRAM, pty::ssh_args(&id));
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
    state.sessions.close(&id, false);
}

#[tauri::command]
fn load_layout() -> layout::Layout {
    layout::load()
}

#[tauri::command]
fn save_layout(
    order: Vec<String>,
    hidden: Vec<String>,
    aliases: std::collections::HashMap<String, String>,
    hidden_collapsed: bool,
) {
    layout::save(&layout::Layout {
        order,
        hidden,
        aliases,
        hidden_collapsed,
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // GUI launches (LaunchServices) inherit a minimal PATH that omits where
    // `devpod` lives, leaving the workspace list empty. Repair PATH before any
    // subprocess is spawned so devpod commands, the PTY `devpod up`, and ssh's
    // `devpod ssh --stdio` ProxyCommand can all find it.
    path_env::repair();

    let runner: Arc<dyn CommandRunner> = Arc::new(DevpodCli);
    // Persisted, stable token (survives app restarts so Claude's loaded hooks
    // keep matching). Fail closed to no notifications if it can't be obtained.
    let notify_token = notify::load_or_create_token().unwrap_or_else(|e| {
        eprintln!("notifications disabled: {e}");
        String::new()
    });

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(AppState {
            runner: runner.clone(),
            sessions: Arc::new(pty::SessionRegistry::new()),
            notify_token: notify_token.clone(),
        })
        .setup(move |app| {
            let handle = app.handle().clone();
            poller::spawn_loop(
                runner.clone(),
                std::time::Duration::from_secs(3),
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
            disconnect_pty,
            load_layout,
            save_layout,
            open_ide
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
