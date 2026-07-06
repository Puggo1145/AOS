import SwiftUI

// MARK: - Tray composition + command palette

extension NotchViewModel {
    /// Wire the built-in tray sources. Each closure captures `self` weakly
    /// so the viewmodel can be torn down without the closures keeping it
    /// alive through the registered array. Order here is display order:
    /// action-bearing system notices first, then live agent status rows.
    func installBuiltinTraySources() {
        tray.registerTraySource { [weak self] in
            guard let self else { return [] }
            return self.systemNoticeItems()
        }
        tray.registerTraySource { [weak self] in
            guard let self else { return [] }
            return self.compactLifecycleItems()
        }
        tray.registerTraySource { [weak self] in
            guard let self else { return [] }
            return self.todoProgressItems()
        }
    }

    /// Action-required system rows: permissions, provider readiness, and
    /// recovered config corruption. Dismissal is still handled by the common
    /// tray filter in `trayItems`.
    func systemNoticeItems() -> [TrayItem] {
        var out: [TrayItem] = []
        if !permissionsService.allGranted {
            out.append(TrayItem(
                id: BuiltinTrayItemID.missingPermission,
                icon: "exclamationmark.shield.fill",
                tint: .orange,
                message: missingPermissionMessage,
                trailing: .action("Open Settings"),
                onTap: { [weak self] in self?.showSettings = true }
            ))
        }
        if !providerService.hasReadyProvider {
            out.append(TrayItem(
                id: BuiltinTrayItemID.missingProvider,
                icon: "questionmark.circle.fill",
                tint: .yellow,
                message: "No model configured",
                trailing: .action("Open Settings"),
                onTap: { [weak self] in self?.showSettings = true }
            ))
        }
        if configService.recoveredFromCorruption {
            out.append(TrayItem(
                id: BuiltinTrayItemID.configCorruption,
                icon: "exclamationmark.triangle.fill",
                tint: .yellow,
                message: "Settings file was corrupt and has been reset.",
                trailing: nil,
                onTap: nil
            ))
        }
        return out
    }

    /// Context compact lifecycle row. Running compaction is live state and
    /// cannot be dismissed; the completed notification is dismissable and is
    /// also cleared from the mirror when the next user turn starts.
    func compactLifecycleItems() -> [TrayItem] {
        if let running = agentService.compactEvents.last(where: { $0.status == .running }) {
            return [TrayItem(
                id: BuiltinTrayItemID.compactPrefix + running.id,
                icon: "arrow.triangle.2.circlepath",
                tint: .white.opacity(0.85),
                message: "Compacting context",
                trailing: nil,
                dismissable: false,
                onTap: nil,
                shimmer: true
            )]
        }

        guard let done = agentService.compactEvents.last(where: { $0.status == .done }) else {
            return []
        }
        return [TrayItem(
            id: BuiltinTrayItemID.compactPrefix + done.id,
            icon: "checkmark.circle.fill",
            tint: .green.opacity(0.9),
            message: "Context compacted",
            trailing: nil,
            dismissable: true,
            onTap: nil
        )]
    }

    /// Slash-command palette rows. Built directly because `trayItems`
    /// short-circuits to these while the palette is active.
    func commandPaletteItems() -> [TrayItem] {
        let currentCommands = SlashCommandRegistry.commands(agentService: agentService)
        let currentCommandIds = Set(currentCommands.map(\.id))
        let matches = commandPalette.matches
            .filter { currentCommandIds.contains($0.id) }
            .prefix(5)
        if matches.isEmpty {
            return [TrayItem(
                id: BuiltinTrayItemID.commandPrefix + "_empty",
                icon: "questionmark.circle",
                tint: .white.opacity(0.5),
                message: "No matching commands",
                trailing: nil,
                dismissable: false,
                onTap: nil,
                highlighted: false
            )]
        }
        let selectedId = commandPalette.selectedCommand?.id
        return matches.map { cmd in
            TrayItem(
                id: BuiltinTrayItemID.commandPrefix + cmd.id,
                icon: "slash.circle",
                tint: .white.opacity(0.85),
                message: "/\(cmd.name) - \(cmd.description)",
                trailing: nil,
                dismissable: false,
                onTap: { [weak self] in
                    guard let self else { return }
                    self.composerInputModel.clear()
                    self.commandPalette.deactivate()
                    Task { await cmd.execute() }
                },
                highlighted: cmd.id == selectedId
            )
        }
    }

    /// Recompute the slash-command palette state from the current chip input
    /// contents. Called by the composer on every relevant input change.
    public func refreshCommandPalette() {
        commandPalette.update(
            text: composerInputModel.displayText,
            attachmentCount: composerInputModel.attachmentCount,
            commands: SlashCommandRegistry.commands(agentService: agentService)
        )
    }

    /// Execute the currently-highlighted command. Returns true when a command
    /// actually ran so the caller can suppress regular prompt submission.
    public func executeHighlightedCommand() -> Bool {
        guard let cmd = commandPalette.selectedCommand else { return false }
        composerInputModel.clear()
        commandPalette.deactivate()
        Task { await cmd.execute() }
        return true
    }

    /// TodoWrite live row. Surfaces only when the plan has an active
    /// in-progress step.
    func todoProgressItems() -> [TrayItem] {
        let todos = agentService.todos
        guard let inProgress = todos.first(where: { $0.status == .inProgress }) else {
            return []
        }
        let done = todos.filter { $0.status == .completed }.count
        return [TrayItem(
            id: BuiltinTrayItemID.todoProgress,
            icon: "checklist",
            tint: .white.opacity(0.85),
            message: inProgress.text,
            trailing: .badge("\(done)/\(todos.count)"),
            dismissable: false,
            onTap: nil
        )]
    }
}
