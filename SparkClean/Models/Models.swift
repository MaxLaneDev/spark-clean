//
//  Models.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import Foundation
import SwiftUI

// MARK: - Category Group

enum CategoryGroup: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case storage = "Storage"
    case browsers = "Browsers"
    case developer = "Developer Tools"
    case packageManagers = "Package Managers"
    case largeFiles = "Large Files"
    case privacy = "Privacy"
    case docker = "Docker"
    case applications = "Applications"

    var id: String { rawValue }

    /// Localized display text. `rawValue` remains a stable Codable/identity key.
    var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .storage: String(localized: "Storage")
        case .browsers: String(localized: "Browsers")
        case .developer: String(localized: "Developer Tools")
        case .packageManagers: String(localized: "Package Managers")
        case .largeFiles: String(localized: "Large Files")
        case .privacy: String(localized: "Privacy")
        case .docker: String(localized: "Docker")
        case .applications: String(localized: "Applications")
        }
    }

    var icon: String {
        switch self {
        case .system: "gearshape.2"
        case .storage: "externaldrive"
        case .browsers: "globe"
        case .developer: "hammer"
        case .packageManagers: "shippingbox"
        case .largeFiles: "doc.fill"
        case .privacy: "hand.raised"
        case .docker: "cube.box"
        case .applications: "app.badge.checkmark"
        }
    }

    var color: Color {
        switch self {
        case .system: .blue
        case .storage: .teal
        case .browsers: .orange
        case .developer: .pink
        case .packageManagers: .green
        case .largeFiles: .yellow
        case .privacy: .indigo
        case .docker: .cyan
        case .applications: .purple
        }
    }
}

// MARK: - Safety Level

enum SafetyLevel: String, Codable {
    case safe = "Safe"
    case review = "Review"
    case caution = "Caution"

    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .caution: .red
        }
    }

    var icon: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .caution: "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .safe: String(localized: "Safe to delete")
        case .review: String(localized: "Review before deleting")
        case .caution: String(localized: "Use caution")
        }
    }

    var displayName: String {
        switch self {
        case .safe: String(localized: "Safe")
        case .review: String(localized: "Review")
        case .caution: String(localized: "Caution")
        }
    }
}

// MARK: - Constants

enum ScanConstants {
    static let minCacheSizeBytes: Int64 = 100_000       // 100KB
    static let minSystemCacheSizeBytes: Int64 = 500_000 // 500KB
    static let minNodeModulesSizeBytes: Int64 = 1_000_000 // 1MB
    static let minCacheTotalBytes: Int64 = 500_000      // 500KB
    static let minSystemCacheTotalBytes: Int64 = 1_000_000 // 1MB
    static let installerFileAgeDays = 14
    static let secondsPerDay: Double = 86400
    static let minVenvSizeBytes: Int64 = 50_000_000  // 50MB
    static let minDuplicateSizeBytes: Int64 = 1_000_000  // 1MB
    static let maxDuplicateFileSize: Int64 = 2_147_483_648  // 2GB
}

// MARK: - Data Models

struct PathStat: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    let fileCount: Int
    let fileIdentity: FileRemover.FileIdentity?
    var children: [PathStat] = []
    var lastAccessed: Date? = nil
    var isSelected: Bool = true
    var displayName: String? = nil

    init(
        path: String,
        size: Int64,
        fileCount: Int,
        children: [PathStat] = [],
        lastAccessed: Date? = nil,
        isSelected: Bool = true,
        displayName: String? = nil,
        fileIdentity: FileRemover.FileIdentity? = nil
    ) {
        self.path = path
        self.size = size
        self.fileCount = fileCount
        self.fileIdentity = fileIdentity ??
            (path.hasPrefix("/") ? FileRemover.fileIdentity(at: path) : nil)
        self.children = children
        self.lastAccessed = lastAccessed
        self.isSelected = isSelected
        self.displayName = displayName
    }
}

struct CleanupCategory: Identifiable, Equatable {
    static func == (lhs: CleanupCategory, rhs: CleanupCategory) -> Bool {
        lhs.id == rhs.id
    }

    let id = UUID()
    let name: String
    let icon: String
    let color: Color
    var description: String
    /// A category-specific consequence that must be shown again at final
    /// confirmation. This is intentionally separate from the short list-row
    /// description so destructive app-data cleanup cannot be hidden by truncation.
    var cleanupWarning: String? = nil
    let group: CategoryGroup
    let safetyLevel: SafetyLevel
    var paths: [String]
    /// The subtree(s) this category is allowed to delete within. Deletion is confined
    /// to paths equal to or under one of these roots (in addition to the global
    /// `DeletionPolicy` rules). Empty means "derive from `paths`" — see
    /// `DeletionPolicy.validate`. This bounds a category to its declared territory so a
    /// scan bug can never delete outside it.
    var allowedRoots: [String] = []
    /// Nested targets owned by another scan definition. They are excluded from both
    /// measurement and delete-time parent enumeration to prevent hidden/double cleanup.
    var excludedPaths: [String] = []
    /// Applications that should be closed before this category is cleaned. Privacy
    /// categories are hard-blocked while an associated app is running; other
    /// categories are skipped with an actionable error instead of risking live data.
    var associatedBundleIDs: [String] = []
    /// Only categories that explicitly represent whole application bundles may use
    /// the Uninstaller deletion-policy profile.
    var allowsApplicationBundles: Bool = false
    /// Only categories that explicitly target direct children of the current home
    /// directory (currently Shell History) may use this deletion-policy profile.
    var allowsDirectHomeItems: Bool = false
    /// Broken-link cleanup removes the symlink object, not its missing target. Only
    /// that scanner may validate the final path component lexically while still
    /// resolving every parent component and enforcing stable traversal roots.
    var allowsSymbolicLinkItems: Bool = false
    /// Items that are already in Trash cannot be moved to Trash again. Categories with
    /// this flag use explicit permanent deletion and must be shown as irreversible.
    var requiresPermanentDeletion: Bool = false
    var breakdown: [PathStat] = []
    var deleteChildrenOnly: Bool = true
    /// Some caution categories intentionally expose one all-or-nothing managed store.
    /// Their breakdown is informational and must not switch cleanup into per-entry
    /// reconciliation semantics.
    var allowsBreakdownSelection: Bool = true
    var isDockerResource: Bool = false
    var dockerCleanCommand: [String]? = nil
    var isOllamaResource: Bool = false
    var size: Int64 = 0
    var fileCount: Int = 0
    var isSelected: Bool = true
    var selectedSize: Int64 {
        breakdown.isEmpty ? size : breakdown.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }
    var selectedFileCount: Int {
        breakdown.isEmpty ? fileCount : breakdown.filter(\.isSelected).reduce(0) { $0 + $1.fileCount }
    }
    var hasSelectedContent: Bool {
        selectedSize > 0 || selectedFileCount > 0
    }
    var selectedPaths: [String] {
        breakdown.isEmpty ? paths : breakdown.filter(\.isSelected).map(\.path)
    }
    var hasPerFileSelection: Bool {
        // Docker prune commands cannot honor per-resource choices. Ollama can
        // (`ollama rm <model>`) and therefore keeps its per-model checkboxes.
        !isDockerResource &&
            allowsBreakdownSelection &&
            !breakdown.isEmpty &&
            (safetyLevel == .review || safetyLevel == .caution)
    }
    var exists: Bool = true
}

struct ScanDefinition {
    let name: String
    let icon: String
    let color: Color
    let description: String
    let cleanupWarning: String?
    let group: CategoryGroup
    let safetyLevel: SafetyLevel
    let associatedBundleIDs: [String]
    let requiresPermanentDeletion: Bool
    let allowsDirectHomeItems: Bool
    let allowsBreakdownSelection: Bool
    let pathResolver: () -> [String]
    let defaultSelected: Bool

    init(
        name: String.LocalizationValue, icon: String, color: Color,
        description: String.LocalizationValue, group: CategoryGroup,
        safetyLevel: SafetyLevel = .safe,
        defaultSelected: Bool = true,
        cleanupWarning: String.LocalizationValue? = nil,
        associatedBundleIDs: [String] = [],
        requiresPermanentDeletion: Bool = false,
        allowsDirectHomeItems: Bool = false,
        allowsBreakdownSelection: Bool = true,
        pathResolver: @escaping () -> [String]
    ) {
        self.name = String(localized: name); self.icon = icon; self.color = color
        self.description = String(localized: description); self.group = group
        self.cleanupWarning = cleanupWarning.map { String(localized: $0) }
        self.safetyLevel = safetyLevel
        self.associatedBundleIDs = associatedBundleIDs
        self.requiresPermanentDeletion = requiresPermanentDeletion
        self.allowsDirectHomeItems = allowsDirectHomeItems
        self.allowsBreakdownSelection = allowsBreakdownSelection
        self.defaultSelected = defaultSelected
        self.pathResolver = pathResolver
    }
}

struct DiskUsageInfo {
    let totalSpace: Int64
    let usedSpace: Int64
    let freeSpace: Int64
    let purgeableSpace: Int64

    var usedPercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace)
    }
}

struct ScanSummary {
    let totalCategories: Int
    let totalSize: Int64
    let totalFiles: Int
    let scanDuration: TimeInterval
    let timestamp: Date
    var wasPartial: Bool = false
}

// MARK: - Sidebar Selection

enum SidebarItem: Hashable {
    case dashboard
    case group(CategoryGroup)
    case uninstaller
    case duplicateFinder
    case maintenance
    case startupManager
    case timeMachine
    case diskMap
    case storageInsights
}

// MARK: - App Info (Uninstaller)

struct AppInfo: Identifiable, Equatable {
    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.id == rhs.id
    }

    let id = UUID()
    let name: String
    let bundleID: String
    let path: String
    var icon: NSImage?
    var appSize: Int64 = 0
    var relatedPaths: [RelatedPath] = []
    var totalRelatedSize: Int64 = 0
    var fileIdentity: FileRemover.FileIdentity? = nil

    var totalSize: Int64 {
        appSize + totalRelatedSize
    }
}

struct RelatedPath: Identifiable {
    let id = UUID()
    let path: String
    let category: String
    let size: Int64
    let fileCount: Int
    let fileIdentity: FileRemover.FileIdentity?
    var isSelected: Bool = true

    var displayCategory: String {
        AppLocalization.relatedPathCategory(category)
    }

    init(
        path: String,
        category: String,
        size: Int64,
        fileCount: Int,
        fileIdentity: FileRemover.FileIdentity? = nil,
        isSelected: Bool = true
    ) {
        self.path = path
        self.category = category
        self.size = size
        self.fileCount = fileCount
        self.fileIdentity = fileIdentity ?? FileRemover.fileIdentity(at: path)
        self.isSelected = isSelected
    }
}

// MARK: - Sidebar Items



enum AppSortOrder: String, CaseIterable {
    case name = "Name"
    case totalSize = "Total Size"
    case appSize = "App Size"
    case relatedSize = "Related Data"
}

// MARK: - Release Notes

struct ReleaseNote: Identifiable {
    let id = UUID()
    let version: String
    let date: String
    let notes: [String]

    init(version: String, date: String.LocalizationValue, notes: [String.LocalizationValue]) {
        self.version = version
        self.date = String(localized: date)
        self.notes = notes.map { String(localized: $0) }
    }
}

// MARK: - Known App Data Paths

struct KnownAppDataEntry {
    let path: String
    let description: String
    let safetyNote: String

    init(
        path: String,
        description: String.LocalizationValue,
        safetyNote: String.LocalizationValue
    ) {
        self.path = path
        self.description = String(localized: description)
        self.safetyNote = String(localized: safetyNote)
    }
}

enum KnownAppData {
    static let paths: [String: [KnownAppDataEntry]] = [
        // AI/ML Apps
        "com.ollama.ollama": [
            KnownAppDataEntry(path: "~/.ollama", description: "AI Models & Configuration", safetyNote: "Models must be re-downloaded after deletion")
        ],
        "com.lmstudio.app": [
            KnownAppDataEntry(path: "~/.lmstudio", description: "AI Models & Configuration", safetyNote: "Models must be re-downloaded")
        ],
        "com.nomic.gpt4all": [
            KnownAppDataEntry(path: "~/Library/Application Support/nomic.ai", description: "AI Models", safetyNote: "")
        ],
        "com.diffusionbee.diffusionbee": [
            KnownAppDataEntry(path: "~/.diffusionbee", description: "Stable Diffusion Models", safetyNote: "")
        ],
        // Virtualization
        "com.docker.docker": [
            KnownAppDataEntry(path: "~/.docker", description: "Docker CLI Configuration", safetyNote: ""),
            KnownAppDataEntry(path: "~/Library/Containers/com.docker.docker/Data/vms", description: "Docker VM Disk Image", safetyNote: "Contains all containers and images")
        ],
        "io.podman.desktop": [
            KnownAppDataEntry(path: "~/.local/share/containers/podman", description: "Podman VM & Containers", safetyNote: "")
        ],
        "com.utmapp.UTM": [
            KnownAppDataEntry(path: "~/Library/Containers/com.utmapp.UTM/Data/Documents", description: "Virtual Machines", safetyNote: "VMs will be permanently deleted")
        ],
        "com.parallels.desktop.console": [
            KnownAppDataEntry(path: "~/Parallels", description: "Virtual Machines", safetyNote: "VMs will be permanently deleted")
        ],
        // Development
        "com.google.android.studio": [
            KnownAppDataEntry(path: "~/.android/avd", description: "Android Virtual Devices", safetyNote: ""),
            KnownAppDataEntry(path: "~/Library/Android/sdk", description: "Android SDK", safetyNote: "Must re-download if needed")
        ],
        // Databases
        "com.postgresapp.Postgres2": [
            KnownAppDataEntry(path: "/opt/homebrew/var/postgres", description: "PostgreSQL Data", safetyNote: "WARNING: Contains all databases"),
            KnownAppDataEntry(path: "/usr/local/var/postgres", description: "PostgreSQL Data (Intel)", safetyNote: "WARNING: Contains all databases")
        ],
        // Media
        "com.adobe.PremierePro": [
            KnownAppDataEntry(path: "~/Library/Application Support/Adobe/Common/Media Cache Files", description: "Adobe Media Cache", safetyNote: "Shared across Adobe apps")
        ],
        // Communication
        "ru.keepcoder.Telegram": [
            KnownAppDataEntry(path: "~/Library/Group Containers/6N38VVP8K2.telegram", description: "Telegram Data & Media", safetyNote: "")
        ],
        "com.tinyspeck.slackmacgap": [
            KnownAppDataEntry(path: "~/Library/Application Support/Slack/Cache", description: "Slack Media Cache", safetyNote: ""),
            KnownAppDataEntry(path: "~/Library/Application Support/Slack/Service Worker", description: "Slack Service Workers", safetyNote: "")
        ],
        // Gaming
        "com.valvesoftware.steam": [
            KnownAppDataEntry(path: "~/Library/Application Support/Steam/steamapps", description: "Steam Games Library", safetyNote: "All installed games will be deleted")
        ],
        "com.epicgames.EpicGamesLauncher": [
            KnownAppDataEntry(path: "/Users/Shared/Epic Games", description: "Epic Games Library", safetyNote: "All installed games will be deleted")
        ],
        // Cloud Storage
        "com.google.drivefs": [
            KnownAppDataEntry(path: "~/Library/Application Support/Google/DriveFS", description: "Google Drive Cache", safetyNote: "Local cache only — cloud files safe")
        ],
        // Browsers
        "com.google.Chrome": [
            KnownAppDataEntry(path: "~/Library/Application Support/Google/Chrome", description: "Chrome Profiles & Extensions", safetyNote: "All bookmarks, history, extensions")
        ],
        "org.mozilla.firefox": [
            KnownAppDataEntry(path: "~/Library/Application Support/Firefox/Profiles", description: "Firefox Profiles", safetyNote: "All bookmarks, history, extensions")
        ],
    ]
}
