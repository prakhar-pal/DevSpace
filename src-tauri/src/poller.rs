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
                // A genuine status error surfaces as Unknown (+ tooltip).
                Some(Err(e)) => ("Unknown".to_string(), Some(e.clone())),
                // Status not fetched yet this cycle: Pending, not an error.
                None => ("Pending".to_string(), None),
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

/// Fetch each workspace's status, up to `MAX_CONCURRENT_STATUS` in flight.
pub fn fetch_statuses(
    runner: &dyn CommandRunner,
    workspaces: &[Workspace],
) -> HashMap<String, Result<WorkspaceStatus, String>> {
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
    statuses
}

/// Run one full poll cycle: list workspaces, fetch every status, return merged
/// views. Used by the on-demand `list_workspaces` command.
pub fn poll_once(runner: &dyn CommandRunner) -> Result<Vec<WorkspaceView>, String> {
    let workspaces = devpod::list(runner)?;
    let statuses = fetch_statuses(runner, &workspaces);
    Ok(merge(&workspaces, &statuses))
}

/// Spawn the background poll loop. Each cycle emits TWICE: first the workspace
/// list immediately after the fast `devpod list` (names visible in ~1s, with
/// not-yet-known statuses shown as Pending), then again once the slower
/// per-workspace `devpod status` sweep resolves. A status cache is carried
/// across cycles so re-polls keep showing last-known states instead of
/// flickering back to Pending.
pub fn spawn_loop<F>(runner: Arc<dyn CommandRunner>, interval: std::time::Duration, emit: F)
where
    F: Fn(Vec<WorkspaceView>) + Send + 'static,
{
    std::thread::spawn(move || {
        let mut cache: HashMap<String, Result<WorkspaceStatus, String>> = HashMap::new();
        loop {
            if let Ok(workspaces) = devpod::list(runner.as_ref()) {
                // 1. Emit names immediately with whatever statuses we already
                //    know (Pending for any not yet in the cache).
                emit(merge(&workspaces, &cache));
                // 2. Resolve fresh statuses, then emit the updated snapshot.
                cache = fetch_statuses(runner.as_ref(), &workspaces);
                emit(merge(&workspaces, &cache));
            }
            std::thread::sleep(interval);
        }
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
