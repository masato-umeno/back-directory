use std::env;
use std::time::{SystemTime, UNIX_EPOCH};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

/// Replaces a leading home directory with `~` for display.
///
/// Windows paths are compared case-insensitively because the file system is.
pub fn abbreviate_home(path: &str, home: &str, separator: char, ignore_case: bool) -> String {
    let home = if home.len() > 1 {
        home.trim_end_matches(separator)
    } else {
        home
    };
    if home.is_empty() || path.len() < home.len() || !path.is_char_boundary(home.len()) {
        return path.to_string();
    }

    let (head, rest) = path.split_at(home.len());
    let head_matches = if ignore_case {
        head.eq_ignore_ascii_case(home)
    } else {
        head == home
    };
    if head_matches && (rest.is_empty() || rest.starts_with(separator)) {
        format!("~{rest}")
    } else {
        path.to_string()
    }
}

pub fn print_list(entries: &[(u32, String)]) {
    let max_step = entries.iter().map(|(step, _)| *step).max().unwrap_or(0);
    let width = max_step.to_string().len();
    let home = env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap_or_default();
    let separator = std::path::MAIN_SEPARATOR;
    for (step, path) in entries.iter().rev() {
        let display_path = abbreviate_home(path, &home, separator, cfg!(windows));
        println!("[{:>width$}] {}", step, display_path, width = width);
    }
}

pub fn format_bytes(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = 1024.0 * 1024.0;
    const GB: f64 = 1024.0 * 1024.0 * 1024.0;
    let value = bytes as f64;
    if value >= GB {
        format!("{:.2} GiB", value / GB)
    } else if value >= MB {
        format!("{:.2} MiB", value / MB)
    } else if value >= KB {
        format!("{:.2} KiB", value / KB)
    } else {
        format!("{bytes} B")
    }
}

pub fn json_escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

pub fn format_ts(ts: i64) -> Option<String> {
    if ts <= 0 {
        return None;
    }
    OffsetDateTime::from_unix_timestamp(ts)
        .ok()
        .and_then(|datetime| datetime.format(&Rfc3339).ok())
}

pub fn current_ts() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::abbreviate_home;

    #[test]
    fn abbreviates_unix_home() {
        assert_eq!(abbreviate_home("/home/u", "/home/u", '/', false), "~");
        assert_eq!(
            abbreviate_home("/home/u/a b", "/home/u/", '/', false),
            "~/a b"
        );
        assert_eq!(
            abbreviate_home("/home/user2", "/home/u", '/', false),
            "/home/user2"
        );
        assert_eq!(
            abbreviate_home("/Home/u/a", "/home/u", '/', false),
            "/Home/u/a"
        );
        assert_eq!(abbreviate_home("/tmp", "", '/', false), "/tmp");
        assert_eq!(abbreviate_home("/tmp", "/", '/', false), "/tmp");
    }

    #[test]
    fn abbreviates_windows_home() {
        let home = r"C:\Users\u";
        assert_eq!(abbreviate_home(r"C:\Users\u", home, '\\', true), "~");
        assert_eq!(
            abbreviate_home(r"c:\users\U\src", home, '\\', true),
            r"~\src"
        );
        assert_eq!(
            abbreviate_home(r"C:\Users\u2\src", home, '\\', true),
            r"C:\Users\u2\src"
        );
        assert_eq!(abbreviate_home(r"D:\work", home, '\\', true), r"D:\work");
    }

    #[test]
    fn keeps_paths_that_split_inside_a_character() {
        assert_eq!(
            abbreviate_home("/h/\u{3042}", "/h/\u{e3}", '/', false),
            "/h/\u{3042}"
        );
    }
}
