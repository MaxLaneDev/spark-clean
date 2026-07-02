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
                Task { await manager.measure(today: StorageInsightsManager.todayString(Date())) }
            } label: {
                Label(manager.isMeasuring ? "Measuring…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(manager.isMeasuring)
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
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(manager.items.filter { $0.size > 0 || !$0.accessible }) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
        }
    }

    private func row(_ item: InsightItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .foregroundStyle(.teal).frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout)
                if !item.accessible {
                    Label("Needs Full Disk Access", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.orange)
                } else if let delta = item.delta, delta != 0 {
                    let up = delta > 0
                    Label("\(up ? "+" : "−")\(CleanupManager.formatBytes(abs(delta))) since last check",
                          systemImage: up ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                        .foregroundStyle(up ? .orange : .green)
                }
            }

            Spacer()

            Text(item.accessible ? CleanupManager.formatBytes(item.size) : "—")
                .font(.callout.monospacedDigit()).fontWeight(.medium)

            Button {
                let path = StorageInsightsManager.resolvePaths(item.templatePaths.first ?? "").first
                if let path {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }
}
