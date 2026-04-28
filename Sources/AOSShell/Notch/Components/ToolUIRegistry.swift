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

    public init(
        label: @escaping @Sendable (_ args: JSONValue, _ isCalling: Bool) -> String,
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
        register(name: "read", presenter: readPresenter())
        register(name: "write", presenter: writePresenter())
        register(name: "update", presenter: updatePresenter())
        // Computer Use family — humane labels rooted in the target app's name.
        // All operate the target in the background (no focus steal); the row
        // wording leans on that ("clicked in Slack") to make it legible to the
        // user that the agent is working OFF-screen for them.
        register(name: "computer_use_list_apps", presenter: cuListAppsPresenter())
        register(name: "computer_use_list_windows", presenter: cuListWindowsPresenter())
        register(name: "computer_use_get_app_state", presenter: cuGetAppStatePresenter())
        register(name: "computer_use_click_element", presenter: cuClickPresenter())
        register(name: "computer_use_click_at", presenter: cuClickPresenter())
        register(name: "computer_use_drag", presenter: cuDragPresenter())
        register(name: "computer_use_type_text", presenter: cuTypeTextPresenter())
        register(name: "computer_use_press_key", presenter: cuPressKeyPresenter())
        register(name: "computer_use_scroll", presenter: cuScrollPresenter())
        register(name: "computer_use_doctor", presenter: cuDoctorPresenter())
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
            callingBody: { args in fileToolPath(args) },
            // Result body keeps the path header above the contents — the
            // tool's text payload is already the file body verbatim.
            resultBody: { args, output, _ in
                guard let path = fileToolPath(args) else { return output }
                return "\(path)\n\n\(output)"
            },
            icon: "doc.text"
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
            callingBody: { args in fileToolPath(args) },
            // Result already says "Created/Overwrote <path> (N bytes)" so we
            // surface it as-is — adding a path header would be redundant.
            resultBody: { _, output, _ in output },
            icon: "square.and.pencil"
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
                else { return fileToolPath(args) }
                let path = fileToolPath(args) ?? ""
                let header = path.isEmpty ? "" : "\(path)\n\n"
                return "\(header)- \(oldText)\n+ \(newText)"
            },
            // Result text already names the file and the byte delta. If the
            // call errored, the wire's outputText is the ToolUserError
            // message — which mentions the file too. Either way, show
            // verbatim.
            resultBody: { _, output, _ in output },
            icon: "pencil.and.outline"
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
            icon: "wrench.and.screwdriver"
        )
    }
}

// MARK: - File-tool helpers
//
// These live outside the `@MainActor`-isolated `ToolUIRegistry` enum so the
// presenter closures (which are `@Sendable` and therefore must be callable
// from any isolation domain) can invoke them synchronously. They are pure
// functions over `JSONValue` — no shared state to protect — so dropping the
// actor isolation is safe.

/// Extract `args.path` for the file tools. Mirrors the JSON shape declared
/// in `agent/tools/{read,write,update}.ts`. Returns `nil` if the wire ever
/// drifts so callers can fall back gracefully rather than rendering a
/// malformed JSON dump.
private func fileToolPath(_ args: JSONValue) -> String? {
    guard case let .object(obj) = args,
          case let .string(path) = obj["path"]
    else { return nil }
    return path
}

/// Row header label for file tools: `<verb> <basename>`. The basename keeps
/// the closed bar tight while still telling the user which file is in play.
/// The expanded body still carries the full path.
private func fileToolLabel(verb: String, args: JSONValue) -> String {
    guard let path = fileToolPath(args), !path.isEmpty else { return verb }
    let base = (path as NSString).lastPathComponent
    return base.isEmpty ? verb : "\(verb) \(base)"
}

// MARK: - Computer Use helpers

/// Resolve the target app's display name from a tool call's `args.pid`.
/// `NSRunningApplication` lookup is sync + cheap; if the process has already
/// exited (rare — the agent only operates apps that are running) we return
/// `nil` so the caller can fall back to the bare verb.
@MainActor
func computerUseAppName(args: AOSRPCSchema.JSONValue) -> String? {
    let pid: pid_t?
    if case let .object(obj) = args, let raw = obj["pid"] {
        switch raw {
        case .int(let i): pid = pid_t(i)
        case .double(let d): pid = pid_t(d)
        default: pid = nil
        }
    } else {
        pid = nil
    }
    guard let pid, pid > 0,
          let app = NSRunningApplication(processIdentifier: pid)
    else { return nil }
    return app.localizedName
}

/// "<verb> in Slack" if we resolved the app, else the bare verb. The "in"
/// reads as "operating ON Slack from the background" — matches the
/// BACKGROUND_NOTE on every computer_use tool.
private func cuLabel(verb: String, args: AOSRPCSchema.JSONValue) -> String {
    if let name = MainActor.assumeIsolated({ computerUseAppName(args: args) }) {
        return "\(verb) in \(name)"
    }
    return verb
}

/// Pretty-print the args JSON for the expanded body. Computer use args are
/// small (pid + windowId + a few primitives), so a stable two-space dump is
/// readable without truncation. We don't strip pid / windowId — they are
/// useful for debugging which window the agent picked.
private func cuArgsBody(_ args: AOSRPCSchema.JSONValue) -> String {
    do {
        let data = try JSONEncoder.prettyForUI.encode(args)
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}

private extension JSONEncoder {
    /// Shared pretty encoder for tool-call arg dumps. Stable key order keeps
    /// the rendered body diff-friendly across reads.
    static let prettyForUI: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private func cuListAppsPresenter() -> ToolUIPresenter {
    ToolUIPresenter(
        label: { _, isCalling in isCalling ? "listing apps" : "listed apps" },
        callingBody: { _ in nil },
        resultBody: { _, output, _ in output },
        icon: "app.dashed"
    )
}

private func cuListWindowsPresenter() -> ToolUIPresenter {
    ToolUIPresenter(
        label: { args, isCalling in
            cuLabel(verb: isCalling ? "listing windows" : "listed windows", args: args)
        },
        callingBody: { args in cuArgsBody(args) },
        resultBody: { _, output, _ in output },
        icon: "macwindow.on.rectangle"
    )
}

private func cuGetAppStatePresenter() -> ToolUIPresenter {
    ToolUIPresenter(
        label: { args, isCalling in
            cuLabel(verb: isCalling ? "reading state" : "read state", args: args)
        },
        callingBody: { args in cuArgsBody(args) },
        resultBody: { _, output, _ in output },
        icon: "eye"
    )
}

private func cuClickPresenter() -> ToolUIPresenter {
    ToolUIPresenter(
        label: { args, isCalling in
            cuLabel(verb: isCalling ? "clicking" : "clicked", args: args)
        },
        callingBody: { args in cuArgsBody(args) },
        resultBody: { args, output, _ in
            // Result already says which degradation layer landed; prefix the
            // arg dump so the row shows what the model targeted plus the
            // outcome together.
            let body = cuArgsBody(args)
            return body.isEmpty ? output : "\(body)\n\n\(output)"
        },
        icon: "cursorarrow.click"
    )
}

private func cuDragPresenter() -> ToolUIPresenter {
    ToolUIPresenter(
        label: { args, isCalling in
            cuLabel(verb: isCalling ? "dragging" : "dragged", args: args)
        },
        callingBody: { args in cuArgsBody(args) },
        resultBody: { args, output, _ in
            let body = cuArgsBody(args)
            return body.isEmpty ? output : "\(body)\n\n\(output)"
        },
        icon: "hand.draw"
    )
}

private func cuTypeTextPresenter() -> ToolUIPresenter {
    ToolUIPresenter(
        label: { args, isCalling in
            cuLabel(verb: isCalling ? "typing" : "typed", args: args)
        },
        // While typing show the verbatim text the model is sending — that's
        // what the user wants to scan against their mental model. Cap at a
        // generous 4KB so a runaway paste doesn't dominate the panel.
        callingBody: { args in
            guard case let .object(obj) = args,
                  case let .string(text) = obj["text"]
            else { return cuArgsBody(args) }
            return text.count > 4_096 ? String(text.prefix(4_096)) + "…" : text
        },
        resultBody: { args, output, _ in
            guard case let .object(obj) = args,
                  case let .string(text) = obj["text"]
            else { return output }
            let preview = text.count > 4_096 ? String(text.prefix(4_096)) + "…" : text
            return "\"\(preview)\"\n\n\(output)"
        },
        icon: "keyboard"
    )
}

private func cuPressKeyPresenter() -> ToolUIPresenter {
    ToolUIPresenter(
        label: { args, isCalling in
            // Surface the chord (e.g. "cmd+shift+a") in the row label — these
            // are short and meaningful at a glance, unlike a free-text field.
            let chord = chordString(args: args)
            let verb = isCalling ? "pressing" : "pressed"
            let withChord = chord.isEmpty ? verb : "\(verb) \(chord)"
            return cuLabel(verb: withChord, args: args)
        },
        callingBody: { args in cuArgsBody(args) },
        resultBody: { args, output, _ in
            let body = cuArgsBody(args)
            return body.isEmpty ? output : "\(body)\n\n\(output)"
        },
        icon: "command"
    )
}

private func chordString(args: AOSRPCSchema.JSONValue) -> String {
    guard case let .object(obj) = args else { return "" }
    var parts: [String] = []
    if case let .array(mods) = obj["modifiers"] ?? .null {
        for m in mods { if case let .string(s) = m { parts.append(s) } }
    }
    if case let .string(key) = obj["key"] ?? .null { parts.append(key) }
    return parts.joined(separator: "+")
}

private func cuScrollPresenter() -> ToolUIPresenter {
    ToolUIPresenter(
        label: { args, isCalling in
            cuLabel(verb: isCalling ? "scrolling" : "scrolled", args: args)
        },
        callingBody: { args in cuArgsBody(args) },
        resultBody: { args, output, _ in
            let body = cuArgsBody(args)
            return body.isEmpty ? output : "\(body)\n\n\(output)"
        },
        icon: "scroll"
    )
}

private func cuDoctorPresenter() -> ToolUIPresenter {
    ToolUIPresenter(
        label: { _, isCalling in isCalling ? "checking computer-use" : "checked computer-use" },
        callingBody: { _ in nil },
        resultBody: { _, output, _ in output },
        icon: "stethoscope"
    )
}
