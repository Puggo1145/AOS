import XCTest
@testable import AOSRPCSchema

/// Byte-equal fixture roundtrip tests.
///
/// For every fixture file in `tests/rpc-fixtures/*.json`:
///   1. Load raw bytes
///   2. Decode to the corresponding `RPCRequest<…>` / `RPCNotification<…>` envelope
///   3. Re-encode with `JSONEncoder.OutputFormatting.sortedKeys`
///   4. Assert the re-encoded bytes are byte-equal to the original file
///
/// This ensures the Swift side preserves canonical (sorted-keys, no-whitespace)
/// JSON layout. The TS side must also pass the same fixture byte-equal —
/// see `sidecar/test/rpc-roundtrip.test.ts`.
final class RoundtripTests: XCTestCase {

    // MARK: - Fixture loading

    /// Resolve `tests/rpc-fixtures/` relative to this source file. The fixtures
    /// live outside the SwiftPM target tree (intentionally — they're shared
    /// with the Bun sidecar conformance test).
    private func fixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
        let here = URL(fileURLWithPath: String(describing: file))
        // .../Tests/AOSRPCSchemaTests/RoundtripTests.swift → repo root
        let repoRoot = here
            .deletingLastPathComponent()  // AOSRPCSchemaTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo/
        return repoRoot
            .appendingPathComponent("tests")
            .appendingPathComponent("rpc-fixtures")
            .appendingPathComponent(name)
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = fixtureURL(name)
        return try Data(contentsOf: url)
    }

    private func canonicalEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func assertRoundtrip<T: Codable & Equatable>(
        fixture: String,
        as type: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let raw = try loadFixture(fixture)
        let decoded = try JSONDecoder().decode(T.self, from: raw)
        let reencoded = try canonicalEncode(decoded)
        XCTAssertEqual(
            reencoded,
            raw,
            """
            Byte-equal roundtrip failed for \(fixture).
            Original: \(String(data: raw, encoding: .utf8) ?? "<binary>")
            Re-encoded: \(String(data: reencoded, encoding: .utf8) ?? "<binary>")
            """,
            file: file,
            line: line
        )
        // Decode → encode → decode chain must be stable.
        let redecoded = try JSONDecoder().decode(T.self, from: reencoded)
        XCTAssertEqual(decoded, redecoded, file: file, line: line)
    }

    // MARK: - rpc.*

    func testRpcHelloRoundtrip() throws {
        try assertRoundtrip(
            fixture: "rpc.hello.json",
            as: RPCRequest<HelloParams>.self
        )
    }

    func testRpcPingRoundtrip() throws {
        try assertRoundtrip(
            fixture: "rpc.ping.json",
            as: RPCRequest<PingParams>.self
        )
    }

    // MARK: - agent.*

    func testAgentSubmitRoundtrip() throws {
        try assertRoundtrip(
            fixture: "agent.submit.json",
            as: RPCRequest<AgentSubmitParams>.self
        )
    }

    func testAgentCancelRoundtrip() throws {
        try assertRoundtrip(
            fixture: "agent.cancel.json",
            as: RPCRequest<AgentCancelParams>.self
        )
    }

    // MARK: - ui.*

    func testUITokenRoundtrip() throws {
        try assertRoundtrip(
            fixture: "ui.token.json",
            as: RPCNotification<UITokenParams>.self
        )
    }

    func testUIStatusRoundtrip() throws {
        try assertRoundtrip(
            fixture: "ui.status.json",
            as: RPCNotification<UIStatusParams>.self
        )
    }

    func testUIErrorRoundtrip() throws {
        try assertRoundtrip(
            fixture: "ui.error.json",
            as: RPCNotification<UIErrorParams>.self
        )
    }

    // MARK: - provider.*

    func testProviderStatusRoundtrip() throws {
        try assertRoundtrip(
            fixture: "provider.status.json",
            as: RPCRequest<ProviderStatusParams>.self
        )
    }

    func testProviderStartLoginRoundtrip() throws {
        try assertRoundtrip(
            fixture: "provider.startLogin.json",
            as: RPCRequest<ProviderStartLoginParams>.self
        )
    }

    func testProviderCancelLoginRoundtrip() throws {
        try assertRoundtrip(
            fixture: "provider.cancelLogin.json",
            as: RPCRequest<ProviderCancelLoginParams>.self
        )
    }

    func testProviderLoginStatusRoundtrip() throws {
        try assertRoundtrip(
            fixture: "provider.loginStatus.json",
            as: RPCNotification<ProviderLoginStatusParams>.self
        )
    }

    func testProviderStatusChangedRoundtrip() throws {
        try assertRoundtrip(
            fixture: "provider.statusChanged.json",
            as: RPCNotification<ProviderStatusChangedParams>.self
        )
    }

    // MARK: - Schema invariants

    func testProtocolVersionConstant() {
        XCTAssertEqual(aosProtocolVersion, "1.0.0")
    }

    func testHelloFixtureCarriesCanonicalProtocolVersion() throws {
        let raw = try loadFixture("rpc.hello.json")
        let req = try JSONDecoder().decode(RPCRequest<HelloParams>.self, from: raw)
        XCTAssertEqual(req.params.protocolVersion, aosProtocolVersion)
    }
}
