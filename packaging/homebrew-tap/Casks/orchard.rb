cask "orchard" do
  arch arm: "arm64"

  version "0.1.0"
  sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/RabinApps/orchard/releases/download/v#{version}/Orchard-#{version}-#{arch}.dmg"
  name "Orchard"
  desc "Autoscaling GitHub Actions runners on your Mac, powered by Tart"
  homepage "https://github.com/RabinApps/orchard"
  license "Apache-2.0"

  # The app is unsigned; Homebrew will verify the sha256 above instead.
  app "Orchard.app"

  zap trash: [
    "~/Library/Application Support/Orchard",
  ]
end
