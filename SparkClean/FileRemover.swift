//
//  FileRemover.swift
//  SparkClean
//
//  Created by George Khananaev.
//
//  The single deletion service shared by every surface — the main clean pipeline, the
//  Uninstaller, and the Duplicate Finder. Each item passes through the same gate:
//  `DeletionPolicy` validation, an iCloud/file-provider guard, then move-to-Trash
//  (capturing the resulting Trash location so the action can be undone) or permanent
//  removal. Centralising this means no surface can delete a file without the safety
//  rules, audit trail, and undo record.
//
//  The move-to-Trash step is injectable (`TrashStrategy`) so tests exercise the full
//  logic against a fixture Trash directory without touching the user's real Trash.
//

import Foundation

final class FileRemover {

    /// One successful removal — enough to write the audit log and undo it later.
    struct Removal {
        let originalPath: String
        /// Where the item now lives in the Trash. `nil` for permanent deletes (no undo).
        let trashedPath: String?
        let size: Int64
        let method: String   // "TRASH", "DELETE", or "TRASH(admin)"
    }

    /// The result of attempting to remove one item.
    enum Result {
        case removed(Removal)
        case blocked(reason: String)
        case needsAdmin(path: String)
        case skippedICloud
        case failed(error: String)
    }

    /// Abstraction over the actual move-to-Trash, so tests can redirect it.
    struct TrashStrategy {
        /// Move `url` to the Trash and return the resulting location. Throws on failure.
        let trash: (URL) throws -> URL

        /// Production strategy: the real system Trash.
        static var system: TrashStrategy {
            TrashStrategy { url in
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return (resulting as URL?) ?? url
            }
        }
    }

    let policy: DeletionPolicy
    let useTrash: Bool
    private let trashStrategy: TrashStrategy
    private let fm = FileManager.default

    init(policy: DeletionPolicy = DeletionPolicy(),
         useTrash: Bool,
         trashStrategy: TrashStrategy = .system) {
        self.policy = policy
        self.useTrash = useTrash
        self.trashStrategy = trashStrategy
    }

    /// Remove a single item that belongs to a category whose territory is `allowedRoots`.
    /// `knownSize` (from a scan's breakdown) is used for the audit/undo record when
    /// provided — more accurate than an inode's `.size` for directories.
    func remove(_ path: String, allowedRoots: [String], knownSize: Int64? = nil) -> Result {
        let url = URL(fileURLWithPath: path)

        // Gate 1: global safety rules + category territory.
        guard policy.validate(path, allowedRoots: allowedRoots) else {
            return .blocked(reason: url.lastPathComponent)
        }

        // Gate 2: never delete an item that is an iCloud/file-provider materialization.
        if let rv = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
           rv.isUbiquitousItem == true {
            return .skippedICloud
        }

        let size = knownSize ?? ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0)

        if useTrash {
            do {
                let trashed = try trashStrategy.trash(url)
                return .removed(Removal(originalPath: path, trashedPath: trashed.path,
                                        size: size, method: "TRASH"))
            } catch {
                // Trash failed (usually a permission issue) — caller may escalate.
                return .needsAdmin(path: path)
            }
        } else {
            do {
                try fm.removeItem(at: url)
                return .removed(Removal(originalPath: path, trashedPath: nil,
                                        size: size, method: "DELETE"))
            } catch {
                return .failed(error: error.localizedDescription)
            }
        }
    }
}
