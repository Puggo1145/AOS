import SwiftUI
import RPCSchema
import OSSenseKit

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
//
// This file owns only the flow-model construction, the page switch, the
// shared page chrome, ESC handling, and measurement plumbing. Each page's
// content lives in its own file under Settings/ — see SettingsMainPage,
// SettingsApiKeyPage, SettingsMcpPage/SettingsMcpEditPage,
// SettingsPermissionsPage, and SettingsPickerPage (provider/model/effort/
// displayMode/permissionLevel).

struct SettingsPanelView: View {
    let configService: ConfigService
    let providerService: ProviderService
    let mcpService: McpService
    let permissionsService: PermissionsService
    let topSafeInset: CGFloat
    let onClose: () -> Void

    @State private var flow: SettingsFlowModel
    @AppStorage(ConversationDisplayMode.storageKey) private var displayModeRaw: String = ConversationDisplayMode.history.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        configService: ConfigService,
        providerService: ProviderService,
        mcpService: McpService,
        permissionsService: PermissionsService,
        topSafeInset: CGFloat,
        onClose: @escaping () -> Void
    ) {
        self.configService = configService
        self.providerService = providerService
        self.mcpService = mcpService
        self.permissionsService = permissionsService
        self.topSafeInset = topSafeInset
        self.onClose = onClose
        // Fresh flow model per panel appearance — this is what gives the
        // panel its "always reopens on .main" reset semantics, matching
        // the old @State-per-page behavior.
        _flow = State(initialValue: SettingsFlowModel(
            configService: configService,
            providerService: providerService,
            mcpService: mcpService,
            permissionsService: permissionsService
        ))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch flow.page {
            case .main:
                SettingsMainPage(flow: flow, topSafeInset: topSafeInset, displayModeRaw: $displayModeRaw, onClose: onClose)
                    .settingsPageTransition(edge: .leading)
            case .provider:
                SettingsProviderPickerPage(flow: flow, topSafeInset: topSafeInset)
                    .settingsPageTransition(edge: .trailing)
            case .model:
                SettingsModelPickerPage(flow: flow, topSafeInset: topSafeInset)
                    .settingsPageTransition(edge: .trailing)
            case .effort:
                SettingsEffortPickerPage(flow: flow, topSafeInset: topSafeInset)
                    .settingsPageTransition(edge: .trailing)
            case .permissionLevel:
                SettingsPermissionLevelPickerPage(flow: flow, topSafeInset: topSafeInset)
                    .settingsPageTransition(edge: .trailing)
            case .displayMode:
                SettingsDisplayModePickerPage(flow: flow, topSafeInset: topSafeInset, displayModeRaw: $displayModeRaw)
                    .settingsPageTransition(edge: .trailing)
            case .permissions:
                SettingsPermissionsPage(flow: flow, topSafeInset: topSafeInset)
                    .settingsPageTransition(edge: .trailing)
            case .mcp:
                SettingsMcpPage(flow: flow, topSafeInset: topSafeInset)
                    .settingsPageTransition(edge: .trailing)
            case .mcpAdd:
                SettingsMcpEditPage(flow: flow, topSafeInset: topSafeInset)
                    .settingsPageTransition(edge: .trailing)
            case .apiKey:
                SettingsApiKeyPage(flow: flow, topSafeInset: topSafeInset)
                    .settingsPageTransition(edge: .trailing)
            }
        }
        .task {
            await flow.onPanelAppear()
            await flow.runPermissionLivePolling()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .notchChrome, value: flow.page)
        .onExitCommand {
            flow.handleEscape(onClose: onClose)
        }
    }
}

// MARK: - Shared page transition
//
// Collapses what used to be 10 copy-pasted `.frame(...).transition(...)`
// blocks (one per page in the switch above) into a single modifier.
// `.main` slides in from the leading edge; every sub-page slides in from
// the trailing edge — reads as page-level navigation instead of an
// in-place reveal.
private extension View {
    func settingsPageTransition(edge: Edge) -> some View {
        frame(maxWidth: .infinity, alignment: .topLeading)
            .transition(.asymmetric(
                insertion: .move(edge: edge).combined(with: .opacity),
                removal: .move(edge: edge).combined(with: .opacity)
            ))
    }
}

// MARK: - Shared picker-page chrome
//
// Back button + title header, scrollable content below. Used by every
// sub-page (pickers, permissions, MCP, API key) so each page file only
// supplies its title and content.
struct SettingsPickerPageChrome<Content: View>: View {
    let title: String
    let topSafeInset: CGFloat
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .notchFont(size: 13, weight: .semibold)
                        .notchForeground(.secondary)
                    Text(title)
                        .notchFont(size: 18, weight: .semibold)
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
}
