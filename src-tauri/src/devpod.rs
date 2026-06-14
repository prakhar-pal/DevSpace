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
}
