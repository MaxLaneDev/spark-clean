//
//  DeletionAuditLogger.swift
//  SparkClean
//
//  Created by George Khananaev.
//
//  A single audit trail shared by every deletion surface. Logs are append-only per
//  cleanup session, include the category and real measured size, and are bounded by
//  age and count so the logger cannot become another source of disk bloat.
//

import Foundation

final class DeletionAuditLogger: @unchecked Sendable {
    static let shared = DeletionAuditLogger()

    private let directory: URL
    private let retentionDays: Int
    private let maximumFiles: Int
    private let fm = FileManager.default
    private let lock = NSLock()
    private var hasPruned = false

    init(directory: URL? = nil, retentionDays: Int = 90, maximumFiles: Int = 200) {
        self.directory = directory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/SparkClean", isDirectory: true)
        self.retentionDays = retentionDays
        self.maximumFiles = maximumFiles
    }

    func record(
        _ removals: [FileRemover.Removal],
        category: String,
        sessionID: String,
        appVersion: String,
        trashMode: Bool
    ) {
        guard !removals.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        secureDirectory()
        if !hasPruned {
            pruneLocked(now: Date())
            hasPruned = true
        }

        let safeSessionID = sessionID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let logURL = directory.appendingPathComponent("cleanup-\(safeSessionID).log")
        let isNew = !fm.fileExists(atPath: logURL.path)

        var text = ""
        if isNew {
            text += "SparkClean Deletion Log\n"
            text += "Session: \(singleLine(sessionID))\n"
            text += "Version: \(singleLine(appVersion))\n"
            text += "Default mode: \(trashMode ? "Trash" : "Permanent delete") (entry method is authoritative)\n"
            text += "Started: \(ISO8601DateFormatter().string(from: Date()))\n"
            text += String(repeating: "─", count: 80) + "\n"
        }
        for removal in removals {
            text += "[\(singleLine(removal.method))] [\(singleLine(category))] "
            text += "\(formatBytes(removal.size).padding(toLength: 10, withPad: " ", startingAt: 0)) "
            text += singleLine(removal.originalPath)
            if let trashedPath = removal.trashedPath {
                text += " -> \(singleLine(trashedPath))"
            }
            text += "\n"
        }

        guard let data = text.data(using: .utf8) else { return }
        if isNew {
            try? data.write(to: logURL, options: .atomic)
            try? fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logURL.path
            )
        } else if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }

    func prune(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        hasPruned = true
    }

    func recordEvent(
        _ message: String,
        category: String,
        sessionID: String,
        appVersion: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        secureDirectory()
        if !hasPruned {
            pruneLocked(now: Date())
            hasPruned = true
        }
        let safeSessionID = sessionID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let logURL = directory.appendingPathComponent("cleanup-\(safeSessionID).log")
        let isNew = !fm.fileExists(atPath: logURL.path)
        var text = isNew
            ? "SparkClean Audit Log\nSession: \(singleLine(sessionID))\nVersion: \(singleLine(appVersion))\n" +
              String(repeating: "─", count: 80) + "\n"
            : ""
        text += "[COMMAND] [\(singleLine(category))] \(singleLine(message))\n"
        guard let data = text.data(using: .utf8) else { return }
        if isNew {
            try? data.write(to: logURL, options: .atomic)
            try? fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logURL.path
            )
        } else if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private func pruneLocked(now: Date) {
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let logs = files
            .filter { $0.lastPathComponent.hasPrefix("cleanup-") && $0.pathExtension == "log" }
            .map { url -> (url: URL, date: Date) in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let date = values?.contentModificationDate ?? .distantPast
                return (url, date)
            }
            .sorted { $0.date > $1.date }

        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: now
        ) ?? .distantPast
        for (index, log) in logs.enumerated()
        where log.date < cutoff || index >= maximumFiles {
            try? fm.removeItem(at: log.url)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func secureDirectory() {
        try? fm.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
