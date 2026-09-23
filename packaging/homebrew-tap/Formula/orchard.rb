class Orchard < Formula
  desc "Autoscaling GitHub Actions runners on your Mac, powered by Tart"
  homepage "https://github.com/RabinApps/orchard"
  license "Apache-2.0"
  version "0.1.0"

  on_arm do
    url "https://github.com/RabinApps/orchard/releases/download/v#{version}/orchard-cli-#{version}-arm64.zip"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"

    def install
      bin.install "orchard"
    end
  end

  def caveats
    <<~EOS
      Tart is required to run VMs:
        brew tap openai/tools
        brew trust --formula openai/tools/tart
        brew install openai/tools/tart

      Getting started:
        orchard config init
        orchard auth set
        orchard doctor
    EOS
  end

  test do
    assert_match "orchard #{version}", shell_output("#{bin}/orchard version")
  end
end
