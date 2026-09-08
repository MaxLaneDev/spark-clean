//
//  TimeMachineView.swift
//  SparkClean
//
//  Created by George Khananaev.
//

import SwiftUI

struct TimeMachineView: View {
    @State private var manager = TimeMachineManager()
    @State private var selected: Set<String> = []
    @State private var showConfirm = false
    @State private var showResult = false
    @State private var resultMessage = ""

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // The newest snapshot is kept as a restore point and can't be selected.
    private var newestSnapshotID: String? {
        TimeMachineManager.newestSnapshotID(in: manager.snapshots)
    }

    private var deletableSnapshots: [TMSnapshot] {
        manager.snapshots.filter { $0.id != newestSnapshotID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if manager.snapshots.isEmpty {
                emptyState
            } else {
                infoBanner
                list
                footer
            }
        }
        .onAppear { Task { await manager.refresh() } }
        .alert("Delete Snapshots", isPresented: $showConfirm) {
            Button("Delete", role: .destructive) {
                let toDelete = deletableSnapshots.filter { selected.contains($0.id) }
                Task {
                    let ok = await manager.deleteSnapshots(toDelete)
                    selected.removeAll()
                    resultMessage = ok
                        ? String(localized: "Requested deletion of \(toDelete.count) snapshot(s). Remaining: \(manager.snapshots.count).")
                        : (manager.lastError ?? String(localized: "Snapshot deletion failed."))
                    showResult = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selected.count) local snapshot(s) will be deleted via tmutil. This may make snapshot-backed space available and requires administrator privileges. Your Time Machine backups on external drives are not affected.")
        }
        .alert("Time Machine", isPresented: $showResult) {
            Button("OK") {}
        } message: {
            Text(resultMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.title2)
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Time Machine")
                    .font(.title3).fontWeight(.bold)
                Text("\(manager.snapshots.count) local snapshot(s) on this disk")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                selected.removeAll()
                Task { await manager.refresh() }
            } label: {
                PrimaryActionLabel(title: String(localized: "Refresh"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.blue)
            .disabled(manager.isBusy)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var infoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.blue)
            Text("macOS keeps local snapshots and thins them under disk pressure. Removing old snapshots may make space available; SparkClean does not estimate an APFS reclaim amount. The most recent snapshot is kept as a restore point.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(manager.snapshots) { snap in
                    HStack(spacing: 12) {
                        if snap.id == newestSnapshotID {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.tertiary)
                                .frame(width: 18)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { selected.contains(snap.id) },
                                set: { on in
                                    if on { selected.insert(snap.id) } else { selected.remove(snap.id) }
                                }
                            ))
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(snap.date.map { Self.displayFormatter.string(from: $0) } ?? snap.name)
                                .font(.callout)
                                .technicalTextDirection()
                            if snap.id == newestSnapshotID {
                                Text("Most recent — kept for restore")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack {
            Button("Select All Older") {
                selected = Set(deletableSnapshots.map(\.id))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(deletableSnapshots.isEmpty)

            Button("Deselect All") { selected.removeAll() }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(selected.isEmpty)

            Spacer()

            Button {
                showConfirm = true
            } label: {
                PrimaryActionLabel(title: String(localized: "Delete Selected"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.red)
            .disabled(selected.isEmpty || manager.isBusy)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: manager.isBusy ? "hourglass" : "checkmark.circle")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(
                manager.isBusy
                    ? String(localized: "Reading snapshots…")
                    : String(localized: "No local Time Machine snapshots")
            )
                .font(.headline)
            if let err = manager.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
