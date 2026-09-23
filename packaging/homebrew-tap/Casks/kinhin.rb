cask "kinhin" do
  arch arm: "arm64"

  version "0.1.0"
  sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/RabinApps/kinhin/releases/download/v#{version}/kinhin-#{version}-#{arch}.dmg"
  name "kinhin"
  desc "Autoscaling CI runners on your Mac: Tart VMs, apple/container, or Docker"
  homepage "https://github.com/RabinApps/kinhin"
  license "Apache-2.0"

  # The app is unsigned; Homebrew will verify the sha256 above instead.
  app "kinhin.app"

  zap trash: [
    "~/Library/Application Support/Kinhin",
  ]
end
