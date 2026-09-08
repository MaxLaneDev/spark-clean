//
//  DiskMapView.swift
//  SparkClean
//
//  Created by George Khananaev.
//

import SwiftUI
import AppKit

struct DiskMapView: View {
    @State private var manager = DiskMapManager.shared
    @State private var didRunLaunchAnalysis = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let snapshot = manager.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if manager.isScanning {
                            progressBanner
                        }
                        if let error = manager.lastError {
                            accessBanner(error, snapshot: snapshot)
                        }
                        capacityCard(snapshot)
                        dataVolumeSection(snapshot)
                        entrySection(
                            title: String(localized: "Your files"),
                            subtitle: NSHomeDirectory(),
                            subtitleIsTechnical: true,
                            entries: snapshot.homeRoots,
                            comparisonSize: snapshot.dataVolumeUsedSpace
                        )
                        entrySection(
                            title: String(localized: "Your Library"),
                            subtitle: String(localized: "~/Library — app data, containers, messages, mail, and caches"),
                            entries: snapshot.libraryRoots,
                            comparisonSize: snapshot.dataVolumeUsedSpace
                        )
                        apfsVolumesSection(snapshot)
                        auditFooter(snapshot)
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            } else if manager.isScanning {
                scanningPlaceholder
            } else {
                emptyState
            }
        }
        .onAppear {
            guard !didRunLaunchAnalysis else { return }
            didRunLaunchAnalysis = true
            let requestedAtLaunch = ProcessInfo.processInfo.arguments.contains("--analyze-storage")
            let shouldHonorLaunchRequest = requestedAtLaunch && !manager.didHandleLaunchRequest
            if shouldHonorLaunchRequest {
                manager.didHandleLaunchRequest = true
            }
            if manager.snapshot == nil || shouldHonorLaunchRequest {
                Task { await manager.scan() }
            }
        }
    }

    private var header: some View {
        AdaptiveHeader {
            HStack(spacing: 14) {
                Image(systemName: "internaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Disk Map")
                        .font(.title3)
                        .fontWeight(.bold)
                    if let snapshot = manager.snapshot {
                        Text(
                            String(
                                localized: "\(CleanupManager.formatBytes(snapshot.containerUsedSpace)) used of \(CleanupManager.formatBytes(snapshot.containerTotalSpace))"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("See where all startup-disk space is allocated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } actions: {
            Button {
                if manager.isScanning {
                    manager.cancel()
                } else {
                    Task { await manager.scan() }
                }
            } label: {
                ToolbarActionLabel(
                    title: manager.isScanning ? String(localized: "Cancel") : String(localized: "Scan"),
                    systemImage: manager.isScanning ? "xmark.circle" : "magnifyingglass"
                )
            }
            .platformPrimaryActionStyle(tint: manager.isScanning ? .orange : .blue)
            .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .platformHeaderSurface()
    }

    private var progressBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Updating the disk map…")
                    .font(.callout.weight(.semibold))
                Text(manager.currentItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("This can take several minutes on a full disk.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.indigo.opacity(0.08))
        )
    }

    private func accessBanner(_ message: String, snapshot: DiskMapSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: snapshot.hasFullDiskAccess ? "lock.trianglebadge.exclamationmark" : "lock.shield")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    snapshot.hasFullDiskAccess
                        ? String(localized: "Some protected space remains")
                        : String(localized: "Full Disk Access needed")
                )
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !snapshot.hasFullDiskAccess {
                Button("Grant Access") {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func capacityCard(_ snapshot: DiskMapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Startup APFS container", systemImage: "externaldrive.fill")
                    .font(.headline)
                Spacer()
                Text("\((usedPercentage(snapshot) / 100).formatted(.percent.precision(.fractionLength(1)))) used")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.green.opacity(0.18))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.indigo, .blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: geometry.size.width
                                * CGFloat(min(1, max(0, usedPercentage(snapshot) / 100)))
                        )
                }
            }
            .frame(height: 18)

            HStack(spacing: 28) {
                metric(String(localized: "Used"), snapshot.containerUsedSpace, color: .indigo)
                metric(String(localized: "Free"), snapshot.containerFreeSpace, color: .green)
                metric(String(localized: "Data volume"), snapshot.dataVolumeUsedSpace, color: .blue)
                metric(String(localized: "Readable files"), snapshot.measuredDataFileSpace, color: .teal)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    private func metric(_ title: String, _ value: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(CleanupManager.formatBytes(value))
                .font(.callout.monospacedDigit().weight(.semibold))
        }
    }

    private func dataVolumeSection(_ snapshot: DiskMapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                String(localized: "Data volume"),
                subtitle: String(localized: "Non-overlapping top-level locations — not just cleanup candidates")
            )

            if snapshot.unaccountedDataSpace > 0 {
                specialRow(
                    name: String(localized: "Protected & APFS-managed space"),
                    description: protectedDescription(snapshot),
                    size: snapshot.unaccountedDataSpace,
                    icon: "lock.square.stack.fill",
                    color: .orange,
                    comparisonSize: snapshot.dataVolumeUsedSpace
                )
            }

            ForEach(snapshot.dataRoots) { entry in
                entryRow(entry, comparisonSize: snapshot.dataVolumeUsedSpace)
            }

            if snapshot.sharedBlockOvercount > 0 {
                specialRow(
                    name: String(localized: "Shared APFS clone records"),
                    description: String(localized: "Folder totals overlap by this amount; APFS stores the shared blocks only once."),
                    size: snapshot.sharedBlockOvercount,
                    icon: "square.on.square",
                    color: .purple,
                    comparisonSize: max(snapshot.measuredDataFileSpace, 1)
                )
            }
        }
    }

    private func entrySection(
        title: String,
        subtitle: String,
        subtitleIsTechnical: Bool = false,
        entries: [DiskMapEntry],
        comparisonSize: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(title, subtitle: subtitle, subtitleIsTechnical: subtitleIsTechnical)
            if entries.isEmpty {
                Text("No measurable folders were found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(entries) { entry in
                    entryRow(entry, comparisonSize: comparisonSize)
                }
            }
        }
    }

    private func apfsVolumesSection(_ snapshot: DiskMapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                String(localized: "APFS volumes"),
                subtitle: String(localized: "macOS shares one physical container across these volumes")
            )
            ForEach(snapshot.volumes) { volume in
                HStack(spacing: 12) {
                    Image(systemName: volume.roles.contains("Data") ? "person.crop.square.fill" : "gearshape.2.fill")
                        .foregroundStyle(volume.roles.contains("Data") ? .blue : .secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(volume.name)
                            .font(.callout)
                        Text(volume.displayRole)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(CleanupManager.formatBytes(volume.usedSpace))
                        .font(.callout.monospacedDigit().weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(rowBackground)
            }
            if snapshot.apfsContainerOverhead > 0 {
                specialRow(
                    name: String(localized: "APFS container metadata"),
                    description: String(localized: "Filesystem metadata not assigned to an individual APFS volume."),
                    size: snapshot.apfsContainerOverhead,
                    icon: "cylinder.split.1x2",
                    color: .secondary,
                    comparisonSize: snapshot.containerUsedSpace
                )
            }
        }
    }

    private func entryRow(_ entry: DiskMapEntry, comparisonSize: Int64) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: entry.measurementIncomplete ? "folder.badge.questionmark" : "folder.fill")
                    .foregroundStyle(entry.measurementIncomplete ? .orange : .indigo)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.callout)
                        .lineLimit(1)
                    if entry.measurementIncomplete {
                        Text("Partial — contains unreadable locations")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Text(CleanupManager.formatBytes(entry.size))
                    .font(.callout.monospacedDigit().weight(.medium))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: entry.path)
                    ])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.indigo.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(entry.measurementIncomplete ? Color.orange : Color.indigo)
                            .frame(
                                width: geometry.size.width * CGFloat(
                                    min(1, Double(entry.size) / Double(max(1, comparisonSize)))
                                )
                            )
                    }
            }
            .frame(height: 4)
            .padding(.leading, 34)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
    }

    private func specialRow(
        name: String,
        description: String,
        size: Int64,
        icon: String,
        color: Color,
        comparisonSize: Int64
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.weight(.semibold))
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(CleanupManager.formatBytes(size))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.18), lineWidth: 1)
                )
        )
        .accessibilityLabel(
            String(localized: "\(name), \(CleanupManager.formatBytes(size)), \(Int(Double(size) / Double(max(1, comparisonSize)) * 100)) percent")
        )
    }

    private func sectionHeading(
        _ title: String, subtitle: String, subtitleIsTechnical: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if subtitleIsTechnical {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .technicalTextDirection()
            } else {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func auditFooter(_ snapshot: DiskMapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(
                String(
                    localized: "Analyzed \(snapshot.generatedAt.formatted(date: .abbreviated, time: .standard)) in \(snapshot.scanDuration.formatted(.number.precision(.fractionLength(1)))) seconds."
                )
            )
            HStack(spacing: 4) {
                Text("Latest audit:")
                Text("~/Library/Logs/SparkClean/latest-storage-map.json")
                    .technicalTextDirection()
            }
            Text("Folder values are allocated-size estimates. APFS volume totals above are authoritative.")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Building your complete disk map…")
                .font(.headline)
            Text(manager.currentItem)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This is read-only and may take several minutes on a full disk.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No disk map yet")
                .font(.headline)
            Text("Analyze the startup disk to account for files, protected data, and APFS volumes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = manager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button {
                Task { await manager.scan() }
            } label: {
                PrimaryActionLabel(title: String(localized: "Scan"), systemImage: "magnifyingglass")
            }
            .platformPrimaryActionStyle(tint: .blue)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rowBackground: some ShapeStyle {
        Color(nsColor: .windowBackgroundColor)
    }

    private func usedPercentage(_ snapshot: DiskMapSnapshot) -> Double {
        guard snapshot.containerTotalSpace > 0 else { return 0 }
        return Double(snapshot.containerUsedSpace) / Double(snapshot.containerTotalSpace) * 100
    }

    private func protectedDescription(_ snapshot: DiskMapSnapshot) -> String {
        if !snapshot.hasFullDiskAccess {
            return String(localized: "Files hidden by macOS privacy controls plus filesystem metadata and shared APFS blocks.")
        }
        return String(localized: "macOS-owned files, filesystem metadata, snapshots, and blocks a folder walk cannot safely assign.")
    }
}
