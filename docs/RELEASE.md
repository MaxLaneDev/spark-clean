# Release, Signing & Distribution (F3)

This documents the steps that require your Apple Developer credentials and Xcode GUI
actions — they can't be scripted headlessly here. Everything else (CI tests, cask
formula) is already in the repo.

## 1. Developer ID signing + notarization (required for distribution & Homebrew)

Prerequisites: Apple Developer Program membership, a **Developer ID Application**
certificate installed in your keychain.

```bash
# Archive a Release build (or use Xcode → Product → Archive).
xcodebuild -project SparkClean.xcodeproj -scheme SparkClean -configuration Release \
  -archivePath build/SparkClean.xcarchive archive

# Export a Developer-ID-signed .app (needs an ExportOptions.plist with
# method = developer-id and your team ID).
xcodebuild -exportArchive -archivePath build/SparkClean.xcarchive \
  -exportPath build/export -exportOptionsPlist ExportOptions.plist

# Build a DMG (e.g. with create-dmg) named SparkClean-<version>.dmg, then notarize:
xcrun notarytool submit build/SparkClean-<version>.dmg \
  --keychain-profile "SparkCleanNotary" --wait
xcrun stapler staple build/SparkClean-<version>.dmg
```

Store the notary credentials once with:
`xcrun notarytool store-credentials "SparkCleanNotary" --apple-id … --team-id … --password …`

Verify the notarized DMG launches on a clean account (quarantine test):
```bash
xattr -w com.apple.quarantine "0081;0;;" build/SparkClean-<version>.dmg
open build/SparkClean-<version>.dmg   # should launch without Gatekeeper blocking
```

## 2. Sparkle auto-updates (needs an Xcode action)

Sparkle must be added as a Swift Package dependency in Xcode (File → Add Package
Dependencies → `https://github.com/sparkle-project/Sparkle`), because editing the
`.xcodeproj` package references by hand risks corrupting the project.

After adding it:
1. Generate an EdDSA key pair (`generate_keys` tool from Sparkle) and add the public
   key to `Info.plist` as `SUPublicEDKey`.
2. Add `SUFeedURL` pointing at `https://github.com/georgekhananaev/spark-clean/releases/latest/download/appcast.xml`.
3. Add a `SPUStandardUpdaterController` and wire the existing "Check for Updates…" menu
   item to it (the app already has an `UpdateChecker` placeholder to replace).
4. Generate `appcast.xml` with Sparkle's `generate_appcast` against the signed DMGs and
   attach it to each GitHub release.

## 3. Homebrew Cask

The cask formula is at `HomebrewFormula/spark-clean.rb`. Per release:
1. Update `version` and set the real `sha256` (`shasum -a 256 SparkClean-<version>.dmg`).
2. Test locally: `brew install --cask ./HomebrewFormula/spark-clean.rb`.
3. Publish via a self-hosted tap (`georgekhananaev/homebrew-tap`) for immediate
   availability, or submit a PR to `Homebrew/homebrew-cask` once the project has enough
   notability (their audit checks stars/forks).

## 4. CI

`.github/workflows/tests.yml` runs the unit suite on every push/PR. `build.yml` builds
Release. A future `sanitizers`/`perf` nightly job is planned (F15).
