//
//  DuplicateFinderView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AppKit
import CryptoKit
import ImageIO
import os

// MARK: - Duplicate Group Model

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let fileName: String
    let fileSize: Int64
    let paths: [String]
    let isSimilarImage: Bool
    let wastedSize: Int64
    var isSelected: Bool = false

    init(fileName: String, fileSize: Int64, paths: [String], isSimilarImage: Bool = false) {
        self.fileSize = fileSize
        self.isSimilarImage = isSimilarImage
        if isSimilarImage {
            // Keep the largest image first (then path-sort ties) so cleaning never
            // discards the best-quality copy because filesystem enumeration happened
            // to return a smaller image first.
            var measured: [(path: String, size: Int64)] = []
            measured.reserveCapacity(paths.count)
            for path in paths {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let number = attrs?[.size] as? NSNumber
                measured.append((path: path, size: number?.int64Value ?? 0))
            }
            measured.sort {
                $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size
            }
            self.paths = measured.map { $0.path }
            self.fileName = measured.first.map {
                ($0.path as NSString).lastPathComponent
            } ?? fileName
            self.wastedSize = measured.dropFirst().reduce(0) { $0 + $1.size }
        } else {
            self.fileName = fileName
            self.paths = paths.sorted()
            self.wastedSize = fileSize * Int64(paths.count - 1)
        }
    }
}

// MARK: - Duplicate Finder Manager

@Observable
class DuplicateFinderManager {
    var duplicateGroups: [DuplicateGroup] = []
    var isScanning = false
    var scanComplete = false
    var scanProgress: Double = 0
    var currentScanItem = ""
    var totalWastedSpace: Int64 = 0
    var scanWasPartial = false
    var searchQuery = ""
    var scanStats = ""
    private let cancelLock = OSAllocatedUnfairLock(initialState: false)
    var cancelRequested: Bool {
        get { cancelLock.withLock { $0 } }
        set { cancelLock.withLock { $0 = newValue } }
    }

    var filteredGroups: [DuplicateGroup] {
        if searchQuery.isEmpty {
            return duplicateGroups
        }
        return duplicateGroups.filter {
            $0.fileName.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var selectedCount: Int {
        duplicateGroups.filter { $0.isSelected }.count
    }

    var selectedWastedSpace: Int64 {
        duplicateGroups.filter { $0.isSelected }.reduce(0) { $0 + $1.wastedSize }
    }

    var selectedSimilarCount: Int {
        duplicateGroups.filter { $0.isSelected && $0.isSimilarImage }.count
    }

    // MARK: - Scan Duplicates

    func cancelScan() {
        cancelRequested = true
    }

    private static func searchRoots(home: String) -> [String] {
        [
            "\(home)/Downloads", "\(home)/Desktop", "\(home)/Documents",
            "\(home)/Movies", "\(home)/Music", "\(home)/Pictures"
        ]
    }

    func scanDuplicates() {
        isScanning = true
        scanComplete = false
        duplicateGroups = []
        totalWastedSpace = 0
        scanProgress = 0
        scanWasPartial = false
        cancelRequested = false
        currentScanItem = String(localized: "Preparing scan...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let home = NSHomeDirectory()
            let dirs = Self.searchRoots(home: home)

            // Phase 1: Group files by size
            DispatchQueue.main.async {
                self.currentScanItem = String(localized: "Grouping files by size...")
                self.scanProgress = 0.05
            }

            // Device + inode is the real hard-link identity. Inode alone can collide
            // across volumes and incorrectly discard an otherwise valid candidate.
            var sizeGroups: [Int64: [(String, FileRemover.FileIdentity?)]] = [:]
            let minSize: Int64 = 100_000           // 100KB (catches photos)
            let maxSize: Int64 = 2_147_483_648     // 2GB
            var totalFilesScanned = 0
            var totalImagesScanned = 0
            var hitWatchdog = false
            let maximumScannedFiles = 1_000_000

            for (dirIndex, dir) in dirs.enumerated() where fm.fileExists(atPath: dir) {
                if self.cancelRequested || hitWatchdog { break }
                let dirName = (dir as NSString).lastPathComponent
                DispatchQueue.main.async {
                    self.currentScanItem = String(localized: "Scanning \(dirName)...")
                    self.scanProgress = 0.05 + Double(dirIndex) / Double(dirs.count) * 0.30
                }

                guard let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: dir),
                    includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isPackageKey,
                                                  .isSymbolicLinkKey,
                                                  .isUbiquitousItemKey,
                                                  .ubiquitousItemDownloadingStatusKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let url as URL in enumerator {
                    if self.cancelRequested || hitWatchdog {
                        enumerator.skipDescendants()
                        break
                    }
                    autoreleasepool {
                        guard let rv = try? url.resourceValues(
                            forKeys: [.fileSizeKey, .isRegularFileKey, .isPackageKey,
                                      .isSymbolicLinkKey,
                                      .isUbiquitousItemKey,
                                      .ubiquitousItemDownloadingStatusKey]
                        ) else { return }

                        if rv.isPackage == true { enumerator.skipDescendants(); return }
                        if rv.isSymbolicLink == true { return }
                        if rv.isUbiquitousItem == true { return }
                        guard rv.isRegularFile == true else { return }

                        // Exact-duplicate candidates must be grouped by logical byte
                        // length. Allocated size can differ for identical compressed,
                        // sparse, or cloned files and would create false negatives.
                        let size = Int64(rv.fileSize ?? 0)
                        totalFilesScanned += 1
                        if totalFilesScanned >= maximumScannedFiles {
                            hitWatchdog = true
                            enumerator.skipDescendants()
                            return
                        }
                        let ext = url.pathExtension.lowercased()
                        if Self.imageExtensions.contains(ext) { totalImagesScanned += 1 }
                        guard size >= minSize, size <= maxSize else { return }

                        sizeGroups[size, default: []].append((
                            url.path,
                            FileRemover.fileIdentity(at: url.path)
                        ))
                    }
                }

            }

            // Keep unique sizes until every root has been visited: copies frequently
            // live in different folders (for example Downloads and Documents).
            sizeGroups = sizeGroups.filter { $0.value.count > 1 }

            DispatchQueue.main.async {
                self.currentScanItem = String(localized: "Comparing file headers...")
                self.scanProgress = 0.40
            }

            // Phase 2: Compare file contents
            var results: [DuplicateGroup] = []
            var totalWasted: Int64 = 0
            let groupCount = sizeGroups.count
            var groupIndex = 0

            for (fileSize, entries) in sizeGroups {
                if self.cancelRequested { break }
                groupIndex += 1

                if groupIndex % 10 == 0 {
                    let progress = 0.40 + Double(groupIndex) / Double(max(groupCount, 1)) * 0.55
                    DispatchQueue.main.async {
                        self.scanProgress = min(progress, 0.95)
                        self.currentScanItem = String(localized: "Comparing candidates (\(groupIndex)/\(groupCount))...")
                    }
                }

                // Skip hard links (same device + inode). Identity lookup failures stay
                // eligible rather than being conflated into one synthetic identity.
                var uniqueIdentities: [FileRemover.FileIdentity: [String]] = [:]
                var unknownIdentityPaths: [String] = []
                for (path, identity) in entries {
                    if let identity {
                        uniqueIdentities[identity, default: []].append(path)
                    } else {
                        unknownIdentityPaths.append(path)
                    }
                }
                let candidates = uniqueIdentities.values.compactMap {
                    $0.min()
                } + unknownIdentityPaths
                guard candidates.count > 1 else { continue }

                // Compare first 4KB header
                var headerGroups: [Data: [String]] = [:]
                for path in candidates.sorted() {
                    if self.cancelRequested { break }
                    autoreleasepool {
                        guard let handle = FileHandle(forReadingAtPath: path) else { return }
                        let header = handle.readData(ofLength: 4096)
                        handle.closeFile()
                        headerGroups[header, default: []].append(path)
                    }
                }

                for (_, paths) in headerGroups where paths.count > 1 {
                    // Full SHA256 hash
                    var fullHashGroups: [String: [String]] = [:]
                    for path in paths {
                        if self.cancelRequested { break }
                        if let hash = Self.sha256(
                            ofFile: path,
                            isCancelled: { self.cancelRequested }
                        ) {
                            fullHashGroups[hash, default: []].append(path)
                        }
                    }

                    for (_, dupPaths) in fullHashGroups where dupPaths.count > 1 {
                        let name = (dupPaths[0] as NSString).lastPathComponent
                        let group = DuplicateGroup(
                            fileName: name,
                            fileSize: fileSize,
                            paths: dupPaths
                        )
                        results.append(group)
                        totalWasted += group.wastedSize
                    }
                }
            }

            // Collect paths already found as exact duplicates
            let exactDupPaths = Set(results.flatMap(\.paths))

            // Phase 3: Find visually similar images
            if !self.cancelRequested && !hitWatchdog {
                DispatchQueue.main.async {
                    self.currentScanItem = String(localized: "Scanning for similar images...")
                    self.scanProgress = 0.70
                }
                let similarImages = self.scanSimilarImages(existingDupPaths: exactDupPaths)
                results.append(contentsOf: similarImages)
                for group in similarImages {
                    totalWasted += group.wastedSize
                }
            }

            // Sort by wasted size descending
            results.sort {
                $0.wastedSize == $1.wastedSize
                    ? ($0.paths.first ?? "") < ($1.paths.first ?? "")
                    : $0.wastedSize > $1.wastedSize
            }

            let wasCancelled = self.cancelRequested
            let wasPartial = wasCancelled || hitWatchdog
            DispatchQueue.main.async {
                self.duplicateGroups = results
                self.totalWastedSpace = totalWasted
                self.scanStats = String(localized: "Scanned \(totalFilesScanned) files (\(totalImagesScanned) images)") +
                    (wasCancelled
                        ? String(localized: " · cancelled, partial results")
                        : (hitWatchdog ? String(localized: " · safety limit reached, partial results") : ""))
                self.scanWasPartial = wasPartial
                self.isScanning = false
                self.scanComplete = true
                self.scanProgress = wasPartial ? 0 : 1.0
                self.currentScanItem = ""
            }
        }
    }

    // MARK: - Clean Selected

    func cleanSelected() async -> Int {
        let selected = duplicateGroups.filter { $0.isSelected }
        guard !selected.isEmpty else { return 0 }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: 0)
                    return
                }
                let fm = FileManager.default
                var removedPathsByGroup: [UUID: Set<String>] = [:]
                var failureCount = 0
                let allowedRoots = Self.searchRoots(home: NSHomeDirectory())

                let remover = FileRemover(policy: CleanupManager.deletionPolicy, useTrash: true)
                let recorder = CleanupSessionRecorder(
                    appVersion: CleanupManager.appVersionString,
                    trashMode: true,
                    store: CleanupManager.manifestStore
                )

                for group in selected {
                    // Verify the keeper still exists before deleting any copy.
                    guard group.paths.count > 1 else {
                        failureCount += 1
                        continue
                    }
                    let keeper = group.paths[0]
                    guard fm.fileExists(atPath: keeper),
                          let keeperIdentity = FileRemover.fileIdentity(at: keeper) else {
                        removedPathsByGroup[group.id, default: []].formUnion(
                            group.paths.filter { !fm.fileExists(atPath: $0) }
                        )
                        failureCount += 1
                        continue
                    }

                    for path in group.paths.dropFirst() {
                        guard fm.fileExists(atPath: path) else {
                            removedPathsByGroup[group.id, default: []].insert(path)
                            failureCount += 1
                            continue
                        }
                        guard let identity = FileRemover.fileIdentity(at: path) else {
                            failureCount += 1
                            continue
                        }
                        let stillMatches: Bool
                        if group.isSimilarImage,
                           let candidateHash = Self.perceptualHash(ofImage: path),
                           FileRemover.fileIdentity(at: keeper) == keeperIdentity,
                           let currentKeeperHash = Self.perceptualHash(ofImage: keeper),
                           FileRemover.fileIdentity(at: keeper) == keeperIdentity {
                            stillMatches = Self.hammingDistance(
                                currentKeeperHash,
                                candidateHash
                            ) <= 5
                        } else if !group.isSimilarImage,
                                  let candidateHash = Self.sha256(ofFile: path),
                                  FileRemover.fileIdentity(at: keeper) == keeperIdentity,
                                  let currentKeeperHash = Self.sha256(ofFile: keeper),
                                  FileRemover.fileIdentity(at: keeper) == keeperIdentity {
                            stillMatches = candidateHash == currentKeeperHash
                        } else {
                            stillMatches = false
                        }
                        guard stillMatches else {
                            failureCount += 1
                            continue
                        }
                        switch remover.remove(
                            path,
                            allowedRoots: allowedRoots,
                            expectedIsDirectory: false,
                            expectedIdentity: identity
                        ) {
                        case .removed(let removal):
                            removedPathsByGroup[group.id, default: []].insert(removal.originalPath)
                            recorder.record(removal, category: "Duplicate Finder")
                            DeletionAuditLogger.shared.record(
                                [removal],
                                category: "Duplicate Finder",
                                sessionID: recorder.sessionID,
                                appVersion: CleanupManager.appVersionString,
                                trashMode: true
                            )
                        default:
                            failureCount += 1
                        }
                    }
                }

                recorder.finish()

                DispatchQueue.main.async {
                    for index in self.duplicateGroups.indices.reversed() {
                        let group = self.duplicateGroups[index]
                        guard let removed = removedPathsByGroup[group.id], !removed.isEmpty else {
                            continue
                        }
                        let remaining = group.paths.filter { !removed.contains($0) }
                        if remaining.count < 2 {
                            self.duplicateGroups.remove(at: index)
                        } else {
                            // Keep a truthful, deselected remainder after partial
                            // failure so the UI never offers already-trashed paths.
                            self.duplicateGroups[index] = DuplicateGroup(
                                fileName: (remaining[0] as NSString).lastPathComponent,
                                fileSize: group.fileSize,
                                paths: remaining,
                                isSimilarImage: group.isSimilarImage
                            )
                        }
                    }
                    self.totalWastedSpace = self.duplicateGroups.reduce(0) { $0 + $1.wastedSize }
                    continuation.resume(returning: failureCount)
                }
            }
        }
    }

    // MARK: - Select Helpers

    func selectAll() {
        for i in duplicateGroups.indices {
            // Similar images are intentionally never batch-selected: they are visual
            // matches, not byte-identical files, and require individual review.
            duplicateGroups[i].isSelected = !duplicateGroups[i].isSimilarImage
        }
    }

    func deselectAll() {
        for i in duplicateGroups.indices {
            duplicateGroups[i].isSelected = false
        }
    }

    // MARK: - SHA256 Streaming Hash

    private static func sha256(
        ofFile path: String,
        isCancelled: () -> Bool = { false }
    ) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        var hasher = CryptoKit.SHA256()
        while autoreleasepool(invoking: {
            if isCancelled() { return false }
            let data = handle.readData(ofLength: 262_144) // 256KB — optimal for APFS
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        if isCancelled() { return nil }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Perceptual Image Hash (dHash)

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "pef", "sr2"
    ]

    /// Difference hash (dHash) — compares adjacent pixel brightness in an 9x8 grid.
    /// Produces a 64-bit hash. Similar images produce similar hashes.
    /// Uses CGImageSource to create a tiny thumbnail WITHOUT loading the full image into memory.
    private static func perceptualHash(ofImage path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }

        // Create a small thumbnail directly — never loads the full image into RAM
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }

        // Draw into a tiny 9x8 grayscale context
        let width = 9
        let height = 8
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        // Compute difference hash: compare each pixel to its right neighbor
        var hash: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let idx = row * width + col
                if pixels[idx] < pixels[idx + 1] {
                    hash |= 1 << UInt64(row * (width - 1) + col)
                }
            }
        }
        return hash
    }

    /// Hamming distance between two hashes
    private static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    /// Scan for visually similar images (different files that look the same)
    private func scanSimilarImages(existingDupPaths: Set<String>) -> [DuplicateGroup] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let dirs = Self.searchRoots(home: home).filter {
            !$0.hasSuffix("/Movies") && !$0.hasSuffix("/Music")
        }

        let minImageSize: Int64 = 50_000 // 50KB — images can be small

        // Collect image files
        var imageFiles: [(path: String, size: Int64)] = []

        for dir in dirs where fm.fileExists(atPath: dir) {
            if cancelRequested { break }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [
                    .fileSizeKey, .isRegularFileKey, .isPackageKey,
                    .isSymbolicLinkKey,
                    .isUbiquitousItemKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if cancelRequested {
                    enumerator.skipDescendants()
                    break
                }
                autoreleasepool {
                    let ext = url.pathExtension.lowercased()
                    guard Self.imageExtensions.contains(ext) else { return }
                    // Skip files already found as exact duplicates
                    guard !existingDupPaths.contains(url.path) else { return }

                    guard let rv = try? url.resourceValues(
                        forKeys: [
                            .fileSizeKey, .isRegularFileKey, .isPackageKey,
                            .isSymbolicLinkKey,
                            .isUbiquitousItemKey,
                        ]
                    ) else { return }
                    if rv.isPackage == true { enumerator.skipDescendants(); return }
                    if rv.isSymbolicLink == true { return }
                    if rv.isUbiquitousItem == true { return }
                    guard rv.isRegularFile == true else { return }
                    let size = Int64(rv.fileSize ?? 0)
                    guard size >= minImageSize else { return }

                    imageFiles.append((url.path, size))
                }
            }
        }

        guard imageFiles.count > 1 else { return [] }

        // Compute perceptual hashes
        var hashGroups: [UInt64: [(path: String, size: Int64)]] = [:]
        for (idx, file) in imageFiles.enumerated() {
            if cancelRequested { break }
            autoreleasepool {
                if idx % 20 == 0 {
                    let progress = 0.70 + Double(idx) / Double(imageFiles.count) * 0.25
                    DispatchQueue.main.async {
                        self.scanProgress = min(progress, 0.95)
                        self.currentScanItem = String(localized: "Analyzing images (\(idx)/\(imageFiles.count))...")
                    }
                }
                if let hash = Self.perceptualHash(ofImage: file.path) {
                    hashGroups[hash, default: []].append(file)
                }
            }
        }

        // Group similar images (exact hash match = very similar)
        var results: [DuplicateGroup] = []
        var processedHashes = Set<UInt64>()

        for (hash, files) in hashGroups.sorted(by: { $0.key < $1.key }) {
            if cancelRequested { break }
            guard !processedHashes.contains(hash) else { continue }
            processedHashes.insert(hash)

            // Also find nearby hashes (hamming distance <= 5)
            var allSimilar = files
            for (otherHash, otherFiles) in hashGroups.sorted(by: { $0.key < $1.key })
            where otherHash != hash {
                if cancelRequested { break }
                if !processedHashes.contains(otherHash) && Self.hammingDistance(hash, otherHash) <= 5 {
                    allSimilar.append(contentsOf: otherFiles)
                    processedHashes.insert(otherHash)
                }
            }

            guard allSimilar.count > 1 else { continue }

            let paths = allSimilar.map(\.path)
            let maxSize = allSimilar.map(\.size).max() ?? 0
            let name = (paths[0] as NSString).lastPathComponent

            results.append(DuplicateGroup(
                fileName: name,
                fileSize: maxSize,
                paths: paths,
                isSimilarImage: true
            ))
        }

        return results
    }
}

// MARK: - Duplicate Finder View

struct DuplicateFinderView: View {
    @State private var manager = DuplicateFinderManager()
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var showCleanAlert = false
    @State private var isCleaning = false
    @State private var cleanFailureMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            if manager.isScanning {
                scanningSection
            } else if manager.scanComplete {
                if manager.filteredGroups.isEmpty {
                    noResultsSection
                } else {
                    duplicateListSection
                }

                Divider()

                bottomBar
            } else {
                welcomeSection
            }
        }
        .alert("Clean Duplicates?", isPresented: $showCleanAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                Task {
                    isCleaning = true
                    let failures = await manager.cleanSelected()
                    isCleaning = false
                    if failures > 0 {
                        cleanFailureMessage = String(localized: "\(failures) duplicate item(s) could not be moved to Trash. The affected groups remain in the list.")
                    }
                }
            }
        } message: {
            let similarWarning = manager.selectedSimilarCount > 0
                ? String(localized: "\n\n\(manager.selectedSimilarCount) selected group(s) are visual matches, not byte-identical files. Review every path before continuing.")
                : ""
            Text(String(localized: "This keeps the first copy of each selected group and moves the others (\(CleanupManager.formatBytes(manager.selectedWastedSpace))) to Trash.\(similarWarning)"))
        }
        .alert("Some Duplicates Were Not Removed", isPresented: Binding(
            get: { cleanFailureMessage != nil },
            set: { if !$0 { cleanFailureMessage = nil } }
        )) {
            Button("OK", role: .cancel) { cleanFailureMessage = nil }
        } message: {
            Text(cleanFailureMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        AdaptiveHeader {
            HStack(spacing: 14) {
                Image(systemName: "doc.on.doc")
                    .font(.title2)
                    .foregroundStyle(.teal)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Finder")
                        .font(.title3)
                        .fontWeight(.bold)
                    if manager.scanComplete {
                        Text("\(manager.duplicateGroups.count) groups found, \(CleanupManager.formatBytes(manager.totalWastedSpace)) wasted · \(manager.scanStats)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } actions: {
            if manager.scanComplete {
                TextField("Search duplicates...", text: $manager.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            Button {
                if manager.isScanning {
                    manager.cancelScan()
                } else {
                    manager.scanDuplicates()
                }
            } label: {
                ToolbarActionLabel(
                    title:
                        manager.isScanning
                            ? String(localized: "Cancel")
                            : (manager.scanComplete ? String(localized: "Rescan") : String(localized: "Scan")),
                    systemImage: manager.isScanning ? "xmark" : "magnifyingglass"
                )
            }
            .platformPrimaryActionStyle(tint: manager.isScanning ? .orange : .blue)
            .controlSize(.regular)
            .disabled(isCleaning)

            if manager.scanComplete {
                Menu {
                    Button("Select All") { manager.selectAll() }
                    Button("Deselect All") { manager.deselectAll() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .platformOverflowMenuStyle()
                .frame(width: 30, height: 28)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .platformHeaderSurface()
    }

    // MARK: - Scanning

    private var scanningSection: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: manager.scanProgress) {
                Text("Scanning for duplicates...")
                    .font(.headline)
            } currentValueLabel: {
                Text(manager.currentScanItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 400)

            Text("\(Int(manager.scanProgress * 100))%")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Welcome

    private var welcomeSection: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            VStack(spacing: 10) {
                Text("Duplicate Finder")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Scan your common folders for duplicate files.\nFree up space by removing unnecessary copies.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No Results

    private var noResultsSection: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(manager.scanWasPartial ? .orange : .green)
            Text(
                manager.searchQuery.isEmpty
                    ? (manager.scanWasPartial ? String(localized: "Partial Scan Completed") : String(localized: "No Duplicates Found"))
                    : String(localized: "No Matches")
            )
                .font(.title3)
                .fontWeight(.semibold)
            Text(manager.searchQuery.isEmpty
                 ? (manager.scanWasPartial
                    ? String(localized: "No duplicates were found in the files processed. Rescan to complete the remaining folders.\n\(manager.scanStats)")
                    : String(localized: "Your files look clean — no duplicate files were detected.\n\(manager.scanStats)"))
                 : String(localized: "No duplicate groups match your search."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Duplicate List

    private var duplicateListSection: some View {
        IndicatorlessScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(manager.filteredGroups.enumerated()), id: \.element.id) { index, group in
                    DuplicateGroupRow(
                        group: group,
                        isExpanded: expandedGroupIDs.contains(group.id),
                        onToggleSelect: {
                            if let realIndex = manager.duplicateGroups.firstIndex(where: { $0.id == group.id }) {
                                manager.duplicateGroups[realIndex].isSelected.toggle()
                            }
                        },
                        onToggleExpand: {
                            if expandedGroupIDs.contains(group.id) {
                                expandedGroupIDs.remove(group.id)
                            } else {
                                expandedGroupIDs.insert(group.id)
                            }
                        }
                    )
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if manager.selectedCount > 0 {
                Text(
                    manager.selectedCount == 1
                        ? String(localized: "1 group selected, \(CleanupManager.formatBytes(manager.selectedWastedSpace)) wasted")
                        : String(localized: "\(manager.selectedCount) groups selected, \(CleanupManager.formatBytes(manager.selectedWastedSpace)) wasted")
                )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("No groups selected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                showCleanAlert = true
            } label: {
                ToolbarActionLabel(
                    title: isCleaning ? String(localized: "Cleaning...") : String(localized: "Clean Selected"),
                    systemImage: isCleaning ? "arrow.triangle.2.circlepath" : "trash"
                )
            }
            .platformPrimaryActionStyle(tint: .red)
            .controlSize(.regular)
            .disabled(manager.selectedCount == 0 || isCleaning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

// MARK: - Duplicate Group Row

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // Checkbox
                Button(action: onToggleSelect) {
                    Image(systemName: group.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(group.isSelected ? .teal : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())

                // Expand/collapse
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                // File info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.fileName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if group.isSimilarImage {
                            Text("SIMILAR IMAGE")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.purple.opacity(0.15)))
                                .foregroundStyle(.purple)
                        } else {
                            Text("EXACT")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.teal.opacity(0.15)))
                                .foregroundStyle(.teal)
                        }
                    }
                    Text(
                        group.isSimilarImage
                            ? String(localized: "\(group.paths.count) copies (visually identical)")
                            : String(localized: "\(group.paths.count) copies")
                    )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // File size
                Text(CleanupManager.formatBytes(group.fileSize))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                // Wasted space
                Text(String(localized: "+\(CleanupManager.formatBytes(group.wastedSize)) wasted"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(group.wastedSize > 100_000_000 ? .red : .orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleExpand()
            }

            // Expanded paths
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(group.paths.enumerated()), id: \.offset) { index, path in
                        HStack(spacing: 10) {
                            if index == 0 {
                                Text("Keep")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.15)))
                                    .foregroundStyle(.green)
                            } else {
                                Text("Remove")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.red.opacity(0.15)))
                                    .foregroundStyle(.red)
                            }

                            Text(path)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .technicalTextDirection()

                            Spacer()

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 10))
                                    Text("Reveal")
                                        .font(.system(size: 10, weight: .medium))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(group.isSelected ? Color.teal.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(group.isSelected ? Color.teal.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }
}
