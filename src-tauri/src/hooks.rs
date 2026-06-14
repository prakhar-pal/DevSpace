use crate::devpod::CommandRunner;
use serde_json::{json, Value};

/// The shell command Claude Code runs for a given hook event. The event label
/// is baked in literally (Claude Code does not reliably export it as an env
/// var); $DEVSPACE_POD_ID, $DEVSPACE_NOTIFY_PORT and $DEVSPACE_NOTIFY_TOKEN ARE
/// set on the ssh session. The token authenticates the callback to the desktop
/// listener.
fn hook_command(event_label: &str) -> String {
    format!(
        "curl -s -m 2 -X POST \
         -d \"{{\\\"pod_id\\\":\\\"$DEVSPACE_POD_ID\\\",\\\"event\\\":\\\"{event_label}\\\",\\\"token\\\":\\\"$DEVSPACE_NOTIFY_TOKEN\\\"}}\" \
         http://localhost:$DEVSPACE_NOTIFY_PORT/notify >/dev/null 2>&1 || true"
    )
}

// (settings-key, optional matcher, literal event label sent to the desktop)
const HOOK_EVENTS: &[(&str, Option<&str>, &str)] = &[
    ("Notification", None, "Notification"),
    ("Stop", None, "Stop"),
    ("PreToolUse", Some("AskUserQuestion"), "AskUserQuestion"),
];

fn devspace_hook_entry(matcher: Option<&str>, event_label: &str) -> Value {
    let mut entry = json!({ "hooks": [ { "type": "command", "command": hook_command(event_label) } ] });
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
pub fn merge_settings(existing: Option<Value>) -> Value {
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
        let cmd = hook_command(label);
        let already = arr.iter().any(|e| {
            e.get("hooks")
                .and_then(|h| h.as_array())
                .map(|h| h.iter().any(|x| x.get("command").and_then(|c| c.as_str()) == Some(cmd.as_str())))
                .unwrap_or(false)
        });
        if !already {
            arr.push(devspace_hook_entry(*matcher, label));
        }
    }
    root
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_hooks_to_empty_settings() {
        let merged = merge_settings(None);
        let notif = &merged["hooks"]["Notification"];
        assert_eq!(notif.as_array().unwrap().len(), 1);
        assert!(merged["hooks"]["Stop"].as_array().unwrap().len() == 1);
        assert!(merged["hooks"]["PreToolUse"].as_array().unwrap().len() == 1);
    }

    #[test]
    fn is_idempotent() {
        let once = merge_settings(None);
        let twice = merge_settings(Some(once.clone()));
        assert_eq!(once, twice);
    }

    #[test]
    fn preserves_existing_unrelated_hooks() {
        let existing = json!({
            "hooks": { "Notification": [ { "hooks": [ { "type": "command", "command": "echo other" } ] } ] }
        });
        let merged = merge_settings(Some(existing));
        let arr = merged["hooks"]["Notification"].as_array().unwrap();
        assert_eq!(arr.len(), 2);
    }

    #[test]
    fn base64_matches_known_vector() {
        assert_eq!(base64_encode(b"hi"), "aGk=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
    }

    #[test]
    fn pretooluse_has_matcher_and_literal_event() {
        let merged = merge_settings(None);
        let arr = merged["hooks"]["PreToolUse"].as_array().unwrap();
        assert_eq!(arr.len(), 1);
        let entry = &arr[0];
        assert_eq!(entry["matcher"], "AskUserQuestion");
        let cmd = entry["hooks"][0]["command"].as_str().unwrap();
        assert!(cmd.contains("AskUserQuestion"));
        assert!(!cmd.contains("$CLAUDE_HOOK_EVENT_NAME"));
    }

    #[test]
    fn tolerates_malformed_settings() {
        // `hooks` is not an object.
        let merged = merge_settings(Some(json!({ "hooks": "garbage" })));
        assert!(merged["hooks"].is_object());
        assert_eq!(merged["hooks"]["Stop"].as_array().unwrap().len(), 1);
        assert_eq!(merged["hooks"]["Notification"].as_array().unwrap().len(), 1);
        assert_eq!(merged["hooks"]["PreToolUse"].as_array().unwrap().len(), 1);

        // An event key is not an array.
        let merged = merge_settings(Some(json!({ "hooks": { "Stop": 5 } })));
        assert!(merged["hooks"].is_object());
        assert_eq!(merged["hooks"]["Stop"].as_array().unwrap().len(), 1);
        assert_eq!(merged["hooks"]["Notification"].as_array().unwrap().len(), 1);
        assert_eq!(merged["hooks"]["PreToolUse"].as_array().unwrap().len(), 1);
    }
}

/// Read the pod's ~/.claude/settings.json, merge in the DevSpace hooks, and
/// write it back via `devpod ssh --command`. Idempotent.
pub fn inject(runner: &dyn CommandRunner, pod_id: &str) -> Result<(), String> {
    crate::devpod::validate_id(pod_id)?;
    let read = runner.run(&[
        "ssh", "--command",
        "cat ~/.claude/settings.json 2>/dev/null || echo '{}'",
        "--", pod_id,
    ])?;
    let existing: Option<Value> = serde_json::from_str(read.trim()).ok();
    let merged = merge_settings(existing);
    let serialized = serde_json::to_string(&merged).map_err(|e| e.to_string())?;
    // base64 to safely transport JSON through the shell.
    let b64 = base64_encode(serialized.as_bytes());
    let cmd = format!(
        "mkdir -p ~/.claude && echo {b64} | base64 -d > ~/.claude/settings.json"
    );
    runner.run(&["ssh", "--command", &cmd, "--", pod_id]).map(|_| ())
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
