import Foundation
import RPCSchema
import Testing
import OSSenseKit
@testable import Shell

@MainActor
@Suite("Permission UI metadata")
struct PermissionUITests {

    @Test("Settings permission list includes Automation")
    func settingsPermissionsIncludeAutomation() {
        #expect(Permission.settingsDisplayOrder == [
            .screenRecording,
            .accessibility,
            .localFiles,
            .automation,
        ])
    }

    @Test("Onboarding permission sequence includes Automation after probeable permissions")
    func onboardingPermissionsIncludeAutomation() {
        #expect(Permission.onboardingDisplayOrder == [
            .screenRecording,
            .accessibility,
            .localFiles,
            .automation,
        ])
    }

    @Test("Settings missing permissions ignore Automation acknowledgement state")
    func settingsMissingPermissionsIgnoreAutomationAcknowledgementState() {
        #expect(SettingsFlowModel.missingProbeablePermissions(denied: []) == [])
        #expect(SettingsFlowModel.missingProbeablePermissions(denied: [.automation]) == [])
        #expect(SettingsFlowModel.missingProbeablePermissions(denied: [.localFiles]) == [])
        #expect(SettingsFlowModel.missingProbeablePermissions(denied: [.accessibility, .automation, .localFiles]) == [.accessibility])
    }

    @Test("Settings Automation row opens System Settings instead of using reviewed state")
    func settingsAutomationRowOpensSystemSettingsInsteadOfUsingReviewedState() {
        #expect(SettingsFlowModel.permissionStatus(for: .automation, denied: []) == .opensSettings)
        #expect(SettingsFlowModel.permissionStatus(for: .localFiles, denied: []) == .opensSettings)
        #expect(SettingsFlowModel.permissionStatus(for: .screenRecording, denied: []) == .granted)
        #expect(SettingsFlowModel.permissionStatus(for: .screenRecording, denied: [.screenRecording]) == .disabled)
    }

    @Test("Automation uses Finder icon only during onboarding")
    func automationUsesFinderIconOnlyDuringOnboarding() {
        #expect(PermissionOnboardPanelView.automationIcon(for: .automation) == .finder)
        #expect(PermissionOnboardPanelView.automationIcon(for: .accessibility) == .gear)
        #expect(PermissionOnboardPanelView.automationIcon(for: .localFiles) == .gear)
        #expect(PermissionGlyph.defaultAutomationIcon == .gear)
    }

    @Test("Exact text selection behavior uses a text quote icon")
    func textSelectionUsesTextQuoteIcon() {
        let envelope = BehaviorEnvelope(
            kind: "general.textSelection",
            citationKey: "general.textSelection:42",
            displaySummary: "Selected text",
            payload: OSSenseKit.JSONValue.object([:])
        )

        #expect(ContextChipsView.behaviorIcon(for: envelope) == "text.quote")
    }

    @Test("Finder file selection behavior uses a file icon")
    func finderFileSelectionUsesFileIcon() {
        let envelope = BehaviorEnvelope(
            kind: "finder.selection",
            citationKey: "finder.selection",
            displaySummary: "Report.pdf",
            payload: OSSenseKit.JSONValue.object([
                "items": OSSenseKit.JSONValue.array([
                    OSSenseKit.JSONValue.object(["role": OSSenseKit.JSONValue.string("file")]),
                ]),
            ])
        )

        #expect(ContextChipsView.behaviorIcon(for: envelope) == "doc")
    }

    @Test("Finder folder selection behavior uses a folder icon")
    func finderFolderSelectionUsesFolderIcon() {
        let envelope = BehaviorEnvelope(
            kind: "finder.selection",
            citationKey: "finder.selection",
            displaySummary: "Assets",
            payload: OSSenseKit.JSONValue.object([
                "items": OSSenseKit.JSONValue.array([
                    OSSenseKit.JSONValue.object(["role": OSSenseKit.JSONValue.string("folder")]),
                ]),
            ])
        )

        #expect(ContextChipsView.behaviorIcon(for: envelope) == "folder")
    }

    @Test("permission approval request is exposed inline and resolves through service buttons")
    func permissionApprovalRequestResolvesThroughServiceButtons() async throws {
        let harness = RPCPermissionHarness()
        harness.client.start()
        defer { harness.client.stop() }
        let service = PermissionApprovalService(rpc: harness.client)
        let params = PermissionRequestApprovalParams(
            sessionId: "S",
            turnId: "T",
            toolCallId: "tc_permission",
            toolName: "bash",
            title: "Allow command?",
            message: "Agent wants to run a shell command.",
            risk: .high,
            capabilities: [
                PermissionCapabilityView(
                    capability: "process.spawn",
                    action: "Run shell command",
                    target: "echo hi"
                ),
            ]
        )

        try harness.writeRequest(id: .string("permission-1"), method: RPCMethod.permissionRequestApproval, params: params)
        try await waitUntil(timeout: 2) {
            service.pendingRequest?.toolCallId == "tc_permission"
        }

        #expect(service.pendingRequest == params)
        service.allowPendingRequest()

        let response = try await harness.readResponse(
            timeout: 2,
            as: RPCResponse<PermissionRequestApprovalResult>.self
        )
        #expect(response.id == .string("permission-1"))
        #expect(response.result.decision == .allow)
        #expect(service.pendingRequest == nil)
    }

    @Test("permission approval cancellation clears inline pending request")
    func permissionApprovalCancellationClearsPendingRequest() async throws {
        let harness = RPCPermissionHarness()
        harness.client.start()
        defer { harness.client.stop() }
        let service = PermissionApprovalService(rpc: harness.client)
        let params = PermissionRequestApprovalParams(
            sessionId: "S",
            turnId: "T",
            toolCallId: "tc_permission_cancel",
            toolName: "bash",
            title: "Allow command?",
            message: "Agent wants to run a shell command.",
            risk: .high,
            capabilities: [
                PermissionCapabilityView(
                    capability: "process.spawn",
                    action: "Run shell command",
                    target: "sleep 10"
                ),
            ]
        )

        try harness.writeRequest(id: .string("permission-cancel"), method: RPCMethod.permissionRequestApproval, params: params)
        try await waitUntil(timeout: 2) {
            service.pendingRequest?.toolCallId == "tc_permission_cancel"
        }

        try harness.writeNotification(
            method: RPCMethod.permissionApprovalCancelled,
            params: PermissionApprovalCancelledParams(
                sessionId: "S",
                turnId: "T",
                toolCallId: "tc_permission_cancel"
            )
        )
        try await waitUntil(timeout: 2) {
            service.pendingRequest == nil
        }

        let response = try await harness.readResponse(
            timeout: 2,
            as: RPCErrorResponse.self
        )
        #expect(response.id == .string("permission-cancel"))
        #expect(response.error.code == RPCErrorCode.internalError)
    }

    @Test("permission approval service queues concurrent approval requests")
    func permissionApprovalServiceQueuesConcurrentRequests() async throws {
        let harness = RPCPermissionHarness()
        harness.client.start()
        defer { harness.client.stop() }
        let service = PermissionApprovalService(rpc: harness.client)
        let first = permissionRequest(toolCallId: "tc_permission_first", target: "echo first")
        let second = permissionRequest(toolCallId: "tc_permission_second", target: "echo second")

        try harness.writeRequest(id: .string("permission-first"), method: RPCMethod.permissionRequestApproval, params: first)
        try harness.writeRequest(id: .string("permission-second"), method: RPCMethod.permissionRequestApproval, params: second)
        try await waitUntil(timeout: 2) {
            service.pendingApprovalCount == 2
        }

        let initiallyDisplayed = try #require(service.pendingRequest)
        service.allowPendingRequest()
        let allowResponse = try await harness.readResponse(
            timeout: 2,
            as: RPCResponse<PermissionRequestApprovalResult>.self
        )
        #expect(allowResponse.id == rpcId(for: initiallyDisplayed.toolCallId))
        #expect(allowResponse.result.decision == .allow)

        try await waitUntil(timeout: 2) {
            service.pendingApprovalCount == 1 &&
            service.pendingRequest?.toolCallId != initiallyDisplayed.toolCallId
        }
        let remaining = try #require(service.pendingRequest)
        service.denyPendingRequest()
        let denyResponse = try await harness.readResponse(
            timeout: 2,
            as: RPCResponse<PermissionRequestApprovalResult>.self
        )
        #expect(denyResponse.id == rpcId(for: remaining.toolCallId))
        #expect(denyResponse.result.decision == .deny)
        #expect(service.pendingRequest == nil)
        #expect(Set([allowResponse.id, denyResponse.id]) == [
            .string("permission-first"),
            .string("permission-second"),
        ])
    }

    @Test("permission approval service fails current and queued requests on shutdown")
    func permissionApprovalServiceFailsCurrentAndQueuedRequestsOnShutdown() async throws {
        let harness = RPCPermissionHarness()
        harness.client.start()
        defer { harness.client.stop() }
        let service = PermissionApprovalService(rpc: harness.client)
        let first = permissionRequest(toolCallId: "tc_permission_shutdown_first", target: "echo first")
        let second = permissionRequest(toolCallId: "tc_permission_shutdown_second", target: "echo second")

        try harness.writeRequest(id: .string("permission-shutdown-first"), method: RPCMethod.permissionRequestApproval, params: first)
        try harness.writeRequest(id: .string("permission-shutdown-second"), method: RPCMethod.permissionRequestApproval, params: second)
        try await waitUntil(timeout: 2) {
            service.pendingApprovalCount == 2
        }

        service.failAllPendingRequests(message: "permission approval service stopped")

        let responses = try await [
            harness.readResponse(timeout: 2, as: RPCErrorResponse.self),
            harness.readResponse(timeout: 2, as: RPCErrorResponse.self),
        ]
        #expect(Set(responses.map(\.id)) == [
            .string("permission-shutdown-first"),
            .string("permission-shutdown-second"),
        ])
        #expect(responses.allSatisfy { $0.error.code == RPCErrorCode.internalError })
        #expect(responses.allSatisfy { $0.error.message == "permission approval service stopped" })
        #expect(service.pendingRequest == nil)
        #expect(service.pendingApprovalCount == 0)
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition was not met before timeout")
    }

    private func permissionRequest(toolCallId: String, target: String) -> PermissionRequestApprovalParams {
        PermissionRequestApprovalParams(
            sessionId: "S",
            turnId: "T",
            toolCallId: toolCallId,
            toolName: "bash",
            title: "Allow command?",
            message: "Agent wants to run a shell command.",
            risk: .high,
            capabilities: [
                PermissionCapabilityView(
                    capability: "process.spawn",
                    action: "Run shell command",
                    target: target
                ),
            ]
        )
    }

    private func rpcId(for toolCallId: String) -> RPCId {
        switch toolCallId {
        case "tc_permission_first":
            return .string("permission-first")
        case "tc_permission_second":
            return .string("permission-second")
        default:
            preconditionFailure("unexpected permission toolCallId: \(toolCallId)")
        }
    }
}

private final class RPCPermissionHarness: @unchecked Sendable {
    let client: RPCClient
    private let serverToClient: Pipe
    private let clientToServer: Pipe
    private var readBuffer = Data()

    init() {
        serverToClient = Pipe()
        clientToServer = Pipe()
        client = RPCClient(
            inbound: serverToClient.fileHandleForReading,
            outbound: clientToServer.fileHandleForWriting
        )
        let fd = clientToServer.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    func writeRequest<P: Codable & Sendable & Equatable>(id: RPCId, method: String, params: P) throws {
        let request = RPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        try serverToClient.fileHandleForWriting.write(contentsOf: data)
        try serverToClient.fileHandleForWriting.write(contentsOf: Data([0x0A]))
    }

    func writeNotification<P: Codable & Sendable & Equatable>(method: String, params: P) throws {
        let notification = RPCNotification(method: method, params: params)
        let data = try JSONEncoder().encode(notification)
        try serverToClient.fileHandleForWriting.write(contentsOf: data)
        try serverToClient.fileHandleForWriting.write(contentsOf: Data([0x0A]))
    }

    func readResponse<R: Codable & Sendable & Equatable>(
        timeout: TimeInterval,
        as type: R.Type = R.self
    ) async throws -> R {
        let line = try await readLine(timeout: timeout)
        return try JSONDecoder().decode(R.self, from: line)
    }

    private func readLine(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        let fd = clientToServer.fileHandleForReading.fileDescriptor
        var scratch = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                return line
            }
            let n = scratch.withUnsafeMutableBufferPointer { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                readBuffer.append(scratch, count: n)
                continue
            }
            if n == 0 {
                throw RPCClientError.connectionClosed
            }
            if errno != EAGAIN && errno != EWOULDBLOCK {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RPCClientError.timeout(method: "test.readResponse")
    }
}
