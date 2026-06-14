use serde::Deserialize;

/// Append a diagnostic line to the DevSpace log file
/// (`~/Library/Logs/DevSpace/devspace.log`). Used to trace the notification
/// path since GUI stderr is not easily captured. The file is created owner-only
/// (0600) in a per-user directory, and callers MUST NOT pass secrets (e.g. the
/// notify token) — log only non-sensitive fields.
pub fn log(msg: &str) {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let Some(home) = std::env::var_os("HOME") else {
        return;
    };
    let mut dir = std::path::PathBuf::from(home);
    dir.push("Library/Logs/DevSpace");
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

/// A per-run secret shared with the in-pod hook (via `--set-env`) so the local
/// listener only acts on callbacks that carry it — any other local process
/// POSTing to the port is ignored. Sourced from the OS CSPRNG; **fails closed**
/// (returns Err) if the RNG is unavailable so callers never run with a
/// predictable token.
pub fn random_token() -> Result<String, String> {
    let mut buf = [0u8; 16];
    getrandom::getrandom(&mut buf).map_err(|e| format!("OS RNG unavailable: {e}"))?;
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
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
