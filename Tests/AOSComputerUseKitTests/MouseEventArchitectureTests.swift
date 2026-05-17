import Foundation
import Testing

@Suite("Computer Use background mouse event architecture")
struct MouseEventArchitectureTests {
    @Test("core exposes mouse events, not left-click compatibility wrappers")
    func coreExposesMouseEventsNotLeftClickWrappers() throws {
        let source = try Self.source("Sources/AOSComputerUseKit/ComputerUseCore.swift")

        #expect(!source.contains("postLeftClick"))
        #expect(!source.contains("WindowClickResult"))
        #expect(!source.contains("WindowClickTrace"))
        #expect(!source.contains("MouseClick"))
    }

    @Test("mouse event model is separate from the poster implementation")
    func mouseEventModelIsSeparateFromPosterImplementation() throws {
        let source = try Self.source("Sources/AOSComputerUseKit/Input/MouseEventPoster.swift")

        #expect(!source.contains("public enum BackgroundMouseEvent"))
        #expect(!source.contains("struct BackgroundMouseEventDeliveryClassifier"))
        #expect(!source.contains("typealias MouseClick"))
    }

    @Test("keyboard event model is separate from the poster implementation")
    func keyboardEventModelIsSeparateFromPosterImplementation() throws {
        let source = try Self.source("Sources/AOSComputerUseKit/Input/KeyboardEventPoster.swift")

        #expect(!source.contains("public enum BackgroundKeyboardEvent"))
        #expect(!source.contains("public struct WindowKeyboardEventResult"))
    }

    @Test("computer use kit only exposes core and value types needed by callers")
    func computerUseKitOnlyExposesCoreAndCallerValueTypes() throws {
        let publicDeclarations = try Self.publicTypeDeclarations()
        let allowedPublicTypes: Set<String> = [
            "AppInfo",
            "AppListMode",
            "AppSessionResult",
            "AppStateBundle",
            "AppType",
            "AppTypeReason",
            "AppTypeResult",
            "AXElementAction",
            "AXElementEvent",
            "AXElementEventResult",
            "AXScrollDirection",
            "BackgroundKeyboardEvent",
            "BackgroundKeyboardModifier",
            "BackgroundMouseButton",
            "BackgroundMouseEvent",
            "CaptureMode",
            "ComputerUseCore",
            "ComputerUseDiagnostics",
            "ComputerUseDiagnosticsProviding",
            "ComputerUseError",
            "ComputerUseVirtualMouseActivityOverlay",
            "ComputerUseVirtualMouseAgentActivity",
            "ComputerUseWindowHighlightControls",
            "ImageFormat",
            "Screenshot",
            "ScreenshotCoordinateSpace",
            "StateID",
            "WindowBounds",
            "WindowFocusResult",
            "WindowInfo",
            "WindowKeyboardEventResult",
            "WindowMouseEventResult",
            "WindowMouseEventTraceResult",
            "WindowMouseEventTraceSnapshot",
            "WindowMouseEventTraceStage",
            "WindowOrderObservationSample",
        ]

        #expect(publicDeclarations.subtracting(allowedPublicTypes).isEmpty)
    }

    @Test("computer use design doc lists the public core surface")
    func computerUseDesignDocListsThePublicCoreSurface() throws {
        let doc = try Self.source("docs/designs/computer-use.md")
        let expectedEntries = [
            "`listApps(mode:) -> [AppInfo]`",
            "`getAppType(pid:) -> AppTypeResult`",
            "`listWindows(pid:) -> [WindowInfo]`",
            "`getAppState(windowId:captureMode:maxImageDimension:) -> AppStateBundle`",
            "`startAppSession(pid:windowId:) -> AppSessionResult`",
            "`stopAppSession() -> AppSessionResult`",
            "`currentAppSession() -> AppSessionResult`",
            "`postMouseEvent(windowId:event:) -> WindowMouseEventResult`",
            "`postMouseEvent(windowId:stateId:event:) -> WindowMouseEventResult`",
            "`postKeyboardEvent(windowId:event:) -> WindowKeyboardEventResult`",
            "`postEventToAXElement(windowId:stateId:elementIndex:event:) -> AXElementEventResult`",
        ]

        for entry in expectedEntries {
            #expect(doc.contains(entry))
        }
        #expect(doc.contains("`core.diagnostics.focusWindowWithoutRaise(pid:windowId:) -> WindowFocusResult`"))
        #expect(doc.contains("`core.diagnostics.postMouseEventTrace(windowId:event:) -> WindowMouseEventTraceResult`"))
        #expect(doc.contains("`core.diagnostics.observeWindowOrder(pid:windowId:durationMilliseconds:intervalMilliseconds:) -> [WindowOrderObservationSample]`"))
    }

    @Test("session scoped action RPC params do not accept explicit pid")
    func sessionScopedActionRPCParamsDoNotAcceptExplicitPID() throws {
        let schema = try Self.source("Sources/AOSRPCSchema/ComputerUse.swift")

        #expect(Self.structBody("ComputerUseGetAppStateParams", in: schema)?.contains("public let pid:") == false)
        #expect(Self.structBody("ComputerUsePostEventToAXElementParams", in: schema)?.contains("public let pid:") == false)
    }

    @Test("core exposes only session scoped getAppState without inspect variants")
    func coreExposesOnlySessionScopedGetAppStateWithoutInspectVariants() throws {
        let core = try Self.source("Sources/AOSComputerUseKit/ComputerUseCore.swift")

        #expect(!core.contains("inspectAppState"))
        #expect(core.contains("public func getAppState("))
    }

    @Test("agent mouse RPC keeps screenshot coordinates in Shell")
    func agentMouseRPCKeepsScreenshotCoordinatesInShell() throws {
        let sidecarTool = try Self.source("sidecar/src/agent/tools/computer-use.ts")
        let rpcService = try Self.source("Sources/AOSShell/Agent/ComputerUseRPCService.swift")
        let core = try Self.source("Sources/AOSComputerUseKit/ComputerUseCore.swift")

        #expect(!sidecarTool.contains("screenshotPointToScreenPoint"))
        #expect(sidecarTool.contains("stateId,"))
        #expect(rpcService.contains("stateId: StateID(params.stateId)"))
        #expect(core.contains("frameTranslatedToCurrentWindowBounds"))
    }

    private static func publicTypeDeclarations(file: String = #filePath) throws -> Set<String> {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = root.appendingPathComponent("Sources/AOSComputerUseKit")
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }

        var declarations = Set<String>()
        let pattern = #"public\s+(?:actor|struct|enum|protocol|class)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        let regex = try NSRegularExpression(pattern: pattern)

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: source) else { continue }
                declarations.insert(String(source[nameRange]))
            }
        }
        return declarations
    }

    private static func source(_ path: String, file: String = #filePath) throws -> String {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func structBody(_ name: String, in source: String) -> String? {
        guard let declaration = source.range(of: "public struct \(name)") else {
            return nil
        }
        guard let openBrace = source[declaration.lowerBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var cursor = openBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openBrace...cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }
}
