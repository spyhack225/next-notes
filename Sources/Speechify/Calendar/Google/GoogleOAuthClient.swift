import AppKit
import CryptoKit
import Foundation
import Network

/// The Google sign-in flow for a desktop app.
///
/// Google's "Desktop app" client type only accepts a **loopback** redirect
/// (`http://127.0.0.1:<port>/callback`), which is why this opens the system browser and
/// listens on a socket rather than using `ASWebAuthenticationSession`: that API needs a
/// custom scheme or an HTTPS universal link, and Google issues neither to desktop clients.
///
/// Google's token endpoint still asks an installed client for the `client_secret` printed
/// beside its client ID, so PKCE (S256) is layered on top rather than substituted for it:
/// the secret is public by construction — it ships inside every copy of an app that has one
/// — and PKCE is what actually binds the code to this process. The secret is sent only when
/// the user has one, so a client type that genuinely doesn't need it still works.
///
/// The listener binds *before* the browser opens: opening first is a race where the user is
/// fast enough to be redirected to a port nothing is listening on.
enum GoogleOAuthClient {
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    /// How long the browser tab is given before the listener gives the port back.
    ///
    /// Five minutes covers picking an account and consenting; leaving it open forever
    /// would leave a socket bound for the life of the app after the user gave up.
    static let timeout: Duration = .seconds(300)

    /// Runs the whole flow and returns the refresh token, having already stored it.
    @discardableResult
    static func signIn(clientID: String, clientSecret: String) async throws -> String {
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw GoogleCalendarError.noClientID
        }

        let verifier = randomURLSafeString(length: 64)
        let challenge = codeChallenge(for: verifier)
        let state = randomURLSafeString(length: 24)

        let listener = LoopbackCallbackListener()
        let port = try await listener.bind()
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        guard let authorizationURL = authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            challenge: challenge,
            state: state
        ) else {
            listener.cancel()
            throw GoogleCalendarError.badAuthorizationURL
        }

        Log.calendar.info("opening Google consent on loopback port \(port, privacy: .public)")
        NSWorkspace.shared.open(authorizationURL)

        let code: String
        do {
            code = try await listener.awaitCode(state: state, timeout: timeout)
        } catch {
            listener.cancel()
            throw error
        }
        listener.cancel()

        let token = try await exchange(
            code: code,
            verifier: verifier,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI
        )
        guard let refreshToken = token.refreshToken else {
            // Google only re-issues a refresh token when consent is requested explicitly,
            // which `prompt=consent` does. Missing one here means an already-consented
            // account returned only an access token, and the app would be signed out again
            // in an hour.
            throw GoogleCalendarError.noRefreshToken
        }
        GoogleTokenStore.save(refreshToken: refreshToken)
        return refreshToken
    }

    /// Trades the stored refresh token for a fresh access token.
    static func refresh(
        clientID: String,
        clientSecret: String,
        refreshToken: String
    ) async throws -> GoogleTokenResponse {
        try await postForm(to: tokenEndpoint, fields: withSecret(clientSecret, in: [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]))
    }

    // MARK: - Internals

    private static func exchange(
        code: String,
        verifier: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String
    ) async throws -> GoogleTokenResponse {
        try await postForm(to: tokenEndpoint, fields: withSecret(clientSecret, in: [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]))
    }

    /// An empty secret is left out rather than sent blank: Google reads a present-but-empty
    /// `client_secret` as a wrong one and answers `invalid_client`.
    private static func withSecret(
        _ secret: String,
        in fields: [String: String]
    ) -> [String: String] {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fields }
        var fields = fields
        fields["client_secret"] = trimmed
        return fields
    }

    private static func postForm(
        to endpoint: String,
        fields: [String: String]
    ) async throws -> GoogleTokenResponse {
        guard let url = URL(string: endpoint) else { throw GoogleCalendarError.badAuthorizationURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(fields).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let failure = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data)
            throw GoogleCalendarError.tokenRequestFailed(
                status: status,
                reason: failure?.errorDescription ?? failure?.error ?? "HTTP \(status)"
            )
        }
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }

    private static func authorizationURL(
        clientID: String,
        redirectURI: String,
        challenge: String,
        state: String
    ) -> URL? {
        var components = URLComponents(string: authorizationEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Offline plus an explicit consent screen is the only combination that reliably
            // returns a refresh token; without `prompt`, a second sign-in with the same
            // account silently returns none.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    private static func formEncoded(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { "\(percentEncoded($0.key))=\(percentEncoded($0.value))" }
            .joined(separator: "&")
    }

    /// `URLComponents` would leave `+` and `&` intact inside a form value; a code verifier
    /// containing either would then arrive at Google as two fields.
    private static func percentEncoded(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    /// base64url(SHA-256(verifier)), unpadded — exactly what RFC 7636's S256 asks for.
    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The one-shot HTTP listener the browser is redirected back to.
///
/// `@unchecked Sendable` with a lock rather than an actor: `NWListener` delivers its
/// callbacks on a dispatch queue, and the continuation they resume has to be reachable
/// from there without an `await`.
private final class LoopbackCallbackListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.pivotstudio.speechify.oauth-callback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<String, any Error>?
    /// Set when the redirect lands before anyone is waiting on it — which is possible, if
    /// unlikely, because binding and awaiting are two separate calls.
    private var pending: Result<String, any Error>?
    private var isFinished = false

    /// Binds an ephemeral loopback port and returns it.
    ///
    /// The port is chosen here and required explicitly rather than asking for `.any`,
    /// because a listener bound with `requiredLocalEndpoint` reports the endpoint it was
    /// asked for — so `.any` would leave nothing to put in the redirect URI. Collisions in
    /// the ephemeral range are rare and simply retried.
    func bind(attempts: Int = 8) async throws -> UInt16 {
        var lastError: (any Error)?
        for _ in 0..<attempts {
            let candidate = UInt16.random(in: 49152...65535)
            do {
                return try await bind(to: candidate)
            } catch {
                // Kept and logged rather than discarded. Eight silent `try?` failures in a
                // row produced one generic "couldn't listen on this Mac", which is true and
                // useless: a port collision and a refused permission look identical from
                // the outside, and only one of them is worth retrying.
                lastError = error
                // The failed listener was already stored and started; without this each
                // retry leaks one that goes on retrying for the life of the process.
                cancel()
            }
        }
        if let lastError {
            Log.calendar.error("loopback bind failed \(attempts) times, last: \(lastError.localizedDescription, privacy: .public)")
        }
        throw GoogleCalendarError.callbackListenerFailed
    }

    private func bind(to port: UInt16) async throws -> UInt16 {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw GoogleCalendarError.callbackListenerFailed
        }
        let parameters = NWParameters.tcp
        // Loopback only. Google accepts any 127.0.0.1 port, and a listener on 0.0.0.0
        // would accept an authorization code from anything on the network.
        //
        // The port is carried *only* by `requiredLocalEndpoint`. Passing it again as
        // `NWListener(using:on:)` states the same thing twice, and the two are not merged:
        // the framework can bind the `on:` port while still holding the endpoint
        // requirement, and the listener then sits in `.waiting` instead of coming ready.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let hasResumed = ResumeGuard()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if hasResumed.claim() { continuation.resume(returning: port) }
                case .failed(let error):
                    if hasResumed.claim() { continuation.resume(throwing: error) }
                // `.waiting` on a listener means the port is taken. It would retry forever
                // on its own, so it is reported as a bind failure and a new port is tried.
                case .waiting(let error):
                    if hasResumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to arrive with a code, or gives up.
    ///
    /// The timeout is a deadline on the listener's own queue rather than a second task
    /// racing the first. A task group would have to *cancel* the waiting child to finish,
    /// and that child is parked on a continuation only `finish(with:)` ever resumes — so
    /// the group would wait forever for a child that has nothing to cancel, and the whole
    /// sign-in (and the actor that started it) would hang for the life of the process.
    /// `finish` is one-shot and lock-guarded, so whichever of the deadline, the redirect
    /// and cancellation gets there first is the answer.
    func awaitCode(state expected: String, timeout: Duration) async throws -> String {
        setExpectedState(expected)
        queue.asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds))) { [weak self] in
            self?.finish(with: .failure(GoogleCalendarError.authorizationTimedOut))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pending {
                    self.pending = nil
                    lock.unlock()
                    continuation.resume(with: pending)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            self.finish(with: .failure(CancellationError()))
        }
    }

    func cancel() {
        lock.lock()
        let listener = self.listener
        let connections = self.connections
        self.listener = nil
        self.connections = []
        lock.unlock()

        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    // MARK: - Connection handling

    /// Guarded by `lock`: written by `awaitCode` on the caller's task, read by a
    /// connection callback on the listener's queue.
    private var expectedState: String?

    /// A synchronous shim: taking a lock directly in an `async` function is refused, and
    /// rightly — the suspension in between would hold it across an await. This one can't.
    private func setExpectedState(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        expectedState = value
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()

        connection.start(queue: queue)
        // One redirect is one small GET; it always fits in a single receive.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // A favicon request or a stray probe returns nil: it is not the redirect,
            // and abandoning the flow over it would strand a user who is still consenting.
            guard let outcome = self.outcome(forRequestLine: request) else {
                connection.cancel()
                return
            }
            self.reply(on: connection, success: outcome.isSuccess)
            self.finish(with: outcome)
        }
    }

    /// `nil` means "this wasn't the redirect" — keep listening.
    private func outcome(forRequestLine request: String) -> Result<String, any Error>? {
        // "GET /callback?code=…&state=… HTTP/1.1"
        guard let line = request.split(separator: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)")
        else {
            return .failure(GoogleCalendarError.callbackListenerFailed)
        }

        let items = components.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        // The browser also asks for /favicon.ico while the consent page is open.
        guard components.path == "/callback" else { return nil }
        if let error = value("error") {
            return .failure(GoogleCalendarError.authorizationDenied(error))
        }
        // State is what stops another local process from feeding its own code into this
        // listener while the browser is open.
        lock.lock()
        let expected = expectedState
        lock.unlock()
        guard let state = value("state"), state == expected else {
            return .failure(GoogleCalendarError.stateMismatch)
        }
        guard let code = value("code"), !code.isEmpty else {
            return .failure(GoogleCalendarError.callbackListenerFailed)
        }
        return .success(code)
    }

    private func reply(on connection: NWConnection, success: Bool) {
        let title = success ? "Speechify is connected" : "Sign-in didn’t finish"
        let body = success
            ? "You can close this tab and go back to Speechify."
            : "Nothing was connected. Try again from Speechify’s Calendar settings."
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>\
            <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:4rem">\
            <h1>\(title)</h1><p>\(body)</p></body></html>
            """
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(with outcome: Result<String, any Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = outcome }
        lock.unlock()

        continuation?.resume(with: outcome)
    }
}

/// One-shot claim on a continuation, for callbacks that can fire more than once.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
