import SwiftUI
import AppKit
import AOSOSSenseKit
import AOSRPCSchema

// MARK: - ComposerCard
//
// Per the post-redesign live composer (see `docs/designs/os-sense.md`
// §"Notch UI 渲染契约" + §"ScreenMirror" + §"Clipboard capture"). Stack,
// top → bottom:
//
//   1. Context chip row: app chip + per-app screenshot toggle, behavior
//      chips. Pasted clipboards are NOT here — they live inline inside
//      the prompt input as rich-text attachments.
//   2. Prompt input — a `ChipInputView` (NSTextView under the hood). The
//      user types text, and Cmd+V inserts a chip attachment at the
//      caret. Backspace deletes a chip atomically; the chip's X button
//      deletes it on click. The whole field — text + chips interleaved
//      — is the prompt.
//   3. Function row: model + effort menus on the leading edge, the
//      circular send button on the trailing edge.
//
// State that lives here:
//
//   - `inputModel`: an `@Observable` bridge to the NSTextView's storage.
//     Exposes `displayText` (typed text only, drives the placeholder) and
//     `snapshot()` (walks storage → (prompt-with-markers, clipboards)).
//   - `policyStore`: per-app "always capture screenshot" toggle. If the
//     toggle is on for the current bundleId, every submit attaches a
//     fresh window snapshot.

struct ComposerCard: View {
    let senseStore: SenseStore
    let agentService: AgentService
    let configService: ConfigService
    let policyStore: VisualCapturePolicyStore
    /// Owned by `NotchViewModel` so the typed text + chips persist
    /// across notch close/reopen cycles. The composer view is recreated
    /// on every open (it's mounted under a `status == .opened` gate);
    /// holding this in `@State` would wipe the input every time.
    let inputModel: ChipInputModel
    @Binding var inputFocused: Bool

    @State private var deselectedBehaviorKeys: Set<String> = []

    /// Disable the send button when the typed prompt is effectively empty.
    /// Chips alone don't count — the LLM contract is "the user actually
    /// said something", and a bag of pastes with no question is a bug
    /// shape, not a turn.
    private var canSubmit: Bool {
        !inputModel.isTextEmpty && !isAgentBusy
    }

    /// The agent is mid-turn — either streaming tokens (`working`) or
    /// waiting on a tool round (`waiting`). In this state the trailing
    /// circular button flips to a stop affordance and clicking it cancels
    /// the in-flight turn instead of submitting a new prompt. Send via
    /// Enter is also gated off so a stray Return keystroke can't enqueue
    /// behind a running turn.
    private var isAgentBusy: Bool {
        switch agentService.status {
        case .working, .waiting: return true
        case .idle, .listening, .done, .error: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ContextChipsView(
                senseStore: senseStore,
                policyStore: policyStore,
                screenshotToggle: screenshotToggleState,
                deselectedBehaviorKeys: $deselectedBehaviorKeys
            )
            inputRow
            functionRow
        }
        .onChange(of: senseStore.context.app?.bundleId) { _, _ in
            // App switch invalidates the in-flight prompt — both typed
            // text and chips were assembled with the previous app in
            // mind. Reset the field so a turn aimed at the new app can't
            // accidentally inherit the previous app's pastes.
            inputModel.clear()
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        ZStack(alignment: .topLeading) {
            // Custom-overlay placeholder. Drawing it ourselves keeps the
            // baseline pinned across focus transitions; AppKit's
            // placeholder shifts ~1pt when the field editor swaps in,
            // which reads as a flicker.
            Text("What can I do for you?")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(inputModel.isStorageEmpty ? 0.35 : 0))
                .padding(.vertical, 4)
                .allowsHitTesting(false)
            ChipInputView(
                model: inputModel,
                font: NSFont.systemFont(ofSize: 15),
                textColor: .white,
                onSubmit: { submit() },
                onFocusChange: { inputFocused = $0 }
            )
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityLabel(Text("Prompt input"))
    }

    // MARK: - Function row

    private var functionRow: some View {
        HStack(spacing: 8) {
            modelMenu
            if !(currentModel?.supportedEfforts.isEmpty ?? true) {
                effortMenu
            }
            Spacer(minLength: 8)
            if let usage = agentService.latestUsage {
                ContextUsageRing(usage: usage)
            }
            sendButton
        }
    }

    @ViewBuilder
    private var modelMenu: some View {
        // Composer-side picker is intentionally scoped to the active
        // provider's models — provider switching lives in Settings.
        // Listing every provider's models here let the user pick a model
        // belonging to a provider they hadn't authed.
        Menu {
            if let provider = currentProvider {
                ForEach(provider.models) { model in
                    Button {
                        Task {
                            await configService.selectModel(
                                providerId: provider.id,
                                modelId: model.id
                            )
                        }
                    } label: {
                        if currentSelection?.modelId == model.id {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            }
        } label: {
            Text(currentModel?.name ?? "—")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Model"))
    }

    @ViewBuilder
    private var effortMenu: some View {
        // Render exactly the effort levels the sidecar reported as
        // supported for this model. Each row carries its own
        // `value`/`label` — labels come straight from the catalog, no
        // local mapping table.
        let efforts = currentModel?.supportedEfforts ?? []
        let active = configService.effort(for: currentModel)
        Menu {
            ForEach(efforts) { effort in
                Button {
                    Task { await configService.selectEffort(effort) }
                } label: {
                    if active == effort {
                        Label(effort.label, systemImage: "checkmark")
                    } else {
                        Text(effort.label)
                    }
                }
            }
        } label: {
            Text(active?.label ?? "")
                .font(.system(size: 12, weight: .regular))
                .notchForeground(.tertiary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Reasoning effort"))
    }

    @ViewBuilder
    private var sendButton: some View {
        if isAgentBusy {
            stopButton
        } else {
            submitButton
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(canSubmit ? Color.black : Color.white.opacity(0.4))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(canSubmit ? Color.white : Color.white.opacity(0.15))
                )
                // Subtle "ready to fire" cue — the disc fades in/out as the
                // composer transitions between disabled/enabled. Reduce
                // Motion users get the snap because the style itself respects
                // the environment.
                .animation(.notchChrome, value: canSubmit)
        }
        .buttonStyle(.notchPressable)
        .disabled(!canSubmit)
        .accessibilityLabel(Text("Send prompt"))
    }

    private var stopButton: some View {
        Button(action: cancel) {
            // Filled square inside a white disc — the standard "stop a
            // running task" affordance. Black-on-white matches the active
            // submit button so the trailing slot doesn't visually shift
            // weight when the agent flips between idle and busy.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.black)
                .frame(width: 9, height: 9)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white))
        }
        .buttonStyle(.notchPressable)
        .accessibilityLabel(Text("Stop agent"))
    }

    private func cancel() {
        Task { await agentService.cancel() }
    }

    // MARK: - Selection helpers

    private var currentSelection: ConfigSelection? {
        configService.effectiveSelection
    }

    private var currentModel: ConfigModelEntry? {
        guard let sel = currentSelection else { return nil }
        return configService.model(providerId: sel.providerId, modelId: sel.modelId)
    }

    private var currentProvider: ConfigProviderEntry? {
        guard let sel = currentSelection else { return nil }
        return configService.provider(id: sel.providerId)
    }

    /// Derived screenshot-toggle state for the chip row. Resolves the
    /// three gates (model vision capability, OS screen-recording
    /// permission, per-bundle pick) into a single closed enum so
    /// ContextChipsView doesn't have to know about LLM models. Order
    /// matters: model capability is the outermost gate (no point asking
    /// for permission for bytes the agent can't read), then permission,
    /// then the user's per-app pick.
    private var screenshotToggleState: ScreenshotToggleState {
        guard currentModel?.supportsVision == true else { return .unsupportedByModel }
        guard senseStore.visualSnapshotAvailable else { return .needsScreenRecordingPermission }
        let on = senseStore.context.app.map { policyStore.isAlwaysCapture(bundleId: $0.bundleId) } ?? false
        return .operable(on: on)
    }

    /// `true` iff the current submit should attach a freshly captured
    /// frame. Mirrors `screenshotToggleState` so the UI's `eye.fill`
    /// glyph and the actual wire payload can never disagree.
    private var shouldAttachCapturedFrame: Bool {
        if case .operable(let on) = screenshotToggleState { return on }
        return false
    }

    private func submit() {
        // Re-check the same gate the send button uses. Return is also a
        // submit path, and `snapshot.prompt` includes `[[clipboard:N]]`
        // markers — checking it would let a chips-only field submit a
        // bag of pastes with no question. Also block while a turn is in
        // flight so a stray Enter keystroke can't enqueue behind the
        // running agent (the button itself flips to stop in that state).
        guard !inputModel.isTextEmpty, !isAgentBusy else { return }
        let snapshot = inputModel.snapshot()

        let selection = CitedSelection(deselectedBehaviors: deselectedBehaviorKeys)

        // Per-app capture policy decides whether to pull a snapshot.
        // No more per-turn visual chip — the toggle next to the app chip
        // is the single source of truth.
        // Capture-cost optimization based on the catalog's `supportsVision`
        // flag projected via `config.get`. This is a *prediction*, not a
        // protocol contract — the sidecar's `transformMessages` is the
        // authoritative vision-downgrade path and remains correct even if
        // this gate goes stale. The reason we still pay for the prediction:
        // the capture itself is not free (ScreenCaptureKit syscall + PNG
        // encode + 400KB payload guard), and the bytes would just be
        // swapped for a `[image omitted]` placeholder downstream. If
        // sidecar ever introduces image→OCR fallback or similar, this
        // line goes silently stale; the chip's `eye.slash` glyph stays
        // correct via the same projection, which is the user-facing signal.
        // Routing both the chip and this decision through
        // `screenshotToggleState` keeps them lockstep — the UI can never
        // promise an attachment that the wire then drops.
        let shouldCaptureVisual = shouldAttachCapturedFrame

        let snapshotCtx = senseStore.context
        let promptForTurn = snapshot.prompt
        let clipboardsForTurn = snapshot.clipboards
        inputModel.clear()
        // Behavior selections persist within the session (see Notch UI
        // design): we don't reset `deselectedBehaviorKeys` here.
        Task {
            let visual: VisualMirror? = shouldCaptureVisual
                ? await senseStore.captureVisualSnapshot()
                : nil
            let cited = CitedContextProjection.project(
                from: snapshotCtx,
                selection: selection,
                visual: visual,
                clipboards: clipboardsForTurn
            )
            await agentService.submit(prompt: promptForTurn, citedContext: cited)
        }
    }
}
