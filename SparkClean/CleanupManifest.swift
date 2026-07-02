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

    init(directory: URL? = nil, retention: Int = 10) {
        self.directory = directory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/SparkClean/manifests")
        self.retention = retention
    }

    private func url(for sessionID: String) -> URL {
        directory.appendingPathComponent("manifest-\(sessionID).json")
    }

    /// Persist (or overwrite) a manifest for its session. Safe to call repeatedly as
    /// entries accumulate — the file is rewritten atomically each time.
    func save(_ manifest: CleanupManifest) {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: url(for: manifest.sessionID), options: .atomic)
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
        for entry in manifest.entries {
            let trashed = URL(fileURLWithPath: entry.trashedPath)
            let original = URL(fileURLWithPath: entry.originalPath)

            guard fm.fileExists(atPath: entry.trashedPath) else {
                outcome.missingInTrash += 1
                continue
            }
            if fm.fileExists(atPath: entry.originalPath) {
                outcome.skippedExisting += 1
                continue
            }

            let parent = original.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: trashed, to: original)
                outcome.restored += 1
            } catch {
                outcome.failed += 1
            }
        }
        return outcome
    }
}
