import AOSComputerUseKit
import CoreGraphics
import Darwin
import Foundation

extension ComputerUseCLI {
    static func runPostCursor(
        request: PostCursorRequest,
        core: ComputerUseCoreClient,
        io: PostCursorIO,
        overlay: PostCursorOverlay
    ) async throws -> PostCursorResult {
        let movementStep: CGFloat = 10
        let session = try await core.currentAppSession()
        let pid = session.pid
        let window = try await resolvePostCursorWindow(
            pid: pid,
            requestedWindowId: request.windowId,
            core: core,
            io: io
        )
        let eventKind = try await resolvePostCursorEventKind(io: io)
        if eventKind == .drag {
            try await requireWebContentDragTarget(pid: pid, core: core)
        }
        var localPoint = request.coordinate ?? CGPoint(
            x: floor(window.bounds.width / 2),
            y: floor(window.bounds.height / 2)
        )
        localPoint = clamp(localPoint, to: window.bounds)
        var currentScreenPoint = screenPoint(localPoint: localPoint, window: window)
        var postedEventCount = 0
        var lastEvent: BackgroundMouseEvent?

        try await overlay.show(at: currentScreenPoint)
        await io.write(postCursorStatus(window: window, eventKind: eventKind, localPoint: localPoint))

        do {
            while true {
                switch eventKind {
                case .leftClick, .rightClick:
                    switch try await readPostCursorPoint(
                        localPoint: &localPoint,
                        currentScreenPoint: &currentScreenPoint,
                        window: window,
                        movementStep: movementStep,
                        io: io,
                        overlay: overlay
                    ) {
                    case .confirm:
                        let event = try postCursorPointEvent(
                            eventKind: eventKind,
                            screenPoint: currentScreenPoint
                        )
                        let result = try await core.postMouseEvent(
                            windowId: window.id,
                            event: event
                        )
                        postedEventCount += 1
                        lastEvent = result.event
                        await io.write(postCursorPostedStatus(
                            event: result.event,
                            localPoint: localPoint,
                            window: window,
                            postedEventCount: postedEventCount
                        ))
                    case .quit:
                        await overlay.hide()
                        return finishPostCursor(
                            pid: pid,
                            window: window,
                            point: currentScreenPoint,
                            localPoint: localPoint,
                            eventKind: eventKind,
                            postedEventCount: postedEventCount,
                            lastEvent: lastEvent
                        )
                    }
                case .drag:
                    await io.write("drag start: move cursor, Enter selects start, Q exits\n")
                    switch try await readPostCursorPoint(
                        localPoint: &localPoint,
                        currentScreenPoint: &currentScreenPoint,
                        window: window,
                        movementStep: movementStep,
                        io: io,
                        overlay: overlay
                    ) {
                    case .confirm:
                        break
                    case .quit:
                        await overlay.hide()
                        return finishPostCursor(
                            pid: pid,
                            window: window,
                            point: currentScreenPoint,
                            localPoint: localPoint,
                            eventKind: eventKind,
                            postedEventCount: postedEventCount,
                            lastEvent: lastEvent
                        )
                    }
                    let startLocalPoint = localPoint
                    let startScreenPoint = currentScreenPoint
                    await io.write("drag end: move cursor, Enter posts drag, Q exits\n")
                    switch try await readPostCursorPoint(
                        localPoint: &localPoint,
                        currentScreenPoint: &currentScreenPoint,
                        window: window,
                        movementStep: movementStep,
                        io: io,
                        overlay: overlay
                    ) {
                    case .confirm:
                        let event = BackgroundMouseEvent.drag(
                            button: .left,
                            from: startScreenPoint,
                            to: currentScreenPoint
                        )
                        let result = try await core.postMouseEvent(
                            windowId: window.id,
                            event: event
                        )
                        postedEventCount += 1
                        lastEvent = result.event
                        await io.write(postCursorPostedStatus(
                            event: result.event,
                            localPoint: localPoint,
                            window: window,
                            postedEventCount: postedEventCount,
                            extra: " from local \(Int(startLocalPoint.x)),\(Int(startLocalPoint.y))"
                        ))
                    case .quit:
                        await overlay.hide()
                        return finishPostCursor(
                            pid: pid,
                            window: window,
                            point: currentScreenPoint,
                            localPoint: localPoint,
                            eventKind: eventKind,
                            postedEventCount: postedEventCount,
                            lastEvent: lastEvent
                        )
                    }
                }
            }
        } catch {
            await overlay.hide()
            throw error
        }
    }

    private static func readPostCursorPoint(
        localPoint: inout CGPoint,
        currentScreenPoint: inout CGPoint,
        window: WindowInfo,
        movementStep: CGFloat,
        io: PostCursorIO,
        overlay: PostCursorOverlay
    ) async throws -> PostCursorPointAction {
        while true {
            switch try await io.readKey() {
            case .up:
                localPoint.y -= movementStep
            case .down:
                localPoint.y += movementStep
            case .left:
                localPoint.x -= movementStep
            case .right:
                localPoint.x += movementStep
            case .confirm:
                return .confirm
            case .character, .backspace:
                continue
            case .quit:
                return .quit
            }

            localPoint = clamp(localPoint, to: window.bounds)
            currentScreenPoint = screenPoint(localPoint: localPoint, window: window)
            try await overlay.move(to: currentScreenPoint)
        }
    }

    private static func postCursorPointEvent(
        eventKind: PostCursorEventKind,
        screenPoint: CGPoint
    ) throws -> BackgroundMouseEvent {
        switch eventKind {
        case .leftClick:
            return .click(button: .left, point: screenPoint)
        case .rightClick:
            return .click(button: .right, point: screenPoint)
        case .drag:
            throw ComputerUseCLIInvariantError("drag does not use point event conversion")
        }
    }

    private static func resolvePostCursorEventKind(io: PostCursorIO) async throws -> PostCursorEventKind {
        let raw = try await io.readLine(prompt: "Select mouse event (left-click/right-click/drag): ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eventKind = PostCursorEventKind(rawValue: raw) else {
            throw UsageError("invalid mouse event selection: \(raw)")
        }
        return eventKind
    }

    private static func finishPostCursor(
        pid: pid_t,
        window: WindowInfo,
        point: CGPoint,
        localPoint: CGPoint,
        eventKind: PostCursorEventKind,
        postedEventCount: Int,
        lastEvent: BackgroundMouseEvent?
    ) -> PostCursorResult {
        PostCursorResult(
            pid: pid,
            windowId: window.id,
            point: point,
            localPoint: localPoint,
            eventKind: eventKind,
            postedEventCount: postedEventCount,
            lastEvent: lastEvent
        )
    }

    private static func resolvePostCursorWindow(
        pid: pid_t,
        requestedWindowId: CGWindowID?,
        core: ComputerUseCoreClient,
        io: PostCursorIO
    ) async throws -> WindowInfo {
        let windows = try await core.listWindows(pid: pid)
        if let requestedWindowId {
            guard let window = windows.first(where: { $0.id == requestedWindowId }) else {
                throw UsageError("window \(requestedWindowId) for pid \(pid) is not available")
            }
            return window
        }

        if windows.isEmpty {
            throw UsageError("pid \(pid) has no layer-0 windows")
        }
        await io.write("Windows for pid \(pid)\n")
        for window in windows {
            let title = window.title.isEmpty ? "(untitled)" : window.title
            await io.write("\(window.id) \(title) \(Int(window.bounds.width))x\(Int(window.bounds.height)) @ \(Int(window.bounds.x)),\(Int(window.bounds.y))\n")
        }
        let raw = try await io.readLine(prompt: "Select window id: ")
        guard let selected = UInt32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UsageError("invalid window selection: \(raw)")
        }
        guard let window = windows.first(where: { $0.id == selected }) else {
            throw UsageError("window \(selected) for pid \(pid) is not available")
        }
        return window
    }

    private static func screenPoint(localPoint: CGPoint, window: WindowInfo) -> CGPoint {
        CGPoint(x: window.bounds.x + localPoint.x, y: window.bounds.y + localPoint.y)
    }

    private static func clamp(_ point: CGPoint, to bounds: WindowBounds) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), max(bounds.width - 1, 0)),
            y: min(max(point.y, 0), max(bounds.height - 1, 0))
        )
    }

    private static func postCursorStatus(
        window: WindowInfo,
        eventKind: PostCursorEventKind,
        localPoint: CGPoint
    ) -> String {
        """
        Post cursor attached to window \(window.id) (pid \(window.pid)).
        Event: \(eventKind.rawValue).
        Arrow keys move the cursor. Enter executes. Q exits.

        """
    }

    private static func postCursorPostedStatus(
        event: BackgroundMouseEvent,
        localPoint: CGPoint,
        window: WindowInfo,
        postedEventCount: Int,
        extra: String = ""
    ) -> String {
        "posted \(postCursorEventName(event)) #\(postedEventCount) at local \(Int(localPoint.x)),\(Int(localPoint.y))\(extra). Enter executes again. Q exits.\n"
    }

    private static func postCursorEventName(_ event: BackgroundMouseEvent) -> String {
        switch event {
        case .click(let button, _, _):
            "\(button.rawValue)-click"
        case .drag(let button, _, _):
            "\(button.rawValue)-drag"
        }
    }
}
