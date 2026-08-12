# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/), [SemVer](https://semver.org/)

## [Unreleased]

### Added
- **localization**: Complete Simplified Chinese, Japanese, German, and Hebrew translations; Hebrew uses a native right-to-left layout with left-to-right handling for paths and other technical text. Added an in-app language selector with one-click restart and catalog coverage tests (#2).

### Changed
- **localization**: Disk-usage percentages (Dashboard, Disk Map) now use locale-aware number formatting instead of a fixed `.` decimal separator, matching the rest of the localized UI.
- **localization**: The App Language picker is now generated from `AppLanguage` itself instead of a hand-duplicated list, so adding a language only touches one place.

### Fixed
- **safety**: The Uninstaller's default-deselect for high-risk related data (VM disks, databases, game libraries, browser profiles) depended on matching English words inside translated description text, so it silently stopped protecting non-English users the moment their category text was translated. It's now driven by an explicit, language-independent flag set per known-app-data entry.
- **safety**: Deletion audit logs, cleanup manifests, and the scan-snapshot JSON now record a stable, language-independent category identifier instead of the on-screen (localized) category name, so support triage (e.g. grepping logs for a category) no longer breaks when the UI language changes.
- **localization**: Corrected several catalog entries that translated brand names as ordinary words (LINE, Telegram, Microsoft Teams) in the German and Simplified Chinese catalogs.
- **localization**: The App Language picker now resyncs to the actually-saved language if persisting a change fails, instead of showing a selection that a restart would not apply.
- Fixed a duplicate, inconsistently-cased "item no longer exists" string in the deletion gate so the administrator-privileged removal path recognizes an already-deleted item the same way the standard path does.
- **docs**: Fixed the documentation site's `<base href>` interacting with root-relative links so the stylesheet and language switcher failed to load on every page.

## [1.4.0] - 2026-07-20

### Added
- **feature**: **Disk Map** — accounts for the complete startup APFS container instead of presenting cleanup candidates as whole-disk usage. It separates the Data volume, user/home/Library folders, macOS support volumes, readable file totals, and a truthful protected/APFS-managed residual; the latest bounded audit is saved to `~/Library/Logs/SparkClean/latest-storage-map.json`.
- **feature**: **Time Machine** sidebar section — lists APFS local snapshots with guarded multi-select deletion via `tmutil` (admin-escalated, injection-guarded). The newest snapshot is kept as a restore point and no speculative reclaim amount is shown.
- **feature**: **Storage Insights** sidebar section — a read-only view of stores that grow silently but usually shouldn't be bulk-deleted (messaging apps, iOS backups, Photos, Mail, iCloud Drive, Downloads, Docker, simulators, and virtual machines). Shows current size, change since the prior measurement, partial-scan state, and a Full-Disk-Access badge when a store is unreadable. Measurement is cancellable and bounded by a deadline/watchdog; incomplete results are never written to history.
- **insights**: Added Developer Projects, installed applications, Chrome profiles, Claude Desktop data, and JetBrains IDE data so the watched-store total explains substantially more of real disk usage instead of focusing only on cleanup candidates.
- **feature**: Full **WhatsApp storage visibility and cleanup** — the cleanup scan now reports the complete local chat-media store as an opt-in Caution category, alongside separate cache and diagnostic-log categories. Clearing media requires explicit selection and confirmation, refuses to run while WhatsApp is open, preserves WhatsApp's databases, and moves attachments to Trash. Storage Insights measures all current WhatsApp app/group containers and links directly to the cleanup category.
- **diagnostics**: The latest cleanup scan is now persisted atomically to `~/Library/Logs/SparkClean/latest-scan.json`, including disk totals, enabled scan settings, categories, paths, sizes, selection state, errors, and partial-scan status. The file is private to the user and replaced on every scan instead of growing without bound.
- **feature**: Optional **menu bar icon** (Settings → General) with Open / Scan Now / Open Trash quick actions.
- **scan**: App/media/cloud cache coverage — WeChat, OneDrive, Dropbox, Steam shader cache, Apple Music artwork (safe), and Podcasts cache (review). Plus a "Shared Container Caches" sweep covering every sandboxed app's Group-Container cache.
- **scan**: Developer-tool cache coverage — new scans for browser-automation binaries (Playwright/Cypress/Puppeteer), uv/pre-commit, compiler caches (ccache/sccache/zig), JS build caches (Turborepo/Nx), IaC & cloud CLI caches (Terraform/Helm/kube/AWS/gcloud), and (review-level, off by default) ML framework caches and Colima/Lima/minikube VM data.
- **scan**: Per-category **Scan** button — each category group can now be rescanned individually without a full scan, preserving every other group's results and selections (#8).
- **scan**: Rust `target/` build-directory scan — finds `target/` dirs next to a `Cargo.toml` (Maven and other coincidental `target/` dirs are excluded), regenerable via `cargo build`. New "Scan Rust target directories" setting (#3 remainder).
- **scan**: Next.js `.next` build artifacts are now discovered only beside a `package.json` and offered as rebuildable cleanup. `node_modules` discovery also follows the narrow `.claude/worktrees` and `.codex/worktrees` locations so agent-created dependency copies are no longer hidden, while unrelated hidden state remains excluded.
- **scan**: Generic Electron cache discovery for direct `Cache`, `Code Cache`, GPU, and Dawn cache directories not already claimed by a dedicated app definition.
- **scan**: Optional old-installer discovery for aged DMG, PKG, MPKG, XIP, installer ZIP, and package files, with installed-app hints and per-item review.
- **localization**: String Catalog groundwork, stable localized group/safety display names, localizable scan-definition text, and a contributor translation workflow.
- **safety/undo**: **Restore Last Cleanup** (⇧⌘Z, File menu) — cleanup, uninstall, duplicate removal, and Trash Monitor operations now record the Trash location of each item they remove, so the latest operation can be reversed. Restores skip items whose original location is re-occupied and tolerate items that have left the Trash.
- **safety**: `FileRemover` — one deletion service now shared by the main clean pipeline, Uninstaller, Duplicate Finder, and Trash Monitor. Every item passes the same `DeletionPolicy` gate, delete-time existence/type/identity/cloud/volume checks, incremental undo recording, and bounded audit logging.
- **safety**: Uninstaller gains a dedicated policy profile that permits removing whole `.app` bundles (never their interior) while keeping every other protection.
- **safety**: `DeletionPolicy` — a single, testable set of rules deciding whether any path may be deleted, extracted from the former inline `isSafePath`. Now also rejects iCloud Drive / cloud-storage mounts (`~/Library/CloudStorage`, `~/Library/Mobile Documents`), the contents of signed `.app`/`.framework` bundles, library document bundles (`.photoslibrary`, `.musiclibrary`, `.fcpbundle`, `.logicx`, `.sparsebundle`, keychains), and launch-service directories (`LaunchDaemons`/`LaunchAgents`/`Extensions`). Home-injectable for testing.
- **safety**: `allowedRoots` deletion territory — each scan category now confines deletion to the subtree(s) it legitimately owns. Every concrete deletion, including children discovered at delete time, must resolve to a path within that territory, so a scan bug or a symlink escaping into a sibling tree can no longer delete outside the category's declared paths.
- **safety**: Delete-time guard skips any item that has become an iCloud/file-provider materialization since it was scanned (prevents corrupting cloud sync state).
- **ci**: `Tests` GitHub Actions workflow running the unit suite on every push/PR to main.
- **tests**: `DeletionPolicyTests` — 23 characterization/expansion/territory tests pinning the exact deletable/undeletable verdicts, including component-boundary matching (`/a/bc` is not within `/a/b`), a regression guard that Ruby's `~/.bundle/cache` stays deletable, and real-symlink escape tests (into a protected dir, and out of a category's territory).
- **tests**: `BrokenSymlinkScanTests` covering broken/valid detection, excluded-dir skipping, cancellation, depth cap, and the iteration watchdog against isolated fixture trees.
- **tests**: Regression coverage for empty deletion territories, delete-time type changes, consumed/retryable undo manifests, strict Time Machine dates/newest selection, bounded Storage Insights measurement, and fixture-based Electron cache discovery.
- **tests**: Replaced the placeholder UI launch test with deterministic dashboard smoke assertions for the main window, title, and Scan action.

### Changed
- **release**: Release builds now enable Hardened Runtime, omit injected debug base entitlements, embed the Apple Events/admin and protected-folder purpose strings in the executable Info.plist, and produce a universal Apple Silicon + Intel binary from the generic macOS destination.
- **safety**: `CleanupManager.isSafePath` delegates to the shared `DeletionPolicy`, and every filesystem deletion surface now uses that policy through `FileRemover`.

### Fixed
- **permissions**: Full Disk Access detection now verifies that a protected directory can actually be enumerated instead of trusting POSIX readability bits, which can report a false positive while macOS privacy controls are still blocking the scan.
- **storage accounting**: Cleanup scans and Storage Insights now collapse complete APFS clones by their filesystem content-stream identifier. Clone-heavy stores such as WhatsApp can no longer add the same shared blocks thousands of times and present a logical file total as guaranteed reclaimable disk space.
- **cleanup**: Broken-symlink scan no longer stalls on "Scanning broken symlinks…" (#9). The walk now checks for cancellation on every iteration (Cancel responds immediately), skips cloud-storage file-provider trees (CloudStorage, Mobile Documents, Photos, and other heavy provider dirs) that could hang enumeration, caps `~/Library` traversal depth, and bails out via an iteration watchdog. Partial results found before an interruption are still surfaced.
- **cleanup**: Zero-byte cleanup items such as broken symbolic links can now reach confirmation and cleanup instead of being disabled by a size-only check.
- **cleanup**: Confirmation and execution now use the same exhaustive path set. Scanner display caps can no longer authorize hidden paths, unreadable sibling roots are excluded, nested definitions omitted from a parent category's measurement are also preserved during deletion (including one-group rescans), group-level Clean stays scoped to that group, and partially successful safe categories are remeasured instead of retaining stale removed entries.
- **cleanup**: Old Downloads no longer duplicates screenshots/installers already owned by another category. A directory is offered only after a complete bounded walk proves every file—including hidden files—is old; unreadable, linked, packaged, cloud-backed, active, or unverifiably large trees are left alone.
- **cleanup**: Narrowed legacy “safe” definitions: system logs and saved app/playground state are now opt-in review; active macOS update staging, raw Simulator devices/runtimes, Deno’s installation, Ruby user gems, broad SwiftPM/Xcode product state, Docker CLI plugins/builder configuration, and Steam partial downloads are no longer cleanup targets. Xcode device support, Conda/Maven/NuGet/Dart stores, Spotify offline cache, and legacy Dropbox cache now require review.
- **privacy**: Recent Items cleanup now targets only recent application/document/host/server lists and preserves unrelated shared-file-list data such as Finder sidebar favorites.
- **cleanup**: Removed the duplicate filesystem Ollama-model category. Models are shown once and removed individually through `ollama rm`, with working per-model checkboxes.
- **cleanup**: Replaced blanket deletion of live temporary-directory contents with an off-by-default review scan limited to non-empty regular files older than seven days directly inside sanctioned temporary roots; directories, links, sockets, cloud items, and recent files are excluded.
- **cleanup**: Results now report bytes and categories actually removed. Blocked, failed, skipped, or partially removed categories remain visible with exact errors instead of disappearing as successfully cleaned.
- **cleanup**: Removed the unconfirmed one-click Ollama deletion path; model removal now goes through selection, the permanent-action confirmation, per-model result handling, and command audit.
- **docker**: Image cleanup now shows and prunes dangling images only, build-cache size uses Docker's reclaimable value, and completed cleanup reports Docker's actual reclaimed bytes instead of the pre-scan estimate.
- **docker**: Removed misleading per-image checkboxes from prune-backed categories; Docker selection now matches the category-level CLI operation.
- **cleanup**: File-valued definitions are no longer silently skipped by `deleteChildrenOnly`, and a Trash root can no longer be treated as a child to trash.
- **cleanup**: Caution categories always use Trash, even when permanent-delete mode is enabled; confirmation copy now accurately separates recoverable and permanent actions.
- **cleanup**: The Trash category now empties selected Trash contents instead of attempting to move those items back into Trash, and is clearly labeled as irreversible.
- **cleanup**: Browser/privacy databases are blocked while their owning application is running, preventing live-database corruption.
- **cleanup**: Confirmation now identifies selected data owned by running apps and offers Quit Apps & Clean, Skip Running Apps, or Cancel; apps that fail to quit within five seconds remain hard-skipped.
- **cleanup**: Administrator moves use a private randomized helper, show the exact path list, revalidate after confirmation, verify every destination, and add successful moves to undo/audit records.
- **cleanup**: Empty deletion territories are denied instead of acting as a wildcard; whole application bundles require an explicit uninstaller profile.
- **cleanup**: Resolved `/private` aliases can no longer bypass system-path protection; symlinked scan roots cannot turn their destinations into authorized territories; direct `/Users/name/item` deletion is denied except for explicitly reviewed shell-history files; and credential/account store descendants are blocked.
- **cleanup**: `/Volumes` paths and items whose device ID is outside the startup/home filesystems are rejected at delete time, including mounts nested under otherwise allowed user folders.
- **cleanup**: Restore Last Cleanup now recognizes dangling symlinks in Trash, so broken-link cleanup remains reversible.
- **cleanup**: Restore manifests now validate trusted Trash/original territories, local-device ancestry, and the recorded device/inode before moving anything back; edited or replaced entries cannot redirect Restore.
- **cleanup**: Dropbox file-provider storage and document/package interiors (including GarageBand projects) are excluded from cleanup.
- **uninstaller**: Protected LaunchAgent files are no longer offered to the generic file remover, and known model/VM/database/game/SDK data defaults to unselected review.
- **uninstaller**: App crash-report matches are removed as individual files; uninstalling one app can no longer remove the entire DiagnosticReports directory.
- **uninstaller**: Confirmation totals now include only selected related locations, and a removed app with failed leftovers is reported as a truthful partial completion instead of a total failure.
- **uninstaller**: The final confirmation now resolves the latest checkbox state instead of an older copied app value, and crash-report matching requires an app-name or bundle-ID boundary to prevent substring collisions.
- **uninstaller**: Heuristic direct-home dot-directory matches were removed, app-name-only cache/log guesses are clearly labeled and off by default, Group Container matches require identifier boundaries, and related items that the shared deletion policy would reject are no longer shown as removable.
- **uninstaller**: The app bundle is now removed and verified before any selected support data; an app permission/authorization failure leaves its preferences and databases untouched.
- **trash-monitor**: Leftover cleanup now has per-item checkboxes; generated cache/log locations start selected while preferences, containers, and Application Support require explicit opt-in. A partial operation retains failed items and offers Retry Remaining instead of presenting them as cleaned.
- **duplicates**: Cross-folder duplicates are detected correctly; size candidates are retained until all roots have been scanned.
- **duplicates**: Package contents (including Photos libraries) are not traversed, hard links do not inflate duplicate counts, inode lookup failures remain eligible, and hashing/image analysis respond to cancellation.
- **duplicates**: iCloud/file-provider files are excluded during discovery as well as at delete time, avoiding uncleanable results and unintended cloud materialization.
- **duplicates**: Candidate grouping now uses logical byte length, hard links use device-plus-inode identity, and the keeper is rehashed/revalidated before every removal.
- **duplicates**: File enumeration has a one-million-entry watchdog and labels cancelled/watchdog results as partial instead of claiming the Mac has no duplicates.
- **duplicates**: Exact hashes and visual similarity are revalidated immediately before removal; partial Trash failures remove successful/missing paths from the displayed group while keeping only truthful retryable results. Similar-image groups preserve the largest file, detect singleton-hash pairs, are never batch-selected, and show an explicit non-identical warning.
- **scan**: Cancelling a per-category refresh restores that group's previous results and selections rather than replacing them with an incomplete scan.
- **scan**: The dashboard now explains that reclaimable scan results are not the same as total disk usage and links to Storage Insights for large app/media stores.
- **time-machine**: Snapshot timestamps now reject impossible calendar dates, the newest snapshot is protected independently of list order, and privileged helper scripts use randomized private paths.
- **time-machine**: Multi-snapshot deletion attempts every requested timestamp, then refreshes to verify and audit partial success instead of treating an all-or-nothing script exit as the result.
- **maintenance**: Removed the duplicate “delete all local snapshots” action; snapshot deletion now lives only in the guarded Time Machine view. APFS defragmentation no longer assumes a fallback disk identifier or promises immediate reclaimed space.
- **maintenance**: Removed the fabricated Spotlight-size estimate, fixed “not enabled” APFS status parsing, and made empty successful DNS output produce a useful result message.
- **maintenance**: Tasks now report command failures instead of unconditional success, and command execution drains stderr with stdout to prevent another pipe-buffer deadlock.
- **startup-items**: Toggle completion now resolves rows by ID after a concurrent rescan, reports launchctl failures, disables in-flight switches, and labels system entries as installed/read-only instead of claiming they are active.
- **updates**: Release metadata now requires a valid stable version and non-empty GitHub-hosted DMG. Downloads reject non-success responses and non-GitHub redirects, validate the UDIF trailer, and stage the complete image beside the destination before atomically replacing an existing file.
- **tests**: Repaired the unit-test target, which did not compile on `main` — a stale `PathStat.id.uuidString` reference (id is now a `String`), plus drifted assertions in `CategoryGroupTests.allCasesExist` (6→9 groups) and `exportReport` (group headers are uppercased).

## [1.3.0] - 2026-04-02

### Added
- **cleanup**: Privacy category with 7 scan definitions — Recent Items, Spotlight History, Shell History, Safari History, Chrome History (multi-profile), Firefox Form History, Browser Cookies
- **cleanup**: Admin privilege escalation for root-owned files in main clean pipeline (macOS password dialog)
- **uninstaller**: Admin privilege escalation for uninstalling root-owned apps (e.g., Microsoft Office)
- **uninstaller**: Show in Finder icon in app detail header
- **uninstaller**: Error alert when uninstall fails
- **app**: Admin escalation for Trash Monitor leftover cleanup
- **ui**: Animated stat counters, disk bar transitions, hover effects, section transitions (P6)
- **maintenance**: Clear Time Machine Snapshots task with admin escalation
- **maintenance**: Free APFS Purgeable Space task with defragmentation
- **maintenance**: Per-task estimate badges (TM snapshots, purgeable space, Spotlight index size)
- **maintenance**: Task selection with checkboxes, "Run Selected" button, and confirmation dialog

### Changed
- **ui**: Removed unused Filter search bar from sidebar
- **cleanup**: `~/Library/Safari` added to protected paths blocklist
- **cleanup**: Static `ISO8601DateFormatter` replacing per-call allocation

### Fixed
- **cleanup**: `directorySizeSync` and `directorySizeSyncExcluding` now handle individual files (was silently returning 0 for non-directory paths like shell history files)
- **cleanup**: `runCommand` pipe deadlock — reads data before `waitUntilExit` to prevent hang when output exceeds 64KB
- **ui**: DuplicateFinderManager strong self capture replaced with `[weak self]` to prevent memory leak during long scans
- **ui**: Disk usage bar visual gap fixed — segments now use clipShape instead of per-segment corner radius
- **ui**: DuplicateFinderManager now supports scan cancellation via `cancelRequested` flag
- **ui**: StartupManager `launchctl` toggle only updates UI if command actually succeeded
- **ui**: StartupManager `NSWorkspace.shared.icon` moved to main thread to prevent potential crash

## [1.2.1] - 2026-04-01

### Added
- **app**: GitHub update checker — check for new versions from Settings > About or Support menu, download DMG to user-chosen location
- **settings**: Optional auto-update check on launch (Settings > General > Startup, off by default)

### Changed
- **ui**: Contact Support and Report a Bug links now open GitHub issues instead of showing email address
- **ui**: Privacy policy updated to reflect optional update check network request

### Fixed
- **ui**: Intro video no longer replays when minimizing and restoring the app window
- **settings**: Update check now shows the latest GitHub version in the result

## [1.2.0] - 2026-04-01

### Added
- **app**: New Maintenance view — system maintenance tasks (flush DNS, purge memory, rebuild indexes, etc.)
- **app**: New Startup Manager — view and manage Launch Agents, System Agents, and Daemons
- **uninstaller**: Smart Trash Monitor — detects apps moved to Trash and offers to clean leftover files (caches, preferences, containers, logs, launch agents)
- **uninstaller**: Drag-and-drop `.app` files onto Uninstaller welcome screen for instant analysis
- **uninstaller**: Per-path selection checkboxes — choose exactly which related data to remove
- **uninstaller**: Launch Agent discovery in related data scanning
- **settings**: "Monitor Trash for uninstalled apps" toggle under Smart Cleanup (off by default)

### Changed
- **uninstaller**: Low-confidence items (App Support, Containers, Group Containers, Home Directory data) default to unselected for safety
- **uninstaller**: Only selected related paths are deleted during uninstall (previously removed all)
- **uninstaller**: `calculateAppSize` made accessible for drag-and-drop analysis

### Fixed
- **uninstaller**: Fixed autoreleasepool leak in dirSizeAndCount (same pattern as the v1.1.0 directorySizeSync fix)
- **uninstaller**: Eliminated duplicated file enumeration code in KnownAppData and dotfile scanning
- **trash-monitor**: Thread safety with OSAllocatedUnfairLock replacing bare Set for knownApps
- **trash-monitor**: Fixed potential retain cycle with `[weak self]` in Task closure

## [1.1.0] - 2026-03-30

### Added
- **cleanup**: Memory pressure monitoring via DispatchSourceMemoryPressure — auto-cancels scans under critical system pressure
- **cleanup**: Protected path blocklist (30+ paths) preventing deletion of critical system/user directories
- **cleanup**: Deletion audit log written to ~/Library/Logs/SparkClean/ on every cleanup
- **cleanup**: Path depth guard rejects any path with fewer than 3 components
- **cleanup**: 10 new scan categories — HuggingFace Models, Ollama Model Cache, LM Studio Models, Bazel Cache, Deno Cache, Poetry Cache, Font Caches, Speech Data Cache, Xcode Playground Cache, Provisioning Profiles
- **uninstaller**: Protected path validation to prevent deletion of system paths

### Changed
- **cleanup**: selectAll() now excludes caution-level categories for safety
- **cleanup**: Other App Caches uses deleteChildrenOnly to preserve cache directories
- **cleanup**: Docker scanning no longer double-counts — removed Docker Desktop Data filesystem scan that overlapped with CLI-based Docker scans
- **cleanup**: Old Downloads checks newest file date inside directories instead of directory modification date
- **cleanup**: Large Files scanner checks if parent directory was already scanned by other phases
- **cleanup**: hasMatchingApp tightened to reduce false positives in orphaned app data detection
- **cleanup**: Trash failure no longer silently falls back to permanent deletion

### Fixed
- **cleanup**: Critical memory leak in directorySizeSync — missing autoreleasepool caused 34GB RAM consumption on large directory scans
- **cleanup**: Critical memory leak in perceptualHash — replaced NSImage+tiffRepresentation (~150MB/image) with CGImageSource thumbnail (~1KB/image)
- **cleanup**: scannedPaths set now cleared after scan completes to release retained strings
- **cleanup**: directorySizeSyncExcluding now calls skipDescendants for excluded paths (performance)
- **cleanup**: XCPGDevices no longer double-counted in both Xcode Previews and Playground Cache
- **cleanup**: DuplicateGroup.wastedSize pre-computed at init instead of filesystem I/O on every SwiftUI render
- **cleanup**: sizeGroups in DuplicateFinderView pruned per-directory to limit peak memory
- **cleanup**: SHA256 buffer increased from 64KB to 256KB for fewer syscalls
- **cleanup**: Static ByteCountFormatter and DateFormatter replacing per-call allocation
- **cleanup**: autoreleasepool added to scanBrokenSymlinks, findNodeModulesRecursive, header comparison
- **ui**: NotificationCenter observer leak fixed in SplashScreenView

## [1.0.0] - 2026-03-14

### Added
- **app**: Rename project from MacSimpleCleanup to SparkClean
- **cleanup**: Disk cleanup scanning and file management
- **uninstaller**: App uninstaller feature
- **settings**: Settings view for user preferences
- **dashboard**: Dashboard components for stats display
- **models**: Data models for cleanup categories and items
- **assets**: Custom app icon set with all required sizes
- **project**: App entitlements and .gitignore configuration
- **ui**: Splash screen intro video on app launch with skip button and settings toggle
- **cleanup**: Ollama model management with per-model deletion via `ollama rm` CLI
- **cleanup**: Large Files category with configurable size, file types, locations, and age filter
- **ui**: Professional clean confirmation sheet with safety breakdown and legal disclaimer
- **ui**: Clean confirmation splits items into "Moved to Trash" and "Permanently Deleted" sections
- **ui**: Partial selection indicator (minus checkbox) for categories with mixed selections
- **uninstaller**: Instant app removal from list with success banner and Open Trash button
- **ui**: Dropdown menus (...) on Uninstaller and Duplicate Finder headers
- **app**: Custom About dialog with system info, build details, GitHub repo link, and Copy Info button
- **app**: Support menu with Help, Contact Support, Report a Bug, GitHub Repository, Privacy Policy, What's New
- **app**: Selection menu with Select All, Deselect All, Select Safe Only shortcuts
- **app**: Scan Now (Cmd+R) and Export Report (Cmd+E) keyboard shortcuts
- **ui**: Onboarding flow for first-time users
- **ui**: What's New view with version-based display
- **ui**: Help sheet with usage guide
- **ui**: Privacy Policy view
- **ui**: Clean progress bar in sidebar
- **ui**: Partial scan banner when scan is cancelled
- **ui**: Smart recommendation banner for Quick Clean
- **ui**: Clean complete dialog with Open Trash and Show Errors buttons
- **cleanup**: Error tracking for clean operations with per-category progress
- **cleanup**: Partial scan results preserved on cancel instead of discarding
- **cleanup**: isDeletableFile check before counting file sizes in scan results
- **cleanup**: 30-second timeout on CLI commands (Docker, Ollama, mdfind) to prevent hangs
- **cleanup**: Dynamic Chrome profile discovery instead of hardcoded Default/Profile 1
- **cleanup**: iOS backup entries now show device name instead of UUID
- **models**: ScanConstants enum with extracted magic numbers
- **models**: ReleaseNote struct for changelog display
- **models**: Stable path-based SwiftUI identifiers replacing random UUIDs
- **models**: displayName property on PathStat for human-readable breakdown entries
- **project**: Info.plist with privacy usage descriptions for folder access
- **project**: LICENSE with non-commercial open source terms
- **project**: SUPPORTED.md with tested devices and compatibility info
- **project**: Privacy manifest declares UserDefaults API usage (CA92.1)
- **dashboard**: Disk usage bar tooltip and accessibility labels
- **ui**: Safety badge tooltips with detailed explanations
- **ui**: Accessibility labels on category rows, badges, stat cards, group cards, sidebar badges, onboarding buttons

### Changed
- **cleanup**: Replace post-clean rescan with instant in-memory state update
- **cleanup**: Docker/Ollama clean now checks return values and reports failures
- **cleanup**: scanLargeFiles returns nil when no files found instead of empty category
- **cleanup**: Ollama model deletion finds entry by name instead of array index (race condition fix)
- **ui**: Sidebar and category rows show selected-only sizes and counts
- **ui**: Category rows read live from manager for reactive updates (Ollama delete, etc.)
- **ui**: Dashboard header restructured with icon+title left, buttons right
- **ui**: All categories visible in sidebar before scan (dimmed with "—")
- **settings**: Large Files settings tab with size, locations, file types, and age filter
- **cleanup**: Thread safety with OSAllocatedUnfairLock for scannedPaths and cancelRequested
- **cleanup**: autoreleasepool in cache scanning loops for memory management
- **cleanup**: Replaced try? with do/catch for proper error collection during clean
- **cleanup**: Fixed node_modules depth check (guard depth < maxDepth)
- **settings**: Enhanced About tab with version, system info, and contact links
- **settings**: Version display shows only version number without build number
- **uninstaller**: Combined dirSize/fileCount into single enumeration pass for performance
- **uninstaller**: NSWorkspace icon fetch moved to main thread for thread safety
- **uninstaller**: filteredApps cached and updated on change instead of recomputing every render
- **uninstaller**: selectedApp cleared on rescan to prevent stale data
- **models**: largeFiles category uses yellow color instead of duplicate orange

### Removed
- **cleanup**: iCloud scan categories (Drive, App Data, Photos Library)
- **cleanup**: Duplicate scan category, replaced by standalone Duplicate Finder tool
- **settings**: iCloud scan toggle removed from settings
- **cleanup**: CryptoKit import from CleanupManager (moved to DuplicateFinderView only)
- **app**: Removed unused isHoveringCopy state variable
- **cleanup**: Removed unused modified variable in scanOllamaModels

### Fixed
- **uninstaller**: Trash-only mode no longer falls back to permanent deletion silently
- **uninstaller**: SparkClean excluded from its own uninstaller list
- **uninstaller**: Fixed inverted trash fallback logic
- **uninstaller**: Added running app termination check before uninstall
- **ui**: Division by zero guard on disk usage and category bars
- **ui**: Export report filename uses yyyy-MM-dd instead of locale date with slashes
- **ui**: Fixed com.microsoft.PowerPoint case in cache path
- **ui**: Fixed estimatedSmartScans count to match actual scan count
- **app**: Fixed Help menu triggering macOS "Help isn't available" system message
- **app**: Fixed version display showing unwanted build number "(1)"
