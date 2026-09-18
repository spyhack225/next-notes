import Foundation
import Security

/// Composio consumer credential in the Keychain.
///
/// The browser sign-in flow lands a key here so Settings never asks a person to
/// dig `ck_…` out of a dashboard. A pasted advanced key is migrated into the
/// same place so MCP headers always read one source.
enum ComposioCredentialStore {
    static let service = "ai.pivotstudio.nextnotes.composio"
    private static let account = "consumer-api-key"

    static var hasCredential: Bool { apiKey != nil }

    static var apiKey: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.agent.error("Composio Keychain read failed with status \(status)")
            }
            return nil
        }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func save(apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentError.backendUnavailable("Composio returned an empty API key.")
        }
        clear()
        var query = baseQuery
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AgentError.backendUnavailable("Could not save the Composio key in Keychain (\(status)).")
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
