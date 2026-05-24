import SwiftUI
import AppKit
import RPCSchema

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
// The view renders the composer surface and forwards user intents. Turn
// reservation, context projection, visual capture, and RPC submit live in
// NotchViewModel so the view does not own business effects.

struct ComposerCard: View {
    let viewModel: NotchViewModel
    /// Owned by `NotchViewModel` so the typed text + chips persist
    /// across notch close/reopen cycles. The composer view is recreated
    /// on every open (it's mounted under a `status == .opened` gate);
    /// holding this in `@State` would wipe the input every time.
    let inputModel: ChipInputModel
    @Binding var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var scaledInputFontSize: CGFloat = 15

    @State private var deselectedBehaviorKeys: Set<String> = []
    /// Slash-command palette state lives on `NotchViewModel` because the
    /// notch's tray drawer (rendered above the composer in the view
    /// tree) consumes the same state to project palette matches into
    /// drawer rows. Pulling it here as a computed pass-through keeps
    /// the composer's local code reading like a `@State` while the
    /// authoritative source is the viewmodel.
    private var palette: CommandPaletteState { viewModel.commandPalette }

    /// Disable the send button when the typed prompt is effectively empty.
    /// Chips alone don't count — the LLM contract is "the user actually
    /// said something", and a bag of pastes with no question is a bug
    /// shape, not a turn.
    ///
    /// While the slash-command palette is active, the send button is
    /// also disabled — the trailing affordance becomes meaningless when
    /// Enter is reserved for command execution, and submitting a
    /// literal `/compact` as a prompt is never desirable.
    private var canSubmit: Bool {
        viewModel.canSubmitComposer(paletteActive: palette.isActive)
    }

    private var inputFontSize: CGFloat {
        NotchScaledMetric(value: scaledInputFontSize, base: 15, maxScale: 1.35).clamped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ContextChipsView(
                context: viewModel.senseStore.context,
                policyStore: viewModel.visualCapturePolicyStore,
                screenshotToggle: viewModel.composerScreenshotToggleState,
                deselectedBehaviorKeys: $deselectedBehaviorKeys
            )
            inputRow
            functionRow
        }
        .onChange(of: inputModel.displayText) { _, _ in
            viewModel.refreshCommandPalette()
        }
        .onChange(of: inputModel.isStorageEmpty) { _, _ in
            viewModel.refreshCommandPalette()
        }
        .onChange(of: inputModel.attachmentCount) { _, _ in
            // Pasting a chip while `/compact` is showing must
            // immediately fail the palette gate — the gate forbids
            // attachments. `displayText` doesn't change on a chip
            // insert, so the regular text-change observer wouldn't
            // catch this.
            viewModel.refreshCommandPalette()
        }
        .onChange(of: viewModel.agentService.hasCompactableContext) { _, _ in
            viewModel.refreshCommandPalette()
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        Group {
            if let queued = viewModel.agentService.queuedPrompt {
                queuedPromptView(queued)
            } else {
                ZStack(alignment: .topLeading) {
                    // Custom-overlay placeholder. Drawing it ourselves keeps the
                    // baseline pinned across focus transitions; AppKit's
                    // placeholder shifts ~1pt when the field editor swaps in,
                    // which reads as a flicker.
                    Text("What can I do for you?")
                        .notchFont(size: 15)
                        .foregroundStyle(.white.opacity(inputModel.isStorageEmpty ? 0.35 : 0))
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                    ChipInputView(
                        model: inputModel,
                        font: NSFont.systemFont(ofSize: inputFontSize),
                        textColor: .white,
                        onSubmit: { submit() },
                        onFocusChange: { inputFocused = $0 },
                        paletteIsActive: { palette.isActive },
                        paletteNavigate: { palette.navigate($0) },
                        paletteEnter: { viewModel.executeHighlightedCommand() },
                        paletteEscape: { palette.deactivate() }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityLabel(Text("Prompt input"))
    }

    private func queuedPromptView(_ queued: QueuedPrompt) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "clock")
                .notchFont(size: 11, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.55))
                .accessibilityHidden(true)
            Text("Queued")
                .notchFont(size: 12, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(.white.opacity(0.7))
            Text(queued.prompt)
                .notchFont(size: 15)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Function row

    private var functionRow: some View {
        HStack(spacing: 8) {
            modelMenu
            if !(currentModel?.supportedEfforts.isEmpty ?? true) {
                effortMenu
            }
            Spacer(minLength: 8)
            if let usage = viewModel.agentService.latestUsage {
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
                            await viewModel.selectComposerModel(
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
                .notchFont(size: 12, weight: .medium, relativeTo: .caption)
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
        let active = viewModel.configService.effort(for: currentModel)
        Menu {
            ForEach(efforts) { effort in
                Button {
                    Task { await viewModel.selectComposerEffort(effort) }
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
                .notchFont(size: 12, relativeTo: .caption)
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
        if viewModel.agentService.hasQueuedPrompt {
            cancelQueuedButton
        } else if viewModel.isAgentBusy || viewModel.agentService.hasRunningCompact {
            stopButton
        } else {
            submitButton
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .notchFont(size: 12, weight: .bold, relativeTo: .caption)
                .foregroundStyle(canSubmit ? Color.black : Color.white.opacity(0.4))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(canSubmit ? Color.white : Color.white.opacity(0.15))
                )
                // Subtle ready-to-fire cue. Reduce Motion users get the snap.
                .animation(reduceMotion ? nil : .notchChrome, value: canSubmit)
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
        .accessibilityLabel(Text(viewModel.agentService.hasRunningCompact ? "Stop compaction" : "Stop agent"))
    }

    private var cancelQueuedButton: some View {
        Button(action: cancel) {
            Image(systemName: "xmark")
                .notchFont(size: 11, weight: .bold, relativeTo: .caption)
                .foregroundStyle(Color.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white))
        }
        .buttonStyle(.notchPressable)
        .accessibilityLabel(Text("Cancel queued prompt"))
    }

    private func cancel() {
        Task { await viewModel.cancelComposerRun() }
    }

    // MARK: - Selection helpers

    private var currentSelection: ConfigSelection? {
        viewModel.currentSelection
    }

    private var currentModel: ConfigModelEntry? {
        viewModel.currentModel
    }

    private var currentProvider: ConfigProviderEntry? {
        viewModel.currentProvider
    }

    private func submit() {
        Task { await viewModel.submitComposer(deselectedBehaviorKeys: deselectedBehaviorKeys) }
    }
}
