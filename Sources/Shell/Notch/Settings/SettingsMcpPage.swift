import SwiftUI

// MARK: - SettingsMcpPage
//
// Lists configured MCP servers with connect/disconnect/edit/delete actions.
// Connect/disconnect/delete call `McpService` directly (it's a service, not
// an RPC payload the view assembles) — only the add/edit form's payload
// construction is routed through the flow model + `McpServerDraft`.

struct SettingsMcpPage: View {
    let flow: SettingsFlowModel
    let topSafeInset: CGFloat

    var body: some View {
        SettingsPickerPageChrome(title: "MCP", topSafeInset: topSafeInset, onBack: { flow.pop() }) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsMcpAddButton {
                    flow.resetMcpDraft()
                    flow.page = .mcpAdd
                }

                if flow.mcpService.servers.isEmpty {
                    Text(flow.mcpService.loaded ? "No MCP servers configured." : "Loading…")
                        .notchFont(size: 12)
                        .notchForeground(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    ForEach(flow.mcpService.servers) { server in
                        SettingsMcpServerCard(
                            server: server,
                            loginSession: flow.mcpService.loginSessions[server.serverId],
                            isWorking: flow.mcpService.actionServerIds.contains(server.serverId),
                            onConnect: {
                                Task { await flow.mcpService.connect(serverId: server.serverId) }
                            },
                            onDisconnect: {
                                Task { await flow.mcpService.disconnect(serverId: server.serverId) }
                            },
                            onEdit: {
                                flow.openMcpEditPage(serverId: server.serverId)
                            },
                            onDelete: {
                                Task { await flow.mcpService.delete(serverId: server.serverId) }
                            }
                        )
                    }
                }
                if let error = flow.mcpService.statusError {
                    NotchErrorText(error)
                }
            }
        }
    }
}
