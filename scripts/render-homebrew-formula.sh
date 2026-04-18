#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 VERSION SOURCE_SHA256" >&2
  exit 1
fi

version="$1"
source_sha256="$2"

cat <<EOF
class BackDirectory < Formula
  desc "Session-scoped directory backtracking with bash and zsh wrappers"
  homepage "https://github.com/01-mu/back-directory"
  url "https://github.com/01-mu/back-directory/archive/refs/tags/v${version}.tar.gz"
  sha256 "${source_sha256}"
  license "MIT"
  head "https://github.com/01-mu/back-directory.git", branch: "main"

  # Bottle checksums are filled in by the tap bottling workflow after release.
  bottle do
    root_url "https://github.com/01-mu/homebrew-back-directory/releases/download/back-directory-${version}"
  end

  depends_on "rust" => :build

  def install
    system "cargo", "install", *std_cargo_args

    pkgshare.install "scripts/bd.bash", "scripts/bd.zsh"
  end

  def caveats
    <<~EOS
      \`bd\` is a shell wrapper, so you need to source the matching script in your shell rc:

        bash: source "\#{opt_pkgshare}/bd.bash"
        zsh:  source "\#{opt_pkgshare}/bd.zsh"

      Then start a new shell or source your rc file.
    EOS
  end

  test do
    assert_match "back-directory uses a local SQLite database", shell_output("\#{bin}/bd-core --help")
  end
end
EOF
