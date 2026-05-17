import AppKit
import CoreGraphics
import Foundation

private struct EventRecord: Encodable {
    let timestamp: TimeInterval
    let type: String
    let x: Double
    let y: Double
    let screenX: Double
    let screenY: Double
    let windowNumber: Int
}

final class CoordinateTargetApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var localMouseMonitor: Any?
    private let eventLogURL: URL

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let eventLog = Self.value(after: "--events", in: arguments) else {
            FileHandle.standardError.write(Data("CoordinateTarget requires --events <path>\n".utf8))
            exit(64)
        }
        self.eventLogURL = URL(fileURLWithPath: eventLog)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = NSSize(width: 720, height: 480)
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Notch Agent Coordinate Reliability Target"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = size
        window.backgroundColor = .windowBackgroundColor
        let canvas = CoordinateCanvasView(eventLogURL: eventLogURL)
        window.contentView = canvas
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak canvas] event in
            canvas?.recordLocalMonitorEvent(event)
            return event
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        return arguments[valueIndex]
    }
}

private final class CoordinateCanvasView: NSView {
    private let eventLogURL: URL
    private var lastEvent: EventRecord?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(eventLogURL: URL) {
        self.eventLogURL = eventLogURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        bounds.fill()
        drawGrid()
        drawLabels()
        drawLastEvent()
    }

    override func mouseDown(with event: NSEvent) {
        record(event, type: "mouseDown")
    }

    override func mouseDragged(with event: NSEvent) {
        record(event, type: "mouseDragged")
    }

    override func mouseUp(with event: NSEvent) {
        record(event, type: "mouseUp")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func recordLocalMonitorEvent(_ event: NSEvent) {
        record(event, type: "localMonitor:\(event.type.coordinateEventName)")
    }

    private func record(_ event: NSEvent, type: String) {
        let local = convert(event.locationInWindow, from: nil)
        let screen = event.locationInWindow.screenPoint(in: window)
        let record = EventRecord(
            timestamp: Date().timeIntervalSince1970,
            type: type,
            x: local.x,
            y: local.y,
            screenX: screen.x,
            screenY: screen.y,
            windowNumber: event.windowNumber
        )
        lastEvent = record
        append(record)
        needsDisplay = true
    }

    private func append(_ event: EventRecord) {
        do {
            let data = try JSONEncoder().encode(event)
            try FileManager.default.createDirectory(
                at: eventLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = data + Data("\n".utf8)
            if FileManager.default.fileExists(atPath: eventLogURL.path) {
                let handle = try FileHandle(forWritingTo: eventLogURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: eventLogURL, options: .atomic)
            }
        } catch {
            FileHandle.standardError.write(Data("failed to write coordinate event log: \(error)\n".utf8))
        }
    }

    private func drawGrid() {
        let path = NSBezierPath()
        path.lineWidth = 1
        let major = CGFloat(100)
        let minor = CGFloat(25)
        for x in stride(from: CGFloat(0), through: bounds.width, by: minor) {
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: bounds.height))
        }
        for y in stride(from: CGFloat(0), through: bounds.height, by: minor) {
            path.move(to: CGPoint(x: 0, y: y))
            path.line(to: CGPoint(x: bounds.width, y: y))
        }
        NSColor(calibratedWhite: 0.18, alpha: 1).setStroke()
        path.stroke()

        let majorPath = NSBezierPath()
        majorPath.lineWidth = 1.5
        for x in stride(from: CGFloat(0), through: bounds.width, by: major) {
            majorPath.move(to: CGPoint(x: x, y: 0))
            majorPath.line(to: CGPoint(x: x, y: bounds.height))
        }
        for y in stride(from: CGFloat(0), through: bounds.height, by: major) {
            majorPath.move(to: CGPoint(x: 0, y: y))
            majorPath.line(to: CGPoint(x: bounds.width, y: y))
        }
        NSColor(calibratedWhite: 0.32, alpha: 1).setStroke()
        majorPath.stroke()
    }

    private func drawLabels() {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ]
        "Notch Agent Coordinate Target  origin: top-left  units: window points"
            .draw(at: CGPoint(x: 16, y: 16), withAttributes: attrs)

        let tickAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1),
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        ]
        for x in stride(from: CGFloat(0), through: bounds.width, by: 100) {
            "\(Int(x))".draw(at: CGPoint(x: x + 4, y: 40), withAttributes: tickAttrs)
        }
        for y in stride(from: CGFloat(0), through: bounds.height, by: 100) {
            "\(Int(y))".draw(at: CGPoint(x: 8, y: y + 4), withAttributes: tickAttrs)
        }
    }

    private func drawLastEvent() {
        guard let lastEvent else {
            return
        }
        let point = CGPoint(x: lastEvent.x, y: lastEvent.y)
        NSColor.systemRed.setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 2
        cross.move(to: CGPoint(x: point.x - 12, y: point.y))
        cross.line(to: CGPoint(x: point.x + 12, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - 12))
        cross.line(to: CGPoint(x: point.x, y: point.y + 12))
        cross.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
        ]
        "\(lastEvent.type) \(Int(lastEvent.x)),\(Int(lastEvent.y))"
            .draw(at: CGPoint(x: 16, y: bounds.height - 32), withAttributes: attrs)
    }
}

private extension NSEvent.EventType {
    var coordinateEventName: String {
        switch self {
        case .mouseMoved:
            return "mouseMoved"
        case .leftMouseDown:
            return "leftMouseDown"
        case .leftMouseDragged:
            return "leftMouseDragged"
        case .leftMouseUp:
            return "leftMouseUp"
        default:
            return "\(rawValue)"
        }
    }
}

private extension NSPoint {
    func screenPoint(in window: NSWindow?) -> CGPoint {
        guard let window else {
            return self
        }
        let rect = NSRect(origin: self, size: .zero)
        return window.convertToScreen(rect).origin
    }
}

let app = NSApplication.shared
let delegate = CoordinateTargetApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
