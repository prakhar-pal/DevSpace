use serde::Deserialize;

pub const LISTENER_PORT: u16 = 17865;

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
            if let Ok(p) = serde_json::from_str::<NotifyPayload>(&body) {
                if p.token == expected_token {
                    on_notify(p.pod_id.clone(), message_for(&p.event).to_string());
                }
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
