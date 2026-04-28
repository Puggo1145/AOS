import Foundation

// MARK: - AppInfo
//
// Per `docs/designs/computer-use.md` §"模块结构" / `computerUse.listApps`.
// Plain-data record of an operable on-screen app. The agent picks one
// and then calls `listWindows({pid})` to drive any actions.

public struct AppInfo: Sendable, Hashable {
    public let pid: pid_t
    public let bundleId: String?
    public let name: String
    /// `true` when this app is the current `NSWorkspace.frontmostApplication`.
    public let active: Bool

    public init(pid: pid_t, bundleId: String?, name: String, active: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.active = active
    }
}
