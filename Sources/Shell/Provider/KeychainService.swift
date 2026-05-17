import Foundation
import Security

// MARK: - KeychainService
//
// Per-provider API key persistence via the macOS Keychain. Used by
// `ProviderService` for any provider whose `authMethod == .apiKey`.
//
// Layout:
//   - kSecClass:      kSecClassGenericPassword
//   - kSecAttrService: "com.notch-agent.apikey"
//   - kSecAttrAccount: <providerId>     (e.g. "deepseek")
//   - kSecValueData:   utf-8 bytes of the API key
//   - kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
//
// Why `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
//   - `AfterFirstUnlock` lets the agent run after a reboot once the user
//     has logged in once — matches user expectation for a background
//     menubar/notch agent.
//   - `ThisDeviceOnly` opts out of iCloud Keychain sync. API keys are
//     small but high-value; not worth the cross-device blast radius.
//
// We deliberately fail fast on Keychain errors. The Shell catches them
// and surfaces an inline status pill; we do not silently fall back to
// disk because that would defeat the whole purpose of using Keychain.

public enum KeychainServiceError: Error, Equatable {
    /// Underlying SecItem* call returned a non-success OSStatus.
    case osStatus(OSStatus)
    /// Keychain entry exists but its data is not valid UTF-8 — corrupt entry.
    case malformedEntry
}

public struct KeychainService: Sendable {
    public static let shared = KeychainService(service: "com.notch-agent.apikey")

    private let service: String

    public init(service: String) {
        self.service = service
    }

    /// Read the API key stored for `providerId`, or `nil` if absent.
    public func loadApiKey(providerId: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: providerId,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainServiceError.osStatus(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError.malformedEntry
        }
        return key
    }

    /// Write or overwrite the API key for `providerId`. Atomically replaces
    /// any existing entry under the same account.
    public func saveApiKey(providerId: String, apiKey: String) throws {
        let data = Data(apiKey.utf8)

        // First try to update an existing entry — this preserves access
        // metadata (creation date, etc) and is the documented Apple pattern
        // (see TN2351). Falls through to add if no existing entry.
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: providerId,
        ]
        let updateAttrs: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainServiceError.osStatus(updateStatus)
        }

        // Nothing to update — add fresh.
        var addAttrs = baseQuery
        addAttrs[kSecValueData] = data
        addAttrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainServiceError.osStatus(addStatus)
        }
    }

    /// Delete the API key for `providerId`. Returns `true` iff an entry was
    /// actually removed (idempotent: missing entry returns `false` without
    /// throwing).
    @discardableResult
    public func deleteApiKey(providerId: String) throws -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: providerId,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw KeychainServiceError.osStatus(status)
    }
}
