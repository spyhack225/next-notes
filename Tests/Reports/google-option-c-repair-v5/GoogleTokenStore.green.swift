import Foundation
import Security

/// One Keychain record binds the refresh token to the permissions Google actually granted.
/// Legacy raw records remain calendar-only. Tests use a process-specific service.
enum GoogleTokenStore {
    static let baseService = "ai.pivotstudio.nextnotes.google"
    static var service: String {
        SelfTest.isRunning ? baseService + ".selftest-\(ProcessInfo.processInfo.processIdentifier)" : baseService
    }
    // Credential-free change notification from the record producer, including direct
    // saves/deletes and refresh revocation. No Calendar entry point owns this transition.
    static let grantDidChange = Notification.Name("NextNotesGoogleGrantDidChange")
    private static let account = "refresh-token"
    private static let selectionKey = "googleAppSignInSelected"
    private static let fixtureSelection = Selection()
    // The existing record owns read/write admission. Never turn a failed read into absence.
    private static let lock = NSRecursiveLock()
    struct StoredGrant: Sendable, Equatable {
        let refreshToken: String
        let scopes: Set<String>
        let identity: Data
    }
    enum ReadState: Sendable, Equatable {
        case absent
        case available(StoredGrant)
        case unavailable
    }
    private static let fixtureRead = ReadFixture()
    static func useReadStatusForTesting(_ status: OSStatus?) {
        precondition(GoogleAccessTokens.testHooksAdmitted)
        fixtureRead.status = status
    }
    static var readState: ReadState { lock.withLock { read() } }
    static var appRouteInEffect: Bool {
        if appSignInSelected { return true }
        // An unreadable record is not evidence that another account may be used.
        return readState != .absent
    }
    static func savedGrant() throws -> StoredGrant? {
        switch readState {
        case .absent: return nil
        case .available(let grant): return grant
        case .unavailable: throw GoogleCalendarError.tokenStoreUnreadable
        }
    }
    private struct Grant: Codable {
        let refreshToken: String
        let scopes: [String]
        let generation: UUID?
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
        guard case .available(let grant) = readState else { return nil }
        return grant.refreshToken
    }
    static var grantedScopes: Set<String> {
        guard case .available(let grant) = readState else { return [] }
        return grant.scopes
    }

    @discardableResult
    static func save(refreshToken: String, grantedScopes: Set<String> = [GoogleScopes.legacyCalendar]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(Grant(refreshToken: refreshToken, scopes: grantedScopes.sorted(), generation: UUID())) else { return false }
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
        NotificationCenter.default.post(name: grantDidChange, object: nil)
        return true
    }

    /// Revocation retains the selected route, so a later call cannot switch to an unrelated
    /// CLI login. Only the person's explicit Disconnect forgets that choice.
    static func clear(forgetSelection: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        // Raw grants predate the preference. Preserve their route before deleting
        // the last credential evidence; a later call must still refuse a foreign login.
        if !forgetSelection, !appSignInSelected, hasRefreshToken { appSignInSelected = true }
        let status = SecItemDelete(baseQuery as CFDictionary)
        if forgetSelection { appSignInSelected = false }
        if status == errSecSuccess || status == errSecItemNotFound {
            NotificationCenter.default.post(name: grantDidChange, object: nil)
        }
    }
    /// Compare and delete while holding the same admission as save/read. A stale refresh
    /// cannot revoke a replacement, including one with the same refresh-token text.
    static func clear(ifMatching identity: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let grant = try savedGrant(), grant.identity == identity else { return false }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GoogleCalendarError.tokenStoreFailed }
        NotificationCenter.default.post(name: grantDidChange, object: nil)
        return true
    }
    /// Launch admission shares replacement's lock: the admitted grant cannot change
    /// between the identity comparison and process.run(). No actor hop under this lock.
    static func withMatchingGrant(_ identity: Data, _ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard try savedGrant()?.identity == identity else { throw GoogleCalendarError.signInChanged }
        try body()
    }
    private static func read() -> ReadState {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = fixtureRead.status ?? SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let data = item as? Data else { return .unavailable }
        let token: String
        let scopes: Set<String>
        if let grant = try? JSONDecoder().decode(Grant.self, from: data) {
            token = grant.refreshToken
            scopes = Set(grant.scopes)
        } else {
            guard data.first != UInt8(ascii: "{"), let raw = String(data: data, encoding: .utf8) else { return .unavailable }
            token = raw
            scopes = [GoogleScopes.legacyCalendar]
        }
        guard !token.isEmpty else { return .unavailable }
        // Adopt a readable legacy grant before its credential evidence can disappear.
        if !appSignInSelected { appSignInSelected = true }
        return .available(StoredGrant(refreshToken: token, scopes: scopes, identity: data))
    }
    private final class ReadFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OSStatus?
        var status: OSStatus? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
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
