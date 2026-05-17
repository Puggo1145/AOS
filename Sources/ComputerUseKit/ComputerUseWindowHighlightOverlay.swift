import AppKit
import CoreGraphics
import Foundation

struct WindowHighlightTarget: Sendable, Equatable {
    let pid: pid_t
    let windowId: CGWindowID
    let bounds: WindowBounds
}

enum WindowHighlightEvent: Sendable, Equatable {
    case show(WindowHighlightTarget)
    case dismiss
}

struct WindowHighlighter: Sendable {
    typealias EventSink = @Sendable (WindowHighlightEvent) async -> Void

    static let live = WindowHighlighter { event in
        await ComputerUseWindowHighlightOverlay.shared.handle(event)
    }

    private let emit: EventSink

    init(emit: @escaping EventSink) {
        self.emit = emit
    }

    func show(window: WindowInfo) async {
        await emit(.show(WindowHighlightTarget(
            pid: window.pid,
            windowId: window.id,
            bounds: window.bounds
        )))
    }

    func dismiss() async {
        await emit(.dismiss)
    }
}

@MainActor
public enum ComputerUseWindowHighlightControls {
    public static func setStopHandler(_ handler: (@MainActor () -> Void)?) {
        ComputerUseWindowHighlightOverlay.shared.setStopHandler(handler)
    }
}

struct ComputerUseWindowHighlightLayout: Equatable {
    let glowFrame: CGRect
    let windowFrameInGlow: CGRect
    let controlFrame: CGRect?

    init(
        windowRect: CGRect,
        glowOutset: CGFloat,
        controlSize: CGSize?,
        controlTopInset: CGFloat = 10,
        controlEdgePadding: CGFloat = ComputerUseWindowControlCapsuleView.horizontalPadding
    ) {
        let glowFrame = windowRect.insetBy(dx: -glowOutset, dy: -glowOutset)
        self.glowFrame = glowFrame
        self.windowFrameInGlow = windowRect.offsetBy(dx: -glowFrame.minX, dy: -glowFrame.minY)

        guard let controlSize else {
            self.controlFrame = nil
            return
        }

        let centeredX = windowRect.midX - controlSize.width / 2
        let minX = glowFrame.minX + controlEdgePadding
        let maxX = glowFrame.maxX - controlEdgePadding - controlSize.width
        let x = min(max(centeredX, minX), maxX)
        let y = max(windowRect.minY + controlTopInset, windowRect.maxY - controlTopInset - controlSize.height)
        self.controlFrame = CGRect(origin: CGPoint(x: x, y: y), size: controlSize)
    }
}

enum ComputerUseWindowHighlightPanelRole {
    case glow
    case controls

    var ignoresMouseEvents: Bool {
        switch self {
        case .glow:
            return true
        case .controls:
            return false
        }
    }

    var title: String {
        switch self {
        case .glow:
            return "Notch Agent Computer Use Window Highlight"
        case .controls:
            return "Notch Agent Computer Use Window Highlight Controls"
        }
    }
}

@MainActor
private final class ComputerUseWindowHighlightOverlay {
    static let shared = ComputerUseWindowHighlightOverlay()

    private let glowOutset: CGFloat = 44
    private let followIntervalNanoseconds: UInt64 = 100_000_000
    private var glowPanel: ComputerUseWindowHighlightPanel?
    private var controlPanel: ComputerUseWindowHighlightPanel?
    private var highlightView: ComputerUseWindowHighlightView?
    private var controlCapsule: ComputerUseWindowControlCapsuleView?
    private var highlightedTarget: WindowHighlightTarget?
    private var renderedTarget: WindowHighlightTarget?
    private var followTask: Task<Void, Never>?
    private var stopHandler: (@MainActor () -> Void)?

    private init() {}

    func handle(_ event: WindowHighlightEvent) {
        switch event {
        case .show(let target):
            show(target)
        case .dismiss:
            dismiss()
        }
    }

    func setStopHandler(_ handler: (@MainActor () -> Void)?) {
        stopHandler = handler
        controlCapsule?.onStop = handler
        if handler == nil {
            controlPanel?.orderOut(nil)
        } else if let target = highlightedTarget {
            render(target, force: true)
        }
    }

    private func show(_ target: WindowHighlightTarget) {
        highlightedTarget = target
        render(target, force: true)
        startFollowLoop(target: target)
    }

    private func render(_ target: WindowHighlightTarget, force: Bool = false) {
        guard force || renderedTarget != target else {
            return
        }

        let windowRect = Self.appKitRect(fromScreenStateRect: target.bounds.cgRect)
        let controlPair: (panel: ComputerUseWindowHighlightPanel, capsule: ComputerUseWindowControlCapsuleView)?
        if stopHandler == nil {
            controlPair = nil
        } else {
            let panel = ensureControlPanel()
            guard let controlCapsule else {
                preconditionFailure("control panel was created without a capsule")
            }
            controlPair = (panel, controlCapsule)
        }

        let layout = ComputerUseWindowHighlightLayout(
            windowRect: windowRect,
            glowOutset: glowOutset,
            controlSize: controlPair?.capsule.fittingSize
        )

        let glowPanel = ensureGlowPanel(frame: layout.glowFrame)
        glowPanel.setFrame(layout.glowFrame, display: true)
        highlightView?.windowFrameInGlow = layout.windowFrameInGlow
        highlightView?.needsDisplay = true
        renderedTarget = target
        glowPanel.order(.above, relativeTo: Int(target.windowId))

        guard let controlPair, let controlFrame = layout.controlFrame else {
            controlPanel?.orderOut(nil)
            return
        }

        controlPair.capsule.frame = CGRect(origin: .zero, size: controlFrame.size)
        controlPair.panel.setFrame(controlFrame, display: true)
        controlPair.panel.order(.above, relativeTo: Int(target.windowId))
    }

    private func dismiss() {
        highlightedTarget = nil
        renderedTarget = nil
        followTask?.cancel()
        followTask = nil
        glowPanel?.orderOut(nil)
        controlPanel?.orderOut(nil)
    }

    private func startFollowLoop(target: WindowHighlightTarget) {
        followTask?.cancel()
        let interval = followIntervalNanoseconds
        followTask = Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                guard let window = WindowEnumerator.window(forId: target.windowId),
                      window.pid == target.pid
                else {
                    await self?.dismissIfStillHighlighting(target)
                    return
                }

                let latest = WindowHighlightTarget(
                    pid: window.pid,
                    windowId: window.id,
                    bounds: window.bounds
                )
                let shouldContinue = await self?.renderFollowSample(latest, for: target) ?? false
                guard shouldContinue else { return }
            }
        }
    }

    private func renderFollowSample(_ latest: WindowHighlightTarget, for original: WindowHighlightTarget) -> Bool {
        guard highlightedTarget?.pid == original.pid,
              highlightedTarget?.windowId == original.windowId
        else {
            return false
        }

        highlightedTarget = latest
        render(latest)
        return true
    }

    private func dismissIfStillHighlighting(_ target: WindowHighlightTarget) {
        guard highlightedTarget?.pid == target.pid,
              highlightedTarget?.windowId == target.windowId
        else {
            return
        }
        dismiss()
    }

    private func ensureGlowPanel(frame: CGRect) -> ComputerUseWindowHighlightPanel {
        if let glowPanel {
            return glowPanel
        }

        let glowPanel = ComputerUseWindowHighlightPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        glowPanel.configureForWindowHighlight(role: .glow)

        let view = ComputerUseWindowHighlightView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        glowPanel.contentView = view

        self.glowPanel = glowPanel
        self.highlightView = view
        return glowPanel
    }

    private func ensureControlPanel() -> ComputerUseWindowHighlightPanel {
        if let controlPanel {
            return controlPanel
        }

        let capsule = ComputerUseWindowControlCapsuleView(frame: .zero)
        capsule.onStop = stopHandler

        let size = capsule.fittingSize
        capsule.frame = CGRect(origin: .zero, size: size)
        capsule.autoresizingMask = [.width, .height]

        let controlPanel = ComputerUseWindowHighlightPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        controlPanel.configureForWindowHighlight(role: .controls)
        controlPanel.contentView = capsule

        self.controlPanel = controlPanel
        self.controlCapsule = capsule
        return controlPanel
    }

    private static func appKitRect(fromScreenStateRect rect: CGRect) -> CGRect {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            guard displayBounds.contains(center) else {
                continue
            }

            let localX = rect.minX - displayBounds.minX
            let localY = rect.minY - displayBounds.minY
            return CGRect(
                x: screen.frame.minX + localX,
                y: screen.frame.maxY - localY - rect.height,
                width: rect.width,
                height: rect.height
            )
        }
        return rect
    }
}

final class ComputerUseWindowHighlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configureForWindowHighlight(role: ComputerUseWindowHighlightPanelRole) {
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        ignoresMouseEvents = role.ignoresMouseEvents
        isOpaque = false
        level = .normal
        title = role.title
        if role == .glow {
            setAccessibilityElement(false)
        }
    }
}

private final class ComputerUseWindowHighlightView: NSView {
    var windowFrameInGlow: CGRect = .zero {
        didSet {
            needsLayout = true
        }
    }

    private let highlightColor = NSColor(
        deviceRed: 11.0 / 255.0,
        green: 153.0 / 255.0,
        blue: 255.0 / 255.0,
        alpha: 1
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        dirtyRect.fill()

        let rect = windowFrameInGlow
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        for pass in [(blur: CGFloat(60), alpha: CGFloat(0.62), width: CGFloat(18)),
                     (blur: CGFloat(42), alpha: CGFloat(0.48), width: CGFloat(12)),
                     (blur: CGFloat(24), alpha: CGFloat(0.34), width: CGFloat(7))] {
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = highlightColor.withAlphaComponent(pass.alpha)
            shadow.shadowBlurRadius = pass.blur
            shadow.shadowOffset = .zero
            shadow.set()
            highlightColor.withAlphaComponent(0.07).setStroke()
            path.lineWidth = pass.width
            path.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        highlightColor.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

private final class ComputerUseWindowControlCapsuleView: NSView {
    static let horizontalPadding: CGFloat = 4
    static let verticalPadding: CGFloat = 4

    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    var onStop: (@MainActor () -> Void)?

    private let itemSpacing: CGFloat = 4
    private let buttonHorizontalPadding: CGFloat = 18
    private let buttonVerticalPadding: CGFloat = 5
    private let labelWidthAllowance: CGFloat = 16
    private let label = NSTextField(labelWithString: "agent is using this app")
    private let capsuleColor = NSColor(
        deviceRed: 11.0 / 255.0,
        green: 153.0 / 255.0,
        blue: 255.0 / 255.0,
        alpha: 1
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = capsuleColor.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("Agent is using this app")
        addSubview(label)

        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.isBordered = false
        stopButton.wantsLayer = true
        stopButton.layer?.backgroundColor = NSColor.white.cgColor
        stopButton.layer?.cornerRadius = 11
        stopButton.contentTintColor = capsuleColor
        stopButton.font = .systemFont(ofSize: 12, weight: .semibold)
        stopButton.setAccessibilityLabel("Stop agent session")
        addSubview(stopButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        let labelSize = labelTextSize()
        let labelFrameWidth = labelSize.width + labelWidthAllowance
        let buttonSize = stopButtonContentSize()
        let buttonFrameSize = NSSize(
            width: buttonSize.width + buttonHorizontalPadding * 2,
            height: buttonSize.height + buttonVerticalPadding * 2
        )
        return NSSize(
            width: Self.horizontalPadding + labelFrameWidth + itemSpacing + buttonFrameSize.width + Self.horizontalPadding,
            height: Self.verticalPadding + max(labelSize.height, buttonFrameSize.height) + Self.verticalPadding
        )
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let labelSize = labelTextSize()
        let buttonContentSize = stopButtonContentSize()
        let buttonWidth = buttonContentSize.width + buttonHorizontalPadding * 2
        let buttonHeight = buttonContentSize.height + buttonVerticalPadding * 2
        let availableLabelWidth = max(
            0,
            bounds.width - Self.horizontalPadding * 2 - itemSpacing - buttonWidth
        )
        label.frame = CGRect(
            x: Self.horizontalPadding,
            y: (bounds.height - labelSize.height) / 2,
            width: availableLabelWidth,
            height: labelSize.height
        )
        stopButton.frame = CGRect(
            x: label.frame.maxX + itemSpacing,
            y: (bounds.height - buttonHeight) / 2,
            width: buttonWidth,
            height: buttonHeight
        )
    }

    @objc private func stopPressed() {
        onStop?()
    }

    private func stopButtonContentSize() -> NSSize {
        let font = stopButton.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let title = stopButton.title as NSString
        return title.size(withAttributes: [.font: font])
    }

    private func labelTextSize() -> NSSize {
        let font = label.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let title = label.stringValue as NSString
        return title.size(withAttributes: [.font: font])
    }
}
