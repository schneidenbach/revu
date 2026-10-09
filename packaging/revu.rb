class Revu < Formula
  desc "Local, PR-style review of coding-agent changes across repos and worktrees"
  homepage "https://github.com/schneidenbach/revu"
  url "https://github.com/schneidenbach/revu/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER"
  license "MIT"

  depends_on macos: :sonoma

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    system "scripts/build-app.sh", "--binary", ".build/release/revu", "--out", prefix.to_s

    # Exec the bundle binary directly (not `open`) so stdout and the exit code reach the caller.
    bin.write_exec_script prefix/"Revu.app/Contents/MacOS/revu"
  end

  def caveats
    <<~EOS
      To let Claude Code open reviews, install the skill:
        npx skills@latest add schneidenbach/skills
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/revu --version")
    # Not a git repository: revu reports it and exits 1.
    shell_output("#{bin}/revu #{testpath} 2>&1", 1)
  end
end
