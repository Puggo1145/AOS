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
            params: UIThinkingParams(sessionId: "s", turnId: "t", kind: .end)
        )
        let bytes = try CanonicalJSON.encode(end)
        let s = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("\"delta\""), "end variant should not carry delta key, got: \(s)")
    }

    /// The decoder rejects a `kind:"delta"` frame that omits `delta`, instead
    /// of silently producing `delta: nil`. Pairs with the TS discriminated
    /// union's compile-time guarantee.
    func testUIThinkingDeltaWithoutDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"kind":"delta","sessionId":"s","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw))
    }

    /// The decoder rejects a `kind:"end"` frame that carries a `delta`,
    /// catching producers that accidentally serialize the leftover field.
    func testUIThinkingEndWithDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"delta":"x","kind":"end","sessionId":"s","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw))
    }

    /// `{"kind":"end","delta":null}` is still a frame carrying the `delta`
    /// key — the wire contract is keyed on field presence, not field value,
    /// so an explicit null must also be rejected.
    func testUIThinkingEndWithNullDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"delta":null,"kind":"end","sessionId":"s","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw))
    }

    /// Symmetric guard: `{"kind":"delta","delta":null}` is malformed — the
    /// delta variant requires a string, not a present-but-null field.
    func testUIThinkingDeltaWithNullDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"delta":null,"kind":"delta","sessionId":"s","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw))
    }

    func testUIToolCallCalledRoundtrip() throws {
        try assertRoundtrip(
            fixture: "ui.toolCall.called.json",
            as: RPCNotification<UIToolCallParams>.self
        )
    }

    func testUIToolCallResultRoundtrip() throws {
        try assertRoundtrip(
            fixture: "ui.toolCall.result.json",
            as: RPCNotification<UIToolCallParams>.self
        )
    }

    /// `phase == .called` MUST omit result-only keys from the wire. The
    /// fixture proves the positive case; this guards the negative — that we
    /// don't accidentally emit `isError`/`outputText` on a called frame.
    func testUIToolCallCalledOmitsResultFields() throws {
        let called = RPCNotification(
            method: "ui.toolCall",
            params: UIToolCallParams(
                sessionId: "s", turnId: "t", phase: .called,
                toolCallId: "tc", toolName: "bash", args: .object([:])
            )
        )
        let bytes = try CanonicalJSON.encode(called)
        let s = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("\"isError\""), "called variant must not carry isError, got: \(s)")
        XCTAssertFalse(s.contains("\"outputText\""), "called variant must not carry outputText, got: \(s)")
    }

    /// Symmetric guard: `phase == .result` must not encode `args`.
    func testUIToolCallResultOmitsArgs() throws {
        let result = RPCNotification(
            method: "ui.toolCall",
            params: UIToolCallParams(
                sessionId: "s", turnId: "t", phase: .result,
                toolCallId: "tc", toolName: "bash",
                isError: false, outputText: "ok"
            )
        )
        let bytes = try CanonicalJSON.encode(result)
        let s = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("\"args\""), "result variant must not carry args, got: \(s)")
    }

    /// Decoder rejects a `phase:"called"` frame missing `args`. Mirrors the
    /// equivalent ui.thinking guards above.
    func testUIToolCallCalledWithoutArgsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"phase":"called","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw))
    }

    /// Decoder rejects a `phase:"result"` frame that carries `args` (leftover
    /// from a producer that forgot to clear the called-side payload).
    func testUIToolCallResultWithArgsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"args":{},"isError":false,"outputText":"x","phase":"result","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw))
    }

    /// Decoder rejects a `phase:"result"` frame missing `isError` or `outputText`.
    func testUIToolCallResultMissingFieldsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"isError":false,"phase":"result","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw))
    }

    func testUIToolCallRejectedRoundtrip() throws {
        try assertRoundtrip(
            fixture: "ui.toolCall.rejected.json",
            as: RPCNotification<UIToolCallParams>.self
        )
    }

    /// `phase == .rejected` MUST NOT carry `isError` / `outputText` — those
    /// keys belong to `.result` and would imply the handler ran. The phase
    /// itself is the failure signal.
    func testUIToolCallRejectedOmitsResultFields() throws {
        let rej = RPCNotification(
            method: "ui.toolCall",
            params: UIToolCallParams(
                sessionId: "s", turnId: "t", phase: .rejected,
                toolCallId: "tc", toolName: "bash",
                args: .object([:]), errorMessage: "bad args"
            )
        )
        let bytes = try CanonicalJSON.encode(rej)
        let s = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("\"isError\""), "rejected variant must not carry isError, got: \(s)")
        XCTAssertFalse(s.contains("\"outputText\""), "rejected variant must not carry outputText, got: \(s)")
    }

    /// Decoder rejects a `phase:"rejected"` frame missing `errorMessage`.
    func testUIToolCallRejectedWithoutErrorMessageIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"args":{},"phase":"rejected","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw))
    }

    /// Decoder rejects a `phase:"rejected"` frame missing `args`.
    func testUIToolCallRejectedWithoutArgsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"errorMessage":"x","phase":"rejected","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw))
    }

    /// Decoder rejects a `phase:"rejected"` frame that smuggles in result-only
    /// fields — guards against producers that copy/paste the result payload
    /// shape into a rejection.
    func testUIToolCallRejectedWithResultFieldsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"args":{},"errorMessage":"x","isError":true,"phase":"rejected","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw))
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

    // MARK: - session.*

    func testSessionCreateRoundtrip() throws {
        try assertRoundtrip(
            fixture: "session.create.json",
            as: RPCRequest<SessionCreateParams>.self
        )
    }

    func testSessionListRoundtrip() throws {
        try assertRoundtrip(
            fixture: "session.list.json",
            as: RPCRequest<SessionListParams>.self
        )
    }

    func testSessionActivateRoundtrip() throws {
        try assertRoundtrip(
            fixture: "session.activate.json",
            as: RPCRequest<SessionActivateParams>.self
        )
    }

    func testSessionCreatedRoundtrip() throws {
        try assertRoundtrip(
            fixture: "session.created.json",
            as: RPCNotification<SessionCreatedNotificationParams>.self
        )
    }

    func testSessionActivatedRoundtrip() throws {
        try assertRoundtrip(
            fixture: "session.activated.json",
            as: RPCNotification<SessionActivatedNotificationParams>.self
        )
    }

    func testSessionListChangedRoundtrip() throws {
        try assertRoundtrip(
            fixture: "session.listChanged.json",
            as: RPCNotification<SessionListChangedNotificationParams>.self
        )
    }

    // MARK: - Computer Use click — split-shape invariants
    //
    // Click was historically one method (`computerUse.click`) with two arms
    // gated on optional fields. The model kept filling both arms with
    // placeholders and the dispatcher would route to the wrong arm and
    // fail with `stateStale`. The fix split it into two physically
    // separate methods. These tests pin the new shapes so a regression
    // — re-merging the params struct, or dropping a `required` field —
    // breaks the test before it breaks production.

    func testClickByElementParamsRequireStateIdAndIndex() throws {
        // Missing both → fails to decode.
        let missingBoth = #"{"pid":42,"windowId":7}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(ComputerUseClickByElementParams.self, from: missingBoth)
        )

        // Missing just elementIndex → still fails.
        let missingIndex = #"{"pid":42,"windowId":7,"stateId":"abc"}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(ComputerUseClickByElementParams.self, from: missingIndex)
        )

        // Full payload → succeeds, fields preserved.
        let full = #"{"pid":42,"windowId":7,"stateId":"abc","elementIndex":3,"action":"AXShowMenu"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ComputerUseClickByElementParams.self, from: full)
        XCTAssertEqual(decoded.stateId, "abc")
        XCTAssertEqual(decoded.elementIndex, 3)
        XCTAssertEqual(decoded.action, "AXShowMenu")
    }

    func testClickByCoordsParamsRequireXAndY() throws {
        let missingY = #"{"pid":42,"windowId":7,"x":100}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(ComputerUseClickByCoordsParams.self, from: missingY)
        )

        let full = #"{"pid":42,"windowId":7,"x":116,"y":421,"count":2}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ComputerUseClickByCoordsParams.self, from: full)
        XCTAssertEqual(decoded.x, 116)
        XCTAssertEqual(decoded.y, 421)
        XCTAssertEqual(decoded.count, 2)
    }

    /// The exact payload shape the LLM used to send (per the user's
    /// screenshot): both placeholder element fields AND real coords.
    /// With the split, the byCoords decoder simply ignores the extra
    /// `stateId`/`elementIndex` keys and routes to the coord-only
    /// service path — no way to land in element mode by accident.
    func testClickByCoordsIgnoresExtraneousElementFields() throws {
        let mixedPayload = """
        {"pid":56340,"windowId":291977,"x":116,"y":421,"stateId":"unused","elementIndex":-1,"count":1}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ComputerUseClickByCoordsParams.self, from: mixedPayload)
        XCTAssertEqual(decoded.x, 116)
        XCTAssertEqual(decoded.y, 421)
        XCTAssertEqual(decoded.count, 1)
        // No stateId/elementIndex on the struct — the wire layer cannot
        // see them, so the service can never accidentally trip the
        // StateCache and synthesize a `stateStale` error.
    }

    func testClickMethodNamesAreDistinct() {
        XCTAssertEqual(RPCMethod.computerUseClickByElement, "computerUse.clickByElement")
        XCTAssertEqual(RPCMethod.computerUseClickByCoords, "computerUse.clickByCoords")
        XCTAssertNotEqual(
            RPCMethod.computerUseClickByElement,
            RPCMethod.computerUseClickByCoords
        )
    }

    // MARK: - Schema invariants

    func testProtocolVersionConstant() {
        XCTAssertEqual(aosProtocolVersion, "2.0.0")
    }

    func testHelloFixtureCarriesCanonicalProtocolVersion() throws {
        let raw = try loadFixture("rpc.hello.json")
        let req = try JSONDecoder().decode(RPCRequest<HelloParams>.self, from: raw)
        XCTAssertEqual(req.params.protocolVersion, aosProtocolVersion)
    }
}
