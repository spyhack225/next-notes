import Foundation
import Security

/// One Keychain record binds the refresh token to the permissions Google actually granted.
/// Legacy raw records remain calendar-only. Tests use a process-specific service.
enum GoogleTokenStore {
    static let baseService = "ai.pivotstudio.nextnotes.google"
    static var service: String {
        SelfTest.isRunning ? baseService + ".selftest-\(ProcessInfo.processInfo.processIdentifier)" : baseService
    }
    private static let account = "refresh-token"
    private static let selectionKey = "googleAppSignInSelected"
    private static let fixtureSelection = Selection()
    private struct Grant: Codable {
        let refreshToken: String
        let scopes: [String]
    }

    static var appSignInSelected: Bool {
        get { SelfTest.isRunning ? fixtureSelection.value : UserDefaults.standard.bool(forKey: selectionKey) }
        set {
            if SelfTest.isRunning { fixtureSelection.value = newValue }
            else { UserDefaults.standard.set(newValue, forKey: selectionKey) }
        }
    }
    static var hasRefreshToken: Bool { refreshToken != nil }
    static var refreshToken: String? {
        guard let data = read() else { return nil }
        if let grant = try? JSONDecoder().decode(Grant.self, from: data) { return grant.refreshToken }
        // Old versions stored a raw refresh token, never a JSON object.
        guard data.first != UInt8(ascii: "{") else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static var grantedScopes: Set<String> {
        guard let data = read() else { return [] }
        if let grant = try? JSONDecoder().decode(Grant.self, from: data) { return Set(grant.scopes) }
        return data.first != UInt8(ascii: "{") ? [GoogleScopes.legacyCalendar] : []
    }

    @discardableResult
    static func save(refreshToken: String, grantedScopes: Set<String> = [GoogleScopes.legacyCalendar]) -> Bool {
        guard let data = try? JSONEncoder().encode(Grant(refreshToken: refreshToken, scopes: grantedScopes.sorted())) else { return false }
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            Log.calendar.error("Keychain write failed with status \(status)")
            return false
        }
        appSignInSelected = true
        return true
    }

    /// Revocation retains the selected route, so a later call cannot switch to an unrelated
    /// CLI login. Only the person's explicit Disconnect forgets that choice.
    static func clear(forgetSelection: Bool = false) {
        // Raw grants predate the preference. Preserve their route before deleting
        // the last credential evidence; a later call must still refuse a foreign login.
        if !forgetSelection, !appSignInSelected, hasRefreshToken { appSignInSelected = true }
        SecItemDelete(baseQuery as CFDictionary)
        if forgetSelection { appSignInSelected = false }
    }
    private static func read() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private final class Selection: @unchecked Sendable {
        private let lock = NSLock()
        private var selected = false
        var value: Bool {
            get { lock.withLock { selected } }
            set { lock.withLock { selected = newValue } }
        }
    }
}
