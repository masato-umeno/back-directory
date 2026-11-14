#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BIN="${BD_CORE_BIN:-$ROOT_DIR/target/release/bd-core}"
[ -x "$BIN" ] || { echo "bd-core binary not found at $BIN" >&2; exit 1; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
prefix="$tmpdir/prefix"
test_home="$tmpdir/home"
test_state="$tmpdir/state"
mkdir -p "$prefix/bin" "$prefix/share/back-directory" "$test_home" "$test_state" "$tmpdir/a" "$tmpdir/b"

# Stage the same payload Homebrew owns, without touching the real Cellar or HOME.
install -m 0755 "$BIN" "$prefix/bin/bd-core"
install -m 0644 "$ROOT_DIR/scripts/bd.bash" "$ROOT_DIR/scripts/bd.zsh" "$prefix/share/back-directory"

HOME="$test_home" XDG_STATE_HOME="$test_state" BD_CORE_BIN="$prefix/bin/bd-core" \
  BD_SESSION_ID=lifecycle zsh -c '
    set -eu
    source "$1/share/back-directory/bd.zsh"
    cd "$2/a"
    cd "$2/b"
    bd
    test "$PWD" = "$2/a"
  ' zsh "$prefix" "$tmpdir"

test -f "$test_state/back-directory/bd.sqlite3"
rm -f "$prefix/bin/bd-core" "$prefix/share/back-directory/bd.bash" "$prefix/share/back-directory/bd.zsh"
test ! -e "$prefix/bin/bd-core"
# Uninstalling the package intentionally preserves user-owned history and rc files.
test -f "$test_state/back-directory/bd.sqlite3"
