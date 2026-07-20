//
//  DeletionPolicy.swift
//  SparkClean
//
//  Created by George Khananaev.
//
//  Centralised, testable rules deciding whether a filesystem path may be deleted by
//  ANY SparkClean deletion surface (the main clean pipeline, the Uninstaller, the
//  Duplicate Finder). Keeping this in one place — rather than three ad-hoc private
//  checks — is the core of the safety-hardening work: a scan or matching bug can only
//  ever delete a path that passes these rules.
//
//  Pure logic: the only I/O is symlink resolution via `resolvingSymlinksInPath`.
//

import Foundation

struct DeletionPolicy {
    /// Home directory the rules are anchored to. Injectable so tests can validate
    /// against a fixture home without touching the real one.
    let home: String

    /// The Uninstaller legitimately removes whole application bundles (e.g.
    /// `/Applications/Foo.app`), which sit at depth 2 and would otherwise be rejected by
    /// the minimum-depth rule. Enabling this profile permits deleting a *whole* `.app`
    /// bundle (never its interior — that still breaks signatures) while keeping every
    /// other rule intact. Off by default; the generic clean pipeline never sets it.
    let allowsApplicationBundles: Bool

    /// A very small number of categories intentionally target a file directly inside
    /// the current user's home directory (for example `.zsh_history`). The default
    /// policy rejects every `/Users/name/item` target; only an explicitly profiled
    /// category may delete one, and the item must be directly inside `home`.
    let allowsDirectHomeItems: Bool

    /// Broken-symlink cleanup needs to remove the link object at its lexical location,
    /// not authorize the missing target. Parent directory symlinks are still resolved,
    /// and this profile is never enabled for generic cache or user-file cleanup.
    let allowsSymbolicLinkItems: Bool

    /// `/var`, `/etc`, and `/tmp` are symlinks into `/private` on macOS. Reject the
    /// entire resolved namespace except the three temporary territories SparkClean
    /// deliberately scans. Precompute this once because the policy is used per item.
    private let sanctionedPrivateTemporaryRoots: Set<String>
    private let normalizedHome: String

    init(
        home: String = NSHomeDirectory(),
        allowsApplicationBundles: Bool = false,
        allowsDirectHomeItems: Bool = false,
        allowsSymbolicLinkItems: Bool = false
    ) {
        self.home = home
        self.allowsApplicationBundles = allowsApplicationBundles
        self.allowsDirectHomeItems = allowsDirectHomeItems
        self.allowsSymbolicLinkItems = allowsSymbolicLinkItems
        normalizedHome = Self.normalizePath(home)
        sanctionedPrivateTemporaryRoots = Set(
            [NSTemporaryDirectory(), "/private/tmp", "/private/var/tmp"].map {
                Self.normalizePath($0).lowercased()
            }
        )
    }

    /// Absolute paths that must never be deleted — defense-in-depth against scan bugs.
    var protectedPaths: Set<String> {
        let h = home
        return [
            "/", "/System", "/usr", "/bin", "/sbin", "/var", "/etc", "/tmp", "/private",
            "/Applications", "/Library", "/Users", "/Volumes",
            h,
            "\(h)/Desktop", "\(h)/Documents", "\(h)/Downloads",
            "\(h)/Pictures", "\(h)/Movies", "\(h)/Music",
            "\(h)/Library", "\(h)/Library/Keychains",
            "\(h)/Library/Safari",
            "\(h)/Library/Mail", "\(h)/Library/Preferences",
            "\(h)/Library/Application Support",
            "\(h)/Library/Accounts", "\(h)/Library/Cookies",
            "\(h)/Library/Containers", "\(h)/Library/Group Containers",
            "\(h)/.ssh", "\(h)/.gnupg",
        ]
    }

    /// Prefixes that are always off-limits, matched against the resolved path.
    /// Beyond the original system roots, this covers launch-service and extension
    /// directories that are managed elsewhere (StartupManager via launchctl) and must
    /// never be touched by the generic clean pipeline (F9 §6).
    var forbiddenPrefixes: [String] {
        [
            "/System/", "/usr/", "/bin/", "/sbin/", "/Volumes/",
            "/private/var/db/",
            "/Library/LaunchDaemons/", "/Library/LaunchAgents/",
            "/Library/Extensions/", "/Library/StartupItems/",
            "\(home)/Library/LaunchAgents/",
            "\(home)/Library/Keychains/",
            "\(home)/Library/Mail/",
            "\(home)/Library/Accounts/",
            "\(home)/.ssh/", "\(home)/.gnupg/",
        ]
    }

    /// Whether `path` is safe to delete. The historical `CleanupManager.isSafePath`
    /// rules (protected roots, forbidden prefixes, minimum depth) plus the F9 §6
    /// expansions. Every rule only ever *rejects* — nothing here makes a path that was
    /// previously unsafe newly deletable.
    func isSafeToDelete(_ path: String) -> Bool {
        guard (path as NSString).isAbsolutePath else { return false }
        if !allowsSymbolicLinkItems,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            return false
        }
        let resolved = normalized(path)
        let lowercasedPath = resolved.lowercased()

        // Never delete a protected root path.
        if protectedPaths.contains(where: { $0.lowercased() == lowercasedPath }) {
            return false
        }

        // Never delete anything under a forbidden prefix.
        for prefix in forbiddenPrefixes
        where lowercasedPath.hasPrefix(prefix.lowercased()) {
            return false
        }

        // Require a minimum depth (at least 3 components).
        // Whole application bundles are exempt under the Uninstaller profile — they
        // legitimately sit at depth 2 in /Applications.
        let applicationBundleRoot = recognizedApplicationBundleRoot(in: resolved)
        let isWholeAppBundle = allowsApplicationBundles &&
            applicationBundleRoot == resolved
        if !isWholeAppBundle {
            let components = resolved.split(separator: "/")
            if components.count < 3 { return false }

            // F9 §6: `/Users/name/item` is too broad for a whole-item deletion target.
            // Shell-history files are the sole intentional exception and receive an
            // explicit profile from their scan definition.
            if lowercasedPath.hasPrefix("/users/"), components.count < 4 {
                let parent = URL(fileURLWithPath: resolved)
                    .deletingLastPathComponent().path.lowercased()
                let isDirectChildOfHome = parent == normalizedHome.lowercased()
                if !allowsDirectHomeItems || !isDirectChildOfHome {
                    return false
                }
            }
        }

        // F9 §6 expansions (additional rejections only).
        if !passesExpandedRules(resolved) { return false }

        return true
    }

    /// Whether `path` lies within one of `roots` (equal to a root, or nested beneath
    /// one). Uses component-boundary matching so that `/a/bc` is NOT considered within
    /// `/a/b`. Symlinks in `path` are resolved first, so a link that escapes its
    /// territory into a sibling tree is rejected. Empty territory is denied: every
    /// deletion surface must state what it owns.
    func isWithinAllowedRoots(_ path: String, roots: [String]) -> Bool {
        guard (path as NSString).isAbsolutePath, !roots.isEmpty else { return false }
        let resolved = normalized(path)
        for root in roots where isStableAllowedRoot(root) {
            let resolvedRoot = normalized(root)
            if resolved == resolvedRoot { return true }
            if resolved.hasPrefix(resolvedRoot + "/") { return true }
        }
        return false
    }

    /// Allowlist roots are declarations, not discovery results. If a declared cache
    /// root resolves through a user-created symlink, trusting its destination would
    /// authorize whatever tree the link points at. Permit only unchanged roots and
    /// macOS's fixed temporary-directory aliases.
    func isStableAllowedRoot(_ root: String) -> Bool {
        guard (root as NSString).isAbsolutePath else { return false }
        // A dangling link may not change `resolvingSymlinksInPath` on every filesystem,
        // but it is still never a trustworthy traversal/ownership root.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: root)) != nil {
            return false
        }
        let lexical = Self.standardizePath(root)
        let resolved = Self.normalizePath(root)
        if lexical == resolved { return true }

        let temporaryAliasPairs = [
            ("/tmp", "/private/tmp"),
            ("/var/tmp", "/private/var/tmp"),
            ("/var/folders", "/private/var/folders"),
        ]
        return temporaryAliasPairs.contains { pair in
            let (publicRoot, privateRoot) = pair
            let lowercasedLexical = lexical.lowercased()
            guard lowercasedLexical == publicRoot ||
                  lowercasedLexical.hasPrefix(publicRoot + "/") else {
                return false
            }
            let suffix = lexical.dropFirst(publicRoot.count)
            let expected = privateRoot + String(suffix)
            return expected == resolved
        }
    }

    /// The full deletion gate for a concrete path belonging to a category: it must pass
    /// the global safety rules AND lie within the category's territory. Pass the
    /// category's `allowedRoots` (or, when those are empty, its `paths`) as `roots`.
    func validate(_ path: String, allowedRoots roots: [String]) -> Bool {
        isSafeToDelete(path) && isWithinAllowedRoots(path, roots: roots)
    }

    /// Additional protections layered on top of the historical rules. Returns `false`
    /// for anything that must never be deleted regardless of depth.
    private func passesExpandedRules(_ resolved: String) -> Bool {
        let lowercasedPath = resolved.lowercased()

        // 1. macOS resolves `/etc`, `/var`, and `/tmp` into `/private`. Deny this
        //    namespace by default so an alias cannot bypass the public-path blocklist.
        //    Only direct descendants of sanctioned temporary roots are eligible; the
        //    roots themselves remain protected.
        if lowercasedPath == "/private" || lowercasedPath.hasPrefix("/private/") {
            let isSanctionedTemporaryItem = sanctionedPrivateTemporaryRoots.contains {
                lowercasedPath.hasPrefix($0 + "/")
            }
            if !isSanctionedTemporaryItem { return false }
        }

        // 2. iCloud Drive and third-party cloud-storage mounts — never delete these or
        //    anything inside them (deleting a placeholder can destroy remote data).
        for root in ["\(home)/Library/CloudStorage", "\(home)/Library/Mobile Documents"]
        where lowercasedPath == root.lowercased() ||
              lowercasedPath.hasPrefix(root.lowercased() + "/") {
            return false
        }

        // 3. Never delete the *contents* of a signed app or framework bundle — that
        //    breaks its code signature. Whole-bundle removal is the Uninstaller's job
        //    (its own policy profile). Mirrors the guard already used by the orphaned
        //    app-data scan.
        if let applicationBundleRoot = recognizedApplicationBundleRoot(in: resolved) {
            let isWholeAppBundle = resolved == applicationBundleRoot
            if !allowsApplicationBundles || !isWholeAppBundle {
                return false
            }
        }
        if lowercasedPath.contains(".framework/") ||
           lowercasedPath.hasSuffix(".framework") {
            return false
        }

        // 4. Library document bundles and keychains — opaque user data stores that
        //    generic cleanup must never open up. Protect both the bundle and contents.
        let protectedBundleSuffixes = [
            ".photoslibrary", ".musiclibrary", ".tvlibrary", ".aplibrary",
            ".fcpbundle", ".logicx", ".band", ".sparsebundle",
        ]
        for suffix in protectedBundleSuffixes
        where lowercasedPath.hasSuffix(suffix) || lowercasedPath.contains(suffix + "/") {
            return false
        }
        if lowercasedPath.hasSuffix(".keychain-db") { return false }

        // 5. Time Machine data must NEVER be touched with FileManager — only via
        //    tmutil/diskutil (see F14). Hard-reject regardless of any other rule.
        for marker in ["backups.backupdb", ".timemachine", "/volumes/.timemachine"]
        where lowercasedPath.contains(marker) {
            return false
        }

        return true
    }

    /// A bundle identifier used as a cache-directory name may legitimately end in
    /// `.app` (for example `~/Library/Caches/com.example.app`). Treat it as an
    /// application bundle only when it is in an Applications directory or has the
    /// standard on-disk bundle marker.
    private func recognizedApplicationBundleRoot(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var candidate = ""
        for component in components {
            candidate += "/" + component
            guard component.lowercased().hasSuffix(".app") else { continue }
            let lowercasedCandidate = candidate.lowercased()
            let isInApplicationsDirectory =
                lowercasedCandidate.hasPrefix("/applications/") ||
                lowercasedCandidate.hasPrefix(
                    normalizedHome.lowercased() + "/applications/"
                )
            let hasBundleInfo = FileManager.default.fileExists(
                atPath: candidate + "/Contents/Info.plist"
            )
            if isInApplicationsDirectory || hasBundleInfo {
                return candidate
            }
        }
        return nil
    }

    /// Standardize `.`/`..`, normalize Unicode, and resolve on-disk symlinks before
    /// comparing security boundaries.
    private func normalized(_ path: String) -> String {
        if allowsSymbolicLinkItems,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
            return Self.normalizePathWithoutFinalSymlink(path)
        }
        return Self.normalizePath(path)
    }

    /// Resolve every parent component while preserving the final symlink's lexical
    /// name. Removing that final object cannot traverse to its target.
    private static func normalizePathWithoutFinalSymlink(_ path: String) -> String {
        let standardized = standardizePath(path)
        let url = URL(fileURLWithPath: standardized)
        let name = url.lastPathComponent
        guard !name.isEmpty else { return normalizePath(standardized) }
        let resolvedParent = normalizePath(url.deletingLastPathComponent().path)
        return (resolvedParent as NSString)
            .appendingPathComponent(name)
            .precomposedStringWithCanonicalMapping
    }

    private static func normalizePath(_ path: String) -> String {
        let standardized = expandFixedSystemAlias(standardizePath(path))
        let resolved = (standardized as NSString).resolvingSymlinksInPath
        return expandFixedSystemAlias(standardizePath(resolved))
            .precomposedStringWithCanonicalMapping
    }

    /// Foundation standardization presents `/private/{etc,tmp,var}` through their
    /// public aliases. Convert those aliases back to one canonical namespace so
    /// security decisions do not depend on whether the final path currently exists.
    private static func expandFixedSystemAlias(_ path: String) -> String {
        for (publicRoot, privateRoot) in [
            ("/etc", "/private/etc"),
            ("/tmp", "/private/tmp"),
            ("/var", "/private/var"),
        ] {
            if path == publicRoot { return privateRoot }
            if path.hasPrefix(publicRoot + "/") {
                return privateRoot + path.dropFirst(publicRoot.count)
            }
        }
        return path
    }

    private static func standardizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
    }
}
