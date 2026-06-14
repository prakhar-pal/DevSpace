use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct Provider {
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct Source {
    #[serde(rename = "gitRepository", default)]
    pub git_repository: Option<String>,
    #[serde(rename = "localFolder", default)]
    pub local_folder: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Workspace {
    pub id: String,
    #[serde(default)]
    pub provider: Provider,
    #[serde(default)]
    pub source: Source,
    #[serde(rename = "lastUsed", default)]
    pub last_used: String,
    #[serde(default)]
    pub context: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct WorkspaceStatus {
    pub id: String,
    pub state: String,
}

pub fn parse_list(json: &str) -> Result<Vec<Workspace>, String> {
    serde_json::from_str(json).map_err(|e| e.to_string())
}

pub fn parse_status(json: &str) -> Result<WorkspaceStatus, String> {
    serde_json::from_str(json).map_err(|e| e.to_string())
}

pub trait CommandRunner: Send + Sync {
    fn run(&self, args: &[&str]) -> Result<String, String>;
}

pub struct DevpodCli;

impl CommandRunner for DevpodCli {
    fn run(&self, args: &[&str]) -> Result<String, String> {
        let out = std::process::Command::new("devpod")
            .args(args)
            .output()
            .map_err(|e| format!("failed to spawn devpod: {e}"))?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}

pub fn list(runner: &dyn CommandRunner) -> Result<Vec<Workspace>, String> {
    let out = runner.run(&["list", "--output", "json"])?;
    parse_list(&out)
}

pub fn status(runner: &dyn CommandRunner, id: &str) -> Result<WorkspaceStatus, String> {
    let out = runner.run(&["status", id, "--output", "json", "--timeout", "10s"])?;
    parse_status(&out)
}

pub fn up(runner: &dyn CommandRunner, id: &str) -> Result<(), String> {
    runner.run(&["up", id, "--ide", "none"]).map(|_| ())
}

pub fn stop(runner: &dyn CommandRunner, id: &str) -> Result<(), String> {
    runner.run(&["stop", id]).map(|_| ())
}

pub fn delete(runner: &dyn CommandRunner, id: &str) -> Result<(), String> {
    runner.run(&["delete", id]).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_list_fixture() {
        let json = include_str!("../tests/fixtures/list.json");
        let ws = parse_list(json).unwrap();
        assert_eq!(ws.len(), 2);
        assert_eq!(ws[0].id, "task-queue");
        assert_eq!(ws[1].provider.name, "kubernetes");
        assert_eq!(
            ws[1].source.git_repository.as_deref(),
            Some("git@github.com:talview/webclients.git")
        );
    }

    #[test]
    fn parses_status_fixture() {
        let json = include_str!("../tests/fixtures/status.json");
        let s = parse_status(json).unwrap();
        assert_eq!(s.id, "wc-1");
        assert_eq!(s.state, "Stopped");
    }

    struct FakeRunner {
        output: String,
        expected_args: Vec<String>,
    }

    impl CommandRunner for FakeRunner {
        fn run(&self, args: &[&str]) -> Result<String, String> {
            assert_eq!(args, self.expected_args.as_slice());
            Ok(self.output.clone())
        }
    }

    #[test]
    fn list_calls_cli_and_parses() {
        let runner = FakeRunner {
            output: include_str!("../tests/fixtures/list.json").to_string(),
            expected_args: vec!["list".into(), "--output".into(), "json".into()],
        };
        let ws = list(&runner).unwrap();
        assert_eq!(ws.len(), 2);
    }

    #[test]
    fn stop_passes_id() {
        let runner = FakeRunner {
            output: String::new(),
            expected_args: vec!["stop".into(), "wc-1".into()],
        };
        assert!(stop(&runner, "wc-1").is_ok());
    }
}
