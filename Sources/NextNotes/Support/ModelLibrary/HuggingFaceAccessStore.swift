import Foundation
import LocalAuthentication
import Security

/// The optional Hugging Face access key, in this Mac's Keychain.
///
/// Deliberately the same shape as `OpenRouterKeyStore`, including the off-the-main-actor
/// read and the cached result: a Security-framework lookup can block for as long as the
/// keychain takes to authorize, and doing that on the UI actor is what makes a settings tab
/// appear to hang when it opens. There is no legacy item to migrate — this key never existed
/// in the old macOS keychain — so the query is data-protection only.
///
/// Most people will never need a key at all. It is asked for exactly twice: when a repo is
/// gated, and when the Hub answers 401 to a download.
enum HuggingFaceAccessStore {
    private static let service = "ai.pivotstudio.nextnotes.huggingface"
    private static let account = "access-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// Synchronous read. Never call this from the main actor — see `keyAsync`.
    static var key: String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let text = String(data: data, encoding: .utf8)
        return (text?.isEmpty ?? true) ? nil : text
    }

    @MainActor private static var cachedKey: String?
    @MainActor private static var didReadKey = false
    @MainActor private static var waiters: [CheckedContinuation<String?, Never>] = []
    @MainActor private static var generation = 0

    @MainActor static func invalidateCache() {
        generation &+= 1
        cachedKey = nil
        didReadKey = false
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: nil) }
    }

    @MainActor
    static func keyAsync() async -> String? {
        if didReadKey { return cachedKey }
        return await withCheckedContinuation { waiter in
            waiters.append(waiter)
            guard waiters.count == 1 else { return }
            let current = generation
            DispatchQueue.global(qos: .userInitiated).async {
                let result = key
                Task { @MainActor in
                    guard generation == current else { return }
                    cachedKey = result
                    didReadKey = true
                    let pending = waiters
                    waiters = []
                    for waiter in pending { waiter.resume(returning: result) }
                }
            }
        }
    }

    @MainActor
    static func hasKeyAsync() async -> Bool { await keyAsync() != nil }

    static func saveAsync(_ value: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try save(value)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func clearAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try clear()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HuggingFaceError.needsAccessKey }
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: Data(trimmed.utf8)]
            let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainWriteError(status: Int(updated)) }
        } else if status != errSecSuccess {
            throw KeychainWriteError(status: Int(status))
        }
    }

    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainWriteError(status: Int(status))
        }
    }

    /// Where a person gets one. Linked from the "Paste your access key" sheet.
    static let keyPageURL = URL(string: "https://huggingface.co/settings/tokens")!
}

struct KeychainWriteError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        "This Mac's Keychain would not save the key (error \(status))."
    }
}
