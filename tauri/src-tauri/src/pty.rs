use crate::notify::{LISTENER_PORT, POD_FORWARD_PORT};
use portable_pty::{CommandBuilder, NativePtySystem, PtyPair, PtySize, PtySystem};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

/// The program we spawn for a terminal session.
pub const SSH_PROGRAM: &str = "ssh";

/// Build the OpenSSH argument vector for a terminal session. We connect via the
/// `<id>.devpod` host alias DevPod writes into `~/.ssh/config` (a raw
/// `devpod ssh --stdio` proxy) rather than `devpod ssh <id>` directly: the
/// latter runs `--start-services`, which floods the session with port-forward
/// errors that conflict with the DevPod desktop app. We still carry the reverse
/// notification tunnel via `-R`. Host-key checking is disabled because devpod
/// containers are ephemeral with rotating keys and the transport is a local
/// proxy, not a network host. The (untrusted) pod id is validated by the caller
/// and can't start with `-`, so it is safe as the `<id>.devpod` hostname.
fn get_sanitized_term() -> String {
    std::env::var("TERM")
        .ok()
        .filter(|t| !t.is_empty() && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'))
        .unwrap_or_else(|| "xterm-256color".to_string())
}

pub fn ssh_args(pod_id: &str) -> Vec<String> {
    // Determine which TERM value to advertise to the remote container.
    // SSH forwards the terminal type via PTY negotiation only when the remote
    // sshd has `AcceptEnv TERM` — devpod container images often don't. Passing
    // `-o SetEnv=TERM=…` injects it unconditionally (OpenSSH 7.8+), the same
    // approach VS Code Remote SSH uses.
    let term = get_sanitized_term();
    vec![
        "-tt".into(),
        "-o".into(),
        "StrictHostKeyChecking=no".into(),
        "-o".into(),
        "UserKnownHostsFile=/dev/null".into(),
        "-o".into(),
        "LogLevel=ERROR".into(),
        "-o".into(),
        "ServerAliveInterval=5".into(),
        "-o".into(),
        "ServerAliveCountMax=3".into(),
        "-o".into(),
        format!("SetEnv=TERM={term}"),
        "-R".into(),
        format!("{POD_FORWARD_PORT}:localhost:{LISTENER_PORT}"),
        format!("{pod_id}.devpod"),
    ]
}

pub struct Session {
    pair: PtyPair,
    writer: Box<dyn Write + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

#[derive(Default)]
pub struct SessionRegistry {
    sessions: Mutex<HashMap<String, Arc<Mutex<Session>>>>,
}

impl SessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn has(&self, pod_id: &str) -> bool {
        self.sessions.lock().unwrap().contains_key(pod_id)
    }

    /// Spawn `program args...` in a PTY keyed by `pod_id`. `on_output` is called
    /// with raw bytes as they arrive; `on_close` runs once when the reader hits
    /// EOF/error. No-op if a session already exists for `pod_id`. Used for both
    /// the interactive `ssh` shell and the streaming `devpod up` startup log.
    pub fn ensure<F, G>(
        &self,
        pod_id: &str,
        program: &str,
        args: &[String],
        on_output: F,
        on_close: G,
    ) -> Result<(), String>
    where
        F: Fn(Vec<u8>) + Send + 'static,
        G: FnOnce(Arc<Mutex<Session>>) + Send + 'static,
    {
        let mut map = self.sessions.lock().unwrap();
        if map.contains_key(pod_id) {
            return Ok(());
        }
        let pty = NativePtySystem::default();
        let pair = pty
            .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| e.to_string())?;

        let mut cmd = CommandBuilder::new(program);
        for a in args {
            cmd.arg(a);
        }
        // Ensure TERM is always set for local PTY processes (e.g. `devpod up`).
        // For SSH sessions TERM is already injected via `-o SetEnv=TERM=…` in
        // ssh_args(), but setting it here too is harmless and covers any other
        // program spawned through this registry.
        cmd.env("TERM", get_sanitized_term());
        let child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;

        let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
        let session = Arc::new(Mutex::new(Session { pair, writer, child }));
        let session_clone = session.clone();

        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => on_output(buf[..n].to_vec()),
                }
            }
            // Reader hit EOF/error: the session is over. Signal the frontend.
            on_close(session_clone);
        });

        map.insert(pod_id.to_string(), session);
        Ok(())
    }

    pub fn write(&self, pod_id: &str, data: &[u8]) -> Result<(), String> {
        let map = self.sessions.lock().unwrap();
        let sess = map.get(pod_id).ok_or("no session")?.clone();
        let mut s = sess.lock().unwrap();
        s.writer.write_all(data).map_err(|e| e.to_string())?;
        s.writer.flush().map_err(|e| e.to_string())
    }

    pub fn resize(&self, pod_id: &str, rows: u16, cols: u16) -> Result<(), String> {
        let map = self.sessions.lock().unwrap();
        let sess = map.get(pod_id).ok_or("no session")?.clone();
        let s = sess.lock().unwrap();
        s.pair
            .master
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| e.to_string())
    }

    pub fn close(&self, pod_id: &str, wait: bool) -> Option<bool> {
        // Bind the removed session to a local so the map's MutexGuard is dropped
        // here — NOT held across the (potentially slow) kill/wait below. Holding
        // it would block every other session op (write/resize/ensure) and freeze
        // the UI.
        let removed = self.sessions.lock().unwrap().remove(pod_id);
        if let Some(sess) = removed {
            if let Ok(mut s) = sess.lock() {
                if let Ok(Some(st)) = s.child.try_wait() {
                    return Some(st.success());
                }
                if wait {
                    if let Ok(st) = s.child.wait() {
                        return Some(st.success());
                    }
                }
                let _ = s.child.kill();
                let _ = s.child.wait();
                return Some(false);
            }
        }
        None
    }

    pub fn close_only_if_matches(&self, pod_id: &str, session: &Arc<Mutex<Session>>, wait: bool) -> Option<bool> {
        let removed = {
            let mut map = self.sessions.lock().unwrap();
            let matches = if let Some(current) = map.get(pod_id) {
                Arc::ptr_eq(current, session)
            } else {
                false
            };
            if matches {
                map.remove(pod_id)
            } else {
                None
            }
        };
        if let Some(sess) = removed {
            if let Ok(mut s) = sess.lock() {
                if let Ok(Some(st)) = s.child.try_wait() {
                    return Some(st.success());
                }
                if wait {
                    if let Ok(st) = s.child.wait() {
                        return Some(st.success());
                    }
                }
                let _ = s.child.kill();
                let _ = s.child.wait();
                return Some(false);
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_ssh_args_for_devpod_alias() {
        let args = ssh_args("wc-1");
        // Forces a remote TTY for an interactive shell.
        assert!(args.contains(&"-tt".to_string()));
        // Injects TERM on remote side.
        assert!(args.iter().any(|a| a.starts_with("SetEnv=TERM=")));
        // Carries the reverse notification tunnel.
        assert!(args.contains(&"-R".to_string()));
        assert!(args.iter().any(|a| a == &format!("{POD_FORWARD_PORT}:localhost:{LISTENER_PORT}")));
        // Connects through the DevPod ssh host alias, not `devpod ssh`.
        assert_eq!(args.last().unwrap(), "wc-1.devpod");
    }
}
