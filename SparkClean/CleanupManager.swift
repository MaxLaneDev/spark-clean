//
//  CleanupManager.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import Foundation
import SwiftUI
import AppKit
import Dispatch
import os
import Darwin

// MARK: - CleanupManager

@Observable
class CleanupManager {
    var categories: [CleanupCategory] = []
    var isScanning = false
    var scanComplete = false
    var isCleaning = false
    var cleanComplete = false
    var lastCleanedSize: Int64 = 0
    var lastMovedToTrashSize: Int64 = 0
    var lastPermanentlyDeletedSize: Int64 = 0
    var lastCleanedCount: Int = 0
    var cleanErrors: [String] = []
    var cleanSuccessCount: Int = 0
    var cleanFailCount: Int = 0
    /// Set by a category-group Clean action so confirmation and execution remain
    /// scoped to what the user is viewing. `nil` means the dashboard's global action.
    var pendingCleanGroup: CategoryGroup?
    var currentScanItem = ""
    var scanProgress: Double = 0
    var cleanProgress: Double = 0
    var diskUsage: DiskUsageInfo?
    var lastScanSummary: ScanSummary?
    var searchQuery = ""
    var scanErrors: [String] = []
    var hasFullDiskAccess: Bool = true
    private let cancelLock = OSAllocatedUnfairLock(initialState: false)
    private var scanStartTime: Date?
    private let scannedPathsLock = OSAllocatedUnfairLock(initialState: Set<String>())

    var totalSize: Int64 {
        filteredCategories.filter(\.isSelected).reduce(0) { $0 + $1.selectedSize }
    }

    var totalFiles: Int {
        filteredCategories.filter(\.isSelected).reduce(0) { $0 + $1.selectedFileCount }
    }

    var overallSize: Int64 {
        categories.reduce(0) { $0 + $1.size }
    }

    var selectedCategoryCount: Int {
        filteredCategories.filter(\.isSelected).count
    }

    var hasSelectedContent: Bool {
        categories.contains { $0.isSelected && $0.hasSelectedContent }
    }

    var filteredCategories: [CleanupCategory] {
        if searchQuery.isEmpty { return categories }
        return categories.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.description.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func categoriesForGroup(_ group: CategoryGroup) -> [CleanupCategory] {
        filteredCategories.filter { $0.group == group }
    }

    func sizeForGroup(_ group: CategoryGroup) -> Int64 {
        categoriesForGroup(group).reduce(0) { $0 + $1.selectedSize }
    }

    func selectAll(in group: CategoryGroup) {
        for i in categories.indices
        where categories[i].group == group &&
              categories[i].safetyLevel != .caution {
            categories[i].isSelected = true
        }
    }

    func deselectAll(in group: CategoryGroup) {
        for i in categories.indices where categories[i].group == group {
            categories[i].isSelected = false
        }
    }

    func selectAll() {
        for i in categories.indices {
            // Never batch-select caution categories — require explicit individual selection
            if categories[i].safetyLevel != .caution {
                categories[i].isSelected = true
            }
        }
    }

    func deselectAll() {
        for i in categories.indices { categories[i].isSelected = false }
    }

    /// Select only safe categories
    func selectSafeOnly() {
        for i in categories.indices {
            categories[i].isSelected = categories[i].safetyLevel == .safe
        }
    }

    static let home = NSHomeDirectory()
    static let whatsAppSharedContainerPath =
        "\(home)/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
    static let whatsAppMediaPath =
        "\(whatsAppSharedContainerPath)/Message/Media"
    static let whatsAppBundleIDs = [
        "net.whatsapp.WhatsApp",
        "net.whatsapp.WhatsApp.Intents",
        "net.whatsapp.WhatsApp.ServiceExtension",
        "net.whatsapp.WhatsApp.WAAppKitBridgeService",
    ]

    // MARK: - Protected Paths (NEVER delete these)

    /// Shared deletion-safety rules. All deletion surfaces validate through this.
    static let deletionPolicy = DeletionPolicy()

    /// Undo-manifest store shared across deletion surfaces (enables Restore Last Cleanup).
    static let manifestStore = CleanupManifestStore()

    /// Marketing version string for audit/manifest headers.
    static var appVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// Validate that a path is safe to delete. Delegates to `DeletionPolicy` so the
    /// rules live in one testable place shared across every deletion surface.
    static func isSafePath(_ path: String) -> Bool {
        deletionPolicy.isSafeToDelete(path)
    }

    /// Whether the most recent cleanup left any recoverable (trashed) items.
    var canRestoreLastCleanup: Bool {
        (Self.manifestStore.mostRecent()?.entries.isEmpty == false)
    }

    /// Restore the most recent cleanup by moving trashed items back to their original
    /// locations. Returns the outcome, or `nil` if there is nothing to restore.
    @discardableResult
    func restoreLastCleanup() async -> RestoreOutcome? {
        guard let manifest = Self.manifestStore.mostRecent(), !manifest.entries.isEmpty else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Self.manifestStore.restore(manifest)
                continuation.resume(returning: outcome)
            }
        }
    }

    // MARK: - Memory Pressure Monitoring

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func startMemoryMonitoring() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.memoryPressureSource?.data ?? []
            if event.contains(.critical) {
                // Emergency: cancel scan immediately
                self.cancelLock.withLock { $0 = true }
                self.resetScannedPaths()
                Task { @MainActor in
                    self.scanErrors.append(String(localized: "Scan cancelled: system memory pressure critical"))
                }
            } else if event.contains(.warning) {
                // Warning: just log it — the autoreleasepool fixes should handle this
                Task { @MainActor in
                    self.scanErrors.append(String(localized: "Warning: elevated memory pressure detected"))
                }
            }
        }
        memoryPressureSource?.resume()
    }

    func stopMemoryMonitoring() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    // MARK: - Settings

    private var settingScanDocker: Bool {
        UserDefaults.standard.object(forKey: "scanDocker") as? Bool ?? true
    }
    private var settingScanNodeModules: Bool {
        UserDefaults.standard.object(forKey: "scanNodeModules") as? Bool ?? true
    }
    private var settingScanUnusedApps: Bool {
        UserDefaults.standard.object(forKey: "scanUnusedApps") as? Bool ?? true
    }
    private var settingUnusedAppThresholdDays: Int {
        let v = UserDefaults.standard.integer(forKey: "unusedAppThresholdDays")
        return v > 0 ? v : 90
    }
    private var settingLargeFileThresholdMB: Int {
        let v = UserDefaults.standard.integer(forKey: "largeFileThresholdMB")
        return v > 0 ? v : 50
    }
    private var settingOldFileThresholdDays: Int {
        let v = UserDefaults.standard.integer(forKey: "oldFileThresholdDays")
        return v > 0 ? v : 30
    }
    private var settingScreenshotThresholdDays: Int {
        let v = UserDefaults.standard.integer(forKey: "screenshotThresholdDays")
        return v > 0 ? v : 30
    }
    private var settingPreferTrash: Bool {
        UserDefaults.standard.object(forKey: "preferTrash") as? Bool ?? true
    }
    private var settingScanLargeFiles: Bool {
        UserDefaults.standard.object(forKey: "scanLargeFiles") as? Bool ?? true
    }
    private var settingLargeFileScanDirs: [String] {
        var dirs: [String] = []
        if UserDefaults.standard.object(forKey: "largeFileScanDownloads") as? Bool ?? true { dirs.append("\(Self.home)/Downloads") }
        if UserDefaults.standard.object(forKey: "largeFileScanDesktop") as? Bool ?? true { dirs.append("\(Self.home)/Desktop") }
        if UserDefaults.standard.object(forKey: "largeFileScanDocuments") as? Bool ?? true { dirs.append("\(Self.home)/Documents") }
        if UserDefaults.standard.object(forKey: "largeFileScanMovies") as? Bool ?? true { dirs.append("\(Self.home)/Movies") }
        if UserDefaults.standard.object(forKey: "largeFileScanMusic") as? Bool ?? true { dirs.append("\(Self.home)/Music") }
        if UserDefaults.standard.object(forKey: "largeFileScanPictures") as? Bool ?? true { dirs.append("\(Self.home)/Pictures") }
        return dirs
    }
    private var settingLargeFileIncludeVideos: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeVideos") as? Bool ?? true
    }
    private var settingLargeFileIncludeImages: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeImages") as? Bool ?? true
    }
    private var settingLargeFileIncludeArchives: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeArchives") as? Bool ?? true
    }
    private var settingLargeFileIncludeInstallers: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeInstallers") as? Bool ?? true
    }
    private var settingLargeFileIncludeAudio: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeAudio") as? Bool ?? true
    }
    private var settingLargeFileIncludeOther: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeOther") as? Bool ?? true
    }
    private var settingLargeFileMaxAgeDays: Int {
        UserDefaults.standard.integer(forKey: "largeFileMaxAgeDays")
    }
    private var settingLargeFileMaxResults: Int {
        let v = UserDefaults.standard.integer(forKey: "largeFileMaxResults")
        return v > 0 ? v : 100
    }
    private var settingScanVirtualEnvironments: Bool {
        UserDefaults.standard.object(forKey: "scanVirtualEnvironments") as? Bool ?? true
    }
    private var settingScanRustTargets: Bool {
        UserDefaults.standard.object(forKey: "scanRustTargets") as? Bool ?? true
    }
    private var settingScanOldInstallers: Bool {
        UserDefaults.standard.object(forKey: "scanOldInstallers") as? Bool ?? true
    }
    private var settingScreenRecordingThresholdDays: Int {
        let v = UserDefaults.standard.integer(forKey: "screenRecordingThresholdDays")
        return v > 0 ? v : 60
    }
    private var settingScanIOSBackups: Bool {
        UserDefaults.standard.object(forKey: "scanIOSBackups") as? Bool ?? true
    }
    private var settingScanIMessageAttachments: Bool {
        UserDefaults.standard.object(forKey: "scanIMessageAttachments") as? Bool ?? true
    }
    private var settingScanBrokenSymlinks: Bool {
        UserDefaults.standard.object(forKey: "scanBrokenSymlinks") as? Bool ?? true
    }
    private var settingScanScreenRecordings: Bool {
        UserDefaults.standard.object(forKey: "scanScreenRecordings") as? Bool ?? true
    }


    // MARK: - Scan Definitions
    //
    // SAFETY RULES:
    // - .safe = narrowly scoped generated data expected to rebuild
    // - .review = user files (downloads, screenshots) — might be wanted
    // - .caution = app data, backups — could break things
    //
    // Only .safe categories are selected by default.

    private let scanDefinitions: [ScanDefinition] = [

        // ═══════════ SYSTEM (safe caches & logs) ═══════════

        ScanDefinition(name: "System Logs", stableName: "System Logs", icon: "doc.text", color: .green,
            description: "Current and historical log files — review if you are diagnosing an issue",
            group: .system, safetyLevel: .review, defaultSelected: false) {
            // Exclude DiagnosticReports subdirectory (scanned separately)
            ["\(home)/Library/Logs", "/Library/Logs"]
        },

        ScanDefinition(name: "Crash Reports", stableName: "Crash Reports", icon: "exclamationmark.triangle", color: .orange,
            description: "App crash reports and diagnostics — safe to remove",
            group: .system, safetyLevel: .safe) {
            ["\(home)/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"]
        },

        ScanDefinition(name: "Saved App State", stableName: "Saved App State", icon: "rectangle.stack", color: .indigo,
            description: "App resume data — removing it can discard restored windows or session state",
            group: .system, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/Saved Application State"]
        },

        ScanDefinition(name: "Software Update Cache", stableName: "Software Update Cache", icon: "arrow.down.circle", color: .blue,
            description: "Per-user software-update cache — system-managed update staging is not touched",
            group: .system, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.apple.SoftwareUpdate"]
        },

        ScanDefinition(name: "Trash", stableName: "Trash", icon: "trash", color: .gray,
            description: "Items already in your Trash — empty to reclaim space",
            group: .system, safetyLevel: .review, defaultSelected: false,
            requiresPermanentDeletion: true) {
            ["\(home)/.Trash"]
        },

        // ═══════════ BROWSERS (safe — caches rebuild) ═══════════

        ScanDefinition(name: "Safari Cache", stableName: "Safari Cache", icon: "safari", color: .cyan,
            description: "Safari browser cache — will be rebuilt as you browse",
            group: .browsers, safetyLevel: .safe,
            associatedBundleIDs: ["com.apple.Safari"]) {
            ["\(home)/Library/Caches/com.apple.Safari",
             "\(home)/Library/Caches/com.apple.Safari.SearchHelper",
             "\(home)/Library/Caches/com.apple.WebKit.Networking"]
        },

        ScanDefinition(name: "Chrome Cache", stableName: "Chrome Cache", icon: "globe", color: .yellow,
            description: "Chrome cache, GPU cache, service workers — rebuilt automatically",
            group: .browsers, safetyLevel: .safe,
            associatedBundleIDs: ["com.google.Chrome"]) {
            var paths = [
                "\(home)/Library/Caches/Google/Chrome",
                "\(home)/Library/Application Support/Google/Chrome/Default/Service Worker",
                "\(home)/Library/Application Support/Google/Chrome/Default/GPUCache",
                "\(home)/Library/Application Support/Google/Chrome/Default/Code Cache",
                "\(home)/Library/Application Support/Google/Chrome/Default/Cache",
                "\(home)/Library/Application Support/Google/Chrome/ShaderCache",
                "\(home)/Library/Application Support/Google/Chrome/GrShaderCache",
            ]
            // Dynamically discover all Chrome profile directories
            let chromeAppSupport = "\(home)/Library/Application Support/Google/Chrome"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: chromeAppSupport) {
                for entry in entries where entry.hasPrefix("Profile ") {
                    paths.append("\(chromeAppSupport)/\(entry)/Cache")
                    paths.append("\(chromeAppSupport)/\(entry)/Code Cache")
                    paths.append("\(chromeAppSupport)/\(entry)/Service Worker")
                    paths.append("\(chromeAppSupport)/\(entry)/GPUCache")
                }
            }
            return paths
        },

        ScanDefinition(name: "Firefox Cache", stableName: "Firefox Cache", icon: "flame", color: .orange,
            description: "Firefox cache and crash reports",
            group: .browsers, safetyLevel: .safe,
            associatedBundleIDs: ["org.mozilla.firefox"]) {
            ["\(home)/Library/Caches/Firefox",
             "\(home)/Library/Caches/org.mozilla.firefox",
             "\(home)/Library/Application Support/Firefox/Crash Reports"]
        },

        ScanDefinition(name: "Arc Cache", stableName: "Arc Cache", icon: "compass.drawing", color: .blue,
            description: "Arc browser cache",
            group: .browsers, safetyLevel: .safe,
            associatedBundleIDs: ["company.thebrowser.Browser"]) {
            ["\(home)/Library/Caches/company.thebrowser.Browser",
             "\(home)/Library/Application Support/Arc/User Data/Default/Service Worker",
             "\(home)/Library/Application Support/Arc/User Data/Default/GPUCache",
             "\(home)/Library/Application Support/Arc/User Data/Default/Code Cache"]
        },

        ScanDefinition(name: "Edge Cache", stableName: "Edge Cache", icon: "globe.americas", color: .cyan,
            description: "Microsoft Edge cache",
            group: .browsers, safetyLevel: .safe,
            associatedBundleIDs: ["com.microsoft.edgemac"]) {
            ["\(home)/Library/Caches/com.microsoft.edgemac",
             "\(home)/Library/Application Support/Microsoft Edge/Default/Service Worker",
             "\(home)/Library/Application Support/Microsoft Edge/Default/Code Cache",
             "\(home)/Library/Application Support/Microsoft Edge/Default/GPUCache"]
        },

        ScanDefinition(name: "Brave Cache", stableName: "Brave Cache", icon: "shield", color: .orange,
            description: "Brave browser cache",
            group: .browsers, safetyLevel: .safe,
            associatedBundleIDs: ["com.brave.Browser"]) {
            ["\(home)/Library/Caches/BraveSoftware/Brave-Browser",
             "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Service Worker",
             "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Code Cache"]
        },

        // ═══════════ PRIVACY (review/caution — user data) ═══════════

        ScanDefinition(name: "Recent Items", stableName: "Recent Items", icon: "clock.arrow.circlepath", color: .indigo,
            description: "Recent applications, documents, hosts, and servers — Finder favorites are preserved",
            group: .privacy, safetyLevel: .review, defaultSelected: false) {
            let base = "\(home)/Library/Application Support/com.apple.sharedfilelist"
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else {
                return []
            }
            return entries
                .filter {
                    $0 == "com.apple.LSSharedFileList.ApplicationRecentDocuments" ||
                        $0.hasPrefix("com.apple.LSSharedFileList.Recent")
                }
                .map { (base as NSString).appendingPathComponent($0) }
        },

        ScanDefinition(name: "Spotlight History", stableName: "Spotlight History", icon: "magnifyingglass", color: .indigo,
            description: "Spotlight search history and shortcuts — reveals what you've searched for",
            group: .privacy, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/Application Support/com.apple.spotlight.Shortcuts",
             "\(home)/Library/Caches/com.apple.Spotlight"]
        },

        ScanDefinition(name: "Shell History", stableName: "Shell History", icon: "terminal", color: .indigo,
            description: "Terminal command history — zsh, bash, Python, Node.js, Ruby REPL",
            group: .privacy, safetyLevel: .review, defaultSelected: false,
            allowsDirectHomeItems: true) {
            ["\(home)/.zsh_history",
             "\(home)/.bash_history",
             "\(home)/.python_history",
             "\(home)/.node_repl_history",
             "\(home)/.irb_history",
             "\(home)/.lesshst",
             "\(home)/.wget-hsts"]
        },

        ScanDefinition(name: "Safari History", stableName: "Safari History", icon: "safari", color: .indigo,
            description: "Safari browsing history and recent tabs — close Safari first",
            group: .privacy, safetyLevel: .caution, defaultSelected: false,
            associatedBundleIDs: ["com.apple.Safari"]) {
            ["\(home)/Library/Safari/History.db",
             "\(home)/Library/Safari/History.db-wal",
             "\(home)/Library/Safari/History.db-shm",
             "\(home)/Library/Safari/RecentlyClosedTabs.plist",
             "\(home)/Library/Safari/LastSession.plist",
             "\(home)/Library/Safari/Downloads.plist",
             "\(home)/Library/Safari/TopSites.plist"]
        },

        ScanDefinition(name: "Chrome History", stableName: "Chrome History", icon: "globe", color: .indigo,
            description: "Chrome browsing history across all profiles — close Chrome first",
            group: .privacy, safetyLevel: .caution, defaultSelected: false,
            associatedBundleIDs: ["com.google.Chrome"]) {
            var paths = [
                "\(home)/Library/Application Support/Google/Chrome/Default/History",
                "\(home)/Library/Application Support/Google/Chrome/Default/History-journal",
                "\(home)/Library/Application Support/Google/Chrome/Default/Visited Links",
                "\(home)/Library/Application Support/Google/Chrome/Default/Top Sites",
                "\(home)/Library/Application Support/Google/Chrome/Default/Top Sites-journal",
            ]
            let chromeAppSupport = "\(home)/Library/Application Support/Google/Chrome"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: chromeAppSupport) {
                for entry in entries where entry.hasPrefix("Profile ") {
                    paths.append("\(chromeAppSupport)/\(entry)/History")
                    paths.append("\(chromeAppSupport)/\(entry)/History-journal")
                    paths.append("\(chromeAppSupport)/\(entry)/Visited Links")
                    paths.append("\(chromeAppSupport)/\(entry)/Top Sites")
                    paths.append("\(chromeAppSupport)/\(entry)/Top Sites-journal")
                }
            }
            return paths
        },

        ScanDefinition(name: "Firefox Form History", stableName: "Firefox Form History", icon: "flame", color: .indigo,
            description: "Firefox form autofill data — close Firefox first",
            group: .privacy, safetyLevel: .caution, defaultSelected: false,
            associatedBundleIDs: ["org.mozilla.firefox"]) {
            var paths: [String] = []
            let profilesDir = "\(home)/Library/Application Support/Firefox/Profiles"
            if let profiles = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) {
                for profile in profiles {
                    paths.append("\(profilesDir)/\(profile)/formhistory.sqlite")
                    paths.append("\(profilesDir)/\(profile)/formhistory.sqlite-wal")
                    paths.append("\(profilesDir)/\(profile)/formhistory.sqlite-shm")
                }
            }
            return paths
        },

        ScanDefinition(name: "Browser Cookies", stableName: "Browser Cookies", icon: "birthday.cake", color: .indigo,
            description: "Safari and Chrome cookies — will log you out of websites; close both browsers first",
            group: .privacy, safetyLevel: .caution, defaultSelected: false,
            associatedBundleIDs: ["com.apple.Safari", "com.google.Chrome"]) {
            var paths = [
                "\(home)/Library/Cookies/Cookies.binarycookies",
                "\(home)/Library/Cookies/com.apple.Safari.cookies",
                "\(home)/Library/Application Support/Google/Chrome/Default/Cookies",
                "\(home)/Library/Application Support/Google/Chrome/Default/Cookies-journal",
            ]
            let chromeAppSupport = "\(home)/Library/Application Support/Google/Chrome"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: chromeAppSupport) {
                for entry in entries where entry.hasPrefix("Profile ") {
                    paths.append("\(chromeAppSupport)/\(entry)/Cookies")
                    paths.append("\(chromeAppSupport)/\(entry)/Cookies-journal")
                }
            }
            return paths
        },

        // ═══════════ DEVELOPER (safe — build artifacts rebuild) ═══════════

        ScanDefinition(name: "Xcode Derived Data", stableName: "Xcode Derived Data", icon: "hammer", color: .pink,
            description: "Xcode build artifacts — rebuilt on next build",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/Library/Developer/Xcode/DerivedData"]
        },

        ScanDefinition(name: "Xcode Caches", stableName: "Xcode Caches", icon: "xmark.bin", color: .indigo,
            description: "Xcode and Simulator generated caches — rebuilt as needed",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.apple.dt.Xcode",
             "\(home)/Library/Developer/CoreSimulator/Caches"]
        },

        ScanDefinition(name: "Xcode Device Support", stableName: "Xcode Device Support", icon: "iphone", color: .indigo,
            description: "All downloaded device-support symbols — large and re-downloadable, but not necessarily old",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/Developer/Xcode/iOS DeviceSupport",
             "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
             "\(home)/Library/Developer/Xcode/tvOS DeviceSupport",
             "\(home)/Library/Developer/Xcode/macOS DeviceSupport"]
        },

        ScanDefinition(name: "Xcode Previews", stableName: "Xcode Previews", icon: "rectangle.on.rectangle", color: .pink,
            description: "SwiftUI preview build data — rebuilt automatically",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/Library/Developer/Xcode/UserData/Previews"]
        },

        ScanDefinition(name: "Xcode Archives", stableName: "Xcode Archives", icon: "archivebox", color: .purple,
            description: "Old build archives — may contain release builds you need",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/Developer/Xcode/Archives"]
        },

        ScanDefinition(name: "Android / Gradle", stableName: "Android / Gradle", icon: "cpu", color: .green,
            description: "Android build caches and Gradle — rebuilt on next build",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/.gradle/caches", "\(home)/.gradle/wrapper/dists",
             "\(home)/.android/cache"]
        },

        // ═══════════ PACKAGE MANAGERS (safe — caches re-download) ═══════════

        ScanDefinition(name: "Homebrew Cache", stableName: "Homebrew Cache", icon: "mug", color: .brown,
            description: "Downloaded packages — re-downloaded on next install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/Homebrew", "/opt/homebrew/Caches",
             "\(home)/Library/Logs/Homebrew"]
        },

        ScanDefinition(name: "CocoaPods Cache", stableName: "CocoaPods Cache", icon: "shippingbox", color: .brown,
            description: "Pod cache — re-downloaded on pod install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/CocoaPods"]
        },

        ScanDefinition(name: "Swift Package Cache", stableName: "Swift Package Cache", icon: "swift", color: .orange,
            description: "Swift Package Manager cache — re-downloaded as needed",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/org.swift.swiftpm"]
        },

        ScanDefinition(name: "npm / Yarn / pnpm / Bun", stableName: "npm / Yarn / pnpm / Bun", icon: "shippingbox", color: .red,
            description: "JS package caches — re-downloaded on install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.npm", "\(home)/Library/Caches/Yarn", "\(home)/.yarn/cache",
             "\(home)/Library/pnpm/store", "\(home)/.pnpm-store",
             "\(home)/.bun/install/cache"]
        },

        ScanDefinition(name: "pip Cache", stableName: "pip Cache", icon: "puzzlepiece", color: .green,
            description: "Python download cache — packages are re-fetched on install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/pip", "\(home)/.cache/pip"]
        },

        ScanDefinition(name: "Conda Package Stores", stableName: "Conda Package Stores", icon: "shippingbox", color: .green,
            description: "Conda package stores — removal can break environments that use symlinked packages",
            group: .packageManagers, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.conda/pkgs", "\(home)/anaconda3/pkgs", "\(home)/miniconda3/pkgs"]
        },

        ScanDefinition(name: "Ruby Bundler Cache", stableName: "Ruby Bundler Cache", icon: "diamond", color: .red,
            description: "Bundler package cache — installed user gems are not touched",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.bundle/cache"]
        },

        ScanDefinition(name: "Go Cache", stableName: "Go Cache", icon: "server.rack", color: .cyan,
            description: "Go build and module caches",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/go-build", "\(home)/go/pkg/mod/cache"]
        },

        ScanDefinition(name: "Cargo / Rust", stableName: "Cargo / Rust", icon: "gearshape.2", color: .orange,
            description: "Cargo registry and build cache",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.cargo/registry", "\(home)/.cargo/git"]
        },

        ScanDefinition(name: "Maven", stableName: "Maven", icon: "building.columns", color: .indigo,
            description: "Maven local repository — may contain locally built artifacts unavailable remotely",
            group: .packageManagers, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.m2/repository"]
        },

        ScanDefinition(name: "Composer Cache", stableName: "Composer Cache", icon: "cube", color: .purple,
            description: "Composer download cache — re-fetched on install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.composer/cache"]
        },

        ScanDefinition(name: "NuGet / Dart Package Stores", stableName: "NuGet / Dart Package Stores", icon: "shippingbox", color: .purple,
            description: "Local package stores — deleting may remove offline packages or activated Dart tools",
            group: .packageManagers, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.nuget/packages", "\(home)/.pub-cache"]
        },

        // ═══════════ DOCKER ═══════════
        // NOTE: Docker Desktop Data scan definition REMOVED to prevent double-counting.
        // The Docker.raw VM disk inside ~/Library/Containers/com.docker.docker/Data
        // contains ALL images, containers, volumes, and build cache. Showing its
        // filesystem size PLUS the Docker CLI-reported sizes was double-counting.
        // Docker cleanup is now handled exclusively via the CLI-based scans below
        // (Docker Images, Docker Containers, Docker Build Cache) which give accurate
        // per-resource sizes. Users who want to fully remove Docker can use the Uninstaller.

        ScanDefinition(name: "Docker Logs & Cache", stableName: "Docker Logs & Cache", icon: "cube.box", color: .blue,
            description: "Docker Desktop generated logs and cache — CLI plugins and builder configuration are not touched",
            group: .docker, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.docker.docker",
             "\(home)/Library/Logs/Docker Desktop"]
        },

        // ═══════════ APPLICATIONS (safe — app caches rebuild) ═══════════

        ScanDefinition(name: "VS Code / Cursor Cache", stableName: "VS Code / Cursor Cache", icon: "curlybraces", color: .blue,
            description: "IDE caches and logs — rebuilt automatically",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.microsoft.VSCode",
             "\(home)/Library/Application Support/Code/Cache",
             "\(home)/Library/Application Support/Code/CachedData",
             "\(home)/Library/Application Support/Code/CachedExtensionVSIXs",
             "\(home)/Library/Application Support/Code/logs",
             "\(home)/Library/Application Support/Code/Service Worker",
             "\(home)/Library/Application Support/Code/Code Cache",
             "\(home)/Library/Application Support/Cursor/Cache",
             "\(home)/Library/Application Support/Cursor/CachedData",
             "\(home)/Library/Application Support/Cursor/Code Cache",
             "\(home)/Library/Application Support/Cursor/logs",
             "\(home)/Library/Caches/com.todesktop.runtime.Cursor"]
        },

        ScanDefinition(name: "JetBrains IDEs Cache", stableName: "JetBrains IDEs Cache", icon: "chevron.left.forwardslash.chevron.right", color: .orange,
            description: "IntelliJ, WebStorm, PyCharm caches/logs — rebuilt on launch",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/JetBrains", "\(home)/Library/Logs/JetBrains"]
        },

        ScanDefinition(name: "Adobe Cache", stableName: "Adobe Cache", icon: "paintbrush", color: .red,
            description: "Adobe media cache — rebuilt when editing",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/Adobe",
             "\(home)/Library/Application Support/Adobe/Common/Media Cache Files",
             "\(home)/Library/Application Support/Adobe/Common/Media Cache"]
        },

        ScanDefinition(name: "Spotify Cache", stableName: "Spotify Cache", icon: "music.note", color: .green,
            description: "Spotify persistent/offline cache — media may need to be downloaded again",
            group: .applications, safetyLevel: .review, defaultSelected: false,
            associatedBundleIDs: ["com.spotify.client"]) {
            ["\(home)/Library/Caches/com.spotify.client",
             "\(home)/Library/Application Support/Spotify/PersistentCache"]
        },

        ScanDefinition(name: "Slack Cache", stableName: "Slack Cache", icon: "number", color: .purple,
            description: "Slack cache — rebuilt when you open channels",
            group: .applications, safetyLevel: .safe,
            associatedBundleIDs: ["com.tinyspeck.slackmacgap"]) {
            ["\(home)/Library/Caches/com.tinyspeck.slackmacgap",
             "\(home)/Library/Application Support/Slack/Cache",
             "\(home)/Library/Application Support/Slack/Service Worker",
             "\(home)/Library/Application Support/Slack/Code Cache"]
        },

        ScanDefinition(name: "Discord Cache", stableName: "Discord Cache", icon: "bubble.left.and.bubble.right", color: .indigo,
            description: "Discord cache — rebuilt automatically",
            group: .applications, safetyLevel: .safe,
            associatedBundleIDs: ["com.hnc.Discord"]) {
            ["\(home)/Library/Caches/com.hnc.Discord",
             "\(home)/Library/Application Support/discord/Cache",
             "\(home)/Library/Application Support/discord/Code Cache",
             "\(home)/Library/Application Support/discord/GPUCache"]
        },

        ScanDefinition(name: "Teams Cache", stableName: "Teams Cache", icon: "person.3", color: .blue,
            description: "Microsoft Teams cache",
            group: .applications, safetyLevel: .safe,
            associatedBundleIDs: ["com.microsoft.teams2"]) {
            ["\(home)/Library/Caches/com.microsoft.teams2",
             "\(home)/Library/Application Support/Microsoft/Teams/Cache",
             "\(home)/Library/Application Support/Microsoft Teams/Cache"]
        },

        ScanDefinition(name: "Zoom Cache", stableName: "Zoom Cache", icon: "video", color: .blue,
            description: "Zoom cache — rebuilt on meetings",
            group: .applications, safetyLevel: .safe,
            associatedBundleIDs: ["us.zoom.xos"]) {
            ["\(home)/Library/Caches/us.zoom.xos"]
        },

        ScanDefinition(name: "Telegram Cache", stableName: "Telegram Cache", icon: "paperplane", color: .blue,
            description: "Telegram media cache — re-downloaded from cloud",
            group: .applications, safetyLevel: .safe,
            associatedBundleIDs: ["ru.keepcoder.Telegram"]) {
            ["\(home)/Library/Caches/ru.keepcoder.Telegram"]
        },

        ScanDefinition(name: "Microsoft Office Cache", stableName: "Microsoft Office Cache", icon: "doc.richtext", color: .blue,
            description: "Office app caches — rebuilt on use",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.microsoft.Word",
             "\(home)/Library/Caches/com.microsoft.Excel",
             "\(home)/Library/Caches/com.microsoft.PowerPoint",
             "\(home)/Library/Caches/com.microsoft.Outlook"]
        },

        ScanDefinition(
            name: "Quick Look Cache", stableName: "Quick Look Cache", icon: "eye.square", color: .gray,
            description: "Thumbnail previews — rebuilds automatically",
            group: .system, safetyLevel: .safe
        ) {
            ["\(home)/Library/Caches/com.apple.QuickLook.thumbnailcache",
             "\(home)/Library/Caches/com.apple.QuickLookThumbnailing"]
        },

        // ═══════════ AI / ML TOOLS (high impact — models can be huge) ═══════════

        ScanDefinition(name: "HuggingFace Models Cache", stableName: "HuggingFace Models Cache", icon: "brain", color: .purple,
            description: "Downloaded ML models — re-downloaded on demand",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.cache/huggingface"]
        },

        ScanDefinition(name: "LM Studio Models", stableName: "LM Studio Models", icon: "cpu.fill", color: .indigo,
            description: "LM Studio model files — re-downloaded from hub",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.cache/lm-studio"]
        },

        // ═══════════ ADDITIONAL DEVELOPER CACHES ═══════════

        ScanDefinition(name: "Bazel Cache", stableName: "Bazel Cache", icon: "hammer.fill", color: .gray,
            description: "Bazel build system cache — rebuilt on next build",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/.cache/bazel", "\(home)/.cache/bazelisk"]
        },

        ScanDefinition(name: "Deno Cache", stableName: "Deno Cache", icon: "d.circle", color: .teal,
            description: "Deno module cache — the ~/.deno installation and binaries are not touched",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/deno", "\(home)/.cache/deno"]
        },

        ScanDefinition(name: "Poetry Cache", stableName: "Poetry Cache", icon: "text.book.closed", color: .purple,
            description: "Poetry Python package cache — re-downloaded on install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/pypoetry", "\(home)/.cache/pypoetry"]
        },

        // ═══════════ ADDITIONAL SYSTEM CLEANUP ═══════════

        ScanDefinition(name: "Font Caches", stableName: "Font Caches", icon: "textformat", color: .gray,
            description: "Font rendering caches — rebuilt automatically on login",
            group: .system, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.apple.FontRegistry",
             "/Library/Caches/com.apple.ATS"]
        },

        ScanDefinition(name: "Speech Data Cache", stableName: "Speech Data Cache", icon: "waveform", color: .blue,
            description: "Speech recognition cache — rebuilt when needed",
            group: .system, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.apple.SpeechRecognitionCore"]
        },

        ScanDefinition(name: "Xcode Playground Cache", stableName: "Xcode Playground Cache", icon: "play.rectangle", color: .pink,
            description: "Swift Playground execution and virtual-device data — review before removal",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/Developer/Xcode/UserData/Playgrounds",
             "\(home)/Library/Developer/XCPGDevices"]
        },

        ScanDefinition(name: "Provisioning Profiles", stableName: "Provisioning Profiles", icon: "shield.checkered", color: .indigo,
            description: "iOS/macOS provisioning profiles — re-downloaded from developer portal",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/MobileDevice/Provisioning Profiles"]
        },

        // ═══════════ DEVELOPER TOOL CACHES (F6) — all regenerable ═══════════

        ScanDefinition(name: "Browser Automation Binaries", stableName: "Browser Automation Binaries", icon: "cursorarrow.rays", color: .teal,
            description: "Playwright/Cypress/Puppeteer browser downloads — re-fetched on next install",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/Library/Caches/ms-playwright", "\(home)/Library/Caches/Cypress",
             "\(home)/Library/Caches/puppeteer", "\(home)/.cache/puppeteer",
             "\(home)/.cache/selenium",
             "\(home)/.cache/ms-playwright"]
        },

        ScanDefinition(name: "uv / Python Tooling Cache", stableName: "uv / Python Tooling Cache", icon: "puzzlepiece.extension", color: .green,
            description: "uv, pre-commit, and pip-tools caches — rebuilt automatically",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.cache/uv", "\(home)/Library/Caches/uv",
             "\(home)/.cache/pre-commit", "\(home)/Library/Caches/pip-tools"]
        },

        ScanDefinition(name: "Compiler Caches", stableName: "Compiler Caches", icon: "hammer.circle", color: .gray,
            description: "ccache / sccache / zig build caches — rebuilt on next compile",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/.ccache", "\(home)/Library/Caches/sccache",
             "\(home)/.cache/sccache", "\(home)/.cache/zig"]
        },

        ScanDefinition(name: "JS Build Caches", stableName: "JS Build Caches", icon: "bolt.horizontal", color: .yellow,
            description: "Turborepo / Nx build caches — rebuilt on next build",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.turbo", "\(home)/.nx/cache"]
        },

        ScanDefinition(name: "IaC & Cloud CLI Caches", stableName: "IaC & Cloud CLI Caches", icon: "cloud", color: .blue,
            description: "Terraform / Helm / kube / AWS / gcloud cache data — rebuilt on demand",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/.terraform.d/plugin-cache", "\(home)/Library/Caches/helm",
             "\(home)/.kube/cache", "\(home)/.aws/cli/cache", "\(home)/.config/gcloud/logs"]
        },

        ScanDefinition(name: "ML / AI Framework Caches", stableName: "ML / AI Framework Caches", icon: "brain", color: .purple,
            description: "PyTorch / Whisper / Keras download caches — re-downloaded when needed",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.cache/torch", "\(home)/.cache/whisper", "\(home)/.keras/datasets"]
        },

        ScanDefinition(name: "Container / VM Images", stableName: "Container / VM Images", icon: "shippingbox", color: .orange,
            description: "Colima / Lima / minikube local VM data — deleting removes local VMs",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.colima", "\(home)/.lima", "\(home)/.minikube/cache"]
        },

        // ═══════════ APP / MEDIA / CLOUD CACHES (F7) — cache dirs only, regenerable ═══════════

        ScanDefinition(
            name: "WhatsApp Chat Media",
            stableName: "WhatsApp Chat Media",
            icon: "photo.stack.fill",
            color: .green,
            description: "All locally stored WhatsApp attachments — clear this media store to reclaim its full on-disk size",
            group: .applications,
            safetyLevel: .caution,
            defaultSelected: false,
            cleanupWarning: "This clears locally stored photos, videos, audio, documents, and other attachments from WhatsApp conversations. Message text and databases stay in place, but removed attachments may no longer open and may not be downloadable again. WhatsApp must be closed. Items move to Trash so you can restore them; empty Trash afterward to reclaim disk space.",
            associatedBundleIDs: CleanupManager.whatsAppBundleIDs,
            allowsBreakdownSelection: false
        ) {
            [CleanupManager.whatsAppMediaPath]
        },

        ScanDefinition(
            name: "WhatsApp Cache",
            stableName: "WhatsApp Cache",
            icon: "message.fill",
            color: .green,
            description: "WhatsApp thumbnails, link previews, and generated cache data — rebuilt as needed",
            group: .applications,
            safetyLevel: .safe,
            associatedBundleIDs: CleanupManager.whatsAppBundleIDs
        ) {
            [
                "\(home)/Library/Containers/net.whatsapp.WhatsApp/Data/Library/Caches",
                "\(CleanupManager.whatsAppSharedContainerPath)/Library/Caches",
            ]
        },

        ScanDefinition(
            name: "WhatsApp Logs",
            stableName: "WhatsApp Logs",
            icon: "doc.text.magnifyingglass",
            color: .green,
            description: "WhatsApp diagnostic logs — review first if you are troubleshooting the app",
            group: .applications,
            safetyLevel: .review,
            defaultSelected: false,
            associatedBundleIDs: CleanupManager.whatsAppBundleIDs
        ) {
            ["\(CleanupManager.whatsAppSharedContainerPath)/Logs"]
        },

        ScanDefinition(name: "WeChat Cache", stableName: "WeChat Cache", icon: "message", color: .green,
            description: "WeChat cached data — rebuilt automatically (chat history is not touched)",
            group: .applications, safetyLevel: .safe,
            associatedBundleIDs: ["com.tencent.xinWeChat"]) {
            ["\(home)/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches"]
        },

        ScanDefinition(name: "OneDrive Cache", stableName: "OneDrive Cache", icon: "cloud", color: .blue,
            description: "OneDrive local cache — re-synced from the cloud",
            group: .applications, safetyLevel: .safe,
            associatedBundleIDs: ["com.microsoft.OneDrive-mac"]) {
            ["\(home)/Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Caches"]
        },

        ScanDefinition(name: "Google Drive Cache", stableName: "Google Drive Cache", icon: "externaldrive.badge.icloud", color: .blue,
            description: "Google Drive streamed-file cache — files are downloaded again when needed",
            group: .applications, safetyLevel: .review, defaultSelected: false,
            cleanupWarning: "Google Drive must be closed. Offline files may need to be downloaded again.",
            associatedBundleIDs: ["com.google.drivefs"]) {
            CleanupManager.googleDriveContentCachePaths(
                in: "\(home)/Library/Application Support/Google/DriveFS"
            )
        },

        ScanDefinition(name: "Dropbox Cache", stableName: "Dropbox Cache", icon: "cloud", color: .blue,
            description: "Legacy Dropbox cache — review because it can contain pending or recently deleted material",
            group: .applications, safetyLevel: .review, defaultSelected: false) {
            // File Provider storage is globally protected: deleting a placeholder
            // there can delete the remote object. Keep only Dropbox's legacy,
            // vendor-documented cache outside CloudStorage.
            ["\(home)/Dropbox/.dropbox.cache"]
        },

        ScanDefinition(name: "Steam Shader Cache", stableName: "Steam Shader Cache", icon: "gamecontroller", color: .indigo,
            description: "Steam shader and HTTP caches — rebuilt while playing",
            group: .applications, safetyLevel: .safe,
            associatedBundleIDs: ["com.valvesoftware.steam"]) {
            ["\(home)/Library/Application Support/Steam/steamapps/shadercache",
             "\(home)/Library/Application Support/Steam/appcache/httpcache"]
        },

        ScanDefinition(name: "Podcasts Cache", stableName: "Podcasts Cache", icon: "mic", color: .purple,
            description: "Apple Podcasts cached episodes — re-downloaded on demand",
            group: .applications, safetyLevel: .review, defaultSelected: false,
            associatedBundleIDs: ["com.apple.podcasts"]) {
            ["\(home)/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Library/Cache"]
        },

        ScanDefinition(name: "Music Artwork Cache", stableName: "Music Artwork Cache", icon: "music.note", color: .pink,
            description: "Apple Music artwork cache — rebuilt automatically",
            group: .applications, safetyLevel: .safe,
            associatedBundleIDs: ["com.apple.Music"]) {
            ["\(home)/Library/Containers/com.apple.Music/Data/Library/Caches"]
        },
    ]

    // MARK: - Disk Usage

    func fetchDiskUsage() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()) else { return }
        let total = (attrs[.systemSize] as? Int64) ?? 0
        let free = (attrs[.systemFreeSize] as? Int64) ?? 0
        let used = total - free
        let url = URL(fileURLWithPath: "/")
        let purgeableBytes: Int64
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            purgeableBytes = available - free
        } else {
            purgeableBytes = 0
        }
        diskUsage = DiskUsageInfo(totalSpace: total, usedSpace: used, freeSpace: free, purgeableSpace: max(0, purgeableBytes))
    }

    // MARK: - Main Scan

    /// Scan for cleanable items. When `onlyGroup` is set, only that category group is
    /// (re)scanned and all other groups' existing results and selections are preserved.
    func scan(onlyGroup: CategoryGroup? = nil) async {
        let previousGroupCategories: [CleanupCategory] = await MainActor.run {
            guard let onlyGroup else { return [] }
            return categories.filter { $0.group == onlyGroup }
        }
        await MainActor.run {
            isScanning = true
            scanComplete = false
            cleanComplete = false
            if let onlyGroup {
                categories.removeAll { $0.group == onlyGroup }
            } else {
                categories = []
            }
            currentScanItem = ""
            scanProgress = 0
            scanErrors = []
            scanStartTime = Date()
        }
        cancelLock.withLock { $0 = false }
        resetScannedPaths()
        // For a single-group rescan, keep the dedup set aware of paths owned by the
        // preserved groups so the generic cache walkers don't reclaim them.
        if onlyGroup != nil {
            let preservedPaths = await MainActor.run { categories.flatMap(\.paths) }
            for path in preservedPaths { insertScannedPath(path) }
        }
        startMemoryMonitoring()

        fetchDiskUsage()
        checkFullDiskAccess()

        let scanDocker = settingScanDocker
        let scanNodeModules = settingScanNodeModules
        let scanUnusedApps = settingScanUnusedApps
        let scanIOSBackups = settingScanIOSBackups
        let scanIMessage = settingScanIMessageAttachments
        let scanBrokenSymlinks = settingScanBrokenSymlinks
        let scanScreenRecordings = settingScanScreenRecordings
        let scanVenvs = settingScanVirtualEnvironments
        let scanRustTargets = settingScanRustTargets
        let scanOldInstallers = settingScanOldInstallers
        let scanLargeFiles = settingScanLargeFiles

        // Phase 2 scanners, each tagged with the category group it produces so a
        // single-group rescan can run only the relevant ones. Built here (before Phase 1)
        // so the progress estimate can be derived from the actual filtered set.
        typealias SmartScan = (label: String, group: CategoryGroup, run: () async -> CleanupCategory?)
        var smartScans: [SmartScan] = [
            (String(localized: "Scanning stale temporary files..."), .system, { await self.scanStaleTemporaryFiles() }),
            (String(localized: "Scanning all app caches..."), .system, { await self.scanAllCaches() }),
            (String(localized: "Scanning shared container caches..."), .system, { await self.scanGroupContainerCaches() }),
            (String(localized: "Scanning system caches..."), .system, { await self.scanSystemCaches() }),
            (String(localized: "Scanning old screenshots..."), .system, { await self.scanOldScreenshots() }),
            (String(localized: "Scanning old downloads..."), .system, { await self.scanOldDownloads() }),
            (String(localized: "Scanning Electron app caches..."), .applications, { await self.scanElectronCaches() }),
            (String(localized: "Scanning Next.js build artifacts..."), .developer, { await self.scanNextJSBuildArtifacts() }),
        ]
        if scanOldInstallers {
            smartScans.append((String(localized: "Scanning installer files..."), .storage, { await self.scanInstallerFiles() }))
        }
        if scanDocker {
            smartScans.append((String(localized: "Scanning Docker images..."), .docker, { await self.scanDockerImages() }))
            smartScans.append((String(localized: "Scanning Docker containers..."), .docker, { await self.scanDockerStoppedContainers() }))
            smartScans.append((String(localized: "Scanning Docker build cache..."), .docker, { await self.scanDockerBuildCache() }))
        }
        smartScans.append((String(localized: "Scanning Ollama models..."), .developer, { await self.scanOllamaModels() }))
        if scanUnusedApps {
            smartScans.append((String(localized: "Scanning unused apps..."), .applications, { await self.scanUnusedApplications() }))
        }
        if scanNodeModules {
            smartScans.append((String(localized: "Scanning node_modules..."), .packageManagers, { await self.scanNodeModules() }))
        }
        smartScans.append((String(localized: "Scanning mail attachments..."), .system, { await self.scanMailAttachments() }))
        smartScans.append((String(localized: "Scanning app leftovers..."), .applications, { await self.scanOrphanedAppData() }))
        smartScans.append((String(localized: "Scanning iOS software updates..."), .system, { await self.scanIPSWFiles() }))
        if scanIOSBackups {
            smartScans.append((String(localized: "Scanning iOS backups..."), .system, { await self.scanIOSBackups() }))
        }
        if scanIMessage {
            smartScans.append((String(localized: "Scanning iMessage attachments..."), .system, { await self.scanIMessageAttachments() }))
        }
        if scanBrokenSymlinks {
            smartScans.append((String(localized: "Scanning broken symlinks..."), .system, { await self.scanBrokenSymlinks() }))
        }
        if scanScreenRecordings {
            smartScans.append((String(localized: "Scanning screen recordings..."), .storage, { await self.scanScreenRecordings() }))
        }
        if scanRustTargets {
            smartScans.append((String(localized: "Scanning Rust target dirs..."), .packageManagers, { await self.scanRustTargets() }))
        }
        if scanVenvs {
            smartScans.append((String(localized: "Scanning virtual environments..."), .packageManagers, { await self.scanVirtualEnvironments() }))
        }
        if scanLargeFiles {
            smartScans.append((String(localized: "Scanning large files..."), .largeFiles, { await self.scanLargeFiles() }))
        }

        // Restrict to a single group's scanners when doing an individual rescan.
        if let onlyGroup {
            smartScans = smartScans.filter { $0.group == onlyGroup }
        }
        let estimatedSmartScans = smartScans.count

        // Phase 1: Specific known-safe targets
        // First pass: collect all paths so we can detect parent-child overlaps
        let definitions: [(offset: Int, element: ScanDefinition)]
        if let onlyGroup {
            definitions = scanDefinitions.enumerated().filter {
                $0.element.group == onlyGroup
            }
        } else {
            definitions = Array(scanDefinitions.enumerated())
        }
        let totalDefs = definitions.count
        var allResolvedPaths: [[String]] = []
        for definition in scanDefinitions {
            // Keep the declared lexical root. Resolving a cache-root symlink here
            // would turn its destination into an authorized deletion territory.
            let declared = definition.pathResolver().map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
                    .precomposedStringWithCanonicalMapping
            }
            allResolvedPaths.append(declared)
        }

        for (index, indexedDefinition) in definitions.enumerated() {
            if cancelRequested { break }
            let definition = indexedDefinition.element
            let definitionIndex = indexedDefinition.offset

            await MainActor.run { currentScanItem = definition.name }

            let resolvedPaths = allResolvedPaths[definitionIndex]
            let fm = FileManager.default
            let existingPaths = resolvedPaths.filter {
                fm.fileExists(atPath: $0) &&
                    Self.deletionPolicy.isStableAllowedRoot($0)
            }

            if !existingPaths.isEmpty {
                var breakdown: [PathStat] = []
                var combinedSize: Int64 = 0
                var combinedCount: Int = 0
                var excludedPaths: [String] = []

                for path in existingPaths {
                    if cancelRequested { break }
                    // Check if this path is a parent of another scan's path — if so,
                    // exclude the child from this scan's size calculation
                    var childPaths: [String] = []
                    for (otherIdx, otherPaths) in allResolvedPaths.enumerated()
                    where otherIdx != definitionIndex {
                        for otherPath in otherPaths where otherPath.hasPrefix(path + "/") {
                            childPaths.append(otherPath)
                        }
                    }
                    excludedPaths.append(contentsOf: childPaths)

                    let (size, count): (Int64, Int)
                    if childPaths.isEmpty {
                        (size, count) = await directorySize(path)
                    } else {
                        (size, count) = await directorySizeExcluding(path, excludedPaths: childPaths)
                    }

                    if size > 0 {
                        breakdown.append(PathStat(path: path, size: size, fileCount: count))
                        combinedSize += size
                        combinedCount += count
                        insertScannedPath(path)
                    }
                }

                if combinedSize > 0 {
                    // Only authorize roots that were successfully measured and shown.
                    // A sibling path that was unreadable (or measured as empty) must
                    // never inherit deletion permission from another populated root.
                    let measuredPaths = breakdown.map(\.path)
                    let category = CleanupCategory(
                        name: definition.name, stableName: definition.stableName, icon: definition.icon,
                        color: definition.color, description: definition.description,
                        cleanupWarning: definition.cleanupWarning,
                        group: definition.group, safetyLevel: definition.safetyLevel,
                        paths: measuredPaths,
                        // Confine deletion to exactly the definition's resolved target
                        // dirs — the scan may only ever remove children of these.
                        allowedRoots: measuredPaths,
                        excludedPaths: Array(Set(excludedPaths)).sorted(),
                        associatedBundleIDs: definition.associatedBundleIDs,
                        allowsDirectHomeItems: definition.allowsDirectHomeItems,
                        requiresPermanentDeletion: definition.requiresPermanentDeletion,
                        breakdown: breakdown,
                        deleteChildrenOnly: true,
                        allowsBreakdownSelection: definition.allowsBreakdownSelection,
                        size: combinedSize, fileCount: combinedCount,
                        isSelected: definition.defaultSelected
                    )
                    await MainActor.run { categories.append(category) }
                }
            }

            await MainActor.run {
                scanProgress = Double(index + 1) / Double(totalDefs + estimatedSmartScans)
            }
        }

        // Phase 2: Comprehensive walkers + smart scans (built and filtered above).
        let totalSmartScans = smartScans.count
        for (index, entry) in smartScans.enumerated() {
            if cancelRequested { break }
            await MainActor.run { currentScanItem = entry.label }

            if let scannedCategory = await entry.run(),
               let category = Self.filterUnsafeSmartScanPaths(scannedCategory) {
                await MainActor.run { categories.append(category) }
            }

            await MainActor.run {
                scanProgress = Double(totalDefs + index + 1) / Double(totalDefs + totalSmartScans)
            }
        }

        if cancelRequested {
            // Keep partial results instead of discarding everything
            let scanDuration = Date().timeIntervalSince(scanStartTime ?? Date())
            await MainActor.run {
                if let onlyGroup {
                    // A cancelled refresh must not replace known-good results with an
                    // incomplete group. Restore that group's exact prior state,
                    // including selections and per-file choices.
                    categories.removeAll { $0.group == onlyGroup }
                    categories.append(contentsOf: previousGroupCategories)
                }
                isScanning = false
                scanComplete = !categories.isEmpty
                currentScanItem = ""
                scanProgress = 0
                if !categories.isEmpty {
                    categories.sort { $0.size > $1.size }
                    lastScanSummary = ScanSummary(
                        totalCategories: categories.count, totalSize: overallSize,
                        totalFiles: categories.reduce(0) { $0 + $1.fileCount },
                        scanDuration: scanDuration, timestamp: Date(),
                        wasPartial: true
                    )
                }
            }
            await persistLatestScanAudit(scope: onlyGroup)
            // Release scan-only data
            resetScannedPaths()
            stopMemoryMonitoring()
            return
        }

        let scanDuration = Date().timeIntervalSince(scanStartTime ?? Date())
        await MainActor.run {
            categories.sort { $0.size > $1.size }
            isScanning = false; scanComplete = true
            currentScanItem = ""; scanProgress = 1.0
            lastScanSummary = ScanSummary(
                totalCategories: categories.count, totalSize: overallSize,
                totalFiles: categories.reduce(0) { $0 + $1.fileCount },
                scanDuration: scanDuration, timestamp: Date(),
                wasPartial: false
            )
        }
        await persistLatestScanAudit(scope: onlyGroup)
        // Release scan-only data
        resetScannedPaths()
        stopMemoryMonitoring()
    }

    /// Keep one local snapshot of the latest scan so a result can be audited after
    /// SparkClean quits. The file is replaced atomically instead of accumulating an
    /// unbounded scan history.
    private func persistLatestScanAudit(scope: CategoryGroup?) async {
        let snapshot = await MainActor.run {
            let summary = lastScanSummary
            let disk = diskUsage.map {
                ScanAuditSnapshot.DiskUsage(
                    totalSpace: $0.totalSpace,
                    usedSpace: $0.usedSpace,
                    freeSpace: $0.freeSpace,
                    purgeableSpace: $0.purgeableSpace
                )
            }
            let categorySnapshots = categories.map { category in
                ScanAuditSnapshot.Category(
                    name: category.stableName,
                    group: category.group.rawValue,
                    safetyLevel: category.safetyLevel.rawValue,
                    description: category.description,
                    cleanupWarning: category.cleanupWarning,
                    size: category.size,
                    fileCount: category.fileCount,
                    isSelected: category.isSelected,
                    selectedSize: category.selectedSize,
                    selectedFileCount: category.selectedFileCount,
                    paths: category.paths,
                    allowedRoots: category.allowedRoots,
                    excludedPaths: category.excludedPaths,
                    associatedBundleIDs: category.associatedBundleIDs,
                    deleteChildrenOnly: category.deleteChildrenOnly,
                    allowsBreakdownSelection: category.allowsBreakdownSelection,
                    entries: category.breakdown.map {
                        ScanAuditSnapshot.Entry(
                            path: $0.path,
                            size: $0.size,
                            fileCount: $0.fileCount,
                            isSelected: $0.isSelected,
                            displayName: $0.displayName
                        )
                    }
                )
            }
            return ScanAuditSnapshot(
                schemaVersion: 1,
                generatedAt: summary?.timestamp ?? Date(),
                appVersion: Self.appVersionString,
                scope: scope?.rawValue ?? "All Categories",
                wasPartial: summary?.wasPartial ?? false,
                scanDuration: summary?.scanDuration ?? 0,
                scanErrors: scanErrors,
                settings: [
                    "scanDocker": String(settingScanDocker),
                    "scanNodeModules": String(settingScanNodeModules),
                    "scanUnusedApps": String(settingScanUnusedApps),
                    "scanIOSBackups": String(settingScanIOSBackups),
                    "scanIMessageAttachments": String(settingScanIMessageAttachments),
                    "scanBrokenSymlinks": String(settingScanBrokenSymlinks),
                    "scanScreenRecordings": String(settingScanScreenRecordings),
                    "scanVirtualEnvironments": String(settingScanVirtualEnvironments),
                    "scanRustTargets": String(settingScanRustTargets),
                    "scanOldInstallers": String(settingScanOldInstallers),
                    "scanLargeFiles": String(settingScanLargeFiles),
                    "largeFileThresholdMB": String(settingLargeFileThresholdMB),
                ],
                diskUsage: disk,
                categories: categorySnapshots
            )
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                _ = ScanAuditLogger.shared.write(snapshot)
                continuation.resume()
            }
        }
    }

    /// Smart scanners discover concrete roots dynamically. Keep their UI and cleanup
    /// eligibility aligned by applying the same deletion policy before a result is
    /// shown. This drops protected/package paths and anything reached through a
    /// user-created symlink. CLI resources use non-filesystem identifiers and are
    /// validated by their dedicated command paths instead.
    private static func filterUnsafeSmartScanPaths(
        _ scanned: CleanupCategory
    ) -> CleanupCategory? {
        guard !scanned.isDockerResource, !scanned.isOllamaResource else {
            return scanned
        }
        var category = scanned
        let policy = DeletionPolicy(
            allowsApplicationBundles: category.allowsApplicationBundles,
            allowsDirectHomeItems: category.allowsDirectHomeItems,
            allowsSymbolicLinkItems: category.allowsSymbolicLinkItems
        )
        let declaredRoots = category.allowedRoots.isEmpty
            ? category.paths
            : category.allowedRoots
        let stablePaths = category.paths.filter {
            policy.validate($0, allowedRoots: declaredRoots) &&
                (!category.allowedRoots.isEmpty ||
                    policy.isStableAllowedRoot($0))
        }
        guard !stablePaths.isEmpty else { return nil }
        let stableSet = Set(stablePaths)
        category.paths = stablePaths
        if !category.allowedRoots.isEmpty {
            category.allowedRoots = category.allowedRoots.filter {
                policy.isStableAllowedRoot($0)
            }
            guard !category.allowedRoots.isEmpty else { return nil }
        }
        if !category.breakdown.isEmpty {
            category.breakdown.removeAll { !stableSet.contains($0.path) }
            category.size = category.breakdown.reduce(0) { $0 + $1.size }
            category.fileCount = category.breakdown.reduce(0) { $0 + $1.fileCount }
        }
        return category.hasSelectedContent || category.size > 0 || category.fileCount > 0
            ? category
            : nil
    }

    func cancelScan() { cancelLock.withLock { $0 = true } }

    private var cancelRequested: Bool {
        cancelLock.withLock { $0 }
    }

    private func insertScannedPath(_ path: String) {
        scannedPathsLock.withLock { _ = $0.insert(path) }
    }

    private func overlapsScannedPath(_ path: String) -> Bool {
        scannedPathsLock.withLock { scanned in
            scanned.contains {
                $0 == path || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/")
            }
        }
    }

    private func scannedPathsSnapshot() -> Set<String> {
        scannedPathsLock.withLock { $0 }
    }

    private func resetScannedPaths() {
        scannedPathsLock.withLock { $0.removeAll() }
    }

    private func checkFullDiskAccess() {
        let fm = FileManager.default
        let protectedPaths = [
            "\(Self.home)/Library/Mail",
            "\(Self.home)/Library/Messages",
            "\(Self.home)/Library/Safari",
        ]
        for path in protectedPaths where fm.fileExists(atPath: path) {
            // POSIX mode bits can say a protected directory is readable even when
            // macOS privacy controls reject listing it. Actually enumerate one.
            hasFullDiskAccess = (try? fm.contentsOfDirectory(atPath: path)) != nil
            return
        }
        hasFullDiskAccess = true
    }

    // MARK: - Clean

    func clean(attemptToQuitAssociatedApps: Bool = false) async {
        await MainActor.run {
            isCleaning = true
            cleanProgress = 0
            cleanErrors = []
            cleanSuccessCount = 0
            cleanFailCount = 0
            lastCleanedSize = 0
            lastMovedToTrashSize = 0
            lastPermanentlyDeletedSize = 0
            lastCleanedCount = 0
        }

        let selectedCategories = categories.filter {
            $0.isSelected && $0.hasSelectedContent &&
                (pendingCleanGroup == nil || $0.group == pendingCleanGroup)
        }
        let preferTrash = settingPreferTrash
        let totalCategories = selectedCategories.count
        guard totalCategories > 0 else {
            await MainActor.run {
                pendingCleanGroup = nil
                isCleaning = false
                cleanComplete = true
            }
            return
        }

        let selectedBundleIDs = Set(selectedCategories.flatMap(\.associatedBundleIDs))
        if attemptToQuitAssociatedApps, !selectedBundleIDs.isEmpty {
            await MainActor.run {
                for app in NSWorkspace.shared.runningApplications
                where app.bundleIdentifier.map({
                    selectedBundleIDs.contains($0)
                }) == true {
                    _ = app.terminate()
                }
            }

            // `terminate()` is asynchronous. Wait briefly without blocking the main
            // actor, then let the normal hard-skip below protect any app that refused
            // or failed to quit.
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let anyStillRunning = await MainActor.run {
                    NSWorkspace.shared.runningApplications.contains {
                        $0.bundleIdentifier.map {
                            selectedBundleIDs.contains($0)
                        } == true
                    }
                }
                if !anyStillRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        // Query AppKit on the main actor. Associated categories are never cleaned while
        // their app is live; privacy databases are a hard block, and cache categories
        // are skipped with an actionable message.
        let runningApplications: [String: String] = await MainActor.run {
            var result: [String: String] = [:]
            for app in NSWorkspace.shared.runningApplications {
                guard let bundleID = app.bundleIdentifier else { continue }
                result[bundleID] = app.localizedName ?? bundleID
            }
            return result
        }

        let recorder = CleanupSessionRecorder(
            appVersion: Self.appVersionString,
            trashMode: preferTrash,
            store: Self.manifestStore
        )
        var actualCleanedSize: Int64 = 0
        var actualMovedToTrashSize: Int64 = 0
        var actualPermanentlyDeletedSize: Int64 = 0
        var successfulCategoryIDs = Set<UUID>()
        var affectedCategoryIDs = Set<UUID>()
        var partiallyRemovedPaths: [UUID: Set<String>] = [:]
        var residualCategoryStates: [
            UUID: (paths: [String], breakdown: [PathStat])
        ] = [:]

        for (catIndex, category) in selectedCategories.enumerated() {
            let runningNames = Set(category.associatedBundleIDs.compactMap {
                runningApplications[$0]
            }).sorted()
            if !runningNames.isEmpty {
                let names = runningNames.joined(separator: ", ")
                let message = category.group == .privacy
                    ? String(localized: "\(category.name): Blocked because \(names) is running. Quit the app before cleaning live privacy databases.")
                    : String(localized: "\(category.name): Skipped because \(names) is running. Quit the app and try again.")
                await MainActor.run {
                    cleanFailCount += 1
                    cleanErrors.append(message)
                    cleanProgress = Double(catIndex + 1) / Double(totalCategories)
                }
                continue
            }

            if category.isDockerResource, let command = category.dockerCleanCommand {
                let outcome = await runDockerClean(command: command)
                let success = outcome.succeeded
                if success {
                    successfulCategoryIDs.insert(category.id)
                    affectedCategoryIDs.insert(category.id)
                    let reclaimedSize = outcome.reclaimedSize ?? 0
                    actualCleanedSize += reclaimedSize
                    actualPermanentlyDeletedSize += reclaimedSize
                    DeletionAuditLogger.shared.recordEvent(
                        "docker \(command.joined(separator: " "))",
                        category: category.stableName,
                        sessionID: recorder.sessionID,
                        appVersion: Self.appVersionString
                    )
                }
                await MainActor.run {
                    if success {
                        cleanSuccessCount += 1
                    } else {
                        cleanFailCount += 1
                        cleanErrors.append(String(localized: "Failed to clean Docker resource: \(category.name)"))
                    }
                    cleanProgress = Double(catIndex + 1) / Double(totalCategories)
                }
                continue
            }

            if category.isOllamaResource {
                let outcome = await runOllamaClean(category: category)
                let selectedModels = category.breakdown.filter(\.isSelected).map(\.path)
                let success = outcome.failedModels.isEmpty &&
                    outcome.removedModels.count == selectedModels.count
                let removedStats = category.breakdown.filter {
                    outcome.removedModels.contains($0.path)
                }
                let removedSize = removedStats.reduce(0) { $0 + $1.size }
                actualCleanedSize += removedSize
                actualPermanentlyDeletedSize += removedSize
                if !outcome.removedModels.isEmpty {
                    affectedCategoryIDs.insert(category.id)
                }
                partiallyRemovedPaths[category.id, default: []].formUnion(
                    outcome.removedModels
                )
                for model in outcome.removedModels.sorted() {
                    DeletionAuditLogger.shared.recordEvent(
                        "ollama rm \(model)",
                        category: category.stableName,
                        sessionID: recorder.sessionID,
                        appVersion: Self.appVersionString
                    )
                }
                if success {
                    successfulCategoryIDs.insert(category.id)
                }
                await MainActor.run {
                    if success {
                        cleanSuccessCount += 1
                    } else {
                        cleanFailCount += 1
                        cleanErrors.append(contentsOf: outcome.failedModels.map {
                            String(localized: "\(category.name): Failed to remove \($0)")
                        })
                    }
                    cleanProgress = Double(catIndex + 1) / Double(totalCategories)
                }
                continue
            }

            let paths = category.paths
            let deleteChildrenOnly = category.deleteChildrenOnly
            let categoryName = category.name
            let usePerFile = category.hasPerFileSelection
            let effectivePaths = usePerFile ? category.selectedPaths : paths
            // Territory this category may delete within: its declared allowedRoots, or
            // (when unset) its full declared paths. Every concrete deletion — including
            // children discovered at delete time — must fall inside this.
            let effectiveAllowedRoots = category.allowedRoots.isEmpty ? paths : category.allowedRoots
            let excludedPaths = category.excludedPaths
            let useTrashForCategory = !category.requiresPermanentDeletion &&
                (preferTrash || category.safetyLevel == .caution)
            var knownSizes: [String: Int64] = [:]
            var knownIdentities: [String: FileRemover.FileIdentity] = [:]
            var knownStats: [String: PathStat] = [:]
            for stat in category.breakdown {
                knownSizes[stat.path] = stat.size
                knownStats[stat.path] = stat
                if let identity = stat.fileIdentity {
                    knownIdentities[stat.path] = identity
                }
            }

            let result: (
                errors: [String],
                removals: [FileRemover.Removal],
                vanishedPaths: Set<String>,
                residualPaths: [String],
                residualBreakdown: [PathStat]
            ) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let fm = FileManager.default
                    var localErrors: [String] = []
                    var needsAdmin: [FileRemover.AdminRequest] = []
                    var removals: [FileRemover.Removal] = []
                    var failedConcretePaths = Set<String>()
                    var vanishedPaths = Set<String>()

                    // Single deletion service — same safety rules, trash-capture, and
                    // records as every other surface.
                    let policy = DeletionPolicy(
                        allowsApplicationBundles: category.allowsApplicationBundles,
                        allowsDirectHomeItems: category.allowsDirectHomeItems,
                        allowsSymbolicLinkItems: category.allowsSymbolicLinkItems
                    )
                    let remover = FileRemover(policy: policy, useTrash: useTrashForCategory)

                    func record(_ removal: FileRemover.Removal) {
                        removals.append(removal)
                        recorder.record(removal, category: category.stableName)
                        DeletionAuditLogger.shared.record(
                            [removal],
                            category: category.stableName,
                            sessionID: recorder.sessionID,
                            appVersion: Self.appVersionString,
                            trashMode: useTrashForCategory
                        )
                    }

                    func deleteItem(
                        at url: URL,
                        knownSize: Int64? = nil,
                        expectedIsDirectory: Bool? = nil,
                        expectedIdentity: FileRemover.FileIdentity? = nil
                    ) {
                        switch remover.remove(
                            url.path,
                            allowedRoots: effectiveAllowedRoots,
                            knownSize: knownSize,
                            expectedIsDirectory: expectedIsDirectory,
                            expectedIdentity: expectedIdentity
                        ) {
                        case .removed(let removal):
                            record(removal)
                        case .blocked(let reason):
                            failedConcretePaths.insert(url.path)
                            let itemName = AppLocalization.isolateTechnicalText(url.lastPathComponent)
                            localErrors.append(String(localized: "\(categoryName): Blocked \(itemName) — \(reason)"))
                        case .skippedICloud:
                            failedConcretePaths.insert(url.path)
                            let itemName = AppLocalization.isolateTechnicalText(url.lastPathComponent)
                            localErrors.append(String(localized: "\(categoryName): Skipped iCloud-synced item — \(itemName)"))
                        case .needsAdmin(let path):
                            needsAdmin.append(FileRemover.AdminRequest(
                                path: path,
                                allowedRoots: effectiveAllowedRoots,
                                knownSize: knownSize,
                                expectedIsDirectory: expectedIsDirectory,
                                expectedIdentity: expectedIdentity
                            ))
                        case .failed(let message):
                            if message == FileRemover.itemNoLongerExistsError {
                                vanishedPaths.insert(url.path)
                            } else {
                                failedConcretePaths.insert(url.path)
                            }
                            let itemName = AppLocalization.isolateTechnicalText(url.lastPathComponent)
                            localErrors.append(String(localized: "\(categoryName): Failed to remove \(itemName) — \(message)"))
                        }
                    }

                    if deleteChildrenOnly {
                        for path in effectivePaths {
                            if let expectedIdentity = knownIdentities[path],
                               FileRemover.fileIdentity(at: path) != expectedIdentity {
                                failedConcretePaths.insert(path)
                                let itemName = AppLocalization.isolateTechnicalText(
                                    (path as NSString).lastPathComponent
                                )
                                localErrors.append(
                                    String(localized: "\(categoryName): Blocked \(itemName) — a different item replaced the scanned root")
                                )
                                continue
                            }
                            var isDirectory: ObjCBool = false
                            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
                                vanishedPaths.insert(path)
                                let itemName = AppLocalization.isolateTechnicalText(
                                    (path as NSString).lastPathComponent
                                )
                                localErrors.append(String(localized: "\(categoryName): Item no longer exists — \(itemName)"))
                                continue
                            }
                            if isDirectory.boolValue {
                                let contents: [String]
                                do {
                                    contents = try fm.contentsOfDirectory(atPath: path)
                                } catch {
                                    failedConcretePaths.insert(path)
                                    let itemName = AppLocalization.isolateTechnicalText(
                                        (path as NSString).lastPathComponent
                                    )
                                    localErrors.append(String(localized: "\(categoryName): Could not read \(itemName) — \(error.localizedDescription)"))
                                    continue
                                }
                                for item in contents {
                                    autoreleasepool {
                                        let fullPath = (path as NSString).appendingPathComponent(item)
                                        guard !Self.path(
                                            fullPath,
                                            overlapsAny: excludedPaths
                                        ) else {
                                            return
                                        }
                                        let identity = FileRemover.fileIdentity(at: fullPath)
                                        let size = knownSizes[fullPath] ?? Self.directorySizeSync(fullPath).0
                                        var childIsDirectory: ObjCBool = false
                                        let expectedType = fm.fileExists(
                                            atPath: fullPath,
                                            isDirectory: &childIsDirectory
                                        ) ? childIsDirectory.boolValue : nil
                                        deleteItem(
                                            at: URL(fileURLWithPath: fullPath),
                                            knownSize: size,
                                            expectedIsDirectory: expectedType,
                                            expectedIdentity: identity
                                        )
                                    }
                                }
                            } else {
                                // Some predefined review categories contain individual
                                // files (history DBs, shell history). `deleteChildrenOnly`
                                // means preserve directory roots, not silently skip files.
                                deleteItem(
                                    at: URL(fileURLWithPath: path),
                                    knownSize: knownSizes[path],
                                    expectedIsDirectory: false,
                                    expectedIdentity: knownIdentities[path]
                                )
                            }
                        }
                    } else {
                        for path in effectivePaths {
                            var isDirectory: ObjCBool = false
                            let expectedType = fm.fileExists(
                                atPath: path,
                                isDirectory: &isDirectory
                            ) ? isDirectory.boolValue : nil
                            deleteItem(
                                at: URL(fileURLWithPath: path),
                                knownSize: knownSizes[path],
                                expectedIsDirectory: expectedType,
                                expectedIdentity: knownIdentities[path]
                            )
                        }
                    }

                    if !needsAdmin.isEmpty {
                        let admin = remover.moveToTrashWithAdministratorPrivileges(
                            needsAdmin,
                            confirmationTitle: String(localized: "\(categoryName) Needs Administrator Access")
                        )
                        for removal in admin.removals {
                            record(removal)
                        }
                        let removedByAdmin = Set(admin.removals.map(\.originalPath))
                        for request in needsAdmin
                        where !removedByAdmin.contains(request.path) {
                            if FileRemover.fileIdentity(at: request.path) == nil {
                                vanishedPaths.insert(request.path)
                            } else {
                                failedConcretePaths.insert(request.path)
                            }
                        }
                        localErrors.append(contentsOf: admin.failures.map {
                            String(localized: "\(categoryName): \($0)")
                        })
                        if admin.wasCancelled {
                            localErrors.append(String(localized: "\(categoryName): Administrator cleanup was cancelled"))
                        }
                    }

                    var residualPaths: [String] = []
                    var residualBreakdown: [PathStat] = []
                    if !localErrors.isEmpty && !usePerFile {
                        for path in paths {
                            guard FileRemover.fileIdentity(at: path) != nil else {
                                continue
                            }
                            let measured = excludedPaths.isEmpty
                                ? Self.directorySizeSync(path)
                                : Self.directorySizeSyncExcluding(
                                    path,
                                    excludedPaths: excludedPaths
                                )
                            let failedWithinPath = failedConcretePaths.contains {
                                $0 == path || $0.hasPrefix(path + "/")
                            }
                            guard measured.0 > 0 || measured.1 > 0 || failedWithinPath else {
                                continue
                            }
                            let previous = knownStats[path]
                            let hasMeasuredContent = measured.0 > 0 || measured.1 > 0
                            residualPaths.append(path)
                            residualBreakdown.append(PathStat(
                                path: path,
                                size: hasMeasuredContent
                                    ? measured.0
                                    : (previous?.size ?? 0),
                                fileCount: hasMeasuredContent
                                    ? measured.1
                                    : (previous?.fileCount ?? 0),
                                children: previous?.children ?? [],
                                lastAccessed: previous?.lastAccessed,
                                isSelected: previous?.isSelected ?? true,
                                displayName: previous?.displayName,
                                fileIdentity: previous?.fileIdentity
                            ))
                        }
                    }

                    continuation.resume(returning: (
                        localErrors,
                        removals,
                        vanishedPaths,
                        residualPaths,
                        residualBreakdown
                    ))
                }
            }

            let errors = result.errors
            for removal in result.removals {
                actualCleanedSize += removal.size
                if removal.trashedPath == nil {
                    actualPermanentlyDeletedSize += removal.size
                } else {
                    actualMovedToTrashSize += removal.size
                }
            }
            if !result.removals.isEmpty {
                affectedCategoryIDs.insert(category.id)
            }
            partiallyRemovedPaths[category.id, default: []].formUnion(
                result.removals.map(\.originalPath)
            )
            partiallyRemovedPaths[category.id, default: []].formUnion(
                result.vanishedPaths
            )
            if errors.isEmpty {
                successfulCategoryIDs.insert(category.id)
            } else if !usePerFile {
                residualCategoryStates[category.id] = (
                    result.residualPaths,
                    result.residualBreakdown
                )
            }

            await MainActor.run {
                if errors.isEmpty {
                    cleanSuccessCount += 1
                } else {
                    cleanFailCount += 1
                    cleanErrors.append(contentsOf: errors)
                }
                cleanProgress = Double(catIndex + 1) / Double(totalCategories)
            }
        }

        recorder.finish()
        DeletionAuditLogger.shared.prune()

        await MainActor.run {
            pendingCleanGroup = nil
            isCleaning = false
            cleanComplete = true
            lastCleanedSize = actualCleanedSize
            lastMovedToTrashSize = actualMovedToTrashSize
            lastPermanentlyDeletedSize = actualPermanentlyDeletedSize
            lastCleanedCount = affectedCategoryIDs.count

            // Remove only results that actually succeeded. Failed/blocked categories
            // remain visible for review or retry instead of being falsely reported as
            // cleaned and disappearing from the UI.
            for i in categories.indices {
                let categoryID = categories[i].id
                if successfulCategoryIDs.contains(categoryID) {
                    if categories[i].hasPerFileSelection {
                        let remainingBreakdown = categories[i].breakdown.filter { !$0.isSelected }
                        categories[i].breakdown = remainingBreakdown
                        if !categories[i].isOllamaResource {
                            categories[i].paths = remainingBreakdown.map(\.path)
                        }
                        categories[i].size = remainingBreakdown.reduce(0) { $0 + $1.size }
                        categories[i].fileCount = remainingBreakdown.reduce(0) { $0 + $1.fileCount }
                    } else {
                        categories[i].size = 0
                        categories[i].fileCount = 0
                        categories[i].breakdown = []
                    }
                } else if let residual = residualCategoryStates[categoryID] {
                    categories[i].paths = residual.paths
                    if !categories[i].allowedRoots.isEmpty {
                        categories[i].allowedRoots = residual.paths
                    }
                    categories[i].breakdown = residual.breakdown
                    categories[i].size = residual.breakdown.reduce(0) { $0 + $1.size }
                    categories[i].fileCount = residual.breakdown.reduce(0) {
                        $0 + $1.fileCount
                    }
                } else if let removed = partiallyRemovedPaths[categoryID], !removed.isEmpty,
                          categories[i].hasPerFileSelection {
                    categories[i].breakdown.removeAll { removed.contains($0.path) }
                    if !categories[i].isOllamaResource {
                        categories[i].paths = categories[i].breakdown.map(\.path)
                    }
                    categories[i].size = categories[i].breakdown.reduce(0) { $0 + $1.size }
                    categories[i].fileCount = categories[i].breakdown.reduce(0) { $0 + $1.fileCount }
                }
            }
            categories.removeAll(where: { $0.size == 0 && $0.fileCount == 0 })
        }
    }

    // MARK: - Size Calculation

    private func directorySize(_ path: String) async -> (Int64, Int) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                continuation.resume(returning: Self.directorySizeSync(
                    path,
                    isCancelled: { self?.cancelRequested ?? true }
                ))
            }
        }
    }

    private func directorySizeExcluding(_ path: String, excludedPaths: [String]) async -> (Int64, Int) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                continuation.resume(returning: Self.directorySizeSyncExcluding(
                    path,
                    excludedPaths: excludedPaths,
                    isCancelled: { self?.cancelRequested ?? true }
                ))
            }
        }
    }

    private static func directorySizeSync(
        _ path: String,
        isCancelled: () -> Bool = { false }
    ) -> (Int64, Int) {
        let fm = FileManager.default
        var accounting = CloneAwareSizeAccumulator()
        var count = 0

        guard let rootValues = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [
                .isSymbolicLinkKey, .isUbiquitousItemKey, .isVolumeKey,
            ]),
            rootValues.isSymbolicLink != true,
            rootValues.isUbiquitousItem != true,
            rootValues.isVolume != true
        else {
            return (0, 0)
        }

        // Handle individual files (not directories)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            let url = URL(fileURLWithPath: path)
            if let rv = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                return (Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0), 1)
            }
            return (0, 0)
        }

        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey,
            .isSymbolicLinkKey, .isUbiquitousItemKey,
            .fileContentIdentifierKey, .mayShareFileContentKey,
        ]
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else {
            return (0, 0)
        }

        while let obj = enumerator.nextObject() {
            if isCancelled() { break }
            guard let fileURL = obj as? URL else { continue }
            autoreleasepool {
                guard let rv = try? fileURL.resourceValues(
                    forKeys: keys
                ),
                    rv.isRegularFile == true,
                    rv.isSymbolicLink != true,
                    rv.isUbiquitousItem != true
                else { return }
                if rv.isRegularFile == true {
                    accounting.add(
                        allocatedSize: Int64(
                            rv.totalFileAllocatedSize ?? rv.fileSize ?? 0
                        ),
                        mayShareFileContent: rv.mayShareFileContent,
                        fileContentIdentifier: rv.fileContentIdentifier
                    )
                    count += 1
                }
            }
        }

        return (accounting.estimatedUniqueSize, count)
    }

    private static func directorySizeSyncExcluding(
        _ path: String,
        excludedPaths: [String],
        isCancelled: () -> Bool = { false }
    ) -> (Int64, Int) {
        let fm = FileManager.default
        var accounting = CloneAwareSizeAccumulator()
        var count = 0

        guard let rootValues = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [
                .isSymbolicLinkKey, .isUbiquitousItemKey, .isVolumeKey,
            ]),
            rootValues.isSymbolicLink != true,
            rootValues.isUbiquitousItem != true,
            rootValues.isVolume != true
        else {
            return (0, 0)
        }

        // Handle individual files (not directories)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            let url = URL(fileURLWithPath: path)
            if let rv = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                return (Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0), 1)
            }
            return (0, 0)
        }

        let excludedWithSlash = excludedPaths.map { $0 + "/" }

        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey,
            .isSymbolicLinkKey, .isUbiquitousItemKey,
            .fileContentIdentifierKey, .mayShareFileContentKey,
        ]
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else {
            return (0, 0)
        }

        let excludedSet = Set(excludedPaths)
        while let obj = enumerator.nextObject() {
            if isCancelled() { break }
            guard let fileURL = obj as? URL else { continue }
            let filePath = fileURL.path
            // Skip excluded subtrees entirely — skip descendants for performance
            if excludedSet.contains(filePath) || excludedWithSlash.contains(where: { filePath.hasPrefix($0) }) {
                enumerator.skipDescendants()
                continue
            }
            autoreleasepool {
                guard let rv = try? fileURL.resourceValues(
                    forKeys: keys
                ),
                    rv.isRegularFile == true,
                    rv.isSymbolicLink != true,
                    rv.isUbiquitousItem != true
                else { return }
                if rv.isRegularFile == true {
                    accounting.add(
                        allocatedSize: Int64(
                            rv.totalFileAllocatedSize ?? rv.fileSize ?? 0
                        ),
                        mayShareFileContent: rv.mayShareFileContent,
                        fileContentIdentifier: rv.fileContentIdentifier
                    )
                    count += 1
                }
            }
        }

        return (accounting.estimatedUniqueSize, count)
    }

    // MARK: - Stale temporary files

    struct StaleTemporaryFileScanResult {
        var breakdown: [PathStat] = []
        var wasCancelled = false
        var hitWatchdog = false
    }

    /// Finds only stale regular files directly inside sanctioned temporary roots.
    /// It deliberately ignores directories, sockets, symlinks, cloud items, and
    /// recent files; blanket deletion of a live temp tree can crash running apps.
    static func findStaleTemporaryFiles(
        roots: [String],
        olderThan threshold: Date,
        maximumEntries: Int = 10_000,
        isCancelled: () -> Bool = { false }
    ) -> StaleTemporaryFileScanResult {
        let fm = FileManager.default
        let canonicalRoots = Set(roots.map {
            ($0 as NSString).resolvingSymlinksInPath
        })
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey,
            .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey,
        ]
        var result = StaleTemporaryFileScanResult()
        var visited = 0

        outer: for root in canonicalRoots.sorted() {
            if isCancelled() {
                result.wasCancelled = true
                break
            }
            guard let entries = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries {
                if isCancelled() {
                    result.wasCancelled = true
                    break outer
                }
                visited += 1
                if visited > maximumEntries {
                    result.hitWatchdog = true
                    break outer
                }
                autoreleasepool {
                    guard let values = try? url.resourceValues(forKeys: keys),
                          values.isRegularFile == true,
                          values.isSymbolicLink != true,
                          values.isUbiquitousItem != true,
                          let modified = values.contentModificationDate,
                          modified < threshold else {
                        return
                    }
                    let size = Int64(
                        values.totalFileAllocatedSize ?? values.fileSize ?? 0
                    )
                    guard size > 0 else { return }
                    result.breakdown.append(PathStat(
                        path: url.path,
                        size: size,
                        fileCount: 1,
                        lastAccessed: modified
                    ))
                }
            }
        }

        result.breakdown.sort {
            $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size
        }
        return result
    }

    private func scanStaleTemporaryFiles() async -> CleanupCategory? {
        let roots = [
            NSTemporaryDirectory(), "/tmp", "/private/var/tmp", "/private/tmp",
        ]
        let threshold = Date().addingTimeInterval(-7 * ScanConstants.secondsPerDay)
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.findStaleTemporaryFiles(
                    roots: roots,
                    olderThan: threshold,
                    isCancelled: { self.cancelRequested }
                ))
            }
        }
        guard !result.breakdown.isEmpty else { return nil }
        let paths = result.breakdown.map(\.path)
        let totalSize = result.breakdown.reduce(0 as Int64) { $0 + $1.size }
        let suffix = result.wasCancelled
            ? String(localized: " · partial scan (cancelled)")
            : (result.hitWatchdog ? String(localized: " · partial scan (safety limit)") : "")
        return CleanupCategory(
            name: String(localized: "Stale Temporary Files"),
            stableName: "Stale Temporary Files",
            icon: "clock.arrow.circlepath",
            color: .red,
            description: String(localized: "\(paths.count) direct temporary file(s) older than 7 days\(suffix)"),
            group: .system,
            safetyLevel: .review,
            paths: paths,
            breakdown: result.breakdown,
            deleteChildrenOnly: false,
            size: totalSize,
            fileCount: paths.count,
            isSelected: false
        )
    }

    // MARK: - Comprehensive Cache Walkers (SAFE — caches always rebuild)

    /// Walks ~/Library/Caches — finds ALL app caches not already covered by specific scans
    private func scanAllCaches() async -> CleanupCategory? {
        let dir = "\(Self.home)/Library/Caches"
        guard FileManager.default.fileExists(atPath: dir) else { return nil }

        let scannedSnapshot = scannedPathsSnapshot()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
                    continuation.resume(returning: nil)
                    return
                }

                var paths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                // Pre-compute sorted scanned paths for efficient overlap detection
                let sortedScanned = scannedSnapshot.sorted()

                for entry in entries {
                    if self.cancelRequested { break }
                    autoreleasepool {
                    let fullPath = (dir as NSString).appendingPathComponent(entry)
                    // Skip entries already covered by specific scans
                    if scannedSnapshot.contains(fullPath) { return }
                    // Efficient overlap check: binary search for child/parent paths
                    let fullPathSlash = fullPath + "/"
                    if sortedScanned.contains(where: { $0.hasPrefix(fullPathSlash) || fullPath.hasPrefix($0 + "/") }) { return }

                    let (sz, ct) = Self.directorySizeSync(
                        fullPath,
                        isCancelled: { self.cancelRequested }
                    )
                    if sz > ScanConstants.minCacheSizeBytes {
                        paths.append(fullPath)
                        breakdown.append(PathStat(path: fullPath, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                    } // autoreleasepool
                }

                guard totalSize > ScanConstants.minCacheTotalBytes, !paths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                var sorted = breakdown
                sorted.sort { $0.size > $1.size }
                for path in paths { self.insertScannedPath(path) }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Other App Caches"), stableName: "Other App Caches", icon: "archivebox", color: .blue,
                    description: String(localized: "\(paths.count) app caches — safe to remove, rebuilt automatically"),
                    group: .system, safetyLevel: .safe,
                    paths: paths, breakdown: sorted,
                    deleteChildrenOnly: true,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    /// Walks `~/Library/Group Containers/<id>/Library/Caches` for every sandboxed app —
    /// only the `Caches` subdir of each container is touched, never any data. Catches
    /// sandboxed-app caches the plain `~/Library/Caches` walker can't see (F8).
    private func scanGroupContainerCaches() async -> CleanupCategory? {
        let root = "\(Self.home)/Library/Group Containers"
        guard FileManager.default.fileExists(atPath: root) else { return nil }

        let scannedSnapshot = scannedPathsSnapshot()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                guard let containers = try? fm.contentsOfDirectory(atPath: root) else {
                    continuation.resume(returning: nil)
                    return
                }

                var paths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                for container in containers {
                    if self.cancelRequested { break }
                    autoreleasepool {
                        let cachesPath = "\(root)/\(container)/Library/Caches"
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: cachesPath, isDirectory: &isDir), isDir.boolValue else { return }
                        if scannedSnapshot.contains(cachesPath) { return }

                        let (sz, ct) = Self.directorySizeSync(
                            cachesPath,
                            isCancelled: { self.cancelRequested }
                        )
                        if sz > ScanConstants.minCacheSizeBytes {
                            paths.append(cachesPath)
                            breakdown.append(PathStat(path: cachesPath, size: sz, fileCount: ct))
                            totalSize += sz
                            totalCount += ct
                        }
                    }
                }

                guard totalSize > ScanConstants.minCacheTotalBytes, !paths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }
                for path in paths { self.insertScannedPath(path) }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Shared Container Caches"), stableName: "Shared Container Caches", icon: "archivebox.fill", color: .blue,
                    description: String(localized: "\(paths.count) sandboxed-app cache(s) — safe to remove, rebuilt automatically"),
                    group: .system, safetyLevel: .safe,
                    paths: paths, breakdown: breakdown,
                    deleteChildrenOnly: true,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    /// Finds standard Chromium/Electron cache directories for apps without a dedicated
    /// definition (Notion, Figma, Obsidian, Postman, and others). Only literal cache
    /// directory names one level below each app-support folder are considered.
    private func scanElectronCaches() async -> CleanupCategory? {
        let root = "\(Self.home)/Library/Application Support"
        guard FileManager.default.fileExists(atPath: root) else { return nil }
        let claimed = scannedPathsSnapshot()

        let breakdown = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.findElectronCacheDirectories(
                    in: root,
                    claimedPaths: claimed,
                    isCancelled: { self.cancelRequested }
                ))
            }
        }
        guard !breakdown.isEmpty else { return nil }

        let sorted = breakdown.sorted { $0.size > $1.size }
        let paths = sorted.map(\.path)
        for path in paths { insertScannedPath(path) }
        return CleanupCategory(
            name: String(localized: "Other Electron App Caches"),
            stableName: "Other Electron App Caches",
            icon: "bolt.square",
            color: .blue,
            description: String(localized: "\(paths.count) Electron cache directories — rebuilt automatically"),
            group: .applications,
            safetyLevel: .safe,
            paths: paths,
            breakdown: sorted,
            deleteChildrenOnly: false,
            size: sorted.reduce(0) { $0 + $1.size },
            fileCount: sorted.reduce(0) { $0 + $1.fileCount },
            isSelected: true
        )
    }

    static func findElectronCacheDirectories(
        in root: String,
        claimedPaths: Set<String>,
        isCancelled: () -> Bool,
        minimumSize: Int64 = ScanConstants.minCacheSizeBytes
    ) -> [PathStat] {
        let fm = FileManager.default
        let cacheNames: Set<String> = [
            "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
        ]
        guard let appDirectories = try? fm.contentsOfDirectory(atPath: root) else {
            return []
        }

        func overlapsClaimedPath(_ path: String) -> Bool {
            claimedPaths.contains(path) || claimedPaths.contains {
                $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/")
            }
        }

        var results: [PathStat] = []
        for appDirectory in appDirectories {
            if isCancelled() { break }
            autoreleasepool {
                let appRoot = (root as NSString).appendingPathComponent(appDirectory)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: appRoot, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      let entries = try? fm.contentsOfDirectory(atPath: appRoot)
                else { return }

                for cacheName in entries where cacheNames.contains(cacheName) {
                    if isCancelled() { return }
                    let path = (appRoot as NSString).appendingPathComponent(cacheName)
                    guard !overlapsClaimedPath(path) else { continue }
                    var cacheIsDirectory: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &cacheIsDirectory),
                          cacheIsDirectory.boolValue else { continue }
                    let (size, count) = directorySizeSync(path, isCancelled: isCancelled)
                    if size >= minimumSize {
                        results.append(PathStat(path: path, size: size, fileCount: count))
                    }
                }
            }
        }
        return results
    }

    /// Walks /Library/Caches — system-level caches
    private func scanSystemCaches() async -> CleanupCategory? {
        let dir = "/Library/Caches"
        guard FileManager.default.fileExists(atPath: dir) else { return nil }

        let scannedSnapshot = scannedPathsSnapshot()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
                    continuation.resume(returning: nil)
                    return
                }

                var paths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                for entry in entries {
                    if self.cancelRequested { break }
                    autoreleasepool {
                    let fullPath = (dir as NSString).appendingPathComponent(entry)
                    if scannedSnapshot.contains(fullPath) { return }

                    let (sz, ct) = Self.directorySizeSync(
                        fullPath,
                        isCancelled: { self.cancelRequested }
                    )
                    if sz > ScanConstants.minSystemCacheSizeBytes {
                        paths.append(fullPath)
                        breakdown.append(PathStat(path: fullPath, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                    } // autoreleasepool
                }

                guard totalSize > ScanConstants.minSystemCacheTotalBytes, !paths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                var sorted = breakdown
                sorted.sort { $0.size > $1.size }
                for path in paths { self.insertScannedPath(path) }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "System Caches"), stableName: "System Caches", icon: "internaldrive.fill", color: .blue,
                    description: String(localized: "\(paths.count) system-level caches — safe to remove"),
                    group: .system, safetyLevel: .safe,
                    paths: paths, breakdown: sorted,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    // MARK: - User File Scanners (REVIEW — user should check before deleting)

    /// Old files in Downloads (>30 days old)
    private func scanOldDownloads() async -> CleanupCategory? {
        let olderThanDays = settingOldFileThresholdDays
        let threshold = Date().addingTimeInterval(-Double(olderThanDays) * 86400)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let downloads = "\(Self.home)/Downloads"
                guard fm.fileExists(atPath: downloads) else {
                    continuation.resume(returning: nil)
                    return
                }

                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                guard let contents = try? fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: downloads),
                    includingPropertiesForKeys: [
                        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                        .isUbiquitousItemKey, .isPackageKey, .isVolumeKey,
                        .totalFileAllocatedSizeKey, .fileSizeKey,
                        .contentModificationDateKey,
                    ],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: nil)
                    return
                }

                for url in contents {
                    if self.cancelRequested { break }
                    autoreleasepool {
                        guard !self.overlapsScannedPath(url.path),
                              let rv = try? url.resourceValues(forKeys: [
                                  .isRegularFileKey, .isDirectoryKey,
                                  .isSymbolicLinkKey, .isUbiquitousItemKey,
                                  .isPackageKey, .isVolumeKey,
                                  .totalFileAllocatedSizeKey,
                                  .fileSizeKey, .contentModificationDateKey,
                              ]),
                              rv.isSymbolicLink != true,
                              rv.isUbiquitousItem != true,
                              rv.isPackage != true,
                              rv.isVolume != true
                        else { return }

                        if rv.isRegularFile == true {
                            let modDate = rv.contentModificationDate ?? Date.distantPast
                            guard modDate < threshold else { return }
                            let size = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                            if size > 0 {
                                filePaths.append(url.path)
                                self.insertScannedPath(url.path)
                                breakdown.append(PathStat(path: url.path, size: size, fileCount: 1))
                                totalSize += size
                            }
                        } else if rv.isDirectory == true {
                            // A directory's own modification date can be stale while a
                            // nested file is active. Require a complete, bounded walk
                            // proving every contained file is old; unreadable, cloud,
                            // linked, packaged, cancelled, or oversized trees are
                            // conservatively left alone.
                            guard let oldContent = Self.oldDirectoryContentStat(
                                url.path,
                                olderThan: threshold,
                                isCancelled: { self.cancelRequested }
                            ) else { return }
                            let (size, count) = oldContent
                            if size > 0 {
                                filePaths.append(url.path)
                                self.insertScannedPath(url.path)
                                breakdown.append(PathStat(path: url.path, size: size, fileCount: count))
                                totalSize += size
                            }
                        }
                    }
                }

                guard !filePaths.isEmpty, totalSize > 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                var sorted = breakdown
                sorted.sort { $0.size > $1.size }
                let totalFileCount = sorted.reduce(0) { $0 + $1.fileCount }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Old Downloads (>\(olderThanDays)d)"), stableName: "Old Downloads (>\(olderThanDays)d)", icon: "arrow.down.circle.fill", color: .blue,
                    description: String(localized: "\(filePaths.count) old items in Downloads — review before deleting"),
                    group: .system, safetyLevel: .review,
                    paths: filePaths, breakdown: sorted,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: totalFileCount,
                    isSelected: false
                ))
            }
        }
    }

    /// Old screenshots
    private func scanOldScreenshots() async -> CleanupCategory? {
        let olderThanDays = settingScreenshotThresholdDays
        let threshold = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        let dirs = ["\(Self.home)/Desktop", "\(Self.home)/Downloads", "\(Self.home)/Documents"]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                for dir in dirs where fm.fileExists(atPath: dir) {
                    if self.cancelRequested { break }
                    guard let contents = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [
                            .fileSizeKey, .contentModificationDateKey,
                            .isRegularFileKey, .isSymbolicLinkKey,
                            .isUbiquitousItemKey, .totalFileAllocatedSizeKey,
                        ],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for url in contents {
                        if self.cancelRequested { break }
                        guard !self.overlapsScannedPath(url.path) else { continue }
                        let name = url.lastPathComponent.lowercased()
                        guard name.hasPrefix("screenshot") || name.hasPrefix("screen shot") ||
                              name.hasPrefix("screen recording") || name.hasPrefix("cleanshot")
                        else { continue }
                        guard let rv = try? url.resourceValues(forKeys: [
                                  .fileSizeKey, .contentModificationDateKey,
                                  .isRegularFileKey, .isSymbolicLinkKey,
                                  .isUbiquitousItemKey, .totalFileAllocatedSizeKey,
                              ]),
                              rv.isRegularFile == true,
                              rv.isSymbolicLink != true,
                              rv.isUbiquitousItem != true,
                              let modDate = rv.contentModificationDate, modDate < threshold else { continue }
                        let size = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                        guard size > 0 else { continue }

                        filePaths.append(url.path)
                        self.insertScannedPath(url.path)
                        breakdown.append(PathStat(path: url.path, size: size, fileCount: 1))
                        totalSize += size
                    }
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Old Screenshots (>\(olderThanDays)d)"), stableName: "Old Screenshots (>\(olderThanDays)d)", icon: "camera.viewfinder", color: .teal,
                    description: String(localized: "\(filePaths.count) old screenshots — likely safe to delete"),
                    group: .system, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Old installer files in Downloads
    private func scanInstallerFiles() async -> CleanupCategory? {
        let olderThanDays = settingOldFileThresholdDays
        let threshold = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let downloads = "\(Self.home)/Downloads"
                guard fm.fileExists(atPath: downloads) else {
                    continuation.resume(returning: nil)
                    return
                }

                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                guard let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: downloads),
                    includingPropertiesForKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey,
                        .isUbiquitousItemKey, .fileSizeKey,
                        .contentModificationDateKey, .totalFileAllocatedSizeKey,
                    ],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: nil
                ) else {
                    continuation.resume(returning: nil)
                    return
                }

                for case let url as URL in enumerator {
                    if self.cancelRequested {
                        enumerator.skipDescendants()
                        break
                    }
                    if enumerator.level > 2 {
                        enumerator.skipDescendants()
                        continue
                    }
                    let ext = url.pathExtension.lowercased()
                    let lowerName = url.deletingPathExtension().lastPathComponent.lowercased()
                    let isInstallerZip = ext == "zip" &&
                        (lowerName.contains("install") || lowerName.contains("setup"))
                    guard installerExtensions.contains(ext) || isInstallerZip else { continue }
                    guard !self.overlapsScannedPath(url.path),
                          let rv = try? url.resourceValues(forKeys: [
                              .isRegularFileKey, .isSymbolicLinkKey,
                              .isUbiquitousItemKey, .fileSizeKey,
                              .contentModificationDateKey,
                              .totalFileAllocatedSizeKey,
                          ]),
                          rv.isRegularFile == true,
                          rv.isSymbolicLink != true,
                          rv.isUbiquitousItem != true
                    else { continue }
                    let size = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                    let modDate = rv.contentModificationDate ?? Date.distantPast
                    if modDate < threshold && size > 0 {
                        filePaths.append(url.path)
                        self.insertScannedPath(url.path)
                        let appName = lowerName
                            .replacingOccurrences(of: " installer", with: "")
                            .replacingOccurrences(of: " setup", with: "")
                        let isInstalled = [
                            "/Applications/\(appName).app",
                            "\(Self.home)/Applications/\(appName).app",
                        ].contains { fm.fileExists(atPath: $0) }
                        breakdown.append(PathStat(
                            path: url.path,
                            size: size,
                            fileCount: 1,
                            displayName: isInstalled
                                ? String(localized: "\(AppLocalization.isolateTechnicalText(url.lastPathComponent)) · matching app installed")
                                : url.lastPathComponent
                        ))
                        totalSize += size
                    }
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Old Installers (>\(olderThanDays)d)"), stableName: "Old Installers (>\(olderThanDays)d)", icon: "doc.zipper", color: .brown,
                    description: String(localized: "\(filePaths.count) old DMG/PKG/MPKG/ISO/XIP or installer ZIP files — review before deleting"),
                    group: .storage, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    // MARK: - Unused Applications

    private func scanUnusedApplications() async -> CleanupCategory? {
        let thresholdDays = settingUnusedAppThresholdDays
        let threshold = Date().addingTimeInterval(-Double(thresholdDays) * 86400)
        let runningBundleIDs: Set<String> = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }

        let candidates: [(path: String, lastUsed: Date, displayName: String)] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                let fm = FileManager.default
                let appDirs = ["/Applications", "\(Self.home)/Applications"]
                var results: [(path: String, lastUsed: Date, displayName: String)] = []

                let systemApps: Set<String> = [
                    "Safari", "Mail", "Messages", "FaceTime", "Maps", "Photos",
                    "Music", "TV", "News", "Stocks", "Podcasts", "Books",
                    "App Store", "System Preferences", "System Settings",
                    "Preview", "TextEdit", "Calculator", "Dictionary",
                    "Font Book", "Keychain Access", "Terminal", "Activity Monitor",
                    "Console", "Disk Utility", "Migration Assistant", "Automator",
                    "Xcode", "Finder", "Siri", "Clock", "Weather", "Freeform",
                    "Passwords", "iPhone Mirroring", "Instruments", "FileMerge",
                    "Shortcuts", "Notes", "Reminders", "Calendar", "Contacts",
                    "Home", "Voice Memos", "Photo Booth", "Image Capture",
                    "Grapher", "Chess", "Stickies",
                ]

                for dir in appDirs where fm.fileExists(atPath: dir) {
                    if self.cancelRequested { break }
                    guard let contents = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [.isPackageKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for url in contents where url.pathExtension == "app" {
                        if self.cancelRequested { break }
                        let appName = url.deletingPathExtension().lastPathComponent
                        if systemApps.contains(appName) { continue }

                        // Skip currently running apps
                        if let bundleID = Bundle(url: url)?.bundleIdentifier,
                           runningBundleIDs.contains(bundleID) { continue }

                        // Multi-signal last-used detection
                        let lastUsed = Self.getBestLastUsedDate(for: url.path, appName: appName)

                        if let lastUsed = lastUsed, lastUsed < threshold {
                            results.append((url.path, lastUsed, appName))
                        }
                        // If we have NO signal at all, skip (don't assume unused)
                    }
                }

                continuation.resume(returning: results)
            }
        }

        guard !candidates.isEmpty else { return nil }

        var appPaths: [String] = []
        var breakdown: [PathStat] = []
        var totalSize: Int64 = 0
        var totalCount: Int = 0

        for candidate in candidates {
            if cancelRequested { break }
            let (size, count) = await directorySize(candidate.path)
            if size > 0 {
                appPaths.append(candidate.path)
                breakdown.append(PathStat(
                    path: candidate.path, size: size, fileCount: count,
                    lastAccessed: candidate.lastUsed
                ))
                totalSize += size
                totalCount += count
            }
        }

        guard totalSize > 0, !appPaths.isEmpty else { return nil }
        breakdown.sort { $0.size > $1.size }
        let associatedBundleIDs = appPaths.compactMap {
            Bundle(url: URL(fileURLWithPath: $0))?.bundleIdentifier
        }

        return CleanupCategory(
            name: String(localized: "Unused Apps (>\(thresholdDays)d)"), stableName: "Unused Apps (>\(thresholdDays)d)", icon: "app.dashed", color: .gray,
            description: String(localized: "\(appPaths.count) apps not opened in \(thresholdDays)+ days"),
            group: .applications, safetyLevel: .caution,
            paths: appPaths, allowedRoots: appPaths,
            associatedBundleIDs: associatedBundleIDs,
            allowsApplicationBundles: true,
            breakdown: breakdown,
            deleteChildrenOnly: false,
            size: totalSize, fileCount: totalCount,
            isSelected: false
        )
    }

    /// Multi-signal detection for app last-used date. Uses the most recent of:
    /// 1. Spotlight kMDItemLastUsedDate
    /// 2. contentAccessDate on the app bundle
    /// 3. Recent modification of app preferences plist
    /// 4. Recent modification of app support data
    private static func getBestLastUsedDate(for appPath: String, appName: String) -> Date? {
        var dates: [Date] = []

        // Signal 1: Spotlight metadata
        if let spotlightDate = getSpotlightLastUsedDate(for: appPath) {
            dates.append(spotlightDate)
        }

        // Signal 2: contentAccessDate on the app bundle
        let appURL = URL(fileURLWithPath: appPath)
        if let rv = try? appURL.resourceValues(forKeys: [.contentAccessDateKey]),
           let accessDate = rv.contentAccessDate {
            dates.append(accessDate)
        }

        // Signal 3: Check preferences plist modification
        if let bundleID = Bundle(url: appURL)?.bundleIdentifier {
            let prefsPath = "\(home)/Library/Preferences/\(bundleID).plist"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: prefsPath),
               let modDate = attrs[.modificationDate] as? Date {
                dates.append(modDate)
            }

            // Signal 4: Check app support folder modification
            let supportPath = "\(home)/Library/Application Support/\(appName)"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: supportPath),
               let modDate = attrs[.modificationDate] as? Date {
                dates.append(modDate)
            }

            // Also check support folder by bundle ID
            let supportPath2 = "\(home)/Library/Application Support/\(bundleID)"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: supportPath2),
               let modDate = attrs[.modificationDate] as? Date {
                dates.append(modDate)
            }
        }

        // Return the most recent signal (most optimistic — if any signal says "used recently", trust it)
        return dates.max()
    }

    private static func getSpotlightLastUsedDate(for path: String) -> Date? {
        guard let output = runCommand("/usr/bin/mdls", arguments: ["-name", "kMDItemLastUsedDate", "-raw", path]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "(null)" || trimmed.isEmpty { return nil }
        return spotlightDateFormatter.date(from: trimmed)
    }

    // MARK: - Docker CLI

    private func scanDockerImages() async -> CleanupCategory? {
        guard let dockerPath = Self.findDocker() else { return nil }
        guard let output = Self.runCommand(dockerPath, arguments: [
            "images", "--filter", "dangling=true",
            "--format", "{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}\t{{.CreatedSince}}"
        ]) else { return nil }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var breakdown: [PathStat] = []
        var totalSize: Int64 = 0

        for line in lines {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let sizeBytes = Self.parseDockerSize(parts[1])
            totalSize += sizeBytes
            let created = parts.count > 3 ? parts[3] : ""
            breakdown.append(PathStat(
                path: "\(parts[0]) (\(parts[2].prefix(12))) — \(created)",
                size: sizeBytes, fileCount: 1
            ))
        }

        guard totalSize > 0 else { return nil }
        breakdown.sort { $0.size > $1.size }

        return CleanupCategory(
            name: String(localized: "Docker Dangling Images"), stableName: "Docker Dangling Images", icon: "shippingbox.circle", color: .blue,
            description: String(localized: "\(breakdown.count) untagged images not referenced by a container"),
            group: .docker, safetyLevel: .review,
            paths: [], breakdown: breakdown,
            deleteChildrenOnly: false, isDockerResource: true,
            dockerCleanCommand: ["image", "prune", "-f"],
            size: totalSize, fileCount: breakdown.count, isSelected: false
        )
    }

    private func scanDockerStoppedContainers() async -> CleanupCategory? {
        guard let dockerPath = Self.findDocker() else { return nil }
        guard let output = Self.runCommand(dockerPath, arguments: [
            "ps", "-a", "--filter", "status=exited",
            "--format", "{{.Names}}\t{{.Size}}\t{{.ID}}\t{{.Status}}"
        ]) else { return nil }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var breakdown: [PathStat] = []
        var totalSize: Int64 = 0

        for line in lines {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let sizeBytes = Self.parseDockerSize(parts[1])
            totalSize += sizeBytes
            let status = parts.count > 3 ? parts[3] : ""
            breakdown.append(PathStat(
                path: "\(parts[0]) (\(parts[2].prefix(12))) — \(status)",
                size: sizeBytes, fileCount: 1
            ))
        }

        guard !breakdown.isEmpty else { return nil }
        breakdown.sort { $0.size > $1.size }

        return CleanupCategory(
            name: String(localized: "Docker Stopped Containers"), stableName: "Docker Stopped Containers", icon: "stop.circle", color: .orange,
            description: String(localized: "\(breakdown.count) stopped containers"),
            group: .docker, safetyLevel: .safe,
            paths: [], breakdown: breakdown,
            deleteChildrenOnly: false, isDockerResource: true,
            dockerCleanCommand: ["container", "prune", "-f"],
            size: totalSize, fileCount: breakdown.count, isSelected: false
        )
    }

    private func scanDockerBuildCache() async -> CleanupCategory? {
        guard let dockerPath = Self.findDocker() else { return nil }
        guard let dfOutput = Self.runCommand(dockerPath, arguments: [
            "system", "df", "--format", "{{.Type}}\t{{.Size}}\t{{.Reclaimable}}"
        ]) else { return nil }

        for line in dfOutput.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 3 && parts[0] == "Build Cache" {
                let reclaimableSize = Self.parseDockerSize(parts[2])
                guard reclaimableSize > 0 else { return nil }
                return CleanupCategory(
                    name: String(localized: "Docker Build Cache"), stableName: "Docker Build Cache", icon: "hammer.circle", color: .teal,
                    description: String(localized: "Build cache — \(parts[2]) reclaimable"),
                    group: .docker, safetyLevel: .safe,
                    paths: [],
                    breakdown: [PathStat(
                        path: "Build cache (\(parts[2]) reclaimable)",
                        size: reclaimableSize,
                        fileCount: 1,
                        displayName: String(localized: "Build cache (\(parts[2]) reclaimable)")
                    )],
                    deleteChildrenOnly: false, isDockerResource: true,
                    dockerCleanCommand: ["builder", "prune", "-f"],
                    size: reclaimableSize, fileCount: 1, isSelected: false
                )
            }
        }
        return nil
    }

    private func runDockerClean(
        command: [String]
    ) async -> (succeeded: Bool, reclaimedSize: Int64?) {
        guard let dockerPath = Self.findDocker(),
              let output = Self.runCommand(dockerPath, arguments: command) else {
            return (false, nil)
        }
        return (true, Self.parseDockerReclaimedSize(output))
    }

    private struct OllamaCleanOutcome {
        var removedModels: Set<String> = []
        var failedModels: [String] = []

        init(
            removedModels: Set<String> = [],
            failedModels: [String] = []
        ) {
            self.removedModels = removedModels
            self.failedModels = failedModels
        }
    }

    private func runOllamaClean(category: CleanupCategory) async -> OllamaCleanOutcome {
        guard let ollamaPath = Self.findOllama() else {
            return OllamaCleanOutcome(
                failedModels: category.breakdown.filter(\.isSelected).map(\.path)
            )
        }
        // Remove each selected model individually via `ollama rm <model>`
        let selectedModels = category.hasPerFileSelection
            ? category.breakdown.filter(\.isSelected).map(\.path)
            : category.breakdown.map(\.path)
        var outcome = OllamaCleanOutcome()
        for model in selectedModels {
            if Self.runCommand(ollamaPath, arguments: ["rm", model]) != nil {
                outcome.removedModels.insert(model)
            } else {
                outcome.failedModels.append(model)
            }
        }
        return outcome
    }

    // MARK: - node_modules

    // MARK: - Ollama Models Scanner

    private func scanOllamaModels() async -> CleanupCategory? {
        guard let ollamaPath = Self.findOllama() else { return nil }
        guard let output = Self.runCommand(ollamaPath, arguments: ["list"]) else { return nil }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > 1 else { return nil }

        var breakdown: [PathStat] = []
        var totalSize: Int64 = 0

        // Parse each model line: split by 2+ whitespace chars
        for line in lines.dropFirst() {
            let columns = line.replacingOccurrences(
                of: "\\s{2,}", with: "\t",
                options: .regularExpression
            ).components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 3 else { continue }

            let modelName = columns[0]
            let sizeStr = columns[2]
            let sizeBytes = Self.parseDockerSize(sizeStr)

            totalSize += sizeBytes
            breakdown.append(PathStat(
                path: modelName,
                size: sizeBytes, fileCount: 1
            ))
        }

        guard !breakdown.isEmpty else { return nil }
        breakdown.sort { $0.size > $1.size }

        let modelDescription = breakdown.count == 1
            ? String(localized: "1 model installed — \(Self.formatBytes(totalSize))")
            : String(localized: "\(breakdown.count) models installed — \(Self.formatBytes(totalSize))")
        return CleanupCategory(
            name: String(localized: "Ollama Models"), stableName: "Ollama Models", icon: "brain.head.profile", color: .purple,
            description: modelDescription,
            group: .developer, safetyLevel: .review,
            paths: [], breakdown: breakdown,
            deleteChildrenOnly: false, isOllamaResource: true,
            size: totalSize, fileCount: breakdown.count, isSelected: false
        )
    }

    // MARK: - Framework build artifacts

    /// Finds Next.js `.next` directories only when their parent is a project root
    /// containing `package.json`. Package contents and generic hidden directories are
    /// skipped; agent worktrees receive the same narrow exception as node_modules.
    private func scanNextJSBuildArtifacts() async -> CleanupCategory? {
        let discoveryFileManager = FileManager.default
        var searchDirs = [
            "\(Self.home)/Projects", "\(Self.home)/Developer",
            "\(Self.home)/Documents", "\(Self.home)/Desktop",
            "\(Self.home)/GitHub", "\(Self.home)/repos",
            "\(Self.home)/code", "\(Self.home)/src",
            "\(Self.home)/dev", "\(Self.home)/workspace",
            "\(Self.home)/Work", "\(Self.home)/Sites",
        ]

        if let topLevel = try? discoveryFileManager.contentsOfDirectory(atPath: Self.home) {
            for directory in topLevel where !directory.hasPrefix(".") {
                let path = (Self.home as NSString)
                    .appendingPathComponent(directory)
                var isDirectory: ObjCBool = false
                if discoveryFileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue,
                   !["Library", "Applications", "Music", "Movies", "Pictures",
                     "Downloads", "Public"].contains(directory),
                   !searchDirs.contains(path) {
                    searchDirs.append(path)
                }
            }
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var found: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount = 0

                for searchDir in searchDirs
                where fm.fileExists(atPath: searchDir) {
                    if self.cancelRequested { break }
                    Self.findNextJSBuildArtifactsRecursive(
                        in: searchDir,
                        depth: 0,
                        maxDepth: 8,
                        fm: fm,
                        found: &found,
                        breakdown: &breakdown,
                        totalSize: &totalSize,
                        totalCount: &totalCount,
                        isCancelled: { self.cancelRequested }
                    )
                }

                guard !found.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }
                for path in found { self.insertScannedPath(path) }
                let artifactDescription = found.count == 1
                    ? String(localized: "1 .next build directory — rebuilt by the next Next.js build")
                    : String(localized: "\(found.count) .next build directories — rebuilt by the next Next.js build")
                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Next.js Build Artifacts"),
                    stableName: "Next.js Build Artifacts",
                    icon: "hammer.fill",
                    color: .primary,
                    description: artifactDescription,
                    group: .developer,
                    safetyLevel: .safe,
                    paths: found,
                    breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize,
                    fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    static func findNextJSBuildArtifactsRecursive(
        in directory: String,
        depth: Int,
        maxDepth: Int,
        fm: FileManager,
        found: inout [String],
        breakdown: inout [PathStat],
        totalSize: inout Int64,
        totalCount: inout Int,
        minSize: Int64 = ScanConstants.minNodeModulesSizeBytes,
        isCancelled: () -> Bool = { false }
    ) {
        guard !isCancelled(), depth < maxDepth,
              let entries = try? fm.contentsOfDirectory(atPath: directory)
        else { return }

        for entry in entries {
            if isCancelled() { break }
            autoreleasepool {
                let path = (directory as NSString).appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      (try? fm.destinationOfSymbolicLink(atPath: path)) == nil
                else { return }

                if entry == ".next" {
                    let packageJSON = (directory as NSString)
                        .appendingPathComponent("package.json")
                    guard fm.fileExists(atPath: packageJSON) else { return }
                    let (size, count) = directorySizeSync(
                        path,
                        isCancelled: isCancelled
                    )
                    if size > minSize {
                        found.append(path)
                        breakdown.append(PathStat(
                            path: path,
                            size: size,
                            fileCount: count
                        ))
                        totalSize += size
                        totalCount += count
                    }
                    return
                }

                if entry == "node_modules" || entry == ".git" {
                    return
                }
                if entry == ".claude" || entry == ".codex" {
                    let worktrees = (path as NSString)
                        .appendingPathComponent("worktrees")
                    var worktreesIsDirectory: ObjCBool = false
                    if fm.fileExists(
                        atPath: worktrees,
                        isDirectory: &worktreesIsDirectory
                    ), worktreesIsDirectory.boolValue {
                        findNextJSBuildArtifactsRecursive(
                            in: worktrees,
                            depth: depth + 1,
                            maxDepth: maxDepth,
                            fm: fm,
                            found: &found,
                            breakdown: &breakdown,
                            totalSize: &totalSize,
                            totalCount: &totalCount,
                            minSize: minSize,
                            isCancelled: isCancelled
                        )
                    }
                } else if !entry.hasPrefix(".") && entry != "Library" {
                    findNextJSBuildArtifactsRecursive(
                        in: path,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        fm: fm,
                        found: &found,
                        breakdown: &breakdown,
                        totalSize: &totalSize,
                        totalCount: &totalCount,
                        minSize: minSize,
                        isCancelled: isCancelled
                    )
                }
            }
        }
    }

    private func scanNodeModules() async -> CleanupCategory? {
        let fm = FileManager.default
        var searchDirs = [
            "\(Self.home)/Projects", "\(Self.home)/Developer",
            "\(Self.home)/Documents", "\(Self.home)/Desktop",
            "\(Self.home)/GitHub", "\(Self.home)/repos",
            "\(Self.home)/code", "\(Self.home)/src",
            "\(Self.home)/dev", "\(Self.home)/workspace",
            "\(Self.home)/Work", "\(Self.home)/Sites",
        ]

        if let topLevel = try? fm.contentsOfDirectory(atPath: Self.home) {
            for dir in topLevel where !dir.hasPrefix(".") {
                let fullPath = (Self.home as NSString).appendingPathComponent(dir)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue,
                   !["Library", "Applications", "Music", "Movies", "Pictures",
                    "Downloads", "Public"].contains(dir),
                   !searchDirs.contains(fullPath) {
                    searchDirs.append(fullPath)
                }
            }
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var found: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                for searchDir in searchDirs where fm.fileExists(atPath: searchDir) {
                    if self.cancelRequested { break }
                    Self.findNodeModulesRecursive(
                        in: searchDir, depth: 0, maxDepth: 6, fm: fm,
                        found: &found, breakdown: &breakdown,
                        totalSize: &totalSize, totalCount: &totalCount,
                        isCancelled: { self.cancelRequested }
                    )
                }

                guard !found.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }
                for path in found { self.insertScannedPath(path) }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "node_modules"), stableName: "node_modules", icon: "shippingbox.fill", color: .green,
                    description: String(localized: "\(found.count) node_modules — run npm install to restore"),
                    group: .packageManagers, safetyLevel: .safe,
                    paths: found, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    static func findNodeModulesRecursive(
        in dir: String, depth: Int, maxDepth: Int, fm: FileManager,
        found: inout [String], breakdown: inout [PathStat],
        totalSize: inout Int64, totalCount: inout Int,
        minSize: Int64 = ScanConstants.minNodeModulesSizeBytes,
        isCancelled: () -> Bool = { false }
    ) {
        guard !isCancelled() else { return }
        guard depth < maxDepth else { return }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }

        for entry in entries {
            if isCancelled() { break }
            autoreleasepool {
                let fullPath = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir),
                      isDir.boolValue,
                      (try? fm.destinationOfSymbolicLink(atPath: fullPath)) == nil
                else { return }

                if entry == "node_modules" {
                    let (sz, ct) = directorySizeSync(fullPath, isCancelled: isCancelled)
                    if sz > minSize {
                        found.append(fullPath)
                        breakdown.append(PathStat(path: fullPath, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                } else if entry == ".claude" || entry == ".codex" {
                    // Agent-created worktrees are intentionally hidden, but their
                    // dependency copies are just as rebuildable as a primary checkout.
                    // Traverse only the conventional `worktrees` child; do not open
                    // generic hidden state, credentials, or session directories.
                    let worktrees = (fullPath as NSString)
                        .appendingPathComponent("worktrees")
                    var worktreesIsDirectory: ObjCBool = false
                    if fm.fileExists(
                        atPath: worktrees,
                        isDirectory: &worktreesIsDirectory
                    ), worktreesIsDirectory.boolValue {
                        findNodeModulesRecursive(
                            in: worktrees,
                            depth: depth + 1,
                            maxDepth: maxDepth,
                            fm: fm,
                            found: &found,
                            breakdown: &breakdown,
                            totalSize: &totalSize,
                            totalCount: &totalCount,
                            minSize: minSize,
                            isCancelled: isCancelled
                        )
                    }
                } else if !entry.hasPrefix(".") && entry != "Library" {
                    findNodeModulesRecursive(
                        in: fullPath, depth: depth + 1, maxDepth: maxDepth, fm: fm,
                        found: &found, breakdown: &breakdown,
                        totalSize: &totalSize, totalCount: &totalCount,
                        minSize: minSize,
                        isCancelled: isCancelled
                    )
                }
            }
        }
    }

    // MARK: - Rust target directories

    /// Finds `target/` build directories in Rust projects (a `target` dir whose parent
    /// also contains `Cargo.toml`). Mirrors the node_modules scan; regenerable via
    /// `cargo build`. (Issue #3 remainder.)
    private func scanRustTargets() async -> CleanupCategory? {
        let fm = FileManager.default
        var searchDirs = [
            "\(Self.home)/Projects", "\(Self.home)/Developer",
            "\(Self.home)/Documents", "\(Self.home)/Desktop",
            "\(Self.home)/GitHub", "\(Self.home)/repos",
            "\(Self.home)/code", "\(Self.home)/src",
            "\(Self.home)/dev", "\(Self.home)/workspace",
            "\(Self.home)/Work", "\(Self.home)/rust",
        ]

        if let topLevel = try? fm.contentsOfDirectory(atPath: Self.home) {
            for dir in topLevel where !dir.hasPrefix(".") {
                let fullPath = (Self.home as NSString).appendingPathComponent(dir)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue,
                   !["Library", "Applications", "Music", "Movies", "Pictures",
                    "Downloads", "Public"].contains(dir),
                   !searchDirs.contains(fullPath) {
                    searchDirs.append(fullPath)
                }
            }
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var found: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                for searchDir in searchDirs where fm.fileExists(atPath: searchDir) {
                    if self.cancelRequested { break }
                    Self.findRustTargetsRecursive(
                        in: searchDir, depth: 0, maxDepth: 6, fm: fm,
                        found: &found, breakdown: &breakdown,
                        totalSize: &totalSize, totalCount: &totalCount,
                        isCancelled: { self.cancelRequested }
                    )
                }

                guard !found.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }
                for path in found { self.insertScannedPath(path) }
                let targetDescription = found.count == 1
                    ? String(localized: "1 target directory — run cargo build to restore")
                    : String(localized: "\(found.count) target directories — run cargo build to restore")

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Rust target directories"), stableName: "Rust target directories", icon: "gearshape.2", color: .orange,
                    description: targetDescription,
                    group: .packageManagers, safetyLevel: .safe,
                    paths: found, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    /// Recursively finds Rust `target/` directories. A `target` dir qualifies only when
    /// its parent directory also contains `Cargo.toml` — the guard that keeps Maven/Java
    /// `target/` dirs (and any other coincidental name) out of the results. Never
    /// descends into a matched `target/`. `minSize` is a parameter so tests can use 0.
    static func findRustTargetsRecursive(
        in dir: String, depth: Int, maxDepth: Int, fm: FileManager,
        found: inout [String], breakdown: inout [PathStat],
        totalSize: inout Int64, totalCount: inout Int,
        minSize: Int64 = 1_000_000,
        isCancelled: () -> Bool = { false }
    ) {
        guard !isCancelled() else { return }
        guard depth < maxDepth else { return }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let entrySet = Set(entries)

        // This directory is a Rust project root with a build dir.
        if entrySet.contains("Cargo.toml"), entrySet.contains("target") {
            let targetPath = (dir as NSString).appendingPathComponent("target")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: targetPath, isDirectory: &isDir), isDir.boolValue {
                let (sz, ct) = directorySizeSync(targetPath, isCancelled: isCancelled)
                if sz >= minSize {
                    found.append(targetPath)
                    breakdown.append(PathStat(path: targetPath, size: sz, fileCount: ct))
                    totalSize += sz
                    totalCount += ct
                }
            }
        }

        for entry in entries {
            if isCancelled() { break }
            autoreleasepool {
                let fullPath = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { return }
                // Never descend into a target dir or noisy/heavy dirs.
                if entry == "target" || entry == "node_modules" || entry == "Library"
                    || entry.hasPrefix(".") { return }
                findRustTargetsRecursive(
                    in: fullPath, depth: depth + 1, maxDepth: maxDepth, fm: fm,
                    found: &found, breakdown: &breakdown,
                    totalSize: &totalSize, totalCount: &totalCount,
                    minSize: minSize, isCancelled: isCancelled
                )
            }
        }
    }

    // MARK: - Mail Attachments

    private func scanMailAttachments() async -> CleanupCategory? {
        let mailDir = "\(Self.home)/Library/Mail"
        guard FileManager.default.fileExists(atPath: mailDir) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let fm = FileManager.default
                // Mail Downloads contains cached attachments
                let attachmentsDir = "\(Self.home)/Library/Mail Downloads"
                var paths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                if fm.fileExists(atPath: attachmentsDir) {
                    let (sz, ct) = Self.directorySizeSync(
                        attachmentsDir,
                        isCancelled: { self.cancelRequested }
                    )
                    if sz > 100_000 {
                        paths.append(attachmentsDir)
                        breakdown.append(PathStat(path: attachmentsDir, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                }

                // Also check Containers mail downloads
                let containerMail = "\(Self.home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
                if fm.fileExists(atPath: containerMail) {
                    let (sz, ct) = Self.directorySizeSync(
                        containerMail,
                        isCancelled: { self.cancelRequested }
                    )
                    if sz > 100_000 {
                        paths.append(containerMail)
                        breakdown.append(PathStat(path: containerMail, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                }

                guard totalSize > 500_000, !paths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Mail Attachments"), stableName: "Mail Attachments", icon: "envelope.badge.shield.half.filled", color: .blue,
                    description: String(localized: "Cached mail attachment downloads — re-downloaded from server"),
                    group: .system, safetyLevel: .safe,
                    paths: paths, breakdown: breakdown,
                    deleteChildrenOnly: true,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    // MARK: - Orphaned App Data

    private func scanOrphanedAppData() async -> CleanupCategory? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let fm = FileManager.default
                // Get list of installed app bundle IDs
                let installedBundleIDs = Self.getInstalledAppBundleIDs()

                var orphanPaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                // Check ~/Library/Application Support for orphaned app data
                let supportDir = "\(Self.home)/Library/Application Support"
                if let entries = try? fm.contentsOfDirectory(atPath: supportDir) {
                    for entry in entries {
                        if self.cancelRequested { break }
                        // Skip system/common directories
                        let skipNames: Set<String> = [
                            "com.apple.TCC", "com.apple.sharedfilelist",
                            "AddressBook", "CloudDocs", "CrashReporter",
                            "FileProvider", "Knowledge", "SyncServices",
                            "CallHistoryDB", "CallHistoryTransactions",
                            "Accounts", "iLifeMediaBrowser",
                        ]
                        if entry.hasPrefix("com.apple.") || skipNames.contains(entry) { continue }
                        // Skip our own app data
                        let ownID = Bundle.main.bundleIdentifier ?? "gk.SparkClean"
                        if entry == ownID || entry == "gk.SparkClean" || entry == "SparkClean" { continue }

                        // Check if this looks like a bundle ID or app name
                        let fullPath = (supportDir as NSString).appendingPathComponent(entry)
                        guard !self.overlapsScannedPath(fullPath),
                              Self.deletionPolicy.isStableAllowedRoot(fullPath),
                              Self.deletionPolicy.validate(
                                  fullPath,
                                  allowedRoots: [fullPath]
                              ),
                              let values = try? URL(fileURLWithPath: fullPath)
                                  .resourceValues(forKeys: [
                                      .isSymbolicLinkKey, .isUbiquitousItemKey,
                                  ]),
                              values.isSymbolicLink != true,
                              values.isUbiquitousItem != true
                        else { continue }
                        // If it matches a bundle ID pattern and the app isn't installed
                        if entry.contains(".") && entry.count > 5 {
                            if !installedBundleIDs.contains(entry) &&
                               !Self.hasMatchingApp(name: entry, bundleIDs: installedBundleIDs) {
                                let (sz, ct) = Self.directorySizeSync(
                                    fullPath,
                                    isCancelled: { self.cancelRequested }
                                )
                                if sz > 1_000_000 { // >1MB
                                    orphanPaths.append(fullPath)
                                    breakdown.append(PathStat(path: fullPath, size: sz, fileCount: ct))
                                    totalSize += sz
                                    totalCount += ct
                                }
                            }
                        }
                    }
                }

                // Check ~/Library/Preferences for orphaned plists
                let prefsDir = "\(Self.home)/Library/Preferences"
                // System plists that are NOT app leftovers (macOS services, agents, daemons)
                let systemPlistPrefixes: [String] = [
                    "com.apple.", "com.microsoft.", "group.",
                    "NSGlobalDomain", "Apple", "systemgroup.",
                ]
                let systemPlistNames: Set<String> = [
                    ".GlobalPreferences", ".GlobalPreferences_m",
                    "loginwindow", "pbs", "systempreferences",
                    "diagnostics_agent", "sharedfilelistd",
                    "ContextStoreAgent", "ScopedBookmarkAgent",
                    "MobileMeAccounts", "familycircled",
                    "mbuseragent", "icloudmailagent",
                    "knowledge-agent", "remindd",
                    "sharingd", "rapportd", "CloudPhotosConfiguration",
                    "symbolichotkeys", "spaces", "dock",
                    "HIToolbox", "universalaccess",
                    "embeddedBinaryValidationUtility",
                    "APMAnalyticsSuiteName", "APMExperimentSuiteName",
                    "WirelessRadioManagerModule", "CoreBluetooth",
                    "UserEventAgent-Aqua", "UserEventAgent-System",
                    "talagent", "cmfsyncagent",
                ]
                // Exclude our own app's bundle ID
                let ownBundlePrefix = Bundle.main.bundleIdentifier ?? "gk.SparkClean"

                if let entries = try? fm.contentsOfDirectory(atPath: prefsDir) {
                    for entry in entries where entry.hasSuffix(".plist") {
                        if self.cancelRequested { break }
                        let bundleID = String(entry.dropLast(6)) // remove .plist
                        // Skip system prefixes
                        if systemPlistPrefixes.contains(where: { bundleID.hasPrefix($0) }) { continue }
                        // Skip known system plist names
                        if systemPlistNames.contains(bundleID) { continue }
                        // Skip our own app
                        if bundleID.hasPrefix(ownBundlePrefix) || bundleID == "gk.SparkClean" { continue }
                        // Skip plists that don't look like bundle IDs (no dots = likely system)
                        if !bundleID.contains(".") { continue }

                        if !installedBundleIDs.contains(bundleID) &&
                           !Self.hasMatchingApp(name: bundleID, bundleIDs: installedBundleIDs) {
                            let fullPath = (prefsDir as NSString).appendingPathComponent(entry)
                            guard !self.overlapsScannedPath(fullPath),
                                  Self.deletionPolicy.isStableAllowedRoot(fullPath),
                                  Self.deletionPolicy.validate(
                                      fullPath,
                                      allowedRoots: [fullPath]
                                  ),
                                  let values = try? URL(fileURLWithPath: fullPath)
                                      .resourceValues(forKeys: [
                                          .isSymbolicLinkKey, .isUbiquitousItemKey,
                                      ]),
                                  values.isSymbolicLink != true,
                                  values.isUbiquitousItem != true
                            else { continue }
                            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                               let sz = attrs[.size] as? Int64, sz > 0 {
                                orphanPaths.append(fullPath)
                                breakdown.append(PathStat(path: fullPath, size: sz, fileCount: 1))
                                totalSize += sz
                                totalCount += 1
                            }
                        }
                    }
                }

                guard totalSize > 1_000_000, !orphanPaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }
                for path in orphanPaths { self.insertScannedPath(path) }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "App Leftovers"), stableName: "App Leftovers", icon: "trash.slash", color: .purple,
                    description: String(localized: "\(orphanPaths.count) leftover files from uninstalled apps"),
                    group: .applications, safetyLevel: .review,
                    paths: orphanPaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: totalCount,
                    isSelected: false
                ))
            }
        }
    }

    private static func getInstalledAppBundleIDs() -> Set<String> {
        let fm = FileManager.default
        var ids = Set<String>()
        for dir in ["/Applications", "\(home)/Applications"] {
            guard let contents = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where url.pathExtension == "app" {
                if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                    ids.insert(id)
                }
                // Also add the app name as a pseudo-ID
                ids.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        return ids
    }

    private static func hasMatchingApp(name: String, bundleIDs: Set<String>) -> Bool {
        let nameLower = name.lowercased()
        // Direct match
        if bundleIDs.contains(where: { $0.lowercased() == nameLower }) { return true }

        // Extract last component of bundle-ID-style names (e.g. "org.mozilla.firefox" -> "firefox")
        // Only match if the extracted name is specific enough (>= 5 chars) to avoid false positives
        let components = name.components(separatedBy: ".")
        if components.count >= 3, let appName = components.last, appName.count >= 5 {
            let appNameLower = appName.lowercased()
            for bundleID in bundleIDs {
                let idComponents = bundleID.lowercased().components(separatedBy: ".")
                if let idAppName = idComponents.last, idAppName == appNameLower { return true }
            }
        }

        // Check if any installed bundle ID shares the same domain-reversed prefix
        // e.g. "com.example.app" matches "com.example.app.helper"
        if components.count >= 3 {
            let prefix = components.prefix(3).joined(separator: ".").lowercased()
            for bundleID in bundleIDs {
                if bundleID.lowercased().hasPrefix(prefix) { return true }
            }
        }

        return false
    }

    // MARK: - New Feature Scans

    /// Feature 1: Large Files Scanner
    private func scanLargeFiles() async -> CleanupCategory? {
        let thresholdMB = settingLargeFileThresholdMB
        let thresholdBytes = Int64(thresholdMB) * 1_000_000
        let dirs = settingLargeFileScanDirs
        let includeVideos = settingLargeFileIncludeVideos
        let includeImages = settingLargeFileIncludeImages
        let includeArchives = settingLargeFileIncludeArchives
        let includeInstallers = settingLargeFileIncludeInstallers
        let includeAudio = settingLargeFileIncludeAudio
        let includeOther = settingLargeFileIncludeOther
        let maxAgeDays = settingLargeFileMaxAgeDays
        let maxResults = settingLargeFileMaxResults

        let packageExtensions: Set<String> = ["vmwarevm", "pvs", "fcpbundle", "sparseimage", "sparsebundle",
                                               "photoslibrary", "band", "logicx", "rtfd", "pages", "numbers", "key"]
        let videoExts: Set<String> = ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "ts", "mts", "vob", "mpg", "mpeg"]
        let imageExts: Set<String> = ["raw", "cr2", "cr3", "nef", "arw", "dng", "tiff", "tif", "psd", "ai", "bmp", "svg", "eps"]
        let archiveExts: Set<String> = ["zip", "tar", "gz", "7z", "rar", "bz2", "xz", "tgz", "zst", "lz", "cab", "sit", "sitx"]
        let installerExts: Set<String> = ["dmg", "pkg", "iso", "msi", "app"]
        let audioExts: Set<String> = ["wav", "flac", "aiff", "aif", "alac", "mp3", "m4a", "ogg", "wma", "ape", "dsd", "dsf"]

        guard !dirs.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                let ageThreshold: Date? = maxAgeDays > 0
                    ? Date().addingTimeInterval(-Double(maxAgeDays) * 86400) : nil

                for dir in dirs where fm.fileExists(atPath: dir) {
                    if self.cancelRequested { break }
                    guard let enumerator = fm.enumerator(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isPackageKey,
                                                      .isSymbolicLinkKey, .contentAccessDateKey,
                                                      .isUbiquitousItemKey,
                                                      .ubiquitousItemDownloadingStatusKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) else { continue }

                    for case let url as URL in enumerator {
                        if self.cancelRequested {
                            enumerator.skipDescendants()
                            break
                        }
                        autoreleasepool {
                            guard let rv = try? url.resourceValues(
                                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isPackageKey,
                                          .isSymbolicLinkKey, .contentAccessDateKey,
                                          .isUbiquitousItemKey,
                                          .ubiquitousItemDownloadingStatusKey]
                            ) else { return }

                            if rv.isUbiquitousItem == true ||
                               rv.ubiquitousItemDownloadingStatus == .notDownloaded {
                                return
                            }
                            if rv.isSymbolicLink == true { return }
                            let ext = url.pathExtension.lowercased()
                            if rv.isPackage == true || packageExtensions.contains(ext) {
                                enumerator.skipDescendants()
                                return
                            }
                            guard rv.isRegularFile == true else { return }
                            if overlapsScannedPath(url.path) { return }
                            // Also skip files inside directories already scanned by other phases
                            // (e.g., a large file inside a folder flagged by "Old Downloads")
                            let parentDir = (url.path as NSString).deletingLastPathComponent
                            if overlapsScannedPath(parentDir) { return }

                            let size = Int64(rv.totalFileAllocatedSize ?? 0)
                            guard size >= thresholdBytes else { return }

                            // File age filter
                            if let ageThreshold, let accessed = rv.contentAccessDate, accessed > ageThreshold { return }

                            let path = url.path
                            if path.contains(".app/Contents/") || path.contains(".framework/") { return }

                            // File type filter
                            let isVideo = videoExts.contains(ext)
                            let isImage = imageExts.contains(ext)
                            let isArchive = archiveExts.contains(ext)
                            let isInstaller = installerExts.contains(ext)
                            let isAudio = audioExts.contains(ext)
                            let isKnown = isVideo || isImage || isArchive || isInstaller || isAudio

                            if isVideo && !includeVideos { return }
                            if isImage && !includeImages { return }
                            if isArchive && !includeArchives { return }
                            if isInstaller && !includeInstallers { return }
                            if isAudio && !includeAudio { return }
                            if !isKnown && !includeOther { return }

                            filePaths.append(path)
                            insertScannedPath(path)

                            breakdown.append(PathStat(path: path, size: size, fileCount: 1,
                                                       lastAccessed: rv.contentAccessDate))
                        }
                    }
                }

                breakdown.sort { $0.size > $1.size }
                let capped = Array(breakdown.prefix(maxResults))
                let cappedPaths = capped.map(\.path)
                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                let cappedSize = capped.reduce(0 as Int64) { $0 + $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Large Files (>\(thresholdMB) MB)"), stableName: "Large Files (>\(thresholdMB) MB)", icon: "doc.fill", color: .orange,
                    description: filePaths.count > capped.count
                        ? String(localized: "\(capped.count) largest matches shown of \(filePaths.count) found")
                        : String(localized: "\(capped.count) large files across user directories"),
                    group: .largeFiles, safetyLevel: .review,
                    paths: cappedPaths, breakdown: capped,
                    deleteChildrenOnly: false,
                    size: cappedSize, fileCount: capped.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 2: Virtual Environments Scanner
    private func scanVirtualEnvironments() async -> CleanupCategory? {
        let projectDirs = [
            "\(Self.home)/Projects", "\(Self.home)/Developer", "\(Self.home)/Documents",
            "\(Self.home)/Desktop", "\(Self.home)/GitHub", "\(Self.home)/repos",
            "\(Self.home)/code", "\(Self.home)/src", "\(Self.home)/dev",
            "\(Self.home)/workspace", "\(Self.home)/Work", "\(Self.home)/Sites"
        ]
        let fixedPaths: [(String, String)] = [
            ("\(Self.home)/.virtualenvs", "virtualenvwrapper"),
            ("\(Self.home)/.local/share/virtualenvs", "pipenv"),
            ("\(Self.home)/.conda/envs", "conda"),
            ("\(Self.home)/anaconda3/envs", "anaconda"),
            ("\(Self.home)/miniconda3/envs", "miniconda"),
        ]
        let skipDirs: Set<String> = [".git", "node_modules", "Pods", "DerivedData", "build", ".build",
                                       "__pycache__", ".tox", ".mypy_cache"]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                func isVenv(_ dirPath: String) -> Bool {
                    let cfg = (dirPath as NSString).appendingPathComponent("pyvenv.cfg")
                    let activate = (dirPath as NSString).appendingPathComponent("bin/activate")
                    return fm.fileExists(atPath: cfg) || fm.fileExists(atPath: activate)
                }

                // Search project directories for venvs
                func searchDir(_ base: String, depth: Int) {
                    guard !cancelRequested, depth < 4,
                          fm.fileExists(atPath: base) else { return }
                    guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return }
                    for entry in entries {
                        if cancelRequested { break }
                        if skipDirs.contains(entry) { continue }
                        let full = (base as NSString).appendingPathComponent(entry)
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

                        if (entry == "venv" || entry == ".venv" || entry == "env") && isVenv(full) {
                            addVenv(full, type: "Python venv")
                        } else if entry == "vendor" {
                            let bundlePath = (full as NSString).appendingPathComponent("bundle")
                            if fm.fileExists(atPath: bundlePath) {
                                addVenv(bundlePath, type: "Ruby Bundler")
                            }
                        } else {
                            searchDir(full, depth: depth + 1)
                        }
                    }
                }

                func addVenv(_ path: String, type _: String) {
                    if cancelRequested || overlapsScannedPath(path) { return }
                    let (size, count) = Self.directorySizeSync(
                        path,
                        isCancelled: { cancelRequested }
                    )
                    guard size >= ScanConstants.minVenvSizeBytes else { return }
                    filePaths.append(path)
                    insertScannedPath(path)
                    breakdown.append(PathStat(path: path, size: size, fileCount: count))
                    totalSize += size
                }

                // Scan fixed paths (virtualenvwrapper, pipenv, conda)
                for (basePath, type) in fixedPaths {
                    if cancelRequested { break }
                    guard fm.fileExists(atPath: basePath),
                          let entries = try? fm.contentsOfDirectory(atPath: basePath) else { continue }
                    for entry in entries {
                        if cancelRequested { break }
                        if entry == "base" { continue } // Skip conda base
                        let full = (basePath as NSString).appendingPathComponent(entry)
                        addVenv(full, type: type)
                    }
                }

                // Scan project directories
                for dir in projectDirs where fm.fileExists(atPath: dir) {
                    if cancelRequested { break }
                    searchDir(dir, depth: 0)
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }
                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Virtual Environments"), stableName: "Virtual Environments", icon: "terminal", color: .green,
                    description: String(localized: "\(filePaths.count) Python/Ruby virtual environments"),
                    group: .packageManagers, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 3: iOS Device Backups
    private func scanIOSBackups() async -> CleanupCategory? {
        let backupDir = "\(Self.home)/Library/Application Support/MobileSync/Backup"
        guard FileManager.default.fileExists(atPath: backupDir) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let fm = FileManager.default
                guard let entries = try? fm.contentsOfDirectory(atPath: backupDir) else {
                    continuation.resume(returning: nil)
                    return
                }

                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                for entry in entries {
                    if self.cancelRequested { break }
                    let full = (backupDir as NSString).appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

                    let (size, count) = Self.directorySizeSync(
                        full,
                        isCancelled: { self.cancelRequested }
                    )
                    guard size > 0 else { continue }

                    // Try to read device name from Info.plist
                    var _deviceName = entry
                    let infoPlist = (full as NSString).appendingPathComponent("Info.plist")
                    if let data = fm.contents(atPath: infoPlist),
                       let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                        if let name = plist["Device Name"] as? String {
                            _deviceName = name
                        }
                        if let date = plist["Last Backup Date"] as? Date {
                            _deviceName += " (\(Self.mediumDateFormatter.string(from: date)))"
                        }
                    }
                    filePaths.append(full)
                    breakdown.append(PathStat(path: full, size: size, fileCount: count, displayName: _deviceName))
                    totalSize += size
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "iOS Device Backups"), stableName: "iOS Device Backups", icon: "iphone", color: .blue,
                    description: String(localized: "\(filePaths.count) device backup(s) — review before deleting"),
                    group: .system, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 4: iOS Software Updates (IPSW)
    private func scanIPSWFiles() async -> CleanupCategory? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                // Direct path
                let directPath = "\(Self.home)/Library/iTunes/iPhone Software Updates"
                if fm.fileExists(atPath: directPath) {
                    let (size, count) = Self.directorySizeSync(
                        directPath,
                        isCancelled: { self.cancelRequested }
                    )
                    if size > 0 {
                        filePaths.append(directPath)
                        breakdown.append(PathStat(path: directPath, size: size, fileCount: count))
                        totalSize += size
                    }
                }

                // Group Containers wildcard
                let groupDir = "\(Self.home)/Library/Group Containers"
                if let containers = try? fm.contentsOfDirectory(atPath: groupDir) {
                    for container in containers {
                        if self.cancelRequested { break }
                        let ipswPath = (groupDir as NSString).appendingPathComponent(container + "/iPhone Software Updates")
                        if fm.fileExists(atPath: ipswPath) {
                            let (size, count) = Self.directorySizeSync(
                                ipswPath,
                                isCancelled: { self.cancelRequested }
                            )
                            if size > 0 {
                                filePaths.append(ipswPath)
                                breakdown.append(PathStat(path: ipswPath, size: size, fileCount: count))
                                totalSize += size
                            }
                        }
                    }
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "iOS Software Updates"), stableName: "iOS Software Updates", icon: "arrow.down.app", color: .blue,
                    description: String(localized: "Downloaded firmware files (IPSW) — no longer needed after update"),
                    group: .system, safetyLevel: .safe,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: true
                ))
            }
        }
    }

    /// Feature 5: iMessage Attachments
    private func scanIMessageAttachments() async -> CleanupCategory? {
        let attachDir = "\(Self.home)/Library/Messages/Attachments"
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: attachDir) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let (size, count) = Self.directorySizeSync(
                    attachDir,
                    isCancelled: { self.cancelRequested }
                )
                guard size > ScanConstants.minCacheSizeBytes else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "iMessage Attachments"), stableName: "iMessage Attachments", icon: "message.fill", color: .green,
                    description: String(localized: "Cached message attachments — deleting creates 'Missing Attachment' placeholders in Messages. May re-download if Messages in iCloud is enabled."),
                    group: .system, safetyLevel: .caution,
                    paths: [attachDir],
                    breakdown: [PathStat(path: attachDir, size: size, fileCount: count)],
                    deleteChildrenOnly: true,
                    size: size, fileCount: count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 7: Screen Recordings
    private func scanScreenRecordings() async -> CleanupCategory? {
        let thresholdDays = settingScreenRecordingThresholdDays
        let threshold = Date().addingTimeInterval(-Double(thresholdDays) * 86400)
        let minSize: Int64 = 50_000_000 // 50MB

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                // Try mdfind first for fast detection
                var spotlightPaths: Set<String> = []
                if let output = Self.runCommand("/usr/bin/mdfind", arguments: ["kMDItemIsScreenCapture == 1"]) {
                    for line in output.components(separatedBy: "\n") where !line.isEmpty {
                        spotlightPaths.insert(line)
                    }
                }

                let dirs = ["\(Self.home)/Desktop", "\(Self.home)/Movies"]
                for dir in dirs where fm.fileExists(atPath: dir) {
                    if cancelRequested { break }
                    guard let contents = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [
                            .isRegularFileKey, .isSymbolicLinkKey,
                            .isUbiquitousItemKey, .totalFileAllocatedSizeKey,
                            .fileSizeKey, .contentModificationDateKey,
                        ],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for url in contents {
                        if cancelRequested { break }
                        let ext = url.pathExtension.lowercased()
                        guard ext == "mov" || ext == "mp4" else { continue }

                        let isScreenRecording = spotlightPaths.contains(url.path) ||
                            url.lastPathComponent.lowercased().hasPrefix("screen recording") ||
                            url.lastPathComponent.lowercased().hasPrefix("simulator screen recording") ||
                            url.lastPathComponent.lowercased().hasPrefix("capture")

                        guard isScreenRecording else { continue }
                        guard let rv = try? url.resourceValues(forKeys: [
                                  .isRegularFileKey, .isSymbolicLinkKey,
                                  .isUbiquitousItemKey,
                                  .totalFileAllocatedSizeKey, .fileSizeKey,
                                  .contentModificationDateKey,
                              ]),
                              rv.isRegularFile == true,
                              rv.isSymbolicLink != true,
                              rv.isUbiquitousItem != true
                        else { continue }

                        let size = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                        let modDate = rv.contentModificationDate ?? Date.distantPast
                        guard size >= minSize, modDate < threshold else { continue }
                        guard !overlapsScannedPath(url.path) else { continue }

                        filePaths.append(url.path)
                        insertScannedPath(url.path)
                        breakdown.append(PathStat(path: url.path, size: size, fileCount: 1))
                        totalSize += size
                    }
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Screen Recordings (>\(thresholdDays)d)"), stableName: "Screen Recordings (>\(thresholdDays)d)", icon: "record.circle", color: .teal,
                    description: String(localized: "\(filePaths.count) old screen recordings over 50 MB"),
                    group: .storage, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 8: Broken Symlinks
    ///
    /// Directories excluded from the `~/Library` walk. Beyond the original set, this
    /// skips cloud-storage file-provider mounts (Dropbox/Google Drive/OneDrive) and
    /// other heavy trees where enumeration can trigger network metadata fetches and
    /// effectively hang — the root cause of the "Scanning broken symlinks…" stall
    /// (issue #9).
    static let brokenSymlinkExcludeDirs: Set<String> = [
        "Keychains", "Group Containers", "Mail", "Caches", "Containers", "Developer",
        // Added for issue #9: cloud + heavy provider trees
        "CloudStorage", "Mobile Documents", "Photos", "Biome", "Metadata",
        "Daemon Containers", "Autosave Information"
    ]

    /// Traversal depth cap for the `~/Library` root. Broken symlinks deeper than this
    /// are effectively never user-cleanable, and the cap prevents pathological trees
    /// from wedging the scan.
    static let brokenSymlinkMaxDepth = 6

    /// Absolute safety valve on total entries visited across all roots.
    static let brokenSymlinkMaxIterations = 200_000

    private func scanBrokenSymlinks() async -> CleanupCategory? {
        let roots = [
            "\(Self.home)/Library",
            "/opt/homebrew/bin"
        ]
        // Only the deep `~/Library` tree gets a depth cap; the bin dirs are flat.
        let depthCappedRoots: Set<String> = ["\(Self.home)/Library"]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = Self.findBrokenSymlinks(
                    roots: roots,
                    excludeDirs: Self.brokenSymlinkExcludeDirs,
                    depthCappedRoots: depthCappedRoots,
                    maxDepth: Self.brokenSymlinkMaxDepth,
                    maxIterations: Self.brokenSymlinkMaxIterations,
                    isCancelled: { self.cancelRequested }
                )

                // Partial results are acceptable — if the walk was cancelled or hit the
                // watchdog after finding some broken links, still surface them.
                let breakdown = result.breakdown.filter {
                    !self.overlapsScannedPath($0.path)
                }
                let paths = breakdown.map(\.path)
                guard !paths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                for path in paths { self.insertScannedPath(path) }
                let suffix = result.wasCancelled
                    ? String(localized: " · partial scan (cancelled)")
                    : (result.hitWatchdog
                        ? String(localized: " · partial scan (safety limit)")
                        : "")

                continuation.resume(returning: CleanupCategory(
                    name: String(localized: "Broken Symlinks (\(paths.count) found)"), stableName: "Broken Symlinks (\(paths.count) found)", icon: "link", color: .gray,
                    description: String(localized: "Symbolic links pointing to nonexistent targets\(suffix)"),
                    group: .system, safetyLevel: .review,
                    paths: paths, allowedRoots: roots,
                    allowsSymbolicLinkItems: true,
                    breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: 0, fileCount: paths.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Outcome of a broken-symlink walk. `wasCancelled`/`hitWatchdog` let callers and
    /// tests distinguish a complete walk from an interrupted one.
    struct BrokenSymlinkScanResult {
        var filePaths: [String] = []
        var breakdown: [PathStat] = []
        var wasCancelled = false
        var hitWatchdog = false
    }

    /// Pure, testable core of the broken-symlink scan.
    ///
    /// Checks `isCancelled()` on every iteration so the scan stops promptly when the
    /// user hits Cancel (the second half of issue #9), caps traversal depth under
    /// `depthCappedRoots`, and bails after `maxIterations` entries as a last resort.
    static func findBrokenSymlinks(
        roots: [String],
        excludeDirs: Set<String>,
        depthCappedRoots: Set<String>,
        maxDepth: Int,
        maxIterations: Int,
        isCancelled: () -> Bool
    ) -> BrokenSymlinkScanResult {
        let fm = FileManager.default
        var result = BrokenSymlinkScanResult()
        var iterations = 0
        let resourceKeys: [URLResourceKey] = [.isSymbolicLinkKey, .isUbiquitousItemKey]

        outer: for root in roots where fm.fileExists(atPath: root) {
            let capDepth = depthCappedRoots.contains(root)
            let options: FileManager.DirectoryEnumerationOptions = capDepth
                ? [.skipsPackageDescendants, .skipsHiddenFiles]
                : [.skipsPackageDescendants]
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: resourceKeys,
                options: options
            ) else { continue }

            while let obj = enumerator.nextObject() {
                // Prompt cancellation — break out of both loops.
                if isCancelled() {
                    result.wasCancelled = true
                    break outer
                }
                iterations += 1
                if iterations >= maxIterations {
                    result.hitWatchdog = true
                    break outer
                }

                guard let url = obj as? URL else { continue }
                autoreleasepool {
                    // Depth cap (only for flagged roots). enumerator.level is 1 at the
                    // first level below the root.
                    if capDepth && enumerator.level > maxDepth {
                        enumerator.skipDescendants()
                        return
                    }

                    // Skip excluded directories (and their subtrees).
                    let components = url.pathComponents
                    if components.contains(where: { excludeDirs.contains($0) }) {
                        enumerator.skipDescendants()
                        return
                    }

                    let rv = try? url.resourceValues(forKeys: Set(resourceKeys))

                    // Never descend into iCloud/file-provider materialization points.
                    if rv?.isUbiquitousItem == true {
                        enumerator.skipDescendants()
                        return
                    }

                    guard rv?.isSymbolicLink == true else { return }

                    // Detect broken symlink
                    guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return }
                    let resolvedTarget: String
                    if target.hasPrefix("/") {
                        resolvedTarget = target
                    } else {
                        resolvedTarget = ((url.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
                    }

                    // Skip if target is on external volume
                    if resolvedTarget.hasPrefix("/Volumes/") { return }

                    if !fm.fileExists(atPath: resolvedTarget) {
                        result.filePaths.append(url.path)
                        result.breakdown.append(PathStat(path: url.path, size: 0, fileCount: 1))
                    }
                }
            }
        }

        return result
    }

    /// Component-boundary overlap used when a parent scan definition excludes a child
    /// definition. A direct child that is itself an ancestor of an excluded path must
    /// also be preserved; otherwise deleting that child would delete the exclusion.
    static func path(_ candidate: String, overlapsAny exclusions: [String]) -> Bool {
        let normalizedCandidate = URL(fileURLWithPath: candidate)
            .standardizedFileURL.path
        return exclusions.contains { exclusion in
            let normalizedExclusion = URL(fileURLWithPath: exclusion)
                .standardizedFileURL.path
            return normalizedCandidate == normalizedExclusion ||
                normalizedCandidate.hasPrefix(normalizedExclusion + "/") ||
                normalizedExclusion.hasPrefix(normalizedCandidate + "/")
        }
    }

    // MARK: - Helpers

    /// Measure a candidate old-download directory only when a complete bounded walk
    /// proves every contained file is older than `threshold`. `nil` means "leave it
    /// alone": the tree was active, unreadable, cancelled, too large to verify, or
    /// contained a symlink, package, cloud item, or special filesystem entry.
    static func oldDirectoryContentStat(
        _ path: String,
        olderThan threshold: Date,
        maximumEntries: Int = 100_000,
        isCancelled: () -> Bool = { false }
    ) -> (Int64, Int)? {
        let fm = FileManager.default
        guard let rootValues = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [
                .isSymbolicLinkKey, .isUbiquitousItemKey, .isVolumeKey,
            ]),
            rootValues.isSymbolicLink != true,
            rootValues.isUbiquitousItem != true,
            rootValues.isVolume != true
        else { return nil }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .isUbiquitousItemKey, .isPackageKey, .isVolumeKey,
            .contentModificationDateKey, .totalFileAllocatedSizeKey,
            .fileSizeKey,
        ]
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { return nil }

        var totalSize: Int64 = 0
        var fileCount = 0
        var visited = 0
        while let obj = enumerator.nextObject() {
            if isCancelled() { return nil }
            visited += 1
            if visited > maximumEntries { return nil }
            guard let url = obj as? URL,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isUbiquitousItem != true,
                  values.isPackage != true,
                  values.isVolume != true
            else { return nil }

            if values.isDirectory == true { continue }
            guard values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < threshold
            else { return nil }
            totalSize += Int64(
                values.totalFileAllocatedSize ?? values.fileSize ?? 0
            )
            fileCount += 1
        }
        return enumerationFailed ? nil : (totalSize, fileCount)
    }

    static func findDocker() -> String? {
        for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    static func googleDriveContentCachePaths(
        in driveFSRoot: String,
        fileManager fm: FileManager = .default
    ) -> [String] {
        guard let accountDirectories = try? fm.contentsOfDirectory(atPath: driveFSRoot) else {
            return []
        }
        return accountDirectories.compactMap { account in
            let path = URL(fileURLWithPath: driveFSRoot)
                .appendingPathComponent(account, isDirectory: true)
                .appendingPathComponent("content_cache", isDirectory: true)
                .path
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? path
                : nil
        }.sorted()
    }

    static func findOllama() -> String? {
        for path in ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama", "/usr/bin/ollama"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    static func runCommand(_ path: String, arguments: [String], timeout: TimeInterval = 30) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Drain stdout and stderr through the same pipe. Leaving stderr on an unread
        // pipe can deadlock once its kernel buffer fills.
        process.standardError = pipe
        do {
            try process.run()

            // Terminate the process if it exceeds the timeout
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    let pid = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning {
                            kill(pid, SIGKILL)
                        }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            // Read pipe data BEFORE waitUntilExit to prevent deadlock when output exceeds pipe buffer (~64KB)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutWorkItem.cancel()

            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func parseDockerSize(_ str: String) -> Int64 {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        let pattern = /^([\d.]+)\s*(B|KB|MB|GB|TB|kB)/
        guard let match = trimmed.firstMatch(of: pattern) else { return 0 }
        let value = Double(match.1) ?? 0
        switch String(match.2).uppercased() {
        case "B": return Int64(value)
        case "KB": return Int64(value * 1_000)
        case "MB": return Int64(value * 1_000_000)
        case "GB": return Int64(value * 1_000_000_000)
        case "TB": return Int64(value * 1_000_000_000_000)
        default: return 0
        }
    }

    static func parseDockerReclaimedSize(_ output: String) -> Int64? {
        for line in output.components(separatedBy: "\n").reversed()
        where line.localizedCaseInsensitiveContains("total reclaimed space") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let value = String(line[line.index(after: separator)...])
            return parseDockerSize(value)
        }
        return nil
    }

    // MARK: - Export Report

    func exportReport() -> String {
        exportDetailedReport(verbose: false)
    }

    func exportDetailedReport(verbose: Bool) -> String {
        let dateStr = Date().formatted(date: .long, time: .standard)
        let reportTitle = String(localized: "SparkClean - Detailed Scan Audit Report")
        let generated = String(localized: "Generated: \(dateStr)")
        var r = """
        ╔═══════════════════════════════════════════════════════════════════╗
        ║  \(reportTitle)
        ║  \(generated)
        ╚═══════════════════════════════════════════════════════════════════╝

        """

        // System info
        r += String(localized: "SYSTEM INFORMATION") + "\n"
        r += String(repeating: "─", count: 60) + "\n"
        r += "  " + String(localized: "macOS Version:") + " \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        r += "  " + String(localized: "Machine:") + " \(Self.runCommand("/usr/sbin/sysctl", arguments: ["-n", "hw.model"]) ?? String(localized: "Unknown"))\n"
        r += "  " + String(localized: "User:") + " \(NSUserName())\n"
        r += "  " + String(localized: "Home:") + " \(AppLocalization.isolateTechnicalText(Self.home))\n\n"

        if let disk = diskUsage {
            r += String(localized: "DISK USAGE") + "\n"
            r += String(repeating: "─", count: 60) + "\n"
            r += "  " + String(localized: "Total Space:") + " \(Self.formatBytes(disk.totalSpace))\n"
            r += "  " + String(localized: "Used Space:") + " \(Self.formatBytes(disk.usedSpace)) (\(disk.usedPercentage.formatted(.percent.precision(.fractionLength(1)))))\n"
            r += "  " + String(localized: "Free Space:") + " \(Self.formatBytes(disk.freeSpace))\n"
            r += "  " + String(localized: "Purgeable:") + " \(Self.formatBytes(disk.purgeableSpace))\n"
            r += "  " + String(localized: "Reclaimable:") + " \(Self.formatBytes(overallSize))\n"
            r += "  " + String(localized: "Selected:") + " \(Self.formatBytes(totalSize))\n\n"
        }

        if let summary = lastScanSummary {
            r += String(localized: "SCAN SUMMARY") + "\n"
            r += String(repeating: "─", count: 60) + "\n"
            r += "  " + String(localized: "Categories:") + " \(summary.totalCategories)\n"
            r += "  " + String(localized: "Total Files:") + " \(summary.totalFiles)\n"
            r += "  " + String(localized: "Total Size:") + " \(Self.formatBytes(summary.totalSize))\n"
            let duration = summary.scanDuration.formatted(
                .number.precision(.fractionLength(2))
            )
            r += "  " + String(localized: "Scan Duration:") + " "
                + String(localized: "\(duration) seconds") + "\n"
            r += "  " + String(localized: "Scan Time:") + " \(summary.timestamp.formatted(date: .abbreviated, time: .standard))\n\n"
        }

        r += "═══════════════════════════════════════════════════════════════════\n"
        r += String(localized: "DETAILED FINDINGS BY CATEGORY") + "\n"
        r += "═══════════════════════════════════════════════════════════════════\n\n"

        for group in CategoryGroup.allCases {
            let groupCats = categoriesForGroup(group)
            guard !groupCats.isEmpty else { continue }

            r += "┌─── \(group.displayName.uppercased()) ─── " + String(localized: "\(Self.formatBytes(sizeForGroup(group))) total") + "\n"
            r += "│\n"

            for (catIdx, cat) in groupCats.enumerated() {
                let isLast = catIdx == groupCats.count - 1
                let prefix = isLast ? "└" : "├"
                let childPrefix = isLast ? "  " : "│ "
                let marker = cat.isSelected ? "✓" : "○"

                r += "\(prefix)── [\(marker)] \(cat.name)\n"
                r += "\(childPrefix)   " + String(localized: "Safety:") + " \(cat.safetyLevel.displayName) — \(cat.safetyLevel.label)\n"
                r += "\(childPrefix)   " + String(localized: "Description:") + " \(cat.description)\n"
                if let warning = cat.cleanupWarning, !warning.isEmpty {
                    r += "\(childPrefix)   " + String(localized: "Warning:") + " \(warning)\n"
                }
                r += "\(childPrefix)   " + String(localized: "Total Size:") + " \(Self.formatBytes(cat.size))\n"
                r += "\(childPrefix)   " + String(localized: "File Count:") + " \(cat.fileCount)\n"
                r += "\(childPrefix)   " + String(localized: "Selected:") + " \(cat.isSelected ? String(localized: "Yes") : String(localized: "No"))\n"

                if cat.isDockerResource {
                    r += "\(childPrefix)   " + String(localized: "Type: Docker resource (cleaned via Docker CLI)") + "\n"
                    if let cmd = cat.dockerCleanCommand {
                        let command = AppLocalization.isolateTechnicalText(
                            "docker " + cmd.joined(separator: " ")
                        )
                        r += "\(childPrefix)   " + String(localized: "Command:") + " \(command)\n"
                    }
                }

                if cat.isOllamaResource {
                    r += "\(childPrefix)   " + String(localized: "Type: Ollama model (cleaned via `ollama rm`)") + "\n"
                }

                if !cat.paths.isEmpty {
                    r += "\(childPrefix)   " + String(localized: "Paths:") + "\n"
                    for path in cat.paths {
                        r += "\(childPrefix)     → \(AppLocalization.isolateTechnicalText(path))\n"
                    }
                }

                // Detailed breakdown — ALL entries, not just top 5
                if !cat.breakdown.isEmpty {
                    r += "\(childPrefix)   " + String(localized: "Breakdown (\(cat.breakdown.count) entries):") + "\n"
                    for stat in cat.breakdown {
                        let name = (stat.path as NSString).lastPathComponent
                        let dir = (stat.path as NSString).deletingLastPathComponent
                        r += "\(childPrefix)     ┊ \(Self.formatBytes(stat.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(name)\n"
                        if verbose {
                            r += "\(childPrefix)     ┊ " + String(localized: "Path:") + " \(AppLocalization.isolateTechnicalText(stat.path))\n"
                            r += "\(childPrefix)     ┊ " + String(localized: "Directory:") + " \(AppLocalization.isolateTechnicalText(dir))\n"
                            r += "\(childPrefix)     ┊ " + String(localized: "Files:") + " \(stat.fileCount)\n"
                            if let accessed = stat.lastAccessed {
                                r += "\(childPrefix)     ┊ " + String(localized: "Last Accessed:") + " \(accessed.formatted(date: .abbreviated, time: .standard))\n"
                            }
                        }
                    }
                }

                r += "\(childPrefix)\n"
            }
            r += "\n"
        }

        // Safety summary
        r += "═══════════════════════════════════════════════════════════════════\n"
        r += String(localized: "SAFETY AUDIT SUMMARY") + "\n"
        r += "═══════════════════════════════════════════════════════════════════\n\n"

        let safeCats = categories.filter { $0.safetyLevel == .safe }
        let reviewCats = categories.filter { $0.safetyLevel == .review }
        let cautionCats = categories.filter { $0.safetyLevel == .caution }

        let safeSize = safeCats.reduce(0 as Int64) { $0 + $1.size }
        let reviewSize = reviewCats.reduce(0 as Int64) { $0 + $1.size }
        let cautionSize = cautionCats.reduce(0 as Int64) { $0 + $1.size }

        r += "  ✓ " + String(localized: "SAFE (\(safeCats.count) categories, \(Self.formatBytes(safeSize))):") + "\n"
        r += "    " + String(localized: "Regenerable caches, reviewed temporary files, and logs. Trash-first recovery still depends on the item remaining in Trash.") + "\n"
        for cat in safeCats {
            r += "    • \(cat.name): \(Self.formatBytes(cat.size))\n"
        }

        r += "\n  ⚠ " + String(localized: "REVIEW (\(reviewCats.count) categories, \(Self.formatBytes(reviewSize))):") + "\n"
        r += "    " + String(localized: "User files that may be wanted — review before deleting.") + "\n"
        for cat in reviewCats {
            r += "    • \(cat.name): \(Self.formatBytes(cat.size))\n"
        }

        r += "\n  ✕ " + String(localized: "CAUTION (\(cautionCats.count) categories, \(Self.formatBytes(cautionSize))):") + "\n"
        r += "    " + String(localized: "App data or system files — could cause issues if deleted.") + "\n"
        for cat in cautionCats {
            r += "    • \(cat.name): \(Self.formatBytes(cat.size))\n"
        }

        r += "\n═══════════════════════════════════════════════════════════════════\n"
        r += String(localized: "END OF REPORT") + "\n"
        r += "═══════════════════════════════════════════════════════════════════\n"

        return r
    }

    // MARK: - Formatting

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useAll]
        f.countStyle = .file
        return f
    }()

    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let spotlightDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
