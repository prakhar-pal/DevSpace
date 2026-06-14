use crate::devpod::CommandRunner;
use serde_json::{json, Value};

/// The shell command Claude Code runs for a given hook event. Pod id, event
/// label, port and auth token are all baked in literally at injection time —
/// we connect with plain `ssh` (no DevPod `--set-env`), so nothing can be read
/// from the environment. pod_id is validated (no quotes) and token is hex, so
/// the single-quoted JSON payload is injection-safe.
fn hook_command(event_label: &str, pod_id: &str, token: &str) -> String {
    let port = crate::notify::POD_FORWARD_PORT;
    format!(
        "curl -s -m 2 -X POST \
         -d '{{\"pod_id\":\"{pod_id}\",\"event\":\"{event_label}\",\"token\":\"{token}\"}}' \
         http://localhost:{port}/notify >/dev/null 2>&1 || true"
    )
}

// (settings-key, optional matcher, literal event label sent to the desktop)
const HOOK_EVENTS: &[(&str, Option<&str>, &str)] = &[
    ("Notification", None, "Notification"),
    ("Stop", None, "Stop"),
    ("PreToolUse", Some("AskUserQuestion"), "AskUserQuestion"),
];

/// True if a hook entry is one DevSpace injected — identified by a command that
/// POSTs a `pod_id` to our `/notify` endpoint. Matches both the current baked
/// form and the older `$DEVSPACE_*` env-var form, so re-injecting cleans up
/// stale entries (e.g. from a previous run's token) instead of accumulating.
fn is_devspace_entry(entry: &Value) -> bool {
    entry
        .get("hooks")
        .and_then(|h| h.as_array())
        .map(|hooks| {
            hooks.iter().any(|x| {
                x.get("command")
                    .and_then(|c| c.as_str())
                    .map(|c| c.contains("/notify") && c.contains("pod_id"))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn devspace_hook_entry(matcher: Option<&str>, event_label: &str, pod_id: &str, token: &str) -> Value {
    let mut entry = json!({
        "hooks": [ { "type": "command", "command": hook_command(event_label, pod_id, token) } ]
    });
    if let Some(m) = matcher {
        entry["matcher"] = json!(m);
    }
    entry
}

/// Merge the DevSpace notification hook into an existing settings document
/// (or an empty one), idempotently for the Notification, Stop, and
/// PreToolUse events. Existing unrelated hooks are preserved. Malformed
/// existing values (wrong-typed `hooks` or event entries) are overwritten
/// with the correct container rather than panicking.
pub fn merge_settings(existing: Option<Value>, pod_id: &str, token: &str) -> Value {
    let mut root = existing.unwrap_or_else(|| json!({}));
    if !root.is_object() {
        root = json!({});
    }
    let obj = root.as_object_mut().unwrap();
    // Treat a wrong-typed `hooks` value as missing.
    let hooks_val = obj.entry("hooks").or_insert_with(|| json!({}));
    if !hooks_val.is_object() {
        *hooks_val = json!({});
    }
    let hooks = hooks_val.as_object_mut().unwrap();

    for (key, matcher, label) in HOOK_EVENTS {
        // Treat a wrong-typed event value as missing.
        let event_val = hooks.entry(*key).or_insert_with(|| json!([]));
        if !event_val.is_array() {
            *event_val = json!([]);
        }
        let arr = event_val.as_array_mut().unwrap();
        // Replace any prior DevSpace hook (old token / legacy form) rather than
        // appending, so settings.json never accumulates stale entries.
        arr.retain(|e| !is_devspace_entry(e));
        arr.push(devspace_hook_entry(*matcher, label, pod_id, token));
    }
    root
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_hooks_to_empty_settings() {
        let merged = merge_settings(None, "wc-1", "tok");
        let notif = &merged["hooks"]["Notification"];
        assert_eq!(notif.as_array().unwrap().len(), 1);
        assert!(merged["hooks"]["Stop"].as_array().unwrap().len() == 1);
        assert!(merged["hooks"]["PreToolUse"].as_array().unwrap().len() == 1);
    }

    #[test]
    fn is_idempotent() {
        let once = merge_settings(None, "wc-1", "tok");
        let twice = merge_settings(Some(once.clone()), "wc-1", "tok");
        assert_eq!(once, twice);
    }

    #[test]
    fn preserves_existing_unrelated_hooks() {
        let existing = json!({
            "hooks": { "Notification": [ { "hooks": [ { "type": "command", "command": "echo other" } ] } ] }
        });
        let merged = merge_settings(Some(existing), "wc-1", "tok");
        let arr = merged["hooks"]["Notification"].as_array().unwrap();
        assert_eq!(arr.len(), 2);
    }

    #[test]
    fn reinjecting_replaces_old_token_not_accumulates() {
        let once = merge_settings(None, "wc-1", "tok1");
        let twice = merge_settings(Some(once), "wc-1", "tok2");
        let arr = twice["hooks"]["Notification"].as_array().unwrap();
        assert_eq!(arr.len(), 1);
        let cmd = arr[0]["hooks"][0]["command"].as_str().unwrap();
        assert!(cmd.contains("tok2"));
        assert!(!cmd.contains("tok1"));
    }

    #[test]
    fn base64_matches_known_vector() {
        assert_eq!(base64_encode(b"hi"), "aGk=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
    }

    #[test]
    fn helper_script_bakes_pod_and_token() {
        let s = notify_helper_script("wc-1", "deadbeef");
        assert!(s.starts_with("#!/usr/bin/env bash"));
        assert!(s.contains("wc-1"));
        assert!(s.contains("deadbeef"));
        assert!(s.contains("/notify"));
        assert!(s.contains("${1:-Stop}"));
    }

    #[test]
    fn bakes_literal_pod_id_token_event_no_env() {
        let merged = merge_settings(None, "wc-7", "deadbeef");
        let arr = merged["hooks"]["PreToolUse"].as_array().unwrap();
        assert_eq!(arr.len(), 1);
        let entry = &arr[0];
        assert_eq!(entry["matcher"], "AskUserQuestion");
        let cmd = entry["hooks"][0]["command"].as_str().unwrap();
        assert!(cmd.contains("AskUserQuestion"));
        assert!(cmd.contains("wc-7"));
        assert!(cmd.contains("deadbeef"));
        // No reliance on the in-pod environment.
        assert!(!cmd.contains("$CLAUDE_HOOK_EVENT_NAME"));
        assert!(!cmd.contains("$DEVSPACE_POD_ID"));
        assert!(!cmd.contains("$DEVSPACE_NOTIFY_TOKEN"));
    }

    #[test]
    fn tolerates_malformed_settings() {
        // `hooks` is not an object.
        let merged = merge_settings(Some(json!({ "hooks": "garbage" })), "wc-1", "tok");
        assert!(merged["hooks"].is_object());
        assert_eq!(merged["hooks"]["Stop"].as_array().unwrap().len(), 1);
        assert_eq!(merged["hooks"]["Notification"].as_array().unwrap().len(), 1);
        assert_eq!(merged["hooks"]["PreToolUse"].as_array().unwrap().len(), 1);

        // An event key is not an array.
        let merged = merge_settings(Some(json!({ "hooks": { "Stop": 5 } })), "wc-1", "tok");
        assert!(merged["hooks"].is_object());
        assert_eq!(merged["hooks"]["Stop"].as_array().unwrap().len(), 1);
        assert_eq!(merged["hooks"]["Notification"].as_array().unwrap().len(), 1);
        assert_eq!(merged["hooks"]["PreToolUse"].as_array().unwrap().len(), 1);
    }
}

/// Read the pod's ~/.claude/settings.json, merge in the DevSpace hooks, and
/// write it back via `devpod ssh --command`. Idempotent.
pub fn inject(runner: &dyn CommandRunner, pod_id: &str, token: &str) -> Result<(), String> {
    crate::devpod::validate_id(pod_id)?;
    let read = runner.run(&[
        "ssh", "--command",
        "cat ~/.claude/settings.json 2>/dev/null || echo '{}'",
        "--", pod_id,
    ])?;
    let existing: Option<Value> = serde_json::from_str(read.trim()).ok();
    let merged = merge_settings(existing, pod_id, token);
    let serialized = serde_json::to_string(&merged).map_err(|e| e.to_string())?;
    // base64 to safely transport JSON through the shell.
    let b64 = base64_encode(serialized.as_bytes());
    let cmd = format!(
        "mkdir -p ~/.claude && echo {b64} | base64 -d > ~/.claude/settings.json"
    );
    runner.run(&["ssh", "--command", &cmd, "--", pod_id])?;

    // Also drop a manual-trigger helper so the user can fire a real notification
    // by hand from the DevSpace terminal (best-effort).
    let script_b64 = base64_encode(notify_helper_script(pod_id, token).as_bytes());
    let cmd2 = format!(
        "echo {script_b64} | base64 -d > ~/.devspace-notify && chmod +x ~/.devspace-notify"
    );
    let _ = runner.run(&["ssh", "--command", &cmd2, "--", pod_id]);
    Ok(())
}

/// A small executable helper written to `~/.devspace-notify` in the pod. Run it
/// from the DevSpace terminal (it relies on this session's reverse tunnel) to
/// fire a notification by hand: `~/.devspace-notify` (defaults to Stop) or
/// `~/.devspace-notify Notification`.
fn notify_helper_script(pod_id: &str, token: &str) -> String {
    let port = crate::notify::POD_FORWARD_PORT;
    format!(
        "#!/usr/bin/env bash\n\
         # DevSpace manual notification trigger. Must run inside the DevSpace\n\
         # terminal — it uses the reverse SSH tunnel this session set up.\n\
         event=\"${{1:-Stop}}\"\n\
         curl -s -m 2 -X POST -d \"{{\\\"pod_id\\\":\\\"{pod_id}\\\",\\\"event\\\":\\\"$event\\\",\\\"token\\\":\\\"{token}\\\"}}\" http://localhost:{port}/notify \
         && echo \"devspace-notify: sent event=$event\" || echo \"devspace-notify: failed (is this the DevSpace terminal?)\"\n"
    )
}

fn base64_encode(input: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in input.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        out.push(T[(b[0] >> 2) as usize] as char);
        out.push(T[(((b[0] & 0x03) << 4) | (b[1] >> 4)) as usize] as char);
        out.push(if chunk.len() > 1 { T[(((b[1] & 0x0f) << 2) | (b[2] >> 6)) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[(b[2] & 0x3f) as usize] as char } else { '=' });
    }
    out
}
