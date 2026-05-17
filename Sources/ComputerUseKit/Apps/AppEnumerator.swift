import AppKit
import CoreGraphics
import Foundation

// MARK: - AppEnumerator
//
// Returns installed/launchable application bundles from the user's standard
// app locations and overlays current `NSRunningApplication` state.

enum AppEnumerator {
    public static func apps(mode: AppListMode) -> [AppInfo] {
        apps(
            mode: mode,
            applicationDirectories: applicationDirectories(),
            runningApplications: NSWorkspace.shared.runningApplications,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    static func apps(
        mode: AppListMode,
        applicationDirectories: [URL],
        runningApplications: [NSRunningApplication],
        frontmostPID: pid_t?
    ) -> [AppInfo] {
        switch mode {
        case .running:
            return runningApps(runningApplications: runningApplications, frontmostPID: frontmostPID)
        case .all:
            return allApps(
                applicationDirectories: applicationDirectories,
                runningApplications: runningApplications,
                frontmostPID: frontmostPID
            )
        }
    }

    private static func allApps(
        applicationDirectories: [URL],
        runningApplications: [NSRunningApplication],
        frontmostPID: pid_t?
    ) -> [AppInfo] {
        var entriesByPath = installedApps(in: applicationDirectories)

        for app in runningApplications where app.activationPolicy == .regular {
            let path = app.bundleURL?.standardizedFileURL.path
            if let path, var existing = entriesByPath[path] {
                existing = existing.withRuntimeState(
                    pid: app.processIdentifier,
                    name: app.localizedName,
                    bundleId: app.bundleIdentifier,
                    active: app.processIdentifier == frontmostPID
                )
                entriesByPath[path] = existing
            } else {
                let entry = makeRunningInfo(app, active: app.processIdentifier == frontmostPID)
                entriesByPath[entry.identity] = entry
            }
        }

        return entriesByPath.values.sorted { lhs, rhs in
            compareApps(lhs, rhs)
        }
    }

    private static func runningApps(
        runningApplications: [NSRunningApplication],
        frontmostPID: pid_t?
    ) -> [AppInfo] {
        runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { makeRunningInfo($0, active: $0.processIdentifier == frontmostPID) }
            .sorted(by: compareApps)
    }

    static func installedApps(in directories: [URL]) -> [String: AppInfo] {
        let fm = FileManager.default
        var entries: [String: AppInfo] = [:]

        for directory in directories {
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()

                let standardized = url.standardizedFileURL
                let path = standardized.path
                if entries[path] != nil { continue }

                if let info = makeInstalledInfo(url: standardized) {
                    entries[path] = info
                }
            }
        }

        return entries
    }

    private static func applicationDirectories() -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for domain in [FileManager.SearchPathDomainMask.userDomainMask, .localDomainMask, .systemDomainMask] {
            urls.append(contentsOf: fm.urls(for: .applicationDirectory, in: domain))
        }
        urls.append(URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true))
        return urls
    }

    private static func makeInstalledInfo(url: URL) -> AppInfo? {
        guard let bundle = Bundle(url: url),
              let bundleId = nonEmptyInfoString(bundle, key: "CFBundleIdentifier"),
              hasLaunchableExecutable(bundle)
        else {
            return nil
        }
        return AppInfo(
            pid: nil,
            bundleId: bundleId,
            name: appName(bundle: bundle, url: url),
            path: url.path,
            running: false,
            active: false
        )
    }

    private static func hasLaunchableExecutable(_ bundle: Bundle) -> Bool {
        guard nonEmptyInfoString(bundle, key: "CFBundleExecutable") != nil,
              let executableURL = bundle.executableURL
        else {
            return false
        }
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: executableURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func makeRunningInfo(_ app: NSRunningApplication, active: Bool) -> AppInfo {
        AppInfo(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
            path: app.bundleURL?.standardizedFileURL.path,
            running: true,
            active: active
        )
    }

    private static func appName(bundle: Bundle?, url: URL) -> String {
        if let displayName = nonEmptyInfoString(bundle, key: "CFBundleDisplayName") {
            return displayName
        }
        if let bundleName = nonEmptyInfoString(bundle, key: "CFBundleName") {
            return bundleName
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func nonEmptyInfoString(_ bundle: Bundle?, key: String) -> String? {
        guard let value = bundle?.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func compareApps(_ lhs: AppInfo, _ rhs: AppInfo) -> Bool {
        let nameCompare = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameCompare != .orderedSame {
            return nameCompare == .orderedAscending
        }
        return lhs.identity.localizedCaseInsensitiveCompare(rhs.identity) == .orderedAscending
    }
}

private extension AppInfo {
    func withRuntimeState(pid: pid_t, name: String?, bundleId: String?, active: Bool) -> AppInfo {
        AppInfo(
            pid: pid,
            bundleId: bundleId ?? self.bundleId,
            name: name ?? self.name,
            path: path,
            running: true,
            active: active
        )
    }
}
