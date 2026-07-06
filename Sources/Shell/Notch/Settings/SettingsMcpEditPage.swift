import SwiftUI
import RPCSchema

// MARK: - SettingsMcpEditPage
//
// Add/edit form for an MCP server. Form state lives in
// `flow.mcpDraft` (`McpServerDraft`, owned by the MCP module); this view
// only binds fields and forwards Save/Cancel intents to the flow model,
// which builds the RPC payload and calls `McpService`.

struct SettingsMcpEditPage: View {
    @Bindable var flow: SettingsFlowModel
    let topSafeInset: CGFloat

    var body: some View {
        SettingsPickerPageChrome(
            title: flow.mcpDraft.isEditing ? "Edit MCP" : "Add MCP",
            topSafeInset: topSafeInset,
            onBack: { flow.page = .mcp }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                NotchTextField(
                    label: "Server ID",
                    placeholder: "filesystem",
                    text: $flow.mcpDraft.serverId,
                    monospaced: true,
                    isEnabled: !flow.mcpDraft.isEditing
                )
                NotchTextField(
                    label: "Description",
                    placeholder: "Local filesystem tools",
                    text: $flow.mcpDraft.description
                )

                Picker("Transport", selection: $flow.mcpDraft.transportType) {
                    Text("stdio").tag(McpTransportType.stdio)
                    Text("HTTP").tag(McpTransportType.streamableHttp)
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $flow.mcpDraft.autoConnect) {
                    Text("Auto Connect")
                        .notchFont(size: 12, weight: .medium)
                        .notchForeground(.primary)
                }
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Auto connect MCP server on startup"))

                if flow.mcpDraft.transportType == .stdio {
                    NotchTextField(
                        label: "Command",
                        placeholder: "npx",
                        text: $flow.mcpDraft.command,
                        monospaced: true
                    )
                    NotchTextField(
                        label: "Args JSON",
                        placeholder: "[\"-y\", \"@modelcontextprotocol/server-filesystem\", \"/tmp\"]",
                        text: $flow.mcpDraft.argsJSON,
                        monospaced: true
                    )
                    NotchTextField(
                        label: "Env JSON",
                        placeholder: "{\"TOKEN\":\"${TOKEN}\"}",
                        text: $flow.mcpDraft.envJSON,
                        monospaced: true
                    )
                } else {
                    NotchTextField(
                        label: "URL",
                        placeholder: "https://example.com/mcp",
                        text: $flow.mcpDraft.url,
                        monospaced: true
                    )
                    Picker("Auth", selection: $flow.mcpDraft.authType) {
                        Text("None").tag(McpAuthType.none)
                        Text("OAuth").tag(McpAuthType.oauth)
                        Text("Headers").tag(McpAuthType.headers)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text("MCP auth type"))

                    if flow.mcpDraft.authType == .headers {
                        NotchTextField(
                            label: "Headers JSON",
                            placeholder: "{\"Authorization\":\"Bearer token\"}",
                            text: $flow.mcpDraft.headersJSON,
                            monospaced: true
                        )
                    }
                }

                if let error = flow.mcpAddError ?? flow.mcpService.statusError {
                    NotchErrorText(error)
                }

                HStack(spacing: 8) {
                    NotchPrimaryButton(title: flow.mcpService.addSaving ? "Saving…" : "Save") {
                        Task { await flow.saveMcpServer() }
                    }
                    .disabled(flow.mcpService.addSaving || !flow.mcpDraft.canSave)

                    NotchSecondaryButton(title: "Cancel") {
                        flow.resetMcpDraft()
                        flow.page = .mcp
                    }
                    .disabled(flow.mcpService.addSaving)
                }
            }
        }
    }

}
