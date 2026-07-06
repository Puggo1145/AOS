import Foundation
import RPCSchema
import OSSenseKit

// MARK: - SettingsFlowModel
//
// Orchestration for the Settings panel: page navigation, API-key CRUD, MCP
// server CRUD, permission actions, and the catalog/runtime selection joins.
// `SettingsPanelView` and its per-page views only read published state and
// forward user intents to methods here — they never assemble RPC payloads
// or drive service calls directly (see docs/designs/notch-ui.md).
//
// One instance is created per Settings-panel appearance (the view constructs
// it via `@State private var flow = SettingsFlowModel(...)`), which is what
// gives the panel its "always reopens on `.main`" reset semantics — there is
// no persistence across opens/closes.
@MainActor
@Observable
final class SettingsFlowModel {
    enum Page: Equatable {
        case main
        case provider
        case model
        case effort
        case permissionLevel
        case displayMode
        case permissions
        case mcp
        case mcpAdd
        case apiKey
    }

    let configService: ConfigService
    let providerService: ProviderService
    let mcpService: McpService
    let permissionsService: PermissionsService

    var page: Page = .main

    // MARK: API key flow

    var apiKeyDraft: String = ""
    var apiKeySaveError: String?
    private(set) var apiKeySaving: Bool = false
    private var apiKeyProviderId: String = ""

    // MARK: MCP flow

    var mcpDraft = McpServerDraft()
    var mcpAddError: String?

    // MARK: Permission flow

    private(set) var permissionRequestError: String?

    init(
        configService: ConfigService,
        providerService: ProviderService,
        mcpService: McpService,
        permissionsService: PermissionsService
    ) {
        self.configService = configService
        self.providerService = providerService
        self.mcpService = mcpService
        self.permissionsService = permissionsService
    }

    // MARK: - Navigation

    /// Pop one level back to `.main`. Used by ESC handling; sub-page "back"
    /// buttons target a specific `backPage` instead (e.g. mcpAdd → mcp).
    func pop() {
        page = .main
    }

    /// ESC semantics: pop to `.main` if on a sub-page, otherwise close the
    /// panel entirely. Every sub-page pops straight to `.main` on ESC
    /// regardless of its own "back" button target.
    func handleEscape(onClose: () -> Void) {
        if page == .main {
            onClose()
        } else {
            pop()
        }
    }

    // MARK: - Panel lifecycle

    /// One-shot setup performed the moment the panel appears.
    func onPanelAppear() async {
        await mcpService.refreshStatus()
    }

    /// Poll permissions while Settings is open so toggling a permission in
    /// System Settings is reflected immediately. The probe is async on
    /// purpose — the screen recording arm uses `SCShareableContent.current`,
    /// the only live source (see `PermissionsService`). Cancellation is
    /// tied to the view's `.task`, which is cancelled when Settings closes.
    func runPermissionLivePolling() async {
        while !Task.isCancelled {
            await permissionsService.refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: - API key flow

    /// Pre-load the existing key into the draft so the field reads
    /// "ready to edit" rather than asking the user to re-type. We
    /// round-trip through Keychain explicitly — the sidecar's in-memory
    /// copy is not a source the UI can read back.
    func openApiKeyPage(provider: ProviderService.Provider) {
        apiKeyProviderId = provider.id
        do {
            apiKeyDraft = try providerService.peekApiKey(providerId: provider.id) ?? ""
            apiKeySaveError = nil
        } catch {
            apiKeyDraft = ""
            apiKeySaveError = ProviderService.message(for: error)
        }
        page = .apiKey
    }

    func saveApiKey() async {
        apiKeySaving = true
        apiKeySaveError = nil
        do {
            try await providerService.saveApiKey(providerId: apiKeyProviderId, apiKey: apiKeyDraft)
            apiKeySaving = false
            page = .main
        } catch {
            apiKeySaving = false
            apiKeySaveError = ProviderService.message(for: error)
        }
    }

    func clearApiKey() async {
        apiKeySaving = true
        apiKeySaveError = nil
        do {
            try await providerService.clearApiKey(providerId: apiKeyProviderId)
            apiKeySaving = false
            apiKeyDraft = ""
            page = .main
        } catch {
            apiKeySaving = false
            apiKeySaveError = ProviderService.message(for: error)
        }
    }

    // MARK: - OAuth row flow
    //
    // `SettingsOAuthRow` used to do its own do/catch around
    // `providerService.startLogin/cancelLogin/logout` inline in the view.
    // That orchestration (and the error mapping) lives here now; the row
    // receives plain display state (`session`, `canStartLogin`) and plain
    // closures, per the "views forward intents" contract.

    /// The in-progress OAuth login session for `providerId`, if any —
    /// filters `ProviderService.loginSession` (which is global, not keyed
    /// by provider) down to the row's own provider.
    func oauthLoginSession(for providerId: String) -> ProviderService.LoginSession? {
        providerService.loginSession.flatMap { $0.providerId == providerId ? $0 : nil }
    }

    /// Sign in (provider not ready) or re-authenticate (provider ready):
    /// dismiss a failed session, log out first if already ready, then
    /// start a fresh login. Errors surface through `apiKeySaveError` — the
    /// same slot the API-key row uses — since both are auth errors shown
    /// on the Settings main page.
    func startOAuthFlow(provider: ProviderService.Provider) {
        let session = oauthLoginSession(for: provider.id)
        let isInflight = session.map(Self.isInflightOAuthState) ?? false
        guard providerService.canStartLogin, !isInflight else { return }
        Task {
            if session?.state == .failed {
                providerService.dismissLoginSession()
            }
            if provider.state == .ready {
                do {
                    try await providerService.logout(providerId: provider.id)
                } catch {
                    apiKeySaveError = ProviderService.message(for: error)
                    return
                }
            }
            await providerService.startLogin(providerId: provider.id)
        }
    }

    func cancelOAuthLogin() {
        Task {
            do {
                try await providerService.cancelLogin()
            } catch {
                apiKeySaveError = ProviderService.message(for: error)
            }
        }
    }

    private static func isInflightOAuthState(_ session: ProviderService.LoginSession) -> Bool {
        switch session.state {
        case .awaitingCallback, .exchanging:
            return true
        case .success, .failed:
            return false
        }
    }

    // MARK: - MCP flow

    func saveMcpServer() async {
        do {
            mcpAddError = nil
            let saved: Bool
            if mcpDraft.isEditing {
                saved = await mcpService.update(try mcpDraft.buildUpdateParams())
            } else {
                saved = await mcpService.add(try mcpDraft.buildAddParams())
            }
            if saved {
                resetMcpDraft()
                page = .mcp
            } else {
                mcpAddError = mcpService.statusError
            }
        } catch {
            mcpAddError = SettingsValidationError.message(for: error)
        }
    }

    func openMcpEditPage(serverId: String) {
        Task {
            do {
                mcpAddError = nil
                let config = try await mcpService.config(serverId: serverId)
                mcpDraft.load(config)
                page = .mcpAdd
            } catch {
                mcpAddError = McpService.message(for: error)
            }
        }
    }

    func resetMcpDraft() {
        mcpDraft.reset()
        mcpAddError = nil
    }

    // MARK: - Permission flow
    //
    // The settings main page surfaces a one-line permissions summary that
    // doubles as the entry point to the dedicated permissions sub-page.
    // A red dot lights up when a probeable permission is missing. Automation
    // has no safe status API here; its row is a direct jump to System
    // Settings.

    var missingPermissions: [Permission] {
        Self.missingProbeablePermissions(denied: permissionsService.state.denied)
    }

    static func missingProbeablePermissions(denied: Set<Permission>) -> [Permission] {
        Permission.settingsDisplayOrder.filter { permission in
            switch permission {
            case .screenRecording, .accessibility:
                return denied.contains(permission)
            case .localFiles, .automation:
                return false
            }
        }
    }

    static func permissionStatus(
        for permission: Permission,
        denied: Set<Permission>
    ) -> PermissionSettingsStatus {
        switch permission {
        case .screenRecording, .accessibility:
            return denied.contains(permission) ? .disabled : .granted
        case .localFiles, .automation:
            return .opensSettings
        }
    }

    func permissionStatus(for permission: Permission) -> PermissionSettingsStatus {
        switch permission {
        case .localFiles:
            return permissionsService.localFilesOnboardingAcknowledged ? .granted : .opensSettings
        case .accessibility, .screenRecording, .automation:
            return Self.permissionStatus(for: permission, denied: permissionsService.state.denied)
        }
    }

    func handlePermissionSettingsAction(_ permission: Permission) {
        switch permission {
        case .localFiles:
            guard !permissionsService.localFilesOnboardingAcknowledged else {
                permissionsService.openSystemSettings(for: permission)
                return
            }
            Task {
                do {
                    permissionRequestError = nil
                    try await permissionsService.request(.localFiles)
                } catch {
                    permissionRequestError = "Permission request failed: \(error)"
                }
            }
        case .accessibility, .screenRecording, .automation:
            permissionRequestError = nil
            permissionsService.openSystemSettings(for: permission)
        }
    }

    // MARK: - Selection joins

    /// The catalog-selected provider (falls back to the catalog's first
    /// provider when no explicit selection exists yet).
    var selectedProvider: ConfigProviderEntry? {
        guard let sel = configService.effectiveSelection else { return configService.providers.first }
        return configService.providers.first(where: { $0.id == sel.providerId }) ?? configService.providers.first
    }

    var selectedModel: ConfigModelEntry? {
        guard let provider = selectedProvider else { return nil }
        let modelId = configService.effectiveSelection?.modelId ?? provider.defaultModelId
        return provider.models.first(where: { $0.id == modelId }) ?? provider.models.first
    }

    /// The runtime provider corresponding to the currently *selected* (catalog)
    /// provider id — joins the catalog-projection (`ConfigService.providers`)
    /// to the live state (`ProviderService.providers`). Returns `nil` if the
    /// runtime hasn't yet enumerated the selected provider.
    var currentRuntimeProvider: ProviderService.Provider? {
        guard let selectedId = selectedProvider?.id else { return nil }
        return providerService.providers.first { $0.id == selectedId }
    }

    var currentEffort: ConfigEffort? {
        configService.effort(for: selectedModel)
    }

    /// Build effort rows from the sidecar-reported supported list.
    /// Each row's id/title come straight from the catalog — no local
    /// mapping table.
    var effortOptions: [BentoOption] {
        let efforts = selectedModel?.supportedEfforts ?? []
        return efforts.map { e in BentoOption(id: e.value, title: e.label) }
    }

    func handleProviderChange(_ newProviderId: String) async {
        guard let target = configService.providers.first(where: { $0.id == newProviderId }) else { return }
        await configService.selectModel(providerId: target.id, modelId: target.defaultModelId)
    }
}
