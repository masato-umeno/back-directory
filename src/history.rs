use crate::cleanup;
use crate::error::{Error, Result};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;

pub const BD_MAX_BACK: u32 = 999;

pub fn validate_pwd(pwd: &str) -> Result<()> {
    if !Path::new(pwd).is_dir() {
        return Err(Error::msg("bd: pwd is not a directory"));
    }
    Ok(())
}

pub fn validate_back(n: u32) -> Result<()> {
    if n == 0 {
        return Err(Error::msg("bd: usage: bd [N|c|ls]"));
    }
    if n > BD_MAX_BACK {
        return Err(Error::msg(format!("bd: max is {BD_MAX_BACK}")));
    }
    Ok(())
}

pub fn validate_list(limit: u32) -> Result<()> {
    if limit == 0 {
        return Err(Error::msg("bd: usage: bd ls [N]"));
    }
    if limit > BD_MAX_BACK {
        return Err(Error::msg(format!("bd: max is {BD_MAX_BACK}")));
    }
    Ok(())
}

pub fn record(conn: &mut Connection, session: &str, pwd: &str, now: i64) -> Result<()> {
    validate_pwd(pwd)?;
    cleanup::maybe_run(conn, session, now)?;
    let tx = conn.transaction()?;

    let last_path: Option<String> = tx
        .query_row(
            "SELECT path FROM events WHERE session_key = ?1 ORDER BY id DESC LIMIT 1",
            params![session],
            |row| row.get(0),
        )
        .optional()?;

    let mut latest_id = None;
    if last_path.as_deref() != Some(pwd) {
        tx.execute(
            "INSERT INTO events (session_key, path, ts) VALUES (?1, ?2, ?3)",
            params![session, pwd, now],
        )?;
        latest_id = Some(tx.last_insert_rowid());
    }

    if latest_id.is_none() {
        latest_id = latest_event_id(&tx, session)?;
    }

    let latest_id = match latest_id {
        Some(id) => id,
        None => {
            tx.execute(
                "INSERT INTO events (session_key, path, ts) VALUES (?1, ?2, ?3)",
                params![session, pwd, now],
            )?;
            tx.last_insert_rowid()
        }
    };

    tx.execute(
        "INSERT INTO sessions (session_key, cursor_id, last_bd_delta, last_bd_from_id, last_bd_to_id, last_bd_armed, last_seen_at)
         VALUES (?1, ?2, 0, 0, 0, 0, ?3)
         ON CONFLICT(session_key) DO UPDATE SET
           cursor_id = excluded.cursor_id,
           last_bd_delta = 0,
           last_bd_from_id = 0,
           last_bd_to_id = 0,
           last_bd_armed = 0,
           last_seen_at = excluded.last_seen_at",
        params![session, latest_id, now],
    )?;

    tx.execute(
        "DELETE FROM undo_moves WHERE session_key = ?1",
        params![session],
    )?;

    cleanup::rotate_events(&tx, session, cleanup::BD_EVENT_LIMIT)?;
    tx.commit()?;
    Ok(())
}

pub fn back(conn: &mut Connection, session: &str, n: u32, now: i64) -> Result<String> {
    validate_back(n)?;
    cleanup::maybe_run(conn, session, now)?;
    let tx = conn.transaction()?;
    let cursor_id = resolve_cursor(&tx, session, "bd: no earlier directory")?;

    let (target_id, target_path, actual_steps) = {
        let mut stmt = tx.prepare(
            "SELECT id, path FROM events WHERE session_key = ?1 AND id < ?2 ORDER BY id DESC",
        )?;
        let mut rows = stmt.query(params![session, cursor_id])?;

        let mut steps: u32 = 0;
        let mut target: Option<(i64, String, u32)> = None;
        let mut oldest_existing: Option<(i64, String, u32)> = None;

        while let Some(row) = rows.next()? {
            let id: i64 = row.get(0)?;
            let path: String = row.get(1)?;
            steps += 1;

            if Path::new(&path).is_dir() {
                oldest_existing = Some((id, path.clone(), steps));
                if steps >= n {
                    target = Some((id, path, steps));
                    break;
                }
            }
        }

        match target.or(oldest_existing) {
            Some(value) => value,
            None => return Err(Error::msg("bd: no earlier directory")),
        }
    };

    tx.execute(
        "INSERT INTO sessions (session_key, cursor_id, last_bd_delta, last_bd_from_id, last_bd_to_id, last_bd_armed, last_seen_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6)
         ON CONFLICT(session_key) DO UPDATE SET
           cursor_id = excluded.cursor_id,
           last_bd_delta = excluded.last_bd_delta,
           last_bd_from_id = excluded.last_bd_from_id,
           last_bd_to_id = excluded.last_bd_to_id,
           last_bd_armed = 1,
           last_seen_at = excluded.last_seen_at",
        params![session, target_id, actual_steps, cursor_id, target_id, now],
    )?;

    tx.execute(
        "INSERT INTO undo_moves (session_key, from_id, to_id, created_at) VALUES (?1, ?2, ?3, ?4)",
        params![session, cursor_id, target_id, now],
    )?;

    tx.commit()?;
    Ok(target_path)
}

pub fn list(
    conn: &mut Connection,
    session: &str,
    limit: u32,
    now: i64,
) -> Result<Vec<(u32, String)>> {
    validate_list(limit)?;
    cleanup::maybe_run(conn, session, now)?;
    let tx = conn.transaction()?;
    let cursor_id = resolve_cursor(&tx, session, "bd: no history in this session")?;

    tx.execute(
        "UPDATE sessions SET last_seen_at = ?1 WHERE session_key = ?2",
        params![now, session],
    )?;

    let mut stmt = tx.prepare(
        "SELECT id, path FROM events WHERE session_key = ?1 AND id < ?2 ORDER BY id DESC",
    )?;
    let mut rows = stmt.query(params![session, cursor_id])?;

    let mut steps: u32 = 0;
    let mut printed = 0;
    let mut lines: Vec<(u32, String)> = Vec::new();
    while let Some(row) = rows.next()? {
        let _id: i64 = row.get(0)?;
        let path: String = row.get(1)?;
        steps += 1;
        if Path::new(&path).is_dir() {
            lines.push((steps, path));
            printed += 1;
            if printed >= limit {
                break;
            }
        }
    }

    if printed == 0 {
        return Err(Error::msg("bd: no history in this session"));
    }

    // Match the previous behavior: leave the last_seen_at update uncommitted.
    Ok(lines)
}

pub fn cancel(conn: &mut Connection, session: &str, now: i64) -> Result<String> {
    cleanup::maybe_run(conn, session, now)?;
    let tx = conn.transaction()?;

    let row: Option<(i64, i64)> = tx
        .query_row(
            "SELECT id, from_id FROM undo_moves WHERE session_key = ?1 ORDER BY id DESC LIMIT 1",
            params![session],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;

    let (undo_id, last_bd_from_id) = match row {
        Some(value) => value,
        None => return Err(Error::msg("bd: nothing to cancel")),
    };

    let target_path: Option<String> = tx
        .query_row(
            "SELECT path FROM events WHERE id = ?1 AND session_key = ?2",
            params![last_bd_from_id, session],
            |row| row.get(0),
        )
        .optional()?;

    let target_path = match target_path {
        Some(path) if Path::new(&path).is_dir() => path,
        _ => return Err(Error::msg("bd: nothing to cancel")),
    };

    tx.execute(
        "UPDATE sessions SET cursor_id = ?1, last_bd_delta = 0, last_bd_from_id = 0, last_bd_to_id = 0, last_bd_armed = 0,
         last_seen_at = ?2 WHERE session_key = ?3",
        params![last_bd_from_id, now, session],
    )?;

    tx.execute("DELETE FROM undo_moves WHERE id = ?1", params![undo_id])?;

    tx.commit()?;
    Ok(target_path)
}

fn latest_event_id(conn: &Connection, session: &str) -> Result<Option<i64>> {
    Ok(conn
        .query_row(
            "SELECT id FROM events WHERE session_key = ?1 ORDER BY id DESC LIMIT 1",
            params![session],
            |row| row.get(0),
        )
        .optional()?)
}

fn event_exists(conn: &Connection, id: i64, session: &str) -> Result<bool> {
    let id: Option<i64> = conn
        .query_row(
            "SELECT id FROM events WHERE id = ?1 AND session_key = ?2",
            params![id, session],
            |row| row.get(0),
        )
        .optional()?;
    Ok(id.is_some())
}

fn resolve_cursor(conn: &Connection, session: &str, no_history: &str) -> Result<i64> {
    let latest_id = latest_event_id(conn, session)?;
    let cursor_id: Option<i64> = conn
        .query_row(
            "SELECT cursor_id FROM sessions WHERE session_key = ?1",
            params![session],
            |row| row.get(0),
        )
        .optional()?;

    match cursor_id {
        Some(id) if event_exists(conn, id, session)? => Ok(id),
        _ => latest_id.ok_or_else(|| Error::msg(no_history)),
    }
}

#[cfg(test)]
mod tests {
    use super::{back, cancel, list, record};
    use crate::test_support::{path_string, TempDb, TempDir};
    use rusqlite::{params, Connection};

    fn event_count(conn: &Connection, session: &str) -> i64 {
        conn.query_row(
            "SELECT COUNT(*) FROM events WHERE session_key = ?1",
            params![session],
            |row| row.get(0),
        )
        .unwrap()
    }

    fn undo_count(conn: &Connection, session: &str) -> i64 {
        conn.query_row(
            "SELECT COUNT(*) FROM undo_moves WHERE session_key = ?1",
            params![session],
            |row| row.get(0),
        )
        .unwrap()
    }

    fn cursor_id(conn: &Connection, session: &str) -> i64 {
        conn.query_row(
            "SELECT cursor_id FROM sessions WHERE session_key = ?1",
            params![session],
            |row| row.get(0),
        )
        .unwrap()
    }

    #[test]
    fn record_collapses_consecutive_paths_and_resets_undo() {
        let db = TempDb::new();
        let dirs = TempDir::new();
        let a = dirs.make("a");
        let b = dirs.make("b");
        let c = dirs.make("c");
        let missing = path_string(&dirs.join("missing"));
        let mut conn = db.open();
        let session = "record";

        record(&mut conn, session, &a, 100).unwrap();
        record(&mut conn, session, &b, 101).unwrap();
        record(&mut conn, session, &b, 102).unwrap();
        assert_eq!(event_count(&conn, session), 2);

        assert_eq!(back(&mut conn, session, 1, 103).unwrap(), a);
        assert_eq!(undo_count(&conn, session), 1);

        record(&mut conn, session, &c, 104).unwrap();
        assert_eq!(event_count(&conn, session), 3);
        assert_eq!(cursor_id(&conn, session), 3);
        assert_eq!(undo_count(&conn, session), 0);

        record(&mut conn, session, &c, 105).unwrap();
        assert_eq!(event_count(&conn, session), 3);
        assert_eq!(cursor_id(&conn, session), 3);

        let error = record(&mut conn, session, &missing, 106).unwrap_err();
        assert_eq!(error.to_string(), "bd: pwd is not a directory");
    }

    #[test]
    fn back_counts_missing_directories_but_skips_them() {
        let db = TempDb::new();
        let dirs = TempDir::new();
        let a = dirs.make("a");
        let b = dirs.make("b");
        let c = dirs.make("c");
        let d = dirs.make("d");
        let mut conn = db.open();
        let session = "back";

        record(&mut conn, session, &a, 100).unwrap();
        record(&mut conn, session, &b, 101).unwrap();
        record(&mut conn, session, &c, 102).unwrap();
        record(&mut conn, session, &d, 103).unwrap();
        dirs.remove("b");

        assert_eq!(back(&mut conn, session, 2, 104).unwrap(), a);

        record(&mut conn, session, &d, 105).unwrap();
        assert_eq!(back(&mut conn, session, 1, 106).unwrap(), c);

        record(&mut conn, session, &d, 107).unwrap();
        assert_eq!(back(&mut conn, session, 99, 108).unwrap(), a);

        record(&mut conn, session, &d, 109).unwrap();
        assert_eq!(
            back(&mut conn, session, 0, 110).unwrap_err().to_string(),
            "bd: usage: bd [N|c|ls]"
        );
        assert_eq!(
            back(&mut conn, session, 1000, 111).unwrap_err().to_string(),
            "bd: max is 999"
        );
        assert_eq!(
            back(&mut conn, "empty", 1, 112).unwrap_err().to_string(),
            "bd: no earlier directory"
        );
    }

    #[test]
    fn cancel_returns_moves_in_reverse_order() {
        let db = TempDb::new();
        let dirs = TempDir::new();
        let a = dirs.make("a");
        let b = dirs.make("b");
        let c = dirs.make("c");
        let mut conn = db.open();
        let session = "cancel";

        record(&mut conn, session, &a, 100).unwrap();
        record(&mut conn, session, &b, 101).unwrap();
        record(&mut conn, session, &c, 102).unwrap();

        assert_eq!(back(&mut conn, session, 1, 103).unwrap(), b);
        assert_eq!(back(&mut conn, session, 1, 104).unwrap(), a);
        assert_eq!(cancel(&mut conn, session, 105).unwrap(), b);
        assert_eq!(cancel(&mut conn, session, 106).unwrap(), c);
        assert_eq!(
            cancel(&mut conn, session, 107).unwrap_err().to_string(),
            "bd: nothing to cancel"
        );
    }

    #[test]
    fn list_numbers_match_back_steps_and_leave_gaps() {
        let db = TempDb::new();
        let dirs = TempDir::new();
        let a = dirs.make("a");
        let b = dirs.make("b");
        let c = dirs.make("c");
        let d = dirs.make("d");
        let mut conn = db.open();
        let session = "list";

        record(&mut conn, session, &a, 100).unwrap();
        record(&mut conn, session, &b, 101).unwrap();
        record(&mut conn, session, &c, 102).unwrap();
        record(&mut conn, session, &d, 103).unwrap();
        dirs.remove("b");

        assert_eq!(
            list(&mut conn, session, 10, 104).unwrap(),
            vec![(1, c.clone()), (3, a.clone())]
        );
        assert_eq!(
            list(&mut conn, session, 1, 105).unwrap(),
            vec![(1, c.clone())]
        );

        record(&mut conn, session, &d, 106).unwrap();
        assert_eq!(back(&mut conn, session, 1, 107).unwrap(), c);

        record(&mut conn, session, &d, 108).unwrap();
        assert_eq!(back(&mut conn, session, 3, 109).unwrap(), a);

        assert_eq!(
            list(&mut conn, "empty", 10, 110).unwrap_err().to_string(),
            "bd: no history in this session"
        );
        assert_eq!(
            list(&mut conn, session, 0, 111).unwrap_err().to_string(),
            "bd: usage: bd ls [N]"
        );
        assert_eq!(
            list(&mut conn, session, 1000, 112).unwrap_err().to_string(),
            "bd: max is 999"
        );
    }
}
