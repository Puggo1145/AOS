import AOSComputerUseKit
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public enum ComputerUsePermission: String, Sendable, Hashable, CaseIterable {
    case accessibility
    case screenRecording

    var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }
}

public struct PermissionGrantResult: Sendable, Equatable {
    public let requested: [ComputerUsePermission]
    public let status: [ComputerUsePermission: Bool]
    public let guidance: [String]

    public init(
        requested: [ComputerUsePermission],
        status: [ComputerUsePermission: Bool],
        guidance: [String]
    ) {
        self.requested = requested
        self.status = status
        self.guidance = guidance
    }
}

public protocol ComputerUsePermissionClient: Sendable {
    func request(_ permissions: [ComputerUsePermission]) async throws -> PermissionGrantResult
}

public struct LiveComputerUsePermissionClient: ComputerUsePermissionClient {
    public init() {}

    public func request(_ permissions: [ComputerUsePermission]) async throws -> PermissionGrantResult {
        for permission in permissions {
            requestPrompt(for: permission)
            openSystemSettings(for: permission)
        }

        return PermissionGrantResult(
            requested: permissions,
            status: currentStatus(for: permissions),
            guidance: permissions.map(guidanceLine(for:))
        )
    }

    private func requestPrompt(for permission: ComputerUsePermission) {
        switch permission {
        case .accessibility:
            let options: NSDictionary = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
            ]
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
    }

    private func currentStatus(for permissions: [ComputerUsePermission]) -> [ComputerUsePermission: Bool] {
        Dictionary(uniqueKeysWithValues: permissions.map { permission in
            switch permission {
            case .accessibility:
                return (permission, AXIsProcessTrusted())
            case .screenRecording:
                return (permission, CGPreflightScreenCaptureAccess())
            }
        })
    }

    private func openSystemSettings(for permission: ComputerUsePermission) {
        let urlString: String
        switch permission {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        guard let url = URL(string: urlString) else {
            preconditionFailure("invalid System Settings URL for \(permission.rawValue)")
        }
        NSWorkspace.shared.open(url)
    }

    private func guidanceLine(for permission: ComputerUsePermission) -> String {
        switch permission {
        case .accessibility:
            return "Grant Accessibility to the terminal app running AOSComputerUseCLI, then rerun the command."
        case .screenRecording:
            return "Grant Screen Recording to the terminal app running AOSComputerUseCLI; macOS may require restarting that terminal app."
        }
    }
}
