class BackDirectory < Formula
  desc "Session-scoped directory backtracking with bash and zsh wrappers"
  homepage "https://github.com/masato-umeno/back-directory"
  url "https://github.com/masato-umeno/back-directory/archive/refs/tags/v0.1.2.tar.gz"
  sha256 "152ee3a1b9a4533567f9efe6d40c82f334f2740b08b1c430c9f9a8efbd5f9768"
  license "MIT"
  head "https://github.com/masato-umeno/back-directory.git", branch: "main"

  resource "bd-core-aarch64-apple-darwin" do
    url "https://github.com/masato-umeno/back-directory/releases/download/v0.1.2/bd-core-aarch64-apple-darwin.tar.gz"
    sha256 "e10e9db643145b6d03f78095c2a9f130259dfb0ce64d31aeb87f074bec5dd9ab"
  end

  resource "bd-core-x86_64-apple-darwin" do
    url "https://github.com/masato-umeno/back-directory/releases/download/v0.1.2/bd-core-x86_64-apple-darwin.tar.gz"
    sha256 "f2ec85774e1580ec038bb5063cf209c84076f7c2f2e6e5ddb4afb1fa033590d7"
  end

  resource "bd-core-x86_64-unknown-linux-gnu" do
    url "https://github.com/masato-umeno/back-directory/releases/download/v0.1.2/bd-core-x86_64-unknown-linux-gnu.tar.gz"
    sha256 "87813972c7873bd88c41dafa5acd7918b8ab1b2f39f258f858661555f2a4906c"
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
      `bd` is a shell wrapper. Add one matching line to your shell rc:

        bash: source "#{opt_pkgshare}/bd.bash"
        zsh:  source "#{opt_pkgshare}/bd.zsh"

      Homebrew does not edit shell rc files or delete history in
      ${XDG_STATE_HOME:-$HOME/.local/state}/back-directory.
    EOS
  end

  test do
    assert_match "bd-core #{version}", shell_output("#{bin}/bd-core --version")
    ENV["XDG_STATE_HOME"] = testpath.to_s
    assert_match "\"events\":0", shell_output("#{bin}/bd-core doctor --json")
    assert_path_exists testpath/"back-directory/bd.sqlite3"
  end
end
