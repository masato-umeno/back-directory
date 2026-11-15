#!/bin/sh
set -eu

if [ "$#" -ne 5 ]; then
  echo "usage: $0 VERSION SOURCE_SHA256 DARWIN_ARM64_SHA256 DARWIN_X86_64_SHA256 LINUX_X86_64_SHA256" >&2
  exit 1
fi

version="$1"
source_sha256="$2"
darwin_arm64_sha256="$3"
darwin_x86_64_sha256="$4"
linux_x86_64_sha256="$5"

case "$version" in *[!0-9A-Za-z.-]*|'') echo "invalid version" >&2; exit 1;; esac
for checksum in "$source_sha256" "$darwin_arm64_sha256" "$darwin_x86_64_sha256" "$linux_x86_64_sha256"; do
  case "$checksum" in *[!0-9a-f]*|'') echo "invalid SHA256" >&2; exit 1;; esac
  [ "${#checksum}" -eq 64 ] || { echo "invalid SHA256" >&2; exit 1; }
done

cat <<EOF
class BackDirectory < Formula
  desc "Session-scoped directory backtracking with bash and zsh wrappers"
  homepage "https://github.com/masato-umeno/back-directory"
  url "https://github.com/masato-umeno/back-directory/archive/refs/tags/v${version}.tar.gz"
  sha256 "${source_sha256}"
  license "MIT"
  head "https://github.com/masato-umeno/back-directory.git", branch: "main"

  resource "bd-core-aarch64-apple-darwin" do
    url "https://github.com/masato-umeno/back-directory/releases/download/v${version}/bd-core-aarch64-apple-darwin.tar.gz"
    sha256 "${darwin_arm64_sha256}"
  end

  resource "bd-core-x86_64-apple-darwin" do
    url "https://github.com/masato-umeno/back-directory/releases/download/v${version}/bd-core-x86_64-apple-darwin.tar.gz"
    sha256 "${darwin_x86_64_sha256}"
  end

  resource "bd-core-x86_64-unknown-linux-gnu" do
    url "https://github.com/masato-umeno/back-directory/releases/download/v${version}/bd-core-x86_64-unknown-linux-gnu.tar.gz"
    sha256 "${linux_x86_64_sha256}"
  end

  def install
    target = if OS.mac? && Hardware::CPU.arm?
      "bd-core-aarch64-apple-darwin"
    elsif OS.mac?
      "bd-core-x86_64-apple-darwin"
    elsif OS.linux? && Hardware::CPU.intel?
      "bd-core-x86_64-unknown-linux-gnu"
    else
      odie "back-directory does not provide a prebuilt release for this platform"
    end

    resource(target).stage do
      bin.install "bd-core"
    end
    pkgshare.install "scripts/bd.bash", "scripts/bd.zsh"
  end

  def caveats
    <<~EOS
      \`bd\` is a shell wrapper. Add one matching line to your shell rc:

        bash: source "#{opt_pkgshare}/bd.bash"
        zsh:  source "#{opt_pkgshare}/bd.zsh"

      Homebrew does not edit shell rc files or delete history in
      \${XDG_STATE_HOME:-\$HOME/.local/state}/back-directory.
    EOS
  end

  test do
    assert_match "bd-core #{version}", shell_output("#{bin}/bd-core --version")
    ENV["XDG_STATE_HOME"] = testpath.to_s
    assert_match "\"events\":0", shell_output("#{bin}/bd-core doctor --json")
    assert_path_exists testpath/"back-directory/bd.sqlite3"
  end
end
EOF
