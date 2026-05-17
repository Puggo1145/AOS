import SwiftUI

// MARK: - SlashCommand
//
// Slash-commands are user-facing shortcuts the live composer surfaces
// when the user types `/` at the start of the input. Each command has a
// short identifier (the slash word — `/compact`, hypothetical
// `/clear`...), a one-line user-facing description, and an `execute`
// closure invoked by the drawer when the user picks it (Enter key on
// the highlighted match, or click).
//
// The registry is a simple in-memory list, ordered for display — the
// first match for any given prefix becomes the default-selected row, so
// listing order matters. We keep this list small (≤ a handful) on
// purpose: slash commands are top-level Shell affordances, not a
// scripting surface.

@MainActor
public struct SlashCommand: Identifiable, Sendable {
    public let id: String
    /// Slash word without the leading `/` (e.g. "compact"). Lowercase.
    public let name: String
    public let description: String
    public let execute: @MainActor () async -> Void

    public init(
        id: String,
        name: String,
        description: String,
        execute: @escaping @MainActor () async -> Void
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.execute = execute
    }
}

@MainActor
public enum SlashCommandRegistry {
    /// Build the live command list for the current Shell wiring. Called
    /// per ComposerCard render so each command's closure captures the
    /// agent service the user is currently aimed at — switching sessions
    /// or restarting the sidecar gives every closure a fresh handle on
    /// next composer render.
    public static func commands(agentService: AgentService) -> [SlashCommand] {
        [
            SlashCommand(
                id: "compact",
                name: "compact",
                description: "Summarize prior history to free up context",
                execute: { await agentService.compactSession() }
            ),
        ]
    }

    /// Prefix-match against the slash word (case-insensitive). The
    /// matcher is case-insensitive to be forgiving with `/Compact`,
    /// `/COMPACT`, etc.; commands themselves are stored lowercase.
    /// Returns matches in registry order — the first is the
    /// default-selected row in the drawer.
    public static func match(prefix: String, in commands: [SlashCommand]) -> [SlashCommand] {
        let lower = prefix.lowercased()
        if lower.isEmpty { return commands }
        return commands.filter { $0.name.hasPrefix(lower) }
    }
}
