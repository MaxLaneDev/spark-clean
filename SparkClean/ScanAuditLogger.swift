//
//  ScanAuditLogger.swift
//  SparkClean
//
//  Created by George Khananaev.
//
//  Persists one bounded, machine-readable snapshot of the latest cleanup scan.
//  The main scan used to exist only in memory, which made it impossible to compare
//  what SparkClean reported with the storage actually present after the app closed.
//

import Foundation

struct ScanAuditSnapshot: Codable, Sendable {
    struct DiskUsage: Codable, Sendable {
        let totalSpace: Int64
        let usedSpace: Int64
        let freeSpace: Int64
        let purgeableSpace: Int64
    }

    struct Entry: Codable, Sendable {
        let path: String
        let size: Int64
        let fileCount: Int
        let isSelected: Bool
        let displayName: String?
    }

    struct Category: Codable, Sendable {
        let name: String
        let group: String
        let safetyLevel: String
        let description: String
        let cleanupWarning: String?
        let size: Int64
        let fileCount: Int
        let isSelected: Bool
        let selectedSize: Int64
        let selectedFileCount: Int
        let paths: [String]
        let allowedRoots: [String]
        let excludedPaths: [String]
        let associatedBundleIDs: [String]
        let deleteChildrenOnly: Bool
        let allowsBreakdownSelection: Bool
        let entries: [Entry]
    }

    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
    let scope: String
    let wasPartial: Bool
    let scanDuration: TimeInterval
    let scanErrors: [String]
    let settings: [String: String]
    let diskUsage: DiskUsage?
    let categories: [Category]
}

final class ScanAuditLogger: @unchecked Sendable {
    static let shared = ScanAuditLogger()

    let fileURL: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Logs/SparkClean/latest-scan.json",
                isDirectory: false
            )
    }

    @discardableResult
    func write(_ snapshot: ScanAuditSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }
}
