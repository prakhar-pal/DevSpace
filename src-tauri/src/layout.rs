use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

/// Persisted sidebar UI preferences: workspace order, hidden set, and
/// user-chosen friendly names (aliases) keyed by workspace id.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Layout {
    #[serde(default)]
    pub order: Vec<String>,
    #[serde(default)]
    pub hidden: Vec<String>,
    #[serde(default)]
    pub aliases: HashMap<String, String>,
    /// Whether the sidebar's "Hidden" section is collapsed.
    #[serde(default)]
    pub hidden_collapsed: bool,
}

/// Tolerant parse: invalid/garbage JSON yields the default (empty) layout.
pub fn parse(json: &str) -> Layout {
    serde_json::from_str(json).unwrap_or_default()
}

pub fn serialize(layout: &Layout) -> String {
    serde_json::to_string_pretty(layout).unwrap_or_else(|_| "{}".to_string())
}

/// `~/Library/Application Support/DevSpace` (same dir as the notify token).
fn dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    let mut p = PathBuf::from(home);
    p.push("Library/Application Support/DevSpace");
    Some(p)
}

pub fn load() -> Layout {
    match dir() {
        Some(d) => std::fs::read_to_string(d.join("layout.json"))
            .map(|s| parse(&s))
            .unwrap_or_default(),
        None => Layout::default(),
    }
}

/// Best-effort write — a lost preference is non-fatal.
pub fn save(layout: &Layout) {
    if let Some(d) = dir() {
        if std::fs::create_dir_all(&d).is_ok() {
            let _ = std::fs::write(d.join("layout.json"), serialize(layout));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        let mut l = Layout::default();
        l.order = vec!["a".into(), "b".into()];
        l.hidden = vec!["c".into()];
        l.aliases.insert("a".into(), "Alpha".into());
        l.hidden_collapsed = true;
        let parsed = parse(&serialize(&l));
        assert_eq!(parsed.order, l.order);
        assert_eq!(parsed.hidden, l.hidden);
        assert_eq!(parsed.aliases.get("a").map(String::as_str), Some("Alpha"));
        assert!(parsed.hidden_collapsed);
    }

    #[test]
    fn malformed_is_default() {
        let l = parse("not json{{");
        assert!(l.order.is_empty() && l.hidden.is_empty() && l.aliases.is_empty());
    }

    #[test]
    fn missing_fields_default_to_empty() {
        let l = parse("{}");
        assert!(l.order.is_empty() && l.hidden.is_empty() && l.aliases.is_empty());
        let l2 = parse(r#"{"order":["x"]}"#);
        assert_eq!(l2.order, vec!["x".to_string()]);
        assert!(l2.hidden.is_empty() && l2.aliases.is_empty());
    }
}
