//
//  Localization.swift
//  SparkClean
//
//  Created by George Khananaev.
//

import SwiftUI
import AppKit
import CoreFoundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"
    case german = "de"
    case hebrew = "he"

    var id: String { rawValue }

    var languageCode: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .japanese: "ja"
        case .german: "de"
        case .hebrew: "he"
        }
    }

    var preferenceValue: [String]? {
        languageCode.map { [$0] }
    }

    static func fromPreference(_ value: Any?) -> AppLanguage {
        let identifier: String?
        if let languages = value as? [String] {
            identifier = languages.first
        } else {
            identifier = value as? String
        }

        guard let identifier else { return .system }
        let baseLanguage = identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map { $0.lowercased() }

        switch baseLanguage {
        case "en": return .english
        case "zh": return .simplifiedChinese
        case "ja": return .japanese
        case "de": return .german
        case "he": return .hebrew
        default: return .system
        }
    }
}

/// Localization metadata used by tests and previews. SwiftUI derives the live
/// layout direction from the selected app language automatically.
enum AppLocalization {
    private static let appleLanguagesKey = "AppleLanguages"

    static let supportedLanguageCodes = AppLanguage.allCases.compactMap(\.languageCode)

    static var selectedLanguage: AppLanguage {
        guard
            let bundleIdentifier = Bundle.main.bundleIdentifier,
            let appPreferences = UserDefaults.standard.persistentDomain(
                forName: bundleIdentifier
            )
        else {
            return .system
        }

        return AppLanguage.fromPreference(appPreferences[appleLanguagesKey])
    }

    /// Saves the same per-app language preference used by macOS Language & Region.
    /// Bundle localization is resolved at process launch, so the app must restart
    /// before every localized runtime string can consistently use the new language.
    @discardableResult
    static func selectLanguage(_ language: AppLanguage) -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let applicationID = bundleIdentifier as CFString
        let preference = language.preferenceValue.map { $0 as CFArray }
        CFPreferencesSetAppValue(
            appleLanguagesKey as CFString,
            preference,
            applicationID
        )
        return CFPreferencesAppSynchronize(applicationID)
    }

    static func restartApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { application, error in
            guard application != nil, error == nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    static func layoutDirection(for languageCode: String) -> LayoutDirection {
        let baseLanguage = languageCode
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map { $0.lowercased() }
        return baseLanguage == "he" ? .rightToLeft : .leftToRight
    }

    /// Keeps paths, commands, bundle identifiers, and similar values ordered
    /// left-to-right when they are embedded in localized right-to-left text.
    static func isolateTechnicalText(_ value: String) -> String {
        "\u{2066}\(value)\u{2069}"
    }

    /// Related-data categories remain stable English identifiers internally because
    /// safety and icon selection depend on them. Only their presentation is localized.
    static func relatedPathCategory(_ category: String) -> String {
        switch category {
        case "Caches": String(localized: "Caches")
        case "App Support": String(localized: "App Support")
        case "Preferences": String(localized: "Preferences")
        case "Container": String(localized: "Container")
        case "Group Container": String(localized: "Group Container")
        case "Saved State": String(localized: "Saved State")
        case "Logs": String(localized: "Logs")
        case "Crash Report": String(localized: "Crash Report")
        case "Crash Reports": String(localized: "Crash Reports")
        case "WebKit Data": String(localized: "WebKit Data")
        case "HTTP Storage": String(localized: "HTTP Storage")
        case "Possible App Data — Cache name match":
            String(localized: "Possible App Data — Cache name match")
        case "Possible App Data — Log name match":
            String(localized: "Possible App Data — Log name match")
        default: category
        }
    }
}

/// File paths, bundle identifiers, commands, and URLs should retain their natural
/// left-to-right order even when the surrounding interface is right-to-left.
extension View {
    func technicalTextDirection() -> some View {
        environment(\.layoutDirection, .leftToRight)
    }
}
