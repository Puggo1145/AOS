import SwiftUI
import RPCSchema

struct SettingsAPIKeyRow: View {
    let provider: ProviderService.Provider
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal")
                    .notchFont(size: 12, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text("API Key")
                    .notchFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                if provider.state == .ready {
                    Image(systemName: "checkmark.circle.fill")
                        .notchFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.green.opacity(0.85))
                        .accessibilityHidden(true)
                    Text("Saved")
                        .notchFont(size: 11)
                        .notchForeground(.secondary)
                        .accessibilityLabel(Text("API key saved"))
                } else {
                    Image(systemName: "exclamationmark.circle.fill")
                        .notchFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.red.opacity(0.9))
                        .accessibilityHidden(true)
                    Text("Required")
                        .notchFont(size: 11)
                        .foregroundStyle(.red.opacity(0.9))
                        .accessibilityLabel(Text("API key required"))
                }
                Image(systemName: "chevron.right")
                    .notchFont(size: 10, weight: .semibold)
                    .notchForeground(.secondary)
            }
            .settingsRowBackground()
        }
        .buttonStyle(.plain)
    }
}

struct SettingsOAuthRow: View {
    let provider: ProviderService.Provider
    /// Display-only snapshot of the in-progress login session for this
    /// provider (if any) — the flow model owns the orchestration that
    /// produces it; this row only reads it.
    let session: ProviderService.LoginSession?
    let canStartLogin: Bool
    let onStartOrReauth: () -> Void
    let onCancel: () -> Void

    private var isReady: Bool {
        provider.state == .ready
    }

    private var status: (text: String, color: Color, glyph: String, isInflight: Bool) {
        if let session {
            switch session.state {
            case .awaitingCallback:
                return ("Opened in browser...", Color.white.opacity(0.6), "hourglass", true)
            case .exchanging:
                return ("Verifying...", Color.white.opacity(0.6), "hourglass", true)
            case .failed:
                return (session.message ?? "Sign-in failed", Color.red.opacity(0.85), "exclamationmark.circle.fill", false)
            case .success:
                return ("Signed in", Color.green.opacity(0.85), "checkmark.circle.fill", false)
            }
        }
        if isReady {
            return ("Signed in", Color.green.opacity(0.85), "checkmark.circle.fill", false)
        }
        return ("Required", Color.red.opacity(0.85), "exclamationmark.circle.fill", false)
    }

    private var rowTitle: String {
        isReady ? "Re-authenticate \(provider.name)" : "Sign in to \(provider.name)"
    }

    var body: some View {
        let status = status
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onStartOrReauth) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .notchFont(size: 12, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 16)
                    Text(rowTitle)
                        .notchFont(size: 13, weight: .medium)
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer(minLength: 8)
                    Image(systemName: status.glyph)
                        .notchFont(size: 11, weight: .semibold)
                        .foregroundStyle(status.color)
                        .accessibilityHidden(true)
                    Text(status.text)
                        .notchFont(size: 11)
                        .foregroundStyle(status.color)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .notchFont(size: 10, weight: .semibold)
                        .notchForeground(.secondary)
                }
                .settingsRowBackground()
            }
            .buttonStyle(.plain)
            .disabled(status.isInflight || !canStartLogin)

            if status.isInflight {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.85))
                    .notchFont(size: 11)
                    .padding(.leading, 12)
            }
        }
    }
}

struct SettingsPermissionsSummaryRow: View {
    let missingCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .notchFont(size: 12, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text("Permissions")
                    .notchFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                if missingCount == 0 {
                    Image(systemName: "checkmark.shield.fill")
                        .notchFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.green.opacity(0.7))
                        .accessibilityHidden(true)
                    Text("All granted")
                        .notchFont(size: 11)
                        .notchForeground(.secondary)
                } else {
                    Image(systemName: "exclamationmark.shield.fill")
                        .notchFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.red.opacity(0.9))
                        .accessibilityHidden(true)
                    Text("\(missingCount) missing")
                        .notchFont(size: 11)
                        .foregroundStyle(.red.opacity(0.9))
                }
                Image(systemName: "chevron.right")
                    .notchFont(size: 10, weight: .semibold)
                    .notchForeground(.secondary)
            }
            .settingsRowBackground()
        }
        .buttonStyle(.plain)
    }
}

struct SettingsMcpSummaryRow: View {
    let configuredCount: Int
    let connectedCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .notchFont(size: 12, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text("MCP")
                    .notchFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                Text(summary)
                    .notchFont(size: 11)
                    .notchForeground(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .notchFont(size: 10, weight: .semibold)
                    .notchForeground(.secondary)
            }
            .settingsRowBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("MCP, \(summary)"))
    }

    private var summary: String {
        if configuredCount == 0 { return "None configured" }
        return "\(connectedCount)/\(configuredCount) connected"
    }
}

struct SettingsMcpAddButton: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .notchFont(size: 12, weight: .semibold)
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                Text("Add MCP")
                    .notchFont(size: 12, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .notchFont(size: 10, weight: .semibold)
                    .notchForeground(.secondary)
            }
            .settingsRowBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add MCP server"))
    }
}

struct SettingsMcpServerCard: View {
    let server: McpServerStatusInfo
    let loginSession: McpAuthLoginStatusParams?
    let isWorking: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var isConnected: Bool {
        server.connectionState == .connected
    }

    private var hasActiveLogin: Bool {
        guard let loginSession else { return false }
        switch loginSession.state {
        case .starting, .awaitingBrowser, .awaitingCallback, .exchanging:
            return true
        case .success, .failed, .cancelled:
            return false
        }
    }

    private var actionTitle: String {
        if isWorking { return "Working…" }
        if hasActiveLogin { return "Retry" }
        return isConnected ? "Disconnect" : "Connect"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .notchFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Text(server.description)
                    .notchFont(size: 11)
                    .notchForeground(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                isConnected ? onDisconnect() : onConnect()
            } label: {
                Text(actionTitle)
                    .notchFont(size: 11, weight: .semibold)
                    .notchForeground(.primary)
                    .frame(width: 76)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isConnected ? Color.white.opacity(0.08) : Color.accentColor.opacity(0.85))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityLabel(Text("\(actionTitle) \(server.name)"))

            Menu {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .notchFont(size: 13, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More actions for \(server.name)"))
        }
        .settingsRowBackground()
        .accessibilityElement(children: .contain)
    }
}

struct SettingsDisplayModeRow: View {
    let displayMode: ConversationDisplayMode
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                    .notchFont(size: 12, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text("Display Mode")
                    .notchFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                Text(displayMode.label)
                    .notchFont(size: 11)
                    .notchForeground(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .notchFont(size: 10, weight: .semibold)
                    .notchForeground(.secondary)
            }
            .settingsRowBackground()
        }
        .buttonStyle(.plain)
    }
}

struct SettingsPermissionLevelRow: View {
    let permissionLevel: ConfigPermissionLevel
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .notchFont(size: 12, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text("Permission Level")
                    .notchFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                Text(permissionLevel.label)
                    .notchFont(size: 11)
                    .notchForeground(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .notchFont(size: 10, weight: .semibold)
                    .notchForeground(.secondary)
            }
            .settingsRowBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Permission Level, \(permissionLevel.label)"))
    }
}

struct SettingsDevModeRow: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .notchOpenDevMode, object: nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "hammer")
                    .notchFont(size: 12, weight: .semibold)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text("Dev Mode")
                    .notchFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward.square")
                    .notchFont(size: 10, weight: .semibold)
                    .notchForeground(.secondary)
            }
            .settingsRowBackground()
        }
        .buttonStyle(.plain)
    }
}

struct SettingsQuitButton: View {
    let reduceMotion: Bool
    @State private var confirming = false
    @State private var confirmTask: Task<Void, Never>?

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 6) {
                Image(systemName: confirming ? "exclamationmark.triangle.fill" : "power")
                    .notchFont(size: 12, weight: .semibold)
                Text(confirming ? "Confirm Quit?" : "Quit Notch Agent")
                    .notchFont(size: 13, weight: .semibold)
            }
            .foregroundStyle(confirming ? Color.white : Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(confirming ? Color.red.opacity(0.85) : Color.white.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: confirming)
        .onDisappear {
            confirmTask?.cancel()
        }
    }

    private func handleTap() {
        if confirming {
            confirmTask?.cancel()
            NSApp.terminate(nil)
            return
        }
        confirming = true
        confirmTask?.cancel()
        confirmTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                confirming = false
            }
        }
    }
}

private extension View {
    func settingsRowBackground() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
