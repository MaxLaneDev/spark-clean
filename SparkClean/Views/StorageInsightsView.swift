//
//  StorageInsightsView.swift
//  SparkClean
//
//  Created by George Khananaev.
//

import SwiftUI
import AppKit

struct StorageInsightsView: View {
    @State private var manager = StorageInsightsManager()
    var onReviewWhatsAppCleanup: () -> Void = {}

    init(onReviewWhatsAppCleanup: @escaping () -> Void = {}) {
        self.onReviewWhatsAppCleanup = onReviewWhatsAppCleanup
    }

    private var totalWatched: Int64 {
        manager.items.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            banner
            list
        }
        .onAppear {
            if manager.items.allSatisfy({ $0.size == 0 }) {
                Task { await manager.measure(today: StorageInsightsManager.todayString(Date())) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.title2).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Storage Insights").font(.title3).fontWeight(.bold)
                Text("\(CleanupManager.formatBytes(totalWatched)) across \(manager.items.filter { $0.size > 0 }.count) watched stores")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if manager.isMeasuring {
                    manager.cancelMeasurement()
                } else {
                    Task { await manager.measure(today: StorageInsightsManager.todayString(Date())) }
                }
            } label: {
                Label(
                    manager.isMeasuring ? String(localized: "Cancel") : String(localized: "Refresh"),
                    systemImage: manager.isMeasuring ? "xmark.circle" : "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye").foregroundStyle(.teal)
            Text("These stores grow over time but usually shouldn't be bulk-deleted. This view only measures — nothing here is removed.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }

    private var list: some View {
        let visibleItems = manager.items.filter {
            $0.size > 0 || !$0.accessible || $0.measurementIncomplete
        }
        return ScrollView {
            if visibleItems.isEmpty && !manager.isMeasuring {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No watched storage found")
                        .font(.headline)
                    Text("Install or use a supported app, then refresh this view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(visibleItems) { item in
                        row(item)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
            }
        }
    }

    private func row(_ item: InsightItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .foregroundStyle(.teal).frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.callout)
                    if !item.accessible {
                        Label("Needs Full Disk Access", systemImage: "lock.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if item.measurementIncomplete {
                        Label("Partial measurement — refresh to retry", systemImage: "clock.badge.exclamationmark")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if let delta = item.delta, delta != 0 {
                        let up = delta > 0
                        Label(String(localized: "\(up ? "+" : "−")\(CleanupManager.formatBytes(abs(delta))) since last check"),
                              systemImage: up ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                            .foregroundStyle(up ? .orange : .green)
                    }
                }

                Spacer()

                Text(item.accessible ? CleanupManager.formatBytes(item.size) : "—")
                    .font(.callout.monospacedDigit()).fontWeight(.medium)

                Button {
                    let path = item.templatePaths
                        .lazy
                        .flatMap { StorageInsightsManager.resolvePaths($0) }
                        .first
                    if let path {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }

            if item.id == "whatsapp", item.accessible, item.size > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack.fill")
                        .foregroundStyle(.orange)
                    Text("Includes locally stored chat attachments. Review the full media store before clearing it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Review & Clear") {
                        onReviewWhatsAppCleanup()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
                .padding(.leading, 34)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }
}
