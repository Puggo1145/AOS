import SwiftUI
import Foundation
import AppKit

// MARK: - DevMessagesView
//
// Human-readable renderer for the `messagesJson` blob captured by the
// Sidecar's context observer. The wire payload is still authoritative —
// this view just unpacks it into per-message cards (role / timestamp /
// content parts) so a developer can scan a turn without parsing escaped
// JSON in their head.
//
// `<os-context>…</os-context>` framing inside a user text block is
// extracted into its own dim sub-card so the actual prompt the user typed
// is read first. Unknown shapes fall back to monospace JSON for that
// single message rather than failing the whole render.

struct DevMessagesView: View {
    let messagesJson: String

    @State private var showRaw: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Messages")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Picker("", selection: $showRaw) {
                    Text("Pretty").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            if showRaw {
                rawView
            } else if let messages = parse(messagesJson) {
                if messages.isEmpty {
                    Text("—")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardBackground)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages.indices, id: \.self) { i in
                            MessageCard(message: messages[i])
                        }
                    }
                }
            } else {
                // Parse failure → don't lie, surface the raw blob.
                rawView
            }
        }
    }

    private var rawView: some View {
        Text(messagesJson.isEmpty ? "—" : messagesJson)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.secondary.opacity(0.08))
    }

    private func parse(_ json: String) -> [ParsedMessage]? {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let arr = any as? [Any] else { return nil }
        // Never silently drop entries: a Dev panel that hides part of the
        // authoritative payload is worse than one that shows raw fallback.
        // Non-dict elements become an "unknown" card carrying their JSON.
        return arr.map { ParsedMessage(any: $0) }
    }
}

// MARK: - Parsed model

private enum ParsedRole: String {
    case user
    case assistant
    case toolResult
    case unknown

    init(_ raw: String?) {
        switch raw {
        case "user": self = .user
        case "assistant": self = .assistant
        case "toolResult": self = .toolResult
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .user: return "USER"
        case .assistant: return "ASSISTANT"
        case .toolResult: return "TOOL RESULT"
        case .unknown: return "UNKNOWN"
        }
    }

    var color: Color {
        switch self {
        case .user: return .blue
        case .assistant: return .purple
        case .toolResult: return .orange
        case .unknown: return .gray
        }
    }
}

private struct ParsedMessage: Identifiable {
    let id = UUID()
    let role: ParsedRole
    let timestamp: Int?
    let parts: [ParsedPart]
    /// Tool-result-only metadata, surfaced inline.
    let toolName: String?
    let toolCallId: String?
    let isError: Bool

    init(any: Any) {
        guard let dict = any as? [String: Any] else {
            // Preserve the raw shape so the user can still see what was in
            // the wire payload, just under an "UNKNOWN" card.
            self.role = .unknown
            self.timestamp = nil
            self.toolName = nil
            self.toolCallId = nil
            self.isError = false
            self.parts = [.unknown(ParsedMessage.prettyJSON(any))]
            return
        }
        self.role = ParsedRole(dict["role"] as? String)
        self.timestamp = (dict["timestamp"] as? Int)
            ?? (dict["timestamp"] as? Double).map { Int($0) }
        self.toolName = dict["toolName"] as? String
        self.toolCallId = dict["toolCallId"] as? String
        self.isError = (dict["isError"] as? Bool) ?? false
        self.parts = ParsedMessage.partsFromContent(dict["content"])
    }

    private static func partsFromContent(_ content: Any?) -> [ParsedPart] {
        if let s = content as? String {
            return splitOSContext(s)
        }
        if let arr = content as? [Any] {
            return arr.flatMap { item -> [ParsedPart] in
                guard let part = item as? [String: Any] else {
                    return [.unknown(jsonString(item))]
                }
                let type = part["type"] as? String
                switch type {
                case "text":
                    let text = part["text"] as? String ?? ""
                    return splitOSContext(text)
                case "thinking":
                    let t = part["thinking"] as? String ?? ""
                    return [.thinking(t, redacted: (part["redacted"] as? Bool) ?? false)]
                case "toolCall":
                    let name = part["name"] as? String ?? "?"
                    let argsAny = part["arguments"] ?? [:]
                    return [.toolCall(name: name, arguments: prettyJSON(argsAny))]
                case "image":
                    let mime = part["mimeType"] as? String ?? "image"
                    let data = part["data"] as? String ?? ""
                    return [.image(mime: mime, base64: data)]
                default:
                    return [.unknown(jsonString(part))]
                }
            }
        }
        return [.unknown(jsonString(content as Any))]
    }

    /// Split `<os-context>…</os-context>` framing out of a text block so the
    /// actual prompt the user typed is rendered as the primary part.
    private static func splitOSContext(_ raw: String) -> [ParsedPart] {
        let openTag = "<os-context>"
        let closeTag = "</os-context>"
        guard let openRange = raw.range(of: openTag),
              let closeRange = raw.range(of: closeTag),
              openRange.upperBound <= closeRange.lowerBound else {
            return [.text(raw)]
        }
        let before = String(raw[..<openRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inside = String(raw[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(raw[closeRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [ParsedPart] = []
        if !before.isEmpty { parts.append(.text(before)) }
        parts.append(.osContext(inside))
        if !after.isEmpty { parts.append(.text(after)) }
        return parts
    }

    private static func prettyJSON(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(
                  withJSONObject: any,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let s = String(data: data, encoding: .utf8) else {
            return String(describing: any)
        }
        return s
    }

    private static func jsonString(_ any: Any) -> String {
        prettyJSON(any)
    }
}

private enum ParsedPart {
    case text(String)
    case osContext(String)
    case thinking(String, redacted: Bool)
    case toolCall(name: String, arguments: String)
    case image(mime: String, base64: String)
    case unknown(String)
}

// MARK: - Card view

private struct MessageCard: View {
    let message: ParsedMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(message.role.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(message.role.color.opacity(0.85))
                    )
                if let tool = message.toolName {
                    Text(tool)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if message.isError {
                    Text("error")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                if let ts = message.timestamp {
                    Text(formatTimestamp(ts))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            ForEach(message.parts.indices, id: \.self) { i in
                partView(message.parts[i])
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(message.role.color.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(message.role.color.opacity(0.20), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func partView(_ part: ParsedPart) -> some View {
        switch part {
        case .text(let s):
            Text(s)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .osContext(let s):
            CollapsibleBlock(title: "os-context", content: s, monospaced: true)
        case .thinking(let s, let redacted):
            CollapsibleBlock(
                title: redacted ? "thinking (redacted)" : "thinking",
                content: s,
                monospaced: false
            )
        case .toolCall(let name, let args):
            VStack(alignment: .leading, spacing: 4) {
                Text("call: \(name)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(args)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }
        case .image(let mime, let base64):
            ImagePartView(mime: mime, base64: base64)
        case .unknown(let raw):
            Text(raw)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatTimestamp(_ msSinceEpoch: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(msSinceEpoch) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}

private struct CollapsibleBlock: View {
    let title: String
    let content: String
    let monospaced: Bool

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(content)
                    .font(.system(
                        size: monospaced ? 11 : 12,
                        design: monospaced ? .monospaced : .default
                    ))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }
        }
    }
}

// MARK: - Image part renderer
//
// The wire-side `ImageContent` block is what the LLM actually sees on
// vision turns; rendering it as `[image: image/png]` defeats the point of
// Dev Mode (no way to confirm the agent is looking at the right window).
// We decode the base64 once into an `NSImage`, render a clamped thumbnail,
// and present a full-size viewer on click. Decode failure surfaces as a
// labeled placeholder rather than a crash — wire bugs should be visible.

private struct ImagePartView: View {
    let mime: String
    private let decoded: NSImage?
    private let base64Length: Int

    init(mime: String, base64: String) {
        self.mime = mime
        self.base64Length = base64.count
        // Decode at struct construction so repeated body evaluations on the
        // same View instance don't re-run base64 + NSImage(data:). The struct
        // is still rebuilt when the parent invalidates — that's SwiftUI's
        // normal cost, not something to fight.
        if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           let image = NSImage(data: data) {
            self.decoded = image
        } else {
            self.decoded = nil
        }
    }

    /// Cap the inline thumbnail at this height. Big enough to recognize a
    /// window snapshot, small enough to keep the message card scannable.
    private static let thumbnailMaxHeight: CGFloat = 160

    var body: some View {
        if let image = decoded {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    ImageViewerWindowController.present(image: image, mime: mime)
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .frame(maxHeight: Self.thumbnailMaxHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.black.opacity(0.4))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to open full-size viewer (pinch / ⌘+ to zoom)")
                .accessibilityLabel(Text("Image attached to message; click to open full-size viewer"))

                Text("\(mime) · \(Int(image.size.width))×\(Int(image.size.height)) · click to enlarge")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else {
            // Decode failure is louder than silent — the wire claimed an
            // image was there, so a developer should see something is off.
            Text("[image: \(mime) — failed to decode \(base64Length) base64 chars]")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Full-size image viewer (separate NSWindow)
//
// SwiftUI `.sheet` is sized by the parent window and ignores idealWidth/
// idealHeight on macOS, which left the previous viewer stuck at a tiny
// square with no way to fit a 1280×800 frame. A standalone NSWindow
// hosting an NSScrollView with `allowsMagnification = true` gives the
// developer a real inspector: resizable, pinch / ⌘+/⌘-/⌘0 zoom, scroll
// to pan. Each click spawns a new viewer (Dev Mode is for comparing
// turns side-by-side, not single-document editing).

@MainActor
private final class ImageViewerWindowController: NSWindowController, NSWindowDelegate {

    /// Strong-retains live viewers — without this the controller would be
    /// deallocated as soon as the SwiftUI button action returns and the
    /// window would close. Cleared on `windowWillClose`.
    private static var liveControllers: Set<ImageViewerWindowController> = []

    static func present(image: NSImage, mime: String) {
        let controller = ImageViewerWindowController(image: image, mime: mime)
        liveControllers.insert(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(image: NSImage, mime: String) {
        // Initial window size: fit the image but cap to 90% of the visible
        // screen so a 4K capture doesn't open off-screen. The user can
        // resize freely afterwards; the scroll view handles overflow with
        // pan + magnification.
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxW = screen.width * 0.9
        let maxH = screen.height * 0.9
        let imageW = max(image.size.width, 1)
        let imageH = max(image.size.height, 1)
        let aspect = imageH / imageW
        var w = min(imageW, maxW)
        var h = w * aspect
        if h > maxH {
            h = maxH
            w = h / max(aspect, 0.0001)
        }
        // Reserve a bit of vertical space for the title bar; AppKit takes
        // care of titlebar geometry but we don't want the document area
        // to start cramped.
        let contentRect = NSRect(x: 0, y: 0, width: w, height: h)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Image · \(mime) · \(Int(imageW))×\(Int(imageH))"
        window.isReleasedWhenClosed = false
        window.center()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        // Magnification: 0.05× lets the user shrink-fit huge frames; 16×
        // is enough to inspect individual pixels for AX / OCR debugging.
        // ⌘+ / ⌘- / ⌘0 are bound automatically by NSScrollView when
        // magnification is enabled.
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16.0

        // Initial magnification: fit-to-window. The user can pinch /
        // ⌘+ from there; ⌘0 returns to fit.
        let fit = min(w / imageW, h / imageH)
        scrollView.magnification = fit > 0 ? fit : 1.0

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: NSSize(width: imageW, height: imageH)))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Sharper pixel rendering when zoomed past 100% — matters for
        // checking small UI text inside a captured frame.
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest

        scrollView.documentView = imageView

        window.contentView = scrollView
        super.init(window: nil)
        self.window = window
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ImageViewerWindowController is constructed in code only")
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the strong reference so the controller (and its image)
        // can be released. Multiple viewers coexist; only the closing
        // one leaves the set.
        ImageViewerWindowController.liveControllers.remove(self)
    }
}
