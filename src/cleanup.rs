use crate::error::Result;
use rusqlite::{params, Connection, OptionalExtension, Transaction};

pub const BD_EVENT_LIMIT: i64 = 10_000;
pub const CLEANUP_INTERVAL_SECS: i64 = 10 * 24 * 60 * 60; //  10 days
pub const SESSION_RETENTION_SECS: i64 = 180 * 24 * 60 * 60; // 180 days
pub const UNDO_RETENTION_SECS: i64 = 90 * 24 * 60 * 60; //  90 days
pub const META_LAST_CLEANUP_KEY: &str = "last_cleanup_at";

/// Deletes the oldest events of a session, keeping `limit` events at most.
///
/// Rows still referenced by the session cursor, the legacy last-move columns, or
/// an undo move are never deleted.
pub fn rotate_events(tx: &Transaction<'_>, session: &str, limit: i64) -> Result<()> {
    if limit <= 0 {
        return Ok(());
    }

    let min_session_cursor_id: Option<i64> = tx.query_row(
        "SELECT MIN(val) FROM (
           SELECT cursor_id AS val FROM sessions WHERE session_key = ?1 AND cursor_id != 0
           UNION ALL
           SELECT last_bd_from_id FROM sessions WHERE session_key = ?1 AND last_bd_from_id != 0
           UNION ALL
           SELECT last_bd_to_id FROM sessions WHERE session_key = ?1 AND last_bd_to_id != 0
           UNION ALL
           SELECT from_id FROM undo_moves WHERE session_key = ?1
           UNION ALL
           SELECT to_id FROM undo_moves WHERE session_key = ?1
         )",
        params![session],
        |row| row.get(0),
    )?;

    let rotation_cutoff_id: Option<i64> = tx
        .query_row(
            "SELECT id FROM events WHERE session_key = ?1 ORDER BY id DESC LIMIT 1 OFFSET ?2",
            params![session, limit - 1],
            |row| row.get(0),
        )
        .optional()?;

    let (rotation_cutoff_id, min_session_cursor_id) =
        match (rotation_cutoff_id, min_session_cursor_id) {
            (Some(rotation_cutoff_id), Some(min_session_cursor_id)) => {
                (rotation_cutoff_id, min_session_cursor_id)
            }
            _ => return Ok(()),
        };

    let delete_before = rotation_cutoff_id.min(min_session_cursor_id);
    if delete_before <= 0 {
        return Ok(());
    }

    tx.execute(
        "DELETE FROM events WHERE session_key = ?1 AND id < ?2",
        params![session, delete_before],
    )?;

    Ok(())
}

/// Runs retention cleanup at most once every ten days.
pub fn maybe_run(conn: &mut Connection, session: &str, now: i64) -> Result<()> {
    let last_cleanup_at: i64 = conn
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            params![META_LAST_CLEANUP_KEY],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or(0);

    if now.saturating_sub(last_cleanup_at) < CLEANUP_INTERVAL_SECS {
        return Ok(());
    }

    let session_cutoff = now - SESSION_RETENTION_SECS;
    let undo_cutoff = now - UNDO_RETENTION_SECS;
    let tx = conn.transaction()?;

    tx.execute(
        "DELETE FROM sessions WHERE last_seen_at < ?1 AND session_key != ?2",
        params![session_cutoff, session],
    )?;

    tx.execute(
        "DELETE FROM undo_moves WHERE created_at < ?1",
        params![undo_cutoff],
    )?;

    // Sessions removed above (or left behind by older versions) no longer own their
    // events or undo moves. Keep the current session even if it has no sessions row yet.
    tx.execute(
        "DELETE FROM events
         WHERE session_key != ?1
           AND session_key NOT IN (SELECT session_key FROM sessions)",
        params![session],
    )?;

    tx.execute(
        "DELETE FROM undo_moves
         WHERE session_key != ?1
           AND session_key NOT IN (SELECT session_key FROM sessions)",
        params![session],
    )?;

    tx.execute(
        "INSERT INTO meta (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![META_LAST_CLEANUP_KEY, now],
    )?;

    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        maybe_run, rotate_events, CLEANUP_INTERVAL_SECS, META_LAST_CLEANUP_KEY,
        SESSION_RETENTION_SECS, UNDO_RETENTION_SECS,
    };
    use crate::test_support::TempDb;
    use rusqlite::{params, Connection};

    const DAY: i64 = 24 * 60 * 60;

    fn insert_event(conn: &Connection, session: &str, path: &str, ts: i64) -> i64 {
        conn.execute(
            "INSERT INTO events (session_key, path, ts) VALUES (?1, ?2, ?3)",
            params![session, path, ts],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    fn insert_session(conn: &Connection, session: &str, cursor_id: i64, last_seen_at: i64) {
        conn.execute(
            "INSERT INTO sessions (session_key, cursor_id, last_seen_at) VALUES (?1, ?2, ?3)",
            params![session, cursor_id, last_seen_at],
        )
        .unwrap();
    }

    fn insert_undo(
        conn: &Connection,
        session: &str,
        from_id: i64,
        to_id: i64,
        created_at: i64,
    ) -> i64 {
        conn.execute(
            "INSERT INTO undo_moves (session_key, from_id, to_id, created_at)
             VALUES (?1, ?2, ?3, ?4)",
            params![session, from_id, to_id, created_at],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    fn event_ids(conn: &Connection, session: &str) -> Vec<i64> {
        let mut stmt = conn
            .prepare("SELECT id FROM events WHERE session_key = ?1 ORDER BY id")
            .unwrap();
        let rows = stmt.query_map(params![session], |row| row.get(0)).unwrap();
        rows.map(|row| row.unwrap()).collect()
    }

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

    fn cleanup_at(conn: &Connection) -> i64 {
        conn.query_row(
            "SELECT value FROM meta WHERE key = ?1",
            params![META_LAST_CLEANUP_KEY],
            |row| row.get(0),
        )
        .unwrap()
    }

    #[test]
    fn rotate_events_honors_a_small_limit_and_keeps_references() {
        let db = TempDb::new();
        let conn = db.open();
        let session = "rotate";
        let ids: Vec<i64> = (0..6)
            .map(|index| insert_event(&conn, session, &format!("/rotate/{index}"), 0))
            .collect();
        insert_session(&conn, session, ids[2], 0);
        insert_undo(&conn, session, ids[1], ids[2], 0);

        let tx = conn.unchecked_transaction().unwrap();
        rotate_events(&tx, session, 3).unwrap();
        tx.commit().unwrap();

        assert_eq!(event_ids(&conn, session), ids[1..].to_vec());
    }

    #[test]
    fn rotate_events_never_deletes_the_cursor_row() {
        let db = TempDb::new();
        let conn = db.open();
        let session = "rotate-old-cursor";
        let ids: Vec<i64> = (0..6)
            .map(|index| insert_event(&conn, session, &format!("/rotate/{index}"), 0))
            .collect();
        insert_session(&conn, session, ids[0], 0);

        let tx = conn.unchecked_transaction().unwrap();
        rotate_events(&tx, session, 3).unwrap();
        tx.commit().unwrap();

        assert_eq!(event_ids(&conn, session), ids);
    }

    #[test]
    fn cleanup_does_nothing_before_the_interval() {
        let db = TempDb::new();
        let mut conn = db.open();
        let now = 1_000_000_000;
        let event_id = insert_event(&conn, "old", "/old", now);
        insert_session(&conn, "old", event_id, now - SESSION_RETENTION_SECS - DAY);
        insert_undo(
            &conn,
            "old",
            event_id,
            event_id,
            now - UNDO_RETENTION_SECS - DAY,
        );
        conn.execute(
            "INSERT INTO meta (key, value) VALUES (?1, ?2)",
            params![META_LAST_CLEANUP_KEY, now - CLEANUP_INTERVAL_SECS + DAY],
        )
        .unwrap();

        maybe_run(&mut conn, "current", now).unwrap();

        assert_eq!(event_count(&conn, "old"), 1);
        assert_eq!(undo_count(&conn, "old"), 1);
        assert_eq!(cleanup_at(&conn), now - CLEANUP_INTERVAL_SECS + DAY);
    }

    #[test]
    fn cleanup_removes_old_sessions_and_orphaned_events_and_undo_moves() {
        let db = TempDb::new();
        let mut conn = db.open();
        let now = 2_000_000_000;

        let old_event = insert_event(&conn, "old", "/old", now);
        insert_session(&conn, "old", old_event, now - SESSION_RETENTION_SECS - DAY);
        insert_undo(
            &conn,
            "old",
            old_event,
            old_event,
            now - UNDO_RETENTION_SECS - DAY,
        );

        let orphan_event = insert_event(&conn, "orphan", "/orphan", now);
        insert_undo(&conn, "orphan", orphan_event, orphan_event, now);

        let current_event = insert_event(&conn, "current", "/current", now);
        insert_undo(&conn, "current", current_event, current_event, now);

        let live_event = insert_event(&conn, "live", "/live", now);
        insert_session(&conn, "live", live_event, now - DAY);
        insert_undo(
            &conn,
            "live",
            live_event,
            live_event,
            now - UNDO_RETENTION_SECS - DAY,
        );
        insert_undo(&conn, "live", live_event, live_event, now);

        conn.execute(
            "INSERT INTO meta (key, value) VALUES (?1, ?2)",
            params![META_LAST_CLEANUP_KEY, now - CLEANUP_INTERVAL_SECS - DAY],
        )
        .unwrap();

        maybe_run(&mut conn, "current", now).unwrap();

        let sessions: Vec<String> = {
            let mut stmt = conn
                .prepare("SELECT session_key FROM sessions ORDER BY session_key")
                .unwrap();
            let rows = stmt.query_map([], |row| row.get(0)).unwrap();
            rows.map(|row| row.unwrap()).collect()
        };
        assert_eq!(sessions, vec!["live".to_string()]);

        assert_eq!(event_count(&conn, "old"), 0);
        assert_eq!(event_count(&conn, "orphan"), 0);
        assert_eq!(event_count(&conn, "current"), 1);
        assert_eq!(event_count(&conn, "live"), 1);

        assert_eq!(undo_count(&conn, "old"), 0);
        assert_eq!(undo_count(&conn, "orphan"), 0);
        assert_eq!(undo_count(&conn, "current"), 1);
        assert_eq!(undo_count(&conn, "live"), 1);

        assert_eq!(cleanup_at(&conn), now);
    }

    #[test]
    fn cleanup_keeps_the_current_session_even_when_it_is_old() {
        let db = TempDb::new();
        let mut conn = db.open();
        let now = 3_000_000_000;

        let current_event = insert_event(&conn, "current", "/current", now);
        insert_session(
            &conn,
            "current",
            current_event,
            now - SESSION_RETENTION_SECS - DAY,
        );
        insert_undo(&conn, "current", current_event, current_event, now);

        let old_event = insert_event(&conn, "old", "/old", now);
        insert_session(&conn, "old", old_event, now - SESSION_RETENTION_SECS - DAY);

        maybe_run(&mut conn, "current", now).unwrap();

        assert_eq!(event_count(&conn, "current"), 1);
        assert_eq!(undo_count(&conn, "current"), 1);
        assert_eq!(event_count(&conn, "old"), 0);
    }
}
