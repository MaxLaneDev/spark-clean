# Supported Devices & OS

## Minimum Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1 or later) or Intel-based Mac

## Tested & Confirmed

| Device | Chip | RAM | macOS Version | Status |
|--------|------|-----|---------------|--------|
| MacBook Pro (Mac16,1) | Apple M4 | 32 GB | macOS 26.3.1 (Tahoe) | Confirmed |

## Expected Compatibility

SparkClean is built with SwiftUI and targets macOS 14.0+. It should work on any Mac that runs macOS Sonoma or later, including:

- MacBook Air (M1, M2, M3, M4)
- MacBook Pro (M1, M2, M3, M4)
- Mac mini (M1, M2, M4)
- Mac Studio (M1 Max/Ultra, M2 Max/Ultra, M4 Max)
- Mac Pro (M2 Ultra, M4 Ultra)
- iMac (M1, M3, M4)
- Intel Macs running macOS 14 Sonoma

## Architecture

- Universal binary (Apple Silicon + Intel x86_64)

## Notes

- Full Disk Access is required for complete scan coverage.
- Docker cleanup features require Docker Desktop to be installed.
- Ollama cleanup features require Ollama to be installed.

## Cleanup Coverage

SparkClean currently covers system and application caches, logs, reviewable stale
files directly inside sanctioned temporary folders, browser caches and opt-in privacy
data, Xcode and developer-tool artifacts, package-manager caches, old downloads and
installers, large files, unused applications, Docker resources, Ollama models, app
leftovers, broken symbolic links, Next.js build output, and Rust/Node/Python project
artifacts (including node_modules inside agent worktrees). Coverage is
filesystem- and installation-dependent, so an empty category does not mean the
related application is unsupported.

Storage Insights separately measures high-value stores such as chat histories, Photos,
Mail, iOS backups, iCloud Drive, simulators, Docker, and virtual machines. The Insights
view remains read-only. WhatsApp is also exposed as explicit cleanup categories:
generated cache, diagnostic logs, and the complete local chat-media store. Chat media
is Caution-level, off by default, blocked while WhatsApp is running, and moved to Trash
only after a separate confirmation.

## Deliberate Safety Exclusions

- SparkClean never cleans `~/Library/CloudStorage` or `~/Library/Mobile Documents`.
- It does not descend into Photos, Music, Final Cut, Logic, GarageBand, sparse-bundle,
  signed application, framework, or other package interiors.
- Mounted volumes and iCloud/file-provider items are rejected again at delete time.
- Broad direct-home targets, protected credential/account stores, and resolved
  `/private` system paths are denied; only explicitly reviewed shell-history files and
  sanctioned temporary-file locations have narrow exceptions.
- Browser/privacy databases are not cleaned while their owning application is running.
- Time Machine data is managed only through `tmutil`; backup folders are never removed
  with filesystem APIs.
- Similar images are suggestions, not exact duplicates. They are excluded from
  Select All and require individual review.
