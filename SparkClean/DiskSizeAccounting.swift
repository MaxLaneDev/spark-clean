//
//  DiskSizeAccounting.swift
//  SparkClean
//
//  Created by George Khananaev.
//

import Foundation

/// Accumulates allocated file sizes without counting a complete APFS clone's
/// shared content stream more than once.
///
/// `totalFileAllocatedSize` is a per-file value. Adding it directly can greatly
/// overstate both a directory's physical footprint and its cleanup potential when
/// an application creates thousands of copy-on-write clones. APFS assigns cloned
/// files and their originals the same `fileContentIdentifier`, which gives us a
/// stable way to collapse complete clones without reading or hashing file contents.
///
/// Partially diverged clones can still share some blocks while having different
/// identifiers, so `estimatedUniqueSize` remains an estimate rather than a promise
/// of exactly how much free space deletion will produce.
struct CloneAwareSizeAccumulator: Sendable {
    private(set) var logicalAllocatedSize: Int64 = 0
    private(set) var estimatedUniqueSize: Int64 = 0
    private(set) var duplicateCloneReferences = 0

    private var sharedContentSizes: [Int64: Int64] = [:]

    mutating func add(
        allocatedSize: Int64,
        mayShareFileContent: Bool?,
        fileContentIdentifier: Int64?
    ) {
        let size = max(0, allocatedSize)
        logicalAllocatedSize += size

        guard mayShareFileContent == true,
              let fileContentIdentifier
        else {
            estimatedUniqueSize += size
            return
        }

        if let priorSize = sharedContentSizes[fileContentIdentifier] {
            duplicateCloneReferences += 1
            if size > priorSize {
                estimatedUniqueSize += size - priorSize
                sharedContentSizes[fileContentIdentifier] = size
            }
        } else {
            sharedContentSizes[fileContentIdentifier] = size
            estimatedUniqueSize += size
        }
    }
}
