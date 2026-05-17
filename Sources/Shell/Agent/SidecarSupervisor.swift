import Foundation

// MARK: - SidecarSupervisor
//
// Runtime policy for the Bun sidecar after CompositionRoot starts it.
// SidecarProcess owns pipes and OS process mechanics; this type owns the
// Shell-facing lifecycle state. A post-launch unexpected exit is fatal for
// the current app session because every Agent/Provider/Config service is
// already wired to dead stdio handles.

@MainActor
public final class SidecarSupervisor {
    public enum State: Equatable, Sendable {
        case idle
        case launching
        case running
        case stopping
        case fatal(String)
    }

    public private(set) var state: State = .idle
    private var fatalHandler: (@MainActor (String) -> Void)?

    public init(process: SidecarProcess? = nil) {
        process?.setUnexpectedExitHandler { [weak self] status in
            Task { @MainActor in
                self?.handleUnexpectedExit(status: status)
            }
        }
    }

    public func setFatalHandler(_ handler: @escaping @MainActor (String) -> Void) {
        fatalHandler = handler
    }

    public func beginLaunch() {
        state = .launching
    }

    public func didLaunch() {
        state = .running
    }

    public func didFailLaunch() {
        state = .idle
    }

    public func expectTermination() {
        state = .stopping
    }

    internal func handleUnexpectedExit(status: Int32) {
        guard state == .launching || state == .running else { return }
        let message = Self.unexpectedExitMessage(status: status)
        state = .fatal(message)
        fatalHandler?(message)
    }

    public static func unexpectedExitMessage(status: Int32) -> String {
        "Sidecar exited unexpectedly with status \(status). Restart Notch Agent to reconnect the agent."
    }
}
