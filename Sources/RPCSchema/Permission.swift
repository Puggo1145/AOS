import Foundation

// MARK: - permission.* request params

public struct PermissionCapabilityView: Codable, Sendable, Equatable {
    public let capability: String
    public let action: String
    public let target: String?
    public let details: JSONValue?

    public init(capability: String, action: String, target: String? = nil, details: JSONValue? = nil) {
        self.capability = capability
        self.action = action
        self.target = target
        self.details = details
    }
}

public struct PermissionRequestApprovalParams: Codable, Sendable, Equatable {
    public enum Risk: String, Codable, Sendable, Equatable {
        case low
        case medium
        case high
    }

    public let sessionId: String
    public let turnId: String
    public let toolCallId: String
    public let toolName: String
    public let title: String
    public let message: String
    public let risk: Risk
    public let capabilities: [PermissionCapabilityView]

    public init(
        sessionId: String,
        turnId: String,
        toolCallId: String,
        toolName: String,
        title: String,
        message: String,
        risk: Risk,
        capabilities: [PermissionCapabilityView]
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.title = title
        self.message = message
        self.risk = risk
        self.capabilities = capabilities
    }
}

public struct PermissionRequestApprovalResult: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable, Equatable {
        case allow
        case deny
    }

    public let decision: Decision

    public init(decision: Decision) {
        self.decision = decision
    }
}

public struct PermissionApprovalCancelledParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let turnId: String
    public let toolCallId: String

    public init(sessionId: String, turnId: String, toolCallId: String) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.toolCallId = toolCallId
    }
}
