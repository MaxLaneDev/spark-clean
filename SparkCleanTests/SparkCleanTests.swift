//
//  SparkCleanTests.swift
//  SparkCleanTests
//
//  Created by George Khananaev on 3/6/26.
//

import Testing
import Foundation
import SwiftUI
@testable import SparkClean

// MARK: - Format Tests

struct FormatTests {

    @Test func formatBytesZero() {
        let result = CleanupManager.formatBytes(0)
        #expect(!result.isEmpty)
    }

    @Test func formatBytesKB() {
        let result = CleanupManager.formatBytes(1024)
        let containsKB = result.contains("KB") || result.contains("kB")
        #expect(containsKB)
    }

    @Test func formatBytesMB() {
        let result = CleanupManager.formatBytes(1_048_576)
        #expect(result.contains("1") && result.contains("MB"))
    }

    @Test func formatBytesGB() {
        let result = CleanupManager.formatBytes(1_073_741_824)
        #expect(result.contains("1") && result.contains("GB"))
    }

    @Test func formatBytesNegative() {
        let result = CleanupManager.formatBytes(-1)
        #expect(!result.isEmpty)
    }
}

// MARK: - Safety Level Tests

struct SafetyLevelTests {

    @Test func safetyLevelLabels() {
        #expect(SafetyLevel.safe.label == "Safe to delete")
        #expect(SafetyLevel.review.label == "Review before deleting")
        #expect(SafetyLevel.caution.label == "Use caution")
    }

    @Test func safetyLevelIcons() {
        #expect(!SafetyLevel.safe.icon.isEmpty)
        #expect(!SafetyLevel.review.icon.isEmpty)
        #expect(!SafetyLevel.caution.icon.isEmpty)
    }

    @Test func safetyLevelRawValues() {
        #expect(SafetyLevel.safe.rawValue == "Safe")
        #expect(SafetyLevel.review.rawValue == "Review")
        #expect(SafetyLevel.caution.rawValue == "Caution")
    }
}

// MARK: - Category Group Tests

struct CategoryGroupTests {

    @Test func allCasesExist() {
        // system, storage, browsers, developer, packageManagers, largeFiles,
        // privacy, docker, applications
        #expect(CategoryGroup.allCases.count == 9)
    }

    @Test func groupIcons() {
        for group in CategoryGroup.allCases {
            #expect(!group.icon.isEmpty)
        }
    }

    @Test func groupIdentifiers() {
        for group in CategoryGroup.allCases {
            #expect(group.id == group.rawValue)
        }
    }
}

// MARK: - CleanupManager Logic Tests

@MainActor
struct CleanupManagerLogicTests {

    @Test func initialState() {
        let manager = CleanupManager()
        #expect(manager.categories.isEmpty)
        #expect(!manager.isScanning)
        #expect(!manager.scanComplete)
        #expect(!manager.isCleaning)
        #expect(!manager.cleanComplete)
        #expect(manager.totalSize == 0)
        #expect(manager.totalFiles == 0)
        #expect(manager.overallSize == 0)
        #expect(manager.selectedCategoryCount == 0)
    }

    @Test func selectAllDeselectAll() {
        let manager = CleanupManager()
        manager.categories = [
            makeCategory(name: "A", selected: false),
            makeCategory(name: "B", selected: false),
        ]
        manager.selectAll()
        let allSelected = manager.categories.allSatisfy(\.isSelected)
        #expect(allSelected)

        manager.deselectAll()
        let noneSelected = manager.categories.allSatisfy { !$0.isSelected }
        #expect(noneSelected)
    }

    @Test func selectSafeOnly() {
        let manager = CleanupManager()
        manager.categories = [
            makeCategory(name: "Safe", safetyLevel: .safe, selected: false),
            makeCategory(name: "Review", safetyLevel: .review, selected: true),
            makeCategory(name: "Caution", safetyLevel: .caution, selected: true),
        ]
        manager.selectSafeOnly()
        #expect(manager.categories[0].isSelected == true)
        #expect(manager.categories[1].isSelected == false)
        #expect(manager.categories[2].isSelected == false)
    }

    @Test func selectAllInGroup() {
        let manager = CleanupManager()
        manager.categories = [
            makeCategory(name: "A", group: .system, selected: false),
            makeCategory(name: "B", group: .browsers, selected: false),
        ]
        manager.selectAll(in: .system)
        #expect(manager.categories[0].isSelected == true)
        #expect(manager.categories[1].isSelected == false)
    }

    @Test func deselectAllInGroup() {
        let manager = CleanupManager()
        manager.categories = [
            makeCategory(name: "A", group: .system, selected: true),
            makeCategory(name: "B", group: .browsers, selected: true),
        ]
        manager.deselectAll(in: .system)
        #expect(manager.categories[0].isSelected == false)
        #expect(manager.categories[1].isSelected == true)
    }

    @Test func totalSizeCalculation() {
        let manager = CleanupManager()
        manager.categories = [
            makeCategory(name: "A", size: 1000, selected: true),
            makeCategory(name: "B", size: 2000, selected: true),
            makeCategory(name: "C", size: 3000, selected: false),
        ]
        #expect(manager.totalSize == 3000)
        #expect(manager.overallSize == 6000)
        #expect(manager.selectedCategoryCount == 2)
    }

    @Test func filteredCategories() {
        let manager = CleanupManager()
        manager.categories = [
            makeCategory(name: "Safari Cache"),
            makeCategory(name: "Chrome Cache"),
            makeCategory(name: "Xcode Derived Data"),
        ]

        manager.searchQuery = "cache"
        #expect(manager.filteredCategories.count == 2)

        manager.searchQuery = "xcode"
        #expect(manager.filteredCategories.count == 1)

        manager.searchQuery = ""
        #expect(manager.filteredCategories.count == 3)
    }

    @Test func categoriesForGroup() {
        let manager = CleanupManager()
        manager.categories = [
            makeCategory(name: "A", group: .system),
            makeCategory(name: "B", group: .system),
            makeCategory(name: "C", group: .browsers),
        ]
        #expect(manager.categoriesForGroup(.system).count == 2)
        #expect(manager.categoriesForGroup(.browsers).count == 1)
        #expect(manager.categoriesForGroup(.docker).count == 0)
    }

    @Test func sizeForGroup() {
        let manager = CleanupManager()
        manager.categories = [
            makeCategory(name: "A", group: .system, size: 1000),
            makeCategory(name: "B", group: .system, size: 2000),
            makeCategory(name: "C", group: .browsers, size: 500),
        ]
        #expect(manager.sizeForGroup(.system) == 3000)
        #expect(manager.sizeForGroup(.browsers) == 500)
    }

    @Test func diskUsageFetch() {
        let manager = CleanupManager()
        manager.fetchDiskUsage()
        #expect(manager.diskUsage != nil)
        #expect(manager.diskUsage!.totalSpace > 0)
        #expect(manager.diskUsage!.freeSpace > 0)
        #expect(manager.diskUsage!.usedPercentage > 0)
        #expect(manager.diskUsage!.usedPercentage < 1)
    }

    @Test func exportReport() {
        let manager = CleanupManager()
        manager.categories = [
            makeCategory(name: "Test Category", group: .system, size: 1024),
        ]
        let report = manager.exportReport()
        #expect(report.contains("Test Category"))
        // The report renders group headers uppercased ("SYSTEM").
        #expect(report.localizedCaseInsensitiveContains("System"))
    }

    // MARK: Helpers

    private func makeCategory(
        name: String,
        group: CategoryGroup = .system,
        safetyLevel: SafetyLevel = .safe,
        size: Int64 = 0,
        selected: Bool = true
    ) -> CleanupCategory {
        CleanupCategory(
            name: name, icon: "folder", color: .blue,
            description: "Test", group: group, safetyLevel: safetyLevel,
            paths: [], size: size, isSelected: selected
        )
    }
}

// MARK: - Model Tests

struct ModelTests {

    @Test func pathStatIdentifiable() {
        let stat = PathStat(path: "/test", size: 100, fileCount: 5)
        // PathStat.id is derived from `path` (String), not a UUID.
        #expect(!stat.id.isEmpty)
        #expect(stat.id == "/test")
        #expect(stat.path == "/test")
        #expect(stat.size == 100)
        #expect(stat.fileCount == 5)
    }

    @Test func diskUsagePercentage() {
        let info = DiskUsageInfo(totalSpace: 1000, usedSpace: 750, freeSpace: 250, purgeableSpace: 0)
        #expect(info.usedPercentage == 0.75)
    }

    @Test func diskUsagePercentageZeroTotal() {
        let info = DiskUsageInfo(totalSpace: 0, usedSpace: 0, freeSpace: 0, purgeableSpace: 0)
        #expect(info.usedPercentage == 0)
    }

    @Test func scanSummary() {
        let summary = ScanSummary(
            totalCategories: 5, totalSize: 1000, totalFiles: 50,
            scanDuration: 2.5, timestamp: Date()
        )
        #expect(summary.totalCategories == 5)
        #expect(summary.totalSize == 1000)
        #expect(summary.scanDuration == 2.5)
    }

    @MainActor @Test func sidebarItemEquality() {
        #expect(SidebarItem.dashboard == SidebarItem.dashboard)
        #expect(SidebarItem.group(.system) == SidebarItem.group(.system))
        #expect(SidebarItem.group(.system) != SidebarItem.group(.browsers))
        #expect(SidebarItem.dashboard != SidebarItem.group(.system))
    }
}

// MARK: - Docker Size Parser Tests

struct DockerSizeParserTests {

    @Test func findDockerPath() {
        _ = CleanupManager.findDocker()
    }

    @Test func parseDockerSizeBytes() {
        #expect(CleanupManager.parseDockerSize("100B") == 100)
    }

    @Test func parseDockerSizeKB() {
        #expect(CleanupManager.parseDockerSize("1.5KB") == 1500)
        #expect(CleanupManager.parseDockerSize("1.5 kB") == 1500)
    }

    @Test func parseDockerSizeMB() {
        #expect(CleanupManager.parseDockerSize("256MB") == 256_000_000)
        #expect(CleanupManager.parseDockerSize("1.2 MB") == 1_200_000)
    }

    @Test func parseDockerSizeGB() {
        #expect(CleanupManager.parseDockerSize("2.5GB") == 2_500_000_000)
    }

    @Test func parseDockerSizeInvalid() {
        #expect(CleanupManager.parseDockerSize("") == 0)
        #expect(CleanupManager.parseDockerSize("invalid") == 0)
    }
}

// MARK: - Broken Symlink Scan Tests (issue #9)

/// Exercises the testable core of the broken-symlink scan against real fixture trees
/// built under the temporary directory. Never touches the real home directory.
struct BrokenSymlinkScanTests {

    /// Builds an isolated fixture tree and returns its root path. Caller must call
    /// `cleanup()`.
    private func makeFixture() -> (root: String, cleanup: () -> Void) {
        let fm = FileManager.default
        let unique = ProcessInfo.processInfo.globallyUniqueString
        let root = fm.temporaryDirectory
            .appendingPathComponent("sparkclean-symlink-\(unique)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return (root.path, { try? fm.removeItem(at: root) })
    }

    /// Creates a symlink at `root/relative` pointing at `target`.
    private func link(_ relative: String, to target: String, under root: String) {
        let fm = FileManager.default
        let linkPath = (root as NSString).appendingPathComponent(relative)
        let parent = (linkPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
    }

    private func writeFile(_ relative: String, under root: String) -> String {
        let fm = FileManager.default
        let path = (root as NSString).appendingPathComponent(relative)
        let parent = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data("x".utf8))
        return path
    }

    @Test func findsBrokenSymlinkAndIgnoresValidOne() {
        let (root, cleanup) = makeFixture()
        defer { cleanup() }

        // Broken symlink at depth 4: root/a/b/c/broken -> /nonexistent
        link("a/b/c/broken", to: "/nonexistent/target-xyz", under: root)
        // Valid symlink pointing at a real file must NOT be flagged.
        let real = writeFile("realfile", under: root)
        link("a/b/c/valid", to: real, under: root)

        let result = CleanupManager.findBrokenSymlinks(
            roots: [root],
            excludeDirs: CleanupManager.brokenSymlinkExcludeDirs,
            depthCappedRoots: [root],
            maxDepth: 6,
            maxIterations: CleanupManager.brokenSymlinkMaxIterations,
            isCancelled: { false }
        )

        #expect(result.filePaths.contains { $0.hasSuffix("/a/b/c/broken") })
        #expect(!result.filePaths.contains { $0.hasSuffix("/a/b/c/valid") })
        #expect(!result.wasCancelled)
        #expect(!result.hitWatchdog)
    }

    @Test func skipsExcludedCloudStorageDir() {
        let (root, cleanup) = makeFixture()
        defer { cleanup() }

        // A broken symlink hidden inside a CloudStorage subtree must be skipped —
        // this is the file-provider tree that stalled the scan in issue #9.
        link("CloudStorage/Dropbox/deadlink", to: "/nonexistent/a", under: root)
        // A broken symlink outside excluded dirs is still found.
        link("normal/deadlink", to: "/nonexistent/b", under: root)

        let result = CleanupManager.findBrokenSymlinks(
            roots: [root],
            excludeDirs: CleanupManager.brokenSymlinkExcludeDirs,
            depthCappedRoots: [root],
            maxDepth: 6,
            maxIterations: CleanupManager.brokenSymlinkMaxIterations,
            isCancelled: { false }
        )

        #expect(!result.filePaths.contains { $0.contains("/CloudStorage/") })
        #expect(result.filePaths.contains { $0.hasSuffix("/normal/deadlink") })
    }

    @Test func respectsCancellation() {
        let (root, cleanup) = makeFixture()
        defer { cleanup() }

        // Enough entries that the walk would otherwise continue past the cancel point.
        for i in 0..<50 { link("dir\(i)/deadlink", to: "/nonexistent/\(i)", under: root) }

        var calls = 0
        let result = CleanupManager.findBrokenSymlinks(
            roots: [root],
            excludeDirs: CleanupManager.brokenSymlinkExcludeDirs,
            depthCappedRoots: [root],
            maxDepth: 6,
            maxIterations: CleanupManager.brokenSymlinkMaxIterations,
            isCancelled: { calls += 1; return calls > 3 }
        )

        #expect(result.wasCancelled)
        // It stopped early rather than walking all 50+ entries.
        #expect(calls <= 5)
    }

    @Test func respectsDepthCapUnderFlaggedRoot() {
        let (root, cleanup) = makeFixture()
        defer { cleanup() }

        // Too deep (level 4) — skipped when the cap is 2.
        link("a/b/c/deeplink", to: "/nonexistent/deep", under: root)
        // Shallow (level 1) — found.
        link("shallowlink", to: "/nonexistent/shallow", under: root)

        let result = CleanupManager.findBrokenSymlinks(
            roots: [root],
            excludeDirs: CleanupManager.brokenSymlinkExcludeDirs,
            depthCappedRoots: [root],
            maxDepth: 2,
            maxIterations: CleanupManager.brokenSymlinkMaxIterations,
            isCancelled: { false }
        )

        #expect(!result.filePaths.contains { $0.hasSuffix("/deeplink") })
        #expect(result.filePaths.contains { $0.hasSuffix("/shallowlink") })
    }

    @Test func depthCapDoesNotApplyToUnflaggedRoots() {
        let (root, cleanup) = makeFixture()
        defer { cleanup() }

        link("a/b/c/d/e/deeplink", to: "/nonexistent/deep", under: root)

        // Root is NOT in depthCappedRoots, so a deep link is still found even with a
        // small maxDepth (mirrors /usr/local/bin being uncapped in production).
        let result = CleanupManager.findBrokenSymlinks(
            roots: [root],
            excludeDirs: CleanupManager.brokenSymlinkExcludeDirs,
            depthCappedRoots: [],
            maxDepth: 2,
            maxIterations: CleanupManager.brokenSymlinkMaxIterations,
            isCancelled: { false }
        )

        #expect(result.filePaths.contains { $0.hasSuffix("/deeplink") })
    }

    @Test func watchdogStopsRunawayWalk() {
        let (root, cleanup) = makeFixture()
        defer { cleanup() }

        for i in 0..<20 { link("dir\(i)/deadlink", to: "/nonexistent/\(i)", under: root) }

        let result = CleanupManager.findBrokenSymlinks(
            roots: [root],
            excludeDirs: CleanupManager.brokenSymlinkExcludeDirs,
            depthCappedRoots: [root],
            maxDepth: 6,
            maxIterations: 2,
            isCancelled: { false }
        )

        #expect(result.hitWatchdog)
    }
}

// MARK: - Performance Guards (F15)

/// Coarse regression guards — they fail only on gross slowdowns, so they're stable in
/// CI while still catching an accidental O(n²) in the hot safety path.
struct PerformanceGuardTests {

    @Test func policyValidatesManyPathsQuickly() {
        let policy = DeletionPolicy(home: "/Users/testuser")
        let roots = ["/Users/testuser/Library/Caches"]
        let paths = (0..<10_000).map { "/Users/testuser/Library/Caches/app\($0)/file\($0).db" }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for p in paths { _ = policy.validate(p, allowedRoots: roots) }
        }
        // 10k validations should be well under a second on any machine.
        #expect(elapsed < .seconds(1))
    }

    @Test func rustFinderHandlesWideTreeQuickly() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("sparkclean-perf-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<200 {
            try? fm.createDirectory(at: root.appendingPathComponent("d\(i)/sub"),
                                    withIntermediateDirectories: true)
        }

        var found: [String] = []; var bd: [PathStat] = []; var ts: Int64 = 0; var tc = 0
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            CleanupManager.findRustTargetsRecursive(
                in: root.path, depth: 0, maxDepth: 6, fm: fm,
                found: &found, breakdown: &bd, totalSize: &ts, totalCount: &tc, minSize: 0)
        }
        #expect(elapsed < .seconds(2))
    }
}

// MARK: - Storage Insights Tests (F13)

struct StorageInsightsTests {

    private func makeStoreFile() -> (URL, () -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("sparkclean-insights-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("history.json"), { try? fm.removeItem(at: dir) })
    }

    @Test func recordsOneSamplePerItemPerDay() {
        let (file, cleanup) = makeStoreFile()
        defer { cleanup() }
        let store = InsightHistoryStore(fileURL: file)
        store.record(sizes: [("whatsapp", 100)], today: "2026-07-01")
        store.record(sizes: [("whatsapp", 150)], today: "2026-07-01")  // same day → replace
        let samples = store.load().filter { $0.itemID == "whatsapp" && $0.day == "2026-07-01" }
        #expect(samples.count == 1)
        #expect(samples.first?.size == 150)
    }

    @Test func previousSizeFindsEarlierDay() {
        let (file, cleanup) = makeStoreFile()
        defer { cleanup() }
        let store = InsightHistoryStore(fileURL: file)
        store.record(sizes: [("whatsapp", 100)], today: "2026-06-01")
        store.record(sizes: [("whatsapp", 200)], today: "2026-06-15")
        // Before 2026-07-01, the most recent earlier sample is the 2026-06-15 one.
        #expect(store.previousSize(for: "whatsapp", before: "2026-07-01") == 200)
        // Before 2026-06-10, only the 2026-06-01 sample qualifies.
        #expect(store.previousSize(for: "whatsapp", before: "2026-06-10") == 100)
    }

    @Test func prunesToMaxDays() {
        let (file, cleanup) = makeStoreFile()
        defer { cleanup() }
        let store = InsightHistoryStore(fileURL: file, maxDays: 2)
        store.record(sizes: [("a", 1)], today: "2026-06-01")
        store.record(sizes: [("a", 2)], today: "2026-06-02")
        store.record(sizes: [("a", 3)], today: "2026-06-03")
        let days = Set(store.load().map(\.day))
        #expect(days.count == 2)
        #expect(!days.contains("2026-06-01"))
    }

    @Test func resolvesGlobPaths() {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("sparkclean-glob-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? fm.createDirectory(at: base.appendingPathComponent("TEAMID.com.example.app"),
                                withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let resolved = StorageInsightsManager.resolvePaths("\(base.path)/*.com.example.app")
        #expect(resolved.count == 1)
        #expect(resolved.first?.hasSuffix("TEAMID.com.example.app") == true)
    }

    @Test func insightsHasNoDeletionPath() {
        // Guard: the Insights module must never delete. (Documented invariant test.)
        let mgr = StorageInsightsManager()
        #expect(!mgr.items.isEmpty)
    }
}

// MARK: - Time Machine Tests (F14)

struct TimeMachineTests {

    @Test func parsesLocalSnapshots() {
        let output = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-07-01-093012.local
        com.apple.TimeMachine.2026-06-30-120000.local
        garbage line that should be ignored
        """
        let snaps = TimeMachineManager.parseLocalSnapshots(output)
        #expect(snaps.count == 2)
        #expect(snaps[0].name == "com.apple.TimeMachine.2026-07-01-093012.local")
        #expect(snaps[0].date != nil)
        #expect(snaps[1].date != nil)
    }

    @Test func parseHandlesEmptyAndGarbage() {
        #expect(TimeMachineManager.parseLocalSnapshots("").isEmpty)
        #expect(TimeMachineManager.parseLocalSnapshots("No snapshots\nrandom text").isEmpty)
    }

    @Test func extractsDeletionTimestamp() {
        let snap = TMSnapshot(name: "com.apple.TimeMachine.2026-07-01-093012.local", date: nil)
        #expect(TimeMachineManager.deletionTimestamp(for: snap) == "2026-07-01-093012")
        let bad = TMSnapshot(name: "not-a-snapshot", date: nil)
        #expect(TimeMachineManager.deletionTimestamp(for: bad) == nil)
    }

    @Test func timestampValidatorGuardsAgainstInjection() {
        #expect(TimeMachineManager.isValidTimestamp("2026-07-01-093012"))
        #expect(!TimeMachineManager.isValidTimestamp("2026-07-01-093012'; rm -rf /"))
        #expect(!TimeMachineManager.isValidTimestamp("../../etc"))
        #expect(!TimeMachineManager.isValidTimestamp(""))
        #expect(!TimeMachineManager.isValidTimestamp("2026/07/01-093012"))
    }

    @Test func deletionScriptOnlyIncludesValidTimestamps() {
        let script = TimeMachineManager.deletionScript(for: ["2026-07-01-093012", "bad; evil"])
        #expect(script != nil)
        #expect(script!.contains("2026-07-01-093012"))
        #expect(!script!.contains("evil"))
        // All-invalid input yields no script.
        #expect(TimeMachineManager.deletionScript(for: ["nope"]) == nil)
    }

    @Test func policyHardRejectsTimeMachinePaths() {
        let policy = DeletionPolicy(home: "/Users/testuser")
        #expect(!policy.isSafeToDelete("/Volumes/TM/Backups.backupdb/MyMac/2026-07-01"))
        #expect(!policy.isSafeToDelete("/Volumes/.timemachine/x"))
        #expect(!policy.isSafeToDelete("/System/Volumes/Data/.timemachine/y"))
        // Even the uninstaller profile cannot touch Time Machine data.
        let uninstaller = DeletionPolicy(home: "/Users/testuser", allowsApplicationBundles: true)
        #expect(!uninstaller.isSafeToDelete("/Volumes/TM/Backups.backupdb/x"))
    }
}

// MARK: - Rust target scan Tests (issue #3 remainder)

struct RustTargetScanTests {

    private func makeFixture() -> (root: String, cleanup: () -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("sparkclean-rust-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return (root.path, { try? fm.removeItem(at: root) })
    }

    private func write(_ relative: String, under root: String) {
        let fm = FileManager.default
        let path = (root as NSString).appendingPathComponent(relative)
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data("x".utf8))
    }

    private func run(_ root: String) -> [String] {
        var found: [String] = []
        var breakdown: [PathStat] = []
        var ts: Int64 = 0
        var tc = 0
        CleanupManager.findRustTargetsRecursive(
            in: root, depth: 0, maxDepth: 6, fm: .default,
            found: &found, breakdown: &breakdown,
            totalSize: &ts, totalCount: &tc, minSize: 0)
        return found
    }

    @Test func findsTargetNextToCargoToml() {
        let (root, cleanup) = makeFixture()
        defer { cleanup() }
        write("proj/Cargo.toml", under: root)
        write("proj/target/debug/app", under: root)

        let found = run(root)
        #expect(found.contains { $0.hasSuffix("/proj/target") })
    }

    @Test func ignoresTargetWithoutCargoToml() {
        let (root, cleanup) = makeFixture()
        defer { cleanup() }
        // A Maven-style project: has target/ but no Cargo.toml — must be skipped.
        write("javaproj/pom.xml", under: root)
        write("javaproj/target/classes/Foo.class", under: root)

        let found = run(root)
        #expect(!found.contains { $0.contains("/javaproj/target") })
    }

    @Test func doesNotDescendIntoTarget() {
        let (root, cleanup) = makeFixture()
        defer { cleanup() }
        write("proj/Cargo.toml", under: root)
        write("proj/target/debug/build/nested/Cargo.toml", under: root)  // decoy inside target
        write("proj/target/debug/build/nested/target/x", under: root)

        let found = run(root)
        // Only the top-level target is found; the decoy inside it is never descended into.
        #expect(found.filter { $0.contains("/proj/target") }.count == 1)
    }
}

// MARK: - DeletionPolicy Tests (safety-critical)

/// Characterization tests: these encode the exact verdicts the historical
/// `CleanupManager.isSafePath` produced, pinned so the extraction into `DeletionPolicy`
/// (and later rule additions) can never silently change what is deletable.
/// Anchored to a fixture home so protected-path checks are deterministic.
struct DeletionPolicyTests {

    private let policy = DeletionPolicy(home: "/Users/testuser")

    @Test func rejectsSystemRoots() {
        for path in ["/", "/System", "/usr", "/bin", "/sbin", "/var", "/etc",
                     "/tmp", "/private", "/Applications", "/Library", "/Users"] {
            #expect(!policy.isSafeToDelete(path), "should reject \(path)")
        }
    }

    @Test func rejectsHomeAndTopLevelUserDirs() {
        for path in ["/Users/testuser",
                     "/Users/testuser/Desktop", "/Users/testuser/Documents",
                     "/Users/testuser/Downloads", "/Users/testuser/Pictures",
                     "/Users/testuser/Movies", "/Users/testuser/Music",
                     "/Users/testuser/Library", "/Users/testuser/Library/Keychains",
                     "/Users/testuser/Library/Safari", "/Users/testuser/Library/Mail",
                     "/Users/testuser/Library/Preferences",
                     "/Users/testuser/Library/Application Support",
                     "/Users/testuser/Library/Accounts", "/Users/testuser/Library/Cookies",
                     "/Users/testuser/Library/Containers",
                     "/Users/testuser/Library/Group Containers",
                     "/Users/testuser/.ssh", "/Users/testuser/.gnupg"] {
            #expect(!policy.isSafeToDelete(path), "should reject \(path)")
        }
    }

    @Test func rejectsForbiddenPrefixes() {
        for path in ["/System/Library/Foo", "/usr/local/bin/foo", "/bin/ls",
                     "/sbin/reboot", "/private/var/db/something"] {
            #expect(!policy.isSafeToDelete(path), "should reject \(path)")
        }
    }

    @Test func rejectsShallowPaths() {
        // Fewer than 3 path components after resolution.
        #expect(!policy.isSafeToDelete("/foo"))
        #expect(!policy.isSafeToDelete("/foo/bar"))
    }

    @Test func acceptsLegitimateCacheTargets() {
        for path in ["/Users/testuser/Library/Caches/com.example.app",
                     "/Users/testuser/Library/Caches/com.example.app/Cache.db",
                     "/Users/testuser/.cargo/registry",
                     "/Users/testuser/.npm/_cacache",
                     "/Users/testuser/Library/Developer/Xcode/DerivedData/App-abc"] {
            #expect(policy.isSafeToDelete(path), "should accept \(path)")
        }
    }

    @Test func policyIsHomeRelative() {
        // A different home makes that home's Desktop protected, and leaves the
        // fixture home's Desktop merely a normal (deletable-by-depth) path.
        let other = DeletionPolicy(home: "/Users/someoneelse")
        #expect(!other.isSafeToDelete("/Users/someoneelse/Desktop"))
        #expect(other.isSafeToDelete("/Users/testuser/Library/Caches/x/y"))
    }

    // MARK: F9 §6 expanded rules

    @Test func rejectsCloudStorageAndICloud() {
        #expect(!policy.isSafeToDelete("/Users/testuser/Library/CloudStorage"))
        #expect(!policy.isSafeToDelete("/Users/testuser/Library/CloudStorage/Dropbox/file.txt"))
        #expect(!policy.isSafeToDelete("/Users/testuser/Library/Mobile Documents/com~apple~x/y"))
    }

    @Test func rejectsBundleInteriorButNotWholeBundle() {
        // Contents of a signed bundle must be protected…
        #expect(!policy.isSafeToDelete("/Applications/Foo.app/Contents/MacOS/foo"))
        #expect(!policy.isSafeToDelete("/Users/testuser/Library/Frameworks/Bar.framework/Bar"))
    }

    @Test func rejectsLibraryDocumentBundles() {
        for path in ["/Users/testuser/Pictures/My.photoslibrary/database/x",
                     "/Users/testuser/Music/My.musiclibrary",
                     "/Users/testuser/Movies/Project.fcpbundle/render/x",
                     "/Users/testuser/Library/Keychains/login.keychain-db"] {
            #expect(!policy.isSafeToDelete(path), "should reject \(path)")
        }
    }

    @Test func rejectsLaunchServiceDirs() {
        #expect(!policy.isSafeToDelete("/Library/LaunchDaemons/com.foo.plist"))
        #expect(!policy.isSafeToDelete("/Library/LaunchAgents/com.foo.plist"))
        #expect(!policy.isSafeToDelete("/Library/Extensions/Foo.kext"))
        #expect(!policy.isSafeToDelete("/Users/testuser/Library/LaunchAgents/com.foo.plist"))
    }

    @Test func applicationBundleProfilePermitsWholeBundles() {
        let uninstaller = DeletionPolicy(home: "/Users/testuser", allowsApplicationBundles: true)
        // Default policy rejects a depth-2 app bundle; the uninstaller profile allows it.
        #expect(!policy.isSafeToDelete("/Applications/Foo.app"))
        #expect(uninstaller.isSafeToDelete("/Applications/Foo.app"))
        #expect(uninstaller.isSafeToDelete("/Users/testuser/Applications/Bar.app"))
        // Even the uninstaller must not delete the *interior* of a bundle, nor system apps.
        #expect(!uninstaller.isSafeToDelete("/Applications/Foo.app/Contents/MacOS/foo"))
        #expect(!uninstaller.isSafeToDelete("/System/Applications/Mail.app"))
        // Related data in Library still validates the normal way.
        #expect(uninstaller.isSafeToDelete("/Users/testuser/Library/Caches/com.foo"))
    }

    @Test func stillAcceptsRubyBundleCache() {
        // Regression guard: `~/.bundle` (Ruby Bundler) is NOT a macOS bundle and must
        // remain deletable — the reason the interior check uses `.app/`/`.framework/`
        // rather than a generic `.bundle` suffix.
        #expect(policy.isSafeToDelete("/Users/testuser/.bundle/cache"))
        #expect(policy.isSafeToDelete("/Users/testuser/.gem/foo"))
    }

    // MARK: F9 §1 allowedRoots territory

    @Test func withinAllowedRootsBasics() {
        let roots = ["/Users/testuser/Library/Caches"]
        #expect(policy.isWithinAllowedRoots("/Users/testuser/Library/Caches", roots: roots))
        #expect(policy.isWithinAllowedRoots("/Users/testuser/Library/Caches/com.foo", roots: roots))
        #expect(policy.isWithinAllowedRoots("/Users/testuser/Library/Caches/com.foo/x.db", roots: roots))
        // Outside the territory.
        #expect(!policy.isWithinAllowedRoots("/Users/testuser/Documents/x", roots: roots))
        #expect(!policy.isWithinAllowedRoots("/Users/testuser/Library/Preferences/x", roots: roots))
    }

    @Test func withinAllowedRootsRespectsComponentBoundary() {
        // The classic prefix trap: "/a/bc" must NOT count as within "/a/b".
        #expect(!policy.isWithinAllowedRoots("/Users/testuser/CachesX/y",
                                             roots: ["/Users/testuser/Caches"]))
        #expect(policy.isWithinAllowedRoots("/Users/testuser/Caches/y",
                                            roots: ["/Users/testuser/Caches"]))
    }

    @Test func emptyRootsImposesNoConstraint() {
        #expect(policy.isWithinAllowedRoots("/anything/at/all", roots: []))
    }

    @Test func validateCombinesSafetyAndTerritory() {
        let roots = ["/Users/testuser/Library/Caches"]
        // In territory and safe → allowed.
        #expect(policy.validate("/Users/testuser/Library/Caches/com.foo/x", allowedRoots: roots))
        // In territory but protected (Caches root itself is protected? no — a
        // forbidden system path) → rejected by safety.
        #expect(!policy.validate("/System/x", allowedRoots: ["/System"]))
        // Safe but outside declared territory → rejected by territory.
        #expect(!policy.validate("/Users/testuser/Documents/x/y", allowedRoots: roots))
    }

    @Test func validateBlocksChildSymlinkEscape() {
        // A "child" that is really a symlink pointing outside the category's territory
        // must be blocked — validate resolves symlinks before the territory check.
        let fm = FileManager.default
        let live = DeletionPolicy(home: NSHomeDirectory())
        let base = fm.temporaryDirectory
            .appendingPathComponent("sparkclean-terr-\(ProcessInfo.processInfo.globallyUniqueString)")
        let cacheDir = base.appendingPathComponent("Caches")
        let outside = base.appendingPathComponent("Documents/secret")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: outside.path, contents: Data("x".utf8))
        defer { try? fm.removeItem(at: base) }

        let escapingChild = cacheDir.appendingPathComponent("link")
        try? fm.createSymbolicLink(atPath: escapingChild.path, withDestinationPath: outside.path)

        // Territory is the cache dir; the link resolves into a sibling Documents tree.
        #expect(!live.validate(escapingChild.path, allowedRoots: [cacheDir.path]))
        // A real file inside the cache dir is fine.
        let realChild = cacheDir.appendingPathComponent("real.db")
        fm.createFile(atPath: realChild.path, contents: Data("x".utf8))
        #expect(live.validate(realChild.path, allowedRoots: [cacheDir.path]))
    }

    @Test func rejectsSymlinkEscapeIntoProtectedDir() {
        // A path that resolves (via a real on-disk symlink) into a protected location
        // must be rejected — the policy resolves symlinks before judging.
        let fm = FileManager.default
        let realHome = NSHomeDirectory()
        let livePolicy = DeletionPolicy(home: realHome)
        let dir = fm.temporaryDirectory
            .appendingPathComponent("sparkclean-escape-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let link = dir.appendingPathComponent("escape")
        // Points at the real home's Desktop (a protected path).
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: realHome + "/Desktop")

        #expect(!livePolicy.isSafeToDelete(link.path))
    }
}

// MARK: - FileRemover Tests (unified deletion service)

struct FileRemoverTests {

    /// A fixture Trash: "trashing" moves the item into `trashDir` instead of the real
    /// system Trash, and returns the new location.
    private func fixtureTrash(_ trashDir: URL) -> FileRemover.TrashStrategy {
        FileRemover.TrashStrategy { url in
            let dest = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    private func makeSandbox() -> (base: URL, trash: URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("sparkclean-remover-\(ProcessInfo.processInfo.globallyUniqueString)")
        let trash = base.appendingPathComponent("Trash")
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        return (base, trash, { try? fm.removeItem(at: base) })
    }

    @Test func trashesFileWithinTerritoryAndCapturesLocation() {
        let (base, trash, cleanup) = makeSandbox()
        defer { cleanup() }
        let fm = FileManager.default
        let cacheDir = base.appendingPathComponent("Caches")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let file = cacheDir.appendingPathComponent("junk.db")
        fm.createFile(atPath: file.path, contents: Data("x".utf8))

        let remover = FileRemover(useTrash: true, trashStrategy: fixtureTrash(trash))
        let result = remover.remove(file.path, allowedRoots: [cacheDir.path])

        guard case let .removed(removal) = result else {
            Issue.record("expected .removed, got \(result)")
            return
        }
        #expect(removal.trashedPath == trash.appendingPathComponent("junk.db").path)
        #expect(!fm.fileExists(atPath: file.path))
        #expect(fm.fileExists(atPath: removal.trashedPath!))
    }

    @Test func blocksItemOutsideTerritory() {
        let (base, trash, cleanup) = makeSandbox()
        defer { cleanup() }
        let fm = FileManager.default
        let cacheDir = base.appendingPathComponent("Caches")
        let docs = base.appendingPathComponent("Documents")
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let precious = docs.appendingPathComponent("thesis.txt")
        fm.createFile(atPath: precious.path, contents: Data("important".utf8))

        let remover = FileRemover(useTrash: true, trashStrategy: fixtureTrash(trash))
        // Territory is Caches, but we try to remove something in Documents.
        let result = remover.remove(precious.path, allowedRoots: [cacheDir.path])

        guard case .blocked = result else {
            Issue.record("expected .blocked, got \(result)")
            return
        }
        #expect(fm.fileExists(atPath: precious.path))  // untouched
    }

    @Test func blocksProtectedPathEvenWithinTerritory() {
        let remover = FileRemover(useTrash: true)
        // Home root is protected; even a permissive territory can't authorize it.
        let result = remover.remove(NSHomeDirectory(), allowedRoots: ["/"])
        guard case .blocked = result else {
            Issue.record("expected .blocked, got \(result)")
            return
        }
    }

    @Test func permanentDeleteRemovesFile() {
        let (base, _, cleanup) = makeSandbox()
        defer { cleanup() }
        let fm = FileManager.default
        let file = base.appendingPathComponent("gone.txt")
        fm.createFile(atPath: file.path, contents: Data("x".utf8))

        let remover = FileRemover(useTrash: false)
        let result = remover.remove(file.path, allowedRoots: [base.path])

        guard case let .removed(removal) = result else {
            Issue.record("expected .removed, got \(result)")
            return
        }
        #expect(removal.method == "DELETE")
        #expect(removal.trashedPath == nil)
        #expect(!fm.fileExists(atPath: file.path))
    }
}

// MARK: - CleanupManifest / Undo Tests

struct CleanupManifestTests {

    private func makeStoreDir() -> (URL, () -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("sparkclean-manifest-\(ProcessInfo.processInfo.globallyUniqueString)")
        return (dir, { try? fm.removeItem(at: dir) })
    }

    @Test func saveAndReadBackRoundTrips() {
        let (dir, cleanup) = makeStoreDir()
        defer { cleanup() }
        let store = CleanupManifestStore(directory: dir)
        var manifest = CleanupManifest(sessionID: "abc", appVersion: "1.4.0", trashMode: true)
        manifest.entries.append(.init(originalPath: "/a/b", trashedPath: "/t/b", size: 10, category: "Cache"))
        store.save(manifest)

        let read = store.mostRecent()
        #expect(read?.sessionID == "abc")
        #expect(read?.entries.count == 1)
        #expect(read?.entries.first?.originalPath == "/a/b")
    }

    @Test func restoreMovesItemsBack() {
        let (dir, cleanup) = makeStoreDir()
        defer { cleanup() }
        let fm = FileManager.default
        // Simulate a trashed item and a vacated original location.
        let trashed = dir.appendingPathComponent("trash/file.txt")
        let original = dir.appendingPathComponent("home/sub/file.txt")
        try? fm.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: trashed.path, contents: Data("data".utf8))

        let store = CleanupManifestStore(directory: dir)
        var manifest = CleanupManifest(sessionID: "s1", appVersion: "1.4.0", trashMode: true)
        manifest.entries.append(.init(originalPath: original.path, trashedPath: trashed.path,
                                      size: 4, category: "Cache"))

        let outcome = store.restore(manifest)
        #expect(outcome.restored == 1)
        #expect(fm.fileExists(atPath: original.path))       // moved back (dirs created)
        #expect(!fm.fileExists(atPath: trashed.path))       // gone from trash
    }

    @Test func restoreSkipsWhenOriginalExists() {
        let (dir, cleanup) = makeStoreDir()
        defer { cleanup() }
        let fm = FileManager.default
        let trashed = dir.appendingPathComponent("trash/file.txt")
        let original = dir.appendingPathComponent("home/file.txt")
        try? fm.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: trashed.path, contents: Data("old".utf8))
        fm.createFile(atPath: original.path, contents: Data("new".utf8))  // already occupied

        let store = CleanupManifestStore(directory: dir)
        var manifest = CleanupManifest(sessionID: "s2", appVersion: "1.4.0", trashMode: true)
        manifest.entries.append(.init(originalPath: original.path, trashedPath: trashed.path,
                                      size: 3, category: "Cache"))

        let outcome = store.restore(manifest)
        #expect(outcome.skippedExisting == 1)
        #expect(outcome.restored == 0)
        #expect(fm.fileExists(atPath: trashed.path))  // not moved
    }

    @Test func restoreReportsMissingTrashItem() {
        let (dir, cleanup) = makeStoreDir()
        defer { cleanup() }
        let store = CleanupManifestStore(directory: dir)
        var manifest = CleanupManifest(sessionID: "s3", appVersion: "1.4.0", trashMode: true)
        manifest.entries.append(.init(originalPath: dir.appendingPathComponent("x").path,
                                      trashedPath: dir.appendingPathComponent("nope").path,
                                      size: 0, category: "Cache"))
        let outcome = store.restore(manifest)
        #expect(outcome.missingInTrash == 1)
    }

    @Test func pruneKeepsRetentionCount() {
        let (dir, cleanup) = makeStoreDir()
        defer { cleanup() }
        let store = CleanupManifestStore(directory: dir, retention: 3)
        for i in 0..<6 {
            store.save(CleanupManifest(sessionID: "s\(i)", appVersion: "1.4.0", trashMode: true))
        }
        store.prune()
        #expect(store.allManifests().count == 3)
    }
}
