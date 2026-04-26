import SwiftUI
import Foundation

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
                    return [.image(mime: mime)]
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
    case image(mime: String)
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
        case .image(let mime):
            Text("[image: \(mime)]")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
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
