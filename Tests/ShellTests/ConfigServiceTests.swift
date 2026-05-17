import Foundation
import Testing
@testable import Shell
@testable import RPCSchema

@MainActor
@Suite("ConfigService")
struct ConfigServiceTests {
    @Test("markOnboardingCompleted does not flip local latch when persistence fails")
    func onboardingCompletionFailureDoesNotAdvanceLocalLatch() async throws {
        let harness = RPCServerHarness()
        let config = ConfigService(rpc: harness.client)
        harness.client.start()
        defer { harness.client.stop() }

        let server = Task {
            let line = try await harness.readRequest(timeout: 2)
            let probe = try JSONDecoder().decode(RequestProbe.self, from: line)
            #expect(probe.method == RPCMethod.configMarkOnboardingCompleted)
            let response = RPCErrorResponse(
                id: probe.id,
                error: RPCError(
                    code: RPCErrorCode.internalError,
                    message: "disk write failed"
                )
            )
            try harness.write(response)
        }

        await config.markOnboardingCompleted()
        try await server.value

        #expect(config.hasCompletedOnboarding == false)
        #expect(config.lastError?.contains("disk write failed") == true)
    }
}

private final class RPCServerHarness: @unchecked Sendable {
    let client: RPCClient
    private let serverToClient: Pipe
    private let clientToServer: Pipe

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

    func readRequest(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        let fd = clientToServer.fileHandleForReading.fileDescriptor
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
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RPCClientError.timeout(method: "test:readRequest")
    }

    func write<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try serverToClient.fileHandleForWriting.write(contentsOf: data)
    }
}

private struct RequestProbe: Decodable {
    let id: RPCId
    let method: String
}
