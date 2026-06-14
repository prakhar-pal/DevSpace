use crate::notify::LISTENER_PORT;

/// Build the argument vector for the `devpod ssh` invocation that carries both
/// the interactive shell and the reverse notification tunnel. The (untrusted)
/// pod id is validated by the caller and passed after a `--` flag terminator.
pub fn ssh_args(pod_id: &str) -> Vec<String> {
    vec![
        "ssh".into(),
        "-R".into(),
        format!("8765:localhost:{LISTENER_PORT}"),
        "--set-env".into(),
        format!("DEVSPACE_POD_ID={pod_id}"),
        "--set-env".into(),
        "DEVSPACE_NOTIFY_PORT=8765".into(),
        "--".into(),
        pod_id.into(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_ssh_args_with_reverse_tunnel() {
        let args = ssh_args("wc-1");
        assert!(args.contains(&"ssh".to_string()));
        assert!(args.contains(&"wc-1".to_string()));
        assert!(args.iter().any(|a| a.starts_with("8765:localhost:")));
        assert!(args.contains(&"DEVSPACE_POD_ID=wc-1".to_string()));
        assert!(args.contains(&"DEVSPACE_NOTIFY_PORT=8765".to_string()));
        // The pod id must come after a `--` flag terminator.
        let dd = args.iter().position(|a| a == "--").expect("has -- terminator");
        assert_eq!(args[dd + 1], "wc-1");
    }
}

use portable_pty::{CommandBuilder, NativePtySystem, PtyPair, PtySize, PtySystem};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

pub struct Session {
    pair: PtyPair,
    writer: Box<dyn Write + Send>,
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

    /// Spawn `devpod ssh ...` in a PTY. `on_output` is called with raw bytes as
    /// they arrive from the workspace. The session persists until `close`.
    pub fn ensure<F>(&self, pod_id: &str, on_output: F) -> Result<(), String>
    where
        F: Fn(Vec<u8>) + Send + 'static,
    {
        let mut map = self.sessions.lock().unwrap();
        if map.contains_key(pod_id) {
            return Ok(());
        }
        let pty = NativePtySystem::default();
        let pair = pty
            .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| e.to_string())?;

        let mut cmd = CommandBuilder::new("devpod");
        for a in ssh_args(pod_id) {
            cmd.arg(a);
        }
        let _child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;

        let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => on_output(buf[..n].to_vec()),
                }
            }
        });

        let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
        map.insert(pod_id.to_string(), Arc::new(Mutex::new(Session { pair, writer })));
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

    pub fn close(&self, pod_id: &str) {
        self.sessions.lock().unwrap().remove(pod_id);
    }
}
