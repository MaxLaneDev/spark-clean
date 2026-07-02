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

    init(home: String = NSHomeDirectory(), allowsApplicationBundles: Bool = false) {
        self.home = home
        self.allowsApplicationBundles = allowsApplicationBundles
    }

    /// Absolute paths that must never be deleted — defense-in-depth against scan bugs.
    var protectedPaths: Set<String> {
        let h = home
        return [
            "/", "/System", "/usr", "/bin", "/sbin", "/var", "/etc", "/tmp", "/private",
            "/Applications", "/Library", "/Users",
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
            "/System/", "/usr/", "/bin/", "/sbin/", "/private/var/db/",
            "/Library/LaunchDaemons/", "/Library/LaunchAgents/",
            "/Library/Extensions/", "/Library/StartupItems/",
            "\(home)/Library/LaunchAgents/",
        ]
    }

    /// Whether `path` is safe to delete. The historical `CleanupManager.isSafePath`
    /// rules (protected roots, forbidden prefixes, minimum depth) plus the F9 §6
    /// expansions. Every rule only ever *rejects* — nothing here makes a path that was
    /// previously unsafe newly deletable.
    func isSafeToDelete(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath

        // Never delete a protected root path.
        if protectedPaths.contains(resolved) { return false }

        // Never delete anything under a forbidden prefix.
        for prefix in forbiddenPrefixes where resolved.hasPrefix(prefix) {
            return false
        }

        // Require a minimum depth (at least 3 components: / Users / name / something).
        // Whole application bundles are exempt under the Uninstaller profile — they
        // legitimately sit at depth 2 in /Applications.
        let isWholeAppBundle = allowsApplicationBundles && resolved.hasSuffix(".app")
        if !isWholeAppBundle {
            let components = resolved.split(separator: "/")
            if components.count < 3 { return false }
        }

        // F9 §6 expansions (additional rejections only).
        if !passesExpandedRules(resolved) { return false }

        return true
    }

    /// Whether `path` lies within one of `roots` (equal to a root, or nested beneath
    /// one). Uses component-boundary matching so that `/a/bc` is NOT considered within
    /// `/a/b`. Symlinks in `path` are resolved first, so a link that escapes its
    /// territory into a sibling tree is rejected. An empty `roots` imposes no
    /// constraint (returns `true`) — callers decide the fallback territory.
    func isWithinAllowedRoots(_ path: String, roots: [String]) -> Bool {
        guard !roots.isEmpty else { return true }
        let resolved = (path as NSString).resolvingSymlinksInPath
        for root in roots {
            let resolvedRoot = (root as NSString).resolvingSymlinksInPath
            if resolved == resolvedRoot { return true }
            if resolved.hasPrefix(resolvedRoot + "/") { return true }
        }
        return false
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
        // 1. iCloud Drive and third-party cloud-storage mounts — never delete these or
        //    anything inside them (deleting a placeholder can destroy remote data).
        for root in ["\(home)/Library/CloudStorage", "\(home)/Library/Mobile Documents"]
        where resolved == root || resolved.hasPrefix(root + "/") {
            return false
        }

        // 2. Never delete the *contents* of a signed app or framework bundle — that
        //    breaks its code signature. Whole-bundle removal is the Uninstaller's job
        //    (its own policy profile). Mirrors the guard already used by the orphaned
        //    app-data scan.
        if resolved.contains(".app/Contents/") || resolved.contains(".framework/") {
            return false
        }

        // 3. Library document bundles and keychains — opaque user data stores that
        //    generic cleanup must never open up. Protect both the bundle and contents.
        let protectedBundleSuffixes = [
            ".photoslibrary", ".musiclibrary", ".tvlibrary", ".aplibrary",
            ".fcpbundle", ".logicx", ".sparsebundle",
        ]
        for suffix in protectedBundleSuffixes
        where resolved.hasSuffix(suffix) || resolved.contains(suffix + "/") {
            return false
        }
        if resolved.hasSuffix(".keychain-db") { return false }

        // 4. Time Machine data must NEVER be touched with FileManager — only via
        //    tmutil/diskutil (see F14). Hard-reject regardless of any other rule.
        for marker in ["Backups.backupdb", ".timemachine", "/Volumes/.timemachine"]
        where resolved.contains(marker) {
            return false
        }

        return true
    }
}
