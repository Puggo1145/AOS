import AppKit
import CoreGraphics
import Darwin
import Foundation

public struct LivePostCursorIO: PostCursorIO {
    public init() {}

    public func write(_ text: String) async {
        FileHandle.standardError.write(Data(text.utf8))
    }

    public func readLine(prompt: String) async throws -> String {
        FileHandle.standardError.write(Data(prompt.utf8))
        guard let line = Swift.readLine() else {
            throw PostCursorRuntimeError("stdin closed while reading \(prompt)")
        }
        return line
    }

    public func readKey() async throws -> TerminalKey {
        try TerminalRawMode.withRawInput {
            while true {
                let byte = try readByte()
                switch byte {
                case 0x1B:
                    let second = try readByte()
                    let third = try readByte()
                    if second == 0x5B {
                        switch third {
                        case 0x41: return .up
                        case 0x42: return .down
                        case 0x43: return .right
                        case 0x44: return .left
                        default:
                            throw PostCursorRuntimeError("unsupported escape key sequence ESC [ \(third)")
                        }
                    }
                    throw PostCursorRuntimeError("unsupported escape key sequence ESC \(second) \(third)")
                case 0x0A, 0x0D:
                    return .confirm
                case 0x7F, 0x08:
                    return .backspace
                case 0x51, 0x71:
                    return .quit
                case 0x20...0x7E:
                    return .character(String(UnicodeScalar(byte)))
                default:
                    continue
                }
            }
        }
    }

    private func readByte() throws -> UInt8 {
        let data = FileHandle.standardInput.readData(ofLength: 1)
        guard let byte = data.first else {
            throw PostCursorRuntimeError("stdin closed while reading cursor key")
        }
        return byte
    }
}

public struct LiveInteractiveCLIIO: InteractiveCLIIO {
    public init() {}

    public func write(_ text: String) async {
        FileHandle.standardError.write(Data(text.utf8))
    }

    public func writeOutput(_ text: String) async {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    public func writeError(_ text: String) async {
        FileHandle.standardError.write(Data(text.utf8))
    }

    public func readLine(prompt: String) async throws -> String {
        FileHandle.standardError.write(Data(prompt.utf8))
        guard let line = Swift.readLine() else {
            throw PostCursorRuntimeError("stdin closed while reading \(prompt)")
        }
        return line
    }

    public func readKey() async throws -> TerminalKey {
        try await LivePostCursorIO().readKey()
    }
}

public final class LivePostCursorOverlay: PostCursorOverlay, @unchecked Sendable {
    @MainActor private var panel: NSPanel?

    public init() {}

    public func show(at point: CGPoint) async throws {
        await MainActor.run {
            NSApplication.shared.setActivationPolicy(.accessory)
            let panel = makePanel()
            self.panel = panel
            panel.setFrameOrigin(Self.appKitOrigin(forScreenPoint: point, size: panel.frame.size))
            panel.displayIfNeeded()
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        }
    }

    public func move(to point: CGPoint) async throws {
        await MainActor.run {
            guard let panel else {
                preconditionFailure("post-cursor overlay was moved before show")
            }
            panel.setFrameOrigin(Self.appKitOrigin(forScreenPoint: point, size: panel.frame.size))
            panel.displayIfNeeded()
            panel.orderFrontRegardless()
        }
    }

    public func hide() async {
        await MainActor.run {
            panel?.orderOut(nil)
            panel = nil
        }
    }

    @MainActor
    private func makePanel() -> NSPanel {
        let size = CGSize(width: 32, height: 32)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = PostCursorView(frame: CGRect(origin: .zero, size: size))
        return panel
    }

    private static func appKitOrigin(forScreenPoint point: CGPoint, size: CGSize) -> CGPoint {
        let cgPoint = CGPoint(x: floor(point.x), y: floor(point.y))
        let displayId = displayContaining(cgPoint)
        let displayBounds = CGDisplayBounds(displayId)
        let appKitY = displayBounds.origin.y + displayBounds.height - cgPoint.y - size.height / 2
        return CGPoint(x: cgPoint.x - size.width / 2, y: appKitY)
    }

    private static func displayContaining(_ point: CGPoint) -> CGDirectDisplayID {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        for display in displays where CGDisplayBounds(display).contains(point) {
            return display
        }
        return CGMainDisplayID()
    }
}

private final class PostCursorView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 2, dy: 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()

        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 6
        path.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
        path.line(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        path.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
        path.line(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        path.stroke()

        NSColor.systemRed.setStroke()
        let redPath = NSBezierPath()
        redPath.lineWidth = 3
        redPath.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
        redPath.line(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        redPath.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
        redPath.line(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        redPath.stroke()

        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        ring.lineWidth = 2
        ring.stroke()
    }
}

private enum TerminalRawMode {
    static func withRawInput<T>(_ body: () throws -> T) throws -> T {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw PostCursorRuntimeError("tcgetattr failed with errno \(errno)")
        }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.16 = 1
        raw.c_cc.17 = 0
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            throw PostCursorRuntimeError("tcsetattr raw failed with errno \(errno)")
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &original)
        }
        return try body()
    }
}

private struct PostCursorRuntimeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}
