import Foundation
import OSSenseKit

// MARK: - DevOSSenseSnapshot
//
// Dev Mode projection for the live OS Sense mirror. It keeps JSON and
// identity formatting out of SwiftUI so the diagnostic panel stays a thin
// observer of the same SenseStore used by the Notch UI.

struct DevOSSenseSnapshot: Equatable {
    struct Behavior: Equatable, Identifiable {
        let kind: String
        let citationKey: String
        let displaySummary: String
        let payloadText: String

        var id: String { citationKey }
    }

    let appLine: String
    let windowLine: String
    let permissionsLine: String
    let behaviors: [Behavior]
    let capturedAt: Date

    init(context: SenseContext, capturedAt: Date = Date()) {
        self.appLine = Self.appLine(context.app)
        self.windowLine = Self.windowLine(context.window)
        self.permissionsLine = Self.permissionsLine(context.permissions)
        self.behaviors = context.behaviors.map { envelope in
            Behavior(
                kind: envelope.kind,
                citationKey: envelope.citationKey,
                displaySummary: envelope.displaySummary,
                payloadText: Self.payloadText(envelope.payload)
            )
        }
        self.capturedAt = capturedAt
    }

    private static func appLine(_ app: AppIdentity?) -> String {
        guard let app else { return "No frontmost app" }
        return "\(app.name) (\(app.bundleId), pid \(app.pid))"
    }

    private static func windowLine(_ window: WindowIdentity?) -> String {
        guard let window else { return "No focused window" }
        if let windowId = window.windowId {
            return "\(window.title) (#\(windowId))"
        }
        return window.title
    }

    private static func permissionsLine(_ permissions: PermissionState) -> String {
        guard !permissions.denied.isEmpty else { return "Denied: none" }
        let labels = permissions.denied
            .map(permissionLabel)
            .sorted()
            .joined(separator: ", ")
        return "Denied: \(labels)"
    }

    private static func permissionLabel(_ permission: Permission) -> String {
        switch permission {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        }
    }

    private static func payloadText(_ payload: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(payload)
        return String(data: data, encoding: .utf8)!
    }
}
