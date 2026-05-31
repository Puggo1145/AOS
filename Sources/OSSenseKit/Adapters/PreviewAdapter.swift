import ApplicationServices
import Foundation

/// Preview-specific OS Sense adapter that exposes the front PDF document as a
/// citable file URL. Preview's script dictionary gives the canonical document
/// path; AX is used only as the live notification trigger.
public actor PreviewAdapter: SenseAdapter {
    public static let id: AdapterID = "preview"
    public static let supportedBundleIds: Set<String> = ["com.apple.Preview"]

    public nonisolated let requiredPermissions: Set<Permission> = [.accessibility, .automation]

    private let documentReader: any PreviewDocumentReading
    private var hub: AXObserverHub?
    private var subscriptionTokens: [AXObserverHub.Token] = []
    private var continuation: AsyncStream<[BehaviorEnvelope]>.Continuation?
    private var refreshTask: Task<Void, Never>?

    public init() {
        self.documentReader = AppleScriptPreviewDocumentReader()
    }

    internal init(documentReader: any PreviewDocumentReading) {
        self.documentReader = documentReader
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

        for notification in Self.previewNotifications {
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

    public func refresh() async -> [BehaviorEnvelope] {
        refreshTask?.cancel()
        return await readDocumentEnvelopes()
    }

    internal nonisolated static func makeEnvelopes(from document: PreviewDocumentItem?) -> [BehaviorEnvelope] {
        guard let document else { return [] }
        guard document.fileURL.pathExtension.lowercased() == "pdf" else { return [] }
        return [
            BehaviorEnvelope(
                kind: "pdf.document",
                citationKey: "pdf.document",
                displaySummary: document.title,
                payload: .object([
                    "title": .string(document.title),
                    "fileURL": .string(document.fileURL.absoluteString),
                ])
            ),
        ]
    }

    private nonisolated static let previewNotifications: [String] = [
        kAXFocusedWindowChangedNotification as String,
        kAXMainWindowChangedNotification as String,
        kAXFocusedUIElementChangedNotification as String,
        kAXTitleChangedNotification as String,
    ]

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [documentReader] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                let document = try await documentReader.readCurrentDocument()
                try Task.checkCancellation()
                self.emitDocument(document)
            } catch is CancellationError {
                return
            } catch {
                Self.logReadFailure(error)
                self.emitDocument(nil)
            }
        }
    }

    private func readAndEmitDocument() async {
        let envelopes = await readDocumentEnvelopes()
        continuation?.yield(envelopes)
    }

    private func readDocumentEnvelopes() async -> [BehaviorEnvelope] {
        do {
            try Task.checkCancellation()
            let document = try await documentReader.readCurrentDocument()
            try Task.checkCancellation()
            return Self.makeEnvelopes(from: document)
        } catch is CancellationError {
            return []
        } catch {
            Self.logReadFailure(error)
            return []
        }
    }

    private func emitDocument(_ document: PreviewDocumentItem?) {
        continuation?.yield(Self.makeEnvelopes(from: document))
    }

    private nonisolated static func logReadFailure(_ error: any Error) {
        FileHandle.standardError.write(
            Data("[os-sense] PreviewAdapter document read failed: \(error)\n".utf8)
        )
    }
}

internal protocol PreviewDocumentReading: Sendable {
    func readCurrentDocument() async throws -> PreviewDocumentItem?
}

internal struct PreviewDocumentItem: Equatable, Sendable {
    let title: String
    let fileURL: URL
}

internal struct AppleScriptPreviewDocumentReader: PreviewDocumentReading {
    func readCurrentDocument() async throws -> PreviewDocumentItem? {
        try Task.checkCancellation()
        let descriptor = try Self.executeDocumentScript()
        try Task.checkCancellation()
        return try Self.makeDocument(from: descriptor)
    }

    private static func executeDocumentScript() throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: Self.documentScript) else {
            throw PreviewDocumentReadError.invalidScript
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw PreviewDocumentReadError.appleScript(String(describing: errorInfo))
        }
        return descriptor
    }

    private static func makeDocument(from descriptor: NSAppleEventDescriptor) throws -> PreviewDocumentItem? {
        guard descriptor.numberOfItems > 0 else { return nil }
        guard let title = descriptor.atIndex(1)?.stringValue,
              let path = descriptor.atIndex(2)?.stringValue else {
            throw PreviewDocumentReadError.malformedDescriptor
        }
        guard !title.isEmpty else { throw PreviewDocumentReadError.emptyTitle }
        guard !path.isEmpty else { throw PreviewDocumentReadError.emptyPath(title: title) }
        return PreviewDocumentItem(
            title: title,
            fileURL: URL(fileURLWithPath: path)
        )
    }

    private static let documentScript = """
    tell application id "com.apple.Preview"
        if (count of windows) is 0 then return {}
        set docRef to document of front window
        return {name of docRef, path of docRef}
    end tell
    """
}

internal enum PreviewDocumentReadError: Error, CustomStringConvertible {
    case invalidScript
    case appleScript(String)
    case malformedDescriptor
    case emptyTitle
    case emptyPath(title: String)

    var description: String {
        switch self {
        case .invalidScript:
            "invalid AppleScript source"
        case .appleScript(let errorInfo):
            "AppleScript error: \(errorInfo)"
        case .malformedDescriptor:
            "malformed AppleScript descriptor"
        case .emptyTitle:
            "Preview document has no title"
        case .emptyPath(let title):
            "Preview document has no path: \(title)"
        }
    }
}
