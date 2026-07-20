//
//  CleanupManifest.swift
//  SparkClean
//
//  Created by George Khananaev.
//
//  Records every item moved to the Trash during a cleanup so the whole operation can be
//  reversed ("Restore Last Cleanup"). Entries are written incrementally as items are
//  removed — if the app dies mid-clean, the partial manifest still restores what was
//  already trashed. Persisted as JSON under Application Support; the store keeps a bounded
//  history and is directory-injectable for testing.
//

import Foundation

struct CleanupManifestEntry: Codable, Equatable {
    let originalPath: String
    let trashedPath: String
    let size: Int64
    let category: String
    let device: UInt64?
    let inode: UInt64?

    init(
        originalPath: String,
        trashedPath: String,
        size: Int64,
        category: String,
        device: UInt64? = nil,
        inode: UInt64? = nil
    ) {
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.size = size
        self.category = category
        self.device = device
        self.inode = inode
    }
}

struct CleanupManifest: Codable {
    var sessionID: String
    var appVersion: String
    var trashMode: Bool
    var entries: [CleanupManifestEntry] = []
}

/// Outcome of a restore pass.
struct RestoreOutcome: Equatable {
    var restored: Int = 0
    var skippedExisting: Int = 0     // original path already occupied
    var missingInTrash: Int = 0      // trashed item gone (e.g. Trash emptied)
    var failed: Int = 0
}

final class CleanupManifestStore {
    let directory: URL
    /// Maximum number of manifest files to retain.
    let retention: Int
    private let fm = FileManager.default
    private let restorePolicy: DeletionPolicy
    private let trustedTrashRoots: [String]
    private let trustedDeviceIDs: Set<UInt64>

    init(
        directory: URL? = nil,
        retention: Int = 10,
        restorePolicy: DeletionPolicy? = nil,
        trustedTrashRoots: [String]? = nil
    ) {
        let policy = restorePolicy ?? DeletionPolicy(
            allowsApplicationBundles: true,
            allowsDirectHomeItems: true,
            allowsSymbolicLinkItems: true
        )
        self.directory = directory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/SparkClean/manifests")
        self.retention = retention
        self.restorePolicy = policy
        self.trustedTrashRoots = trustedTrashRoots ?? [
            URL(fileURLWithPath: policy.home)
                .appendingPathComponent(".Trash", isDirectory: true).path,
        ]
        self.trustedDeviceIDs = Set(
            [policy.home, "/"].compactMap {
                FileRemover.fileIdentity(at: $0)?.device
            }
        )
    }

    private func url(for sessionID: String) -> URL {
        let safeSessionID = sessionID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        return directory.appendingPathComponent("manifest-\(safeSessionID).json")
    }

    func remove(sessionID: String) {
        try? fm.removeItem(at: url(for: sessionID))
    }

    /// Persist (or overwrite) a manifest for its session. Safe to call repeatedly as
    /// entries accumulate — the file is rewritten atomically each time.
    func save(_ manifest: CleanupManifest) {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        let manifestURL = url(for: manifest.sessionID)
        try? data.write(to: manifestURL, options: .atomic)
        try? fm.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
    }

    /// All manifests, newest first (by file modification date).
    func allManifests() -> [CleanupManifest] {
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.lastPathComponent.hasPrefix("manifest-") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
            .compactMap { try? JSONDecoder().decode(CleanupManifest.self, from: Data(contentsOf: $0)) }
    }

    /// The most recent manifest, if any.
    func mostRecent() -> CleanupManifest? { allManifests().first }

    /// Delete manifest files beyond the retention limit (oldest first).
    func prune() {
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let manifests = files
            .filter { $0.lastPathComponent.hasPrefix("manifest-") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
        for file in manifests.dropFirst(retention) {
            try? fm.removeItem(at: file)
        }
    }

    /// Move each trashed item back to its original location. Never overwrites an
    /// existing file at the original path (reports it skipped instead), and tolerates
    /// items that have since left the Trash.
    @discardableResult
    func restore(_ manifest: CleanupManifest) -> RestoreOutcome {
        var outcome = RestoreOutcome()
        var remainingEntries: [CleanupManifestEntry] = []
        for entry in manifest.entries {
            let trashed = URL(fileURLWithPath: entry.trashedPath)
            let original = URL(fileURLWithPath: entry.originalPath)

            // Manifests are user-writable data, not authority. Refuse edited entries
            // that point outside Trash, target protected locations, contain unstable
            // path components, or use relative/noncanonical spellings.
            guard isValidRestoreEntry(entry) else {
                outcome.failed += 1
                continue
            }

            // `fileExists` follows symlinks and returns false for a dangling link.
            // Broken symlinks are a first-class cleanup result, so use lstat-backed
            // identity checks for both Trash presence and destination occupancy.
            guard itemExists(at: entry.trashedPath) else {
                outcome.missingInTrash += 1
                continue
            }
            if let device = entry.device, let inode = entry.inode,
               FileRemover.fileIdentity(at: entry.trashedPath) != .init(
                   device: device,
                   inode: inode
               ) {
                outcome.failed += 1
                remainingEntries.append(entry)
                continue
            }
            if itemExists(at: entry.originalPath) {
                outcome.skippedExisting += 1
                remainingEntries.append(entry)
                continue
            }

            let parent = original.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: trashed, to: original)
                outcome.restored += 1
            } catch {
                outcome.failed += 1
                remainingEntries.append(entry)
            }
        }

        // Consume restored/missing entries so "Restore Last Cleanup" never offers a
        // stale manifest forever. Keep only conflicts/failures that can be retried.
        if remainingEntries.isEmpty {
            remove(sessionID: manifest.sessionID)
        } else {
            var remaining = manifest
            remaining.entries = remainingEntries
            save(remaining)
        }
        return outcome
    }

    private func itemExists(at path: String) -> Bool {
        FileRemover.fileIdentity(at: path) != nil
    }

    private func isValidRestoreEntry(_ entry: CleanupManifestEntry) -> Bool {
        guard (entry.originalPath as NSString).isAbsolutePath,
              (entry.trashedPath as NSString).isAbsolutePath,
              URL(fileURLWithPath: entry.originalPath).standardizedFileURL.path ==
                  entry.originalPath,
              URL(fileURLWithPath: entry.trashedPath).standardizedFileURL.path ==
                  entry.trashedPath,
              restorePolicy.isSafeToDelete(entry.originalPath),
              restorePolicy.isStableAllowedRoot(entry.originalPath),
              nearestExistingAncestorDevice(of: entry.originalPath).map({
                  trustedDeviceIDs.contains($0)
              }) == true
        else { return false }

        return trustedTrashRoots.contains {
            restorePolicy.isWithinAllowedRoots(
                entry.trashedPath,
                roots: [$0]
            )
        }
    }

    private func nearestExistingAncestorDevice(of path: String) -> UInt64? {
        var candidate = URL(fileURLWithPath: path).deletingLastPathComponent()
        while true {
            if let device = FileRemover.fileIdentity(at: candidate.path)?.device {
                return device
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }
}

/// Thread-safe session writer used by every deletion surface. Each successful Trash
/// move is persisted immediately, so a crash halfway through a large category still
/// leaves a complete undo record for everything already removed.
final class CleanupSessionRecorder: @unchecked Sendable {
    let sessionID: String

    private let store: CleanupManifestStore
    private let excludedOriginalRoot: String
    private let lock = NSLock()
    private var manifest: CleanupManifest

    init(
        sessionID: String = ProcessInfo.processInfo.globallyUniqueString,
        appVersion: String,
        trashMode: Bool,
        store: CleanupManifestStore,
        excludedOriginalRoot: String = NSHomeDirectory() + "/.Trash"
    ) {
        self.sessionID = sessionID
        self.store = store
        self.excludedOriginalRoot = excludedOriginalRoot
        self.manifest = CleanupManifest(
            sessionID: sessionID,
            appVersion: appVersion,
            trashMode: trashMode
        )
    }

    func record(_ removal: FileRemover.Removal, category: String) {
        guard let trashedPath = removal.trashedPath else { return }
        let original = URL(fileURLWithPath: removal.originalPath).standardizedFileURL.path
        let excluded = URL(fileURLWithPath: excludedOriginalRoot).standardizedFileURL.path
        guard original != excluded, !original.hasPrefix(excluded + "/") else {
            return
        }

        lock.lock()
        manifest.entries.append(CleanupManifestEntry(
            originalPath: removal.originalPath,
            trashedPath: trashedPath,
            size: removal.size,
            category: category,
            device: removal.fileIdentity?.device,
            inode: removal.fileIdentity?.inode
        ))
        store.save(manifest)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        // Persist an empty completion marker when an operation removed nothing to
        // Trash. Otherwise "Restore Last Cleanup" could incorrectly offer an older,
        // unrelated session after a permanent-only or failed operation.
        if manifest.entries.isEmpty {
            store.save(manifest)
        }
        store.prune()
        lock.unlock()
    }
}
