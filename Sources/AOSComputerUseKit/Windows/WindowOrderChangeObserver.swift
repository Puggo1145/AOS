import CoreGraphics
import Darwin
import Foundation

struct WindowOrderChangeObserver: Sendable {
    typealias Handler = @Sendable (CGWindowID) async throws -> Void
    typealias Observe = @Sendable ([CGWindowID], @escaping Handler) async throws -> WindowOrderChangeObservation

    private let observeWindows: Observe

    init(_ observeWindows: @escaping Observe) {
        self.observeWindows = observeWindows
    }

    func observe(
        windowIds: [CGWindowID],
        onChange: @escaping Handler
    ) async throws -> WindowOrderChangeObservation {
        try await observeWindows(windowIds, onChange)
    }

    static func live() -> WindowOrderChangeObserver {
        WindowOrderChangeObserver { windowIds, onChange in
            try SLSWindowOrderChangeObservation.start(windowIds: windowIds, onChange: onChange)
        }
    }
}

struct WindowOrderChangeObservation: Sendable {
    private let finishObservation: @Sendable () async throws -> Void

    init(_ finishObservation: @escaping @Sendable () async throws -> Void) {
        self.finishObservation = finishObservation
    }

    init(_ finishObservation: @escaping @Sendable () -> Void) {
        self.finishObservation = {
            finishObservation()
        }
    }

    func finish() async throws {
        try await finishObservation()
    }
}

private enum SLSWindowOrderChangeObservation {
    private static let windowOrderedEvent: UInt32 = 808

    static func start(
        windowIds: [CGWindowID],
        onChange: @escaping WindowOrderChangeObserver.Handler
    ) throws -> WindowOrderChangeObservation {
        let uniqueIds = Array(Set(windowIds)).sorted()
        guard !uniqueIds.isEmpty else {
            throw ComputerUseError.clickUnavailable("window-order observer requires at least one window id")
        }

        let symbols = try SLSWindowOrderSymbols.load()
        let connection = symbols.mainConnectionId()
        let box = SLSWindowOrderNotificationBox(
            observedWindowIds: Set(uniqueIds),
            onChange: onChange
        )
        let context = Unmanaged.passRetained(box).toOpaque()

        let registerStatus = symbols.registerConnectionNotifyProc(
            connection,
            slsWindowOrderNotificationCallback,
            windowOrderedEvent,
            context
        )
        guard registerStatus == 0 else {
            Unmanaged<SLSWindowOrderNotificationBox>.fromOpaque(context).release()
            throw ComputerUseError.clickUnavailable(
                "SLSRegisterConnectionNotifyProc failed for window-order event \(windowOrderedEvent): CGError \(registerStatus)"
            )
        }

        var rawWindowIds = uniqueIds.map { UInt32($0) }
        let requestStatus = rawWindowIds.withUnsafeMutableBufferPointer { buffer in
            symbols.requestNotificationsForWindows(
                connection,
                buffer.baseAddress!,
                Int32(buffer.count)
            )
        }
        guard requestStatus == 0 else {
            _ = symbols.removeConnectionNotifyProc(
                connection,
                slsWindowOrderNotificationCallback,
                windowOrderedEvent,
                context
            )
            Unmanaged<SLSWindowOrderNotificationBox>.fromOpaque(context).release()
            throw ComputerUseError.clickUnavailable(
                "SLSRequestNotificationsForWindows failed for \(rawWindowIds): CGError \(requestStatus)"
            )
        }

        let token = SLSWindowOrderObservationToken(
            symbols: symbols,
            connection: connection,
            context: context,
            box: box,
            event: windowOrderedEvent
        )
        return WindowOrderChangeObservation {
            try await token.finish()
        }
    }
}

private final class SLSWindowOrderObservationToken: @unchecked Sendable {
    private let symbols: SLSWindowOrderSymbols
    private let connection: Int32
    private let context: UnsafeMutableRawPointer
    private let box: SLSWindowOrderNotificationBox
    private let event: UInt32
    private let lock = NSLock()
    private var didFinish = false

    init(
        symbols: SLSWindowOrderSymbols,
        connection: Int32,
        context: UnsafeMutableRawPointer,
        box: SLSWindowOrderNotificationBox,
        event: UInt32
    ) {
        self.symbols = symbols
        self.connection = connection
        self.context = context
        self.box = box
        self.event = event
    }

    func finish() async throws {
        guard markFinished() else {
            return
        }

        box.stopAcceptingEvents()
        let removeStatus = symbols.removeConnectionNotifyProc(
            connection,
            slsWindowOrderNotificationCallback,
            event,
            context
        )
        defer {
            Unmanaged<SLSWindowOrderNotificationBox>.fromOpaque(context).release()
        }

        try await box.drain()
        guard removeStatus == 0 else {
            throw ComputerUseError.clickUnavailable(
                "SLSRemoveConnectionNotifyProc failed for window-order event \(event): CGError \(removeStatus)"
            )
        }
    }

    private func markFinished() -> Bool {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return false
        }
        didFinish = true
        lock.unlock()
        return true
    }
}

private final class SLSWindowOrderNotificationBox: @unchecked Sendable {
    private let observedWindowIds: Set<CGWindowID>
    private let onChange: WindowOrderChangeObserver.Handler
    private let lock = NSLock()
    private var acceptsEvents = true
    private var tasks: [Task<Void, Error>] = []

    init(
        observedWindowIds: Set<CGWindowID>,
        onChange: @escaping WindowOrderChangeObserver.Handler
    ) {
        self.observedWindowIds = observedWindowIds
        self.onChange = onChange
    }

    func emit(windowId: CGWindowID) {
        guard observedWindowIds.contains(windowId) else {
            return
        }

        lock.lock()
        guard acceptsEvents else {
            lock.unlock()
            return
        }
        let task = Task {
            try await onChange(windowId)
        }
        tasks.append(task)
        lock.unlock()
    }

    func stopAcceptingEvents() {
        lock.lock()
        acceptsEvents = false
        lock.unlock()
    }

    func drain() async throws {
        let pending = takePendingTasks()
        for task in pending {
            try await task.value
        }
    }

    private func takePendingTasks() -> [Task<Void, Error>] {
        lock.lock()
        let pending = tasks
        tasks.removeAll()
        lock.unlock()
        return pending
    }
}

private typealias SLSConnectionNotifyProc = @convention(c) (
    UInt32,
    UnsafeMutableRawPointer?,
    Int,
    UnsafeMutableRawPointer?,
    Int32
) -> Void
private typealias SLSMainConnectionID = @convention(c) () -> Int32
private typealias SLSRegisterConnectionNotifyProc = @convention(c) (
    Int32,
    SLSConnectionNotifyProc,
    UInt32,
    UnsafeMutableRawPointer?
) -> Int32
private typealias SLSRemoveConnectionNotifyProc = @convention(c) (
    Int32,
    SLSConnectionNotifyProc,
    UInt32,
    UnsafeMutableRawPointer?
) -> Int32
private typealias SLSRequestNotificationsForWindows = @convention(c) (
    Int32,
    UnsafeMutablePointer<UInt32>,
    Int32
) -> Int32

private struct SLSWindowOrderSymbols: Sendable {
    let mainConnectionId: SLSMainConnectionID
    let registerConnectionNotifyProc: SLSRegisterConnectionNotifyProc
    let removeConnectionNotifyProc: SLSRemoveConnectionNotifyProc
    let requestNotificationsForWindows: SLSRequestNotificationsForWindows

    static func load() throws -> SLSWindowOrderSymbols {
        let handles = try WindowOrderPrivateFrameworkHandles.load()
        return SLSWindowOrderSymbols(
            mainConnectionId: try handles.symbol("SLSMainConnectionID"),
            registerConnectionNotifyProc: try handles.symbol("SLSRegisterConnectionNotifyProc"),
            removeConnectionNotifyProc: try handles.symbol("SLSRemoveConnectionNotifyProc"),
            requestNotificationsForWindows: try handles.symbol("SLSRequestNotificationsForWindows")
        )
    }
}

private let slsWindowOrderNotificationCallback: SLSConnectionNotifyProc = { type, data, dataLength, context, _ in
    guard
        type == 808,
        dataLength >= MemoryLayout<UInt32>.size,
        let data,
        let context
    else {
        return
    }

    var rawWindowId: UInt32 = 0
    withUnsafeMutableBytes(of: &rawWindowId) { destination in
        destination.copyMemory(from: UnsafeRawBufferPointer(
            start: data,
            count: MemoryLayout<UInt32>.size
        ))
    }

    let box = Unmanaged<SLSWindowOrderNotificationBox>
        .fromOpaque(context)
        .takeUnretainedValue()
    box.emit(windowId: CGWindowID(rawWindowId))
}

private struct WindowOrderPrivateFrameworkHandles {
    private let defaultHandle: UnsafeMutableRawPointer

    static func load() throws -> WindowOrderPrivateFrameworkHandles {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard dlopen(path, RTLD_LAZY) != nil else {
            throw ComputerUseError.clickUnavailable("failed to load private framework at \(path)")
        }
        guard let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) else {
            throw ComputerUseError.clickUnavailable("failed to access RTLD_DEFAULT symbol scope")
        }
        return WindowOrderPrivateFrameworkHandles(defaultHandle: defaultHandle)
    }

    func symbol<T>(_ name: String) throws -> T {
        if let pointer = dlsym(defaultHandle, name) {
            return unsafeBitCast(pointer, to: T.self)
        }
        throw ComputerUseError.clickUnavailable("missing private symbol \(name)")
    }
}
