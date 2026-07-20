//
//  TimeMachineManager.swift
//  SparkClean
//
//  Created by George Khananaev.
//
//  Time Machine local-snapshot management (F14). macOS keeps hourly APFS local
//  snapshots and thins them under disk pressure. This lists and deletes local
//  snapshots without estimating how much physical space an APFS deletion will free.
//
//  HARD RULE: Time Machine data is only ever touched through `tmutil` — never with
//  FileManager. `DeletionPolicy` additionally hard-rejects any Backups.backupdb /
//  .timemachine path as defense in depth.
//

import Foundation

struct TMSnapshot: Identifiable, Equatable {
    /// Full snapshot name, e.g. "com.apple.TimeMachine.2026-07-01-093012.local".
    let name: String
    /// Parsed creation date, if the name matched the expected format.
    let date: Date?
    var id: String { name }
}

@Observable
final class TimeMachineManager {
    var snapshots: [TMSnapshot] = []
    var isBusy = false
    var lastError: String?

    /// Parses the timestamp embedded in a snapshot name (`yyyy-MM-dd-HHmmss`).
    private static let snapshotDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.isLenient = false
        return f
    }()

    /// Parse `tmutil listlocalsnapshots /` output into snapshots. Tolerant of header
    /// lines and unknown formats (unrecognized lines are skipped, never crash).
    static func parseLocalSnapshots(_ output: String) -> [TMSnapshot] {
        var result: [TMSnapshot] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("com.apple.TimeMachine.") else { continue }
            // Strip the fixed prefix and the trailing ".local" to isolate the timestamp.
            var stamp = String(line.dropFirst("com.apple.TimeMachine.".count))
            guard stamp.hasSuffix(".local") else { continue }
            stamp = String(stamp.dropLast(".local".count))
            guard isValidTimestamp(stamp),
                  let date = snapshotDateFormatter.date(from: stamp) else { continue }
            result.append(TMSnapshot(name: line, date: date))
        }
        return result
    }

    /// The timestamp argument `tmutil deletelocalsnapshots` expects, extracted from a
    /// snapshot name (e.g. "2026-07-01-093012"). Returns nil if the name is malformed.
    static func deletionTimestamp(for snapshot: TMSnapshot) -> String? {
        guard snapshot.name.hasPrefix("com.apple.TimeMachine.") else { return nil }
        var stamp = String(snapshot.name.dropFirst("com.apple.TimeMachine.".count))
        if stamp.hasSuffix(".local") { stamp = String(stamp.dropLast(".local".count)) }
        return stamp.isEmpty ? nil : stamp
    }

    // MARK: - tmutil execution

    @discardableResult
    private static func runTmutil(_ args: [String]) -> (output: String, ok: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            return (out, process.terminationStatus == 0)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    /// Refresh the local-snapshot list (listing requires no privileges).
    func refresh() async {
        await MainActor.run { isBusy = true; lastError = nil }
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (out, ok) = Self.runTmutil(["listlocalsnapshots", "/"])
                continuation.resume(returning: (out, ok))
            }
        }
        let parsed = Self.parseLocalSnapshots(result.0)
        await MainActor.run {
            snapshots = parsed.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            if !result.1 && parsed.isEmpty { lastError = "Could not list Time Machine snapshots." }
            isBusy = false
        }
    }

    /// Build the admin shell script that deletes the given snapshot timestamps via
    /// tmutil. Timestamps are validated to `yyyy-MM-dd-HHmmss` before interpolation so
    /// nothing arbitrary reaches the shell. Returns nil if no valid timestamps.
    static func deletionScript(for stamps: [String]) -> String? {
        let valid = stamps.filter { isValidTimestamp($0) }
        guard !valid.isEmpty else { return nil }
        // Attempt every selected snapshot even if one command fails. The caller
        // refreshes and verifies each timestamp afterward, so partial completion is
        // reported and audited accurately.
        var script = "#!/bin/bash\nset -u\nstatus=0\n"
        for stamp in valid {
            script += "/usr/bin/tmutil deletelocalsnapshots '\(stamp)' || status=1\n"
        }
        script += "exit \"$status\"\n"
        return script
    }

    /// Strict validator: 17 chars, digits with dashes at the expected positions
    /// (`yyyy-MM-dd-HHmmss`). Guards the admin script against injection.
    static func isValidTimestamp(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 17 else { return false }  // 2026-07-01-093012 -> 17 chars
        for (i, c) in chars.enumerated() {
            if i == 4 || i == 7 || i == 10 {
                if c != "-" { return false }
            } else if !c.isNumber {
                return false
            }
        }
        guard let date = snapshotDateFormatter.date(from: s) else { return false }
        return snapshotDateFormatter.string(from: date) == s
    }

    /// Choose by timestamp rather than array position so callers cannot accidentally
    /// delete the newest snapshot by passing an unsorted list.
    static func newestSnapshotID(in snapshots: [TMSnapshot]) -> String? {
        snapshots.max { lhs, rhs in
            let left = lhs.date ?? .distantPast
            let right = rhs.date ?? .distantPast
            return left == right ? lhs.name < rhs.name : left < right
        }?.id
    }

    /// Delete the given snapshots via tmutil with administrator privileges. The newest
    /// snapshot is never offered for deletion by the UI. Returns true on success.
    @discardableResult
    func deleteSnapshots(_ toDelete: [TMSnapshot]) async -> Bool {
        // Include the requested objects in the protection pool so the safety invariant
        // still holds if a caller invokes deletion before a refresh populated state.
        let newestID = Self.newestSnapshotID(in: snapshots + toDelete)
        let safeSelection = toDelete.filter { $0.id != newestID }
        let stamps = Array(Set(safeSelection
            .compactMap { Self.deletionTimestamp(for: $0) }
            .filter(Self.isValidTimestamp))).sorted()
        guard let script = Self.deletionScript(for: stamps) else { return false }

        await MainActor.run { isBusy = true; lastError = nil }
        let ok = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let privateDirectory = fm.temporaryDirectory
                    .appendingPathComponent("SparkClean-TM-\(UUID().uuidString)", isDirectory: true)
                let scriptURL = privateDirectory.appendingPathComponent("delete-snapshots.sh")
                do {
                    try fm.createDirectory(
                        at: privateDirectory,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try Data(script.utf8).write(to: scriptURL, options: .withoutOverwriting)
                    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
                } catch {
                    try? fm.removeItem(at: privateDirectory)
                    continuation.resume(returning: false)
                    return
                }
                let escaped = scriptURL.path.replacingOccurrences(of: "'", with: "'\\''")
                let source = "do shell script \"/bin/bash '\(escaped)'\" with administrator privileges"
                var success = false
                DispatchQueue.main.sync {
                    var error: NSDictionary?
                    NSAppleScript(source: source)?.executeAndReturnError(&error)
                    success = (error == nil)
                }
                try? fm.removeItem(at: privateDirectory)
                continuation.resume(returning: success)
            }
        }
        await refresh()
        let verification = await MainActor.run { () -> (refreshSucceeded: Bool, removed: [String]) in
            guard lastError == nil else { return (false, []) }
            let remaining = Set(snapshots.compactMap {
                Self.deletionTimestamp(for: $0)
            })
            return (true, stamps.filter { !remaining.contains($0) })
        }
        if verification.refreshSucceeded, !verification.removed.isEmpty {
            let sessionID = "tm-\(ProcessInfo.processInfo.globallyUniqueString)"
            for stamp in verification.removed {
                DeletionAuditLogger.shared.recordEvent(
                    "/usr/bin/tmutil deletelocalsnapshots \(stamp) (verified absent)",
                    category: "Time Machine",
                    sessionID: sessionID,
                    appVersion: CleanupManager.appVersionString
                )
            }
        }
        let allRemoved = verification.refreshSucceeded &&
            verification.removed.count == stamps.count
        await MainActor.run {
            if verification.refreshSucceeded {
                if allRemoved {
                    lastError = nil
                } else if !verification.removed.isEmpty {
                    lastError = "Removed \(verification.removed.count) of \(stamps.count) snapshots. The remaining snapshots were not deleted."
                } else {
                    lastError = ok
                        ? "The selected snapshots are still present."
                        : "Snapshot deletion failed or was cancelled."
                }
            }
            isBusy = false
        }
        return allRemoved
    }
}
