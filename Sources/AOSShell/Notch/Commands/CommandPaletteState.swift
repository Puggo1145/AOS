import SwiftUI

// MARK: - CommandPaletteState
//
// View-local state machine for the slash-command palette that lives
// above the live composer. Owned by `ComposerCard`; each text change
// (`displayText`) refreshes `prefix` / `matches` / `selectedIndex`.
//
// Activation gate (deliberately strict to avoid false positives):
//
//   - `displayText` starts with exactly one `/`
//   - the rest of the typed text is a contiguous slug (lowercase
//     letters / `-`) — no spaces, no second slash
//   - the chip-input model carries no attachments (a `/` next to a
//     pasted file isn't a command)
//
// First match is always selected by default; up/down arrow navigates;
// Enter executes; Escape (or violating the gate) deactivates.

@MainActor
@Observable
public final class CommandPaletteState {
    /// True iff the gate above passes. The composer reads this to
    /// decide whether to show the drawer and whether to route Enter
    /// into the palette vs. into the agent submit.
    public private(set) var isActive: Bool = false
    /// Slash word the user has typed so far, without the leading `/`.
    /// Empty when the input is just `/` — that case shows every command.
    public private(set) var prefix: String = ""
    /// Filtered command list (registry order, prefix-matched).
    public private(set) var matches: [SlashCommand] = []
    /// Index into `matches`. Clamped to the valid range; `nil` when
    /// matches is empty.
    public private(set) var selectedIndex: Int? = nil

    /// Recompute the palette state for the current composer text. The
    /// caller passes both the typed text and the chip-attachment count
    /// (zero is required for activation).
    public func update(
        text: String,
        attachmentCount: Int,
        commands: [SlashCommand]
    ) {
        guard attachmentCount == 0,
              text.first == "/",
              isCommandSlug(String(text.dropFirst())) else {
            deactivate()
            return
        }
        let prefix = String(text.dropFirst())
        let matches = SlashCommandRegistry.match(prefix: prefix, in: commands)
        self.isActive = true
        self.prefix = prefix
        self.matches = matches
        // Preserve the selection if the previously-selected command is
        // still in the new match list (e.g. user typed an extra char
        // that the highlighted command also satisfies). Otherwise reset
        // to the first match.
        if let prev = selectedIndex.flatMap({ idx -> SlashCommand? in
            // matches array changed; lookup by id in old matches
            // requires holding the old list. Cheap enough to recompute:
            // we only have a handful of commands.
            return idx < self.matches.count ? self.matches[idx] : nil
        }), matches.contains(where: { $0.id == prev.id }),
           let newIdx = matches.firstIndex(where: { $0.id == prev.id }) {
            self.selectedIndex = newIdx
        } else {
            self.selectedIndex = matches.isEmpty ? nil : 0
        }
    }

    public func deactivate() {
        isActive = false
        prefix = ""
        matches = []
        selectedIndex = nil
    }

    /// Cycle the highlight up or down through the visible matches.
    /// Wrap-around is intentional — the drawer is a small list and
    /// trapping at the ends adds friction without communicating
    /// anything useful.
    public func navigate(_ direction: NavigationDirection) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        let current = selectedIndex ?? 0
        switch direction {
        case .up:   selectedIndex = (current - 1 + count) % count
        case .down: selectedIndex = (current + 1) % count
        }
    }

    public enum NavigationDirection: Sendable, Equatable {
        case up
        case down
    }

    /// Currently highlighted command. `nil` only when there are no
    /// matches (e.g. user typed `/zzz`).
    public var selectedCommand: SlashCommand? {
        guard let idx = selectedIndex, idx < matches.count else { return nil }
        return matches[idx]
    }

    /// Tight slug check. Allowed characters: lowercase letters and `-`.
    /// We only allow lowercase here because `/` triggers a command and
    /// uppercase shifts feel like a typo to most users; the registry's
    /// match is case-insensitive so the inverse is fine.
    private func isCommandSlug(_ s: String) -> Bool {
        for ch in s {
            if ch.isLowercase { continue }
            if ch == "-" { continue }
            return false
        }
        return true
    }
}
