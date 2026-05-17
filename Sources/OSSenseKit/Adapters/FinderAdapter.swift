import Foundation
import ApplicationServices

/// Finder-specific OS Sense adapter that turns the current Finder selection
/// into final, citable file URLs.
public actor FinderAdapter: SenseAdapter {
    public static let id: AdapterID = "finder"
    public static let supportedBundleIds: Set<String> = ["com.apple.finder"]

    public nonisolated let requiredPermissions: Set<Permission> = [.accessibility, .automation]

    private let selectionReader: any FinderSelectionReading
    private var hub: AXObserverHub?
    private var subscriptionTokens: [AXObserverHub.Token] = []
    private var continuation: AsyncStream<[BehaviorEnvelope]>.Continuation?
    private var refreshTask: Task<Void, Never>?

    /// Creates the production Finder adapter backed by AppleScript Finder
    /// selection reads.
    public init() {
        self.selectionReader = AppleScriptFinderSelectionReader()
    }

    /// Creates a Finder adapter with an injected reader for tests.
    internal init(selectionReader: any FinderSelectionReading) {
        self.selectionReader = selectionReader
    }

    public func attach(hub: AXObserverHub, target: RunningApp) async -> AsyncStream<[BehaviorEnvelope]> {
        await detach()
        guard !Task.isCancelled else { return AsyncStream { $0.finish() } }

        self.hub = hub
        let appElement = AXUIElementCreateApplication(target.pid)
        var capturedContinuation: AsyncStream<[BehaviorEnvelope]>.Continuation!
        let stream = AsyncStream<[BehaviorEnvelope]> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation

        for notification in Self.finderNotifications {
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

    public func refresh() async {
        scheduleRefresh()
    }

    /// Converts Finder selection rows into the opaque behavior shape consumed
    /// by SenseStore and the submit projection.
    internal nonisolated static func makeEnvelopes(from items: [FinderSelectionItem]) -> [BehaviorEnvelope] {
        guard let first = items.first else { return [] }

        let summary: String
        if items.count == 1 {
            summary = first.label
        } else {
            summary = "\(first.label) + \(items.count - 1)"
        }

        return [
            BehaviorEnvelope(
                kind: "finder.selection",
                citationKey: "finder.selection",
                displaySummary: summary,
                payload: .object([
                    "items": .array(items.map(\.jsonValue)),
                ])
            ),
        ]
    }

    private nonisolated static let finderNotifications: [String] = [
        kAXSelectedChildrenChangedNotification as String,
        kAXSelectedRowsChangedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXMainWindowChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
    ]

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [selectionReader] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                let items = try await selectionReader.readSelection()
                try Task.checkCancellation()
                self.emitSelection(items)
            } catch is CancellationError {
                return
            } catch {
                Self.logReadFailure(error)
                self.emitSelection([])
            }
        }
    }

    private func emitSelection(_ items: [FinderSelectionItem]) {
        continuation?.yield(Self.makeEnvelopes(from: items))
    }

    private nonisolated static func logReadFailure(_ error: any Error) {
        FileHandle.standardError.write(
            Data("[os-sense] FinderAdapter selection read failed: \(error)\n".utf8)
        )
    }
}

/// Reads the current Finder selection as structured rows.
internal protocol FinderSelectionReading: Sendable {
    func readSelection() async throws -> [FinderSelectionItem]
}

/// Finder item role exposed in `finder.selection` payloads.
internal enum FinderSelectionRole: String, Sendable {
    case file
    case folder
    case alias
    case item
}

/// A Finder selection row after AppleScript has resolved it to a file URL.
internal struct FinderSelectionItem: Equatable, Sendable {
    let role: FinderSelectionRole
    let label: String
    let fileURL: URL

    var jsonValue: JSONValue {
        .object([
            "role": .string(role.rawValue),
            "label": .string(label),
            "identifier": .string(fileURL.absoluteString),
        ])
    }
}

/// AppleScript-backed Finder selection reader. The script returns a list of
/// `{POSIX path, Finder class}` pairs so Swift parses descriptors instead of
/// scraping display text.
internal struct AppleScriptFinderSelectionReader: FinderSelectionReading {
    func readSelection() async throws -> [FinderSelectionItem] {
        try Task.checkCancellation()
        let descriptor = try Self.executeSelectionScript()
        try Task.checkCancellation()
        return try Self.makeSelectionItems(from: descriptor)
    }

    internal static func makeSelectionItem(
        posixPath: String,
        finderClass: String
    ) throws -> FinderSelectionItem {
        let isDirectory = normalizedRole(fromFinderClass: finderClass) == .folder
        let fileURL = URL(fileURLWithPath: posixPath, isDirectory: isDirectory)
        let label = fileURL.lastPathComponent
        guard !label.isEmpty else {
            throw FinderSelectionReadError.emptyLabel(posixPath: posixPath)
        }
        return FinderSelectionItem(
            role: normalizedRole(fromFinderClass: finderClass),
            label: label,
            fileURL: fileURL
        )
    }

    private static func executeSelectionScript() throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: Self.selectionScript) else {
            throw FinderSelectionReadError.invalidScript
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw FinderSelectionReadError.appleScript(String(describing: errorInfo))
        }
        return descriptor
    }

    private static func makeSelectionItems(
        from descriptor: NSAppleEventDescriptor
    ) throws -> [FinderSelectionItem] {
        guard descriptor.numberOfItems > 0 else { return [] }

        var items: [FinderSelectionItem] = []
        for index in 1...descriptor.numberOfItems {
            guard let row = descriptor.atIndex(index),
                  let posixPath = row.atIndex(1)?.stringValue,
                  let finderClass = row.atIndex(2)?.stringValue else {
                throw FinderSelectionReadError.malformedDescriptor(index: index)
            }
            items.append(try makeSelectionItem(
                posixPath: posixPath,
                finderClass: finderClass
            ))
        }
        return items
    }

    private static func normalizedRole(fromFinderClass finderClass: String) -> FinderSelectionRole {
        let lowercased = finderClass.lowercased()
        if lowercased.contains("alias") { return .alias }
        if lowercased.contains("folder") { return .folder }
        if lowercased.contains("file") { return .file }
        return .item
    }

    private static let selectionScript = """
    tell application "Finder"
        set selectedItems to selection
        set outputRows to {}
        repeat with itemRef in selectedItems
            set itemPath to POSIX path of (itemRef as alias)
            set itemClass to class of itemRef as string
            set end of outputRows to {itemPath, itemClass}
        end repeat
        return outputRows
    end tell
    """
}

internal enum FinderSelectionReadError: Error, CustomStringConvertible {
    case invalidScript
    case appleScript(String)
    case malformedDescriptor(index: Int)
    case emptyLabel(posixPath: String)

    var description: String {
        switch self {
        case .invalidScript:
            "invalid AppleScript source"
        case .appleScript(let errorInfo):
            "AppleScript error: \(errorInfo)"
        case .malformedDescriptor(let index):
            "malformed AppleScript descriptor at row \(index)"
        case .emptyLabel(let posixPath):
            "Finder selection path has no label: \(posixPath)"
        }
    }
}
