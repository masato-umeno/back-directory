#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-targets --all-features
cargo build --release

shellcheck -e SC2016 scripts/*.sh scripts/*.bash examples/bd-demo/demo.sh examples/bd-demo/pv
actionlint .github/workflows/*.yml
scripts/e2e-smoke.sh
scripts/test-homebrew-formula.sh
scripts/test-package-lifecycle.sh
scripts/test-windows-packages.sh
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File scripts/e2e-smoke.ps1
  pwsh -NoProfile -File scripts/e2e-smoke.ps1 -Hook prompt
else
  echo "pwsh not found; skipping the PowerShell wrapper smoke test" >&2
fi
scripts/demo-media.sh check
