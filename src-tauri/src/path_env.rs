//! Repair `PATH` for GUI launches.
//!
//! When the app is started from a terminal it inherits the user's full shell
//! `PATH`. When it's launched via macOS LaunchServices (Finder / `open`), it
//! inherits only a minimal system `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) —
//! which omits where `devpod` actually lives (e.g. `~/.local/bin`, Homebrew).
//! Every devpod subprocess then fails to spawn and the workspace list stays
//! empty.
//!
//! We fix this once at startup by asking the user's login shell for its `PATH`
//! and merging it into the current process's `PATH`. Because child processes
//! inherit the parent environment, this single fix reaches the `devpod`
//! commands, the PTY-spawned `devpod up`, and ssh's `devpod ssh --stdio`
//! ProxyCommand alike.

/// Markers wrapped around `$PATH` in the shell command so we can extract the
/// real value even if the user's rc files print noise to stdout.
const MARK_START: &str = "__DEVSPACE_PATH_START__";
const MARK_END: &str = "__DEVSPACE_PATH_END__";

/// The command run inside the login shell. `${PATH}` MUST be brace-delimited:
/// the markers contain underscores, so a bare `$PATH__DEVSPACE…` would be
/// parsed by zsh as one (unset) variable name and expand to nothing.
fn path_query_command() -> String {
    format!("echo \"{MARK_START}${{PATH}}{MARK_END}\"")
}

/// Pull the marked `PATH` out of the login shell's stdout.
fn extract_path(stdout: &str) -> Option<String> {
    let start = stdout.find(MARK_START)? + MARK_START.len();
    let rest = &stdout[start..];
    let end = rest.find(MARK_END)?;
    Some(rest[..end].to_string())
}

/// Merge `shell_path` into `current`, keeping the shell's entries first and
/// dropping empties and duplicates. Order within each source is preserved.
fn merge_path(current: &str, shell_path: &str) -> String {
    let mut seen = std::collections::HashSet::new();
    let mut entries: Vec<&str> = Vec::new();
    for part in shell_path.split(':').chain(current.split(':')) {
        if part.is_empty() {
            continue;
        }
        if seen.insert(part) {
            entries.push(part);
        }
    }
    entries.join(":")
}

/// Whether a `devpod` executable is reachable on the given colon-separated PATH.
/// `is_file` follows symlinks, so the usual `~/.local/bin/devpod -> DevPod.app`
/// link counts.
fn devpod_in(path: &str) -> bool {
    path.split(':')
        .filter(|dir| !dir.is_empty())
        .any(|dir| std::path::Path::new(dir).join("devpod").is_file())
}

/// Query the user's login shell for its `PATH` and merge it into this process's
/// `PATH`. Best-effort: on any failure the existing `PATH` is left untouched.
///
/// MUST be called before any thread is spawned: it mutates the process
/// environment via `set_var`, which is only sound while single-threaded.
pub fn repair() {
    // Fast path: if `devpod` already resolves (e.g. launched from a terminal
    // that inherited the user's full PATH), skip the shell spawn entirely.
    // Sourcing the login shell's rc files is slow and could hang on a
    // misbehaving profile, so we only pay that cost when devpod is missing —
    // i.e. the LaunchServices/minimal-PATH case this exists to fix.
    if devpod_in(&std::env::var("PATH").unwrap_or_default()) {
        return;
    }

    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    // `-i -l` so the same profile/rc files that build the user's interactive
    // PATH are sourced; `-c` runs our echo and exits. This assumes a POSIX-ish
    // shell (zsh/bash/sh) that prints `$PATH` colon-separated — fish would emit
    // it space-separated; there we simply leave PATH as-is (best-effort).
    let mut child = match std::process::Command::new(&shell)
        .args(["-ilc", &path_query_command()])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return,
    };

    let timeout = std::time::Duration::from_secs(3);
    let start = std::time::Instant::now();
    let mut exit_status = None;

    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                exit_status = Some(status);
                break;
            }
            Ok(None) => {
                if start.elapsed() >= timeout {
                    let _ = child.kill();
                    return;
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(_) => {
                let _ = child.kill();
                return;
            }
        }
    }

    if let Some(status) = exit_status {
        if !status.success() {
            return;
        }
    } else {
        return;
    }

    let mut stdout = String::new();
    if let Some(mut stream) = child.stdout.take() {
        use std::io::Read;
        let _ = stream.read_to_string(&mut stdout);
    }
    let Some(shell_path) = extract_path(&stdout) else {
        return;
    };
    if shell_path.is_empty() {
        return;
    }
    let current = std::env::var("PATH").unwrap_or_default();
    let merged = merge_path(&current, &shell_path);
    std::env::set_var("PATH", merged);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_path_between_markers() {
        let out = "some rc noise\n__DEVSPACE_PATH_START__/a/bin:/b/bin__DEVSPACE_PATH_END__\n";
        assert_eq!(extract_path(out).as_deref(), Some("/a/bin:/b/bin"));
    }

    #[test]
    fn extract_returns_none_without_markers() {
        assert_eq!(extract_path("no markers here"), None);
    }

    #[test]
    fn merge_prepends_shell_entries_and_dedups() {
        let merged = merge_path("/usr/bin:/bin", "/Users/me/.local/bin:/usr/bin");
        assert_eq!(merged, "/Users/me/.local/bin:/usr/bin:/bin");
    }

    #[test]
    fn merge_drops_empty_segments() {
        assert_eq!(merge_path(":/bin:", "/opt/bin::"), "/opt/bin:/bin");
    }

    #[test]
    fn merge_handles_empty_current() {
        assert_eq!(merge_path("", "/a:/b"), "/a:/b");
    }

    #[test]
    fn query_command_braces_the_path_variable() {
        // A bare `$PATH` followed by the underscore-leading end marker would be
        // swallowed into the variable name by zsh. Braces are mandatory.
        let cmd = path_query_command();
        assert!(cmd.contains("${PATH}"), "command must brace PATH: {cmd}");
        assert!(!cmd.contains("$PATH}"), "must not have a bare $PATH: {cmd}");
    }

    #[test]
    fn devpod_in_detects_an_executable_on_path() {
        // A real directory (this crate's manifest dir) without a `devpod` file
        // must read as absent; a temp dir we plant one in must read as present.
        let manifest = env!("CARGO_MANIFEST_DIR");
        assert!(!devpod_in(manifest));
        assert!(!devpod_in("")); // empty PATH
        assert!(!devpod_in("/no/such/dir:/also/missing"));

        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join("devpod_in_test");
        std::fs::create_dir_all(&dir).unwrap();
        let bin = dir.join("devpod");
        std::fs::write(&bin, b"#!/bin/sh\n").unwrap();
        assert!(devpod_in(dir.to_str().unwrap()));
        assert!(devpod_in(&format!("/no/such/dir:{}", dir.display())));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn query_command_round_trips_through_a_shell() {
        // Run the actual command through `sh` and confirm we get a real PATH
        // back — this exercises the marker expansion, not just the parser.
        let out = std::process::Command::new("/bin/sh")
            .args(["-c", &path_query_command()])
            .env("PATH", "/sentinel/bin:/usr/bin")
            .output()
            .expect("sh should run");
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert_eq!(
            extract_path(&stdout).as_deref(),
            Some("/sentinel/bin:/usr/bin")
        );
    }
}
