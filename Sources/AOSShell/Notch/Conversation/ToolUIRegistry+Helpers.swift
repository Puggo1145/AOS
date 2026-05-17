import Foundation
import AOSRPCSchema

// MARK: - todo_write helpers

/// Render the `todo_write` tool call's args (the list the model is about
/// to write) as the same `[ ] / [>] / [x] #id: text` shape the sidecar's
/// `TodoManager.render()` produces. Keeps the inline row body consistent
/// with the live panel's wording. Returns `nil` on a malformed wire shape
/// so the presenter can surface an explicit malformed-tool message.
func renderTodoArgs(_ args: AOSRPCSchema.JSONValue) -> String? {
    guard case let .object(obj) = args, case let .array(rawItems) = obj["items"] ?? .null else {
        return nil
    }
    var lines: [String] = []
    var done = 0
    for raw in rawItems {
        guard case let .object(item) = raw,
              case let .string(id) = item["id"] ?? .null,
              case let .string(text) = item["text"] ?? .null,
              case let .string(status) = item["status"] ?? .null
        else { continue }
        let marker: String
        switch status {
        case "pending": marker = "[ ]"
        case "in_progress": marker = "[>]"
        case "completed": marker = "[x]"; done += 1
        default: marker = "[?]"
        }
        lines.append("\(marker) #\(id): \(text)")
    }
    if lines.isEmpty { return nil }
    lines.append("")
    lines.append("(\(done)/\(lines.count - 1) completed)")
    return lines.joined(separator: "\n")
}

func malformedToolArgs(_ toolName: String, missing field: String) -> String {
    "Malformed \(toolName) args: missing \(field)"
}

// MARK: - File-tool helpers
//
// These live outside the `@MainActor`-isolated `ToolUIRegistry` enum so the
// presenter closures (which are `@Sendable` and therefore must be callable
// from any isolation domain) can invoke them synchronously. They are pure
// functions over `JSONValue` with no shared state to protect.

/// Extract `args.path` for the file tools. Mirrors the JSON shape declared
/// in `agent/tools/{read,write,update}.ts`. Returns `nil` if the wire drifts.
func fileToolPath(_ args: JSONValue) -> String? {
    guard case let .object(obj) = args,
          case let .string(path) = obj["path"]
    else { return nil }
    return path
}

/// Row header label for file tools: `<verb> <basename>`. The basename keeps
/// the closed bar tight while the expanded body still carries the full path.
func fileToolLabel(verb: String, args: JSONValue) -> String {
    guard let path = fileToolPath(args), !path.isEmpty else { return verb }
    let base = (path as NSString).lastPathComponent
    return base.isEmpty ? verb : "\(verb) \(base)"
}

// MARK: - Computer Use helpers

let computerSummaryUnit = ToolUISummaryUnit(key: "computer_use") { count in
    count == 1 ? "used computer" : "used computer \(count) times"
}

func computerObject(_ value: JSONValue) -> [String: JSONValue]? {
    guard case let .object(obj) = value else { return nil }
    return obj
}

func computerEvent(_ args: JSONValue) -> [String: JSONValue]? {
    guard let obj = computerObject(args),
          let rawEvent = obj["event"],
          case let .object(event) = rawEvent
    else { return nil }
    return event
}

func computerString(_ args: JSONValue, _ key: String) -> String? {
    guard let obj = computerObject(args),
          case let .string(value) = obj[key]
    else { return nil }
    return value
}

func computerEventString(_ args: JSONValue, _ key: String) -> String? {
    guard let event = computerEvent(args),
          case let .string(value) = event[key]
    else { return nil }
    return value
}

func computerNumber(_ args: JSONValue, _ key: String) -> String? {
    guard let obj = computerObject(args), let value = obj[key] else { return nil }
    return computerNumberString(value)
}

func computerEventNumber(_ args: JSONValue, _ key: String) -> String? {
    guard let event = computerEvent(args), let value = event[key] else { return nil }
    return computerNumberString(value)
}

func computerNumberString(_ value: JSONValue) -> String? {
    switch value {
    case .int(let number):
        return String(number)
    case .double(let number):
        let rounded = number.rounded()
        if number == rounded,
           rounded >= Double(Int.min),
           rounded <= Double(Int.max) {
            return String(Int(rounded))
        }
        return String(number)
    default:
        return nil
    }
}

func computerPoint(_ args: JSONValue, _ key: String) -> String? {
    guard let event = computerEvent(args),
          let rawPoint = event[key],
          case let .object(point) = rawPoint,
          let rawX = point["x"],
          let rawY = point["y"],
          let x = computerNumberString(rawX),
          let y = computerNumberString(rawY)
    else { return nil }
    return "\(x), \(y)"
}

func computerModifiers(_ args: JSONValue) -> String? {
    guard let event = computerEvent(args),
          let rawModifiers = event["modifiers"],
          case let .array(modifiers) = rawModifiers
    else { return nil }

    let names = modifiers.compactMap { value -> String? in
        guard case let .string(name) = value else { return nil }
        return name
    }
    return names.isEmpty ? nil : names.joined(separator: "+")
}

func computerKeyValueBody(_ args: JSONValue, keys: [String]) -> String? {
    guard let obj = computerObject(args) else { return nil }
    let lines = keys.compactMap { key -> String? in
        guard let value = obj[key], let rendered = computerScalar(value) else { return nil }
        return "\(key): \(rendered)"
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

func computerScalar(_ value: JSONValue) -> String? {
    switch value {
    case .string(let string):
        return string
    case .int, .double:
        return computerNumberString(value)
    case .bool(let bool):
        return bool ? "true" : "false"
    default:
        return nil
    }
}

func computerResultWithArgs(_ args: JSONValue, output: String) -> String {
    guard let body = computerActionBody(args) else { return output }
    if output.isEmpty { return body }
    return "\(body)\n\n\(output)"
}

func computerActionBody(_ args: JSONValue) -> String? {
    switch computerEventString(args, "kind") {
    case "click", "drag":
        return computerMouseBody(args)
    case "text", "keyPress", "hotkey":
        return computerKeyboardBody(args)
    case "focus", "action", "setValue", "setSelectedText", "scroll":
        return computerAXBody(args)
    default:
        return nil
    }
}

func computerMouseLabel(_ args: JSONValue, isCalling: Bool) -> String {
    switch computerEventString(args, "kind") {
    case "click":
        let verb = isCalling ? "clicking" : "clicked"
        let point = computerPoint(args, "point").map { " at \($0)" } ?? ""
        return "\(verb)\(point)"
    case "drag":
        let verb = isCalling ? "dragging" : "dragged"
        guard let from = computerPoint(args, "from"), let to = computerPoint(args, "to") else {
            return verb
        }
        return "\(verb) \(from) to \(to)"
    default:
        return isCalling ? "using mouse" : "used mouse"
    }
}

func computerMouseBody(_ args: JSONValue) -> String? {
    let kind = computerEventString(args, "kind").map { "event: \($0)" }
    let button = computerEventString(args, "button").map { "button: \($0)" }
    let point = computerPoint(args, "point").map { "point: \($0)" }
    let from = computerPoint(args, "from").map { "from: \($0)" }
    let to = computerPoint(args, "to").map { "to: \($0)" }
    let count = computerEventNumber(args, "count").map { "count: \($0)" }
    return [kind, button, point, from, to, count].compactMap(\.self).joinedNonEmpty()
}

func computerKeyboardLabel(_ args: JSONValue, isCalling: Bool) -> String {
    switch computerEventString(args, "kind") {
    case "text":
        return isCalling ? "typing text" : "typed text"
    case "keyPress":
        let verb = isCalling ? "pressing" : "pressed"
        let key = computerEventString(args, "key").map { " \($0)" } ?? ""
        return "\(verb)\(key)"
    case "hotkey":
        let verb = isCalling ? "pressing" : "pressed"
        let modifiers = computerModifiers(args)
        let key = computerEventString(args, "key")
        if let modifiers, let key {
            return "\(verb) \(modifiers)+\(key)"
        }
        return "\(verb) hotkey"
    default:
        return isCalling ? "using keyboard" : "used keyboard"
    }
}

func computerKeyboardBody(_ args: JSONValue) -> String? {
    let kind = computerEventString(args, "kind").map { "event: \($0)" }
    let text = computerEventString(args, "text").map { "text: \($0)" }
    let key = computerEventString(args, "key").map { "key: \($0)" }
    let modifiers = computerModifiers(args).map { "modifiers: \($0)" }
    let count = computerEventNumber(args, "count").map { "count: \($0)" }
    let delay = computerEventNumber(args, "delayMilliseconds").map { "delayMilliseconds: \($0)" }
    return [kind, text, key, modifiers, count, delay].compactMap(\.self).joinedNonEmpty()
}

func computerAXLabel(_ args: JSONValue, isCalling: Bool) -> String {
    let element = computerNumber(args, "elementIndex").map { " AX element \($0)" } ?? " AX element"
    switch computerEventString(args, "kind") {
    case "focus":
        return "\(isCalling ? "focusing" : "focused")\(element)"
    case "action":
        let action = computerEventString(args, "action")
        let verb = computerAXActionVerb(action, isCalling: isCalling)
        return "\(verb)\(element)"
    case "setValue":
        return "\(isCalling ? "setting" : "set")\(element) value"
    case "setSelectedText":
        return "\(isCalling ? "setting" : "set")\(element) selection"
    case "scroll":
        let direction = computerEventString(args, "direction").map { " \($0)" } ?? ""
        return "\(isCalling ? "scrolling" : "scrolled")\(element)\(direction)"
    default:
        return isCalling ? "using AX element" : "used AX element"
    }
}

func computerAXActionVerb(_ action: String?, isCalling: Bool) -> String {
    switch action {
    case "press":
        return isCalling ? "pressing" : "pressed"
    case "open":
        return isCalling ? "opening" : "opened"
    case "showMenu":
        return isCalling ? "showing menu on" : "showed menu on"
    case "increment":
        return isCalling ? "incrementing" : "incremented"
    case "decrement":
        return isCalling ? "decrementing" : "decremented"
    case "scrollToVisible":
        return isCalling ? "revealing" : "revealed"
    case "pick":
        return isCalling ? "picking" : "picked"
    case "confirm":
        return isCalling ? "confirming" : "confirmed"
    case "cancel":
        return isCalling ? "cancelling" : "cancelled"
    default:
        return isCalling ? "acting on" : "acted on"
    }
}

func computerAXBody(_ args: JSONValue) -> String? {
    let element = computerNumber(args, "elementIndex").map { "elementIndex: \($0)" }
    let kind = computerEventString(args, "kind").map { "event: \($0)" }
    let action = computerEventString(args, "action").map { "action: \($0)" }
    let value = computerEventString(args, "value").map { "value: \($0)" }
    let direction = computerEventString(args, "direction").map { "direction: \($0)" }
    let pages = computerEventNumber(args, "pages").map { "pages: \($0)" }
    return [element, kind, action, value, direction, pages].compactMap(\.self).joinedNonEmpty()
}

private extension Array where Element == String {
    func joinedNonEmpty() -> String? {
        guard !isEmpty else { return nil }
        return joined(separator: "\n")
    }
}
