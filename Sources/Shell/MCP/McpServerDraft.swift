import Foundation
import RPCSchema

// MARK: - McpServerDraft
//
// Form-values → wire-params mapping for the Settings "Add/Edit MCP" page.
// Lives in the MCP module (not Settings) because the design forbids views
// assembling RPC payloads: this is where form state becomes
// `RPCSchema.McpAddParams` / `McpUpdateParams`, including JSON validation.
// The Settings flow model owns the instance and drives it from user intent;
// `SettingsMcpEditPage` only reads/writes plain draft fields.

struct McpServerDraft: Equatable {
    var editingServerId: String?
    var serverId: String = ""
    var description: String = ""
    var transportType: McpTransportType = .stdio
    var command: String = ""
    var argsJSON: String = "[]"
    var envJSON: String = "{}"
    var url: String = ""
    var authType: McpAuthType = .none
    var autoConnect: Bool = false
    var headersJSON: String = "{}"

    var isEditing: Bool {
        editingServerId != nil
    }

    var canSave: Bool {
        let hasBase = !serverId.trimmedForSettings.isEmpty &&
            !description.trimmedForSettings.isEmpty
        switch transportType {
        case .stdio:
            return hasBase && !command.trimmedForSettings.isEmpty
        case .streamableHttp:
            return hasBase && !url.trimmedForSettings.isEmpty
        }
    }

    mutating func load(_ config: McpServerConfigInfo) {
        editingServerId = config.serverId
        serverId = config.serverId
        description = config.description
        transportType = config.transportType
        command = config.command ?? ""
        argsJSON = Self.jsonString(config.args ?? [])
        envJSON = Self.jsonString(config.env ?? [:])
        url = config.url ?? ""
        authType = config.authType ?? (config.headers?.isEmpty == false ? .headers : .none)
        autoConnect = config.autoConnect ?? false
        headersJSON = Self.jsonString(config.headers ?? [:])
    }

    mutating func reset() {
        editingServerId = nil
        serverId = ""
        description = ""
        transportType = .stdio
        command = ""
        argsJSON = "[]"
        envJSON = "{}"
        url = ""
        authType = .none
        autoConnect = false
        headersJSON = "{}"
    }

    func buildAddParams() throws -> McpAddParams {
        switch transportType {
        case .stdio:
            return McpAddParams(
                serverId: serverId.trimmedForSettings,
                description: description.trimmedForSettings,
                transportType: .stdio,
                autoConnect: autoConnect,
                command: command.trimmedForSettings,
                args: try decodeJSON([String].self, from: argsJSON, label: "Args JSON"),
                env: try decodeJSON([String: String].self, from: envJSON, label: "Env JSON")
            )
        case .streamableHttp:
            return McpAddParams(
                serverId: serverId.trimmedForSettings,
                description: description.trimmedForSettings,
                transportType: .streamableHttp,
                authType: authType,
                autoConnect: autoConnect,
                url: url.trimmedForSettings,
                headers: try headersForSelectedAuthType()
            )
        }
    }

    func buildUpdateParams() throws -> McpUpdateParams {
        guard let editingServerId else {
            throw SettingsValidationError("No MCP server is selected for editing.")
        }
        switch transportType {
        case .stdio:
            return McpUpdateParams(
                serverId: editingServerId,
                description: description.trimmedForSettings,
                transportType: .stdio,
                autoConnect: autoConnect,
                command: command.trimmedForSettings,
                args: try decodeJSON([String].self, from: argsJSON, label: "Args JSON"),
                env: try decodeJSON([String: String].self, from: envJSON, label: "Env JSON")
            )
        case .streamableHttp:
            return McpUpdateParams(
                serverId: editingServerId,
                description: description.trimmedForSettings,
                transportType: .streamableHttp,
                authType: authType,
                autoConnect: autoConnect,
                url: url.trimmedForSettings,
                headers: try headersForSelectedAuthType()
            )
        }
    }

    private func headersForSelectedAuthType() throws -> [String: String]? {
        guard authType == .headers else {
            return nil
        }
        let headers = try decodeJSON([String: String].self, from: headersJSON, label: "Headers JSON")
        if headers.isEmpty {
            throw SettingsValidationError("Headers JSON must include at least one header when Auth is Headers.")
        }
        return headers
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    private func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from raw: String,
        label: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(raw.trimmedForSettings.utf8))
        } catch {
            throw SettingsValidationError("\(label) must be valid JSON: \(error.localizedDescription)")
        }
    }
}

/// Validation error for form → RPC-params mapping (JSON parsing, required
/// selection state). Scoped to the MCP module since `McpServerDraft` is its
/// only producer.
struct SettingsValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription {
            return message
        }
        return String(describing: error)
    }
}

extension String {
    var trimmedForSettings: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
