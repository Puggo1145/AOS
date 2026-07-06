import SwiftUI
import RPCSchema

// MARK: - Picker pages
//
// Provider / Model / Effort / Display Mode / Permission Level are all thin
// BentoOptionsList wrappers around the shared `SettingsPickerPageChrome`:
// each just supplies its own option list, current selection, and commit
// action. Kept together in one file since none of them earns a file on
// its own.

struct SettingsProviderPickerPage: View {
    let flow: SettingsFlowModel
    let topSafeInset: CGFloat

    var body: some View {
        SettingsPickerPageChrome(title: "Provider", topSafeInset: topSafeInset, onBack: { flow.pop() }) {
            BentoOptionsList(
                options: flow.configService.providers.map {
                    BentoOption(id: $0.id, title: $0.name)
                },
                selectedId: flow.selectedProvider?.id ?? "",
                onSelect: { newProviderId in
                    Task {
                        await flow.handleProviderChange(newProviderId)
                        flow.pop()
                    }
                }
            )
        }
    }
}

struct SettingsModelPickerPage: View {
    let flow: SettingsFlowModel
    let topSafeInset: CGFloat

    var body: some View {
        SettingsPickerPageChrome(title: "Model", topSafeInset: topSafeInset, onBack: { flow.pop() }) {
            if let provider = flow.selectedProvider {
                BentoOptionsList(
                    options: provider.models.map { BentoOption(id: $0.id, title: $0.name) },
                    selectedId: flow.selectedModel?.id ?? "",
                    onSelect: { newModelId in
                        Task {
                            await flow.configService.selectModel(providerId: provider.id, modelId: newModelId)
                            flow.pop()
                        }
                    }
                )
            }
        }
    }
}

struct SettingsEffortPickerPage: View {
    let flow: SettingsFlowModel
    let topSafeInset: CGFloat

    var body: some View {
        SettingsPickerPageChrome(title: "Effort", topSafeInset: topSafeInset, onBack: { flow.pop() }) {
            BentoOptionsList(
                options: flow.effortOptions,
                selectedId: flow.currentEffort?.value ?? "",
                onSelect: { rawValue in
                    guard let value = flow.selectedModel?.supportedEfforts.first(where: { $0.value == rawValue }) else { return }
                    Task {
                        await flow.configService.selectEffort(value)
                        flow.pop()
                    }
                }
            )
        }
    }
}

struct SettingsDisplayModePickerPage: View {
    let flow: SettingsFlowModel
    let topSafeInset: CGFloat
    @Binding var displayModeRaw: String

    var body: some View {
        SettingsPickerPageChrome(title: "Display Mode", topSafeInset: topSafeInset, onBack: { flow.pop() }) {
            BentoOptionsList(
                options: ConversationDisplayMode.allCases.map {
                    BentoOption(id: $0.rawValue, title: $0.label)
                },
                selectedId: displayModeRaw,
                onSelect: { rawValue in
                    displayModeRaw = rawValue
                    flow.pop()
                }
            )
        }
    }
}

struct SettingsPermissionLevelPickerPage: View {
    let flow: SettingsFlowModel
    let topSafeInset: CGFloat

    var body: some View {
        SettingsPickerPageChrome(title: "Permission Level", topSafeInset: topSafeInset, onBack: { flow.pop() }) {
            BentoOptionsList(
                options: ConfigPermissionLevel.allCases.map {
                    BentoOption(id: $0.rawValue, title: $0.label)
                },
                selectedId: flow.configService.permissionLevel.rawValue,
                onSelect: { rawValue in
                    guard let level = ConfigPermissionLevel(rawValue: rawValue) else { return }
                    Task {
                        await flow.configService.selectPermissionLevel(level)
                        flow.pop()
                    }
                }
            )
        }
    }
}
