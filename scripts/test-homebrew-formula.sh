#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

sha_a=$(printf a%.0s $(seq 1 64))
sha_b=$(printf b%.0s $(seq 1 64))
sha_c=$(printf c%.0s $(seq 1 64))
sha_d=$(printf d%.0s $(seq 1 64))

"$ROOT_DIR/scripts/render-homebrew-formula.sh" 9.8.7 "$sha_a" "$sha_b" "$sha_c" "$sha_d" > "$tmpdir/one.rb"
"$ROOT_DIR/scripts/render-homebrew-formula.sh" 9.8.7 "$sha_a" "$sha_b" "$sha_c" "$sha_d" > "$tmpdir/two.rb"
cmp "$tmpdir/one.rb" "$tmpdir/two.rb"
ruby -c "$tmpdir/one.rb" >/dev/null

grep -q 'releases/download/v9.8.7/bd-core-aarch64-apple-darwin.tar.gz' "$tmpdir/one.rb"
grep -q "sha256 \"$sha_d\"" "$tmpdir/one.rb"
grep -q 'resource(target).stage' "$tmpdir/one.rb"
if grep -q 'post_install\|depends_on "rust"' "$tmpdir/one.rb"; then
  echo "formula must use release artifacts without modifying shell rc files" >&2
  exit 1
fi

ruby -c "$ROOT_DIR/Formula/back-directory.rb" >/dev/null
