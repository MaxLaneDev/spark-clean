//
//  ContentView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Tracks whether the intro video has played this app session (survives view re-creation).
private var _introPlayedThisSession = false

// MARK: - Main Content View

struct ContentView: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var manager = CleanupManager()
    @State private var showCleanAlert = false
    @State private var selectedSidebar: SidebarItem =
        ProcessInfo.processInfo.arguments.contains("--analyze-storage")
        ? .diskMap
        : .dashboard
    @State private var showExportSheet = false
    @State private var showCleanComplete = false
    @State private var exportVerbose = false
    @State private var exportReport = ""
    @State private var isGeneratingReport = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @State private var showWhatsNew = false
    @State private var showHelpSheet = false
    @State private var showPrivacyPolicy = false
    @State private var showCleanErrors = false
    @State private var showRestoreResult = false
    @State private var restoreMessage = ""
    @AppStorage("showIntroVideo") private var showIntroVideo = true
    @State private var introPlayed = _introPlayedThisSession

    private var sidebarPane: some View {
        VStack(spacing: 0) {
            sidebarContent
        }
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("mainSidebar")
    }

    @ViewBuilder
    private var detailPane: some View {
        Group {
            switch selectedSidebar {
            case .dashboard:
                DashboardView(
                    manager: manager,
                    showCleanAlert: $showCleanAlert,
                    selectedSidebar: $selectedSidebar,
                    showExportSheet: $showExportSheet,
                    exportVerbose: $exportVerbose,
                    introPlayed: $introPlayed,
                    showIntroVideo: showIntroVideo,
                    onExport: { verbose in generateAndShowReport(verbose: verbose) }
                )
            case .group(let group):
                CategoryGroupDetailView(
                    manager: manager,
                    group: group,
                    showCleanAlert: $showCleanAlert
                )
            case .uninstaller:
                UninstallerView()
            case .duplicateFinder:
                DuplicateFinderView()
            case .maintenance:
                MaintenanceView()
            case .startupManager:
                StartupManagerView()
            case .timeMachine:
                TimeMachineView()
            case .diskMap:
                DiskMapView()
            case .storageInsights:
                StorageInsightsView {
                    selectedSidebar = .group(.applications)
                    guard !manager.isScanning else { return }
                    Task { await manager.scan(onlyGroup: .applications) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generateAndShowReport(verbose: Bool) {
        exportVerbose = verbose
        isGeneratingReport = true
        exportReport = ""
        showExportSheet = true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = manager.exportDetailedReport(verbose: verbose)
            DispatchQueue.main.async {
                exportReport = report
                isGeneratingReport = false
            }
        }
    }

    var body: some View {
        HSplitView {
            if layoutDirection == .rightToLeft {
                detailPane
                sidebarPane
            } else {
                sidebarPane
                detailPane
            }
        }
        // Clean confirmation with safety breakdown
        .sheet(isPresented: $showCleanAlert) {
            CleanConfirmationSheet(manager: manager, isPresented: $showCleanAlert) {
                attemptToQuitAssociatedApps in
                Task {
                    await manager.clean(
                        attemptToQuitAssociatedApps: attemptToQuitAssociatedApps
                    )
                    manager.fetchDiskUsage()
                    showCleanComplete = true
                }
            }
        }
        // Clean complete
        .alert(
            manager.lastMovedToTrashSize > 0 &&
                manager.lastPermanentlyDeletedSize == 0
                ? String(localized: "Moved to Trash")
                : String(localized: "Cleanup Complete"),
            isPresented: $showCleanComplete
        ) {
            if !manager.cleanErrors.isEmpty {
                Button("Show Errors") { showCleanErrors = true }
            }
            if manager.canRestoreLastCleanup {
                Button("Restore Cleanup") {
                    Task {
                        guard let outcome = await manager.restoreLastCleanup() else { return }
                        restoreMessage = String(localized: "Restored \(outcome.restored) item(s).")
                        if outcome.skippedExisting > 0 {
                            restoreMessage += String(localized: " \(outcome.skippedExisting) conflict(s) remain available to retry.")
                        }
                        if outcome.missingInTrash > 0 {
                            restoreMessage += String(localized: " \(outcome.missingInTrash) item(s) were no longer in Trash.")
                        }
                        if outcome.failed > 0 {
                            restoreMessage += String(localized: " \(outcome.failed) item(s) failed validation or could not be restored.")
                        }
                        showRestoreResult = true
                        manager.fetchDiskUsage()
                    }
                }
            }
            if manager.lastMovedToTrashSize > 0 {
                Button("Open Trash") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
                    )
                }
            }
            Button("OK") {}
        } message: {
            let errorNote = manager.cleanErrors.isEmpty
                ? ""
                : String(localized: "\n\n\(manager.cleanErrors.count) cleanup issue(s) were reported.")
            let trashNote = manager.lastMovedToTrashSize > 0
                ? String(localized: "\n\n\(CleanupManager.formatBytes(manager.lastMovedToTrashSize)) was moved to Trash and is still using disk space. Empty Trash to reclaim that space, or restore the cleanup before emptying it.")
                : ""
            let permanentNote = manager.lastPermanentlyDeletedSize > 0
                ? String(localized: "\n\n\(CleanupManager.formatBytes(manager.lastPermanentlyDeletedSize)) was permanently removed.")
                : ""
            Text(
                String(localized: "Processed \(CleanupManager.formatBytes(manager.lastCleanedSize)) across \(manager.lastCleanedCount) categories (\(manager.cleanSuccessCount) succeeded, \(manager.cleanFailCount) had errors).\(trashNote)\(permanentNote)\(errorNote)")
            )
        }
        // Clean errors detail
        .alert("Clean Errors", isPresented: $showCleanErrors) {
            Button("OK") {}
        } message: {
            let remaining = manager.cleanErrors.count - 10
            Text(
                manager.cleanErrors.prefix(10).joined(separator: "\n")
                    + (remaining > 0 ? String(localized: "\n...and \(remaining) more") : "")
            )
        }
        // Restore result
        .alert("Restore Last Cleanup", isPresented: $showRestoreResult) {
            Button("OK") {}
        } message: {
            Text(restoreMessage)
        }
        .sheet(isPresented: $showExportSheet) {
            ExportReportView(report: $exportReport, isGenerating: $isGeneratingReport)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                showOnboarding = false
            }
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView()
        }
        .sheet(isPresented: $showHelpSheet) {
            HelpView()
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .frame(minWidth: 800, minHeight: 550)
        .onAppear {
            manager.fetchDiskUsage()
            checkWhatsNew()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startScan)) { _ in
            if !manager.isScanning {
                Task { await manager.scan() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAll)) { _ in
            manager.selectAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deselectAll)) { _ in
            manager.deselectAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectSafeOnly)) { _ in
            manager.selectSafeOnly()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportReport)) { _ in
            if manager.scanComplete {
                generateAndShowReport(verbose: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreLastCleanup)) { _ in
            Task {
                guard let outcome = await manager.restoreLastCleanup() else {
                    restoreMessage = String(localized: "There is no recent cleanup to restore.")
                    showRestoreResult = true
                    return
                }
                var parts = [String(localized: "Restored \(outcome.restored) item(s) from the Trash.")]
                if outcome.skippedExisting > 0 {
                    parts.append(String(localized: "\(outcome.skippedExisting) skipped (a file already exists at the original location)."))
                }
                if outcome.missingInTrash > 0 {
                    parts.append(String(localized: "\(outcome.missingInTrash) no longer in the Trash."))
                }
                if outcome.failed > 0 {
                    parts.append(String(localized: "\(outcome.failed) could not be restored."))
                }
                restoreMessage = parts.joined(separator: "\n")
                showRestoreResult = true
                manager.fetchDiskUsage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
            showHelpSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPrivacyPolicy)) { _ in
            showPrivacyPolicy = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
            showWhatsNew = true
        }
    }

    private func checkWhatsNew() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let lastSeen = UserDefaults.standard.string(forKey: "lastSeenVersion") ?? ""
        if lastSeen != currentVersion && !showOnboarding {
            showWhatsNew = true
            UserDefaults.standard.set(currentVersion, forKey: "lastSeenVersion")
        }
    }

    // MARK: Sidebar Content

    @ViewBuilder
    private var sidebarContent: some View {
        List {
            Section {
                SidebarRow(
                    label: String(localized: "Dashboard"),
                    icon: "gauge.with.dots.needle.33percent",
                    iconColor: .accentColor,
                    isSelected: selectedSidebar == .dashboard
                ) {
                    selectedSidebar = .dashboard
                }
            }

            Section("Categories") {
                ForEach(CategoryGroup.allCases) { group in
                    let cats = manager.categoriesForGroup(group)
                    let hasResults = !cats.isEmpty
                    let selectedCats = cats.filter(\.isSelected)
                    let selectedSize = selectedCats.reduce(0) { $0 + $1.selectedSize }
                    let sizeText = hasResults ? CleanupManager.formatBytes(selectedSize) : "—"
                    SidebarRow(
                        label: group.displayName,
                        icon: group.icon,
                        iconColor: hasResults ? group.color : .gray,
                        trailing: sizeText,
                        badgeCount: hasResults ? selectedCats.count : nil,
                        isSelected: selectedSidebar == .group(group)
                    ) {
                        selectedSidebar = .group(group)
                    }
                    .opacity(hasResults ? 1.0 : 0.5)
                }
            }

            Section("Tools") {
                SidebarRow(
                    label: String(localized: "Uninstaller"),
                    icon: "trash.square",
                    iconColor: .red,
                    isSelected: selectedSidebar == .uninstaller
                ) {
                    selectedSidebar = .uninstaller
                }

                SidebarRow(
                    label: String(localized: "Duplicate Finder"),
                    icon: "doc.on.doc",
                    iconColor: .teal,
                    isSelected: selectedSidebar == .duplicateFinder
                ) {
                    selectedSidebar = .duplicateFinder
                }

                SidebarRow(
                    label: String(localized: "Maintenance"),
                    icon: "wrench.and.screwdriver",
                    iconColor: .orange,
                    isSelected: selectedSidebar == .maintenance
                ) {
                    selectedSidebar = .maintenance
                }

                SidebarRow(
                    label: String(localized: "Startup Items"),
                    icon: "bolt.circle",
                    iconColor: .yellow,
                    isSelected: selectedSidebar == .startupManager
                ) {
                    selectedSidebar = .startupManager
                }

                SidebarRow(
                    label: String(localized: "Time Machine"),
                    icon: "clock.arrow.2.circlepath",
                    iconColor: .purple,
                    isSelected: selectedSidebar == .timeMachine
                ) {
                    selectedSidebar = .timeMachine
                }

                SidebarRow(
                    label: String(localized: "Disk Map"),
                    icon: "internaldrive.fill",
                    iconColor: .indigo,
                    isSelected: selectedSidebar == .diskMap
                ) {
                    selectedSidebar = .diskMap
                }

                SidebarRow(
                    label: String(localized: "Storage Insights"),
                    icon: "chart.bar.doc.horizontal",
                    iconColor: .teal,
                    isSelected: selectedSidebar == .storageInsights
                ) {
                    selectedSidebar = .storageInsights
                }
            }
        }
        .listStyle(.sidebar)

        // Scan progress
        if manager.isScanning {
            VStack(spacing: 6) {
                ProgressView(value: manager.scanProgress)
                    .progressViewStyle(.linear)
                Text(manager.currentScanItem)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }

        // Clean progress
        if manager.isCleaning {
            VStack(spacing: 6) {
                ProgressView(value: manager.cleanProgress)
                    .progressViewStyle(.linear)
                    .tint(.red)
                Text("Cleaning...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }

        // Partial scan banner
        if let summary = manager.lastScanSummary, summary.wasPartial {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Partial scan")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }

        // FDA banner
        if !manager.hasFullDiskAccess && manager.scanComplete {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Limited Access")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
                Text("Some scans need Full Disk Access to find all files.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Grant Access") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2), lineWidth: 1))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Dashboard View

struct DashboardView: View {
    let manager: CleanupManager
    @Binding var showCleanAlert: Bool
    @Binding var selectedSidebar: SidebarItem
    @Binding var showExportSheet: Bool
    @Binding var exportVerbose: Bool
    @Binding var introPlayed: Bool
    var showIntroVideo: Bool
    var onExport: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar (same pattern as Uninstaller / Duplicate Finder)
            headerSection

            Divider()

            // Content
            if manager.scanComplete {
                ScrollView {
                    VStack(spacing: 20) {
                        if let disk = manager.diskUsage {
                            DiskUsageCardView(disk: disk, reclaimable: manager.overallSize)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }

                        storageScopeNotice

                        if manager.categories.contains(where: { $0.safetyLevel == .safe && $0.isSelected }) {
                            smartRecommendation
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        summaryStatsGrid
                        topCategoriesSection
                        groupOverviewSection
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .transition(.opacity)
            } else if manager.isScanning {
                scanningSection
                    .transition(.opacity)
            } else {
                welcomeSection
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: manager.scanComplete)
        .animation(.easeInOut(duration: 0.3), value: manager.isScanning)
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("SparkClean")
                    .font(.title3)
                    .fontWeight(.bold)
                if manager.scanComplete {
                    Text("\(manager.categories.count) categories · \(CleanupManager.formatBytes(manager.overallSize)) reclaimable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Mac cleanup & storage optimizer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if manager.isScanning {
                Button("Cancel") { manager.cancelScan() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            }

            if manager.scanComplete {
                Button {
                    manager.pendingCleanGroup = nil
                    showCleanAlert = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                        Text(manager.isCleaning ? String(localized: "Cleaning...") : String(localized: "Clean"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(manager.isScanning || manager.isCleaning || !manager.hasSelectedContent)
            }

            Button {
                Task { await manager.scan() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: manager.isScanning ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        manager.isScanning
                            ? String(localized: "Scanning...")
                            : (manager.scanComplete ? String(localized: "Rescan") : String(localized: "Scan"))
                    )
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isScanning || manager.isCleaning)

            if manager.scanComplete {
                Menu {
                    Button("Select Safe Only") { manager.selectSafeOnly() }
                    Button("Select All") { manager.selectAll() }
                    Button("Deselect All") { manager.deselectAll() }
                    Divider()
                    Button("Export Summary Report...") { onExport(false) }
                    Button("Export Detailed Audit Report...") { onExport(true) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var sizeGradient: LinearGradient {
        if manager.overallSize > 5_000_000_000 {
            return LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
        } else if manager.overallSize > 1_000_000_000 {
            return LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: Smart Recommendation

    private var storageScopeNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.teal)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cleanup results are not your whole disk")
                    .font(.system(size: 13, weight: .semibold))
                Text("Personal files and app data can use far more space. Disk Map accounts for the whole APFS container, including protected and system-managed space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Review Storage") {
                selectedSidebar = .diskMap
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.teal.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.teal.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var smartRecommendation: some View {
        let safeCats = manager.categories.filter { $0.safetyLevel == .safe && $0.isSelected }
        let safeSize = safeCats.reduce(0 as Int64) { $0 + $1.selectedSize }
        return HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Clean Available")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(safeCats.count) rebuildable cache/log categories can free \(CleanupManager.formatBytes(safeSize)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Select Safe Only") {
                manager.selectSafeOnly()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.yellow.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.yellow.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: Summary Stats

    private var summaryStatsGrid: some View {
        HStack(spacing: 14) {
            StatCard(title: String(localized: "Categories"), value: "\(manager.categories.count)", icon: "folder", color: .blue)
            StatCard(title: String(localized: "Selected"), value: CleanupManager.formatBytes(manager.totalSize), icon: "checkmark.circle", color: .green)
            StatCard(title: String(localized: "Files"), value: formatNumber(manager.categories.reduce(0) { $0 + $1.fileCount }), icon: "doc", color: .orange)
            if let summary = manager.lastScanSummary {
                StatCard(
                    title: summary.wasPartial ? String(localized: "Partial Scan") : String(localized: "Scan Time"),
                    value: String(
                        localized: "\(summary.scanDuration.formatted(.number.precision(.fractionLength(1)))) seconds"
                    ),
                    icon: summary.wasPartial ? "exclamationmark.clock" : "clock",
                    color: summary.wasPartial ? .orange : .purple
                )
            }
        }
    }

    // MARK: Top Categories

    private var topCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Largest Categories")
                .font(.headline)

            let topCats = manager.categories.sorted { $0.size > $1.size }.prefix(5)
            ForEach(Array(topCats)) { category in
                TopCategoryRow(category: category, maxSize: topCats.first?.size ?? 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    // MARK: Group Overview

    private var groupOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By Category")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 12) {
                ForEach(CategoryGroup.allCases) { group in
                    let cats = manager.categoriesForGroup(group)
                    GroupCard(group: group, categories: cats) {
                        selectedSidebar = .group(group)
                    }
                }
            }
        }
    }

    // MARK: Scanning

    private var scanningSection: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: manager.scanProgress) {
                Text("Scanning your Mac...")
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

            if !manager.categories.isEmpty {
                Text("Found \(manager.categories.count) categories (\(CleanupManager.formatBytes(manager.overallSize)) so far)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Welcome

    private var welcomeSection: some View {
        Group {
            if introPlayed || !showIntroVideo {
                readyToScanSection
            } else {
                SplashScreenView {
                    withAnimation(.easeOut(duration: 0.4)) {
                        introPlayed = true
                        _introPlayedThisSession = true
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyToScanSection: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.blue.opacity(0.15), .clear],
                            center: .center,
                            startRadius: 30,
                            endRadius: 120
                        )
                    )
                    .frame(width: 220, height: 220)

                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 10) {
                Text("Ready to Scan")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Click **Scan** to deep-scan your Mac for caches, temp files,\norphaned app data, Docker resources, unused apps, and more.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let disk = manager.diskUsage {
                HStack(spacing: 20) {
                    DiskMiniStat(label: String(localized: "Total"), value: CleanupManager.formatBytes(disk.totalSpace))
                    DiskMiniStat(label: String(localized: "Used"), value: CleanupManager.formatBytes(disk.usedSpace))
                    DiskMiniStat(label: String(localized: "Free"), value: CleanupManager.formatBytes(disk.freeSpace))
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                )
            }

            Spacer()
        }
    }

    private func formatNumber(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName))
    }
}

// MARK: - Clean Confirmation Sheet

struct CleanConfirmationSheet: View {
    let manager: CleanupManager
    @Binding var isPresented: Bool
    let onConfirm: (Bool) -> Void
    @AppStorage("preferTrash") private var preferTrash = true

    private var selectedCategories: [CleanupCategory] {
        manager.categories.filter {
            $0.isSelected && $0.hasSelectedContent &&
                (manager.pendingCleanGroup == nil || $0.group == manager.pendingCleanGroup)
        }
    }

    private var safeCount: Int { selectedCategories.filter { $0.safetyLevel == .safe }.count }
    private var reviewCount: Int { selectedCategories.filter { $0.safetyLevel == .review }.count }
    private var cautionCount: Int { selectedCategories.filter { $0.safetyLevel == .caution }.count }
    private var selectedSize: Int64 {
        selectedCategories.reduce(0) { $0 + $1.selectedSize }
    }
    private var selectedFiles: Int {
        selectedCategories.reduce(0) { $0 + $1.selectedFileCount }
    }
    private var trashItems: [CleanupCategory] {
        selectedCategories.filter { !isPermanent($0) }
    }
    private var permanentItems: [CleanupCategory] {
        selectedCategories.filter { isPermanent($0) }
    }
    private var runningAssociatedApps: [String] {
        let bundleIDs = Set(selectedCategories.flatMap(\.associatedBundleIDs))
        return Set(NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier,
                  bundleIDs.contains(bundleID) else { return nil }
            return app.localizedName ?? bundleID
        }).sorted()
    }
    private var categoriesWithWarnings: [CleanupCategory] {
        selectedCategories.filter { $0.cleanupWarning?.isEmpty == false }
    }
    private func isPermanent(_ category: CleanupCategory) -> Bool {
        category.isDockerResource || category.isOllamaResource ||
            category.requiresPermanentDeletion ||
            (!preferTrash && category.safetyLevel != .caution)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)

                Text("Confirm Cleanup")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Summary
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !preferTrash {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                            Text("Permanent-delete mode is enabled. Safe and Review file categories will be deleted immediately and cannot be restored. Caution categories still go to Trash.")
                                .font(.callout)
                                .fontWeight(.semibold)
                                .foregroundStyle(.red)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)))
                    }

                    if !runningAssociatedApps.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "app.badge.checkmark")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Close applications before cleanup")
                                    .font(.callout)
                                    .fontWeight(.semibold)
                                Text("\(runningAssociatedApps.joined(separator: ", ")) currently owns selected cache or privacy data. Quit Apps & Clean waits up to five seconds; anything still running is skipped.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.08))
                        )
                    }

                    ForEach(categoriesWithWarnings) { category in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(category.name) changes app data")
                                    .font(.callout)
                                    .fontWeight(.semibold)
                                Text(category.cleanupWarning ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red.opacity(0.08))
                        )
                    }

                    // Overview
                    HStack(spacing: 20) {
                        summaryCard(String(localized: "Total Size"), value: CleanupManager.formatBytes(selectedSize), color: .blue)
                        summaryCard(String(localized: "Categories"), value: "\(selectedCategories.count)", color: .purple)
                        summaryCard(String(localized: "Items"), value: "\(selectedFiles)", color: .orange)
                    }
                    .padding(.top, 12)

                    // Safety breakdown
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Safety Breakdown")
                            .font(.headline)

                        if safeCount > 0 {
                            safetyRow(level: .safe, count: safeCount)
                        }
                        if reviewCount > 0 {
                            safetyRow(level: .review, count: reviewCount)
                        }
                        if cautionCount > 0 {
                            safetyRow(level: .caution, count: cautionCount)
                        }
                    }

                    if !trashItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                Text("Moved to Trash")
                                    .font(.headline)
                                Text("(recoverable)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(trashItems) { cat in
                                categoryRow(for: cat)
                            }
                        }
                    }

                    if !permanentItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                Text("Permanently Deleted")
                                    .font(.headline)
                                Text("(cannot be undone)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            ForEach(permanentItems) { cat in
                                categoryRow(for: cat, permanent: true)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.red.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
                                )
                        )
                    }

                    // Recovery note
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "trash")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recovery")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Items listed under Moved to Trash are recorded for Restore Last Cleanup. Items listed under Permanently Deleted cannot be restored by SparkClean.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.06)))

                    // Disclaimer
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Disclaimer")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("By proceeding, you acknowledge that SparkClean is provided \"as is\" without warranty of any kind. The developer assumes no liability for any data loss, system instability, or damages resulting from the use of this application. You are solely responsible for reviewing the items selected for removal and ensuring they are not required by your system or applications. It is strongly recommended to maintain up-to-date backups before performing any cleanup operations.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.06)))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 380)

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    manager.pendingCleanGroup = nil
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer()

                if !runningAssociatedApps.isEmpty {
                    Button("Skip Running Apps") {
                        isPresented = false
                        onConfirm(false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        isPresented = false
                        onConfirm(true)
                    } label: {
                        Label(
                            "Quit Apps & Clean",
                            systemImage: "power"
                        )
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                } else {
                    Button {
                        isPresented = false
                        onConfirm(false)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: permanentItems.isEmpty ? "trash" : "exclamationmark.triangle.fill")
                            Text(
                                permanentItems.isEmpty
                                    ? String(localized: "Move to Trash — \(CleanupManager.formatBytes(selectedSize))")
                                    : String(localized: "Clean Selected — \(CleanupManager.formatBytes(selectedSize))")
                            )
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }
            }
            .padding(20)
        }
        .frame(width: 560)
    }

    private func categoryRow(for cat: CleanupCategory, permanent: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cat.safetyLevel.icon)
                .font(.caption)
                .foregroundStyle(cat.safetyLevel.color)
                .frame(width: 16)

            Image(systemName: cat.icon)
                .font(.caption)
                .foregroundStyle(cat.color)
                .frame(width: 16)

            Text(cat.name)
                .font(.callout)

            if permanent {
                Text(
                    cat.isDockerResource
                        ? String(localized: "via Docker CLI")
                        : (cat.isOllamaResource
                            ? String(localized: "via Ollama CLI")
                            : (cat.requiresPermanentDeletion
                                ? String(localized: "empty Trash")
                                : String(localized: "direct delete")))
                )
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.1)))
            }

            Spacer()

            Text("\(cat.selectedFileCount) items")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(CleanupManager.formatBytes(cat.selectedSize))
                .font(.callout)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(permanent ? Color.red.opacity(0.06) : Color.primary.opacity(0.03))
        )
    }

    private func summaryCard(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }

    private func safetyRow(level: SafetyLevel, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: level.icon)
                .foregroundStyle(level.color)
                .frame(width: 18)
            Text(level.label)
                .font(.callout)
            Spacer()
            Text(count == 1 ? String(localized: "1 category") : String(localized: "\(count) categories"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    let onComplete: () -> Void
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            if currentStep == 0 {
                welcomeStep
            } else {
                permissionsStep
            }
        }
        .frame(width: 520, height: 620)
    }

    // MARK: Step 1 - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("Welcome to SparkClean")
                .font(.title)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 14) {
                featureRow(icon: "magnifyingglass", color: .blue,
                    title: String(localized: "Deep Scan"),
                    desc: String(localized: "Finds caches, temp files, build artifacts, browser data, and more."))

                featureRow(icon: "checkmark.shield.fill", color: .green,
                    title: String(localized: "Safety Levels"),
                    desc: String(localized: "Every item is labeled Safe, Review, or Caution so you know what's risk-free."))

                featureRow(icon: "trash", color: .orange,
                    title: String(localized: "Trash First"),
                    desc: String(localized: "Files are moved to Trash by default — you can always recover them."))

                featureRow(icon: "app.badge.checkmark", color: .purple,
                    title: String(localized: "App Uninstaller"),
                    desc: String(localized: "Completely remove apps and all their hidden data with one click."))

                featureRow(icon: "doc.on.doc", color: .teal,
                    title: String(localized: "Duplicate Finder"),
                    desc: String(localized: "Find and remove duplicate files wasting disk space."))
            }
            .padding(.horizontal, 20)

            Spacer()

            Button {
                withAnimation { currentStep = 1 }
            } label: {
                HStack(spacing: 6) {
                    Text("Next: Set Up Permissions")
                    Image(systemName: "arrow.forward")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer().frame(height: 16)
        }
        .padding(32)
    }

    // MARK: Step 2 - Permissions

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("Grant Permissions")
                .font(.title2)
                .fontWeight(.bold)

            Text("SparkClean needs access to scan and clean your Mac.\nGrant these permissions for the best experience.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                permissionCard(
                    icon: "lock.open.fill",
                    color: .orange,
                    title: String(localized: "Full Disk Access"),
                    desc: String(localized: "Required to scan Mail, Messages, system caches, and all directories."),
                    importance: String(localized: "Required"),
                    importanceColor: .red,
                    urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                )

                permissionCard(
                    icon: "folder.fill",
                    color: .blue,
                    title: String(localized: "Files & Folders"),
                    desc: String(localized: "Access Downloads, Documents, Desktop, and removable volumes."),
                    importance: String(localized: "Recommended"),
                    importanceColor: .blue,
                    urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
                )

                permissionCard(
                    icon: "gearshape.fill",
                    color: .gray,
                    title: String(localized: "Automation"),
                    desc: String(localized: "Allows Docker cleanup commands and Finder integration."),
                    importance: String(localized: "Optional"),
                    importanceColor: .gray,
                    urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
            }
            .padding(.horizontal, 16)

            Text("You can always change these later in System Settings > Privacy & Security.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { currentStep = 0 }
                }
                .buttonStyle(.bordered)

                Button("Get Started") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer().frame(height: 12)
        }
        .padding(28)
    }

    private func permissionCard(
        icon: String,
        color: Color,
        title: String,
        desc: String,
        importance: String,
        importanceColor: Color,
        urlString: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(importance)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(importanceColor.opacity(0.15))
                        )
                        .foregroundStyle(importanceColor)
                }
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Open") {
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Open \(title) settings"))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.15), lineWidth: 1))
        )
    }

    private func featureRow(
        icon: String,
        color: Color,
        title: String,
        desc: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - What's New View

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    private let releases: [ReleaseNote] = [
        ReleaseNote(version: "1.4.0", date: "July 2026", notes: [
            "New Disk Map — accounts for the whole startup volume instead of showing cleanup results as total disk usage",
            "New Storage Insights — read-only sizes and trends for chat apps, Photos, Mail, iOS backups, simulators, and VMs",
            "New Time Machine section — review and delete APFS local snapshots, with the newest kept as a restore point",
            "WhatsApp storage — see the full media footprint and clear it explicitly, without touching your message database",
            "Restore Last Cleanup (⇧⌘Z) now covers cleanup, uninstall, duplicates, and Trash Monitor",
            "Every deletion path now goes through one shared safety policy with delete-time re-validation",
            "APFS clones are no longer counted twice, so reported sizes match real reclaimable space",
            "Per-category Scan button, plus new Next.js, Rust, Electron, installer, and dev-tool cache scans",
            "Optional menu bar icon with Open, Scan Now, and Open Trash quick actions",
            "Many accuracy fixes: cleanup results, Docker prune reporting, duplicate detection, and maintenance tasks",
        ]),
        ReleaseNote(version: "1.3.0", date: "April 2026", notes: [
            "New Privacy category — scan and clean Recent Items, Spotlight History, Shell History, Safari/Chrome/Firefox browsing data, and cookies",
            "Admin privilege escalation — clean root-owned files, uninstall system apps (e.g., Microsoft Office), and Trash Monitor cleanup",
            "Maintenance: Clear Time Machine Snapshots and Free APFS Purgeable Space tasks with size estimates",
            "Maintenance: Task selection with checkboxes, Run Selected button, and confirmation dialog",
            "Animated stat counters, disk bar transitions, hover effects, and section transitions",
            "Show in Finder icon in Uninstaller app detail header",
            "Fixed pipe deadlock when CLI command output exceeds 64KB",
            "Fixed DuplicateFinder memory leak and added scan cancellation support",
            "Fixed disk usage bar visual gap between segments",
        ]),
        ReleaseNote(version: "1.2.1", date: "April 2026", notes: [
            "Check for Updates — verify your version from Settings > About or Support menu",
            "Optional auto-update check on launch (Settings > Startup, off by default)",
            "Download latest DMG directly from GitHub when an update is available",
            "Contact and bug report links now open GitHub issues instead of email",
            "Fixed intro video replaying on every minimize/restore",
            "Privacy policy updated to reflect optional update check",
        ]),
        ReleaseNote(version: "1.2.0", date: "April 2026", notes: [
            "New Maintenance view — run system maintenance tasks like flushing DNS, purging memory, and rebuilding indexes",
            "New Startup Manager — view and manage Launch Agents, System Agents, and Daemons",
            "Smart Trash Monitor — detects apps moved to Trash and offers to clean leftover files",
            "Drag-and-drop .app files onto Uninstaller for instant analysis",
            "Per-path selection checkboxes in Uninstaller — choose exactly which related data to remove",
            "Launch Agent discovery in Uninstaller related data scanning",
            "Low-confidence items (App Support, Containers) now default to unselected for safety",
            "TrashMonitor thread safety improvements with OSAllocatedUnfairLock",
        ]),
        ReleaseNote(version: "1.1.0", date: "March 2026", notes: [
            "Fixed critical memory leak that could cause 34GB+ RAM usage and crashes",
            "Added memory pressure monitoring — scans auto-cancel under critical pressure",
            "Protected path blocklist prevents deletion of system and user directories",
            "Deletion audit log written to ~/Library/Logs/SparkClean/",
            "Fixed Docker double-counting — sizes now reported accurately via CLI",
            "Old Downloads now checks actual file dates inside folders",
            "10 new categories: HuggingFace, Ollama, LM Studio, Bazel, Deno, Poetry, and more",
            "Trash failure no longer silently falls back to permanent deletion",
            "Duplicate Finder uses 150x less memory for image hashing",
        ]),
        ReleaseNote(version: "1.0.0", date: "March 2026", notes: [
            "Deep scan for caches, temp files, logs, and crash reports",
            "Browser cache cleanup (Safari, Chrome, Firefox, Arc, Edge, Brave)",
            "Developer tools cleanup (Xcode, Android, Gradle)",
            "Package manager cache cleanup (npm, pip, Homebrew, CocoaPods, and more)",
            "Docker resource scanning and cleanup",
            "App Uninstaller with related data detection",
            "Safety levels (Safe, Review, Caution) for every category",
            "Detailed export reports",
            "Configurable scan thresholds",
        ]),
    ]

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("What's New")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(releases) { release in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("v\(release.version)")
                                    .font(.headline)
                                Text(release.date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(release.notes, id: \.self) { note in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(note)
                                        .font(.body)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 420)
    }
}

// MARK: - Help View

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("SparkClean Help")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    helpSection(
                        String(localized: "Getting Started"),
                        AttributedString(localized: "Click **Scan** to analyze your Mac. SparkClean will find caches, reviewable stale temporary files, build artifacts, and other reclaimable space.")
                    )

                    helpSection(
                        String(localized: "Safety Levels"),
                        AttributedString(localized: "**Safe** (green): Low-risk caches, logs, and generated files expected to rebuild.\n**Review** (orange): User files like old downloads or stale temp files. Check before deleting.\n**Caution** (red): App data or Docker resources. Could affect running apps.")
                    )

                    helpSection(
                        String(localized: "Cleaning"),
                        AttributedString(localized: "Select categories you want to clean, then click **Clean**. Files are moved to Trash by default so you can recover them if needed.")
                    )

                    helpSection(
                        String(localized: "App Uninstaller"),
                        AttributedString(localized: "The Uninstaller finds all installed apps and their hidden data (caches, preferences, containers). Remove everything with one click.")
                    )

                    helpSection(
                        String(localized: "Keyboard Shortcuts"),
                        AttributedString(localized: "**Cmd+R** — Scan\n**Cmd+E** — Export Report\n**Cmd+Shift+A** — Select All\n**Cmd+Shift+D** — Deselect All\n**Cmd+Shift+S** — Select Safe Only")
                    )

                    helpSection(
                        String(localized: "Contact"),
                        AttributedString(localized: "Report issues or get help at:\ngithub.com/georgekhananaev/spark-clean/issues")
                    )
                }
            }
        }
        .padding(24)
        .frame(width: 500, height: 480)
    }

    private func helpSection(_ title: String, _ body: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Privacy Policy View

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Privacy Policy")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Last updated: July 2026")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    policySection(
                        String(localized: "Data Collection"),
                        String(localized: "SparkClean does not send personal data, file paths, or scan results to George Khananaev or any SparkClean service. Scanning and cleanup happen on your device.")
                    )

                    policySection(
                        String(localized: "Network Access"),
                        String(localized: "SparkClean works offline by default. Optional update checks contact GitHub to compare versions. If you choose Download Update, the selected GitHub release is downloaded to a location you approve. No analytics, telemetry, or tracking requests are sent.")
                    )

                    policySection(
                        String(localized: "File Access"),
                        String(localized: "SparkClean reads file metadata (including paths, sizes, and dates) to identify reviewable space. It only removes categories or items you select and confirm. Files move to Trash by default; the confirmation sheet identifies command-based and permanent exceptions.")
                    )

                    policySection(
                        String(localized: "Local Records"),
                        String(localized: "Settings, Storage Insights size history, the latest scan audit, Restore Last Cleanup manifests, and deletion audit logs are stored only on this Mac. Scan, undo, and audit records can contain local file paths. They are kept under ~/Library/Application Support/SparkClean and ~/Library/Logs/SparkClean, are never uploaded, and can be removed by deleting those folders.")
                    )

                    policySection(
                        String(localized: "Third-Party Services"),
                        String(localized: "GitHub is used only for optional release checks and user-requested downloads. SparkClean does not integrate with advertising networks or analytics platforms.")
                    )

                    policySection(
                        String(localized: "Contact"),
                        String(localized: "For questions about this privacy policy, visit github.com/georgekhananaev/spark-clean/issues")
                    )
                }
            }
        }
        .padding(24)
        .frame(width: 500, height: 440)
    }

    private func policySection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 650)
}

#Preview("Hebrew RTL") {
    ContentView()
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
        .frame(width: 900, height: 650)
}
