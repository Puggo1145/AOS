import AOSComputerUseKit
import AOSRPCSchema
import CoreGraphics
import Darwin
import Foundation

// MARK: - ComputerUseRPCService
//
// Shell-hosted bridge from sidecar `computerUse.*` requests into the live
// `ComputerUseCore`. This layer only maps wire DTOs to Kit value types; core
// validation and failures intentionally bubble through the JSON-RPC boundary.

protocol ShellComputerUseClient: Sendable {
    func listApps(mode: AppListMode) async throws -> [AppInfo]
    func listWindows(pid: pid_t) async throws -> [WindowInfo]
    func getAppState(
        windowId: CGWindowID,
        captureMode: CaptureMode,
        maxImageDimension: Int
    ) async throws -> AppStateBundle
    func startAppSession(pid: pid_t, windowId: CGWindowID) async throws -> AppSessionResult
    func stopAppSession() async throws -> AppSessionResult
    func postMouseEvent(windowId: CGWindowID, event: BackgroundMouseEvent) async throws -> WindowMouseEventResult
    func postKeyboardEvent(windowId: CGWindowID, event: BackgroundKeyboardEvent) async throws -> WindowKeyboardEventResult
    func postEventToAXElement(
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int,
        event: AXElementEvent
    ) async throws -> AXElementEventResult
}

struct LiveShellComputerUseClient: ShellComputerUseClient {
    let core: ComputerUseCore

    func listApps(mode: AppListMode) async throws -> [AppInfo] {
        await core.listApps(mode: mode)
    }

    func listWindows(pid: pid_t) async throws -> [WindowInfo] {
        await core.listWindows(pid: pid)
    }

    func getAppState(
        windowId: CGWindowID,
        captureMode: CaptureMode,
        maxImageDimension: Int
    ) async throws -> AppStateBundle {
        try await core.getAppState(
            windowId: windowId,
            captureMode: captureMode,
            maxImageDimension: maxImageDimension
        )
    }

    func startAppSession(pid: pid_t, windowId: CGWindowID) async throws -> AppSessionResult {
        try await core.startAppSession(pid: pid, windowId: windowId)
    }

    func stopAppSession() async throws -> AppSessionResult {
        try await core.stopAppSession()
    }

    func postMouseEvent(windowId: CGWindowID, event: BackgroundMouseEvent) async throws -> WindowMouseEventResult {
        try await core.postMouseEvent(windowId: windowId, event: event)
    }

    func postKeyboardEvent(windowId: CGWindowID, event: BackgroundKeyboardEvent) async throws -> WindowKeyboardEventResult {
        try await core.postKeyboardEvent(windowId: windowId, event: event)
    }

    func postEventToAXElement(
        windowId: CGWindowID,
        stateId: StateID,
        elementIndex: Int,
        event: AXElementEvent
    ) async throws -> AXElementEventResult {
        try await core.postEventToAXElement(
            windowId: windowId,
            stateId: stateId,
            elementIndex: elementIndex,
            event: event
        )
    }
}

final class ComputerUseRPCService: Sendable {
    private let core: any ShellComputerUseClient

    init(core: any ShellComputerUseClient) {
        self.core = core
    }

    convenience init(rpc: RPCClient, core: any ShellComputerUseClient) {
        self.init(core: core)
        registerHandlers(on: rpc)
    }

    func registerHandlers(on rpc: RPCClient) {
        rpc.registerRequestHandler(
            method: RPCMethod.computerUseListApps,
            as: ComputerUseListAppsParams.self,
            resultType: ComputerUseListAppsResult.self
        ) { [self] params in
            try await handleListApps(params)
        }

        rpc.registerRequestHandler(
            method: RPCMethod.computerUseListWindows,
            as: ComputerUseListWindowsParams.self,
            resultType: ComputerUseListWindowsResult.self
        ) { [self] params in
            try await handleListWindows(params)
        }

        rpc.registerRequestHandler(
            method: RPCMethod.computerUseGetAppState,
            as: ComputerUseGetAppStateParams.self,
            resultType: ComputerUseGetAppStateResult.self
        ) { [self] params in
            try await handleGetAppState(params)
        }

        rpc.registerRequestHandler(
            method: RPCMethod.computerUseStartAppSession,
            as: ComputerUseStartAppSessionParams.self,
            resultType: ComputerUseAppSessionResult.self
        ) { [self] params in
            try await handleStartAppSession(params)
        }

        rpc.registerRequestHandler(
            method: RPCMethod.computerUseStopAppSession,
            as: ComputerUseStopAppSessionParams.self,
            resultType: ComputerUseAppSessionResult.self
        ) { [self] params in
            try await handleStopAppSession(params)
        }

        rpc.registerRequestHandler(
            method: RPCMethod.computerUsePostMouseEvent,
            as: ComputerUsePostMouseEventParams.self,
            resultType: ComputerUsePostMouseEventResult.self
        ) { [self] params in
            try await handlePostMouseEvent(params)
        }

        rpc.registerRequestHandler(
            method: RPCMethod.computerUsePostKeyboardEvent,
            as: ComputerUsePostKeyboardEventParams.self,
            resultType: ComputerUsePostKeyboardEventResult.self
        ) { [self] params in
            try await handlePostKeyboardEvent(params)
        }

        rpc.registerRequestHandler(
            method: RPCMethod.computerUsePostEventToAXElement,
            as: ComputerUsePostEventToAXElementParams.self,
            resultType: ComputerUsePostEventToAXElementResult.self
        ) { [self] params in
            try await handlePostEventToAXElement(params)
        }
    }

    func handleListApps(_ params: ComputerUseListAppsParams) async throws -> ComputerUseListAppsResult {
        let apps = try await core.listApps(mode: AppListMode(params.mode))
        return ComputerUseListAppsResult(apps: apps.map(ComputerUseAppInfo.init))
    }

    func handleListWindows(_ params: ComputerUseListWindowsParams) async throws -> ComputerUseListWindowsResult {
        let windows = try await core.listWindows(pid: try pid(params.pid, name: "pid"))
        return ComputerUseListWindowsResult(windows: windows.map(ComputerUseWindowInfo.init))
    }

    func handleGetAppState(_ params: ComputerUseGetAppStateParams) async throws -> ComputerUseGetAppStateResult {
        let state = try await core.getAppState(
            windowId: try windowId(params.windowId),
            captureMode: CaptureMode(params.captureMode),
            maxImageDimension: params.maxImageDimension
        )
        return ComputerUseGetAppStateResult(state)
    }

    func handleStartAppSession(_ params: ComputerUseStartAppSessionParams) async throws -> ComputerUseAppSessionResult {
        let result = try await core.startAppSession(
            pid: try pid(params.pid, name: "pid"),
            windowId: try windowId(params.windowId)
        )
        return ComputerUseAppSessionResult(pid: Int(result.pid))
    }

    func handleStopAppSession(_: ComputerUseStopAppSessionParams) async throws -> ComputerUseAppSessionResult {
        let result = try await core.stopAppSession()
        return ComputerUseAppSessionResult(pid: Int(result.pid))
    }

    func handlePostMouseEvent(_ params: ComputerUsePostMouseEventParams) async throws -> ComputerUsePostMouseEventResult {
        let result = try await core.postMouseEvent(
            windowId: try windowId(params.windowId),
            event: try BackgroundMouseEvent(params.event)
        )
        return ComputerUsePostMouseEventResult(result)
    }

    func handlePostKeyboardEvent(
        _ params: ComputerUsePostKeyboardEventParams
    ) async throws -> ComputerUsePostKeyboardEventResult {
        let result = try await core.postKeyboardEvent(
            windowId: try windowId(params.windowId),
            event: BackgroundKeyboardEvent(params.event)
        )
        return ComputerUsePostKeyboardEventResult(result)
    }

    func handlePostEventToAXElement(
        _ params: ComputerUsePostEventToAXElementParams
    ) async throws -> ComputerUsePostEventToAXElementResult {
        let result = try await core.postEventToAXElement(
            windowId: try windowId(params.windowId),
            stateId: StateID(params.stateId),
            elementIndex: params.elementIndex,
            event: AXElementEvent(params.event)
        )
        return ComputerUsePostEventToAXElementResult(result)
    }

    private func pid(_ value: Int, name: String) throws -> pid_t {
        guard let parsed = Int32(exactly: value), parsed > 0 else {
            throw ComputerUseRPCMappingError.invalidInteger(name: name, value: value)
        }
        return pid_t(parsed)
    }

    private func windowId(_ value: Int) throws -> CGWindowID {
        guard let parsed = UInt32(exactly: value) else {
            throw ComputerUseRPCMappingError.invalidInteger(name: "windowId", value: value)
        }
        return CGWindowID(parsed)
    }
}

private enum ComputerUseRPCMappingError: Error, CustomStringConvertible {
    case invalidInteger(name: String, value: Int)

    var description: String {
        switch self {
        case .invalidInteger(let name, let value):
            return "\(name) is out of range: \(value)"
        }
    }
}

private extension AppListMode {
    init(_ value: ComputerUseAppListMode) {
        switch value {
        case .running: self = .running
        case .all: self = .all
        }
    }
}

private extension CaptureMode {
    init(_ value: ComputerUseCaptureMode) {
        switch value {
        case .vision: self = .vision
        case .ax: self = .ax
        }
    }
}

private extension ComputerUseAppInfo {
    init(_ app: AppInfo) {
        self.init(
            pid: app.pid.map(Int.init),
            bundleId: app.bundleId,
            name: app.name,
            path: app.path,
            running: app.running,
            active: app.active,
            identity: app.identity
        )
    }
}

private extension ComputerUseWindowInfo {
    init(_ window: WindowInfo) {
        self.init(
            windowId: Int(window.id),
            pid: Int(window.pid),
            owner: window.owner,
            title: window.title,
            bounds: ComputerUseBounds(window.bounds),
            zIndex: window.zIndex,
            isOnScreen: window.isOnScreen,
            layer: window.layer
        )
    }
}

private extension ComputerUseBounds {
    init(_ bounds: WindowBounds) {
        self.init(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }
}

private extension ComputerUseCoordinateSpace {
    init(_ coordinateSpace: ScreenshotCoordinateSpace) {
        self.init(
            windowFrame: ComputerUseBounds(coordinateSpace.windowFrame),
            windowBounds: ComputerUseBounds(coordinateSpace.windowBounds),
            pixelSize: ComputerUsePixelSize(
                width: coordinateSpace.pixelSize.width,
                height: coordinateSpace.pixelSize.height
            )
        )
    }
}

private extension ComputerUseScreenshot {
    init(_ screenshot: Screenshot) {
        self.init(
            imageBase64: screenshot.imageData.base64EncodedString(),
            format: screenshot.format.rawValue,
            width: screenshot.width,
            height: screenshot.height,
            scaleFactor: screenshot.scaleFactor,
            coordinateSpace: ComputerUseCoordinateSpace(screenshot.coordinateSpace),
            originalWidth: screenshot.originalWidth,
            originalHeight: screenshot.originalHeight
        )
    }
}

private extension ComputerUseGetAppStateResult {
    init(_ state: AppStateBundle) {
        self.init(
            pid: Int(state.pid),
            stateId: state.stateId.raw,
            treeMarkdown: state.treeMarkdown,
            elementCount: state.elementCount,
            screenshot: state.screenshot.map(ComputerUseScreenshot.init),
            bundleId: state.bundleId,
            appName: state.appName
        )
    }
}

private extension BackgroundMouseButton {
    init(_ value: ComputerUseMouseButton) {
        switch value {
        case .left: self = .left
        case .right: self = .right
        }
    }
}

private extension BackgroundMouseEvent {
    init(_ value: ComputerUseMouseEvent) throws {
        switch value {
        case .click(let event):
            self = .click(
                button: BackgroundMouseButton(event.button),
                point: CGPoint(event.point),
                count: event.count
            )
        case .drag(let event):
            self = .drag(
                button: BackgroundMouseButton(event.button),
                from: CGPoint(event.from),
                to: CGPoint(event.to)
            )
        }
    }
}

private extension ComputerUseMouseButton {
    init(_ value: BackgroundMouseButton) {
        switch value {
        case .left: self = .left
        case .right: self = .right
        }
    }
}

private extension ComputerUseMouseEvent {
    init(_ event: BackgroundMouseEvent) {
        switch event {
        case .click(let button, let point, let count):
            self = .click(ComputerUseMouseClickEvent(
                button: ComputerUseMouseButton(button),
                point: ComputerUsePoint(point),
                count: count
            ))
        case .drag(let button, let from, let to):
            self = .drag(ComputerUseMouseDragEvent(
                button: ComputerUseMouseButton(button),
                from: ComputerUsePoint(from),
                to: ComputerUsePoint(to)
            ))
        }
    }
}

private extension ComputerUsePostMouseEventResult {
    init(_ result: WindowMouseEventResult) {
        self.init(
            pid: Int(result.pid),
            windowId: Int(result.windowId),
            event: ComputerUseMouseEvent(result.event)
        )
    }
}

private extension CGPoint {
    init(_ point: ComputerUsePoint) {
        self.init(x: point.x, y: point.y)
    }
}

private extension ComputerUsePoint {
    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }
}

private extension BackgroundKeyboardModifier {
    init(_ value: ComputerUseKeyboardModifier) {
        switch value {
        case .command: self = .command
        case .shift: self = .shift
        case .option: self = .option
        case .control: self = .control
        case .function: self = .function
        }
    }
}

private extension ComputerUseKeyboardModifier {
    init(_ value: BackgroundKeyboardModifier) {
        switch value {
        case .command: self = .command
        case .shift: self = .shift
        case .option: self = .option
        case .control: self = .control
        case .function: self = .function
        }
    }
}

private extension BackgroundKeyboardEvent {
    init(_ value: ComputerUseKeyboardEvent) {
        switch value {
        case .text(let event):
            self = .text(event.text, delayMilliseconds: event.delayMilliseconds)
        case .keyPress(let event):
            self = .keyPress(
                key: event.key,
                modifiers: event.modifiers.map(BackgroundKeyboardModifier.init),
                count: event.count
            )
        case .hotkey(let event):
            self = .hotkey(
                modifiers: event.modifiers.map(BackgroundKeyboardModifier.init),
                key: event.key
            )
        }
    }
}

private extension ComputerUseKeyboardEvent {
    init(_ event: BackgroundKeyboardEvent) {
        switch event {
        case .text(let text, let delayMilliseconds):
            self = .text(ComputerUseKeyboardTextEvent(
                text: text,
                delayMilliseconds: delayMilliseconds
            ))
        case .keyPress(let key, let modifiers, let count):
            self = .keyPress(ComputerUseKeyboardKeyPressEvent(
                key: key,
                modifiers: modifiers.map(ComputerUseKeyboardModifier.init),
                count: count
            ))
        case .hotkey(let modifiers, let key):
            self = .hotkey(ComputerUseKeyboardHotkeyEvent(
                modifiers: modifiers.map(ComputerUseKeyboardModifier.init),
                key: key
            ))
        }
    }
}

private extension ComputerUsePostKeyboardEventResult {
    init(_ result: WindowKeyboardEventResult) {
        self.init(
            pid: Int(result.pid),
            windowId: Int(result.windowId),
            event: ComputerUseKeyboardEvent(result.event)
        )
    }
}

private extension AXElementAction {
    init(_ value: ComputerUseAXElementAction) {
        switch value {
        case .press: self = .press
        case .showMenu: self = .showMenu
        case .pick: self = .pick
        case .confirm: self = .confirm
        case .cancel: self = .cancel
        case .open: self = .open
        case .increment: self = .increment
        case .decrement: self = .decrement
        case .scrollToVisible: self = .scrollToVisible
        }
    }
}

private extension ComputerUseAXElementAction {
    init(_ value: AXElementAction) {
        switch value {
        case .press: self = .press
        case .showMenu: self = .showMenu
        case .pick: self = .pick
        case .confirm: self = .confirm
        case .cancel: self = .cancel
        case .open: self = .open
        case .increment: self = .increment
        case .decrement: self = .decrement
        case .scrollToVisible: self = .scrollToVisible
        }
    }
}

private extension AXScrollDirection {
    init(_ value: ComputerUseAXScrollDirection) {
        switch value {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }
}

private extension ComputerUseAXScrollDirection {
    init(_ value: AXScrollDirection) {
        switch value {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }
}

private extension AXElementEvent {
    init(_ value: ComputerUseAXElementEvent) {
        switch value {
        case .action(let event):
            self = .action(AXElementAction(event.action))
        case .setValue(let event):
            self = .setValue(event.value)
        case .setSelectedText(let event):
            self = .setSelectedText(event.value)
        case .focus:
            self = .focus
        case .scroll(let event):
            self = .scroll(
                direction: AXScrollDirection(event.direction),
                pages: event.pages
            )
        }
    }
}

private extension ComputerUseAXElementEvent {
    init(_ event: AXElementEvent) {
        switch event {
        case .action(let action):
            self = .action(ComputerUseAXActionEvent(action: ComputerUseAXElementAction(action)))
        case .setValue(let value):
            self = .setValue(ComputerUseAXSetValueEvent(value: value))
        case .setSelectedText(let value):
            self = .setSelectedText(ComputerUseAXSetValueEvent(value: value))
        case .focus:
            self = .focus
        case .scroll(let direction, let pages):
            self = .scroll(ComputerUseAXScrollEvent(
                direction: ComputerUseAXScrollDirection(direction),
                pages: pages
            ))
        }
    }
}

private extension ComputerUsePostEventToAXElementResult {
    init(_ result: AXElementEventResult) {
        self.init(
            pid: Int(result.pid),
            windowId: Int(result.windowId),
            stateId: result.stateId.raw,
            elementIndex: result.elementIndex,
            event: ComputerUseAXElementEvent(result.event)
        )
    }
}
