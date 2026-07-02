# Homebrew Cask for SparkClean (F3).
#
# Usage after publishing a signed + notarized DMG to GitHub Releases:
#   brew install --cask georgekhananaev/tap/spark-clean       # self-hosted tap
#
# Update `version` and `sha256` for each release. Compute the sha256 with:
#   shasum -a 256 SparkClean-<version>.dmg
#
# IMPORTANT: the DMG must be Developer-ID signed, notarized, and stapled, or Gatekeeper
# will block launch and the official homebrew-cask tap will reject the formula. See
# docs/RELEASE.md for the signing/notarization steps.
cask "spark-clean" do
  version "1.3.0"
  sha256 :no_check # replace with the real DMG sha256 for each release

  url "https://github.com/georgekhananaev/spark-clean/releases/download/v#{version}/SparkClean-#{version}.dmg"
  name "SparkClean"
  desc "Cleanup utility for caches, developer junk, duplicates, and startup items"
  homepage "https://github.com/georgekhananaev/spark-clean"

  depends_on macos: ">= :sonoma"

  app "SparkClean.app"

  zap trash: [
    "~/Library/Preferences/gk.SparkClean.plist",
    "~/Library/Logs/SparkClean",
    "~/Library/Application Support/SparkClean",
  ]
end
