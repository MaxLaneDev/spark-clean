//
//  SettingsView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Update Checker

@Observable
final class UpdateChecker {
    var isChecking = false
    var isDownloading = false
    var downloadProgress: Double = 0
    var latestVersion: String?
    var downloadURL: URL?
    var errorMessage: String?
    var checkCompleted = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return compareVersions(latest, isGreaterThan: currentVersion)
    }

    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    func check() async {
        await MainActor.run {
            isChecking = true
            errorMessage = nil
            checkCompleted = false
            latestVersion = nil
            downloadURL = nil
        }

        do {
            let url = URL(string: "https://api.github.com/repos/georgekhananaev/spark-clean/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard version.range(
                of: #"^[0-9]+(?:\.[0-9]+){1,3}$"#,
                options: .regularExpression
            ) != nil,
            let dmgAsset = release.assets.first(where: {
                let name = $0.name.lowercased()
                return name.hasPrefix("sparkclean") &&
                    name.hasSuffix(".dmg") &&
                    $0.size > 0
            }),
            let validatedURL = Self.validatedGitHubDownloadURL(
                dmgAsset.browserDownloadURL
            ) else {
                throw URLError(.badServerResponse)
            }

            await MainActor.run {
                latestVersion = version
                downloadURL = validatedURL
                isChecking = false
                checkCompleted = true
            }
        } catch {
            await MainActor.run {
                errorMessage = String(localized: "Could not verify the latest GitHub release. Check your connection and try again.")
                isChecking = false
                checkCompleted = true
            }
        }
    }

    func downloadUpdate() {
        guard let url = downloadURL, let version = latestVersion else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SparkClean-\(version).dmg"
        panel.allowedContentTypes = [.diskImage]

        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        isDownloading = true
        downloadProgress = 0

        let task = URLSession.shared.downloadTask(with: url) {
            [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                self?.isDownloading = false

                guard let tempURL,
                      error == nil,
                      let response = response as? HTTPURLResponse,
                      response.statusCode == 200,
                      Self.isAllowedGitHubAssetURL(response.url),
                      Self.isValidUDIFDiskImage(at: tempURL)
                else {
                    self?.errorMessage = String(localized: "Download failed. Please try again.")
                    return
                }

                do {
                    let fm = FileManager.default
                    let stagingURL = saveURL.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".\(saveURL.lastPathComponent).\(UUID().uuidString).download"
                        )
                    defer { try? fm.removeItem(at: stagingURL) }
                    try fm.copyItem(at: tempURL, to: stagingURL)
                    if FileManager.default.fileExists(atPath: saveURL.path) {
                        _ = try fm.replaceItemAt(
                            saveURL,
                            withItemAt: stagingURL
                        )
                    } else {
                        try fm.moveItem(at: stagingURL, to: saveURL)
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([saveURL])
                } catch {
                    self?.errorMessage = String(localized: "Could not save the file.")
                }
            }
        }

        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        downloadTask = task
        task.resume()
    }

    private static func validatedGitHubDownloadURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else {
            return nil
        }
        return url
    }

    private static func isAllowedGitHubAssetURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "github.com" ||
            host == "release-assets.githubusercontent.com" ||
            host == "objects.githubusercontent.com"
    }

    /// UDIF disk images end with a 512-byte resource fork trailer beginning `koly`.
    /// This rejects HTML/error payloads that happen to arrive with HTTP 200.
    private static func isValidUDIFDiskImage(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        do {
            let length = try handle.seekToEnd()
            guard length >= 512 else { return false }
            try handle.seek(toOffset: length - 512)
            return try handle.read(upToCount: 4) == Data("koly".utf8)
        } catch {
            return false
        }
    }

    private func compareVersions(_ a: String, isGreaterThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(aParts.count, bParts.count) {
            let aVal = i < aParts.count ? aParts[i] : 0
            let bVal = i < bParts.count ? bParts[i] : 0
            if aVal > bVal { return true }
            if aVal < bVal { return false }
        }
        return false
    }
}

private struct GitHubRelease: Codable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Codable {
    let name: String
    let browserDownloadURL: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

struct SettingsView: View {
    @AppStorage("scanNodeModules") private var scanNodeModules = true
    @AppStorage("scanDocker") private var scanDocker = true
    @AppStorage("scanUnusedApps") private var scanUnusedApps = true
    @AppStorage("unusedAppThresholdDays") private var unusedAppThresholdDays = 90
    @AppStorage("largeFileThresholdMB") private var largeFileThresholdMB = 50
    @AppStorage("oldFileThresholdDays") private var oldFileThresholdDays = 30
    @AppStorage("screenshotThresholdDays") private var screenshotThresholdDays = 30
    @AppStorage("preferTrash") private var preferTrash = true
    @AppStorage("scanLargeFiles") private var scanLargeFiles = true
    @AppStorage("scanVirtualEnvironments") private var scanVirtualEnvironments = true
    @AppStorage("scanRustTargets") private var scanRustTargets = true
    @AppStorage("scanOldInstallers") private var scanOldInstallers = true
    @AppStorage("screenRecordingThresholdDays") private var screenRecordingThresholdDays = 60
    @AppStorage("scanIOSBackups") private var scanIOSBackups = true
    @AppStorage("scanIMessageAttachments") private var scanIMessageAttachments = true
    @AppStorage("scanBrokenSymlinks") private var scanBrokenSymlinks = true
    @AppStorage("scanScreenRecordings") private var scanScreenRecordings = true
    @AppStorage("showIntroVideo") private var showIntroVideo = true
    @AppStorage("trashMonitorEnabled") private var trashMonitorEnabled = false
    @AppStorage("checkUpdatesOnLaunch") private var checkUpdatesOnLaunch = false
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = false
    @State private var selectedLanguage = AppLocalization.selectedLanguage
    @State private var languageChangeNeedsRestart = false
    @State private var languageSaveFailed = false

    // Large Files settings
    @AppStorage("largeFileScanDownloads") private var largeFileScanDownloads = true
    @AppStorage("largeFileScanDesktop") private var largeFileScanDesktop = true
    @AppStorage("largeFileScanDocuments") private var largeFileScanDocuments = true
    @AppStorage("largeFileScanMovies") private var largeFileScanMovies = true
    @AppStorage("largeFileScanMusic") private var largeFileScanMusic = true
    @AppStorage("largeFileScanPictures") private var largeFileScanPictures = true
    @AppStorage("largeFileIncludeVideos") private var largeFileIncludeVideos = true
    @AppStorage("largeFileIncludeImages") private var largeFileIncludeImages = true
    @AppStorage("largeFileIncludeArchives") private var largeFileIncludeArchives = true
    @AppStorage("largeFileIncludeInstallers") private var largeFileIncludeInstallers = true
    @AppStorage("largeFileIncludeAudio") private var largeFileIncludeAudio = true
    @AppStorage("largeFileIncludeOther") private var largeFileIncludeOther = true
    @AppStorage("largeFileMaxAgeDays") private var largeFileMaxAgeDays = 0
    @AppStorage("largeFileMaxResults") private var largeFileMaxResults = 100

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            scanTab
                .tabItem {
                    Label("Scanning", systemImage: "magnifyingglass")
                }

            largeFilesTab
                .tabItem {
                    Label("Large Files", systemImage: "doc.fill")
                }

            cleanupTab
                .tabItem {
                    Label("Cleanup", systemImage: "trash")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 560)
        .alert("Language Change Failed", isPresented: $languageSaveFailed) {
            Button("OK") {}
        } message: {
            Text("SparkClean could not save your language preference.")
        }
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section {
                HStack {
                    Label("App Language", systemImage: "globe")

                    Spacer()

                    Picker("App Language", selection: $selectedLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .onChange(of: selectedLanguage) { oldValue, newValue in
                        guard oldValue != newValue else { return }
                        if AppLocalization.selectLanguage(newValue) {
                            languageChangeNeedsRestart = true
                        } else {
                            // Persisting the preference failed — resync the picker with
                            // what's actually saved so it never shows a language that a
                            // restart would not actually apply.
                            selectedLanguage = AppLocalization.selectedLanguage
                            languageSaveFailed = true
                        }
                    }
                }

                if languageChangeNeedsRestart {
                    HStack {
                        Spacer()
                        Button("Restart SparkClean") {
                            AppLocalization.restartApplication()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("System Default follows your Mac language. Changes take effect after restarting SparkClean.")
            }

            Section("Startup") {
                Toggle("Show intro video on launch", isOn: $showIntroVideo)
                Toggle("Check for updates on launch", isOn: $checkUpdatesOnLaunch)
                Toggle("Show menu bar icon", isOn: $showMenuBarExtra)
            }

            Section {
                Toggle("Monitor Trash for uninstalled apps", isOn: $trashMonitorEnabled)
            } header: {
                Text("Smart Cleanup")
            } footer: {
                Text("When enabled, SparkClean detects apps moved to Trash and offers to clean leftover files. Uses zero CPU when idle.")
            }

            Section("Core Scans") {
                Toggle("Scan node_modules directories", isOn: $scanNodeModules)
                Toggle("Scan Rust target directories", isOn: $scanRustTargets)
                Toggle("Scan Docker resources", isOn: $scanDocker)
                Toggle("Detect unused applications", isOn: $scanUnusedApps)
            }

            Section {
                Toggle("Scan for large files", isOn: $scanLargeFiles)
                Toggle("Scan virtual environments", isOn: $scanVirtualEnvironments)
            } header: {
                Text("Storage Analysis")
            } footer: {
                Text("Duplicate files can be found using the Duplicate Finder tool.")
            }

            Section("System & Media") {
                Toggle("Scan iOS backups", isOn: $scanIOSBackups)
                Toggle("Scan iMessage attachments", isOn: $scanIMessageAttachments)
                Toggle("Scan broken symlinks", isOn: $scanBrokenSymlinks)
                Toggle("Scan screen recordings", isOn: $scanScreenRecordings)
                Toggle("Scan old installer files", isOn: $scanOldInstallers)
            }

        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Scanning

    private var scanTab: some View {
        Form {
            Section("Thresholds") {
                HStack {
                    Text("Unused app threshold")
                    Spacer()
                    Picker("", selection: $unusedAppThresholdDays) {
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                        Text("180 days").tag(180)
                        Text("365 days").tag(365)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Old file threshold")
                    Spacer()
                    Picker("", selection: $oldFileThresholdDays) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Old screenshot threshold")
                    Spacer()
                    Picker("", selection: $screenshotThresholdDays) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Screen recording threshold")
                    Spacer()
                    Picker("", selection: $screenRecordingThresholdDays) {
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .frame(width: 120)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Large Files

    private var largeFilesTab: some View {
        Form {
            Section {
                HStack {
                    Text("Minimum file size")
                    Spacer()
                    Picker("", selection: $largeFileThresholdMB) {
                        Text("10 MB").tag(10)
                        Text("25 MB").tag(25)
                        Text("50 MB").tag(50)
                        Text("100 MB").tag(100)
                        Text("250 MB").tag(250)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1000)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Maximum results")
                    Spacer()
                    Picker("", selection: $largeFileMaxResults) {
                        Text("25").tag(25)
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("200").tag(200)
                        Text("500").tag(500)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Only files older than")
                    Spacer()
                    Picker("", selection: $largeFileMaxAgeDays) {
                        Text("Any age").tag(0)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                        Text("180 days").tag(180)
                        Text("365 days").tag(365)
                    }
                    .frame(width: 120)
                }
            } header: {
                Text("Size & Filters")
            } footer: {
                Text("\"Only files older than\" filters by last access date — recently used files are excluded.")
            }

            Section("Scan Locations") {
                Toggle("Downloads", isOn: $largeFileScanDownloads)
                Toggle("Desktop", isOn: $largeFileScanDesktop)
                Toggle("Documents", isOn: $largeFileScanDocuments)
                Toggle("Movies", isOn: $largeFileScanMovies)
                Toggle("Music", isOn: $largeFileScanMusic)
                Toggle("Pictures", isOn: $largeFileScanPictures)
            }

            Section {
                Toggle("Videos (mp4, mov, avi, mkv, wmv, m4v, webm, flv)", isOn: $largeFileIncludeVideos)
                Toggle("Images (raw, cr2, nef, arw, dng, tiff, psd, ai)", isOn: $largeFileIncludeImages)
                Toggle("Archives (zip, tar, gz, 7z, rar, bz2, xz, tgz)", isOn: $largeFileIncludeArchives)
                Toggle("Installers (dmg, pkg, iso)", isOn: $largeFileIncludeInstallers)
                Toggle("Audio (wav, flac, aiff, alac, mp3, m4a, ogg)", isOn: $largeFileIncludeAudio)
                Toggle("Other / Unknown file types", isOn: $largeFileIncludeOther)
            } header: {
                Text("File Types to Include")
            } footer: {
                Text("Disable file types you want to keep. Only enabled types will appear in scan results.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Cleanup

    private var cleanupTab: some View {
        Form {
            Section {
                Toggle("Move files to Trash instead of deleting permanently", isOn: $preferTrash)
            } header: {
                Text("Deletion Behavior")
            } footer: {
                Text("When enabled, files are moved to Trash and can be restored. Trash failures are reported and may request administrator access; SparkClean never silently falls back to permanent deletion. Caution items always go to Trash.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: About

    @State private var updateChecker = UpdateChecker()

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("SparkClean")
                .font(.title2)
                .fontWeight(.bold)

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Mac Storage & Cache Cleaner.\nScans caches, temp files, Docker resources,\ndev tools, browsers, and more.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Update checker
            updateCheckerView

            HStack(spacing: 16) {
                Link("Contact Support", destination: URL(string: "https://github.com/georgekhananaev/spark-clean/issues")!)
                    .font(.caption)

                Text("·").foregroundStyle(.tertiary)

                Link("Report a Bug", destination: URL(string: "https://github.com/georgekhananaev/spark-clean/issues")!)
                    .font(.caption)
            }

            Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("Copyright \u{00A9} 2026 George Khananaev. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var updateCheckerView: some View {
        if updateChecker.isChecking {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if updateChecker.isDownloading {
            VStack(spacing: 6) {
                ProgressView(value: updateChecker.downloadProgress)
                    .frame(width: 200)
                Text("Downloading... \(Int(updateChecker.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if updateChecker.checkCompleted {
            if let error = updateChecker.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if updateChecker.updateAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                    Text("v\(updateChecker.latestVersion!) available")
                        .font(.callout)
                        .fontWeight(.medium)
                    Button("Download") {
                        updateChecker.downloadUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("You're up to date! (v\(updateChecker.latestVersion ?? updateChecker.currentVersion))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Button("Check for Updates") {
                Task { await updateChecker.check() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

#Preview {
    SettingsView()
}
