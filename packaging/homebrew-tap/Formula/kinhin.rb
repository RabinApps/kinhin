class Kinhin < Formula
  desc "Autoscaling CI runners on your Mac: Tart VMs, apple/container, or Docker"
  homepage "https://github.com/RabinApps/kinhin"
  license "Apache-2.0"
  version "0.1.0"

  on_arm do
    url "https://github.com/RabinApps/kinhin/releases/download/v#{version}/kinhin-cli-#{version}-arm64.zip"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"

    def install
      bin.install "kinhin"
    end
  end

  def caveats
    <<~EOS
      Tart is required to run VMs:
        brew tap openai/tools
        brew trust --formula openai/tools/tart
        brew install openai/tools/tart

      Getting started:
        kinhin config init
        kinhin auth set
        kinhin doctor
    EOS
  end

  test do
    assert_match "kinhin #{version}", shell_output("#{bin}/kinhin version")
  end
end
