import AOSAXSupport
import ApplicationServices
import CoreGraphics
import Foundation

/// Raises an existing AX window without using app activation APIs.
///
/// This is intentionally scoped to a concrete CGWindowID: WindowServer order
/// repair needs to put a specific pre-existing window back above the target
/// after a synthetic click disturbed the background z-order.
struct AXWindowRaiser: Sendable {
    typealias IsTrusted = @Sendable () -> Bool
    typealias CreateApplication = @Sendable (pid_t) -> AXUIElement
    typealias CopyAttribute = @Sendable (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError
    typealias PerformAction = @Sendable (AXUIElement, CFString) -> AXError
    typealias ResolveWindowID = @Sendable (AXUIElement) -> CGWindowID?

    private let isTrusted: IsTrusted
    private let createApplication: CreateApplication
    private let copyAttribute: CopyAttribute
    private let performAction: PerformAction
    private let resolveWindowID: ResolveWindowID

    init(
        isTrusted: @escaping IsTrusted,
        createApplication: @escaping CreateApplication,
        copyAttribute: @escaping CopyAttribute,
        performAction: @escaping PerformAction,
        resolveWindowID: @escaping ResolveWindowID
    ) {
        self.isTrusted = isTrusted
        self.createApplication = createApplication
        self.copyAttribute = copyAttribute
        self.performAction = performAction
        self.resolveWindowID = resolveWindowID
    }

    static func live() -> AXWindowRaiser {
        AXWindowRaiser(
            isTrusted: { AXIsProcessTrusted() },
            createApplication: { AXUIElementCreateApplication($0) },
            copyAttribute: { element, attribute, value in
                AXUIElementCopyAttributeValue(element, attribute, value)
            },
            performAction: { element, action in
                AXUIElementPerformAction(element, action)
            },
            resolveWindowID: { element in
                axWindowID(for: element)
            }
        )
    }

    func raise(_ window: WindowInfo) throws {
        guard isTrusted() else {
            throw ComputerUseError.clickUnavailable(
                "Accessibility permission is required to repair window order"
            )
        }

        let app = createApplication(window.pid)
        guard let axWindow = try axWindows(of: app).first(where: { resolveWindowID($0) == window.id }) else {
            throw ComputerUseError.clickUnavailable(
                "no AX window found for window \(window.id) owned by pid \(window.pid)"
            )
        }

        let result = performAction(axWindow, "AXRaise" as CFString)
        guard result == .success else {
            throw ComputerUseError.clickUnavailable(
                "AXRaise failed for window \(window.id): AXError \(result.rawValue)"
            )
        }
    }

    private func axWindows(of app: AXUIElement) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let result = copyAttribute(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success else {
            throw ComputerUseError.clickUnavailable(
                "AX windows lookup failed: AXError \(result.rawValue)"
            )
        }
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else {
            throw ComputerUseError.clickUnavailable("AX windows lookup did not return an array")
        }

        let array = unsafeDowncast(value, to: CFArray.self)
        let count = CFArrayGetCount(array)
        var windows: [AXUIElement] = []
        windows.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            windows.append(Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue())
        }
        return windows
    }
}
