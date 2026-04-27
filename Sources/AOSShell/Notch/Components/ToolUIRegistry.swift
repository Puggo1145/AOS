import Foundation
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

/// Rendering rules for one tool's inline row + expanded panel.
public struct ToolUIPresenter: Sendable {
    /// Short label shown next to "using" / "used" in the row header. Receives
    /// the call's `args` so a tool can specialize per-invocation
    /// (e.g. `read /etc/hosts` instead of just `read`). Default presenter
    /// returns the tool's name unchanged.
    public let label: @Sendable (JSONValue) -> String

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

    public init(
        label: @escaping @Sendable (JSONValue) -> String,
        callingBody: @escaping @Sendable (JSONValue) -> String?,
        resultBody: @escaping @Sendable (_ args: JSONValue, _ outputText: String, _ isError: Bool) -> String,
        icon: String
    ) {
        self.label = label
        self.callingBody = callingBody
        self.resultBody = resultBody
        self.icon = icon
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
    }

    // MARK: - Built-in presenters

    private static func bashPresenter() -> ToolUIPresenter {
        ToolUIPresenter(
            // The header just says "bash" — the command itself is the row's
            // payload, not its title. Putting the command in the header would
            // crowd the closed bar and make long commands wrap behind the
            // chevron, which is exactly the noise the registry exists to avoid.
            label: { _ in "bash" },
            // For `.calling` we read the validated `args.command` straight
            // off the wire. JSON shape mirrors `agent/tools/bash.ts`'s schema:
            // `{ command: string, timeout?: number }`. If the shape ever
            // drifts we return nil and the view falls back to "running…" —
            // safer than rendering a malformed JSON dump in the open panel.
            callingBody: { args in
                guard case let .object(obj) = args,
                      case let .string(command) = obj["command"]
                else { return nil }
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
            icon: "terminal"
        )
    }

    private static func fallback(toolName: String) -> ToolUIPresenter {
        ToolUIPresenter(
            label: { _ in toolName },
            // Unknown tool: don't try to guess which arg key carries the
            // user-facing payload. The view will show a generic "running…"
            // until the result arrives.
            callingBody: { _ in nil },
            resultBody: { _, output, _ in output },
            icon: "wrench.and.screwdriver"
        )
    }
}
