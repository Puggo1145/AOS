import SwiftUI
import AOSOSSenseKit
import AOSRPCSchema

// MARK: - ComposerCard
//
// Per notch-ui.md §"输入区" (revised). One bordered rounded card stacking,
// top → bottom:
//
//   1. Live context chips (frontmost app + behavior envelopes). Hidden when
//      no chips would render so the empty state is just input + function row.
//   2. The borderless TextField — the prompt the user is composing.
//   3. Function row: model menu + effort menu on the leading edge, the
//      circular send button on the trailing edge.
//
// The whole card is a single visual surface so the user reads it as the
// "this is what I'd send right now" packet. Submit goes through Return on
// the field or the trailing send button — both call the same closure.
//
// `inputFocused` mirrors first-responder state to the view-model so the
// closed-bar status emoji can flip to `:o` (listening) while composing,
// without polluting `AgentService.status`.

struct ComposerCard: View {
    let senseStore: SenseStore
    let agentService: AgentService
    let configService: ConfigService
    @Binding var inputFocused: Bool

    @State private var text: String = ""
    @State private var deselectedChipKeys: Set<String> = []
    @FocusState private var focused: Bool

    /// Disable the send button when the trimmed prompt is empty so the user
    /// can't fire an empty turn (the sidecar would 400). Keeping the button
    /// visible-but-dim (rather than hidden) prevents the input row width from
    /// shifting as the user types.
    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasChips: Bool {
        !senseStore.context.behaviors.isEmpty
            || senseStore.context.clipboard != nil
            || (senseStore.visualSnapshotAvailable && senseStore.context.behaviors.isEmpty)
            || senseStore.context.app != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasChips {
                ContextChipsView(
                    senseStore: senseStore,
                    deselectedKeys: $deselectedChipKeys
                )
            }
            inputRow
            functionRow
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        ZStack(alignment: .leading) {
            // Custom-overlay placeholder. Drawing it ourselves (instead of
            // using `TextField("…", text:)`) keeps the placeholder pinned
            // to the same baseline as typed text on every focus transition;
            // AppKit's NSTextField placeholder shifts ~1pt when the field
            // editor swaps in, which reads as a flicker.
            //
            // Always kept in the layout (opacity-toggled, not `if`-toggled)
            // so the ZStack's height stays anchored to Text's line height
            // in both states. If we removed it via `if`, the row would
            // collapse to NSTextField's slightly shorter intrinsic height
            // the moment the user types, shrinking the whole notch by ~1pt.
            Text("What can I do for you?")
                .foregroundStyle(.white.opacity(text.isEmpty ? 0.35 : 0))
                .allowsHitTesting(false)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: focused) { _, newValue in
                    inputFocused = newValue
                }
                .onSubmit { submit() }
        }
        .font(.system(size: 15))
        .foregroundStyle(.white)
        .tint(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityLabel(Text("Prompt input"))
    }

    // MARK: - Function row

    private var functionRow: some View {
        HStack(spacing: 8) {
            modelMenu
            if currentModel?.reasoning ?? false {
                effortMenu
            }
            Spacer(minLength: 8)
            sendButton
        }
    }

    @ViewBuilder
    private var modelMenu: some View {
        Menu {
            ForEach(configService.providers) { provider in
                Section(provider.name) {
                    ForEach(provider.models) { model in
                        Button {
                            Task {
                                await configService.selectModel(
                                    providerId: provider.id,
                                    modelId: model.id
                                )
                            }
                        } label: {
                            if currentSelection?.providerId == provider.id,
                               currentSelection?.modelId == model.id {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
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
        let supportsXhigh = currentModel?.supportsXhigh ?? true
        Menu {
            ForEach(ConfigEffort.allCases, id: \.self) { effort in
                if effort == .xhigh && !supportsXhigh {
                    EmptyView()
                } else {
                    Button {
                        Task { await configService.selectEffort(effort) }
                    } label: {
                        if configService.effectiveEffort == effort {
                            Label(effortDisplayName(effort), systemImage: "checkmark")
                        } else {
                            Text(effortDisplayName(effort))
                        }
                    }
                }
            }
        } label: {
            Text(effortDisplayName(configService.effectiveEffort))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Reasoning effort"))
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(canSubmit ? Color.black : Color.white.opacity(0.4))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(canSubmit ? Color.white : Color.white.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .accessibilityLabel(Text("Send prompt"))
    }

    // MARK: - Selection helpers

    private var currentSelection: ConfigSelection? {
        configService.effectiveSelection
    }

    private var currentModel: ConfigModelEntry? {
        guard let sel = currentSelection else { return nil }
        return configService.model(providerId: sel.providerId, modelId: sel.modelId)
    }

    private func effortDisplayName(_ e: ConfigEffort) -> String {
        switch e {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        }
    }

    private func submit() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        // Selection enforcement happens here: chips the user deselected get
        // filtered out, so they never reach the sidecar log or LLM prompt.
        let selection = CitedSelection(
            deselectedBehaviors: deselectedChipKeys.subtracting([
                ContextChipKey.clipboard,
                ContextChipKey.visual
            ]),
            clipboardSelected: !deselectedChipKeys.contains(ContextChipKey.clipboard),
            visualSelected: !deselectedChipKeys.contains(ContextChipKey.visual)
        )
        // Visual snapshot only happens at submit time: if the chip is on
        // screen and the user kept it selected, capture once now and attach.
        // No background screen-recording loop runs at any point.
        let shouldCapture = selection.visualSelected
            && senseStore.visualSnapshotAvailable
            && senseStore.context.behaviors.isEmpty
        let snapshotCtx = senseStore.context
        let promptCopy = prompt
        text = ""
        // Chip selection persists within the session: if the user opted out
        // of clipboard/visual on a prior turn, the next prompt should respect
        // that until they re-select. Per-app chip identities still reset on
        // app switch (handled in ContextChipsView).
        Task {
            let visual: VisualMirror? = shouldCapture
                ? await senseStore.captureVisualSnapshot()
                : nil
            let cited = CitedContextProjection.project(
                from: snapshotCtx,
                selection: selection,
                visual: visual
            )
            // The sidecar registers the turn and broadcasts
            // `conversation.turnStarted`; the panel re-renders from there.
            // We intentionally don't seed a local turn so the UI has a single
            // source of truth (the sidecar's Conversation, mirrored by
            // AgentService).
            await agentService.submit(prompt: promptCopy, citedContext: cited)
        }
    }
}
