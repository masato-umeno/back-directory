#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cast="$ROOT_DIR/examples/bd-demo/media/bd-demo.cast"
webp="$ROOT_DIR/examples/bd-demo/media/bd-demo.webp"

case "${1:-}" in
  check)
    test -s "$cast"
    test -s "$webp"
    first_line=$(sed -n '1p' "$cast")
    printf '%s\n' "$first_line" | grep -Eq '"version"[[:space:]]*:[[:space:]]*[23]([^0-9]|$)'
    ;;
  record)
    test -t 0 || { echo "record requires an interactive terminal" >&2; exit 1; }
    command -v asciinema >/dev/null 2>&1 || { echo "asciinema not found; run inside nix develop" >&2; exit 1; }
    rm -f "$cast"
    asciinema rec "$cast" --command "bash -lc 'cd \"$ROOT_DIR/examples/bd-demo\" && ./demo.sh'"
    ;;
  render)
    command -v agg >/dev/null 2>&1 || { echo "agg not found; run inside nix develop" >&2; exit 1; }
    agg --speed 1.25 --font-size 16 --cols 80 --fps-cap 30 "$cast" "$webp"
    ;;
  all)
    "$0" record
    "$0" render
    ;;
  *)
    echo "usage: $0 {check|record|render|all}" >&2
    exit 1
    ;;
esac
