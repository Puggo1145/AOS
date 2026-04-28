import Foundation

// MARK: - TreeRenderer
//
// Per `docs/designs/computer-use.md` §"AX 树遍历" line format:
//
//   [<index>] <role> "<title>" (<subrole>) <description> actions=[...]
//
// Walked by `AccessibilitySnapshot`; LLM-readable Markdown so the agent
// can match elements by index. Lines without an index are non-interactive
// containers (groups, layout regions, etc).

public enum TreeRenderer {
    public static func renderLine(
        depth: Int,
        elementIndex: Int?,
        role: String,
        subrole: String?,
        title: String?,
        value: String?,
        description: String?,
        identifier: String?,
        help: String?,
        enabled: Bool?,
        actions: [String]
    ) -> String {
        var line = String(repeating: "  ", count: depth) + "- "
        if let idx = elementIndex {
            line += "[\(idx)] "
        }
        line += role
        if let sub = subrole, !sub.isEmpty {
            line += " (\(sub))"
        }
        if let t = title, !t.isEmpty {
            line += " \"\(t)\""
        }
        if let v = value, !v.isEmpty, v.count < 120 {
            line += " = \"\(v)\""
        }
        if let d = description, !d.isEmpty, d.count < 120 {
            line += " desc=\"\(d)\""
        }
        if let h = help, !h.isEmpty, h.count < 160 {
            line += " help=\"\(h)\""
        }
        if let id = identifier, !id.isEmpty {
            line += " id=\(id)"
        }
        // DISABLED only meaningful on interactive elements; containers
        // routinely report enabled=false.
        if elementIndex != nil, enabled == false {
            line += " DISABLED"
        }
        // AXPress is the default click; show secondary actions so the LLM
        // can pick the right verb (AXShowMenu for right-click, AXIncrement
        // for steppers, etc).
        let secondary = actions.filter { $0 != "AXPress" }
        if !secondary.isEmpty {
            line += " actions=[\(secondary.joined(separator: ", "))]"
        }
        return line
    }
}
