import SwiftUI
import AOSRPCSchema

// MARK: - SettingsPanelView
//
// Two-page navigation inside the same panel:
//
//   .main
//     Settings
//     ┌─ Provider ─┐  ┌─ Model ─┐
//     │  Codex…    │  │ GPT-5.5 │
//     └────────────┘  └─────────┘
//
//   .picker (provider | model)
//     ‹ Provider
//     ◉ Codex Subscription
//     ◯ ...
//
// Tap a card → push to picker page; tap a row → commit + pop back. The
// transition is a horizontal slide so it reads as page-level navigation
// instead of an in-place reveal. ESC pops one level (or closes settings
// if already on .main).

struct SettingsPanelView: View {
    let configService: ConfigService
    let topSafeInset: CGFloat
    let onClose: () -> Void

    @State private var page: Page = .main
    @State private var quitConfirming: Bool = false
    @State private var quitConfirmTask: Task<Void, Never>? = nil

    private enum Page: Equatable {
        case main
        case provider
        case model
        case effort
    }

    var body: some View {
        ZStack {
            switch page {
            case .main:
                mainPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            case .provider:
                providerPickerPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .model:
                modelPickerPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            case .effort:
                effortPickerPage
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: page)
        .onExitCommand {
            if page == .main { onClose() } else { page = .main }
        }
    }

    // MARK: - Main page

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Text("Settings")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configService.providers.isEmpty {
                placeholder
            } else {
                HStack(alignment: .top, spacing: 10) {
                    BentoPickerCard(
                        caption: "Provider",
                        valueTitle: selectedProvider?.name ?? "—",
                        onTap: { page = .provider }
                    )
                    BentoPickerCard(
                        caption: "Model",
                        valueTitle: selectedModel?.name ?? "—",
                        isEnabled: !(selectedProvider?.models.isEmpty ?? true),
                        onTap: { page = .model }
                    )
                    BentoPickerCard(
                        caption: "Effort",
                        valueTitle: effortDisplayName(currentEffort),
                        isEnabled: selectedModel?.reasoning ?? false,
                        onTap: { page = .effort }
                    )
                }
            }

            Spacer(minLength: 0)

            quitButton
        }
        .padding(.top, topSafeInset)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    // MARK: - Quit
    //
    // Two-tap confirm: first tap arms the button (label flips to a red
    // "Confirm Quit?" state); second tap within 3s terminates the app.
    // Auto-disarms after the window so a stray click never quits.

    private var quitButton: some View {
        Button(action: handleQuitTap) {
            HStack(spacing: 6) {
                Image(systemName: quitConfirming ? "exclamationmark.triangle.fill" : "power")
                    .font(.system(size: 12, weight: .semibold))
                Text(quitConfirming ? "Confirm Quit?" : "Quit AOS")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(quitConfirming ? Color.white : Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(quitConfirming
                          ? Color.red.opacity(0.85)
                          : Color.white.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: quitConfirming)
    }

    private func handleQuitTap() {
        if quitConfirming {
            quitConfirmTask?.cancel()
            NSApp.terminate(nil)
            return
        }
        quitConfirming = true
        quitConfirmTask?.cancel()
        quitConfirmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                quitConfirming = false
            }
        }
    }

    // MARK: - Picker pages

    private var providerPickerPage: some View {
        pickerPage(title: "Provider") {
            BentoOptionsList(
                options: configService.providers.map {
                    BentoOption(id: $0.id, title: $0.name)
                },
                selectedId: selectedProvider?.id ?? "",
                onSelect: { newProviderId in
                    Task {
                        await handleProviderChange(newProviderId)
                        page = .main
                    }
                }
            )
        }
    }

    private var modelPickerPage: some View {
        pickerPage(title: "Model") {
            if let provider = selectedProvider {
                BentoOptionsList(
                    options: provider.models.map { BentoOption(id: $0.id, title: $0.name) },
                    selectedId: selectedModel?.id ?? "",
                    onSelect: { newModelId in
                        Task {
                            await configService.selectModel(providerId: provider.id, modelId: newModelId)
                            page = .main
                        }
                    }
                )
            }
        }
    }

    private var effortPickerPage: some View {
        pickerPage(title: "Effort") {
            BentoOptionsList(
                options: effortOptions,
                selectedId: currentEffort.rawValue,
                onSelect: { rawValue in
                    guard let value = ConfigEffort(rawValue: rawValue) else { return }
                    Task {
                        await configService.selectEffort(value)
                        page = .main
                    }
                }
            )
        }
    }

    /// Build effort rows respecting the current model's `supportsXhigh`
    /// flag — disable rather than hide so the row count stays stable.
    private var effortOptions: [BentoOption] {
        let supportsXhigh = selectedModel?.supportsXhigh ?? true
        return ConfigEffort.allCases.compactMap { e in
            if e == .xhigh && !supportsXhigh { return nil }
            return BentoOption(id: e.rawValue, title: effortDisplayName(e))
        }
    }

    private var currentEffort: ConfigEffort {
        configService.effectiveEffort
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

    @ViewBuilder
    private func pickerPage<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                page = .main
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView {
                content()
            }
        }
        .padding(.top, topSafeInset)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var placeholder: some View {
        Text(configService.loaded ? "No providers available." : "Loading…")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    // MARK: - Selection helpers

    private var selectedProvider: ConfigProviderEntry? {
        guard let sel = configService.effectiveSelection else { return configService.providers.first }
        return configService.providers.first(where: { $0.id == sel.providerId }) ?? configService.providers.first
    }

    private var selectedModel: ConfigModelEntry? {
        guard let provider = selectedProvider else { return nil }
        let modelId = configService.effectiveSelection?.modelId ?? provider.defaultModelId
        return provider.models.first(where: { $0.id == modelId }) ?? provider.models.first
    }

    private func handleProviderChange(_ newProviderId: String) async {
        guard let target = configService.providers.first(where: { $0.id == newProviderId }) else { return }
        await configService.selectModel(providerId: target.id, modelId: target.defaultModelId)
    }
}
