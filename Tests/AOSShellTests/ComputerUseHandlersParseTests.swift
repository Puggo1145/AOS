import Testing
import Foundation
import AOSComputerUseKit
import AOSRPCSchema
@testable import AOSShell

// MARK: - ComputerUseHandlers.parseCaptureMode
//
// Strict parsing: nil falls back to the documented default (.som), every
// known string maps cleanly, and every unknown non-nil string raises
// `invalidParams` instead of silently picking .som. Silent fallback was
// the previous behavior — it hid malformed model output and quietly
// upgraded `ax`-only intents into full AX+screenshot work, which both
// burned the screenshot payload budget and obscured prompt bugs.

@Suite("ComputerUseHandlers.parseCaptureMode")
struct ComputerUseHandlersParseTests {

    @Test("nil falls back to .som")
    func nilDefault() throws {
        let mode = try ComputerUseHandlers.parseCaptureMode(nil)
        #expect(mode == .som)
    }

    @Test("Known values round-trip")
    func knownValues() throws {
        #expect(try ComputerUseHandlers.parseCaptureMode("som") == .som)
        #expect(try ComputerUseHandlers.parseCaptureMode("vision") == .vision)
        #expect(try ComputerUseHandlers.parseCaptureMode("ax") == .ax)
        // Case insensitive.
        #expect(try ComputerUseHandlers.parseCaptureMode("VISION") == .vision)
        #expect(try ComputerUseHandlers.parseCaptureMode("Ax") == .ax)
    }

    @Test("Unknown non-nil string throws invalidParams")
    func unknownStringThrows() {
        #expect(throws: RPCErrorThrowable.self) {
            _ = try ComputerUseHandlers.parseCaptureMode("foo")
        }
        do {
            _ = try ComputerUseHandlers.parseCaptureMode("foo")
            Issue.record("expected throw for unknown captureMode")
        } catch let err as RPCErrorThrowable {
            #expect(err.rpcError.code == RPCErrorCode.invalidParams)
            #expect(err.rpcError.message.contains("foo"))
        } catch {
            Issue.record("expected RPCErrorThrowable, got \(error)")
        }
    }

    @Test("Empty string is treated as unknown — not silently coerced to .som")
    func emptyStringThrows() {
        #expect(throws: RPCErrorThrowable.self) {
            _ = try ComputerUseHandlers.parseCaptureMode("")
        }
    }
}

// MARK: - ComputerUseHandlers.mapError
//
// Locks the wire shape against `docs/designs/rpc-protocol.md` "错误模型".
// Drift here is silent — the sidecar/model can still parse the JSON, but
// recovery branches that look for `expected.windowId` (vs flat
// `expectedWindowId`) would just see "no expected info" and fall back to
// generic stale handling. Catching that in a unit test is much cheaper
// than catching it in agent loop traces.

@Suite("ComputerUseHandlers.mapError windowMismatch shape")
struct ComputerUseHandlersMapErrorTests {

    /// Pull `data["expected"]` out of the RPCError, asserting it's a
    /// nested object (not flat fields on `data`). Returns `nil` if
    /// `expected` is absent — caller decides if that's expected.
    private static func expectedObject(_ rpc: RPCError) -> [String: AOSRPCSchema.JSONValue]? {
        guard case .object(let data) = rpc.data ?? .null else { return nil }
        guard let expected = data["expected"] else { return nil }
        guard case .object(let nested) = expected else {
            Issue.record("expected nested object, got \(expected)")
            return nil
        }
        return nested
    }

    private static func intValue(_ v: AOSRPCSchema.JSONValue?) -> Int? {
        guard case .int(let n) = v else { return nil }
        return n
    }

    @Test("Ownership mismatch (validateOwnership source) emits expected.pid only")
    func ownershipMismatch() throws {
        let err = ComputerUseError.windowMismatch(
            pid: 1234, windowId: 5678, ownerPid: 9999, expectedWindowId: nil
        )
        let rpc = ComputerUseHandlers.mapError(err)
        #expect(rpc.code == RPCErrorCode.windowMismatch)
        guard case .object(let data) = rpc.data ?? .null else {
            Issue.record("expected data to be object"); return
        }
        #expect(Self.intValue(data["pid"]) == 1234)
        #expect(Self.intValue(data["windowId"]) == 5678)
        #expect(data["expectedPid"] == nil) // no flat fields
        #expect(data["expectedWindowId"] == nil)
        let expected = try #require(Self.expectedObject(rpc))
        #expect(Self.intValue(expected["pid"]) == 9999)
        #expect(expected["windowId"] == nil) // ownership source doesn't know windowId
    }

    @Test("StateCache mismatch source emits expected.pid AND expected.windowId")
    func stateCacheMismatch() throws {
        let err = ComputerUseError.windowMismatch(
            pid: 100, windowId: 200, ownerPid: 100, expectedWindowId: 999
        )
        let rpc = ComputerUseHandlers.mapError(err)
        let expected = try #require(Self.expectedObject(rpc))
        #expect(Self.intValue(expected["pid"]) == 100)
        #expect(Self.intValue(expected["windowId"]) == 999)
    }

    @Test("Mismatch with neither owner nor expected window omits expected key entirely")
    func neitherSideKnown() {
        let err = ComputerUseError.windowMismatch(
            pid: 1, windowId: 2, ownerPid: nil, expectedWindowId: nil
        )
        let rpc = ComputerUseHandlers.mapError(err)
        guard case .object(let data) = rpc.data ?? .null else {
            Issue.record("expected data to be object"); return
        }
        #expect(data["pid"] != nil)
        #expect(data["windowId"] != nil)
        #expect(data["expected"] == nil)
    }

    @Test("payloadTooLarge maps to ErrPayloadTooLarge with bytes/limit data")
    func payloadTooLargeShape() throws {
        let err = ComputerUseError.payloadTooLarge(bytes: 1_500_000, limit: 700_000)
        let rpc = ComputerUseHandlers.mapError(err)
        #expect(rpc.code == RPCErrorCode.payloadTooLarge)
        guard case .object(let data) = rpc.data ?? .null else {
            Issue.record("expected data to be object"); return
        }
        #expect(Self.intValue(data["bytes"]) == 1_500_000)
        #expect(Self.intValue(data["limit"]) == 700_000)
    }
}
