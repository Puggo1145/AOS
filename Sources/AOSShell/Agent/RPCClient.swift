import Foundation
import os
import AOSRPCSchema

// MARK: - RPCClient
//
// JSON-RPC 2.0 NDJSON codec, built strictly per docs/designs/rpc-protocol.md
// §"Dispatcher 并发模型":
//   - single reader Task on the inbound FileHandle, parses + dispatches only
//     (no business handler runs on the reader)
//   - outbound writes serialized through an actor (`Outbound`) so concurrent
//     `request` callers don't interleave bytes
//   - per-request `pending` map keyed by `RPCId`, resumed when the matching
//     response arrives
//   - notifications dispatched into independent Tasks so handlers don't block
//     the reader
//   - per-method timeouts implemented via Task.sleep race
//
// This round, the only Bun→Shell Request is `rpc.hello`'s response (handled
// via the request path); business Requests Bun→Shell (computerUse.*) arrive
// in Wave 4. The symmetric request-handler dispatch path is implemented but
// unused this round so Wave 4 can register handlers without a structural
// change.

public enum RPCClientError: Error, Sendable {
    /// `rpc.hello` returned with a MAJOR version that doesn't match aosProtocolVersion.
    case protocolMajorMismatch(remote: String, local: String)
    /// Connection closed before a request response was received.
    case connectionClosed
    /// Timed out waiting for a response within the per-method limit.
    case timeout(method: String)
    /// Server side returned an RPC error envelope.
    case server(RPCError)
    /// Reader hit an oversized line (single NDJSON line > 2MB) and aborted.
    case payloadTooLarge
    /// Outbound encoded frame would exceed the 2MB single-line cap and was
    /// rejected at `request(...)` before any pending continuation was
    /// registered or any byte was written. Carries the encoded byte count and
    /// the limit so callers can surface a precise user-facing message.
    case outboundPayloadTooLarge(method: String, bytes: Int, limit: Int)
    /// Initial handshake produced a non-decodable result.
    case malformed(String)
}

/// Read-only view onto inbound notifications. Handlers receive raw `Data` of
/// the `params` value and decode it themselves; the reader stays generic.
public typealias NotificationHandler = @Sendable (Data) async -> Void

/// Inbound-request handler. Receives the raw NDJSON line (so the handler
/// can decode `RPCRequest<P>` for whichever P it expects) and returns the
/// already-encoded response/error line. Handlers are invoked on a detached
/// Task so they don't block the reader; the wire layer writes the
/// returned bytes back through the outbound queue. Per
/// docs/designs/rpc-protocol.md §"computerUse.*" each `computerUse.*`
/// method registers one handler here.
public typealias RequestHandler = @Sendable (Data) async -> Data?

/// Bridge for handlers that want to surface a typed `RPCError` on the
/// wire. `RPCError` is a Codable struct (not an `Error`); wrap it here
/// so the handler closure can throw and the dispatcher recovers the
/// original wire shape via the `as RPCErrorThrowable` catch arm.
public struct RPCErrorThrowable: Error {
    public let rpcError: RPCError
    public init(_ rpcError: RPCError) { self.rpcError = rpcError }
}

public final class RPCClient: @unchecked Sendable {
    private let inbound: FileHandle
    private let outbound: FileHandle

    /// Pending request continuations. Each key is the RPCId we sent.
    /// `OSAllocatedUnfairLock<State>` instead of NSLock + raw var so the
    /// state and the lock guarding it are inseparable — Swift 6 strict
    /// concurrency can prove the access is serialized without `@unchecked
    /// Sendable` relying on convention.
    private let pendingLock = OSAllocatedUnfairLock<[RPCId: CheckedContinuation<Data, Error>]>(
        initialState: [:]
    )

    /// Notification + inbound-request handler registries. Both share one lock
    /// so registry reads/writes stay coherent (handle() peeks `method` then
    /// looks up either map).
    private struct HandlerRegistry {
        var notifications: [String: NotificationHandler] = [:]
        var requests: [String: RequestHandler] = [:]
    }
    private let handlerRegistry = OSAllocatedUnfairLock<HandlerRegistry>(
        initialState: HandlerRegistry()
    )

    private let writeQueue = DispatchQueue(label: "aos.rpc.write")

    /// Lifecycle + serial-notification state. Originally three plain
    /// mutable properties (`readerStopped`, `notificationContinuation`,
    /// `notificationConsumer`) accessed concurrently from the caller
    /// thread (start/stop), the reader DispatchQueue (`runReaderSync`
    /// reads `readerStopped`, `handle()` reads `notificationContinuation`),
    /// and the consumer Task. That left the class depending on
    /// `@unchecked Sendable` for exactly the lifecycle properties most
    /// likely to race a stop/start cycle. Bundled here under the same
    /// `OSAllocatedUnfairLock<State>` pattern used by `pendingLock` /
    /// `handlerRegistry` / `handshakeState` so the whole class's mutable
    /// state is uniformly serialized.
    ///
    /// `readerStopped` is read once per reader-loop iteration (cheap on
    /// `OSAllocatedUnfairLock`). `notificationContinuation` is captured
    /// once per inbound notification line; `notificationConsumer` is
    /// only read on stop.
    ///
    /// Why serial notification consumer: streaming `ui.token` deltas must
    /// be applied in arrival order. An earlier implementation spawned
    /// `Task.detached` per notification, which let two deltas race to the
    /// MainActor handler and concatenate out of order (e.g. a reply
    /// streamed as "Hi", "! How" landed in `turns[idx].reply` as
    /// "! HowHi"). One consumer = no race.
    private struct LifecycleState {
        var readerStopped: Bool = false
        var notificationContinuation: AsyncStream<@Sendable () async -> Void>.Continuation?
        var notificationConsumer: Task<Void, Never>?
    }
    private let lifecycle = OSAllocatedUnfairLock<LifecycleState>(
        initialState: LifecycleState()
    )

    private static let maxLineBytes = 2 * 1024 * 1024 // 2MB per protocol spec

    public init(inbound: FileHandle, outbound: FileHandle) {
        self.inbound = inbound
        self.outbound = outbound
    }

    // MARK: - Lifecycle

    public func start() {
        // Run the reader on a dedicated DispatchQueue rather than a Swift Task
        // so the synchronous `read(upToCount:)` doesn't pin a cooperative-pool
        // thread. This keeps Swift Concurrency's pool free for all the other
        // async work in tests + production.

        // Spin up the serial notification consumer before the reader starts
        // producing so the first inbound notification has somewhere to land.
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        let consumer = Task.detached {
            for await work in stream {
                await work()
            }
        }
        lifecycle.withLock { state in
            state.readerStopped = false
            state.notificationContinuation = continuation
            state.notificationConsumer = consumer
        }

        let q = DispatchQueue(label: "aos.rpc.reader", qos: .utility)
        q.async { [weak self] in self?.runReaderSync() }
    }

    public func stop() {
        let priorContinuation = lifecycle.withLock { state -> AsyncStream<@Sendable () async -> Void>.Continuation? in
            state.readerStopped = true
            let c = state.notificationContinuation
            state.notificationContinuation = nil
            state.notificationConsumer = nil
            return c
        }
        priorContinuation?.finish()
        // Close the inbound handle so the synchronous `read()` in
        // `runReaderSync` returns EOF and the reader queue's iteration
        // exits. Without this the reader holds a cooperative thread
        // indefinitely (Swift Testing waits on all live tasks before
        // completing).
        try? inbound.close()
        // Fail every pending continuation so callers don't hang.
        let snapshot = pendingLock.withLock { pending -> [RPCId: CheckedContinuation<Data, Error>] in
            let s = pending
            pending.removeAll()
            return s
        }
        for (_, cont) in snapshot {
            cont.resume(throwing: RPCClientError.connectionClosed)
        }
        // Resolve any pending handshake awaiter with `connectionClosed`
        // so a `start()` → `stop()` race never leaves a Task suspended.
        resolveHandshake(.failure(RPCClientError.connectionClosed))
    }

    // MARK: - Notification handler registry

    /// Register a typed notification handler. Decodes `RPCNotification<P>`
    /// from the wire and forwards `params` to the closure.
    public func registerNotificationHandler<P: Codable & Sendable & Equatable>(
        method: String,
        as paramsType: P.Type = P.self,
        _ handler: @escaping @Sendable (P) async -> Void
    ) {
        let raw: NotificationHandler = { data in
            do {
                let env = try JSONDecoder().decode(RPCNotification<P>.self, from: data)
                await handler(env.params)
            } catch {
                FileHandle.standardError.write(
                    Data("[rpc] failed to decode notification \(method): \(error)\n".utf8)
                )
            }
        }
        handlerRegistry.withLock { $0.notifications[method] = raw }
    }

    // MARK: - Inbound request handler registry
    //
    // Per docs/designs/rpc-protocol.md §"computerUse.*". Each typed handler
    // decodes `RPCRequest<P>`, runs the kit operation, and projects the
    // result back into `RPCResponse<R>`. Errors thrown by the closure
    // become `RPCErrorResponse`s — the caller can map them onto application
    // codes via `RPCErrorAdapter`.
    public func registerRequestHandler<P: Codable & Sendable & Equatable, R: Codable & Sendable & Equatable>(
        method: String,
        as paramsType: P.Type = P.self,
        resultType: R.Type = R.self,
        _ handler: @escaping @Sendable (P) async throws -> R
    ) {
        let raw: RequestHandler = { data in
            // Decode the request envelope so we can pin the response id.
            // Failure here is wire corruption — fall back to invalidRequest
            // so the sidecar isn't left waiting on a continuation.
            let decoder = JSONDecoder()
            do {
                let req = try decoder.decode(RPCRequest<P>.self, from: data)
                do {
                    let result = try await handler(req.params)
                    let resp = RPCResponse(id: req.id, result: result)
                    return Self.guardedResponseLine(resp, id: req.id, method: method)
                } catch let throwable as RPCErrorThrowable {
                    let err = RPCErrorResponse(id: req.id, error: throwable.rpcError)
                    return Self.guardedResponseLine(err, id: req.id, method: method)
                } catch {
                    let err = RPCErrorResponse(
                        id: req.id,
                        error: RPCError(
                            code: RPCErrorCode.internalError,
                            message: "\(error)"
                        )
                    )
                    return Self.guardedResponseLine(err, id: req.id, method: method)
                }
            } catch {
                // Try to recover the request id so the sidecar continuation
                // is freed even on decode failure.
                if let probe = try? decoder.decode(Probe.self, from: data),
                   let id = probe.id
                {
                    let err = RPCErrorResponse(
                        id: id,
                        error: RPCError(
                            code: RPCErrorCode.invalidParams,
                            message: "failed to decode params for \(method): \(error)"
                        )
                    )
                    return try? Self.encodeLine(err)
                }
                return nil
            }
        }
        handlerRegistry.withLock { $0.requests[method] = raw }
    }

    // MARK: - Outbound: typed request

    /// Send a request and await the typed result. Per-method timeout pulled
    /// from `timeout(forMethod:)` (see rpc-protocol.md timeout table).
    public func request<P: Codable & Sendable & Equatable, R: Codable & Sendable & Equatable>(
        method: String,
        params: P,
        as resultType: R.Type = R.self,
        timeout: TimeInterval? = nil
    ) async throws -> R {
        let id = RPCId.string(UUID().uuidString)
        let envelope = RPCRequest(id: id, method: method, params: params)
        let line = try Self.encodeLine(envelope)

        // Outbound size guard against the sidecar's MAX_LINE_BYTES cap (see
        // sidecar/src/rpc/transport.ts). The sidecar treats any inbound line
        // > 2 MiB as fatal and closes the channel, which would crash the
        // agent loop mid-conversation. Reject *before* registering pending
        // or writing any bytes so the caller gets a clean typed error and
        // the transport stays healthy.
        if line.count > Self.maxLineBytes {
            throw RPCClientError.outboundPayloadTooLarge(
                method: method,
                bytes: line.count,
                limit: Self.maxLineBytes
            )
        }

        let resolvedTimeout = timeout ?? Self.timeout(forMethod: method)

        // Hoist the timeout Task so the success path cancels it instead of
        // letting it sleep for the full window. Without this, every
        // successful request leaks one sleeping detached Task per the full
        // timeout window — at the streaming notification rate this
        // accumulates fast.
        var timeoutTask: Task<Void, Never>?
        defer { timeoutTask?.cancel() }

        let data: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pendingLock.withLock { $0[id] = cont }

            timeoutTask = Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(resolvedTimeout))
                guard !Task.isCancelled, let self else { return }
                let waiting = self.removePending(id)
                waiting?.resume(throwing: RPCClientError.timeout(method: method))
            }

            self.write(line: line)
        }

        // Decode RPCResponse<R> or RPCErrorResponse.
        if let resp = try? JSONDecoder().decode(RPCResponse<R>.self, from: data) {
            return resp.result
        }
        if let err = try? JSONDecoder().decode(RPCErrorResponse.self, from: data) {
            throw RPCClientError.server(err.error)
        }
        throw RPCClientError.malformed("response did not match RPCResponse<\(R.self)> or RPCErrorResponse")
    }

    /// Convenience wrapper for `rpc.ping`.
    public func ping() async throws {
        _ = try await request(
            method: RPCMethod.rpcPing,
            params: PingParams(),
            as: PingResult.self
        )
    }

    /// Validate the version returned by the sidecar's `rpc.hello`. Per
    /// rpc-protocol.md §"版本协商": MAJOR mismatch ⇒ throw + caller terminates
    /// the sidecar; MINOR/PATCH mismatch ⇒ logged but accepted.
    ///
    /// Note: per design, `rpc.hello` is initiated by the SIDECAR (Bun) as its
    /// first message. This Shell-side `handshake()` therefore *waits* for an
    /// inbound `rpc.hello` Request and replies, rather than sending one.
    /// The sidecar wave is being built by a parallel agent — when their
    /// dispatcher calls `rpc.hello`, the request handler path takes over.
    /// For this round we expose a simpler `awaitHandshake(timeout:)` that
    /// suspends until the first valid `rpc.hello` Request has been observed
    /// and replied to.
    public func awaitHandshake(timeout: TimeInterval = 5) async throws -> HelloResult {
        // Race the suspended handshake gate against a timeout Task. The
        // suspended path returns as soon as `resolveHandshake(_:)` is
        // called from the inbound dispatcher; the timeout path throws
        // `RPCClientError.timeout` if the sidecar never sends `rpc.hello`.
        // Either path cancels the other on completion.
        return try await withThrowingTaskGroup(of: HelloResult.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw RPCClientError.connectionClosed }
                return try await self.suspendForHandshake()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw RPCClientError.timeout(method: RPCMethod.rpcHello)
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Suspend on the handshake gate. Returns immediately if the sidecar
    /// already sent `rpc.hello`; otherwise registers a continuation
    /// resolved by `resolveHandshake(_:)` from the inbound dispatcher.
    ///
    /// Wrapped in `withTaskCancellationHandler` so that when the parent
    /// task group cancels this child (e.g. timeout sibling threw), the
    /// stored continuation gets actively resumed with `CancellationError`.
    /// Plain `withCheckedThrowingContinuation` is NOT cancellation-aware —
    /// the cont stays suspended forever, the cancelled child task never
    /// completes, and `withThrowingTaskGroup` waits indefinitely for it.
    /// Without this handler, `awaitHandshake()`'s timeout path hangs the
    /// caller (Shell startup) instead of throwing.
    private func suspendForHandshake() async throws -> HelloResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HelloResult, Error>) in
                handshakeState.withLock { state in
                    if let result = state.result {
                        cont.resume(returning: result)
                        return
                    }
                    if let failed = state.failure {
                        cont.resume(throwing: failed)
                        return
                    }
                    // Two concurrent awaiters would be a programmer error;
                    // resolve the prior one with cancellation so it surfaces
                    // rather than silently leaking.
                    if let prior = state.continuation {
                        prior.resume(throwing: CancellationError())
                    }
                    state.continuation = cont
                }
            }
        } onCancel: {
            // Pull the stored cont out under the lock and resume it so
            // the awaiting task actually unblocks. Safe to no-op if
            // `resolveHandshake(_:)` already raced ahead and consumed it.
            let pending: CheckedContinuation<HelloResult, Error>? = handshakeState.withLock { state in
                let c = state.continuation
                state.continuation = nil
                return c
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    /// Called from the inbound-request dispatcher when the sidecar's
    /// `rpc.hello` has been observed and answered (success) — or rejected
    /// for MAJOR-version mismatch (failure). Caches the outcome so any
    /// later `awaitHandshake()` returns synchronously, and resolves any
    /// already-suspended awaiter.
    private func resolveHandshake(_ outcome: Result<HelloResult, Error>) {
        let pending: CheckedContinuation<HelloResult, Error>? = handshakeState.withLock { state in
            switch outcome {
            case .success(let r):
                state.result = r
                state.failure = nil
            case .failure(let e):
                state.failure = e
                state.result = nil
            }
            let c = state.continuation
            state.continuation = nil
            return c
        }
        if let pending {
            switch outcome {
            case .success(let r): pending.resume(returning: r)
            case .failure(let e): pending.resume(throwing: e)
            }
        }
    }

    private struct HandshakeState {
        var result: HelloResult?
        var failure: Error?
        var continuation: CheckedContinuation<HelloResult, Error>?
    }
    private let handshakeState = OSAllocatedUnfairLock<HandshakeState>(initialState: HandshakeState())

    // MARK: - Outbound writer

    private func write(line: Data) {
        writeQueue.sync {
            do {
                try outbound.write(contentsOf: line)
                try outbound.write(contentsOf: Data([0x0A]))
            } catch {
                FileHandle.standardError.write(
                    Data("[rpc] write failure: \(error)\n".utf8)
                )
            }
        }
    }

    private static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        // Canonical encoder shared with the fixture roundtrip tests so the
        // wire bytes the Shell actually emits are the same bytes the
        // conformance harness pins. See `AOSRPCSchema/CanonicalEncoder.swift`.
        try CanonicalJSON.encode(value)
    }

    /// Encode an inbound-request response and reject anything over the
    /// `maxLineBytes` cap. Mirror of the outbound `outboundPayloadTooLarge`
    /// guard in `request(...)`: the sidecar treats any inbound NDJSON line
    /// > 2 MiB as fatal and closes the channel, which would crash the agent
    /// loop mid-conversation. A getAppState response (screenshot + AX tree)
    /// is the only realistic way to hit this in production, but the screenshot
    /// payload cap (`ScreenshotPayloadPolicy.defaultRawByteBudget`, 700KB raw
    /// ≈ 1MB base64) plus the AX tree node cap (`maxRenderedNodes = 2000`)
    /// can in pathological cases still combine past 2 MiB. Defending the
    /// boundary here so any new oversize source can't take down the channel.
    ///
    /// On overflow we substitute a `payloadTooLarge` error response keyed to
    /// the same id so the sidecar continuation gets resolved (no hang) and
    /// the agent treats the call as a recoverable failure (per
    /// `isRecoverableComputerUseError` in `sidecar/.../computer-use.ts`).
    private static func guardedResponseLine<T: Encodable>(
        _ value: T,
        id: RPCId,
        method: String
    ) -> Data? {
        guard let line = try? Self.encodeLine(value) else { return nil }
        if line.count <= Self.maxLineBytes { return line }
        FileHandle.standardError.write(
            Data("[rpc] inbound response for '\(method)' is \(line.count) bytes (> \(Self.maxLineBytes)); substituting payloadTooLarge\n".utf8)
        )
        let fallback = RPCErrorResponse(
            id: id,
            error: RPCError(
                code: RPCErrorCode.payloadTooLarge,
                message: "response for '\(method)' exceeds \(Self.maxLineBytes)-byte NDJSON line cap",
                data: .object([
                    "bytes": .int(line.count),
                    "limit": .int(Self.maxLineBytes),
                    "method": .string(method),
                ])
            )
        )
        return try? Self.encodeLine(fallback)
    }

    // MARK: - Reader loop

    private func runReaderSync() {
        var buffer = Data()
        while !lifecycle.withLock({ $0.readerStopped }) {
            // Use raw POSIX read(2) on the underlying fd. Foundation's
            // `FileHandle.read(upToCount:)` on a Pipe sometimes coalesces
            // multiple kernel reads and only returns once a larger threshold
            // is met, which makes interactive line-delimited protocols
            // (NDJSON over stdio) appear to stall.
            let fd = inbound.fileDescriptor
            var scratch = [UInt8](repeating: 0, count: 64 * 1024)
            let n = scratch.withUnsafeMutableBufferPointer { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n == 0 {
                // EOF — sidecar exited or pipe closed.
                break
            }
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            let chunk = Data(scratch.prefix(n))
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineRange = buffer.startIndex..<nl
                let line = buffer.subdata(in: lineRange)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.count > Self.maxLineBytes {
                    FileHandle.standardError.write(
                        Data("[rpc] oversized NDJSON line; aborting reader\n".utf8)
                    )
                    failAllPending(RPCClientError.payloadTooLarge)
                    return
                }
                if line.isEmpty { continue }
                handle(line: line)
            }
            if buffer.count > Self.maxLineBytes {
                FileHandle.standardError.write(
                    Data("[rpc] oversized NDJSON buffer (no newline); aborting\n".utf8)
                )
                failAllPending(RPCClientError.payloadTooLarge)
                return
            }
        }
        failAllPending(RPCClientError.connectionClosed)
    }

    private func failAllPending(_ error: Error) {
        let snapshot = pendingLock.withLock { pending -> [RPCId: CheckedContinuation<Data, Error>] in
            let s = pending
            pending.removeAll()
            return s
        }
        for (_, cont) in snapshot {
            cont.resume(throwing: error)
        }
    }

    /// Dispatch a single decoded NDJSON line. Distinguishes Response /
    /// ErrorResponse / Notification / Request by which JSON-RPC fields are
    /// present.
    private func handle(line: Data) {
        // Peek at the structure cheaply by decoding into Probe.
        guard let probe = try? JSONDecoder().decode(Probe.self, from: line) else {
            FileHandle.standardError.write(
                Data("[rpc] dropping unparseable line\n".utf8)
            )
            return
        }
        if probe.id != nil, probe.method == nil {
            // It's a Response (success or error) — resolve pending continuation.
            guard let id = probe.id else { return }
            let cont = pendingLock.withLock { $0.removeValue(forKey: id) }
            cont?.resume(returning: line)
            return
        }
        if let method = probe.method, probe.id == nil {
            // Notification.
            let handler = handlerRegistry.withLock { $0.notifications[method] }
            if let handler {
                // Hand off to the serial consumer so handlers run in arrival
                // order. Critical for streaming `ui.token` deltas: detached
                // tasks would let two deltas race the MainActor and append
                // out of order.
                let continuation = lifecycle.withLock { $0.notificationContinuation }
                continuation?.yield { await handler(line) }
            }
            return
        }
        if let method = probe.method, probe.id != nil {
            // Request from peer. Stage 0 only handles `rpc.hello`; everything
            // else is replied to with MethodNotFound so a misbehaving sidecar
            // doesn't deadlock.
            Task.detached { [weak self] in
                await self?.handleInboundRequest(line: line, method: method)
            }
            return
        }
    }

    private struct Probe: Decodable {
        let jsonrpc: String?
        let id: RPCId?
        let method: String?
    }

    private func handleInboundRequest(line: Data, method: String) async {
        if method == RPCMethod.rpcHello {
            do {
                let req = try JSONDecoder().decode(RPCRequest<HelloParams>.self, from: line)
                let major = Self.majorVersion(req.params.protocolVersion)
                let localMajor = Self.majorVersion(aosProtocolVersion)
                if major != localMajor {
                    let err = RPCErrorResponse(
                        id: req.id,
                        error: RPCError(
                            code: RPCErrorCode.invalidRequest,
                            message: "protocol MAJOR mismatch: remote=\(req.params.protocolVersion) local=\(aosProtocolVersion)"
                        )
                    )
                    if let data = try? Self.encodeLine(err) { write(line: data) }
                    resolveHandshake(.failure(RPCClientError.protocolMajorMismatch(
                        remote: req.params.protocolVersion,
                        local: aosProtocolVersion
                    )))
                    return
                }
                let result = HelloResult(
                    protocolVersion: aosProtocolVersion,
                    serverInfo: ServerInfo(name: "aos-shell", version: aosProtocolVersion)
                )
                let resp = RPCResponse(id: req.id, result: result)
                if let data = try? Self.encodeLine(resp) { write(line: data) }
                resolveHandshake(.success(result))
            } catch {
                FileHandle.standardError.write(
                    Data("[rpc] failed to decode rpc.hello: \(error)\n".utf8)
                )
            }
            return
        }
        // Try registered request handlers (computerUse.* live here). Each
        // handler runs in this detached Task so concurrent inbound
        // requests don't serialise behind one another — per
        // docs/designs/rpc-protocol.md §"Dispatcher 并发模型".
        let handler = handlerRegistry.withLock { $0.requests[method] }
        if let handler {
            if let response = await handler(line) {
                write(line: response)
            }
            return
        }
        // No registered handler — reply MethodNotFound so the sidecar
        // isn't stuck waiting on a continuation.
        if let probe = try? JSONDecoder().decode(Probe.self, from: line), let id = probe.id {
            let err = RPCErrorResponse(
                id: id,
                error: RPCError(
                    code: RPCErrorCode.methodNotFound,
                    message: "method not found: \(method)"
                )
            )
            if let data = try? Self.encodeLine(err) { write(line: data) }
        }
    }

    // MARK: - Utilities

    private func removePending(_ id: RPCId) -> CheckedContinuation<Data, Error>? {
        pendingLock.withLock { $0.removeValue(forKey: id) }
    }

    /// Per-method timeouts from rpc-protocol.md "Dispatcher 并发模型" table.
    /// Methods not listed default to 5s.
    public static func timeout(forMethod method: String) -> TimeInterval {
        switch method {
        case RPCMethod.rpcPing: return 1
        case RPCMethod.agentSubmit, RPCMethod.agentCancel: return 1
        case RPCMethod.rpcHello: return 5
        default: return 5
        }
    }

    /// Parse the MAJOR component of a "MAJOR.MINOR.PATCH" string. Used by the
    /// handshake. Non-conforming inputs return `0`, ensuring a mismatch with
    /// any well-formed peer (i.e. fail fast).
    public static func majorVersion(_ s: String) -> Int {
        let parts = s.split(separator: ".")
        guard let first = parts.first, let n = Int(first) else { return 0 }
        return n
    }
}
