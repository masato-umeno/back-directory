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

# The checked-in formula must be exactly what the renderer produces for its
# release, so that the template (used by the release workflow) is what we test.
formula="$ROOT_DIR/Formula/back-directory.rb"
formula_version=$(sed -n 's|.*/archive/refs/tags/v\(.*\)\.tar\.gz".*|\1|p' "$formula")
# shellcheck disable=SC2046
"$ROOT_DIR/scripts/render-homebrew-formula.sh" "$formula_version" \
  $(sed -n 's/^ *sha256 "\([0-9a-f]*\)"$/\1/p' "$formula") > "$tmpdir/checked-in.rb"
if ! diff -u "$formula" "$tmpdir/checked-in.rb"; then
  echo "Formula/back-directory.rb differs from scripts/render-homebrew-formula.sh output" >&2
  exit 1
fi
if grep -q '\\#{' "$tmpdir/one.rb"; then
  echo "rendered formula contains an escaped Ruby interpolation" >&2
  exit 1
fi

# Run the formula's test block against the built binary, so that what it
# asserts is what bd-core really prints (brew test only runs after a release).
core_bin=${BD_CORE_BIN:-"$ROOT_DIR/target/release/bd-core"}
if [ -x "$core_bin" ]; then
  cargo_version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT_DIR/Cargo.toml" | head -n 1)
  "$core_bin" --version | grep -qF "bd-core $cargo_version"
  XDG_STATE_HOME="$tmpdir/state" "$core_bin" doctor --json | grep -qF '"events":0'
  test -f "$tmpdir/state/back-directory/bd.sqlite3"
else
  echo "bd-core not built; skipping the formula test block check" >&2
fi
