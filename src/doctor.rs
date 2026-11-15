use crate::cleanup::META_LAST_CLEANUP_KEY;
use crate::db::{file_size, remove_file_if_exists};
use crate::error::{Error, Result};
use crate::format::{format_bytes, format_ts, json_escape};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::{Path, PathBuf};

/// Hook state reported by the shell wrapper that called `doctor`.
pub struct HookStatus {
    pub mode: String,
    pub installed: bool,
}

const HOOK_MISSING_HINT: &str =
    "directory changes are not recorded; load bd after any prompt setup (move the bd line to the end of your profile)";

pub fn run(
    conn: &Connection,
    path: &Path,
    integrity: bool,
    json: bool,
    hook: Option<&HookStatus>,
    now: i64,
) -> Result<()> {
    let db_size = file_size(path);
    let wal_path = PathBuf::from(format!("{}-wal", path.display()));
    let shm_path = PathBuf::from(format!("{}-shm", path.display()));
    let wal_size = file_size(&wal_path);
    let shm_size = file_size(&shm_path);

    let page_count: i64 = conn.query_row("PRAGMA page_count", [], |row| row.get(0))?;
    let freelist_count: i64 = conn.query_row("PRAGMA freelist_count", [], |row| row.get(0))?;
    let page_size: i64 = conn.query_row("PRAGMA page_size", [], |row| row.get(0))?;

    let events_count: i64 = conn.query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))?;
    let sessions_count: i64 =
        conn.query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0))?;
    let undo_count: i64 =
        conn.query_row("SELECT COUNT(*) FROM undo_moves", [], |row| row.get(0))?;

    let last_cleanup_at: i64 = conn
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            params![META_LAST_CLEANUP_KEY],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or(0);

    let integrity = if integrity {
        let mut stmt = conn.prepare("PRAGMA integrity_check")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        let mut results = Vec::new();
        for row in rows {
            results.push(row?);
        }
        Some(results)
    } else {
        None
    };

    if json {
        let db_path_json = json_escape(&path.to_string_lossy());
        let integrity_json = integrity.as_ref().map(|rows| {
            format!(
                "[{}]",
                rows.iter()
                    .map(|r| format!("\"{}\"", json_escape(r)))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        });
        let last_cleanup_age_days = if last_cleanup_at > 0 {
            Some((now - last_cleanup_at) / 86_400)
        } else {
            None
        };
        let last_cleanup_rfc3339 = format_ts(last_cleanup_at);

        let optimize_recommended = if page_count > 0 {
            (freelist_count as f64 / page_count as f64) >= 0.2
        } else {
            false
        };

        let mut payload = format!(
            "\"database\":\"{db_path}\",\"db_size_bytes\":{db_size},\"wal_size_bytes\":{wal_size},\"shm_size_bytes\":{shm_size},\"page_count\":{page_count},\"freelist_count\":{freelist_count},\"page_size\":{page_size},\"events\":{events},\"sessions\":{sessions},\"undo_moves\":{undo},\"last_cleanup_at\":{last_cleanup_at},\"last_cleanup_at_rfc3339\":{last_cleanup_rfc3339},\"last_cleanup_age_days\":{last_cleanup_age},\"optimize_recommended\":{optimize_recommended}",
            db_path = db_path_json,
            db_size = db_size.map_or("null".to_string(), |v| v.to_string()),
            wal_size = wal_size.map_or("null".to_string(), |v| v.to_string()),
            shm_size = shm_size.map_or("null".to_string(), |v| v.to_string()),
            page_count = page_count,
            freelist_count = freelist_count,
            page_size = page_size,
            events = events_count,
            sessions = sessions_count,
            undo = undo_count,
            last_cleanup_at = last_cleanup_at,
            last_cleanup_rfc3339 = last_cleanup_rfc3339
                .map(|v| format!("\"{}\"", json_escape(&v)))
                .unwrap_or_else(|| "null".to_string()),
            last_cleanup_age = last_cleanup_age_days.map_or("null".to_string(), |v| v.to_string()),
            optimize_recommended = optimize_recommended,
        );
        if let Some(hook) = hook {
            payload.push_str(&format!(
                ",\"hook_mode\":\"{}\",\"hook_installed\":{}",
                json_escape(&hook.mode),
                hook.installed
            ));
        }
        if let Some(integrity_json) = integrity_json {
            payload.push_str(&format!(",\"integrity_check\":{integrity_json}"));
        }
        println!("{{{payload}}}");
        return Ok(());
    }

    println!("sqlite.database");
    println!("  path: {}", path.display());
    if let Some(size) = db_size {
        println!("  size: {} ({} bytes)", format_bytes(size), size);
    } else {
        println!("  size: unknown");
    }
    if wal_size.is_some() || shm_size.is_some() {
        println!("sqlite.wal");
        if let Some(size) = wal_size {
            println!("  size: {} ({} bytes)", format_bytes(size), size);
        }
        if let Some(size) = shm_size {
            println!("  shm size: {} ({} bytes)", format_bytes(size), size);
        }
    }
    println!("sqlite.stats");
    println!("  page_count: {page_count}");
    println!("  freelist_count: {freelist_count}");
    println!("  page_size: {page_size}");
    println!("app.tables");
    println!("  events: {events_count}");
    println!("  sessions: {sessions_count}");
    println!("  undo_moves: {undo_count}");
    let optimize_recommended = if page_count > 0 {
        (freelist_count as f64 / page_count as f64) >= 0.2
    } else {
        false
    };
    if optimize_recommended {
        println!("optimize");
        println!("  recommended: yes (can be slow)");
    } else {
        println!("optimize");
        println!("  recommended: no");
    }
    if last_cleanup_at > 0 {
        let age_days = (now - last_cleanup_at) / 86_400;
        let formatted = format_ts(last_cleanup_at).unwrap_or_else(|| "unknown".to_string());
        println!("cleanup");
        println!("  last_cleanup_at: {formatted} ({age_days} days ago)");
    } else {
        println!("cleanup");
        println!("  last_cleanup_at: never");
    }
    if let Some(hook) = hook {
        println!("shell.hook");
        println!("  mode: {}", hook.mode);
        if hook.installed {
            println!("  installed: yes");
        } else {
            println!("  installed: no ({HOOK_MISSING_HINT})");
        }
    }
    if let Some(rows) = integrity {
        if rows.len() == 1 && rows[0] == "ok" {
            println!("integrity_check: ok");
        } else {
            println!("integrity_check:");
            for line in rows {
                println!("- {line}");
            }
        }
    }
    Ok(())
}

pub fn optimize(conn: &Connection) -> Result<()> {
    conn.execute_batch("VACUUM;")?;
    Ok(())
}

pub fn confirm_vacuum(yes: bool) -> Result<()> {
    if !yes {
        return Err(Error::msg(
            "bd: vacuum requires --yes (this deletes all history)",
        ));
    }
    Ok(())
}

pub fn vacuum(path: &Path) -> Result<()> {
    remove_file_if_exists(path)?;
    let wal_path = PathBuf::from(format!("{}-wal", path.display()));
    let shm_path = PathBuf::from(format!("{}-shm", path.display()));
    remove_file_if_exists(&wal_path)?;
    remove_file_if_exists(&shm_path)?;
    crate::db::open(path)?;
    Ok(())
}
