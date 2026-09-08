//
//  MaintenanceView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/30/26.
//

import SwiftUI

// MARK: - Maintenance Task Model

struct MaintenanceTask: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String
    let iconColor: Color
    let requiresAdmin: Bool
    let warning: String?
    let command: () -> (Bool, String)
    var estimate: String? = nil

    init(
        name: String.LocalizationValue,
        description: String.LocalizationValue,
        icon: String,
        iconColor: Color,
        requiresAdmin: Bool,
        warning: String.LocalizationValue?,
        command: @escaping () -> (Bool, String)
    ) {
        self.name = String(localized: name)
        self.description = String(localized: description)
        self.icon = icon
        self.iconColor = iconColor
        self.requiresAdmin = requiresAdmin
        self.warning = warning.map { String(localized: $0) }
        self.command = command
    }

    enum Status: Equatable {
        case idle
        case running
        case success(String)
        case failed(String)
    }
}

// MARK: - Maintenance Manager

@Observable
class MaintenanceManager {
    var tasks: [(task: MaintenanceTask, status: MaintenanceTask.Status, isSelected: Bool)] = []
    var isRunningAll = false
    var containerDisk: String?

    init() {
        setupTasks()
        determineAPFSContainer()
    }

    func determineAPFSContainer() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var diskID: String?

            // Get container disk identifier
            if let output = CleanupManager.runCommand("/usr/sbin/diskutil", arguments: ["info", "/"]) {
                for line in output.components(separatedBy: "\n") {
                    if line.contains("Part of Whole:") {
                        let parts = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
                        if parts.range(
                            of: #"^disk[0-9]+$"#,
                            options: .regularExpression
                        ) != nil {
                            diskID = parts
                        }
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.containerDisk = diskID
            }
        }
    }

    private func setupTasks() {
        tasks = [
            // No root required
            (task: MaintenanceTask(
                name: "Flush DNS Cache",
                description: "Clears stale DNS lookups — fixes website access issues",
                icon: "network", iconColor: .blue, requiresAdmin: false, warning: nil,
                command: {
                    let r1 = CleanupManager.runCommand("/usr/bin/dscacheutil", arguments: ["-flushcache"])
                    guard let r1 else {
                        return (false, String(localized: "Could not flush the DNS cache"))
                    }
                    return (true, r1.isEmpty ? String(localized: "DNS cache flushed") : r1)
                }
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Reset QuickLook Cache",
                description: "Rebuilds file preview thumbnails — fixes broken previews",
                icon: "eye.square", iconColor: .purple, requiresAdmin: false, warning: nil,
                command: {
                    let r = CleanupManager.runCommand("/usr/bin/qlmanage", arguments: ["-r", "cache"])
                    return (r != nil, r ?? String(localized: "QuickLook cache reset"))
                }
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Compact Launch Services",
                description: "Cleans up \"Open With\" menu — removes stale/duplicate entries",
                icon: "arrow.up.doc", iconColor: .orange, requiresAdmin: false, warning: nil,
                command: {
                    let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                    guard CleanupManager.runCommand(lsregister, arguments: ["-gc"]) != nil else {
                        return (false, String(localized: "Could not compact Launch Services"))
                    }
                    let restarted = CleanupManager.runCommand(
                        "/usr/bin/killall",
                        arguments: ["Finder"]
                    ) != nil
                    return (
                        restarted,
                        restarted
                            ? String(localized: "Launch Services compacted, Finder restarted")
                            : String(localized: "Launch Services compacted, but Finder could not be restarted")
                    )
                }
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Clear Font Cache",
                description: "Rebuilds font rendering cache — fixes garbled text (requires re-login)",
                icon: "textformat", iconColor: .pink, requiresAdmin: false,
                warning: "You may need to log out and back in for fonts to reload.",
                command: {
                    let r = CleanupManager.runCommand("/usr/bin/atsutil", arguments: ["databases", "-removeUser"])
                    return (r != nil, r ?? String(localized: "User font cache cleared"))
                }
            ), status: .idle, isSelected: false),

            // Requires admin
            (task: MaintenanceTask(
                name: "Full DNS Resolver Restart",
                description: "Restarts the mDNSResponder service — complete DNS reset",
                icon: "network.badge.shield.half.filled", iconColor: .green, requiresAdmin: true, warning: nil,
                command: {
                    let script = "do shell script \"/usr/bin/killall -HUP mDNSResponder\" with administrator privileges"
                    var error: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&error)
                    if let error {
                        return (false, error["NSAppleScriptErrorMessage"] as? String ?? String(localized: "Failed"))
                    }
                    return (true, String(localized: "mDNSResponder restarted"))
                }
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Rebuild Spotlight Index",
                description: "Re-indexes your entire drive — fixes broken Spotlight search",
                icon: "magnifyingglass", iconColor: .blue, requiresAdmin: true,
                warning: "This takes 30 minutes to 2 hours. Your Mac will use extra CPU during reindexing.",
                command: {
                    let script = "do shell script \"/usr/bin/mdutil -E /\" with administrator privileges"
                    var error: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&error)
                    if let error {
                        return (false, error["NSAppleScriptErrorMessage"] as? String ?? String(localized: "Failed"))
                    }
                    return (true, String(localized: "Spotlight reindex started — will complete in the background"))
                }
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Enable APFS Defragmentation",
                description: "Lets macOS compact fragmented APFS files in the background",
                icon: "externaldrive.badge.minus", iconColor: .cyan, requiresAdmin: true,
                warning: "This changes an APFS container setting. It does not guarantee immediate free space.",
                command: { [weak self] in
                    guard let diskID = self?.containerDisk else {
                        return (false, String(localized: "Could not safely determine the APFS container identifier."))
                    }

                    // Check current status first
                    let status = CleanupManager.runCommand("/usr/sbin/diskutil", arguments: ["apfs", "defragment", diskID, "status"])
                    let normalizedStatus = status?.lowercased() ?? ""
                    let explicitlyDisabled = normalizedStatus.contains("not enabled") ||
                        normalizedStatus.contains("disabled")
                    let alreadyEnabled = !explicitlyDisabled &&
                        normalizedStatus.range(
                            of: #"\benabled\b"#,
                            options: .regularExpression
                        ) != nil

                    if alreadyEnabled {
                        return (true, String(localized: "APFS defragmentation is already enabled and running in the background"))
                    }

                    let script = "do shell script \"/usr/sbin/diskutil apfs defragment \(diskID) enable\" with administrator privileges"
                    var error: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&error)
                    if let error {
                        return (false, error["NSAppleScriptErrorMessage"] as? String ?? String(localized: "Failed — admin password required"))
                    }
                    return (true, String(localized: "APFS defragmentation enabled — macOS will compact eligible files in the background"))
                }
            ), status: .idle, isSelected: false),
        ]
    }

    func runTask(at index: Int) {
        guard index < tasks.count else { return }
        tasks[index].status = .running
        let command = tasks[index].task.command

        // Run on background thread for non-blocking tasks,
        // but NSAppleScript must run on main thread for admin tasks
        if tasks[index].task.requiresAdmin {
            Task { @MainActor [weak self] in
                let (success, message) = command()
                self?.tasks[index].status = success ? .success(message) : .failed(message)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let (success, message) = command()
                DispatchQueue.main.async {
                    self?.tasks[index].status = success ? .success(message) : .failed(message)
                }
            }
        }
    }

    var selectedCount: Int {
        tasks.filter(\.isSelected).count
    }

    func runSelected() {
        isRunningAll = true
        let selectedIndices = tasks.indices.filter { tasks[$0].isSelected }

        // Split into non-admin (run on background) and admin (run on main)
        let nonAdmin = selectedIndices.filter { !tasks[$0].task.requiresAdmin }
        let admin = selectedIndices.filter { tasks[$0].task.requiresAdmin }

        Task { [weak self] in
            // Run non-admin tasks on background thread
            if !nonAdmin.isEmpty {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        for i in nonAdmin {
                            guard let self else { break }
                            let command = self.tasks[i].task.command
                            DispatchQueue.main.async { self.tasks[i].status = .running }
                            let (success, message) = command()
                            DispatchQueue.main.async {
                                self.tasks[i].status = success ? .success(message) : .failed(message)
                            }
                        }
                        continuation.resume()
                    }
                }
            }

            // Run admin tasks on main thread (NSAppleScript requirement)
            for i in admin {
                guard let self else { break }
                await MainActor.run { self.tasks[i].status = .running }
                let command = self.tasks[i].task.command
                let (success, message) = await MainActor.run { command() }
                await MainActor.run {
                    self.tasks[i].status = success ? .success(message) : .failed(message)
                }
            }

            await MainActor.run { self?.isRunningAll = false }
        }
    }

    func resetAll() {
        for i in tasks.indices {
            tasks[i].status = .idle
            tasks[i].isSelected = false
        }
    }
}

// MARK: - Maintenance View

struct MaintenanceView: View {
    @State private var manager = MaintenanceManager()
    @State private var showRunConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            AdaptiveHeader {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Maintenance")
                        .font(.title2.bold())
                    Text("Select tasks to run, then click Run Selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } actions: {
                if manager.tasks.contains(where: { $0.status != .idle }) {
                    Button("Reset") {
                        manager.resetAll()
                    }
                    .disabled(manager.isRunningAll)
                }

                Button {
                    showRunConfirmation = true
                } label: {
                    ToolbarActionLabel(title: String(localized: "Run Selected"), systemImage: "play.fill")
                }
                .platformPrimaryActionStyle(tint: .blue)
                .controlSize(.regular)
                .disabled(manager.selectedCount == 0 || manager.isRunningAll)
            }
            .padding()
            .platformHeaderSurface()

            Divider()

            // Task List
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    // No-admin section
                    Section {
                        ForEach(Array(manager.tasks.enumerated()), id: \.element.task.id) { index, item in
                            if !item.task.requiresAdmin {
                                MaintenanceTaskRow(
                                    task: item.task,
                                    status: item.status,
                                    isSelected: $manager.tasks[index].isSelected,
                                    isRunning: manager.isRunningAll
                                )
                            }
                        }
                    } header: {
                        sectionHeader(
                            String(localized: "Quick Actions"),
                            subtitle: String(localized: "No admin password required")
                        )
                    }

                    Section {
                        ForEach(Array(manager.tasks.enumerated()), id: \.element.task.id) { index, item in
                            if item.task.requiresAdmin {
                                MaintenanceTaskRow(
                                    task: item.task,
                                    status: item.status,
                                    isSelected: $manager.tasks[index].isSelected,
                                    isRunning: manager.isRunningAll
                                )
                            }
                        }
                    } header: {
                        sectionHeader(
                            String(localized: "Admin Actions"),
                            subtitle: String(localized: "Requires your password")
                        )
                    }

                }
                .padding()
            }
        }
        .alert("Run Maintenance Tasks?", isPresented: $showRunConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(
                manager.selectedCount == 1
                    ? String(localized: "Run 1 Task")
                    : String(localized: "Run \(manager.selectedCount) Tasks"),
                role: .destructive
            ) {
                manager.runSelected()
            }
        } message: {
            let selected = manager.tasks.filter(\.isSelected)
            let names = selected.map(\.task.name).joined(separator: ", ")
            let hasAdmin = selected.contains(where: \.task.requiresAdmin)
            let adminNote = hasAdmin
                ? String(localized: "\n\nSome tasks require your admin password.")
                : ""
            Text(names + adminNote)
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Task Row

struct MaintenanceTaskRow: View {
    let task: MaintenanceTask
    let status: MaintenanceTask.Status
    @Binding var isSelected: Bool
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox for selection (hide during/after run)
            if status == .idle {
                Toggle("", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(isRunning)
            }

            Image(systemName: task.icon)
                .font(.title3)
                .foregroundStyle(task.iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .font(.body.weight(.medium))
                    if task.requiresAdmin {
                        Image(systemName: "lock.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let estimate = task.estimate {
                        Text(estimate)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(task.iconColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(task.iconColor.opacity(0.12)))
                    }
                }
                Text(task.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = task.warning {
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                // Status message
                switch status {
                case .success(let msg):
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.green)
                case .failed(let msg):
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }

            Spacer()

            // Status indicator
            switch status {
            case .idle:
                EmptyView()
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}
