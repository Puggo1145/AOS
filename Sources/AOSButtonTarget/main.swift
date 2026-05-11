import AppKit
import Foundation

private struct ButtonEventRecord: Encodable {
    let timestamp: TimeInterval
    let type: String
    let clickCount: Int
    let x: Double
    let y: Double
    let screenX: Double
    let screenY: Double
    let windowNumber: Int
}

final class ButtonTargetApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let eventLogURL: URL

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let eventLog = Self.value(after: "--events", in: arguments) else {
            FileHandle.standardError.write(Data("AOSButtonTarget requires --events <path>\n".utf8))
            exit(64)
        }
        self.eventLogURL = URL(fileURLWithPath: eventLog)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = NSSize(width: 520, height: 360)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AOS Button Reliability Target"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = size
        window.backgroundColor = .windowBackgroundColor
        window.contentView = ButtonProbeView(eventLogURL: eventLogURL)
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

private final class ButtonProbeView: NSView {
    private let eventLogURL: URL
    private let button = FirstMouseButton(title: "Clicked 0 times", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "AOS Button Target")
    private let statusLabel = NSTextField(labelWithString: "Click the centered button with post-left-click --coor.")
    private var clickCount = 0

    override var isFlipped: Bool { true }

    init(eventLogURL: URL) {
        self.eventLogURL = eventLogURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let buttonSize = NSSize(width: 220, height: 54)
        button.frame = NSRect(
            x: (bounds.width - buttonSize.width) / 2,
            y: (bounds.height - buttonSize.height) / 2,
            width: buttonSize.width,
            height: buttonSize.height
        )
        titleLabel.frame = NSRect(x: 24, y: 26, width: bounds.width - 48, height: 28)
        statusLabel.frame = NSRect(x: 24, y: button.frame.maxY + 32, width: bounds.width - 48, height: 24)
    }

    private func configureViews() {
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center

        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        statusLabel.alignment = .center

        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 18, weight: .semibold)

        addSubview(titleLabel)
        addSubview(button)
        addSubview(statusLabel)
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        clickCount += 1
        button.title = "Clicked \(clickCount) \(clickCount == 1 ? "time" : "times")"
        statusLabel.stringValue = "Last button action count: \(clickCount)"
        append(record(from: NSApp.currentEvent, type: "buttonAction"))
    }

    private func record(from event: NSEvent?, type: String) -> ButtonEventRecord {
        let local: CGPoint
        let screen: CGPoint
        let windowNumber: Int
        if let event {
            local = convert(event.locationInWindow, from: nil)
            screen = event.locationInWindow.screenPoint(in: window)
            windowNumber = event.windowNumber
        } else {
            local = CGPoint(x: bounds.midX, y: bounds.midY)
            screen = window?.convertToScreen(NSRect(origin: local, size: .zero)).origin ?? local
            windowNumber = window?.windowNumber ?? 0
        }
        return ButtonEventRecord(
            timestamp: Date().timeIntervalSince1970,
            type: type,
            clickCount: clickCount,
            x: local.x,
            y: local.y,
            screenX: screen.x,
            screenY: screen.y,
            windowNumber: windowNumber
        )
    }

    private func append(_ event: ButtonEventRecord) {
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
            FileHandle.standardError.write(Data("failed to write button event log: \(error)\n".utf8))
        }
    }
}

private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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
let delegate = ButtonTargetApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
