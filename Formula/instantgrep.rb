class Instantgrep < Formula
  desc "Fast regex search using trigram indexes"
  homepage "https://github.com/GrowlyX/instantgrep"
  version "0.0.2"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/GrowlyX/instantgrep/releases/download/v0.0.2/instantgrep-darwin-arm64.tar.gz"
      sha256 "Not"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/GrowlyX/instantgrep/releases/download/v0.0.2/instantgrep-linux-amd64.tar.gz"
      sha256 "Not"
    end
  end

  depends_on "erlang"

  def install
    bin.install "instantgrep"
    bin.install "instantgrep-bench"
    bin.install_symlink "instantgrep" => "igrep"
    bin.install_symlink "instantgrep" => "ig"
  end

  test do
    assert_match "instantgrep", shell_output("#{bin}/instantgrep --help")
  end
end
