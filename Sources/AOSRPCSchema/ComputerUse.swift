import Foundation

// MARK: - computerUse.* params / results
//
// Shell-hosted Computer Use business surface. The Sidecar exposes these as
// agent tools and calls Shell over JSON-RPC; Shell maps the wire DTOs into
// AOSComputerUseKit value types at the composition boundary.

public enum ComputerUseAppListMode: String, Codable, Sendable, Equatable {
    case running
    case all
}

public enum ComputerUseCaptureMode: String, Codable, Sendable, Equatable {
    case vision
    case ax
}

public struct ComputerUsePoint: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ComputerUseBounds: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ComputerUseAppInfo: Codable, Sendable, Equatable {
    public let pid: Int?
    public let bundleId: String?
    public let name: String
    public let path: String?
    public let running: Bool
    public let active: Bool
    public let identity: String

    public init(
        pid: Int?,
        bundleId: String?,
        name: String,
        path: String?,
        running: Bool,
        active: Bool,
        identity: String
    ) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.path = path
        self.running = running
        self.active = active
        self.identity = identity
    }
}

public struct ComputerUseWindowInfo: Codable, Sendable, Equatable {
    public let windowId: Int
    public let pid: Int
    public let owner: String
    public let title: String
    public let bounds: ComputerUseBounds
    public let zIndex: Int
    public let isOnScreen: Bool
    public let layer: Int

    public init(
        windowId: Int,
        pid: Int,
        owner: String,
        title: String,
        bounds: ComputerUseBounds,
        zIndex: Int,
        isOnScreen: Bool,
        layer: Int
    ) {
        self.windowId = windowId
        self.pid = pid
        self.owner = owner
        self.title = title
        self.bounds = bounds
        self.zIndex = zIndex
        self.isOnScreen = isOnScreen
        self.layer = layer
    }
}

public struct ComputerUseCoordinateSpace: Codable, Sendable, Equatable {
    public let windowFrame: ComputerUseBounds
    public let windowBounds: ComputerUseBounds
    public let pixelSize: ComputerUsePixelSize

    public init(
        windowFrame: ComputerUseBounds,
        windowBounds: ComputerUseBounds,
        pixelSize: ComputerUsePixelSize
    ) {
        self.windowFrame = windowFrame
        self.windowBounds = windowBounds
        self.pixelSize = pixelSize
    }
}

public struct ComputerUsePixelSize: Codable, Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct ComputerUseScreenshot: Codable, Sendable, Equatable {
    public let imageBase64: String
    public let format: String
    public let width: Int
    public let height: Int
    public let scaleFactor: Double
    public let coordinateSpace: ComputerUseCoordinateSpace
    public let originalWidth: Int?
    public let originalHeight: Int?

    public init(
        imageBase64: String,
        format: String,
        width: Int,
        height: Int,
        scaleFactor: Double,
        coordinateSpace: ComputerUseCoordinateSpace,
        originalWidth: Int?,
        originalHeight: Int?
    ) {
        self.imageBase64 = imageBase64
        self.format = format
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.coordinateSpace = coordinateSpace
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
    }
}

public struct ComputerUseListAppsParams: Codable, Sendable, Equatable {
    public let mode: ComputerUseAppListMode

    public init(mode: ComputerUseAppListMode) {
        self.mode = mode
    }
}

public struct ComputerUseListAppsResult: Codable, Sendable, Equatable {
    public let apps: [ComputerUseAppInfo]

    public init(apps: [ComputerUseAppInfo]) {
        self.apps = apps
    }
}

public struct ComputerUseListWindowsParams: Codable, Sendable, Equatable {
    public let pid: Int

    public init(pid: Int) {
        self.pid = pid
    }
}

public struct ComputerUseListWindowsResult: Codable, Sendable, Equatable {
    public let windows: [ComputerUseWindowInfo]

    public init(windows: [ComputerUseWindowInfo]) {
        self.windows = windows
    }
}

public struct ComputerUseGetAppStateParams: Codable, Sendable, Equatable {
    public let windowId: Int
    public let captureMode: ComputerUseCaptureMode
    public let maxImageDimension: Int

    public init(
        windowId: Int,
        captureMode: ComputerUseCaptureMode,
        maxImageDimension: Int
    ) {
        self.windowId = windowId
        self.captureMode = captureMode
        self.maxImageDimension = maxImageDimension
    }
}

public struct ComputerUseGetAppStateResult: Codable, Sendable, Equatable {
    public let pid: Int
    public let stateId: String
    public let treeMarkdown: String
    public let elementCount: Int
    public let screenshot: ComputerUseScreenshot?
    public let bundleId: String?
    public let appName: String?

    public init(
        pid: Int,
        stateId: String,
        treeMarkdown: String,
        elementCount: Int,
        screenshot: ComputerUseScreenshot?,
        bundleId: String?,
        appName: String?
    ) {
        self.pid = pid
        self.stateId = stateId
        self.treeMarkdown = treeMarkdown
        self.elementCount = elementCount
        self.screenshot = screenshot
        self.bundleId = bundleId
        self.appName = appName
    }
}

public struct ComputerUseStartAppSessionParams: Codable, Sendable, Equatable {
    public let pid: Int
    public let windowId: Int

    public init(pid: Int, windowId: Int) {
        self.pid = pid
        self.windowId = windowId
    }
}

public struct ComputerUseAppSessionResult: Codable, Sendable, Equatable {
    public let pid: Int

    public init(pid: Int) {
        self.pid = pid
    }
}

public struct ComputerUseStopAppSessionParams: Codable, Sendable, Equatable {
    public init() {}
}

public enum ComputerUseMouseButton: String, Codable, Sendable, Equatable {
    case left
    case right
}

public struct ComputerUseMouseClickEvent: Codable, Sendable, Equatable {
    public let button: ComputerUseMouseButton
    public let point: ComputerUsePoint
    public let count: Int

    public init(button: ComputerUseMouseButton, point: ComputerUsePoint, count: Int = 1) {
        self.button = button
        self.point = point
        self.count = count
    }
}

public struct ComputerUseMouseDragEvent: Codable, Sendable, Equatable {
    public let button: ComputerUseMouseButton
    public let from: ComputerUsePoint
    public let to: ComputerUsePoint

    public init(button: ComputerUseMouseButton, from: ComputerUsePoint, to: ComputerUsePoint) {
        self.button = button
        self.from = from
        self.to = to
    }
}

public enum ComputerUseMouseEvent: Sendable, Equatable {
    case click(ComputerUseMouseClickEvent)
    case drag(ComputerUseMouseDragEvent)
}

extension ComputerUseMouseEvent: Codable {
    private enum Kind: String, Codable {
        case click
        case drag
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case button
        case point
        case count
        case from
        case to
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .click:
            self = .click(ComputerUseMouseClickEvent(
                button: try container.decode(ComputerUseMouseButton.self, forKey: .button),
                point: try container.decode(ComputerUsePoint.self, forKey: .point),
                count: try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
            ))
        case .drag:
            self = .drag(ComputerUseMouseDragEvent(
                button: try container.decode(ComputerUseMouseButton.self, forKey: .button),
                from: try container.decode(ComputerUsePoint.self, forKey: .from),
                to: try container.decode(ComputerUsePoint.self, forKey: .to)
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .click(let event):
            try container.encode(Kind.click, forKey: .kind)
            try container.encode(event.button, forKey: .button)
            try container.encode(event.point, forKey: .point)
            try container.encode(event.count, forKey: .count)
        case .drag(let event):
            try container.encode(Kind.drag, forKey: .kind)
            try container.encode(event.button, forKey: .button)
            try container.encode(event.from, forKey: .from)
            try container.encode(event.to, forKey: .to)
        }
    }
}

public struct ComputerUsePostMouseEventParams: Codable, Sendable, Equatable {
    public let windowId: Int
    public let event: ComputerUseMouseEvent

    public init(windowId: Int, event: ComputerUseMouseEvent) {
        self.windowId = windowId
        self.event = event
    }
}

public struct ComputerUsePostMouseEventResult: Codable, Sendable, Equatable {
    public let pid: Int
    public let windowId: Int
    public let event: ComputerUseMouseEvent

    public init(pid: Int, windowId: Int, event: ComputerUseMouseEvent) {
        self.pid = pid
        self.windowId = windowId
        self.event = event
    }
}

public enum ComputerUseKeyboardModifier: String, Codable, Sendable, Equatable {
    case command
    case shift
    case option
    case control
    case function
}

public struct ComputerUseKeyboardTextEvent: Codable, Sendable, Equatable {
    public let text: String
    public let delayMilliseconds: Int

    public init(text: String, delayMilliseconds: Int = 30) {
        self.text = text
        self.delayMilliseconds = delayMilliseconds
    }
}

public struct ComputerUseKeyboardKeyPressEvent: Codable, Sendable, Equatable {
    public let key: String
    public let modifiers: [ComputerUseKeyboardModifier]
    public let count: Int

    public init(
        key: String,
        modifiers: [ComputerUseKeyboardModifier] = [],
        count: Int = 1
    ) {
        self.key = key
        self.modifiers = modifiers
        self.count = count
    }
}

public struct ComputerUseKeyboardHotkeyEvent: Codable, Sendable, Equatable {
    public let modifiers: [ComputerUseKeyboardModifier]
    public let key: String

    public init(modifiers: [ComputerUseKeyboardModifier], key: String) {
        self.modifiers = modifiers
        self.key = key
    }
}

public enum ComputerUseKeyboardEvent: Sendable, Equatable {
    case text(ComputerUseKeyboardTextEvent)
    case keyPress(ComputerUseKeyboardKeyPressEvent)
    case hotkey(ComputerUseKeyboardHotkeyEvent)
}

extension ComputerUseKeyboardEvent: Codable {
    private enum Kind: String, Codable {
        case text
        case keyPress
        case hotkey
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case delayMilliseconds
        case key
        case modifiers
        case count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(ComputerUseKeyboardTextEvent(
                text: try container.decode(String.self, forKey: .text),
                delayMilliseconds: try container.decodeIfPresent(Int.self, forKey: .delayMilliseconds) ?? 30
            ))
        case .keyPress:
            self = .keyPress(ComputerUseKeyboardKeyPressEvent(
                key: try container.decode(String.self, forKey: .key),
                modifiers: try container.decodeIfPresent([ComputerUseKeyboardModifier].self, forKey: .modifiers) ?? [],
                count: try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
            ))
        case .hotkey:
            self = .hotkey(ComputerUseKeyboardHotkeyEvent(
                modifiers: try container.decode([ComputerUseKeyboardModifier].self, forKey: .modifiers),
                key: try container.decode(String.self, forKey: .key)
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let event):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(event.text, forKey: .text)
            try container.encode(event.delayMilliseconds, forKey: .delayMilliseconds)
        case .keyPress(let event):
            try container.encode(Kind.keyPress, forKey: .kind)
            try container.encode(event.key, forKey: .key)
            try container.encode(event.modifiers, forKey: .modifiers)
            try container.encode(event.count, forKey: .count)
        case .hotkey(let event):
            try container.encode(Kind.hotkey, forKey: .kind)
            try container.encode(event.modifiers, forKey: .modifiers)
            try container.encode(event.key, forKey: .key)
        }
    }
}

public struct ComputerUsePostKeyboardEventParams: Codable, Sendable, Equatable {
    public let windowId: Int
    public let event: ComputerUseKeyboardEvent

    public init(windowId: Int, event: ComputerUseKeyboardEvent) {
        self.windowId = windowId
        self.event = event
    }
}

public struct ComputerUsePostKeyboardEventResult: Codable, Sendable, Equatable {
    public let pid: Int
    public let windowId: Int
    public let event: ComputerUseKeyboardEvent

    public init(pid: Int, windowId: Int, event: ComputerUseKeyboardEvent) {
        self.pid = pid
        self.windowId = windowId
        self.event = event
    }
}

public enum ComputerUseAXElementAction: String, Codable, Sendable, Equatable {
    case press
    case showMenu
    case pick
    case confirm
    case cancel
    case open
    case increment
    case decrement
    case scrollToVisible
}

public enum ComputerUseAXScrollDirection: String, Codable, Sendable, Equatable {
    case up
    case down
    case left
    case right
}

public struct ComputerUseAXActionEvent: Codable, Sendable, Equatable {
    public let action: ComputerUseAXElementAction

    public init(action: ComputerUseAXElementAction) {
        self.action = action
    }
}

public struct ComputerUseAXSetValueEvent: Codable, Sendable, Equatable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

public struct ComputerUseAXScrollEvent: Codable, Sendable, Equatable {
    public let direction: ComputerUseAXScrollDirection
    public let pages: Double

    public init(direction: ComputerUseAXScrollDirection, pages: Double) {
        self.direction = direction
        self.pages = pages
    }
}

public enum ComputerUseAXElementEvent: Sendable, Equatable {
    case action(ComputerUseAXActionEvent)
    case setValue(ComputerUseAXSetValueEvent)
    case setSelectedText(ComputerUseAXSetValueEvent)
    case focus
    case scroll(ComputerUseAXScrollEvent)
}

extension ComputerUseAXElementEvent: Codable {
    private enum Kind: String, Codable {
        case action
        case setValue
        case setSelectedText
        case focus
        case scroll
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case action
        case value
        case direction
        case pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .action:
            self = .action(ComputerUseAXActionEvent(
                action: try container.decode(ComputerUseAXElementAction.self, forKey: .action)
            ))
        case .setValue:
            self = .setValue(ComputerUseAXSetValueEvent(
                value: try container.decode(String.self, forKey: .value)
            ))
        case .setSelectedText:
            self = .setSelectedText(ComputerUseAXSetValueEvent(
                value: try container.decode(String.self, forKey: .value)
            ))
        case .focus:
            self = .focus
        case .scroll:
            self = .scroll(ComputerUseAXScrollEvent(
                direction: try container.decode(ComputerUseAXScrollDirection.self, forKey: .direction),
                pages: try container.decode(Double.self, forKey: .pages)
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .action(let event):
            try container.encode(Kind.action, forKey: .kind)
            try container.encode(event.action, forKey: .action)
        case .setValue(let event):
            try container.encode(Kind.setValue, forKey: .kind)
            try container.encode(event.value, forKey: .value)
        case .setSelectedText(let event):
            try container.encode(Kind.setSelectedText, forKey: .kind)
            try container.encode(event.value, forKey: .value)
        case .focus:
            try container.encode(Kind.focus, forKey: .kind)
        case .scroll(let event):
            try container.encode(Kind.scroll, forKey: .kind)
            try container.encode(event.direction, forKey: .direction)
            try container.encode(event.pages, forKey: .pages)
        }
    }
}

public struct ComputerUsePostEventToAXElementParams: Codable, Sendable, Equatable {
    public let windowId: Int
    public let stateId: String
    public let elementIndex: Int
    public let event: ComputerUseAXElementEvent

    public init(
        windowId: Int,
        stateId: String,
        elementIndex: Int,
        event: ComputerUseAXElementEvent
    ) {
        self.windowId = windowId
        self.stateId = stateId
        self.elementIndex = elementIndex
        self.event = event
    }
}

public struct ComputerUsePostEventToAXElementResult: Codable, Sendable, Equatable {
    public let pid: Int
    public let windowId: Int
    public let stateId: String
    public let elementIndex: Int
    public let event: ComputerUseAXElementEvent

    public init(
        pid: Int,
        windowId: Int,
        stateId: String,
        elementIndex: Int,
        event: ComputerUseAXElementEvent
    ) {
        self.pid = pid
        self.windowId = windowId
        self.stateId = stateId
        self.elementIndex = elementIndex
        self.event = event
    }
}
