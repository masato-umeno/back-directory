#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BIN="${BD_CORE_BIN:-$ROOT_DIR/target/release/bd-core}"

if [ ! -x "$BIN" ]; then
  echo "bd-core binary not found at $BIN" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

test_home="$tmpdir/home"
test_state="$tmpdir/state"
mkdir -p "$test_home" "$test_state" "$tmpdir/a" "$tmpdir/b"

run_shell_test() {
  shell="$1"
  wrapper="$2"

  HOME="$test_home" XDG_STATE_HOME="$test_state" "$shell" -c '
    set -eu
    export BD_CORE_BIN="$1"
    export BD_SESSION_ID="e2e-$4"
    source "$2/scripts/$3"

    cd "$5/a"
    if [ "$4" = bash ]; then back_directory_prompt; fi
    cd "$5/b"
    if [ "$4" = bash ]; then back_directory_prompt; fi

    bd 1
    if [ "$PWD" != "$5/a" ]; then
      echo "expected back to a, got $PWD" >&2
      exit 1
    fi

    bd c
    if [ "$PWD" != "$5/b" ]; then
      echo "expected cancel back to b, got $PWD" >&2
      exit 1
    fi

    if bd optimize unexpected >/dev/null 2>&1; then
      echo "bd optimize accepted an extra argument" >&2
      exit 1
    fi
    if bd vacuum --yes unexpected >/dev/null 2>&1; then
      echo "bd vacuum accepted an extra argument" >&2
      exit 1
    fi
  ' "$shell" "$BIN" "$ROOT_DIR" "$wrapper" "$shell" "$tmpdir"
}

run_shell_test bash bd.bash
run_shell_test zsh bd.zsh

test -f "$test_state/back-directory/bd.sqlite3"
