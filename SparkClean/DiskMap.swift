//
//  DiskMap.swift
//  SparkClean
//
//  Created by George Khananaev.
//
//  A read-only, non-overlapping view of the startup disk. Cleanup results answer
//  "what may I remove?"; this scanner answers "where is all the used space?"
//

import Foundation
import os

struct DiskMapEntry: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let path: String
    let size: Int64
    let measurementIncomplete: Bool
}

struct APFSVolumeUsage: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let roles: [String]
    let usedSpace: Int64

    var displayRole: String {
        guard let role = roles.first else { return name }
        switch role {
        case "Data": return String(localized: "Data")
        case "System": return String(localized: "System")
        case "Preboot": return String(localized: "Preboot")
        case "Recovery": return String(localized: "Recovery")
        case "VM": return String(localized: "Virtual Memory")
        default: return role
        }
    }
}

struct DiskMapSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let scanDuration: TimeInterval
    let containerTotalSpace: Int64
    let containerFreeSpace: Int64
    let dataVolumeUsedSpace: Int64
    let measuredDataFileSpace: Int64
    let volumes: [APFSVolumeUsage]
    let dataRoots: [DiskMapEntry]
    let homeRoots: [DiskMapEntry]
    let libraryRoots: [DiskMapEntry]
    let inaccessiblePaths: [String]
    let hasFullDiskAccess: Bool
    let measurementIncomplete: Bool

    var containerUsedSpace: Int64 {
        max(0, containerTotalSpace - containerFreeSpace)
    }

    /// Space allocated to the Data volume but not attributable through a normal
    /// user-level directory walk. This deliberately stays visible rather than
    /// silently pretending that the folder list explains the whole disk.
    var unaccountedDataSpace: Int64 {
        max(0, dataVolumeUsedSpace - measuredDataFileSpace)
    }

    /// A directory walk can count copy-on-write clone records more than once even
    /// though APFS shares their physical blocks. The APFS volume total is authoritative.
    var sharedBlockOvercount: Int64 {
        max(0, measuredDataFileSpace - dataVolumeUsedSpace)
    }

    var apfsContainerOverhead: Int64 {
        let volumeTotal = volumes.reduce(Int64(0)) { $0 + $1.usedSpace }
        return max(0, containerUsedSpace - volumeTotal)
    }
}

@Observable
final class DiskMapManager {
    static let shared = DiskMapManager()

    var snapshot: DiskMapSnapshot?
    var isScanning = false {
        didSet { ScanActivityTracker.shared.update(from: oldValue, to: isScanning) }
    }
    var currentItem = ""
    var lastError: String?
    var didHandleLaunchRequest = false

    @ObservationIgnored
    private let fileURL: URL
    @ObservationIgnored
    private let cancelLock = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored
    private let processLock = OSAllocatedUnfairLock<Process?>(initialState: nil)
    @ObservationIgnored
    private let scanStateLock = OSAllocatedUnfairLock(initialState: false)

    private var cancelRequested: Bool {
        cancelLock.withLock { $0 }
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Logs/SparkClean/latest-storage-map.json",
                isDirectory: false
            )
        self.snapshot = Self.load(from: self.fileURL)
    }

    func scan() async {
        let didStart = scanStateLock.withLock { alreadyScanning in
            guard !alreadyScanning else { return false }
            alreadyScanning = true
            return true
        }
        guard didStart else { return }
        cancelLock.withLock { $0 = false }
        await MainActor.run {
            isScanning = true
            currentItem = String(localized: "Reading APFS volume totals…")
            lastError = nil
        }

        let result: (snapshot: DiskMapSnapshot?, error: String?) =
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: self.collectSnapshot())
                }
            }

        await MainActor.run {
            isScanning = false
            currentItem = ""
            if let newSnapshot = result.snapshot {
                snapshot = newSnapshot
                Self.save(newSnapshot, to: fileURL)
            }
            if cancelRequested {
                lastError = String(localized: "Disk analysis was cancelled. The previous completed map is still shown.")
            } else {
                lastError = result.error
            }
        }
        scanStateLock.withLock { $0 = false }
    }

    func cancel() {
        cancelLock.withLock { $0 = true }
        processLock.withLock { process in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
    }

    private func collectSnapshot() -> (snapshot: DiskMapSnapshot?, error: String?) {
        let startedAt = Date()
        let dataRoot = "/System/Volumes/Data"
        let homeRoot = dataRoot + NSHomeDirectory()
        let libraryRoot = homeRoot + "/Library"

        guard let diskInfoData = Self.run(
            executable: "/usr/sbin/diskutil",
            arguments: ["info", "-plist", dataRoot]
        ),
        let diskInfo = Self.propertyList(diskInfoData)
        else {
            return (nil, String(localized: "SparkClean could not read the startup disk's APFS information."))
        }

        let containerReference = diskInfo["APFSContainerReference"] as? String ?? ""
        let containerTotal = Self.int64(diskInfo["APFSContainerSize"])
        let containerFree = Self.int64(diskInfo["APFSContainerFree"])
        let dataUsed = Self.int64(diskInfo["CapacityInUse"])
        let volumes = Self.apfsVolumes(containerReference: containerReference)

        guard !cancelRequested else { return (nil, nil) }
        DispatchQueue.main.async {
            self.currentItem = String(localized: "Measuring every readable file on the Data volume…")
        }

        let process = Process()
        let combinedPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        // One filesystem prevents mounted disk images, external disks, and simulator
        // runtimes from being charged to the startup Data volume. Depth four gives us
        // Data roots, home roots, and ~/Library roots in one filesystem traversal.
        process.arguments = ["-x", "-k", "-r", "-d", "4", dataRoot]
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe

        do {
            processLock.withLock { $0 = process }
            try process.run()
        } catch {
            processLock.withLock { $0 = nil }
            return (nil, String(localized: "SparkClean could not start the disk analyzer: \(error.localizedDescription)"))
        }

        let outputData = combinedPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        processLock.withLock { $0 = nil }

        guard !cancelRequested else { return (nil, nil) }

        let parsed = Self.parseDUOutput(outputData)
        guard let measuredData = parsed.sizes[dataRoot] else {
            return (nil, String(localized: "The disk analyzer finished without a usable Data-volume result."))
        }

        let dataRoots = Self.makeEntries(
            parent: dataRoot,
            sizes: parsed.sizes,
            inaccessiblePaths: parsed.inaccessiblePaths,
            layer: .data
        )
        let homeRoots = Self.makeEntries(
            parent: homeRoot,
            sizes: parsed.sizes,
            inaccessiblePaths: parsed.inaccessiblePaths,
            layer: .home
        )
        let libraryRoots = Self.makeEntries(
            parent: libraryRoot,
            sizes: parsed.sizes,
            inaccessiblePaths: parsed.inaccessiblePaths,
            layer: .library
        )

        let fullDiskAccess = Self.canReadProtectedUserData()
        let incomplete = process.terminationStatus != 0 || !parsed.inaccessiblePaths.isEmpty
        let snapshot = DiskMapSnapshot(
            schemaVersion: 1,
            generatedAt: Date(),
            scanDuration: Date().timeIntervalSince(startedAt),
            containerTotalSpace: containerTotal,
            containerFreeSpace: containerFree,
            dataVolumeUsedSpace: dataUsed,
            measuredDataFileSpace: measuredData,
            volumes: volumes,
            dataRoots: dataRoots,
            homeRoots: homeRoots,
            libraryRoots: libraryRoots,
            inaccessiblePaths: Array(parsed.inaccessiblePaths.prefix(100)),
            hasFullDiskAccess: fullDiskAccess,
            measurementIncomplete: incomplete
        )

        let error: String?
        if !fullDiskAccess {
            error = String(localized: "Full Disk Access is required to measure protected Mail, Messages, Safari, and other app data.")
        } else if incomplete {
            error = String(localized: "Some macOS-owned locations could not be read. Their usage remains in Protected & APFS-managed space.")
        } else {
            error = nil
        }
        return (snapshot, error)
    }

    private enum EntryLayer {
        case data
        case home
        case library
    }

    private static func makeEntries(
        parent: String,
        sizes: [String: Int64],
        inaccessiblePaths: [String],
        layer: EntryLayer
    ) -> [DiskMapEntry] {
        let fm = FileManager.default
        let parentURL = URL(fileURLWithPath: parent, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = (try? fm.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        )) ?? []

        var entries: [DiskMapEntry] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: keys)
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }

            // `FileManager` resolves the Data-volume firmlink back to `/Users`
            // when returning children. `du` retains the explicit
            // `/System/Volumes/Data/Users` spelling, so use a measured path for
            // accounting and the resolved path for Finder.
            let measuredPath = parent + "/" + child.lastPathComponent
            let revealPath = child.standardizedFileURL.path
            let size = sizes[measuredPath] ?? 0
            let incomplete = inaccessiblePaths.contains {
                $0 == measuredPath || $0.hasPrefix(measuredPath + "/")
            }
            // Tiny empty/system directories add noise. An unreadable directory is
            // always kept because explaining missing bytes matters more than its
            // currently measurable size.
            guard size >= 1_048_576 || incomplete else { continue }
            entries.append(DiskMapEntry(
                id: measuredPath,
                name: friendlyName(for: child.lastPathComponent, layer: layer),
                path: revealPath,
                size: size,
                measurementIncomplete: incomplete
            ))
        }

        if let parentSize = sizes[parent] {
            let childTotal = entries.reduce(Int64(0)) { $0 + $1.size }
            let directSize = max(0, parentSize - childTotal)
            if directSize >= 1_048_576 {
                entries.append(DiskMapEntry(
                    id: parent + "#direct-files",
                    name: layer == .data
                        ? String(localized: "Other volume-root files")
                        : String(localized: "Other directly stored files"),
                    path: parent,
                    size: directSize,
                    measurementIncomplete: false
                ))
            }
        }

        return entries.sorted {
            if $0.size == $1.size { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.size > $1.size
        }
    }

    private static func friendlyName(for component: String, layer: EntryLayer) -> String {
        guard layer == .data else {
            switch component {
            case ".cache": return String(localized: "Developer & tool caches")
            case ".npm": return String(localized: "npm data")
            case ".bun": return String(localized: "Bun data")
            case ".local": return String(localized: "Local app data")
            case ".Trash": return String(localized: "Trash")
            default:
                return component.hasPrefix(".")
                    ? component
                    : component.replacingOccurrences(of: ".localized", with: "")
            }
        }

        switch component {
        case "Users": return String(localized: "User accounts")
        case "Applications": return String(localized: "Applications")
        case "Library": return String(localized: "Shared Library & app data")
        case "System": return String(localized: "Data-side system files")
        case "private": return String(localized: "System logs, databases & temporary files")
        case "usr": return String(localized: "Unix tools & shared data")
        case "opt": return String(localized: "Third-party command-line tools")
        case ".DocumentRevisions-V100": return String(localized: "Document Versions")
        case ".PreviousSystemInformation": return String(localized: "Previous System Information")
        case ".Spotlight-V100": return String(localized: "Spotlight index")
        case ".fseventsd": return String(localized: "File-system history")
        case "MobileSoftwareUpdate": return String(localized: "Software updates")
        default: return component
        }
    }

    private static func canReadProtectedUserData() -> Bool {
        let fm = FileManager.default
        let candidates = [
            NSHomeDirectory() + "/Library/Mail",
            NSHomeDirectory() + "/Library/Messages",
            NSHomeDirectory() + "/Library/Safari",
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            return (try? fm.contentsOfDirectory(atPath: path)) != nil
        }
        return true
    }

    private static func parseDUOutput(
        _ data: Data
    ) -> (sizes: [String: Int64], inaccessiblePaths: [String]) {
        guard let output = String(data: data, encoding: .utf8) else {
            return ([:], [])
        }

        var sizes: [String: Int64] = [:]
        var inaccessible: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let tab = line.firstIndex(of: "\t"),
               let blocks = Int64(line[..<tab]) {
                let path = String(line[line.index(after: tab)...])
                sizes[path] = blocks.multipliedReportingOverflow(by: 1_024).overflow
                    ? Int64.max
                    : blocks * 1_024
                continue
            }

            guard line.hasPrefix("du: ") else { continue }
            var path = String(line.dropFirst(4))
            for suffix in [
                ": Operation not permitted",
                ": Permission denied",
                ": No such file or directory",
            ] where path.hasSuffix(suffix) {
                path.removeLast(suffix.count)
                break
            }
            if path.hasPrefix("/") && !inaccessible.contains(path) {
                inaccessible.append(path)
            }
        }
        return (sizes, inaccessible)
    }

    private static func apfsVolumes(containerReference: String) -> [APFSVolumeUsage] {
        guard !containerReference.isEmpty,
              let data = run(
                executable: "/usr/sbin/diskutil",
                arguments: ["apfs", "list", "-plist"]
              ),
              let root = propertyList(data),
              let containers = root["Containers"] as? [[String: Any]],
              let container = containers.first(where: {
                  ($0["ContainerReference"] as? String) == containerReference
              }),
              let rawVolumes = container["Volumes"] as? [[String: Any]]
        else { return [] }

        return rawVolumes.compactMap { volume in
            guard let id = volume["DeviceIdentifier"] as? String else { return nil }
            return APFSVolumeUsage(
                id: id,
                name: volume["Name"] as? String ?? id,
                roles: volume["Roles"] as? [String] ?? [],
                usedSpace: int64(volume["CapacityInUse"])
            )
        }
        .sorted { $0.usedSpace > $1.usedSpace }
    }

    private static func propertyList(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )) as? [String: Any]
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return 0
    }

    private static func run(executable: String, arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private static func load(from fileURL: URL) -> DiskMapSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiskMapSnapshot.self, from: data)
    }

    private static func save(_ snapshot: DiskMapSnapshot, to fileURL: URL) {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // The map remains visible in memory even if the optional audit file fails.
        }
    }
}
