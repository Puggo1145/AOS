import AppKit
import CoreGraphics
import Darwin
import Foundation

private let windowTitle = "AOS Coordinate Reliability Target"
private let clearNotificationName = Notification.Name("com.aos.coordinateTarget.clear")

private struct EventRecord: Codable {
    let kind: String
    let x: Double
    let y: Double
    let timestampMs: Int
    let dx: Double?
    let dy: Double?
}

@main
final class CoordinateTargetApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var eventLogURL: URL?
    private var parentPid: pid_t?
    private var parentMonitor: Timer?

    static func main() {
        let app = NSApplication.shared
        let delegate = CoordinateTargetApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        eventLogURL = Self.parseEventLogURL(arguments: ProcessInfo.processInfo.arguments)
        parentPid = Self.parseParentPid(arguments: ProcessInfo.processInfo.arguments)
        guard let eventLogURL else {
            fatalError("AOSCoordinateTarget requires --events <path>")
        }
        FileManager.default.createFile(atPath: eventLogURL.path, contents: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.contentView = CoordinateCanvasView(
            frame: window.contentView?.bounds ?? .zero,
            eventLogURL: eventLogURL
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        startParentMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private static func parseEventLogURL(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--events") else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return URL(fileURLWithPath: arguments[valueIndex])
    }

    private static func parseParentPid(arguments: [String]) -> pid_t? {
        guard let index = arguments.firstIndex(of: "--parent-pid") else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex),
              let parsed = Int32(arguments[valueIndex])
        else { return nil }
        return pid_t(parsed)
    }

    private func startParentMonitor() {
        guard let parentPid else { return }
        parentMonitor = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if kill(parentPid, 0) != 0 {
                NSApp.terminate(nil)
            }
        }
    }
}

private final class CoordinateCanvasView: NSView {
    private let eventLogURL: URL
    private var events: [EventRecord] = []
    private var clearObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame frameRect: NSRect, eventLogURL: URL) {
        self.eventLogURL = eventLogURL
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Coordinate reliability canvas") // [VERIFY] dev-only label.
        clearObserver = DistributedNotificationCenter.default().addObserver(
            forName: clearNotificationName,
            object: eventLogURL.path,
            queue: .main
        ) { [weak self] _ in
            self?.clearEvents()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let clearObserver {
            DistributedNotificationCenter.default().removeObserver(clearObserver)
        }
    }

    override func viewDidMoveToWindow() {
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseDown(with event: NSEvent) {
        record(kind: "mouseDown", event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        record(kind: "mouseDragged", event: event)
    }

    override func mouseUp(with event: NSEvent) {
        record(kind: "mouseUp", event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        append(
            EventRecord(
                kind: "scroll",
                x: point.x,
                y: point.y,
                timestampMs: Self.nowMs(),
                dx: event.scrollingDeltaX,
                dy: event.scrollingDeltaY
            )
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBackground()
        drawGrid()
        drawEvents()
    }

    private func record(kind: String, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        append(
            EventRecord(
                kind: kind,
                x: point.x,
                y: point.y,
                timestampMs: Self.nowMs(),
                dx: nil,
                dy: nil
            )
        )
    }

    private func append(_ record: EventRecord) {
        events.append(record)
        guard let data = try? JSONEncoder().encode(record),
              let line = String(data: data, encoding: .utf8)
        else {
            fatalError("failed to encode coordinate event")
        }
        do {
            let handle = try FileHandle(forWritingTo: eventLogURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.close()
        } catch {
            fatalError("failed to write coordinate event log: \(error)")
        }
        needsDisplay = true
    }

    private func clearEvents() {
        events = []
        needsDisplay = true
    }

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private func drawBackground() {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    private func drawGrid() {
        let minor: CGFloat = 10
        let major: CGFloat = 50

        let path = NSBezierPath()
        path.lineWidth = 1
        var x: CGFloat = 0
        while x <= bounds.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: bounds.height))
            x += minor
        }
        var y: CGFloat = 0
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
            majorPath.move(to: CGPoint(x: x, y: 0))
            majorPath.line(to: CGPoint(x: x, y: bounds.height))
            drawLabel("\(Int(x))", at: CGPoint(x: x + 3, y: 3))
            x += major
        }
        y = 0
        while y <= bounds.height {
            majorPath.move(to: CGPoint(x: 0, y: y))
            majorPath.line(to: CGPoint(x: bounds.width, y: y))
            drawLabel("\(Int(y))", at: CGPoint(x: 3, y: y + 3))
            y += major
        }
        NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
        majorPath.stroke()
    }

    private func drawEvents() {
        guard !events.isEmpty else { return }

        let path = NSBezierPath()
        path.lineWidth = 2
        var previous: CGPoint?
        for event in events where event.kind != "scroll" {
            let point = CGPoint(x: event.x, y: event.y)
            if let previous {
                path.move(to: previous)
                path.line(to: point)
            }
            previous = point
        }
        NSColor.systemOrange.setStroke()
        path.stroke()

        for (index, event) in events.enumerated() {
            drawMarker(event, index: index + 1)
        }
    }

    private func drawMarker(_ event: EventRecord, index: Int) {
        let color: NSColor
        switch event.kind {
        case "mouseDown": color = .systemGreen
        case "mouseDragged": color = .systemOrange
        case "mouseUp": color = .systemBlue
        case "scroll": color = .systemPurple
        default: color = .systemRed
        }
        let point = CGPoint(x: event.x, y: event.y)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        drawLabel("\(index)", at: CGPoint(x: point.x + 6, y: point.y + 4))
    }

    private func drawLabel(_ value: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        value.draw(at: point, withAttributes: attrs)
    }
}
