import Testing
import Foundation
@testable import AOSRPCSchema

// MARK: - RoundtripTests
//
// Byte-equal fixture roundtrip tests, plus discriminated-union variant
// guards that pin the wire shape of `ui.thinking` / `ui.toolCall` / split
// click params.
//
// Converted to Swift Testing so the fixture roundtrips can run as a single
// parameterised `@Test` over a typed registry — failing one fixture
// doesn't mask the others, and each row's name shows up directly in the
// test output. Variant-guard `@Test`s stay individual because each one
// pins a distinct decoder rejection contract that reads better as its own
// named case.

@Suite("RPC fixture roundtrip", .serialized)
struct RoundtripTests {

    // MARK: - Fixture loading

    /// Resolve `Tests/rpc-fixtures/` relative to this source file. The
    /// fixtures live outside the SwiftPM target tree (intentionally —
    /// they're shared with the Bun sidecar conformance test).
    private static func fixtureURL(_ name: String, file: String = #filePath) -> URL {
        let here = URL(fileURLWithPath: file)
        let repoRoot = here
            .deletingLastPathComponent()  // AOSRPCSchemaTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo/
        return repoRoot
            .appendingPathComponent("Tests")
            .appendingPathComponent("rpc-fixtures")
            .appendingPathComponent(name)
    }

    private static func loadFixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private static func canonicalEncode<T: Encodable>(_ value: T) throws -> Data {
        try CanonicalJSON.encode(value)
    }

    /// Generic byte-equal roundtrip: decode → re-encode → compare bytes,
    /// then decode the re-encoded bytes back and assert structural equality.
    /// Templated so each `RoundtripCase` carries its own type witness.
    private static func assertRoundtrip<T: Codable & Equatable>(
        fixture: String,
        as type: T.Type
    ) throws {
        let raw = try loadFixture(fixture)
        let decoded = try JSONDecoder().decode(T.self, from: raw)
        let reencoded = try canonicalEncode(decoded)
        #expect(
            reencoded == raw,
            """
            Byte-equal roundtrip failed for \(fixture).
            Original: \(String(data: raw, encoding: .utf8) ?? "<binary>")
            Re-encoded: \(String(data: reencoded, encoding: .utf8) ?? "<binary>")
            """
        )
        let redecoded = try JSONDecoder().decode(T.self, from: reencoded)
        #expect(decoded == redecoded)
    }

    // MARK: - Parameterised fixture roundtrip
    //
    // Each row is `(fixtureName, runner)` — the runner closes over the
    // concrete generic type so the parameterised `@Test` doesn't need a
    // single homogenous type. Closures capture the type witness via
    // `assertRoundtrip<T>(fixture:as:)`. Failures point at the row name in
    // the runner output.

    struct FixtureRow: CustomStringConvertible {
        let name: String
        let run: () throws -> Void
        var description: String { name }
    }

    /// Single source of truth for the fixture catalogue. Adding a new
    /// fixture means one entry here — not a new top-level test method.
    static let fixtureRows: [FixtureRow] = [
        // rpc.*
        FixtureRow(name: "rpc.hello.json") { try assertRoundtrip(fixture: "rpc.hello.json", as: RPCRequest<HelloParams>.self) },
        FixtureRow(name: "rpc.ping.json") { try assertRoundtrip(fixture: "rpc.ping.json", as: RPCRequest<PingParams>.self) },

        // agent.*
        FixtureRow(name: "agent.submit.json") { try assertRoundtrip(fixture: "agent.submit.json", as: RPCRequest<AgentSubmitParams>.self) },
        FixtureRow(name: "agent.cancel.json") { try assertRoundtrip(fixture: "agent.cancel.json", as: RPCRequest<AgentCancelParams>.self) },
        FixtureRow(name: "agent.reset.json") { try assertRoundtrip(fixture: "agent.reset.json", as: RPCRequest<AgentResetParams>.self) },

        // conversation.*
        FixtureRow(name: "conversation.turnStarted.json") { try assertRoundtrip(fixture: "conversation.turnStarted.json", as: RPCNotification<ConversationTurnStartedParams>.self) },
        FixtureRow(name: "conversation.reset.json") { try assertRoundtrip(fixture: "conversation.reset.json", as: RPCNotification<ConversationResetParams>.self) },

        // config.*
        FixtureRow(name: "config.get.json") { try assertRoundtrip(fixture: "config.get.json", as: RPCRequest<ConfigGetParams>.self) },
        FixtureRow(name: "config.set.json") { try assertRoundtrip(fixture: "config.set.json", as: RPCRequest<ConfigSetParams>.self) },
        FixtureRow(name: "config.setEffort.json") { try assertRoundtrip(fixture: "config.setEffort.json", as: RPCRequest<ConfigSetEffortParams>.self) },

        // ui.*
        FixtureRow(name: "ui.token.json") { try assertRoundtrip(fixture: "ui.token.json", as: RPCNotification<UITokenParams>.self) },
        FixtureRow(name: "ui.thinking.delta.json") { try assertRoundtrip(fixture: "ui.thinking.delta.json", as: RPCNotification<UIThinkingParams>.self) },
        FixtureRow(name: "ui.thinking.end.json") { try assertRoundtrip(fixture: "ui.thinking.end.json", as: RPCNotification<UIThinkingParams>.self) },
        FixtureRow(name: "ui.toolCall.called.json") { try assertRoundtrip(fixture: "ui.toolCall.called.json", as: RPCNotification<UIToolCallParams>.self) },
        FixtureRow(name: "ui.toolCall.result.json") { try assertRoundtrip(fixture: "ui.toolCall.result.json", as: RPCNotification<UIToolCallParams>.self) },
        FixtureRow(name: "ui.toolCall.rejected.json") { try assertRoundtrip(fixture: "ui.toolCall.rejected.json", as: RPCNotification<UIToolCallParams>.self) },
        FixtureRow(name: "ui.status.json") { try assertRoundtrip(fixture: "ui.status.json", as: RPCNotification<UIStatusParams>.self) },
        FixtureRow(name: "ui.error.json") { try assertRoundtrip(fixture: "ui.error.json", as: RPCNotification<UIErrorParams>.self) },
        FixtureRow(name: "ui.usage.json") { try assertRoundtrip(fixture: "ui.usage.json", as: RPCNotification<UIUsageParams>.self) },

        // provider.*
        FixtureRow(name: "provider.status.json") { try assertRoundtrip(fixture: "provider.status.json", as: RPCRequest<ProviderStatusParams>.self) },
        FixtureRow(name: "provider.startLogin.json") { try assertRoundtrip(fixture: "provider.startLogin.json", as: RPCRequest<ProviderStartLoginParams>.self) },
        FixtureRow(name: "provider.cancelLogin.json") { try assertRoundtrip(fixture: "provider.cancelLogin.json", as: RPCRequest<ProviderCancelLoginParams>.self) },
        FixtureRow(name: "provider.loginStatus.json") { try assertRoundtrip(fixture: "provider.loginStatus.json", as: RPCNotification<ProviderLoginStatusParams>.self) },
        FixtureRow(name: "provider.statusChanged.json") { try assertRoundtrip(fixture: "provider.statusChanged.json", as: RPCNotification<ProviderStatusChangedParams>.self) },
        FixtureRow(name: "provider.setApiKey.json") { try assertRoundtrip(fixture: "provider.setApiKey.json", as: RPCRequest<ProviderSetApiKeyParams>.self) },
        FixtureRow(name: "provider.clearApiKey.json") { try assertRoundtrip(fixture: "provider.clearApiKey.json", as: RPCRequest<ProviderClearApiKeyParams>.self) },
        FixtureRow(name: "provider.logout.json") { try assertRoundtrip(fixture: "provider.logout.json", as: RPCRequest<ProviderLogoutParams>.self) },

        // dev.*
        FixtureRow(name: "dev.context.get.json") { try assertRoundtrip(fixture: "dev.context.get.json", as: RPCRequest<DevContextGetParams>.self) },
        FixtureRow(name: "dev.context.changed.json") { try assertRoundtrip(fixture: "dev.context.changed.json", as: RPCNotification<DevContextChangedParams>.self) },

        // session.*
        FixtureRow(name: "session.create.json") { try assertRoundtrip(fixture: "session.create.json", as: RPCRequest<SessionCreateParams>.self) },
        FixtureRow(name: "session.list.json") { try assertRoundtrip(fixture: "session.list.json", as: RPCRequest<SessionListParams>.self) },
        FixtureRow(name: "session.activate.json") { try assertRoundtrip(fixture: "session.activate.json", as: RPCRequest<SessionActivateParams>.self) },
        FixtureRow(name: "session.created.json") { try assertRoundtrip(fixture: "session.created.json", as: RPCNotification<SessionCreatedNotificationParams>.self) },
        FixtureRow(name: "session.activated.json") { try assertRoundtrip(fixture: "session.activated.json", as: RPCNotification<SessionActivatedNotificationParams>.self) },
        FixtureRow(name: "session.listChanged.json") { try assertRoundtrip(fixture: "session.listChanged.json", as: RPCNotification<SessionListChangedNotificationParams>.self) },
    ]

    @Test("fixture roundtrips byte-equal", arguments: RoundtripTests.fixtureRows)
    func fixtureRoundtrip(_ row: FixtureRow) throws {
        try row.run()
    }

    // MARK: - ui.thinking discriminated-union guards
    //
    // `kind == .end` MUST omit `delta` from the wire (not encode it as
    // `null`). The end fixture is the byte-equal proof; this guards the
    // inverse — that we don't accidentally encode `delta: null`.

    @Test("ui.thinking end variant omits delta on encode")
    func uiThinkingEndOmitsDelta() throws {
        let end = RPCNotification(
            method: "ui.thinking",
            params: UIThinkingParams(sessionId: "s", turnId: "t", kind: .end)
        )
        let bytes = try CanonicalJSON.encode(end)
        let s = String(data: bytes, encoding: .utf8) ?? ""
        #expect(!s.contains("\"delta\""), "end variant should not carry delta key, got: \(s)")
    }

    @Test("ui.thinking delta without delta field is rejected")
    func uiThinkingDeltaWithoutDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"kind":"delta","sessionId":"s","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw)
        }
    }

    @Test("ui.thinking end with delta field is rejected")
    func uiThinkingEndWithDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"delta":"x","kind":"end","sessionId":"s","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw)
        }
    }

    @Test("ui.thinking end with explicit-null delta is rejected")
    func uiThinkingEndWithNullDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"delta":null,"kind":"end","sessionId":"s","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw)
        }
    }

    @Test("ui.thinking delta with explicit-null delta is rejected")
    func uiThinkingDeltaWithNullDeltaIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.thinking","params":{"delta":null,"kind":"delta","sessionId":"s","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIThinkingParams>.self, from: raw)
        }
    }

    // MARK: - ui.toolCall discriminated-union guards

    @Test("ui.toolCall called variant omits result-only fields")
    func uiToolCallCalledOmitsResultFields() throws {
        let called = RPCNotification(
            method: "ui.toolCall",
            params: UIToolCallParams(
                sessionId: "s", turnId: "t", phase: .called,
                toolCallId: "tc", toolName: "bash", args: .object([:])
            )
        )
        let bytes = try CanonicalJSON.encode(called)
        let s = String(data: bytes, encoding: .utf8) ?? ""
        #expect(!s.contains("\"isError\""), "called variant must not carry isError, got: \(s)")
        #expect(!s.contains("\"outputText\""), "called variant must not carry outputText, got: \(s)")
    }

    @Test("ui.toolCall result variant omits args")
    func uiToolCallResultOmitsArgs() throws {
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
        #expect(!s.contains("\"args\""), "result variant must not carry args, got: \(s)")
    }

    @Test("ui.toolCall called without args is rejected")
    func uiToolCallCalledWithoutArgsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"phase":"called","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw)
        }
    }

    @Test("ui.toolCall result with args is rejected")
    func uiToolCallResultWithArgsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"args":{},"isError":false,"outputText":"x","phase":"result","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw)
        }
    }

    @Test("ui.toolCall result missing isError or outputText is rejected")
    func uiToolCallResultMissingFieldsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"isError":false,"phase":"result","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw)
        }
    }

    @Test("ui.toolCall rejected variant omits result-only fields")
    func uiToolCallRejectedOmitsResultFields() throws {
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
        #expect(!s.contains("\"isError\""), "rejected variant must not carry isError, got: \(s)")
        #expect(!s.contains("\"outputText\""), "rejected variant must not carry outputText, got: \(s)")
    }

    @Test("ui.toolCall rejected without errorMessage is rejected")
    func uiToolCallRejectedWithoutErrorMessageIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"args":{},"phase":"rejected","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw)
        }
    }

    @Test("ui.toolCall rejected without args is rejected")
    func uiToolCallRejectedWithoutArgsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"errorMessage":"x","phase":"rejected","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw)
        }
    }

    @Test("ui.toolCall rejected with result fields is rejected")
    func uiToolCallRejectedWithResultFieldsIsRejected() {
        let raw = #"{"jsonrpc":"2.0","method":"ui.toolCall","params":{"args":{},"errorMessage":"x","isError":true,"phase":"rejected","sessionId":"s","toolCallId":"tc","toolName":"bash","turnId":"t"}}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(RPCNotification<UIToolCallParams>.self, from: raw)
        }
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

    @Test("clickByElement requires stateId + elementIndex")
    func clickByElementParamsRequireStateIdAndIndex() throws {
        let missingBoth = #"{"pid":42,"windowId":7}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ComputerUseClickByElementParams.self, from: missingBoth)
        }

        let missingIndex = #"{"pid":42,"windowId":7,"stateId":"abc"}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ComputerUseClickByElementParams.self, from: missingIndex)
        }

        let full = #"{"pid":42,"windowId":7,"stateId":"abc","elementIndex":3,"action":"AXShowMenu"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ComputerUseClickByElementParams.self, from: full)
        #expect(decoded.stateId == "abc")
        #expect(decoded.elementIndex == 3)
        #expect(decoded.action == "AXShowMenu")
    }

    @Test("clickByCoords requires x + y")
    func clickByCoordsParamsRequireXAndY() throws {
        let missingY = #"{"pid":42,"windowId":7,"x":100}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ComputerUseClickByCoordsParams.self, from: missingY)
        }

        let full = #"{"pid":42,"windowId":7,"x":116,"y":421,"count":2}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ComputerUseClickByCoordsParams.self, from: full)
        #expect(decoded.x == 116)
        #expect(decoded.y == 421)
        #expect(decoded.count == 2)
    }

    @Test("clickByCoords decoder ignores stale element fields")
    func clickByCoordsIgnoresExtraneousElementFields() throws {
        // Exact payload shape the LLM used to send: both placeholder element
        // fields AND real coords. The byCoords decoder ignores the extra
        // `stateId`/`elementIndex` keys so the agent can never accidentally
        // route to element mode.
        let mixedPayload = """
        {"pid":56340,"windowId":291977,"x":116,"y":421,"stateId":"unused","elementIndex":-1,"count":1}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ComputerUseClickByCoordsParams.self, from: mixedPayload)
        #expect(decoded.x == 116)
        #expect(decoded.y == 421)
        #expect(decoded.count == 1)
    }

    @Test("clickByElement and clickByCoords method names are distinct")
    func clickMethodNamesAreDistinct() {
        #expect(RPCMethod.computerUseClickByElement == "computerUse.clickByElement")
        #expect(RPCMethod.computerUseClickByCoords == "computerUse.clickByCoords")
        #expect(RPCMethod.computerUseClickByElement != RPCMethod.computerUseClickByCoords)
    }

    // MARK: - Schema invariants

    @Test("aosProtocolVersion is 2.0.0")
    func protocolVersionConstant() {
        #expect(aosProtocolVersion == "2.0.0")
    }

    @Test("rpc.hello fixture carries canonical protocolVersion")
    func helloFixtureCarriesCanonicalProtocolVersion() throws {
        let raw = try Self.loadFixture("rpc.hello.json")
        let req = try JSONDecoder().decode(RPCRequest<HelloParams>.self, from: raw)
        #expect(req.params.protocolVersion == aosProtocolVersion)
    }
}
