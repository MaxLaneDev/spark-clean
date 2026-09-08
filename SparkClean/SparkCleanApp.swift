//
//  SparkCleanApp.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AppKit

final class ScanActivityTracker: @unchecked Sendable {
    static let shared = ScanActivityTracker()
    private let lock = NSLock()
    private var activeCount = 0

    var isActive: Bool { lock.withLock { activeCount > 0 } }

    func update(from oldValue: Bool, to newValue: Bool) {
        guard oldValue != newValue else { return }
        lock.withLock { activeCount = max(0, activeCount + (newValue ? 1 : -1)) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ScanActivityTracker.shared.isActive else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Stop scanning?")
        alert.informativeText = String(localized: "A scan is still running. Stop it and quit SparkClean?")
        alert.addButton(withTitle: String(localized: "Stop Scanning and Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct SparkCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var showCustomAbout = false
    @State private var trashMonitor = TrashMonitor()
    @State private var updateChecker = UpdateChecker()
    @State private var showUpdateSheet = false
    @AppStorage("trashMonitorEnabled") private var trashMonitorEnabled = false
    @AppStorage("checkUpdatesOnLaunch") private var checkUpdatesOnLaunch = false
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = false

    var body: some Scene {
        WindowGroup {
            RootWindowView(
                trashMonitor: trashMonitor,
                updateChecker: updateChecker,
                showCustomAbout: $showCustomAbout,
                showUpdateSheet: $showUpdateSheet
            )
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 680)
        .windowResizability(.contentSize)
        .commands {
            // Replace the default About menu item
            CommandGroup(replacing: .appInfo) {
                Button("About SparkClean") {
                    showCustomAbout = true
                }
            }

            // File menu
            CommandGroup(after: .newItem) {
                Button("Scan Now") {
                    NotificationCenter.default.post(name: .startScan, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Export Report...") {
                    NotificationCenter.default.post(name: .exportReport, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button("Restore Last Cleanup") {
                    NotificationCenter.default.post(name: .restoreLastCleanup, object: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            // Selection menu
            CommandMenu("Selection") {
                Button("Select All") {
                    NotificationCenter.default.post(name: .selectAll, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Deselect All") {
                    NotificationCenter.default.post(name: .deselectAll, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Select Safe Only") {
                    NotificationCenter.default.post(name: .selectSafeOnly, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // Help menu — use a custom menu to avoid macOS intercepting the help system
            CommandMenu("Support") {
                Button("SparkClean Help") {
                    NotificationCenter.default.post(name: .showHelp, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command])

                Divider()

                Button("Contact Support") {
                    if let url = URL(string: "https://github.com/georgekhananaev/spark-clean/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Report a Bug") {
                    if let url = URL(string: "https://github.com/georgekhananaev/spark-clean/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("GitHub Repository") {
                    if let url = URL(string: "https://github.com/georgekhananaev/spark-clean") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()

                Button("Privacy Policy") {
                    NotificationCenter.default.post(name: .showPrivacyPolicy, object: nil)
                }

                Button("What's New") {
                    NotificationCenter.default.post(name: .showWhatsNew, object: nil)
                }

                Divider()

                Button("Check for Updates...") {
                    showUpdateSheet = true
                    Task { await updateChecker.check() }
                }
            }

            // Remove the default Help menu to avoid "Help isn't available" message
            CommandGroup(replacing: .help) { }
        }

        Settings {
            SettingsView()
        }

        // Optional menu bar presence (F12) — off by default.
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent()
        } label: {
            Image(systemName: "sparkles")
        }
    }
}

// MARK: - Root Window (extracted to keep the App scene body simple)

struct RootWindowView: View {
    @Bindable var trashMonitor: TrashMonitor
    @Bindable var updateChecker: UpdateChecker
    @Binding var showCustomAbout: Bool
    @Binding var showUpdateSheet: Bool
    @AppStorage("trashMonitorEnabled") private var trashMonitorEnabled = false
    @AppStorage("checkUpdatesOnLaunch") private var checkUpdatesOnLaunch = false

    var body: some View {
        ContentView()
            .environment(trashMonitor)
            .frame(minWidth: 800, minHeight: 550)
            .background(WindowTransparencyConfigurator())
            .sheet(isPresented: $showCustomAbout) {
                CustomAboutView()
            }
            .onAppear {
                if trashMonitorEnabled {
                    trashMonitor.isEnabled = true
                }
                if checkUpdatesOnLaunch {
                    Task {
                        await updateChecker.check()
                        if updateChecker.updateAvailable {
                            showUpdateSheet = true
                        }
                    }
                }
            }
            .onChange(of: trashMonitorEnabled) { _, newValue in
                trashMonitor.isEnabled = newValue
            }
            .sheet(item: $trashMonitor.lastDetectedApp) { detected in
                TrashLeftoverSheet(detected: detected, trashMonitor: trashMonitor)
            }
            .sheet(isPresented: $showUpdateSheet) {
                UpdateCheckSheet(updateChecker: updateChecker)
            }
    }
}

private struct WindowTransparencyConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window, closeTarget: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window, closeTarget: context.coordinator) }
    }

    private func configure(_ window: NSWindow?, closeTarget: Coordinator) {
        window?.styleMask.insert(.fullSizeContentView)
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.titlebarSeparatorStyle = .none
        window?.standardWindowButton(.closeButton)?.target = closeTarget
        window?.standardWindowButton(.closeButton)?.action = #selector(Coordinator.quitApplication(_:))
    }

    final class Coordinator: NSObject {
        @objc func quitApplication(_ sender: NSButton) {
            NSApp.terminate(sender)
        }
    }
}

// MARK: - Menu Bar Content (F12)

struct MenuBarContent: View {
    var body: some View {
        Button("Open SparkClean") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        Button("Scan Now") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .startScan, object: nil)
        }
        Divider()
        Button("Open Trash") {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
        }
        Divider()
        Button("Quit SparkClean") { NSApp.terminate(nil) }
    }
}

// MARK: - Custom About View

struct CustomAboutView: View {
    @Environment(\.dismiss) private var dismiss
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var systemInfo: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let arch = {
            #if arch(arm64)
            return "Apple Silicon (arm64)"
            #elseif arch(x86_64)
            return "Intel (x86_64)"
            #else
            return String(localized: "Unknown")
            #endif
        }()
        let ram = ProcessInfo.processInfo.physicalMemory
        let ramGB = String(format: "%.0f", Double(ram) / 1_073_741_824)
        let system = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) \(arch)"
        let memory = String(localized: "Memory: \(ramGB) GB")
        let processors = String(localized: "Processors: \(ProcessInfo.processInfo.activeProcessorCount) cores")
        return [system, memory, processors].joined(separator: "\n")
    }

    private var buildInfo: String {
        String(localized: "Build #SC-\(buildNumber), \(version)")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient background
            ZStack {
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.15),
                        Color.purple.opacity(0.1),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .blue.opacity(0.3), radius: 10)

                    Text("SparkClean")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text("Version \(version)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Mac Storage & Cache Cleaner")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 20)
                .padding(.bottom, 16)
            }
            .frame(height: 180)

            Divider()

            // System info section
            VStack(alignment: .leading, spacing: 12) {
                InfoSection(title: String(localized: "Build Information"), content: buildInfo)

                InfoSection(title: String(localized: "Developer"), content: "George Khananaev")

                HStack(spacing: 4) {
                    Text("SOURCE CODE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                    Spacer()
                }
                Link("github.com/georgekhananaev/spark-clean", destination: URL(string: "https://github.com/georgekhananaev/spark-clean")!)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.blue)

                InfoSection(title: String(localized: "Runtime"), content: systemInfo)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Footer
            HStack {
                Button {
                    let info = """
                    SparkClean \(version)
                    \(buildInfo)

                    \(systemInfo)
                    """
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("Copy Info")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("Copyright \u{00A9} 2026 George Khananaev")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 420)
    }
}

struct InfoSection: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

extension Notification.Name {
    static let startScan = Notification.Name("startScan")
    static let selectAll = Notification.Name("selectAll")
    static let deselectAll = Notification.Name("deselectAll")
    static let selectSafeOnly = Notification.Name("selectSafeOnly")
    static let exportReport = Notification.Name("exportReport")
    static let restoreLastCleanup = Notification.Name("restoreLastCleanup")
    static let showHelp = Notification.Name("showHelp")
    static let showPrivacyPolicy = Notification.Name("showPrivacyPolicy")
    static let showWhatsNew = Notification.Name("showWhatsNew")
}

// MARK: - Trash Leftover Cleanup Sheet

struct TrashLeftoverSheet: View {
    let detected: TrashMonitor.DetectedTrashedApp
    let trashMonitor: TrashMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var isCleaning = false
    @State private var cleaned = false
    @State private var cleanupError: String?
    @State private var selectedPaths = Set<String>()
    @State private var completedPaths = Set<String>()
    @State private var initializedSelection = false

    private var visibleLeftovers: [TrashMonitor.LeftoverItem] {
        detected.leftovers.filter { !completedPaths.contains($0.path) }
    }

    private var selectedSize: Int64 {
        visibleLeftovers
            .filter { selectedPaths.contains($0.path) }
            .reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "trash.slash")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Leftover Files Detected")
                    .font(.title3.bold())
                Spacer()
                Button("Dismiss") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("**\(detected.appName)** was moved to Trash but left **\(detected.formattedSize)** of data behind:")
                    .font(.body)

                IndicatorlessScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleLeftovers, id: \.path) { item in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { selectedPaths.contains(item.path) },
                                    set: { selected in
                                        if selected {
                                            selectedPaths.insert(item.path)
                                        } else {
                                            selectedPaths.remove(item.path)
                                        }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()

                                Text(AppLocalization.relatedPathCategory(item.category))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, alignment: .leading)
                                Text((item.path as NSString).lastPathComponent)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .technicalTextDirection()
                                Spacer()
                                Text(CleanupManager.formatBytes(item.size))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Text("\(CleanupManager.formatBytes(selectedSize)) selected · moved to Trash (recoverable).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                if cleaned {
                    Label("Selected leftovers cleaned", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    if let cleanupError {
                        Text(cleanupError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if isCleaning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(cleanupError == nil ? String(localized: "Clean Leftovers") : String(localized: "Retry Remaining")) {
                        cleanLeftovers()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCleaning || selectedPaths.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 500, height: 350)
        .onAppear {
            guard !initializedSelection else { return }
            // User-data locations need an explicit opt-in; generated cache/log state
            // is selected by default.
            let generatedCategories: Set<String> = [
                "Caches", "Logs", "Saved State", "HTTP Storage", "WebKit Data",
            ]
            selectedPaths = Set(detected.leftovers.compactMap {
                generatedCategories.contains($0.category) ? $0.path : nil
            })
            initializedSelection = true
        }
    }

    private func cleanLeftovers() {
        isCleaning = true
        cleanupError = nil
        let pathsToClean = selectedPaths
        let itemsToClean = detected.leftovers.filter {
            pathsToClean.contains($0.path)
        }
        let appName = detected.appName
        DispatchQueue.global(qos: .userInitiated).async {
            let remover = FileRemover(policy: CleanupManager.deletionPolicy, useTrash: true)
            let recorder = CleanupSessionRecorder(
                appVersion: CleanupManager.appVersionString,
                trashMode: true,
                store: CleanupManager.manifestStore
            )
            var failures: [String] = []
            var needsAdmin: [FileRemover.AdminRequest] = []
            var completed = Set<String>()
            let category = "Trash Monitor: \(appName)"

            for item in itemsToClean {
                switch remover.remove(
                    item.path,
                    allowedRoots: [item.path],
                    knownSize: item.size,
                    expectedIsDirectory: item.isDirectory,
                    expectedIdentity: item.fileIdentity
                ) {
                case .removed(let removal):
                    completed.insert(removal.originalPath)
                    recorder.record(removal, category: category)
                    DeletionAuditLogger.shared.record(
                        [removal],
                        category: category,
                        sessionID: recorder.sessionID,
                        appVersion: CleanupManager.appVersionString,
                        trashMode: true
                    )
                case .needsAdmin(let path):
                    needsAdmin.append(FileRemover.AdminRequest(
                        path: path,
                        allowedRoots: [item.path],
                        knownSize: item.size,
                        expectedIsDirectory: item.isDirectory,
                        expectedIdentity: item.fileIdentity
                    ))
                case .blocked(let reason):
                    let itemName = AppLocalization.isolateTechnicalText(
                        (item.path as NSString).lastPathComponent
                    )
                    failures.append(String(localized: "\(itemName): \(reason)"))
                case .skippedICloud:
                    let itemName = AppLocalization.isolateTechnicalText(
                        (item.path as NSString).lastPathComponent
                    )
                    failures.append(String(localized: "\(itemName): iCloud item protected"))
                case .failed(let error):
                    if error == FileRemover.itemNoLongerExistsError {
                        completed.insert(item.path)
                    } else {
                        let itemName = AppLocalization.isolateTechnicalText(
                            (item.path as NSString).lastPathComponent
                        )
                        failures.append(String(localized: "\(itemName): \(error)"))
                    }
                }
            }

            if !needsAdmin.isEmpty {
                let admin = remover.moveToTrashWithAdministratorPrivileges(
                    needsAdmin,
                    confirmationTitle: String(localized: "\(appName) Leftovers Need Administrator Access")
                )
                for removal in admin.removals {
                    completed.insert(removal.originalPath)
                    recorder.record(removal, category: category)
                    DeletionAuditLogger.shared.record(
                        [removal],
                        category: category,
                        sessionID: recorder.sessionID,
                        appVersion: CleanupManager.appVersionString,
                        trashMode: true
                    )
                }
                failures.append(contentsOf: admin.failures)
                if admin.wasCancelled {
                    failures.append(String(localized: "Administrator cleanup was cancelled"))
                }
            }
            recorder.finish()

            let completedSnapshot = completed
            let failureCount = failures.count
            DispatchQueue.main.async {
                completedPaths.formUnion(completedSnapshot)
                selectedPaths.subtract(completedSnapshot)
                cleaned = failureCount == 0
                cleanupError = failureCount == 0
                    ? nil
                    : String(localized: "\(failureCount) item(s) could not be removed.")
                isCleaning = false
            }
        }
    }
}

// MARK: - Update Check Sheet (from menu)

struct UpdateCheckSheet: View {
    @Bindable var updateChecker: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Software Update")
                    .font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if updateChecker.isChecking {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Checking for updates...")
                        .foregroundStyle(.secondary)
                }
            } else if updateChecker.isDownloading {
                VStack(spacing: 12) {
                    ProgressView(value: updateChecker.downloadProgress)
                        .frame(width: 250)
                    Text("Downloading... \(Int(updateChecker.downloadProgress * 100))%")
                        .foregroundStyle(.secondary)
                }
            } else if updateChecker.checkCompleted {
                if let error = updateChecker.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            Task { await updateChecker.check() }
                        }
                        .buttonStyle(.bordered)
                    }
                } else if updateChecker.updateAvailable {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text("SparkClean v\(updateChecker.latestVersion!) is available")
                            .font(.headline)
                        Text("You're currently on v\(updateChecker.currentVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Download Update") {
                            updateChecker.downloadUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text("You're up to date!")
                            .font(.headline)
                        Text("SparkClean v\(updateChecker.currentVersion) is the latest version")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 380, height: 260)
    }
}
