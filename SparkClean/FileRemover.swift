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
import AppKit
import Darwin

final class FileRemover {

    static let itemNoLongerExistsError = String(localized: "Item no longer exists")

    /// Stable filesystem identity captured at scan/review time. Device + inode catches
    /// a different item being swapped into the same path before cleanup.
    nonisolated struct FileIdentity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    /// One successful removal — enough to write the audit log and undo it later.
    struct Removal {
        let originalPath: String
        /// Where the item now lives in the Trash. `nil` for permanent deletes (no undo).
        let trashedPath: String?
        let size: Int64
        let method: String   // "TRASH", "DELETE", or "TRASH(admin)"
        let fileIdentity: FileIdentity?
    }

    /// The result of attempting to remove one item.
    enum Result {
        case removed(Removal)
        case blocked(reason: String)
        case needsAdmin(path: String)
        case skippedICloud
        case failed(error: String)
    }

    struct AdminRequest {
        let path: String
        let allowedRoots: [String]
        let knownSize: Int64?
        let expectedIsDirectory: Bool?
        let expectedIdentity: FileIdentity?

        init(path: String, allowedRoots: [String], knownSize: Int64? = nil,
             expectedIsDirectory: Bool? = nil, expectedIdentity: FileIdentity? = nil) {
            self.path = path
            self.allowedRoots = allowedRoots
            self.knownSize = knownSize
            self.expectedIsDirectory = expectedIsDirectory
            self.expectedIdentity = expectedIdentity
        }
    }

    struct AdminResult {
        var removals: [Removal] = []
        var failures: [String] = []
        var wasCancelled = false

        init(
            removals: [Removal] = [],
            failures: [String] = [],
            wasCancelled: Bool = false
        ) {
            self.removals = removals
            self.failures = failures
            self.wasCancelled = wasCancelled
        }
    }

    /// Abstraction over the actual move-to-Trash, so tests can redirect it.
    struct TrashStrategy {
        /// Move `url` to the Trash and return the resulting location when macOS
        /// provides it. A successful move with no destination remains successful but
        /// cannot be added to the undo manifest.
        let trash: (URL) throws -> URL?

        /// Production strategy: the real system Trash.
        static var system: TrashStrategy {
            TrashStrategy { url in
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return resulting as URL?
            }
        }
    }

    let policy: DeletionPolicy
    let useTrash: Bool
    private let trashStrategy: TrashStrategy
    private let fm = FileManager.default
    private let trustedDeviceIDs: Set<UInt64>

    init(policy: DeletionPolicy = DeletionPolicy(),
         useTrash: Bool,
         trashStrategy: TrashStrategy = .system) {
        self.policy = policy
        self.useTrash = useTrash
        self.trashStrategy = trashStrategy
        self.trustedDeviceIDs = Set(
            [policy.home, "/"].compactMap {
                Self.fileIdentity(at: $0)?.device
            }
        )
    }

    /// Remove a single item that belongs to a category whose territory is `allowedRoots`.
    /// `knownSize` (from a scan's breakdown) is used for the audit/undo record when
    /// provided — more accurate than an inode's `.size` for directories.
    func remove(_ path: String, allowedRoots: [String], knownSize: Int64? = nil,
                expectedIsDirectory: Bool? = nil,
                expectedIdentity: FileIdentity? = nil) -> Result {
        let url = URL(fileURLWithPath: path)

        // Gate 1: global safety rules + category territory.
        guard policy.validate(path, allowedRoots: allowedRoots) else {
            return .blocked(reason: String(localized: "outside the permitted cleanup area"))
        }

        // Gate 2: delete-time revalidation. A scan result can be minutes old, so do
        // not trust that the path still exists or has the same kind.
        guard let isDirectory = existingItemIsDirectory(at: path) else {
            return .failed(error: Self.itemNoLongerExistsError)
        }
        if let expectedIsDirectory, expectedIsDirectory != isDirectory {
            return .blocked(reason: String(localized: "item type changed since it was scanned"))
        }
        if let expectedIdentity, Self.fileIdentity(at: path) != expectedIdentity {
            return .blocked(reason: String(localized: "a different item replaced the scanned path"))
        }
        guard let currentIdentity = Self.fileIdentity(at: path) else {
            return .failed(error: String(localized: "Could not verify the item's filesystem identity"))
        }
        guard trustedDeviceIDs.contains(currentIdentity.device) else {
            return .blocked(reason: String(localized: "items on mounted or external volumes are protected"))
        }

        // Gate 3: never delete a mounted volume or an iCloud/file-provider item.
        if let rv = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .isVolumeKey]) {
            if rv.isUbiquitousItem == true { return .skippedICloud }
            if rv.isVolume == true {
                return .blocked(reason: String(localized: "mounted volumes cannot be removed"))
            }
        }

        let size = knownSize ?? itemSize(at: path)

        if useTrash {
            do {
                let trashed = try trashStrategy.trash(url)
                return .removed(Removal(originalPath: path, trashedPath: trashed?.path,
                                        size: size, method: "TRASH",
                                        fileIdentity: currentIdentity))
            } catch {
                // Trash failed (usually a permission issue) — caller may escalate.
                return .needsAdmin(path: path)
            }
        } else {
            do {
                try fm.removeItem(at: url)
                return .removed(Removal(originalPath: path, trashedPath: nil,
                                        size: size, method: "DELETE",
                                        fileIdentity: currentIdentity))
            } catch {
                return .failed(error: error.localizedDescription)
            }
        }
    }

    /// Move paths that failed the normal Trash operation with administrator
    /// privileges. The user sees the exact list first; every path is revalidated after
    /// confirmation, destinations are precomputed, and results are verified one by one
    /// so undo/audit records are accurate even after a partial failure.
    func moveToTrashWithAdministratorPrivileges(
        _ requests: [AdminRequest],
        confirmationTitle: String
    ) -> AdminResult {
        guard useTrash, !requests.isEmpty else { return AdminResult() }

        let initiallyValid = requests.filter {
            policy.validate($0.path, allowedRoots: $0.allowedRoots)
        }
        guard !initiallyValid.isEmpty else {
            return AdminResult(failures: requests.map {
                let path = AppLocalization.isolateTechnicalText($0.path)
                return String(localized: "\(path): blocked by deletion policy")
            })
        }
        guard confirmAdministratorMove(
            paths: initiallyValid.map(\.path),
            title: confirmationTitle
        ) else {
            return AdminResult(wasCancelled: true)
        }

        // Revalidate after the user has reviewed the sheet (TOCTOU defense).
        var valid: [AdminRequest] = []
        var result = AdminResult()
        for request in initiallyValid {
            switch validateForAdministratorMove(request) {
            case nil:
                valid.append(request)
            case .some(let message):
                let path = AppLocalization.isolateTechnicalText(request.path)
                result.failures.append(String(localized: "\(path): \(message)"))
            }
        }
        guard !valid.isEmpty else { return result }

        let trashDirectory = URL(fileURLWithPath: policy.home)
            .appendingPathComponent(".Trash", isDirectory: true)
        var reservedDestinations = Set<String>()
        var moves: [
            (request: AdminRequest, destination: URL, identity: FileIdentity)
        ] = []
        for request in valid {
            guard let identity = Self.fileIdentity(at: request.path) else {
                let path = AppLocalization.isolateTechnicalText(request.path)
                result.failures.append(
                    String(localized: "\(path): could not verify filesystem identity")
                )
                continue
            }
            if let expected = request.expectedIdentity, identity != expected {
                let path = AppLocalization.isolateTechnicalText(request.path)
                result.failures.append(
                    String(localized: "\(path): a different item replaced the reviewed path")
                )
                continue
            }
            let destination = uniqueTrashDestination(
                for: request.path,
                trashDirectory: trashDirectory,
                reserved: &reservedDestinations
            )
            moves.append((request, destination, identity))
        }
        guard !moves.isEmpty else { return result }

        let privateDirectory = fm.temporaryDirectory
            .appendingPathComponent("SparkClean-\(UUID().uuidString)", isDirectory: true)
        let scriptURL = privateDirectory.appendingPathComponent("admin-trash.sh")

        do {
            try fm.createDirectory(
                at: privateDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var script = "#!/bin/bash\nset -u\n"
            for move in moves {
                // `-n` keeps a same-user process from racing the precomputed Trash
                // destination and making the privileged move overwrite an item.
                script += "/bin/mv -n \(shellQuote(move.request.path)) \(shellQuote(move.destination.path)) || true\n"
            }
            try Data(script.utf8).write(to: scriptURL, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            try? fm.removeItem(at: privateDirectory)
            result.failures.append(String(localized: "Could not prepare the private administrator helper: \(error.localizedDescription)"))
            return result
        }
        defer { try? fm.removeItem(at: privateDirectory) }

        let source = "do shell script \"/bin/bash \(shellQuote(scriptURL.path))\" with administrator privileges"
        var scriptError: NSDictionary?
        _ = runOnMain {
            NSAppleScript(source: source)?.executeAndReturnError(&scriptError)
        }

        for move in moves {
            let sourceStillExists = itemExists(at: move.request.path)
            let nestedDestination = move.destination.appendingPathComponent(
                URL(fileURLWithPath: move.request.path).lastPathComponent
            )
            let actualDestination: URL?
            if Self.fileIdentity(at: move.destination.path) == move.identity {
                actualDestination = move.destination
            } else if Self.fileIdentity(at: nestedDestination.path) == move.identity {
                // BSD `mv` places the source inside a directory if a destination
                // directory appears during the authorization prompt. Preserve the
                // exact resulting location instead of losing undo coverage.
                actualDestination = nestedDestination
            } else {
                actualDestination = nil
            }
            if !sourceStillExists, let actualDestination {
                result.removals.append(Removal(
                    originalPath: move.request.path,
                    trashedPath: actualDestination.path,
                    size: move.request.knownSize ?? itemSize(at: actualDestination.path),
                    method: "TRASH(admin)",
                    fileIdentity: move.identity
                ))
            } else {
                let path = AppLocalization.isolateTechnicalText(move.request.path)
                result.failures.append(String(localized: "\(path): administrator move failed"))
            }
        }

        if let scriptError, result.removals.isEmpty {
            let message = scriptError["NSAppleScriptErrorMessage"] as? String
                ?? String(localized: "Administrator authorization was cancelled or failed")
            result.failures.append(message)
        }
        return result
    }

    private func validateForAdministratorMove(_ request: AdminRequest) -> String? {
        guard policy.validate(request.path, allowedRoots: request.allowedRoots) else {
            return String(localized: "blocked by deletion policy")
        }
        guard let isDirectory = existingItemIsDirectory(at: request.path) else {
            return Self.itemNoLongerExistsError
        }
        if let expected = request.expectedIsDirectory, expected != isDirectory {
            return String(localized: "item type changed since it was scanned")
        }
        if let expected = request.expectedIdentity,
           Self.fileIdentity(at: request.path) != expected {
            return String(localized: "a different item replaced the scanned path")
        }
        guard let identity = Self.fileIdentity(at: request.path),
              trustedDeviceIDs.contains(identity.device) else {
            return String(localized: "items on mounted or external volumes are protected")
        }
        let url = URL(fileURLWithPath: request.path)
        if let rv = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .isVolumeKey]) {
            if rv.isUbiquitousItem == true {
                return String(localized: "iCloud/file-provider items are protected")
            }
            if rv.isVolume == true {
                return String(localized: "mounted volumes cannot be removed")
            }
        }
        return nil
    }

    private func uniqueTrashDestination(
        for path: String,
        trashDirectory: URL,
        reserved: inout Set<String>
    ) -> URL {
        let name = URL(fileURLWithPath: path).lastPathComponent
        var candidate = trashDirectory.appendingPathComponent(name)
        var suffix = 2
        while itemExists(at: candidate.path) || reserved.contains(candidate.path) {
            candidate = trashDirectory.appendingPathComponent("\(name) \(suffix)")
            suffix += 1
        }
        reserved.insert(candidate.path)
        return candidate
    }

    private func confirmAdministratorMove(paths: [String], title: String) -> Bool {
        runOnMain {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = String(localized: "\(paths.count) item(s) need administrator privileges. Review every path before continuing.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Move to Trash"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            let textView = NSTextView(frame: scrollView.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.string = paths
                .map { "\u{2066}\($0)\u{2069}" }
                .joined(separator: "\n")
            scrollView.documentView = textView
            alert.accessoryView = scrollView

            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func itemSize(at path: String) -> Int64 {
        guard let value = (try? fm.attributesOfItem(atPath: path))?[.size] else { return 0 }
        if let number = value as? NSNumber { return number.int64Value }
        return value as? Int64 ?? 0
    }

    /// `FileManager.fileExists` follows symlinks and returns false for a dangling link.
    /// Broken-symlink cleanup still needs to remove the link itself, so treat a
    /// readable link destination record as existence and classify it as a file.
    private func existingItemIsDirectory(at path: String) -> Bool? {
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
            return false
        }
        return nil
    }

    private func itemExists(at path: String) -> Bool {
        existingItemIsDirectory(at: path) != nil
    }

    static func fileIdentity(at path: String) -> FileIdentity? {
        var info = stat()
        let status = path.withCString { pointer in
            lstat(pointer, &info)
        }
        guard status == 0 else { return nil }
        return FileIdentity(
            device: UInt64(truncatingIfNeeded: info.st_dev),
            inode: UInt64(truncatingIfNeeded: info.st_ino)
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runOnMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}
