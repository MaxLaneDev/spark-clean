//
//  TimeMachineManager.swift
//  SparkClean
//
//  Created by George Khananaev.
//
//  Time Machine local-snapshot management (F14). macOS keeps hourly APFS local
//  snapshots and thins them only lazily under disk pressure, so many Macs carry tens of
//  GB of purgeable "System Data". This lists and deletes those snapshots.
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
            if stamp.hasSuffix(".local") { stamp = String(stamp.dropLast(".local".count)) }
            let date = snapshotDateFormatter.date(from: stamp)
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
        var script = "#!/bin/bash\n"
        for stamp in valid {
            script += "/usr/bin/tmutil deletelocalsnapshots '\(stamp)'\n"
        }
        return script
    }

    /// Strict validator: 19 chars, digits with dashes at the expected positions
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
        return true
    }

    /// Delete the given snapshots via tmutil with administrator privileges. The newest
    /// snapshot is never offered for deletion by the UI. Returns true on success.
    @discardableResult
    func deleteSnapshots(_ toDelete: [TMSnapshot]) async -> Bool {
        let stamps = toDelete.compactMap { Self.deletionTimestamp(for: $0) }
        guard let script = Self.deletionScript(for: stamps) else { return false }

        await MainActor.run { isBusy = true; lastError = nil }
        let ok = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let tempScript = NSTemporaryDirectory() + "sparkclean_tm_\(ProcessInfo.processInfo.processIdentifier).sh"
                try? script.write(toFile: tempScript, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempScript)
                let escaped = tempScript.replacingOccurrences(of: "'", with: "'\\''")
                let source = "do shell script \"/bin/bash '\(escaped)'\" with administrator privileges"
                var success = false
                DispatchQueue.main.sync {
                    var error: NSDictionary?
                    NSAppleScript(source: source)?.executeAndReturnError(&error)
                    success = (error == nil)
                }
                try? FileManager.default.removeItem(atPath: tempScript)
                continuation.resume(returning: success)
            }
        }
        await refresh()
        await MainActor.run {
            if !ok { lastError = "Snapshot deletion failed or was cancelled." }
            isBusy = false
        }
        return ok
    }
}
