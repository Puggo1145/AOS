import ApplicationServices
import Foundation

/// Browser-specific OS Sense adapter that exposes the front tab URL/title.
/// For PDFs opened in a browser, the URL is the stable document identity the
/// agent needs; PDF page text remains a visual or future document-extraction
/// concern.
public actor BrowserAdapter: SenseAdapter {
    public static let id: AdapterID = "browser"
    public static let supportedBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    public nonisolated let requiredPermissions: Set<Permission> = [.accessibility, .automation]

    private let tabReaderFactory: @Sendable (String) -> any BrowserTabReading
    private var tabReader: (any BrowserTabReading)?
    private var hub: AXObserverHub?
    private var subscriptionTokens: [AXObserverHub.Token] = []
    private var continuation: AsyncStream<[BehaviorEnvelope]>.Continuation?
    private var refreshTask: Task<Void, Never>?

    public init() {
        self.tabReaderFactory = { bundleId in
            AppleScriptBrowserTabReader(bundleId: bundleId)
        }
    }

    internal init(tabReaderFactory: @escaping @Sendable (String) -> any BrowserTabReading) {
        self.tabReaderFactory = tabReaderFactory
    }

    public func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        await detach()
        guard !Task.isCancelled else { return AsyncStream { $0.finish() } }

        self.hub = hub
        self.tabReader = tabReaderFactory(target.bundleId)
        let appElement = AXUIElementCreateApplication(target.pid)
        var capturedContinuation: AsyncStream<[BehaviorEnvelope]>.Continuation!
        let stream = AsyncStream<[BehaviorEnvelope]> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation

        for notification in Self.browserNotifications {
            guard !Task.isCancelled else { break }
            if let token = await hub.subscribe(
                pid: target.pid,
                element: appElement,
                notification: notification,
                handler: { [weak self] in
                    Task { await self?.scheduleRefresh() }
                }
            ) {
                subscriptionTokens.append(token)
            }
        }

        scheduleRefresh()
        return stream
    }

    public func detach() async {
        refreshTask?.cancel()
        refreshTask = nil
        tabReader = nil
        continuation?.finish()
        continuation = nil

        if let hub {
            for token in subscriptionTokens {
                await hub.unsubscribe(token)
            }
        }
        subscriptionTokens = []
        hub = nil
    }

    public func refresh() async -> [BehaviorEnvelope] {
        refreshTask?.cancel()
        return await readTabEnvelopes()
    }

    internal nonisolated static func makeEnvelopes(from tab: BrowserTabItem?) -> [BehaviorEnvelope] {
        guard let tab else { return [] }
        guard !tab.url.isEmpty else { return [] }
        let summary = tab.title.isEmpty ? tab.url : tab.title
        return [
            BehaviorEnvelope(
                kind: "browser.tab",
                citationKey: "browser.tab",
                displaySummary: summary,
                payload: .object([
                    "url": .string(tab.url),
                    "pageTitle": .string(tab.title),
                ])
            ),
        ]
    }

    private nonisolated static let browserNotifications: [String] = [
        kAXFocusedWindowChangedNotification as String,
        kAXMainWindowChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
        kAXTitleChangedNotification as String,
        kAXValueChangedNotification as String,
    ]

    private func scheduleRefresh() {
        guard let tabReader else {
            continuation?.yield([])
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { [tabReader] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                let tab = try await tabReader.readCurrentTab()
                try Task.checkCancellation()
                self.emitTab(tab)
            } catch is CancellationError {
                return
            } catch {
                Self.logReadFailure(error)
                self.emitTab(nil)
            }
        }
    }

    private func readAndEmitTab() async {
        let envelopes = await readTabEnvelopes()
        continuation?.yield(envelopes)
    }

    private func readTabEnvelopes() async -> [BehaviorEnvelope] {
        guard let tabReader else {
            return []
        }
        do {
            try Task.checkCancellation()
            let tab = try await tabReader.readCurrentTab()
            try Task.checkCancellation()
            return Self.makeEnvelopes(from: tab)
        } catch is CancellationError {
            return []
        } catch {
            Self.logReadFailure(error)
            return []
        }
    }

    private func emitTab(_ tab: BrowserTabItem?) {
        continuation?.yield(Self.makeEnvelopes(from: tab))
    }

    private nonisolated static func logReadFailure(_ error: any Error) {
        FileHandle.standardError.write(
            Data("[os-sense] BrowserAdapter tab read failed: \(error)\n".utf8)
        )
    }
}

internal protocol BrowserTabReading: Sendable {
    func readCurrentTab() async throws -> BrowserTabItem?
}

internal struct BrowserTabItem: Equatable, Sendable {
    let url: String
    let title: String
}

internal struct AppleScriptBrowserTabReader: BrowserTabReading {
    let bundleId: String

    func readCurrentTab() async throws -> BrowserTabItem? {
        try Task.checkCancellation()
        let descriptor = try Self.executeTabScript(bundleId: bundleId)
        try Task.checkCancellation()
        return try Self.makeTab(from: descriptor)
    }

    private static func executeTabScript(bundleId: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: tabScript(bundleId: bundleId)) else {
            throw BrowserTabReadError.invalidScript(bundleId: bundleId)
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw BrowserTabReadError.appleScript(bundleId: bundleId, String(describing: errorInfo))
        }
        return descriptor
    }

    private static func makeTab(from descriptor: NSAppleEventDescriptor) throws -> BrowserTabItem? {
        guard descriptor.numberOfItems > 0 else { return nil }
        guard let url = descriptor.atIndex(1)?.stringValue,
              let title = descriptor.atIndex(2)?.stringValue else {
            throw BrowserTabReadError.malformedDescriptor
        }
        return BrowserTabItem(url: url, title: title)
    }

    private static func tabScript(bundleId: String) -> String {
        if bundleId == "com.apple.Safari" {
            return """
            tell application id "\(bundleId)"
                if (count of windows) is 0 then return {}
                set tabRef to current tab of front window
                return {URL of tabRef, name of tabRef}
            end tell
            """
        }

        return """
        tell application id "\(bundleId)"
            if (count of windows) is 0 then return {}
            set tabRef to active tab of front window
            return {URL of tabRef, title of tabRef}
        end tell
        """
    }
}

internal enum BrowserTabReadError: Error, CustomStringConvertible {
    case invalidScript(bundleId: String)
    case appleScript(bundleId: String, String)
    case malformedDescriptor

    var description: String {
        switch self {
        case .invalidScript(let bundleId):
            "invalid AppleScript source for \(bundleId)"
        case .appleScript(let bundleId, let errorInfo):
            "AppleScript error for \(bundleId): \(errorInfo)"
        case .malformedDescriptor:
            "malformed AppleScript descriptor"
        }
    }
}
