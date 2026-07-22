# Homebrew formula skeleton for Aether (aether-grok).
#
# Local install from this repo:
#   brew install --build-from-source ./packaging/homebrew/aether-grok.rb
#
# Future tap (publish formula to a homebrew-tap repo):
#   brew tap BRONZowl/aether
#   brew install aether-grok
#
# Runtime deps: curl, mbedtls (link), ripgrep (rg on PATH).
# Build: bootstraps Odin via scripts/bootstrap-odin.sh (needs clang/llvm).

class AetherGrok < Formula
  desc "High-performance coding agent (Odin) — peer to xAI Grok Build CLI"
  homepage "https://github.com/BRONZowl/aether-build"
  # Pin to a release tag when cutting stable versions; master is fine for the skeleton.
  url "https://github.com/BRONZowl/aether-build.git", branch: "master"
  version "0.1.0-dev"
  license "Apache-2.0"

  depends_on "curl"
  depends_on "mbedtls"
  depends_on "ripgrep"
  depends_on "llvm" => :build
  depends_on "make" => :build

  def install
    ENV.deparallelize # Odin bootstrap can be sensitive to job storms

    # Bootstrap Odin into .tools (same path as CI / make bootstrap-odin)
    system "bash", "scripts/bootstrap-odin.sh"
    system "make", "build"

    bin.install "out/aether" => "aether-grok"
    bin.install_symlink "aether-grok" => "aether-grok-odin"
    bin.install_symlink "aether-grok" => "grok-odin"

    bash_completion.install "completions/aether.bash" => "aether-grok"

    doc.install "README.md"
    doc.install "LICENSE"
    doc.install "NOTICE" if File.exist?("NOTICE")
  end

  test do
    assert_match(/aether/i, shell_output("#{bin}/aether-grok --version"))
  end

  def caveats
    <<~EOS
      Auth: export XAI_API_KEY=...   (or use ~/.grok/auth.json)
      Primary command: aether-grok   (TUI on a TTY; -p for one-shot)
      Does not install short name `aether` (avoids clashing with unrelated tools).
    EOS
  end
end
