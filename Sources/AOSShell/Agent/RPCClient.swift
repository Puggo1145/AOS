import Foundation
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
    /// Initial handshake produced a non-decodable result.
    case malformed(String)
}

/// Read-only view onto inbound notifications. Handlers receive raw `Data` of
/// the `params` value and decode it themselves; the reader stays generic.
public typealias NotificationHandler = @Sendable (Data) async -> Void

public final class RPCClient: @unchecked Sendable {
    private let inbound: FileHandle
    private let outbound: FileHandle

    /// Pending request continuations. Each key is the RPCId we sent.
    private var pending: [RPCId: CheckedContinuation<Data, Error>] = [:]
    private let pendingLock = NSLock()

    /// Notification handlers keyed by method name. Handlers are invoked in
    /// detached Tasks so they don't block the reader.
    private var notificationHandlers: [String: NotificationHandler] = [:]
    private let handlersLock = NSLock()

    private let writeQueue = DispatchQueue(label: "aos.rpc.write")
    private var readerStopped = false

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
        readerStopped = false
        let q = DispatchQueue(label: "aos.rpc.reader", qos: .utility)
        q.async { [weak self] in self?.runReaderSync() }
    }

    public func stop() {
        readerStopped = true
        // Close the inbound handle so the synchronous `read()` in runReader
        // returns EOF and the reader thread exits.
        try? inbound.close()
        // Close the inbound handle so the synchronous `read()` in runReader
        // returns EOF and the detached reader Task exits. Without this the
        // reader holds a cooperative thread indefinitely (Swift Testing
        // waits on all live tasks before completing).
        try? inbound.close()
        // Fail every pending continuation so callers don't hang.
        let snapshot: [RPCId: CheckedContinuation<Data, Error>] = {
            pendingLock.lock(); defer { pendingLock.unlock() }
            let s = pending
            pending.removeAll()
            return s
        }()
        for (_, cont) in snapshot {
            cont.resume(throwing: RPCClientError.connectionClosed)
        }
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
        handlersLock.lock()
        notificationHandlers[method] = raw
        handlersLock.unlock()
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

        let resolvedTimeout = timeout ?? Self.timeout(forMethod: method)

        let data: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            pendingLock.lock()
            pending[id] = cont
            pendingLock.unlock()

            // Schedule a timeout.
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(resolvedTimeout * 1_000_000_000))
                guard let self else { return }
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
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = handshakeResult {
                return result
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms poll
        }
        throw RPCClientError.timeout(method: RPCMethod.rpcHello)
    }

    private var handshakeResult: HelloResult?

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

    // MARK: - Reader loop

    private func runReaderSync() {
        var buffer = Data()
        while !readerStopped {
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
        pendingLock.lock()
        let snapshot = pending
        pending.removeAll()
        pendingLock.unlock()
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
            pendingLock.lock()
            let cont = pending.removeValue(forKey: id)
            pendingLock.unlock()
            cont?.resume(returning: line)
            return
        }
        if let method = probe.method, probe.id == nil {
            // Notification.
            handlersLock.lock()
            let handler = notificationHandlers[method]
            handlersLock.unlock()
            if let handler {
                Task.detached { await handler(line) }
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
                    handshakeResult = nil
                    return
                }
                let result = HelloResult(
                    protocolVersion: aosProtocolVersion,
                    serverInfo: ServerInfo(name: "aos-shell", version: aosProtocolVersion)
                )
                let resp = RPCResponse(id: req.id, result: result)
                if let data = try? Self.encodeLine(resp) { write(line: data) }
                handshakeResult = result
            } catch {
                FileHandle.standardError.write(
                    Data("[rpc] failed to decode rpc.hello: \(error)\n".utf8)
                )
            }
            return
        }
        // Any other inbound Request — reply MethodNotFound.
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
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending.removeValue(forKey: id)
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
