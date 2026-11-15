mod cleanup;
mod cli;
mod db;
mod doctor;
mod error;
mod format;
mod history;
#[cfg(test)]
mod test_support;

use clap::Parser;
use error::Result;

fn main() {
    let cli = cli::Cli::parse();
    if let Err(error) = dispatch(cli.command) {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn dispatch(command: cli::Commands) -> Result<()> {
    match command {
        cli::Commands::Record { session, pwd } => {
            history::validate_pwd(&pwd)?;
            let mut conn = db::open_default()?;
            history::record(&mut conn, &session, &pwd, format::current_ts())
        }
        cli::Commands::Back {
            session,
            n,
            print_path: _,
        } => {
            history::validate_back(n)?;
            let mut conn = db::open_default()?;
            let target = history::back(&mut conn, &session, n, format::current_ts())?;
            println!("{target}");
            Ok(())
        }
        cli::Commands::List { session, limit } => {
            history::validate_list(limit)?;
            let mut conn = db::open_default()?;
            let entries = history::list(&mut conn, &session, limit, format::current_ts())?;
            format::print_list(&entries);
            Ok(())
        }
        cli::Commands::Cancel { session } => {
            let mut conn = db::open_default()?;
            let target = history::cancel(&mut conn, &session, format::current_ts())?;
            println!("{target}");
            Ok(())
        }
        cli::Commands::Doctor {
            integrity,
            json,
            hook,
            hook_missing,
        } => {
            let path = db::default_path()?;
            let conn = db::open(&path)?;
            let hook = hook.map(|mode| doctor::HookStatus {
                mode,
                installed: !hook_missing,
            });
            doctor::run(
                &conn,
                &path,
                integrity,
                json,
                hook.as_ref(),
                format::current_ts(),
            )
        }
        cli::Commands::Optimize => {
            let conn = db::open_default()?;
            doctor::optimize(&conn)
        }
        cli::Commands::Init { shell } => cli::init(&shell),
        cli::Commands::Vacuum { yes, y } => {
            doctor::confirm_vacuum(yes || y)?;
            let path = db::default_path()?;
            doctor::vacuum(&path)
        }
    }
}
