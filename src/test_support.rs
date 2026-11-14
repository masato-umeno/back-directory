use rusqlite::Connection;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT_ID: AtomicU64 = AtomicU64::new(0);

fn unique_path(label: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let sequence = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "bd-core-test-{label}-{}-{nanos}-{sequence}",
        std::process::id()
    ))
}

pub struct TempDb {
    pub path: PathBuf,
}

impl TempDb {
    pub fn new() -> Self {
        let path = unique_path("db").with_extension("sqlite3");
        drop(crate::db::open(&path).expect("create temporary database"));
        Self { path }
    }

    pub fn open(&self) -> Connection {
        crate::db::open(&self.path).expect("open temporary database")
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        let _ = std::fs::remove_file(format!("{}-wal", self.path.display()));
        let _ = std::fs::remove_file(format!("{}-shm", self.path.display()));
    }
}

pub struct TempDir {
    pub path: PathBuf,
}

impl TempDir {
    pub fn new() -> Self {
        let path = unique_path("dir");
        std::fs::create_dir_all(&path).expect("create temporary directory");
        Self { path }
    }

    pub fn make(&self, name: &str) -> String {
        let path = self.path.join(name);
        std::fs::create_dir_all(&path).expect("create test directory");
        path_string(&path)
    }

    pub fn join(&self, name: &str) -> PathBuf {
        self.path.join(name)
    }

    pub fn remove(&self, name: &str) {
        std::fs::remove_dir(self.join(name)).expect("remove test directory");
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

pub fn path_string(path: &Path) -> String {
    path.to_str()
        .expect("temporary paths are valid UTF-8")
        .to_string()
}
