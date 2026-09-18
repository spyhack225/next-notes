import AppKit
import Foundation

/// Browser sign-in for Composio For You — the same device-link flow the CLI uses.
///
/// 1. `POST /api/v3.1/cli/create-session` with `scope: user`
/// 2. Open `https://dashboard.composio.dev/?cliKey=<id>`
/// 3. Poll `GET /api/v3.1/cli/get-session?id=<id>` until `status == linked`
/// 4. Persist `api_key` in the Keychain
///
/// Non-technical users never see a consumer key. Pasting one stays as an advanced
/// fallback on the Integrations tab.
enum ComposioBrowserAuth {
    static let backendURL = URL(string: "https://backend.composio.dev/api/v3.1")!
    static let dashboardURL = URL(string: "https://dashboard.composio.dev/")!

    enum Limits {
        static let pollInterval: Duration = .seconds(1)
        static let timeout: Duration = .seconds(600)
    }

    struct PendingSession: Sendable, Equatable {
        var id: String
        var loginURL: URL
        var expiresAt: Date?
    }

    struct LinkedSession: Sendable, Equatable {
        var id: String
        var apiKey: String
        var orgID: String?
    }

    enum AuthError: LocalizedError, Equatable {
        case createFailed(String)
        case expired
        case timedOut
        case cancelled
        case missingAPIKey
        case unexpectedStatus(String)

        var errorDescription: String? {
            switch self {
            case .createFailed(let detail):
                return "Could not start Composio sign-in. \(detail)"
            case .expired:
                return "That Composio sign-in link expired. Try Sign in again."
            case .timedOut:
                return "Composio sign-in timed out. Open the link and click Authorize, then try again."
            case .cancelled:
                return "Composio sign-in was cancelled."
            case .missingAPIKey:
                return "Composio authorised the session but returned no API key."
            case .unexpectedStatus(let status):
                return "Composio sign-in is still “\(status)”. Finish Authorize in the browser."
            }
        }
    }

    /// Creates a pending CLI session and returns the browser URL to authorize.
    static func begin() async throws -> PendingSession {
        var request = URLRequest(url: backendURL.appendingPathComponent("cli/create-session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": "user"])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.createFailed("HTTP \(status)\(body.isEmpty ? "" : ": \(body.prefix(160))")")
        }

        guard let session = parsePendingSession(data) else {
            throw AuthError.createFailed("The create-session response had no session id.")
        }
        return session
    }

    static func openBrowser(for session: PendingSession) {
        NSWorkspace.shared.open(session.loginURL)
    }

    /// Polls until the browser Authorize step links the session, then returns the API key.
    static func waitUntilLinked(
        _ session: PendingSession,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> LinkedSession {
        let deadline = ContinuousClock.now + Limits.timeout
        while ContinuousClock.now < deadline {
            if isCancelled() { throw AuthError.cancelled }
            if let expiresAt = session.expiresAt, expiresAt < Date() {
                throw AuthError.expired
            }

            switch try await fetchStatus(id: session.id) {
            case .linked(let linked):
                return linked
            case .pending:
                try await Task.sleep(for: Limits.pollInterval)
            case .expired:
                throw AuthError.expired
            }
        }
        throw AuthError.timedOut
    }

    /// Full product path: create → open browser → wait → Keychain.
    @MainActor
    static func signIn() async throws -> LinkedSession {
        let pending = try await begin()
        openBrowser(for: pending)
        let linked = try await waitUntilLinked(pending)
        try ComposioCredentialStore.save(apiKey: linked.apiKey)
        Settings.shared.composioEnabled = true
        // Prefer Keychain; clear any leftover plaintext paste from an older build.
        Settings.shared.composioAPIKey = ""
        return linked
    }

    // MARK: - Parsing (kept free of network so self-tests can drive it)

    static func parsePendingSession(_ data: Data) -> PendingSession? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let root = unwrapData(object)
        guard let id = string(root, "id") ?? string(root, "key"), !id.isEmpty else {
            return nil
        }
        var components = URLComponents(url: dashboardURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "cliKey", value: id)]
        guard let loginURL = components?.url else { return nil }
        return PendingSession(
            id: id,
            loginURL: loginURL,
            expiresAt: date(root, "expires_at") ?? date(root, "expiresAt")
        )
    }

    enum PollResult: Equatable {
        case pending
        case linked(LinkedSession)
        case expired
    }

    static func parsePollResult(_ data: Data, expectedID: String) -> PollResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .pending
        }
        let root = unwrapData(object)
        let status = (string(root, "status") ?? "").lowercased()
        if status == "expired" || status == "revoked" {
            return .expired
        }
        if status == "linked" || status == "authorized" || status == "completed" {
            let apiKey = string(root, "api_key")
                ?? string(root, "apiKey")
                ?? string(root, "user_api_key")
                ?? string(root, "consumer_api_key")
            guard let apiKey, !apiKey.isEmpty else {
                return .pending
            }
            return .linked(LinkedSession(
                id: string(root, "id") ?? expectedID,
                apiKey: apiKey,
                orgID: string(root, "org_id") ?? string(root, "orgId")
            ))
        }
        // Some responses omit status and only set the key once linked.
        if let apiKey = string(root, "api_key") ?? string(root, "apiKey"), !apiKey.isEmpty {
            return .linked(LinkedSession(
                id: string(root, "id") ?? expectedID,
                apiKey: apiKey,
                orgID: string(root, "org_id") ?? string(root, "orgId")
            ))
        }
        return .pending
    }

    private static func fetchStatus(id: String) async throws -> PollResult {
        var components = URLComponents(
            url: backendURL.appendingPathComponent("cli/get-session"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components?.url else {
            throw AuthError.createFailed("Bad get-session URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 {
            throw AuthError.expired
        }
        guard (200...299).contains(code) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.createFailed("HTTP \(code)\(body.isEmpty ? "" : ": \(body.prefix(160))")")
        }
        return parsePollResult(data, expectedID: id)
    }

    private static func unwrapData(_ object: [String: Any]) -> [String: Any] {
        if let nested = object["data"] as? [String: Any] { return nested }
        return object
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        if let value = object[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func date(_ object: [String: Any], _ key: String) -> Date? {
        guard let raw = string(object, key) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }
}
