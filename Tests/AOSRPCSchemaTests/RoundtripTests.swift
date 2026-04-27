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
        // Use the package's canonical encoder so any drift in output flags
        // shows up in both runtime + tests at once.
        try CanonicalJSON.encode(value)
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

    func testAgentResetRoundtrip() throws {
        try assertRoundtrip(
            fixture: "agent.reset.json",
            as: RPCRequest<AgentResetParams>.self
        )
    }

    // MARK: - conversation.*

    func testConversationTurnStartedRoundtrip() throws {
        try assertRoundtrip(
            fixture: "conversation.turnStarted.json",
            as: RPCNotification<ConversationTurnStartedParams>.self
        )
    }

    func testConversationResetRoundtrip() throws {
        try assertRoundtrip(
            fixture: "conversation.reset.json",
            as: RPCNotification<ConversationResetParams>.self
        )
    }

    // MARK: - config.*

    func testConfigGetRoundtrip() throws {
        try assertRoundtrip(
            fixture: "config.get.json",
            as: RPCRequest<ConfigGetParams>.self
        )
    }

    func testConfigSetRoundtrip() throws {
        try assertRoundtrip(
            fixture: "config.set.json",
            as: RPCRequest<ConfigSetParams>.self
        )
    }

    func testConfigSetEffortRoundtrip() throws {
        try assertRoundtrip(
            fixture: "config.setEffort.json",
            as: RPCRequest<ConfigSetEffortParams>.self
        )
    }

    // MARK: - ui.*

    func testUITokenRoundtrip() throws {
        try assertRoundtrip(
            fixture: "ui.token.json",
            as: RPCNotification<UITokenParams>.self
        )
    }

    func testUIThinkingDeltaRoundtrip() throws {
        try assertRoundtrip(
            fixture: "ui.thinking.delta.json",
            as: RPCNotification<UIThinkingParams>.self
        )
    }

    func testUIThinkingEndRoundtrip() throws {
        try assertRoundtrip(
            fixture: "ui.thinking.end.json",
            as: RPCNotification<UIThinkingParams>.self
        )
    }

    /// `kind == .end` MUST omit `delta` from the wire (not encode it as
    /// `null`). The end fixture is the byte-equal proof; this guards the
    /// inverse — that we don't accidentally encode `delta: null`.
    func testUIThinkingEndOmitsDelta() throws {
        let end = RPCNotification(
            method: "ui.thinking",
            params: UIThinkingParams(turnId: "t", kind: .end)
        )
        let bytes = try CanonicalJSON.encode(end)
        let s = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("\"delta\""), "end variant should not carry delta key, got: \(s)")
    }

    /// The decoder rejects a `kind:"delta"` frame that omits `delta`, instead
    /// of silently producing `delta: nil`. Pairs with the TS discriminated
    /// union's compile-time guarantee.
    func testUIThinkingDeltaWithoutDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"kind":"delta","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw))
    }

    /// The decoder rejects a `kind:"end"` frame that carries a `delta`,
    /// catching producers that accidentally serialize the leftover field.
    func testUIThinkingEndWithDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"delta":"x","kind":"end","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw))
    }

    /// `{"kind":"end","delta":null}` is still a frame carrying the `delta`
    /// key — the wire contract is keyed on field presence, not field value,
    /// so an explicit null must also be rejected.
    func testUIThinkingEndWithNullDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"delta":null,"kind":"end","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw))
    }

    /// Symmetric guard: `{"kind":"delta","delta":null}` is malformed — the
    /// delta variant requires a string, not a present-but-null field.
    func testUIThinkingDeltaWithNullDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"delta":null,"kind":"delta","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw))
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

    func testProviderSetApiKeyRoundtrip() throws {
        try assertRoundtrip(
            fixture: "provider.setApiKey.json",
            as: RPCRequest<ProviderSetApiKeyParams>.self
        )
    }

    func testProviderClearApiKeyRoundtrip() throws {
        try assertRoundtrip(
            fixture: "provider.clearApiKey.json",
            as: RPCRequest<ProviderClearApiKeyParams>.self
        )
    }

    func testProviderLogoutRoundtrip() throws {
        try assertRoundtrip(
            fixture: "provider.logout.json",
            as: RPCRequest<ProviderLogoutParams>.self
        )
    }

    // MARK: - dev.*

    func testDevContextGetRoundtrip() throws {
        try assertRoundtrip(
            fixture: "dev.context.get.json",
            as: RPCRequest<DevContextGetParams>.self
        )
    }

    func testDevContextChangedRoundtrip() throws {
        try assertRoundtrip(
            fixture: "dev.context.changed.json",
            as: RPCNotification<DevContextChangedParams>.self
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
