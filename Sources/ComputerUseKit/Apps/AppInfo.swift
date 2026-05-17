import Foundation

// MARK: - AppInfo
//
// Plain-data record of an available macOS application. Apps that are already
// running carry a pid. Installed-but-not-running apps intentionally keep pid nil.

public struct AppInfo: Sendable, Hashable {
    public let pid: pid_t?
    public let bundleId: String?
    public let name: String
    public let path: String?
    public let running: Bool
    /// `true` when this app is the current `NSWorkspace.frontmostApplication`.
    public let active: Bool

    public var identity: String {
        path ?? bundleId ?? pid.map { "pid:\($0)" } ?? "name:\(name)"
    }

    public init(
        pid: pid_t?,
        bundleId: String?,
        name: String,
        path: String?,
        running: Bool,
        active: Bool
    ) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.path = path
        self.running = running
        self.active = active
    }
}

public enum AppListMode: String, Sendable, Equatable {
    case running
    case all
}
