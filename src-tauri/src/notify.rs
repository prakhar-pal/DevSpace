use serde::Deserialize;

/// Locate the project root so the dev-only diagnostic log lands in `.tmp/`.
/// `DEVSPACE_PROJECT_DIR` overrides; otherwise we use the cwd (`tauri dev` runs
/// cargo from `src-tauri/`, so also accept that and step up to its parent).
/// Only compiled in debug builds — release logging is disabled entirely.
#[cfg(debug_assertions)]
fn find_project_dir() -> std::path::PathBuf {
    if let Some(val) = std::env::var_os("DEVSPACE_PROJECT_DIR") {
        return std::path::PathBuf::from(val);
    }
    if let Ok(cwd) = std::env::current_dir() {
        if cwd.join("src-tauri").exists() || cwd.join("package.json").exists() {
            return cwd;
        }
        if cwd.join("Cargo.toml").exists()
            && cwd.file_name().map(|n| n == "src-tauri").unwrap_or(false)
        {
            if let Some(parent) = cwd.parent() {
                return parent.to_path_buf();
            }
        }
        return cwd;
    }
    std::path::PathBuf::from(".")
}

/// Append a diagnostic line to `.tmp/devspace.log` at the project root, to trace
/// the notification path since GUI stderr is not easily captured. The `.tmp`
/// dir is `.gitignore`d. The file is created owner-only (0600), and callers MUST
/// NOT pass secrets (e.g. the notify token) — log only non-sensitive fields.
///
/// Disabled in release builds: this is a development-only diagnostic, so the
/// production bundle writes nothing. (See the `not(debug_assertions)` no-op.)
#[cfg(debug_assertions)]
pub fn log(msg: &str) {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let dir = find_project_dir().join(".tmp");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(dir.join("devspace.log"))
    {
        let _ = writeln!(f, "[{ts}] {msg}");
    }
}

/// Release builds: logging is a no-op (development-only diagnostic).
#[cfg(not(debug_assertions))]
pub fn log(_msg: &str) {}

/// Desktop-side port the notify HTTP listener binds.
pub const LISTENER_PORT: u16 = 17865;
/// Pod-side port the reverse SSH tunnel forwards to `LISTENER_PORT`; the in-pod
/// hook posts here. Kept in one place so the tunnel and the hook agree.
pub const POD_FORWARD_PORT: u16 = 8765;

#[derive(Debug, Clone, Deserialize)]
pub struct NotifyPayload {
    pub pod_id: String,
    pub event: String,
    #[serde(default)]
    pub token: String,
}

/// Map a Claude Code hook event name to a user-facing message.
pub fn message_for(event: &str) -> &'static str {
    match event {
        "Stop" => "Claude finished",
        _ => "Claude needs your input",
    }
}

/// A secret shared with the in-pod hook so the local listener only acts on
/// callbacks that carry it. Sourced from the OS CSPRNG; **fails closed**
/// (returns Err) if the RNG is unavailable so callers never run with a
/// predictable token.
pub fn random_token() -> Result<String, String> {
    let mut buf = [0u8; 16];
    getrandom::getrandom(&mut buf).map_err(|e| format!("OS RNG unavailable: {e}"))?;
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
}

/// Load the persisted notify token, or create+persist one. Persisting it (vs a
/// per-run random) keeps it STABLE across app restarts, so hooks Claude Code
/// loaded at startup keep matching even after DevSpace is relaunched. Stored
/// owner-only (0600) under ~/Library/Application Support/DevSpace.
pub fn load_or_create_token() -> Result<String, String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let home = std::env::var_os("HOME").ok_or("no HOME")?;
    let mut dir = std::path::PathBuf::from(home);
    dir.push("Library/Application Support/DevSpace");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join("notify-token");
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let t = existing.trim();
        if t.len() == 32 && t.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Ok(t.to_string());
        }
    }
    let token = random_token()?;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)
        .map_err(|e| e.to_string())?;
    f.write_all(token.as_bytes()).map_err(|e| e.to_string())?;
    Ok(token)
}

/// Start a blocking HTTP listener on `LISTENER_PORT`. For each `POST /notify`
/// with a JSON `NotifyPayload` whose `token` matches `expected_token`, invoke
/// `on_notify(pod_id, message)`. Returns Err if the port cannot be bound
/// (caller logs and disables notifications).
pub fn serve<F>(expected_token: String, on_notify: F) -> Result<(), String>
where
    F: Fn(String, String) + Send + 'static,
{
    let server = tiny_http::Server::http(("127.0.0.1", LISTENER_PORT))
        .map_err(|e| format!("notify listener bind failed: {e}"))?;
    std::thread::spawn(move || {
        for mut req in server.incoming_requests() {
            let mut body = String::new();
            let _ = req.as_reader().read_to_string(&mut body);
            // Never log the raw body — it carries the auth token. Log only
            // non-sensitive fields after parsing.
            match serde_json::from_str::<NotifyPayload>(&body) {
                Ok(p) => {
                    let matched = p.token == expected_token;
                    log(&format!(
                        "listener: received pod={} event={} token_match={}",
                        p.pod_id, p.event, matched
                    ));
                    if matched {
                        on_notify(p.pod_id.clone(), message_for(&p.event).to_string());
                    } else {
                        log("listener: token mismatch — ignoring (stale hook?)");
                    }
                }
                Err(_) => log("listener: received unparseable body (ignored)"),
            }
            let _ = req.respond(tiny_http::Response::empty(204));
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_events() {
        assert_eq!(message_for("Stop"), "Claude finished");
        assert_eq!(message_for("Notification"), "Claude needs your input");
        assert_eq!(message_for("AskUserQuestion"), "Claude needs your input");
    }

    #[test]
    fn parses_payload() {
        let p: NotifyPayload =
            serde_json::from_str(r#"{"pod_id":"wc-1","event":"Stop","token":"abc"}"#).unwrap();
        assert_eq!(p.pod_id, "wc-1");
        assert_eq!(p.event, "Stop");
        assert_eq!(p.token, "abc");
    }

    #[test]
    fn token_defaults_when_absent() {
        let p: NotifyPayload =
            serde_json::from_str(r#"{"pod_id":"wc-1","event":"Stop"}"#).unwrap();
        assert_eq!(p.token, "");
    }
}
