use serde_json::{json, Value};

/// The shell command Claude Code runs for each hook event. It posts the event
/// name and pod id to the reverse-forwarded notify port.
fn hook_command() -> String {
    // $DEVSPACE_POD_ID and $DEVSPACE_NOTIFY_PORT are set via `devpod ssh --set-env`.
    // CLAUDE_HOOK_EVENT_NAME is provided by Claude Code in the hook's environment.
    "curl -s -m 2 -X POST \
      -d \"{\\\"pod_id\\\":\\\"$DEVSPACE_POD_ID\\\",\\\"event\\\":\\\"$CLAUDE_HOOK_EVENT_NAME\\\"}\" \
      http://localhost:$DEVSPACE_NOTIFY_PORT/notify >/dev/null 2>&1 || true"
        .to_string()
}

fn devspace_hook_entry() -> Value {
    json!({ "hooks": [ { "type": "command", "command": hook_command() } ] })
}

/// Merge the DevSpace notification hook into an existing settings document
/// (or an empty one), idempotently for the Notification, Stop, and
/// PreToolUse events. Existing unrelated hooks are preserved.
pub fn merge_settings(existing: Option<Value>) -> Value {
    let mut root = existing.unwrap_or_else(|| json!({}));
    if !root.is_object() {
        root = json!({});
    }
    let obj = root.as_object_mut().unwrap();
    let hooks = obj
        .entry("hooks")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .expect("hooks must be an object");

    for event in ["Notification", "Stop", "PreToolUse"] {
        let arr = hooks
            .entry(event)
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .expect("event hooks must be an array");
        let cmd = hook_command();
        let already = arr.iter().any(|e| {
            e.get("hooks")
                .and_then(|h| h.as_array())
                .map(|h| h.iter().any(|x| x.get("command").and_then(|c| c.as_str()) == Some(cmd.as_str())))
                .unwrap_or(false)
        });
        if !already {
            arr.push(devspace_hook_entry());
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
}

use crate::devpod::CommandRunner;

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
