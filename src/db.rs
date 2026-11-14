use crate::error::{Error, Result};
use rusqlite::Connection;
use std::env;
use std::path::{Path, PathBuf};

pub fn default_path() -> Result<PathBuf> {
    Ok(state_dir()?.join("bd.sqlite3"))
}

pub fn open_default() -> Result<Connection> {
    open(&default_path()?)
}

/// Opens a database at an explicit path, creating the parent directory and schema.
pub fn open(path: &Path) -> Result<Connection> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let conn = Connection::open(path)?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA temp_store = MEMORY;
         CREATE TABLE IF NOT EXISTS events (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           session_key TEXT NOT NULL DEFAULT '',
           path TEXT NOT NULL,
           ts INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_events_session_id ON events(session_key, id);
         CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
         CREATE TABLE IF NOT EXISTS sessions (
           session_key TEXT PRIMARY KEY,
           cursor_id INTEGER NOT NULL,
           last_bd_delta INTEGER NOT NULL DEFAULT 0,
           last_bd_from_id INTEGER NOT NULL DEFAULT 0,
           last_bd_to_id INTEGER NOT NULL DEFAULT 0,
           last_bd_armed INTEGER NOT NULL DEFAULT 0,
           last_seen_at INTEGER NOT NULL DEFAULT 0
         );
         CREATE TABLE IF NOT EXISTS undo_moves (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           session_key TEXT NOT NULL,
           from_id INTEGER NOT NULL,
           to_id INTEGER NOT NULL,
           created_at INTEGER NOT NULL DEFAULT 0
         );
         CREATE INDEX IF NOT EXISTS idx_undo_moves_session_id ON undo_moves(session_key, id);
         CREATE TABLE IF NOT EXISTS meta (
           key TEXT PRIMARY KEY,
           value INTEGER NOT NULL
         );
         ",
    )?;

    ensure_schema(&conn)?;
    Ok(conn)
}

pub fn remove_file_if_exists(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

pub fn file_size(path: &Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|metadata| metadata.len())
}

fn state_dir() -> Result<PathBuf> {
    if let Ok(state_home) = env::var("XDG_STATE_HOME") {
        return Ok(PathBuf::from(state_home).join("back-directory"));
    }

    if cfg!(windows) {
        if let Some(local_app_data) = env::var_os("LOCALAPPDATA").filter(|value| !value.is_empty())
        {
            return Ok(PathBuf::from(local_app_data).join("back-directory"));
        }
        let profile = env::var_os("USERPROFILE")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| Error::msg("bd: LOCALAPPDATA not set"))?;
        return Ok(PathBuf::from(profile)
            .join("AppData")
            .join("Local")
            .join("back-directory"));
    }

    let home = env::var("HOME").map_err(|_| Error::msg("bd: HOME not set"))?;
    Ok(PathBuf::from(home)
        .join(".local")
        .join("state")
        .join("back-directory"))
}

fn ensure_schema(conn: &Connection) -> Result<()> {
    ensure_column(
        conn,
        "sessions",
        "last_seen_at",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    ensure_column(
        conn,
        "undo_moves",
        "created_at",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    Ok(())
}

fn ensure_column(conn: &Connection, table: &str, column: &str, definition: &str) -> Result<()> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(1)?;
        if name == column {
            return Ok(());
        }
    }
    conn.execute(
        &format!("ALTER TABLE {table} ADD COLUMN {column} {definition}"),
        [],
    )?;
    Ok(())
}
