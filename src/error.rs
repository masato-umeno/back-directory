use std::fmt;
use std::io;

pub type Result<T> = std::result::Result<T, Error>;

/// An error that is already formatted the way the command line prints it.
#[derive(Debug)]
pub enum Error {
    Db(rusqlite::Error),
    Io(io::Error),
    Message(String),
}

impl Error {
    pub fn msg(message: impl Into<String>) -> Self {
        Self::Message(message.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Db(error) => write!(f, "bd: db error: {error}"),
            Self::Io(error) => write!(f, "bd: db error: {error}"),
            Self::Message(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Db(error) => Some(error),
            Self::Io(error) => Some(error),
            Self::Message(_) => None,
        }
    }
}

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Self::Db(error)
    }
}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}
