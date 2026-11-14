# Dataflow and cleanup

This document shows how `bd` records directory changes, how `bd N` and `bd c` move
through them, and how old data is removed. The diagrams render on GitHub.

## Components

`bd` is a shell function. It cannot be a plain binary, because a child process cannot
change the directory of the shell that started it. The shell part is kept small and the
Rust binary `bd-core` owns all state.

```mermaid
flowchart LR
  you([You])

  subgraph shell["Your shell: bash, zsh, or PowerShell"]
    hook["Directory-change hook"]
    bdfn["bd function"]
  end

  core["bd-core"]
  db[("bd.sqlite3")]

  you -- "cd somewhere" --> hook
  you -- "bd, bd N, bd c, bd ls" --> bdfn
  hook -- "record" --> core
  bdfn -- "back, cancel, list" --> core
  core -- "target path" --> bdfn
  core <--> db
```

| Part | Where | Job |
| --- | --- | --- |
| Hook | `chpwd` (zsh), `PROMPT_COMMAND` (bash), `LocationChangedAction` or `prompt` (PowerShell) | Calls `bd-core record` after the directory changes |
| `bd` function | `scripts/bd.zsh`, `scripts/bd.bash`, `scripts/bd.ps1` | Checks arguments, asks `bd-core` for a path, then changes directory |
| `bd-core` | `src/main.rs` | Stores history, picks the target, keeps the undo stack |
| Database | `${XDG_STATE_HOME:-~/.local/state}/back-directory/bd.sqlite3`, or `%LOCALAPPDATA%\back-directory\bd.sqlite3` on Windows | One file shared by all shells |

Each shell is one session. The wrapper computes a session key when it loads (terminal and
process id in zsh, parent and process id plus host and user in bash, process id and start
time in PowerShell), unless `BD_SESSION_ID` is already set. Every row in the database
belongs to one session key.

## Tables

```mermaid
erDiagram
  sessions ||--o{ events : "has history"
  sessions ||--o{ undo_moves : "has undo stack"
  events ||--o| sessions : "cursor_id points at"
  events ||--o{ undo_moves : "from_id and to_id point at"

  events {
    INTEGER id PK
    TEXT session_key
    TEXT path
    INTEGER ts
  }
  sessions {
    TEXT session_key PK
    INTEGER cursor_id
    INTEGER last_seen_at
  }
  undo_moves {
    INTEGER id PK
    TEXT session_key
    INTEGER from_id
    INTEGER to_id
    INTEGER created_at
  }
  meta {
    TEXT key PK
    INTEGER value
  }
```

- `events`: one row per directory change, in order.
- `sessions`: where the session currently stands in its history (`cursor_id`).
- `undo_moves`: one row per `bd` move that can still be cancelled.
- `meta`: the time of the last cleanup (`last_cleanup_at`).

The links are by convention; the schema declares no foreign keys. `sessions` also has
`last_bd_*` columns that are written but no longer drive any decision. The full column
list is in [development.md](development.md#sqlite-schema).

## The cursor

A session is either at the newest event or somewhere behind it.

```mermaid
stateDiagram-v2
  direction LR
  [*] --> AtNewest: wrapper loads
  AtNewest --> AtNewest: cd
  AtNewest --> MovedBack: bd N
  MovedBack --> MovedBack: bd N
  MovedBack --> MovedBack: bd c, undo stack not empty
  MovedBack --> AtNewest: bd c, undo stack empty
  MovedBack --> AtNewest: cd
```

- `bd N` moves the cursor back and pushes the move onto the undo stack.
- `bd c` pops one move and puts the cursor back where that move started.
- A normal `cd` adds an event, moves the cursor to it, and clears the undo stack.

## What each command does

### A directory change (`record`)

```mermaid
sequenceDiagram
  actor You
  participant Shell as Shell hook
  participant Core as bd-core
  participant DB as SQLite

  You->>Shell: cd /work/b
  Shell->>Core: record --session S1 --pwd /work/b
  Core->>DB: insert into events, unless the newest event is the same path
  Core->>DB: sessions.cursor_id = newest event
  Core->>DB: delete this session's undo_moves
  Core->>DB: rotate old events of this session
```

The hook discards the output of `record`, so a failure here is silent. `bd doctor` shows
the state of the database.

### Going back (`bd N`)

```mermaid
sequenceDiagram
  actor You
  participant Fn as bd function
  participant Core as bd-core
  participant DB as SQLite

  You->>Fn: bd 2
  Fn->>Core: back --session S1 --n 2
  Core->>DB: read events older than the cursor, newest first
  Note over Core: Count steps and stop at step N.<br/>Skip directories that no longer exist.
  Core->>DB: sessions.cursor_id = target
  Core->>DB: push (from, to) onto undo_moves
  Core-->>Fn: /work/x
  Fn->>Fn: cd /work/x, and tell the hook not to record it
```

- Directories that no longer exist still count as a step, but are never chosen. If step
  `N` is missing, the next older existing directory is used.
- If the history is shorter than `N`, `bd` goes to the oldest existing directory.
- The move itself is not added to `events`.

### Cancelling (`bd c`)

```mermaid
sequenceDiagram
  actor You
  participant Fn as bd function
  participant Core as bd-core
  participant DB as SQLite

  You->>Fn: bd c
  Fn->>Core: cancel --session S1
  Core->>DB: read the newest row of undo_moves
  Core->>DB: sessions.cursor_id = from_id
  Core->>DB: delete that undo_moves row
  Core-->>Fn: /work/b
  Fn->>Fn: cd /work/b, and tell the hook not to record it
```

## Worked example

Start in `/work/x`, then `cd /work/a` and `cd /work/b`.

| Step | Command | `events` (id: path) | Cursor | Undo stack | You are in |
| --- | --- | --- | --- | --- | --- |
| 1 | `cd /work/b` | 1: x, 2: a, 3: b | 3 | empty | b |
| 2 | `bd 2` | 1: x, 2: a, 3: b | 1 | 3 → 1 | x |
| 3 | `bd c` | 1: x, 2: a, 3: b | 3 | empty | b |
| 4 | `bd 2` | 1: x, 2: a, 3: b | 1 | 3 → 1 | x |
| 5 | `cd /work/c` | 1: x, 2: a, 3: b, 4: c | 4 | empty | c |
| 6 | `bd` | 1: x, 2: a, 3: b, 4: c | 3 | 4 → 3 | b |

Step 6 lands in `b`, not in `x`, although `x` is where you were before `c`. `bd` walks the
log of `cd` commands, and the `bd 2` in step 4 is not part of that log. Whether this
should change is tracked in
[issue 10](https://github.com/masato-umeno/back-directory/issues/10).

## Cleanup

Two mechanisms keep the database small. Both run inside ordinary commands; there is no
background process.

```mermaid
flowchart TD
  start([record, back, list, or cancel]) --> due{"10 days since<br/>last_cleanup_at?"}
  due -- no --> cmd[Run the command]
  due -- yes --> s["Delete sessions not seen for 180 days,<br/>except the current one"]
  s --> u[Delete undo_moves older than 90 days]
  u --> m[Set last_cleanup_at to now]
  m --> cmd
  cmd --> isrec{"Was it record?"}
  isrec -- no --> done([Done])
  isrec -- yes --> big{"10,000 or more events<br/>in this session?"}
  big -- no --> done
  big -- yes --> rot["Delete this session's events older than the<br/>10,000th newest, keeping any that the cursor<br/>or the undo stack still points at"]
  rot --> done
```

| What | When | Rule |
| --- | --- | --- |
| Retention cleanup | At most once every 10 days | Remove sessions unused for 180 days and undo moves older than 90 days |
| Event rotation | On every `record` | Keep the newest 10,000 events of the session |

Known gap: retention cleanup removes the `sessions` row but leaves that session's
`events` rows behind. See
[issue 7](https://github.com/masato-umeno/back-directory/issues/7).

Space freed by deletes stays inside the file until `bd optimize` runs SQLite `VACUUM`.
`bd vacuum` is different: it deletes the database file and all history. See
[maintenance.md](maintenance.md).
