import Foundation
import RPCSchema

@MainActor
@Observable
public final class PermissionApprovalService {
    public private(set) var pendingRequest: PermissionRequestApprovalParams?

    @ObservationIgnored
    private var pendingContinuation: CheckedContinuation<PermissionRequestApprovalResult, Error>?

    @ObservationIgnored
    private var queuedRequests: [PendingApprovalRequest] = []

    var pendingApprovalCount: Int {
        (pendingContinuation == nil ? 0 : 1) + queuedRequests.count
    }

    public init(rpc: RPCClient) {
        registerHandlers(on: rpc)
    }

    private func registerHandlers(on rpc: RPCClient) {
        rpc.registerNotificationHandler(
            method: RPCMethod.permissionApprovalCancelled,
            as: PermissionApprovalCancelledParams.self
        ) { [weak self] params in
            await self?.cancelPendingRequest(params)
        }

        rpc.registerRequestHandler(
            method: RPCMethod.permissionRequestApproval,
            as: PermissionRequestApprovalParams.self,
            resultType: PermissionRequestApprovalResult.self
        ) { [weak self] params in
            guard let self else {
                throw RPCErrorThrowable(RPCError(
                    code: RPCErrorCode.internalError,
                    message: "permission approval service unavailable"
                ))
            }
            return try await self.requestApproval(params)
        }
    }

    private func requestApproval(_ params: PermissionRequestApprovalParams) async throws -> PermissionRequestApprovalResult {
        return try await withCheckedThrowingContinuation { continuation in
            let request = PendingApprovalRequest(params: params, continuation: continuation)
            if pendingContinuation == nil {
                start(request)
            } else {
                queuedRequests.append(request)
            }
        }
    }

    public func allowPendingRequest() {
        resolvePendingRequest(.allow)
    }

    public func denyPendingRequest() {
        resolvePendingRequest(.deny)
    }

    public func failPendingRequest(message: String) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        pendingRequest = nil
        continuation.resume(throwing: approvalFailure(message: message))
        startNextQueuedRequest()
    }

    public func failAllPendingRequests(message: String) {
        let current = pendingContinuation
        let queued = queuedRequests
        pendingContinuation = nil
        pendingRequest = nil
        queuedRequests.removeAll()

        current?.resume(throwing: approvalFailure(message: message))
        for request in queued {
            request.continuation.resume(throwing: approvalFailure(message: message))
        }
    }

    private func cancelPendingRequest(_ params: PermissionApprovalCancelledParams) {
        guard pendingRequest?.sessionId == params.sessionId,
              pendingRequest?.turnId == params.turnId,
              pendingRequest?.toolCallId == params.toolCallId
        else {
            cancelQueuedRequest(params)
            return
        }
        failPendingRequest(message: "permission approval request cancelled")
    }

    private func resolvePendingRequest(_ decision: PermissionRequestApprovalResult.Decision) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        pendingRequest = nil
        continuation.resume(returning: PermissionRequestApprovalResult(decision: decision))
        startNextQueuedRequest()
    }

    private func start(_ request: PendingApprovalRequest) {
        pendingRequest = request.params
        pendingContinuation = request.continuation
    }

    private func startNextQueuedRequest() {
        guard pendingContinuation == nil else { return }
        guard !queuedRequests.isEmpty else { return }
        start(queuedRequests.removeFirst())
    }

    private func cancelQueuedRequest(_ params: PermissionApprovalCancelledParams) {
        guard let index = queuedRequests.firstIndex(where: {
            $0.params.sessionId == params.sessionId &&
            $0.params.turnId == params.turnId &&
            $0.params.toolCallId == params.toolCallId
        }) else {
            return
        }
        let request = queuedRequests.remove(at: index)
        request.continuation.resume(throwing: approvalFailure(message: "permission approval request cancelled"))
    }
}

private struct PendingApprovalRequest {
    let params: PermissionRequestApprovalParams
    let continuation: CheckedContinuation<PermissionRequestApprovalResult, Error>
}

private func approvalFailure(message: String) -> RPCErrorThrowable {
    RPCErrorThrowable(RPCError(
        code: RPCErrorCode.internalError,
        message: message
    ))
}
