import Foundation
import AppKit

// MARK: - EventMonitor
//
// Per docs/guide/notch-dev-guide.md §5.1: a thin wrapper around the global +
// local NSEvent monitor pair. `addGlobalMonitorForEvents` only fires when our
// app is NOT the key window; `addLocalMonitorForEvents` fires only when it is.
// We need both so hot-zone hover and ESC keystrokes both work whether or not
// the user has currently focused the panel.

public final class EventMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    public init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    public func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [handler] event in
            handler(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [handler] event in
            handler(event)
            return event
        }
    }

    public func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
    }

    deinit { stop() }
}
