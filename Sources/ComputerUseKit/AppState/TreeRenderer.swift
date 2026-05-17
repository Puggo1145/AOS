import Foundation

// MARK: - TreeRenderer
//
// Per `docs/designs/computer-use.md` §"AX 树遍历" line format:
//
//   <index> <normalized role> <name>, Description: ..., ID: ..., Secondary Actions: ...
//
// Walked by `AccessibilitySnapshot`; LLM-readable Markdown so the agent
// can match every rendered element by index.

enum TreeRenderer {
    public static func renderLine(
        depth: Int,
        elementIndex: Int,
        role: String,
        subrole: String?,
        title: String?,
        value: String?,
        description: String?,
        identifier: String?,
        help: String?,
        placeholder: String?,
        enabled: Bool?,
        selected: Bool?,
        valueSettable: Bool,
        actions: [String]
    ) -> String {
        var line = String(repeating: "\t", count: depth)
        line += "\(elementIndex)"
        let roleName = displayRole(role: role, subrole: subrole, valueSettable: valueSettable)
        if !roleName.isEmpty {
            line += " \(roleName)"
        }

        var states: [String] = []
        if selected == true {
            states.append("selected")
        }
        if enabled == false {
            states.append("disabled")
        }
        if !states.isEmpty {
            line += " (\(states.joined(separator: ", ")))"
        }

        let displayIdentifier = displayIdentifier(identifier)
        let name = primaryName(
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            identifier: displayIdentifier
        )
        if let name {
            line += " \(name)"
        }

        var attributes: [String] = []
        if let value = displayString(value),
           value != name,
           value != title,
           value != description {
            attributes.append("Value: \(value)")
        }
        if let description = displayString(description), description != title {
            attributes.append("Description: \(description)")
        }
        if let help = displayString(help) {
            attributes.append("Help: \(help)")
        }
        if let placeholder = displayString(placeholder) {
            attributes.append("Placeholder: \(placeholder)")
        }
        if let identifier = displayIdentifier, identifier != name {
            attributes.append("ID: \(identifier)")
        }

        let secondary = actions
            .filter { $0 != "AXPress" }
            .map(displayAction(_:))
            .filter { !isNoisyAction($0) }
        if !secondary.isEmpty {
            attributes.append("Secondary Actions: \(secondary.joined(separator: ", "))")
        }
        if !attributes.isEmpty {
            line += (name == nil ? " " : ", ") + attributes.joined(separator: ", ")
        }
        return line
    }

    private static func displayRole(role: String, subrole: String?, valueSettable: Bool) -> String {
        switch (role, subrole) {
        case ("AXApplication", _):
            return "application"
        case ("AXWindow", "AXStandardWindow"):
            return "standard window"
        case ("AXWindow", _):
            return "window"
        case ("AXSplitGroup", _):
            return "split group"
        case ("AXTabGroup", _):
            return "tab group"
        case ("AXScrollArea", _):
            return "scroll area"
        case ("AXList", "AXCollectionList"):
            return "collection"
        case ("AXList", "AXSectionList"):
            return "section"
        case ("AXList", _):
            return "list"
        case ("AXGroup", _):
            return "container"
        case ("AXButton", "AXCloseButton"):
            return "close button"
        case ("AXButton", "AXMinimizeButton"):
            return "minimize button"
        case ("AXButton", "AXFullScreenButton"):
            return "full screen button"
        case ("AXButton", _):
            return "button"
        case ("AXCheckBox", "AXToggle"):
            return "toggle button"
        case ("AXCheckBox", _):
            return "checkbox"
        case ("AXRadioButton", _):
            return "radio button"
        case ("AXTextField", _):
            return valueSettable ? "text field (settable, string)" : "text field"
        case ("AXTextArea", _):
            return valueSettable ? "text entry area (settable, string)" : "text entry area"
        case ("AXStaticText", _):
            return "text"
        case ("AXImage", _):
            return "image"
        case ("AXToolbar", _):
            return "toolbar"
        case ("AXMenuBar", _):
            return "menu bar"
        case ("AXMenu", _):
            return "menu"
        case ("AXMenuItem", _):
            return "menu item"
        case ("AXMenuBarItem", _):
            return ""
        case ("AXMenuButton", _):
            return "menu button"
        case ("AXPopUpButton", _):
            return "menu button"
        case ("AXSlider", _):
            return "slider"
        case ("AXScrollBar", _):
            return "scroll bar"
        case ("AXCloseButton", _):
            return "close button"
        case ("AXMinimizeButton", _):
            return "minimize button"
        case ("AXFullScreenButton", _):
            return "full screen button"
        default:
            return role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role
        }
    }

    private static func displayAction(_ action: String) -> String {
        switch action {
        case "AXRaise": return "Raise"
        case "AXShowMenu": return "Show Menu"
        case "AXPick": return "Pick"
        case "AXConfirm": return "Confirm"
        case "AXCancel": return "Cancel"
        case "AXOpen": return "Open"
        case "AXIncrement": return "Increment"
        case "AXDecrement": return "Decrement"
        case "AXScrollToVisible": return "Scroll To Visible"
        case "AXScrollUpByPage": return "Scroll Up"
        case "AXScrollDownByPage": return "Scroll Down"
        case "AXScrollLeftByPage": return "Scroll Left"
        case "AXScrollRightByPage": return "Scroll Right"
        case "AXZoomWindow": return "zoom the window"
        default:
            return action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
        }
    }

    private static func isNoisyAction(_ action: String) -> Bool {
        switch action {
        case "Show Menu", "Confirm", "Cancel", "Pick", "ShowDefaultUI", "ShowAlternateUI", "Scroll To Visible":
            return true
        default:
            return false
        }
    }

    private static func primaryName(
        role: String,
        subrole: String?,
        title: String?,
        value: String?,
        identifier: String?
    ) -> String? {
        if let title = displayString(title) {
            return title
        }
        if let value = displayString(value) {
            return value
        }
        switch (role, subrole) {
        case ("AXImage", _), ("AXGroup", _), ("AXList", _), ("AXMenuBarItem", _):
            return displayString(identifier)
        default:
            return nil
        }
    }

    private static func displayIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("_NS:") { return nil }
        return value
    }

    private static func displayString(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count < 180 else {
            return nil
        }
        return value
    }
}
