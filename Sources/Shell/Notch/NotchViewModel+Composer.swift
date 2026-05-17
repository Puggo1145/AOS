import OSSenseKit
import RPCSchema

// MARK: - Composer orchestration

extension NotchViewModel {
    public var isAgentBusy: Bool {
        switch agentService.status {
        case .working, .waiting: return true
        case .idle, .listening, .done, .error: return false
        }
    }

    public var currentSelection: ConfigSelection? {
        configService.effectiveSelection
    }

    public var currentModel: ConfigModelEntry? {
        guard let sel = currentSelection else { return nil }
        return configService.model(providerId: sel.providerId, modelId: sel.modelId)
    }

    public var currentProvider: ConfigProviderEntry? {
        guard let sel = currentSelection else { return nil }
        return configService.provider(id: sel.providerId)
    }

    var composerScreenshotToggleState: ScreenshotToggleState {
        guard currentModel?.supportsVision == true else { return .unsupportedByModel }
        guard senseStore.visualSnapshotAvailable else { return .needsScreenRecordingPermission }
        let on = senseStore.context.app.map {
            visualCapturePolicyStore.isAlwaysCapture(bundleId: $0.bundleId)
        } ?? false
        return .operable(on: on)
    }

    func canSubmitComposer(paletteActive: Bool) -> Bool {
        !composerInputModel.isTextEmpty
            && !agentService.hasQueuedPrompt
            && !paletteActive
            && composerSubmitEnabled
    }

    func selectComposerModel(providerId: String, modelId: String) async {
        await configService.selectModel(providerId: providerId, modelId: modelId)
    }

    func selectComposerEffort(_ effort: ConfigEffort) async {
        await configService.selectEffort(effort)
    }

    func cancelComposerRun() async {
        await agentService.cancel()
    }

    func submitComposer(deselectedBehaviorKeys: Set<String>) async {
        guard canSubmitComposer(paletteActive: commandPalette.isActive) else { return }
        let snapshot = composerInputModel.snapshot()
        let selection = CitedSelection(deselectedBehaviors: deselectedBehaviorKeys)
        let shouldCaptureVisual: Bool = {
            if case .operable(let on) = composerScreenshotToggleState { return on }
            return false
        }()

        let snapshotCtx = senseStore.context
        let promptForTurn = snapshot.prompt
        let clipboardsForTurn = snapshot.clipboards
        let turnId = agentService.reserveSubmitTurnId(
            prompt: promptForTurn,
            queueIfNeeded: isAgentBusy || agentService.hasRunningCompact
        )
        composerInputModel.clear()

        let visual: VisualMirror? = shouldCaptureVisual
            ? await senseStore.captureVisualSnapshot()
            : nil
        let cited = CitedContextProjection.project(
            from: snapshotCtx,
            selection: selection,
            visual: visual,
            clipboards: clipboardsForTurn
        )
        await agentService.submit(prompt: promptForTurn, citedContext: cited, turnId: turnId)
    }
}
