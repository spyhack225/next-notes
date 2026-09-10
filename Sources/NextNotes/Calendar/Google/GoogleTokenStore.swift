import Foundation
import Security

/// The Google refresh token, in the login Keychain.
///
/// A refresh token is a long-lived credential for the user's calendar — it belongs in the
/// Keychain rather than in `UserDefaults`, where every process the user runs could read it
/// out of a plist. The client ID stays in defaults: desktop OAuth clients are public by
/// design, which is the whole reason the flow uses PKCE.
///
/// Access tokens are never stored. They last an hour, and asking for a new one costs one
/// HTTP round trip against a token the Keychain already holds.
enum GoogleTokenStore {
    static let service = "ai.pivotstudio.nextnotes.google"
    private static let account = "refresh-token"

    static var hasRefreshToken: Bool { refreshToken != nil }

    static var refreshToken: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.calendar.error("Keychain read failed with status \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces whatever is stored. Written as delete-then-add rather than `SecItemUpdate`
    /// so that a partially written or duplicated entry from an earlier version is replaced
    /// rather than merged with.
    static func save(refreshToken: String) {
        clear()
        var query = baseQuery
        query[kSecValueData as String] = Data(refreshToken.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Log.calendar.error("Keychain write failed with status \(status)")
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
