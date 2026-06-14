use crate::devpod::{self, CommandRunner, Workspace, WorkspaceStatus};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Debug, Clone, Serialize)]
pub struct WorkspaceView {
    pub id: String,
    pub provider: String,
    pub source: String,
    pub last_used: String,
    pub state: String,
    pub error: Option<String>,
}

/// Merge the workspace list with a map of id -> status (or error string).
pub fn merge(
    workspaces: &[Workspace],
    statuses: &HashMap<String, Result<WorkspaceStatus, String>>,
) -> Vec<WorkspaceView> {
    workspaces
        .iter()
        .map(|w| {
            let source = w
                .source
                .git_repository
                .clone()
                .or_else(|| w.source.local_folder.clone())
                .unwrap_or_default();
            let (state, error) = match statuses.get(&w.id) {
                Some(Ok(s)) => (s.state.clone(), None),
                Some(Err(e)) => ("Unknown".to_string(), Some(e.clone())),
                None => ("Unknown".to_string(), None),
            };
            WorkspaceView {
                id: w.id.clone(),
                provider: w.provider.name.clone(),
                source,
                last_used: w.last_used.clone(),
                state,
                error,
            }
        })
        .collect()
}

/// How many `devpod status` calls run concurrently per poll cycle. Bounds load
/// while keeping a slow/unreachable workspace from stalling the whole cycle
/// (each call still carries the CLI's own short timeout).
const MAX_CONCURRENT_STATUS: usize = 4;

/// Run one poll cycle: list workspaces, fetch each status (up to
/// `MAX_CONCURRENT_STATUS` in flight), return merged views.
pub fn poll_once(runner: &dyn CommandRunner) -> Result<Vec<WorkspaceView>, String> {
    let workspaces = devpod::list(runner)?;
    let mut statuses = HashMap::new();
    // `dyn CommandRunner: Send + Sync` (supertrait bounds), so `&dyn` is Send and
    // can be shared with scoped threads that are guaranteed to join before return.
    for chunk in workspaces.chunks(MAX_CONCURRENT_STATUS) {
        std::thread::scope(|scope| {
            let handles: Vec<_> = chunk
                .iter()
                .map(|w| {
                    let id = w.id.clone();
                    scope.spawn(move || (id.clone(), devpod::status(runner, &id)))
                })
                .collect();
            for handle in handles {
                let (id, status) = handle.join().expect("status thread panicked");
                statuses.insert(id, status);
            }
        });
    }
    Ok(merge(&workspaces, &statuses))
}

/// Spawn the background poll loop; emits `workspaces-updated` every `interval`.
pub fn spawn_loop<F>(runner: Arc<dyn CommandRunner>, interval: std::time::Duration, emit: F)
where
    F: Fn(Vec<WorkspaceView>) + Send + 'static,
{
    std::thread::spawn(move || loop {
        match poll_once(runner.as_ref()) {
            Ok(views) => emit(views),
            Err(_e) => { /* keep looping; transient CLI errors are expected */ }
        }
        std::thread::sleep(interval);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::devpod::parse_list;

    #[test]
    fn merge_applies_status_and_error() {
        let ws = parse_list(include_str!("../tests/fixtures/list.json")).unwrap();
        let mut statuses = HashMap::new();
        statuses.insert(
            "wc-1".to_string(),
            Ok(WorkspaceStatus { id: "wc-1".into(), state: "Running".into() }),
        );
        statuses.insert("task-queue".to_string(), Err("timeout".to_string()));

        let views = merge(&ws, &statuses);
        let wc1 = views.iter().find(|v| v.id == "wc-1").unwrap();
        assert_eq!(wc1.state, "Running");
        assert_eq!(wc1.source, "git@github.com:talview/webclients.git");

        let tq = views.iter().find(|v| v.id == "task-queue").unwrap();
        assert_eq!(tq.state, "Unknown");
        assert_eq!(tq.error.as_deref(), Some("timeout"));
    }
}
