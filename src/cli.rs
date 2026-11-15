use crate::error::{Error, Result};
use clap::{Parser, Subcommand};

const BD_DEFAULT_LIST: u32 = 10;
pub const POWERSHELL_WRAPPER: &str = include_str!("../scripts/bd.ps1");

#[derive(Parser)]
#[command(author, version, about)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand)]
pub enum Commands {
    Record {
        #[arg(long)]
        session: String,
        #[arg(long)]
        pwd: String,
    },
    Back {
        #[arg(long)]
        session: String,
        #[arg(long)]
        n: u32,
        #[arg(long)]
        print_path: bool,
    },
    List {
        #[arg(long)]
        session: String,
        #[arg(long, default_value_t = BD_DEFAULT_LIST)]
        limit: u32,
    },
    Cancel {
        #[arg(long)]
        session: String,
    },
    Doctor {
        #[arg(long)]
        integrity: bool,
        #[arg(long)]
        json: bool,
        /// Hook mode reported by the shell wrapper (set by the wrapper, not by users)
        #[arg(long, hide = true)]
        hook: Option<String>,
        /// Set by the shell wrapper when its hook is no longer installed
        #[arg(long, hide = true, requires = "hook")]
        hook_missing: bool,
    },
    Optimize,
    /// Print the shell wrapper for the given shell (supported: powershell)
    Init {
        shell: String,
    },
    Vacuum {
        #[arg(long)]
        yes: bool,
        #[arg(long)]
        y: bool,
    },
}

pub fn init(shell: &str) -> Result<()> {
    match shell {
        "powershell" | "pwsh" => {
            print!("{POWERSHELL_WRAPPER}");
            Ok(())
        }
        _ => Err(Error::msg("bd: init supports only: powershell")),
    }
}
