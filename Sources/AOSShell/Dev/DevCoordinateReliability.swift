import AppKit
import CoreGraphics
import SwiftUI
import AOSComputerUseKit

// MARK: - DevCoordinateScript

enum DevCoordinateScript {
    enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformedLine(Int, String)
        case empty

        var description: String {
            switch self {
            case .malformedLine(let line, let value):
                return "line \(line) is not an x,y coordinate: \(value)"
            case .empty:
                return "coordinate script is empty"
            }
        }
    }

    static func parse(_ script: String) throws -> [CGPoint] {
        let lines = script.split(whereSeparator: \.isNewline)
        var points: [CGPoint] = []
        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line
                .split { $0 == "," || $0 == " " || $0 == "\t" }
                .map(String.init)
            guard parts.count == 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]),
                  x.isFinite,
                  y.isFinite
            else {
                throw ParseError.malformedLine(offset + 1, line)
            }
            points.append(CGPoint(x: x, y: y))
        }
        if points.isEmpty { throw ParseError.empty }
        return points
    }
}

// MARK: - DevCoordinateReliabilityInput

enum DevCoordinateReliabilityInput {
    static func screenshotPixel(
        fromTargetPoint point: CGPoint,
        coordinateSpace: ScreenshotCoordinateSpace
    ) -> CGPoint {
        let frame = coordinateSpace.windowFrame
        let pixels = coordinateSpace.pixelSize
        guard frame.width > 0, frame.height > 0 else {
            return CGPoint(x: Double.nan, y: Double.nan)
        }
        return CGPoint(
            x: point.x * pixels.width / frame.width,
            y: point.y * pixels.height / frame.height
        )
    }
}

// MARK: - DevCoordinateReliabilityLayout

enum DevCoordinateReliabilityLayout {
    static let dragRegionHeight: CGFloat = 34

    static func isDragRegion(_ point: CGPoint) -> Bool {
        point.y >= 0 && point.y < dragRegionHeight
    }

    static func shouldRecordCoordinateEvent(point: CGPoint, isWindowDragSequence: Bool) -> Bool {
        !isWindowDragSequence && !isDragRegion(point)
    }
}

// MARK: - DevCoordinateReliabilityResult

struct DevCoordinateReliabilityResult: Identifiable, Equatable {
    let index: Int
    let expected: CGPoint
    let actual: CGPoint
    let tolerancePixels: Double

    var id: Int { index }

    var delta: CGSize {
        CGSize(
            width: actual.x - expected.x,
            height: actual.y - expected.y
        )
    }

    var distance: Double {
        hypot(delta.width, delta.height)
    }

    var passed: Bool {
        distance <= tolerancePixels
    }
}

// MARK: - DevCoordinateMouseEvent

enum DevCoordinateMouseEventKind: String, Equatable {
    case mouseDown
    case mouseDragged
    case mouseUp
    case scroll
}

struct DevCoordinateMouseEvent: Identifiable, Equatable {
    let id = UUID()
    let kind: DevCoordinateMouseEventKind
    let point: CGPoint
    let timestamp: Date
    let scrollDelta: CGSize?
}

private struct DevCoordinateTargetEventRecord: Codable {
    let kind: String
    let x: Double
    let y: Double
    let timestampMs: Int
    let dx: Double?
    let dy: Double?

    func event() throws -> DevCoordinateMouseEvent {
        guard let kind = DevCoordinateMouseEventKind(rawValue: kind) else {
            throw DevComputerUseInputError.invalid(label: "coordinate target event kind", value: self.kind)
        }
        return DevCoordinateMouseEvent(
            kind: kind,
            point: CGPoint(x: x, y: y),
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000),
            scrollDelta: dx.map { CGSize(width: $0, height: dy ?? 0) }
        )
    }
}

// MARK: - DevCoordinateReliabilityStore

@MainActor
@Observable
final class DevCoordinateReliabilityStore {
    var events: [DevCoordinateMouseEvent] = []
    var canvasSize: CGSize = .zero

    var clickEvents: [DevCoordinateMouseEvent] {
        events.filter { $0.kind == .mouseDown }
    }

    func reset() {
        events = []
    }

    func updateCanvasSize(_ size: CGSize) {
        canvasSize = size
    }

    func record(kind: DevCoordinateMouseEventKind, point: CGPoint, scrollDelta: CGSize? = nil) {
        events.append(
            DevCoordinateMouseEvent(
                kind: kind,
                point: point,
                timestamp: Date(),
                scrollDelta: scrollDelta
            )
        )
    }
}

// MARK: - DevCoordinateReliabilityTargetProcess

@MainActor
final class DevCoordinateReliabilityTargetProcess {
    static let windowTitle = "AOS Coordinate Reliability Target"
    private static let clearNotificationName = Notification.Name("com.aos.coordinateTarget.clear")

    private var process: Process?
    let eventLogURL: URL

    init(eventLogURL: URL? = nil) {
        self.eventLogURL = eventLogURL
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("aos-coordinate-target-\(UUID().uuidString).jsonl")
    }

    deinit {
        process?.terminate()
    }

    var pid: pid_t? {
        process?.isRunning == true ? process?.processIdentifier : nil
    }

    func launch() throws {
        if process?.isRunning == true { return }

        let executableURL = try Self.resolveExecutableURL()
        try Data().write(to: eventLogURL, options: .atomic)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--events", eventLogURL.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        try process.run()
        self.process = process
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    func clearEvents() throws {
        try Data().write(to: eventLogURL, options: .atomic)
        DistributedNotificationCenter.default().post(
            name: Self.clearNotificationName,
            object: eventLogURL.path,
            userInfo: nil
        )
    }

    func readEvents() throws -> [DevCoordinateMouseEvent] {
        let data = try Data(contentsOf: eventLogURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DevComputerUseInputError.invalid(label: "coordinate target event log", value: eventLogURL.path)
        }
        return try text
            .split(whereSeparator: \.isNewline)
            .map { line in
                let data = Data(line.utf8)
                let record = try JSONDecoder().decode(DevCoordinateTargetEventRecord.self, from: data)
                return try record.event()
            }
    }

    private static func resolveExecutableURL() throws -> URL {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw DevComputerUseInputError.missingTarget("Bundle.main.resourceURL")
        }
        let url = resourceURL
            .appendingPathComponent("dev")
            .appendingPathComponent("AOSCoordinateTarget")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw DevComputerUseInputError.missingTarget(url.path)
        }
        return url
    }
}

// MARK: - DevCoordinateReliabilityWindowController

@MainActor
final class DevCoordinateReliabilityWindowController: NSWindowController {
    let store: DevCoordinateReliabilityStore

    init(store: DevCoordinateReliabilityStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AOS Coordinate Reliability Target"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: DevCoordinateReliabilityTargetView(store: store)
        )
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

// MARK: - DevCoordinateReliabilityTargetView

struct DevCoordinateReliabilityTargetView: View {
    let store: DevCoordinateReliabilityStore

    var body: some View {
        let eventCount = store.events.count
        DevCoordinateCanvasView(store: store, redrawToken: eventCount)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Coordinate reliability target")
    }
}

// MARK: - DevCoordinateCanvasView

struct DevCoordinateCanvasView: NSViewRepresentable {
    let store: DevCoordinateReliabilityStore
    let redrawToken: Int

    func makeNSView(context: Context) -> CanvasNSView {
        CanvasNSView(store: store)
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        nsView.store = store
        nsView.needsDisplay = true
    }

    final class CanvasNSView: NSView {
        @MainActor var store: DevCoordinateReliabilityStore
        private var isDraggingWindow = false

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        @MainActor
        init(store: DevCoordinateReliabilityStore) {
            self.store = store
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel("Coordinate reliability canvas") // [VERIFY] dev-only label.
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            window?.acceptsMouseMovedEvents = true
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            store.updateCanvasSize(newSize)
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if DevCoordinateReliabilityLayout.isDragRegion(point) {
                isDraggingWindow = true
                window?.performDrag(with: event)
                return
            }
            isDraggingWindow = false
            record(.mouseDown, event: event)
        }

        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard DevCoordinateReliabilityLayout.shouldRecordCoordinateEvent(
                point: point,
                isWindowDragSequence: isDraggingWindow
            ) else { return }
            record(.mouseDragged, event: event)
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard DevCoordinateReliabilityLayout.shouldRecordCoordinateEvent(
                point: point,
                isWindowDragSequence: isDraggingWindow
            ) else {
                isDraggingWindow = false
                return
            }
            record(.mouseUp, event: event)
        }

        override func scrollWheel(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard DevCoordinateReliabilityLayout.shouldRecordCoordinateEvent(
                point: point,
                isWindowDragSequence: isDraggingWindow
            ) else {
                return
            }
            store.record(
                kind: .scroll,
                point: point,
                scrollDelta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            )
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            drawBackground()
            drawGrid()
            drawEvents()
        }

        private func record(_ kind: DevCoordinateMouseEventKind, event: NSEvent) {
            store.record(kind: kind, point: convert(event.locationInWindow, from: nil))
            needsDisplay = true
        }

        private func drawBackground() {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()

            let headerRect = NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: min(DevCoordinateReliabilityLayout.dragRegionHeight, bounds.height)
            )
            NSColor.controlBackgroundColor.setFill()
            headerRect.fill()
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            NSBezierPath.strokeLine(
                from: CGPoint(x: bounds.minX, y: headerRect.maxY),
                to: CGPoint(x: bounds.maxX, y: headerRect.maxY)
            )
            drawHeaderTitle(in: headerRect)
        }

        private func drawGrid() {
            let minor: CGFloat = 10
            let major: CGFloat = 50
            let gridMinY = min(DevCoordinateReliabilityLayout.dragRegionHeight, bounds.height)

            let path = NSBezierPath()
            path.lineWidth = 1
            var x: CGFloat = 0
            while x <= bounds.width {
                path.move(to: CGPoint(x: x, y: gridMinY))
                path.line(to: CGPoint(x: x, y: bounds.height))
                x += minor
            }
            var y = ceil(gridMinY / minor) * minor
            while y <= bounds.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.line(to: CGPoint(x: bounds.width, y: y))
                y += minor
            }
            NSColor.separatorColor.withAlphaComponent(0.22).setStroke()
            path.stroke()

            let majorPath = NSBezierPath()
            majorPath.lineWidth = 1.5
            x = 0
            while x <= bounds.width {
                majorPath.move(to: CGPoint(x: x, y: gridMinY))
                majorPath.line(to: CGPoint(x: x, y: bounds.height))
                drawLabel("\(Int(x))", at: CGPoint(x: x + 3, y: gridMinY + 3))
                x += major
            }
            y = ceil(gridMinY / major) * major
            while y <= bounds.height {
                majorPath.move(to: CGPoint(x: 0, y: y))
                majorPath.line(to: CGPoint(x: bounds.width, y: y))
                drawLabel("\(Int(y))", at: CGPoint(x: 3, y: y + 3))
                y += major
            }
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            majorPath.stroke()
        }

        private func drawHeaderTitle(in rect: NSRect) {
            let value = "Coordinate Reliability Target"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = value.size(withAttributes: attrs)
            value.draw(
                at: CGPoint(
                    x: max(rect.midX - size.width / 2, rect.minX + 72),
                    y: rect.midY - size.height / 2
                ),
                withAttributes: attrs
            )
        }

        private func drawEvents() {
            let events = store.events
            guard !events.isEmpty else { return }

            let path = NSBezierPath()
            path.lineWidth = 2
            var previous: CGPoint?
            for event in events where event.kind != .scroll {
                if let previous {
                    path.move(to: previous)
                    path.line(to: event.point)
                }
                previous = event.point
            }
            NSColor.systemOrange.setStroke()
            path.stroke()

            for (index, event) in events.enumerated() {
                drawMarker(event, index: index + 1)
            }
        }

        private func drawMarker(_ event: DevCoordinateMouseEvent, index: Int) {
            let color: NSColor = switch event.kind {
            case .mouseDown: .systemGreen
            case .mouseDragged: .systemOrange
            case .mouseUp: .systemBlue
            case .scroll: .systemPurple
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: event.point.x - 4,
                y: event.point.y - 4,
                width: 8,
                height: 8
            )).fill()
            drawLabel("\(index)", at: CGPoint(x: event.point.x + 6, y: event.point.y + 4))
        }

        private func drawLabel(_ value: String, at point: CGPoint) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            value.draw(at: point, withAttributes: attrs)
        }
    }
}
