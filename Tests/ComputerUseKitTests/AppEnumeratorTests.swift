import Foundation
import Testing
@testable import ComputerUseKit

@Suite("AppEnumerator")
struct AppEnumeratorTests {
    @Test("availableApps includes installed app bundles that are not running")
    func availableAppsIncludesInstalledBundlesWithoutPid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-agent-app-enumerator-\(UUID().uuidString)", isDirectory: true)
        let appName = "Fixture-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = try makeValidAppBundle(root: root, appName: appName)

        let apps = AppEnumerator.apps(
            mode: .all,
            applicationDirectories: [root],
            runningApplications: [],
            frontmostPID: nil
        )

        let match = try #require(apps.first { $0.path == appURL.standardizedFileURL.path })
        #expect(match.name == appName)
        #expect(match.pid == nil)
        #expect(!match.running)
        #expect(!match.active)
    }

    @Test("running mode excludes installed bundles that are not running")
    func runningModeExcludesInstalledBundlesWithoutPid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-agent-app-enumerator-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let apps = AppEnumerator.apps(
            mode: .running,
            applicationDirectories: [root],
            runningApplications: [],
            frontmostPID: nil
        )

        #expect(apps.isEmpty)
    }

    @Test("all mode excludes malformed app directories")
    func allModeExcludesMalformedAppDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-agent-app-enumerator-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Malformed.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let apps = AppEnumerator.apps(
            mode: .all,
            applicationDirectories: [root],
            runningApplications: [],
            frontmostPID: nil
        )

        #expect(!apps.contains { $0.path == appURL.standardizedFileURL.path })
    }

    private func makeValidAppBundle(root: URL, appName: String) throws -> URL {
        let appURL = root.appendingPathComponent("\(appName).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let executableName = "fixture"
        let executableURL = macOSURL.appendingPathComponent(executableName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: String] = [
            "CFBundleIdentifier": "test.notch-agent.\(UUID().uuidString)",
            "CFBundleName": appName,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
        return appURL
    }
}
