//
//  StorageInsights.swift
//  SparkClean
//
//  Created by George Khananaev.
//
//  The read-only "observe" pillar (F13): measures data stores that grow silently but
//  usually should NOT be bulk-deleted (chat histories, backups, media libraries) and
//  tracks their size over time so growth is visible. This module NEVER deletes anything.
//

import Foundation
import os

struct InsightItem: Identifiable {
    let id: String          // stable key, used for history
    let name: String
    let icon: String
    /// Glob-capable paths (one `*` component supported) that are summed for the size.
    let templatePaths: [String]
    var size: Int64 = 0
    var previousSize: Int64?    // most recent earlier measurement, for trend
    var accessible: Bool = true // false when a path exists but is unreadable (needs FDA)
    var measurementIncomplete = false

    var delta: Int64? {
        guard let prev = previousSize else { return nil }
        return size - prev
    }
}

/// One historical size sample.
struct InsightSample: Codable {
    let itemID: String
    let day: String     // "yyyy-MM-dd"
    let size: Int64
}

/// Persists daily size samples (one per item per day) under Application Support.
/// Immutable configuration + atomic file writes make it safe to share across threads.
final class InsightHistoryStore: @unchecked Sendable {
    let fileURL: URL
    let maxDays: Int
    private let fm = FileManager.default

    init(fileURL: URL? = nil, maxDays: Int = 365) {
        self.fileURL = fileURL ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/SparkClean/insights-history.json")
        self.maxDays = maxDays
    }

    func load() -> [InsightSample] {
        guard let data = try? Data(contentsOf: fileURL),
              let samples = try? JSONDecoder().decode([InsightSample].self, from: data) else { return [] }
        return samples
    }

    private func save(_ samples: [InsightSample]) {
        let directory = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    /// Record today's sizes, replacing any existing sample for the same item+day
    /// (so re-measuring on the same day updates rather than duplicates). Prunes old days.
    func record(sizes: [(itemID: String, size: Int64)], today: String) {
        var samples = load()
        let todaysItems = Set(sizes.map(\.itemID))
        // Drop existing same-day entries for the items we're recording.
        samples.removeAll { $0.day == today && todaysItems.contains($0.itemID) }
        for entry in sizes {
            samples.append(InsightSample(itemID: entry.itemID, day: today, size: entry.size))
        }
        // Prune: keep only the most recent `maxDays` distinct days.
        let recentDays = Set(samples.map(\.day).sorted().suffix(maxDays))
        samples.removeAll { !recentDays.contains($0.day) }
        save(samples)
    }

    /// The most recent sample for `itemID` on a day *before* `today`.
    func previousSize(for itemID: String, before today: String) -> Int64? {
        load()
            .filter { $0.itemID == itemID && $0.day < today }
            .max { $0.day < $1.day }?
            .size
    }
}

@Observable
final class StorageInsightsManager {
    var items: [InsightItem] = []
    var isMeasuring = false

    private let history: InsightHistoryStore
    private static let home = NSHomeDirectory()
    private let cancelLock = OSAllocatedUnfairLock(initialState: false)

    private var cancelRequested: Bool {
        cancelLock.withLock { $0 }
    }

    init(history: InsightHistoryStore = InsightHistoryStore()) {
        self.history = history
        self.items = Self.defaultRegistry()
    }

    /// The watched-store registry. Paths use a single `*` for account/team-ID segments.
    static func defaultRegistry() -> [InsightItem] {
        [
            InsightItem(id: "whatsapp", name: "WhatsApp", icon: "message.fill",
                        templatePaths: [
                            "\(home)/Library/Group Containers/group.net.whatsapp.WhatsApp.shared",
                            "\(home)/Library/Group Containers/group.net.whatsapp.WhatsApp.private",
                            "\(home)/Library/Group Containers/group.net.whatsapp.WhatsAppSMB.shared",
                            "\(home)/Library/Group Containers/group.net.whatsapp.family",
                            "\(home)/Library/Containers/net.whatsapp.WhatsApp",
                            "\(home)/Library/Containers/net.whatsapp.WhatsApp.Intents",
                            "\(home)/Library/Containers/net.whatsapp.WhatsApp.ServiceExtension",
                            "\(home)/Library/Containers/net.whatsapp.WhatsApp.WAAppKitBridgeService",
                        ]),
            InsightItem(id: "telegram", name: "Telegram", icon: "paperplane.fill",
                        templatePaths: ["\(home)/Library/Group Containers/*.ru.keepcoder.Telegram"]),
            InsightItem(id: "wechat", name: "WeChat", icon: "message",
                        templatePaths: ["\(home)/Library/Containers/com.tencent.xinWeChat"]),
            InsightItem(id: "signal", name: "Signal", icon: "lock.message",
                        templatePaths: ["\(home)/Library/Application Support/Signal"]),
            InsightItem(id: "line", name: "LINE", icon: "message.badge",
                        templatePaths: ["\(home)/Library/Containers/jp.naver.line.mac"]),
            InsightItem(id: "slack", name: "Slack", icon: "number",
                        templatePaths: ["\(home)/Library/Application Support/Slack"]),
            InsightItem(id: "discord", name: "Discord", icon: "bubble.left.and.bubble.right",
                        templatePaths: ["\(home)/Library/Application Support/discord"]),
            InsightItem(id: "teams", name: "Microsoft Teams", icon: "person.3.fill",
                        templatePaths: ["\(home)/Library/Containers/com.microsoft.teams2"]),
            InsightItem(id: "chrome-profiles", name: "Chrome Profiles", icon: "globe",
                        templatePaths: ["\(home)/Library/Application Support/Google/Chrome"]),
            InsightItem(id: "claude-data", name: "Claude Desktop Data", icon: "cpu",
                        templatePaths: ["\(home)/Library/Application Support/Claude"]),
            InsightItem(id: "jetbrains-data", name: "JetBrains IDE Data", icon: "chevron.left.forwardslash.chevron.right",
                        templatePaths: ["\(home)/Library/Application Support/JetBrains"]),
            InsightItem(id: "messages", name: "Messages (iMessage)", icon: "bubble.left.and.bubble.right.fill",
                        templatePaths: ["\(home)/Library/Messages"]),
            InsightItem(id: "ios-backups", name: "iOS Device Backups", icon: "iphone",
                        templatePaths: ["\(home)/Library/Application Support/MobileSync/Backup"]),
            InsightItem(id: "photos", name: "Photos Library", icon: "photo.stack.fill",
                        templatePaths: ["\(home)/Pictures/*.photoslibrary"]),
            InsightItem(id: "mail", name: "Mail", icon: "envelope.fill",
                        templatePaths: ["\(home)/Library/Mail"]),
            InsightItem(id: "icloud-drive", name: "iCloud Drive (local)", icon: "icloud.fill",
                        templatePaths: ["\(home)/Library/Mobile Documents"]),
            InsightItem(id: "music", name: "Music Library", icon: "music.note.house.fill",
                        templatePaths: ["\(home)/Music/Music/Media", "\(home)/Music/iTunes"]),
            InsightItem(id: "downloads", name: "Downloads", icon: "arrow.down.circle.fill",
                        templatePaths: ["\(home)/Downloads"]),
            InsightItem(id: "developer-projects", name: "Developer Projects", icon: "folder.badge.gearshape",
                        templatePaths: [
                            "\(home)/GitHub", "\(home)/Projects", "\(home)/Developer",
                            "\(home)/Work", "\(home)/Sites", "\(home)/repos",
                            "\(home)/code", "\(home)/src", "\(home)/dev",
                            "\(home)/workspace",
                        ]),
            InsightItem(id: "installed-apps", name: "Installed Applications", icon: "square.grid.2x2.fill",
                        templatePaths: ["/Applications", "\(home)/Applications"]),
            InsightItem(id: "docker", name: "Docker Desktop", icon: "shippingbox.fill",
                        templatePaths: ["\(home)/Library/Containers/com.docker.docker"]),
            InsightItem(id: "xcode-simulators", name: "Xcode Simulators", icon: "iphone.gen3",
                        templatePaths: ["\(home)/Library/Developer/CoreSimulator/Devices"]),
            InsightItem(id: "virtual-machines", name: "Virtual Machines", icon: "desktopcomputer",
                        templatePaths: ["\(home)/Virtual Machines.localized", "\(home)/Parallels"]),
        ]
    }

    /// Resolve a template path. A single `*` in the LAST path component is expanded
    /// against the filesystem (matching by prefix/suffix around the star); e.g.
    /// `.../Pictures/*.photoslibrary` or `.../Group Containers/*.ru.keepcoder.Telegram`.
    static func resolvePaths(_ template: String) -> [String] {
        let fm = FileManager.default
        guard template.contains("*") else {
            return fm.fileExists(atPath: template) ? [template] : []
        }
        let base = (template as NSString).deletingLastPathComponent
        let pattern = (template as NSString).lastPathComponent
        guard pattern.contains("*") else {
            return fm.fileExists(atPath: template) ? [template] : []
        }
        let starParts = pattern.components(separatedBy: "*")
        let prefix = starParts.first ?? ""
        let suffix = starParts.count > 1 ? starParts[1] : ""
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        var result: [String] = []
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
            let candidate = "\(base)/\(entry)"
            if fm.fileExists(atPath: candidate) { result.append(candidate) }
        }
        return result
    }

    /// Estimated unique allocated size of a tree. Complete APFS clones that share a
    /// content identifier are counted once instead of once per directory entry.
    static func allocatedSize(_ path: String) -> Int64 {
        measureAllocatedSize(path).size
    }

    /// Bounded, clone-aware allocated-size walk. Returns `complete == false` on
    /// cancellation, deadline, or the entry watchdog so one huge/cloud-backed store
    /// cannot wedge the entire Insights refresh.
    static func measureAllocatedSize(
        _ path: String,
        timeout: Duration = .seconds(30),
        maximumEntries: Int = 500_000,
        isCancelled: () -> Bool = { false }
    ) -> (size: Int64, complete: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return (0, true) }
        if !isDir.boolValue {
            let rv = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            return (Int64(rv?.totalFileAllocatedSize ?? 0), true)
        }
        guard let en = fm.enumerator(at: URL(fileURLWithPath: path),
                                     includingPropertiesForKeys: [
                                        .totalFileAllocatedSizeKey, .isRegularFileKey,
                                        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                        .fileContentIdentifierKey, .mayShareFileContentKey,
                                     ],
                                     options: []) else { return (0, false) }
        var accounting = CloneAwareSizeAccumulator()
        var entries = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while let obj = en.nextObject() {
            entries += 1
            if isCancelled() || entries >= maximumEntries || clock.now >= deadline {
                return (accounting.estimatedUniqueSize, false)
            }
            guard let url = obj as? URL else { continue }
            autoreleasepool {
                if let rv = try? url.resourceValues(forKeys: [
                    .totalFileAllocatedSizeKey, .isRegularFileKey,
                    .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                    .fileContentIdentifierKey, .mayShareFileContentKey,
                ]),
                   !(rv.isUbiquitousItem == true &&
                     rv.ubiquitousItemDownloadingStatus == .notDownloaded),
                   rv.isRegularFile == true {
                    accounting.add(
                        allocatedSize: Int64(rv.totalFileAllocatedSize ?? 0),
                        mayShareFileContent: rv.mayShareFileContent,
                        fileContentIdentifier: rv.fileContentIdentifier
                    )
                }
            }
        }
        return (accounting.estimatedUniqueSize, true)
    }

    /// Measure all registry items and record today's history.
    func measure(today: String) async {
        cancelLock.withLock { $0 = false }
        await MainActor.run { isMeasuring = true }
        let registry = items
        let store = history
        let measured: [InsightItem] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var results: [InsightItem] = []
                for var item in registry {
                    if self.cancelRequested {
                        item.measurementIncomplete = true
                        results.append(item)
                        continue
                    }
                    let resolved = item.templatePaths.flatMap { Self.resolvePaths($0) }
                    var size: Int64 = 0
                    var accessible = true
                    var complete = true
                    for path in resolved {
                        if self.cancelRequested {
                            complete = false
                            break
                        }
                        let measurement = Self.measureAllocatedSize(
                            path,
                            isCancelled: { self.cancelRequested }
                        )
                        let s = measurement.size
                        complete = complete && measurement.complete
                        // A path that exists but reports 0 with no readable contents is
                        // likely permission-blocked (needs Full Disk Access).
                        if s == 0 && !((try? FileManager.default.contentsOfDirectory(atPath: path)) != nil) {
                            accessible = false
                        }
                        size += s
                    }
                    item.size = size
                    item.accessible = resolved.isEmpty ? true : accessible
                    item.measurementIncomplete = !complete
                    item.previousSize = store.previousSize(for: item.id, before: today)
                    results.append(item)
                }
                continuation.resume(returning: results)
            }
        }
        // Record history for items that measured something.
        history.record(
            sizes: measured
                .filter { $0.size > 0 && $0.accessible && !$0.measurementIncomplete }
                .map { ($0.id, $0.size) },
            today: today
        )
        await MainActor.run {
            self.items = measured.sorted { $0.size > $1.size }
            self.isMeasuring = false
        }
    }

    func cancelMeasurement() {
        cancelLock.withLock { $0 = true }
    }

    static func todayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
