import Testing
import Foundation
@testable import AOSShell
@testable import AOSRPCSchema

// MARK: - RPCClientCodecTests
//
// Exercise the RPCClient over an in-process pipe pair. We feed canonical
// NDJSON frames into the inbound pipe and assert the client correctly:
//   - completes a typed `request(...)` with a matching `RPCResponse`
//   - throws `RPCClientError.server` for an `RPCErrorResponse`
//   - dispatches notifications to registered handlers
//   - errors out on `payloadTooLarge` for >2MB single lines
//   - rejects MAJOR mismatch in awaitHandshake() via the inbound rpc.hello path

@Suite("RPCClient NDJSON codec", .serialized)
struct RPCClientCodecTests {

    /// Make an RPCClient backed by two pipes. We write to `serverToClient.write`
    /// to deliver inbound frames, and read from `clientToServer.read` to
    /// inspect what the client sent. The server-side read end is set to
    /// O_NONBLOCK so polling reads in tests don't pin the async executor.
    private func makeClient() -> (
        client: RPCClient,
        serverWrite: FileHandle,
        serverRead: FileHandle
    ) {
        let inbound = Pipe()   // server → client
        let outbound = Pipe()  // client → server
        let client = RPCClient(
            inbound: inbound.fileHandleForReading,
            outbound: outbound.fileHandleForWriting
        )
        client.start()
        // Make the read side non-blocking.
        let fd = outbound.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return (
            client: client,
            serverWrite: inbound.fileHandleForWriting,
            serverRead: outbound.fileHandleForReading
        )
    }

    private func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var data = try enc.encode(value)
        data.append(0x0A)
        return data
    }

    @Test("notification handler is invoked with decoded params")
    func notificationDispatch() async throws {
        let (client, serverWrite, _) = makeClient()
        defer { client.stop() }

        let received = Lock<UITokenParams?>(nil)
        client.registerNotificationHandler(method: RPCMethod.uiToken) { (params: UITokenParams) in
            received.set(params)
        }

        let notif = RPCNotification(
            method: RPCMethod.uiToken,
            params: UITokenParams(sessionId: "S", turnId: "T1", delta: "hello")
        )
        try serverWrite.write(contentsOf: encodeLine(notif))

        // Poll for the handler to fire.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if received.get() != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let got = received.get()
        #expect(got?.turnId == "T1")
        #expect(got?.delta == "hello")
    }

    @Test("notifications are delivered to handlers in wire arrival order")
    func notificationOrderingPreservedAcrossHandlerSuspensions() async throws {
        // Regression test for the streaming-token race: when each notification
        // was dispatched into its own `Task.detached`, multiple `ui.token`
        // deltas raced and the MainActor handler appended them out of order
        // (e.g. wire "Hi", "! How" landed in the reply as "! HowHi").
        //
        // The old implementation passes `notificationDispatch` (one delta in,
        // one delta out) but fails here as soon as the handler suspends a few
        // times mid-way: the detached tasks for later deltas leapfrog the
        // earlier ones during the yields. The current single-consumer
        // implementation `await`s each handler before pulling the next item,
        // so order is preserved regardless of internal suspensions.
        let (client, serverWrite, _) = makeClient()
        defer { client.stop() }

        let n = 50
        let collected = Lock<[String]>([])
        client.registerNotificationHandler(method: RPCMethod.uiToken) { (params: UITokenParams) in
            // Several explicit yields so the cooperative scheduler has real
            // chances to interleave concurrent handlers in the broken
            // implementation. Without these, even detached tasks may finish
            // before the next notification is parsed and look ordered by luck.
            for _ in 0..<5 { await Task.yield() }
            var current = collected.get()
            current.append(params.delta)
            collected.set(current)
        }

        // Fire the notifications back-to-back. Deltas are zero-padded so a
        // simple lexicographic compare matches the numeric order — easier to
        // eyeball in failure output than raw integers.
        for i in 0..<n {
            let delta = String(format: "%03d", i)
            let notif = RPCNotification(
                method: RPCMethod.uiToken,
                params: UITokenParams(sessionId: "S", turnId: "T1", delta: delta)
            )
            try serverWrite.write(contentsOf: encodeLine(notif))
        }

        // Poll until all deltas are collected (or fail the test if we time out).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if collected.get().count == n { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let got = collected.get()
        #expect(got.count == n)
        let expected = (0..<n).map { String(format: "%03d", $0) }
        #expect(got == expected)
    }

    @Test("typed request resolves on matching response id")
    func requestResolvesOnResponse() async throws {
        let (client, serverWrite, serverRead) = makeClient()
        defer { client.stop() }

        // Spawn the request in the background.
        let task = Task {
            try await client.request(
                method: RPCMethod.rpcPing,
                params: PingParams(),
                as: PingResult.self
            )
        }

        // Read what the client sent so we can echo the same id back.
        let outboundFrame = try await readOneLine(from: serverRead, timeout: 2)
        let probe = try JSONDecoder().decode(SentRequestProbe.self, from: outboundFrame)
        let response = RPCResponse(id: probe.id, result: PingResult())
        try serverWrite.write(contentsOf: encodeLine(response))

        _ = try await task.value
    }

    @Test("server error envelope surfaces as RPCClientError.server")
    func serverErrorMaps() async throws {
        let (client, serverWrite, serverRead) = makeClient()
        defer { client.stop() }

        let task = Task { () -> Result<PingResult, Error> in
            do {
                let r = try await client.request(
                    method: RPCMethod.rpcPing,
                    params: PingParams(),
                    as: PingResult.self
                )
                return .success(r)
            } catch {
                return .failure(error)
            }
        }

        let frame = try await readOneLine(from: serverRead, timeout: 2)
        let probe = try JSONDecoder().decode(SentRequestProbe.self, from: frame)
        let err = RPCErrorResponse(
            id: probe.id,
            error: RPCError(code: RPCErrorCode.permissionDenied, message: "no auth")
        )
        try serverWrite.write(contentsOf: encodeLine(err))

        let result = await task.value
        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(let error):
            guard case let RPCClientError.server(serverErr) = error else {
                Issue.record("expected .server error, got \(error)")
                return
            }
            #expect(serverErr.code == RPCErrorCode.permissionDenied)
        }
    }

    @Test("outbound request exceeding the 2 MiB line cap is rejected before any byte is written")
    func outboundOversizeRejected() async throws {
        let (client, _, serverRead) = makeClient()
        defer { client.stop() }

        // 3 MiB ASCII prompt — well past the 2 MiB MAX_LINE_BYTES cap that
        // both the local encoder and the sidecar transport enforce. Pure
        // ASCII so the encoded JSON length tracks the raw character count
        // (no surprise expansion that would let a smaller string also
        // overflow and confuse the assertion).
        let huge = String(repeating: "x", count: 3 * 1024 * 1024)
        let params = AgentSubmitParams(
            sessionId: "S",
            turnId: "T1",
            prompt: huge,
            citedContext: CitedContext()
        )

        do {
            _ = try await client.request(
                method: RPCMethod.agentSubmit,
                params: params,
                as: AgentSubmitResult.self,
                timeout: 0.2
            )
            Issue.record("expected outboundPayloadTooLarge to throw")
        } catch let RPCClientError.outboundPayloadTooLarge(method, bytes, limit) {
            #expect(method == RPCMethod.agentSubmit)
            #expect(bytes > limit)
            #expect(limit == 2 * 1024 * 1024)
        } catch {
            Issue.record("expected outboundPayloadTooLarge, got \(error)")
        }

        // Nothing should have hit the wire — the guard runs before write().
        // Poll briefly to make sure no deferred write sneaks in.
        try await Task.sleep(for: .milliseconds(100))
        let fd = serverRead.fileDescriptor
        var scratch = [UInt8](repeating: 0, count: 64)
        let n = scratch.withUnsafeMutableBufferPointer { ptr in
            read(fd, ptr.baseAddress, ptr.count)
        }
        // Non-blocking fd: -1 with EAGAIN means no bytes available, which is
        // exactly what we want. A positive n would mean the guard leaked
        // a write past the size check.
        #expect(n <= 0)
    }

    @Test("majorVersion parses the leading integer")
    func majorVersionParse() {
        #expect(RPCClient.majorVersion("1.2.3") == 1)
        #expect(RPCClient.majorVersion("2.0.0") == 2)
        #expect(RPCClient.majorVersion("garbage") == 0)
    }

    @Test("rpc.hello inbound with MAJOR mismatch surfaces protocolMajorMismatch")
    func handshakeMajorMismatch() async throws {
        let (client, serverWrite, serverRead) = makeClient()
        defer { client.stop() }

        // Send a hello with MAJOR = 99 (our local is "2.0.0").
        let req = RPCRequest(
            id: .string("hello-1"),
            method: RPCMethod.rpcHello,
            params: HelloParams(
                protocolVersion: "99.0.0",
                clientInfo: ClientInfo(name: "fake", version: "0")
            )
        )
        try serverWrite.write(contentsOf: encodeLine(req))

        // Client should reply with an invalidRequest error envelope AND
        // surface a typed `protocolMajorMismatch` to the caller. The
        // earlier polling-handshake implementation used to time out
        // silently; the continuation-based gate now resolves the awaiter
        // with the actionable mismatch error so the UI can show "please
        // update" instead of "no response".
        do {
            _ = try await client.awaitHandshake(timeout: 2.0)
            Issue.record("expected protocolMajorMismatch for MAJOR mismatch")
        } catch RPCClientError.protocolMajorMismatch(let remote, let local) {
            #expect(remote == "99.0.0")
            #expect(local == aosProtocolVersion)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // Inspect what the client wrote back: should be an error envelope
        // with code invalidRequest.
        let response = try await readOneLine(from: serverRead, timeout: 2)
        let errResp = try JSONDecoder().decode(RPCErrorResponse.self, from: response)
        #expect(errResp.error.code == RPCErrorCode.invalidRequest)
    }

    @Test("awaitHandshake resolves on matching protocol version with no polling delay")
    func handshakeMatchingVersionResolves() async throws {
        // NB: Retain `serverRead` for the lifetime of the test even if we
        // don't read from it — the handshake handler writes the success
        // response onto `outbound`, and dropping the read end of that
        // pipe via `_` would close it and SIGPIPE the writer.
        let (client, serverWrite, serverRead) = makeClient()
        _ = serverRead
        defer { client.stop() }

        let req = RPCRequest(
            id: .string("hello-ok"),
            method: RPCMethod.rpcHello,
            params: HelloParams(
                protocolVersion: aosProtocolVersion,
                clientInfo: ClientInfo(name: "fake", version: "0")
            )
        )
        try serverWrite.write(contentsOf: encodeLine(req))

        let result = try await client.awaitHandshake(timeout: 2.0)
        #expect(result.protocolVersion == aosProtocolVersion)
    }

    @Test("oversized inbound NDJSON line aborts the reader and fails pending requests")
    func oversizedInboundLineAbortsReader() async throws {
        // The reader's 2 MiB single-line cap is what protects the Shell from
        // a misbehaving sidecar (a runaway tool result, or a corrupted
        // frame that never terminates). When it trips, every pending
        // request must surface `payloadTooLarge` instead of hanging — the
        // reader has decided the channel is unusable.
        //
        // Retain `serverRead` for the test's lifetime: the client may write
        // an outbound frame (e.g. while the request was registering) and
        // dropping the read end via `_` would close it and SIGPIPE the
        // writer.
        let (client, serverWrite, serverRead) = makeClient()
        _ = serverRead
        defer { client.stop() }

        // Spawn an in-flight request first so the abort path has a
        // continuation to fail.
        let task = Task { () -> Result<PingResult, Error> in
            do {
                let r = try await client.request(
                    method: RPCMethod.rpcPing,
                    params: PingParams(),
                    as: PingResult.self,
                    timeout: 5
                )
                return .success(r)
            } catch {
                return .failure(error)
            }
        }

        // Brief yield so the request registers its pending continuation
        // before we fire the oversize frame.
        try await Task.sleep(for: .milliseconds(50))

        // Write exactly 2 MiB + 1 bytes with no embedded newline. The
        // payload size matters: macOS pipe buffers cap around 64 KiB and
        // the reader stops draining the moment its accumulator passes
        // the cap. With a much larger payload (e.g. 3 MiB) the writer
        // would hang on a kernel pipe full of un-drainable bytes — and
        // even on a detached Task the eventual close()→SIGPIPE crashes
        // the whole test process. 2 MiB + 1 is the minimum that trips
        // the guard, and by the time the reader trips the writer has
        // already handed off all bytes to the kernel buffer (no
        // post-trip writes remain).
        let oversized = Data(repeating: 0x78 /* 'x' */, count: 2 * 1024 * 1024 + 1)
        try serverWrite.write(contentsOf: oversized)

        let result = await task.value
        switch result {
        case .success:
            Issue.record("expected oversized inbound to surface payloadTooLarge or connectionClosed")
        case .failure(let error):
            // Either is acceptable: payloadTooLarge if the reader trips
            // the size guard before EOF, connectionClosed if the abort
            // closes the pipe before the size check fires (e.g. on a
            // particularly fast scheduler).
            switch error {
            case RPCClientError.payloadTooLarge, RPCClientError.connectionClosed:
                break
            default:
                Issue.record("expected payloadTooLarge or connectionClosed, got \(error)")
            }
        }
    }

    @Test("stop() resolves all pending request continuations with connectionClosed")
    func stopFailsPendingRequests() async throws {
        // Retain both pipe ends — see the comment on
        // `oversizedInboundLineAbortsReader`. Even on the stop() path,
        // failAllPending could log via stderr and we want the writer side
        // to stay valid until the test's defer runs.
        let (client, serverWrite, serverRead) = makeClient()
        _ = serverWrite
        _ = serverRead

        // Start two requests so we exercise the bulk-fail path and not just
        // the single-pending case.
        async let a: Result<PingResult, Error> = {
            do {
                return .success(try await client.request(
                    method: RPCMethod.rpcPing,
                    params: PingParams(),
                    as: PingResult.self,
                    timeout: 5
                ))
            } catch {
                return .failure(error)
            }
        }()
        async let b: Result<PingResult, Error> = {
            do {
                return .success(try await client.request(
                    method: RPCMethod.rpcPing,
                    params: PingParams(),
                    as: PingResult.self,
                    timeout: 5
                ))
            } catch {
                return .failure(error)
            }
        }()

        // Both requests register their continuations before stop() runs.
        try await Task.sleep(for: .milliseconds(50))
        client.stop()

        let (resA, resB) = await (a, b)
        for result in [resA, resB] {
            switch result {
            case .success:
                Issue.record("expected stop() to fail pending request")
            case .failure(let error):
                guard case RPCClientError.connectionClosed = error else {
                    Issue.record("expected connectionClosed, got \(error)")
                    continue
                }
            }
        }
    }

    @Test("awaitHandshake returns immediately when rpc.hello arrived before the awaiter")
    func handshakeAlreadyResolvedFastPath() async throws {
        // The polling-handshake implementation could miss an `rpc.hello`
        // that landed during a 50 ms sleep slice; the continuation gate
        // makes early arrivals stable. Land the inbound hello first,
        // wait long enough for the dispatcher to ingest it, then await
        // — it must resolve synchronously without any timeout race.
        let (client, serverWrite, serverRead) = makeClient()
        _ = serverRead // hold the read end so the handshake response write doesn't SIGPIPE
        defer { client.stop() }

        let req = RPCRequest(
            id: .string("hello-fast"),
            method: RPCMethod.rpcHello,
            params: HelloParams(
                protocolVersion: aosProtocolVersion,
                clientInfo: ClientInfo(name: "fake", version: "0")
            )
        )
        try serverWrite.write(contentsOf: encodeLine(req))

        // Give the reader queue time to ingest + dispatch the hello.
        // 200 ms is generous; the handshake fully resolves in ≤10 ms in
        // practice on a quiet CI box.
        try await Task.sleep(for: .milliseconds(200))

        // Tight 100 ms timeout: the polling implementation would have
        // missed the arrival and timed out; the continuation gate caches
        // the result and returns it without sleeping.
        let result = try await client.awaitHandshake(timeout: 0.1)
        #expect(result.protocolVersion == aosProtocolVersion)
    }

    @Test("awaitHandshake throws timeout (and does not hang) when sidecar never sends rpc.hello")
    func handshakeTimeoutWhenNoHelloEverArrives() async throws {
        // The bug this guards against: `awaitHandshake` runs `suspendForHandshake`
        // and a timeout sibling inside `withThrowingTaskGroup`. Cancellation does
        // NOT auto-resume `withCheckedThrowingContinuation`, so without a
        // cancellation handler the suspended child task never finishes and the
        // group's implicit "wait for all children" stalls forever — the timeout
        // path silently hangs the caller (Shell startup) instead of throwing.
        //
        // The fix wraps `suspendForHandshake` in `withTaskCancellationHandler`
        // that pulls the stored continuation out and resumes it with
        // `CancellationError`. This test fails (hangs past `Task.sleep`) on the
        // unfixed code and completes within the timeout window on the fixed
        // code.
        let (client, _, serverRead) = makeClient()
        _ = serverRead
        defer { client.stop() }

        // Wall-clock guard: if `awaitHandshake` ever does hang, this Task
        // ensures the test fails loudly within a bounded window instead of
        // hanging the whole suite.
        let start = Date()
        do {
            _ = try await client.awaitHandshake(timeout: 0.3)
            Issue.record("awaitHandshake should have thrown timeout when no rpc.hello ever arrived")
        } catch RPCClientError.timeout(let method) {
            #expect(method == RPCMethod.rpcHello)
        } catch {
            Issue.record("expected RPCClientError.timeout, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        // Generous bound: timeout is 0.3s, allow scheduling slack but reject
        // anything in "hung" territory.
        #expect(elapsed < 2.0, "awaitHandshake took \(elapsed)s; expected ~0.3s")
    }

    // MARK: - Helpers

    private struct SentRequestProbe: Decodable {
        let id: RPCId
        let method: String
    }

    /// Read a single newline-terminated frame from a non-blocking fd, waiting
    /// up to `timeout`s. Uses raw `read(2)` so EAGAIN can be polled cleanly.
    private func readOneLine(from handle: FileHandle, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        let fd = handle.fileDescriptor
        var scratch = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            if let nl = buffer.firstIndex(of: 0x0A) {
                return buffer.subdata(in: buffer.startIndex..<nl)
            }
            let n = scratch.withUnsafeMutableBufferPointer { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                buffer.append(scratch, count: n)
                continue
            }
            if n == 0 {
                throw RPCClientError.connectionClosed
            }
            // n < 0: EAGAIN expected on non-blocking fd. Sleep + retry.
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RPCClientError.timeout(method: "test:readOneLine")
    }
}

// Tiny thread-safe box for cross-Task assertions inside tests.
final class Lock<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ initial: T) { value = initial }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
