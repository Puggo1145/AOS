import Foundation
import AppKit
import AOSRPCSchema

// MARK: - ToolUIRegistry
//
// Per-tool presentation rules for inline tool-call rows in the notch panel.
// The wire (`ui.toolCall`) carries opaque JSON for `args` and a one-shot
// `outputText` for the result; both are general enough to support every tool
// the sidecar might ever ship. The renderer cannot show the raw JSON without
// turning every tool row into developer-facing noise — so each tool that wants
// a humane UI registers a `ToolUIPresenter` here.
//
// Adding a new tool's UI is a one-file change: extend `register(...)` calls
// in `registerBuiltins()` (or call `register(name:presenter:)` from another
// site at startup). Tools without a registered presenter fall back to a
// generic "tool name + opaque output" view — they still render correctly, just
// without the per-tool affordance (e.g. bash's "show the command verbatim").

/// Summary grammar for a family of tool calls collapsed into one row.
public struct ToolUISummaryUnit: Sendable {
    /// Stable grouping key. Related tools can share a key so the collapsed row
    /// says "clicked 3 times" across both element and coordinate click tools.
    public let key: String
    public let label: @Sendable (_ count: Int) -> String

    public init(key: String, label: @escaping @Sendable (_ count: Int) -> String) {
        self.key = key
        self.label = label
    }
}

/// Rendering rules for one tool's inline row + expanded panel.
public struct ToolUIPresenter: Sendable {
    /// Full row-header text for one call. Receives the call's `args` plus
    /// `isCalling` (true while in `.calling`, false after `.result`) so the
    /// presenter owns its own grammar — file tools say `reading hosts` /
    /// `read hosts`, while opaque tools like `bash` keep the generic
    /// `using bash` / `used bash`. The view does NOT prefix a verb, so
    /// the closure must return the full string it wants displayed.
    public let label: @Sendable (_ args: JSONValue, _ isCalling: Bool) -> String

    /// Body shown when expanded while the call is still in `.calling`. For
    /// `bash` this is the command string the model is executing. Returning
    /// `nil` means "no preview available yet" — the view falls back to a
    /// generic `running…` placeholder rather than showing raw JSON.
    public let callingBody: @Sendable (JSONValue) -> String?

    /// Body shown when expanded after `.result` arrives. Receives the call's
    /// `args` (so the result view can echo the originating command — `bash`
    /// uses this for the `> <command>` header above the output) plus the
    /// wire `outputText` and `isError` flag. The presenter is free to add
    /// a header, truncate, or transform; the default is "show outputText
    /// verbatim", which already matches the wire's intent.
    public let resultBody: @Sendable (_ args: JSONValue, _ outputText: String, _ isError: Bool) -> String

    /// SF Symbol name for the row's leading icon. Tools should pick a glyph
    /// that telegraphs the operation at a glance: `terminal` for shell-likes,
    /// `doc.text` for file reads, etc.
    public let icon: String

    /// Grammar for collapsed multi-tool summaries. Kept on the presenter so
    /// adding a tool-specific UI also adds its collapsed transcript wording.
    public let summaryUnit: ToolUISummaryUnit

    public init(
        label: @escaping @Sendable (_ args: JSONValue, _ isCalling: Bool) -> String,
        callingBody: @escaping @Sendable (JSONValue) -> String?,
        resultBody: @escaping @Sendable (_ args: JSONValue, _ outputText: String, _ isError: Bool) -> String,
        icon: String,
        summaryUnit: ToolUISummaryUnit
    ) {
        self.label = label
        self.callingBody = callingBody
        self.resultBody = resultBody
        self.icon = icon
        self.summaryUnit = summaryUnit
    }
}

/// Process-wide tool-UI registry. Single global instance — tool registration
/// is a startup-time concern; mutating after first read is allowed (the row
/// view re-resolves on every render) but not expected. No locking because
/// every read/write happens on `@MainActor` (only the SwiftUI render thread
/// touches it in production; `registerBuiltins()` is invoked from app boot
/// before any view body runs).
@MainActor
public enum ToolUIRegistry {
    private static var presenters: [String: ToolUIPresenter] = [:]
    private static var didRegisterBuiltins = false

    /// Register or replace the presenter for `toolName`. Idempotent on the
    /// `(name, presenter)` pair — last write wins so tests can override
    /// built-ins without first calling an `unregister` step.
    public static func register(name: String, presenter: ToolUIPresenter) {
        presenters[name] = presenter
    }

    /// Look up the presenter for a tool. Falls back to a generic presenter
    /// rather than throwing — an unknown tool still renders, just without
    /// a tool-specific affordance.
    public static func presenter(for toolName: String) -> ToolUIPresenter {
        ensureBuiltins()
        return presenters[toolName] ?? Self.fallback(toolName: toolName)
    }

    /// Idempotently install built-in presenters on first lookup. Doing this
    /// lazily (rather than at app start) means new tools shipped by the
    /// sidecar can be handled even if the Shell hasn't been recompiled — the
    /// fallback presenter is already correct for any unknown tool.
    private static func ensureBuiltins() {
        guard !didRegisterBuiltins else { return }
        didRegisterBuiltins = true
        registerBuiltins()
    }

    private static func registerBuiltins() {
        register(name: "bash", presenter: bashPresenter())
        register(name: "read", presenter: readPresenter())
        register(name: "write", presenter: writePresenter())
        register(name: "update", presenter: updatePresenter())
        register(name: "todo_write", presenter: todoWritePresenter())
        register(name: "list_apps", presenter: computerListAppsPresenter())
        register(name: "list_windows", presenter: computerListWindowsPresenter())
        register(name: "get_app_state", presenter: computerGetAppStatePresenter())
        register(name: "start_app_session", presenter: computerStartSessionPresenter())
        register(name: "stop_app_session", presenter: computerStopSessionPresenter())
        register(name: "use_mouse", presenter: computerMousePresenter())
        register(name: "use_keyboard", presenter: computerKeyboardPresenter())
        register(name: "perform_AX_action", presenter: computerAXPresenter())
    }

    // MARK: - Built-in presenters

    private static func bashPresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            // Bash is opaque — we don't have a single English verb that
            // captures "run an arbitrary shell pipeline" (`running` is wrong
            // when the command is a one-shot `cat`, etc.). Stick with the
            // generic `using bash` / `used bash` framing; the command itself
            // lives in the expanded body, not the header.
            label: { _, isCalling in isCalling ? "using bash" : "used bash" },
            // For `.calling` we read the validated `args.command` straight
            // off the wire. JSON shape mirrors `agent/tools/bash.ts`'s schema:
            // `{ command: string, timeout?: number }`. If the shape ever
            // drifts, surface that as an explicit malformed-tool message
            // instead of falling through to a generic `running…` placeholder.
            callingBody: { args in
                guard case let .object(obj) = args,
                      case let .string(command) = obj["command"]
                else { return "Malformed bash args: missing command" }
                return command
            },
            // After the call lands we want the user to see what the model
            // actually ran *and* what came back, in shell-transcript order:
            //   > <command>
            //
            //   <output>
            // The leading `> ` makes the command unambiguous against the
            // output below even when the output itself contains lines that
            // look prompt-like. Output is rendered verbatim — the bash tool
            // already truncates in the sidecar (200-line / 50KB tail cap).
            // If args ever drifts away from the `{ command: string }` shape
            // we fall back to the bare output rather than fabricating a
            // header from a malformed payload.
            resultBody: { args, output, _ in
                guard case let .object(obj) = args,
                      case let .string(command) = obj["command"]
                else { return output }
                return "> \(command)\n\n\(output)"
            },
            icon: "terminal",
            summaryUnit: ToolUISummaryUnit(key: "bash") { count in
                count == 1 ? "used bash" : "used \(count) bash"
            }
        )
    }

    // File-tool presenters mirror `agent/tools/{read,write,update}.ts`'s
    // wire shape: `args.path` is always the user-facing identifier of the
    // call (which file the model is touching), so the row label echoes the
    // file's basename — that's what the user scans against their mental
    // model of "what is the agent doing right now". Full paths are visible
    // in the expanded body so context isn't lost.

    private static func readPresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { args, isCalling in
                fileToolLabel(verb: isCalling ? "reading" : "read", args: args)
            },
            // Pre-result body shows the path so the user knows which file
            // is in flight even before output arrives.
            callingBody: { args in
                fileToolPath(args) ?? malformedToolArgs("read", missing: "path")
            },
            // Result body keeps the path header above the contents — the
            // tool's text payload is already the file body verbatim.
            resultBody: { args, output, _ in
                guard let path = fileToolPath(args) else { return output }
                return "\(path)\n\n\(output)"
            },
            icon: "doc.text",
            summaryUnit: ToolUISummaryUnit(key: "read") { count in
                count == 1 ? "read 1 file" : "read \(count) files"
            }
        )
    }

    private static func writePresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { args, isCalling in
                fileToolLabel(verb: isCalling ? "writing" : "wrote", args: args)
            },
            // While writing we have no preview of the new content here (it's
            // on the wire's `args.content` but rendering the full new file
            // would dominate the panel). Show the target path only.
            callingBody: { args in
                fileToolPath(args) ?? malformedToolArgs("write", missing: "path")
            },
            // Result already says "Created/Overwrote <path> (N bytes)" so we
            // surface it as-is — adding a path header would be redundant.
            resultBody: { _, output, _ in output },
            icon: "square.and.pencil",
            summaryUnit: ToolUISummaryUnit(key: "write") { count in
                count == 1 ? "wrote 1 file" : "wrote \(count) files"
            }
        )
    }

    private static func updatePresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { args, isCalling in
                fileToolLabel(verb: isCalling ? "updating" : "updated", args: args)
            },
            // Show the substring being replaced while the call is running.
            // The `old → new` block tracks the user's mental model of "edit
            // this into that" without us having to reconstruct a diff.
            callingBody: { args in
                guard case let .object(obj) = args,
                      case let .string(oldText) = obj["old_text"],
                      case let .string(newText) = obj["new_text"]
                else { return malformedToolArgs("update", missing: "old_text/new_text") }
                let path = fileToolPath(args) ?? ""
                let header = path.isEmpty ? "" : "\(path)\n\n"
                return "\(header)- \(oldText)\n+ \(newText)"
            },
            // Result text already names the file and the byte delta. If the
            // call errored, the wire's outputText is the ToolUserError
            // message — which mentions the file too. Either way, show
            // verbatim.
            resultBody: { _, output, _ in output },
            icon: "pencil.and.outline",
            summaryUnit: ToolUISummaryUnit(key: "update") { count in
                count == 1 ? "updated 1 file" : "updated \(count) files"
            }
        )
    }

    /// `todo_write` row treatment. Whole-list semantics: each call replaces
    /// the plan, so a single row that says "updating todos" / "updated todos"
    /// reads correctly. The expanded body re-renders the list with status
    /// markers so the user sees what the model wrote without expanding the
    /// big TodoListView elsewhere in the panel — the inline row is the
    /// audit trail of *when* the model planned/changed; the panel above the
    /// composer is the live current state.
    private static func todoWritePresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { _, isCalling in isCalling ? "updating todos" : "updated todos" },
            // Pre-result we have the items the model is writing; render
            // them verbatim so the row is informative even before the
            // sidecar's render lands as `outputText`.
            callingBody: { args in
                renderTodoArgs(args) ?? malformedToolArgs("todo_write", missing: "items")
            },
            // Post-result the wire's `outputText` is the manager's render
            // (the `[ ] / [>] / [x] #id: text` listing). Show as-is — it
            // matches what the user sees in the live panel.
            resultBody: { _, output, _ in output },
            icon: "checklist",
            summaryUnit: ToolUISummaryUnit(key: "todo_write") { count in
                count == 1 ? "updated todos" : "updated todos \(count) times"
            }
        )
    }

    private static func computerListAppsPresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { args, isCalling in
                let mode = computerString(args, "mode")
                let suffix = mode.map { " (\($0))" } ?? ""
                return "\(isCalling ? "listing" : "listed") apps\(suffix)"
            },
            callingBody: { args in computerKeyValueBody(args, keys: ["mode"]) },
            resultBody: { _, output, _ in output },
            icon: "macwindow.on.rectangle",
            summaryUnit: computerSummaryUnit
        )
    }

    private static func computerListWindowsPresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { _, isCalling in
                "\(isCalling ? "listing" : "listed") windows"
            },
            callingBody: { _ in "running app" },
            resultBody: { _, output, _ in output },
            icon: "rectangle.stack",
            summaryUnit: computerSummaryUnit
        )
    }

    private static func computerGetAppStatePresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { _, isCalling in
                "\(isCalling ? "reading" : "read") app state"
            },
            callingBody: { args in computerKeyValueBody(args, keys: ["captureMode"]) },
            resultBody: { _, output, _ in output },
            icon: "eye",
            summaryUnit: computerSummaryUnit
        )
    }

    private static func computerStartSessionPresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { _, isCalling in
                "\(isCalling ? "starting" : "started") app session"
            },
            callingBody: { _ in "target app" },
            resultBody: { _, output, _ in output },
            icon: "play.rectangle",
            summaryUnit: computerSummaryUnit
        )
    }

    private static func computerStopSessionPresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { _, isCalling in isCalling ? "stopping app session" : "stopped app session" },
            callingBody: { _ in "active app session" },
            resultBody: { _, output, _ in output },
            icon: "stop.rectangle",
            summaryUnit: computerSummaryUnit
        )
    }

    private static func computerMousePresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { args, isCalling in computerMouseLabel(args, isCalling: isCalling) },
            callingBody: { args in
                computerMouseBody(args) ?? malformedToolArgs("use_mouse", missing: "event")
            },
            resultBody: { args, output, _ in computerResultWithArgs(args, output: output) },
            icon: "cursorarrow.click",
            summaryUnit: computerSummaryUnit
        )
    }

    private static func computerKeyboardPresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { args, isCalling in computerKeyboardLabel(args, isCalling: isCalling) },
            callingBody: { args in
                computerKeyboardBody(args) ?? malformedToolArgs("use_keyboard", missing: "event")
            },
            resultBody: { args, output, _ in computerResultWithArgs(args, output: output) },
            icon: "keyboard",
            summaryUnit: computerSummaryUnit
        )
    }

    private static func computerAXPresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            label: { args, isCalling in computerAXLabel(args, isCalling: isCalling) },
            callingBody: { args in
                computerAXBody(args) ?? malformedToolArgs("perform_AX_action", missing: "event")
            },
            resultBody: { args, output, _ in computerResultWithArgs(args, output: output) },
            icon: "accessibility",
            summaryUnit: computerSummaryUnit
        )
    }

    private static func fallback(toolName: String) -> ToolUIPresenter {
        ToolUIPresenter(
            // Unknown tools fall back to the generic `using/used` framing —
            // we have no idea what verb fits.
            label: { _, isCalling in "\(isCalling ? "using" : "used") \(toolName)" },
            // Unknown tool: don't try to guess which arg key carries the
            // user-facing payload. The view will show a generic "running…"
            // until the result arrives.
            callingBody: { _ in nil },
            resultBody: { _, output, _ in output },
            icon: "wrench.and.screwdriver",
            summaryUnit: ToolUISummaryUnit(key: toolName) { count in
                count == 1 ? "used \(toolName)" : "used \(count) \(toolName)"
            }
        )
    }
}
