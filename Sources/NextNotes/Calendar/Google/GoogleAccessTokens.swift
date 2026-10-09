import Foundation

/// Calendar and Workspace share this existing grant and one refresh in flight.
actor GoogleAccessTokens {
    static let shared = GoogleAccessTokens()
    private(set) var endpoints: GoogleOAuthClient.Endpoints = .google
    private var clientOverride: GoogleAppClient?
    var currentClient: GoogleAppClient? { clientOverride ?? GoogleAppClient.current }
    func useEndpoints(_ value: GoogleOAuthClient.Endpoints) {
        guard Self.testHooksAdmitted else { return }
        endpoints = value
        invalidate()
    }
    func useClient(_ value: GoogleAppClient?) {
        guard Self.testHooksAdmitted else { return }
        clientOverride = value
        invalidate()
    }
    nonisolated static var testHooksAdmitted: Bool {
        hooksAdmitted(isRunning: SelfTest.isRunning, requested: SelfTest.requested)
    }
    nonisolated static func hooksAdmitted(isRunning: Bool, requested: String?) -> Bool {
        isRunning && requested == "--selftest-google-connect"
    }

    private var rejectedTokenObserverForTesting: (@Sendable () -> Void)?
    func observeRejectedTokenForTesting(_ observer: (@Sendable () -> Void)?) {
        precondition(Self.testHooksAdmitted)
        rejectedTokenObserverForTesting = observer
    }
    private var requestOverrideForTesting: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    func useRequestForTesting(_ request: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?) {
        precondition(Self.testHooksAdmitted)
        requestOverrideForTesting = request
        invalidate()
    }
    private let requestForTesting: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    private let refreshTokenForTesting: (@Sendable () -> String?)?
    private let clearTokenForTesting: (@Sendable () -> Void)?
    init(
        requestForTesting: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        refreshTokenForTesting: (@Sendable () -> String?)? = nil,
        clearTokenForTesting: (@Sendable () -> Void)? = nil
    ) {
        let injected = requestForTesting != nil || refreshTokenForTesting != nil || clearTokenForTesting != nil
        precondition(!injected || ((GoogleCalendarErrorSelfTest.isRequested || Self.testHooksAdmitted)
            && requestForTesting != nil && refreshTokenForTesting != nil && clearTokenForTesting != nil))
        self.requestForTesting = requestForTesting
        self.refreshTokenForTesting = refreshTokenForTesting
        self.clearTokenForTesting = clearTokenForTesting
    }
    private struct Identity: Equatable, Sendable {
        let clientID: String
        let secret: String
        let refresh: String
        let grantIdentity: Data?
    }
    private var cached: (identity: Identity, token: String, expiry: Date)?
    private var inFlight: (id: UUID, identity: Identity, task: Task<String, any Error>)?
    private var generation = 0
    private(set) var refreshCount = 0

    func token(clientID: String, clientSecret: String) async throws -> String {
        try Task.checkCancellation()
        let grant = refreshTokenForTesting == nil ? try GoogleTokenStore.savedGrant() : nil
        let refresh = refreshTokenForTesting?() ?? grant?.refreshToken
        guard let refresh else { throw GoogleCalendarError.notSignedIn }
        let identity = Identity(clientID: clientID, secret: clientSecret, refresh: refresh, grantIdentity: grant?.identity)
        if let cached, cached.identity == identity, cached.expiry > Date().addingTimeInterval(60) { return cached.token }
        if let inFlight, inFlight.identity == identity {
            let token = try await inFlight.task.value
            try Task.checkCancellation()
            return token
        }
        if inFlight != nil { invalidate() }
        let started = generation
        let requestID = UUID()
        let endpoint = endpoints.token
        let task = Task<String, any Error> {
            do {
                let response = try await GoogleOAuthClient.refresh(
                    clientID: clientID, clientSecret: clientSecret, refreshToken: refresh,
                    endpoint: endpoint, requestForTesting: requestOverrideForTesting ?? requestForTesting)
                guard generation == started, !Task.isCancelled, try isCurrent(identity) else { throw CancellationError() }
                cached = (identity, response.accessToken, Date().addingTimeInterval(TimeInterval(response.expiresIn)))
                refreshCount += 1
                return response.accessToken
            } catch GoogleCalendarError.tokenRequestFailed(let status, _, let code)
                where status == 400 && code == "invalid_grant" {
                guard generation == started else { throw CancellationError() }
                if let clearTokenForTesting {
                    guard refreshTokenForTesting?() == identity.refresh else { throw CancellationError() }
                    clearTokenForTesting()
                } else {
                    guard let grantIdentity = identity.grantIdentity,
                          try GoogleTokenStore.clear(ifMatching: grantIdentity) else { throw CancellationError() }
                }
                invalidate()
                throw GoogleCalendarError.accessRevoked
            }
        }
        inFlight = (requestID, identity, task)
        defer { if inFlight?.id == requestID { inFlight = nil } }
        let token = try await task.value
        // A shared refresh survives one cancelled waiter, but its result must not
        // carry that waiter into executable backing after cancellation.
        try Task.checkCancellation()
        return token
    }
    private func isCurrent(_ identity: Identity) throws -> Bool {
        if let refreshTokenForTesting { return refreshTokenForTesting() == identity.refresh }
        return try GoogleTokenStore.savedGrant()?.identity == identity.grantIdentity
    }
    /// No suspension between the existing record replacement and cache/refresh invalidation.
    func replaceGrant(refreshToken: String, scopes: Set<String>) throws {
        guard GoogleTokenStore.save(refreshToken: refreshToken, grantedScopes: scopes) else { throw GoogleCalendarError.tokenStoreFailed }
        invalidate()
    }
    func disconnectGrant() {
        GoogleTokenStore.clear(forgetSelection: true)
        invalidate()
    }
    func invalidate(rejectedToken: String) {
        defer { rejectedTokenObserverForTesting?() }
        // A late 401 for A has no authority over a refresh already replacing A.
        guard cached?.token == rejectedToken else { return }
        cached = nil
    }
    func invalidate() {
        generation += 1
        cached = nil
        inFlight?.task.cancel()
        inFlight = nil
    }
    func workspaceToken() async throws -> String? {
        let grant = try GoogleTokenStore.savedGrant()
        guard let client = currentClient, grant != nil else {
            throw GoogleCalendarError.notSignedIn
        }
        return try await token(clientID: client.clientID, clientSecret: client.clientSecret)
    }
}
