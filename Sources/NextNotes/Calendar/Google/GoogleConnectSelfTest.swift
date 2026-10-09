import CryptoKit
import Foundation
import Network
import Security

/// `--selftest-google-connect` — PL-08 and PL-09, answered with no account, no browser, no
/// Terminal and no Google.
///
/// What it proves, through the real producers: the default path to Google never opens
/// Terminal or asks for a client; the sign-in runs end to end (loopback listener, PKCE, state
/// check, token exchange, granted scopes, Keychain, revocation) against a loopback fixture
/// that plays Google's endpoints; the managed Workspace tool is fetched, checksum-verified,
/// unpacked and run; the runner hands the tool the app's own sign-in; and first run asks no
/// technical question. What it cannot prove — a real consent page, Google's verification of
/// the restricted Gmail scopes, a real mailbox, the native views — is listed in the packet.
///
/// The token store runs under its own per-process Keychain service (`GoogleTokenStore.service`
/// under a self-test), so the owner's real sign-in is never read or replaced.
@MainActor
enum GoogleConnectSelfTest {
    static func run() async -> Bool {
        print("GOOGLE_CONNECT: first run and Google without Terminal")
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if condition {
                SelfTest.diagnostic("  ok   \(message)")
            } else {
                SelfTest.diagnostic("  FAIL \(message)")
                failures.append(message)
            }
        }
        defer { GoogleTokenStore.clear(forgetSelection: true) }
        GoogleTokenStore.clear(forgetSelection: true)

        buttonCases(expect)
        clientAndScopeCases(expect)
        plainWordsCases(expect)
        await orchestrationCases(expect)
        await signInCases(expect)
        await hardeningCases(expect)
        await toolInstallCases(expect)
        await runnerCases(expect)
        await calendarConsumerCases(expect)
        await GoogleGrantReadSelfTest.run(expect)
        await GoogleLaunchCancellationSelfTest.run(expect)
        await GoogleGrantReplacementSelfTest.run(expect)

        await GoogleAccessTokens.shared.invalidate()
        await GoogleAccessTokens.shared.useClient(nil)
        await GoogleAccessTokens.shared.useEndpoints(.google)
        if failures.isEmpty {
            SelfTest.diagnostic("GOOGLE_CONNECT_OK")
            return true
        }
        SelfTest.diagnostic("GOOGLE_CONNECT: \(failures.count) failed")
        SelfTest.diagnostic("GOOGLE_CONNECT_FAILED")
        return false
    }

    typealias Expect = (Bool, String) -> Void

    // MARK: - The button

    private static func buttonCases(_ expect: Expect) {
        expect(GoogleConnection.State.notConnected.buttonTitle(addOn: true) == "Connect Google Docs, Sheets and Drive too",
               "next to the Mac's own account the sign-in is offered for what only Google can open")
        expect(GoogleConnection.State.notConnected.buttonTitle(addOn: false) == "Connect your Google account",
               "…and on its own it is the plain \u{201C}Connect your Google account\u{201D}")
        expect(GoogleConnection.State.connected.buttonTitle(addOn: true) == "Disconnect",
               "a connected sign-in can always be disconnected")
    }

    // MARK: - Client and scopes

    private static func clientAndScopeCases(_ expect: Expect) {
        guard let scratch = UserDefaults(suiteName: "NextNotesGoogleConnect-\(ProcessInfo.processInfo.processIdentifier)") else {
            expect(false, "scratch preferences available"); return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: "NextNotesGoogleConnect-\(ProcessInfo.processInfo.processIdentifier)") }
        let real = "123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com"
        func plist(_ id: String?, secret: String = "S") -> (String) -> Any? {
            { key in key == GoogleAppClient.plistIDKey ? id : (key == GoogleAppClient.plistSecretKey ? secret : nil) }
        }
        expect(GoogleAppClient.resolve(defaults: scratch, info: plist(GoogleAppClient.placeholderID)) == nil,
               "the placeholder client reads as not configured")
        expect(GoogleAppClient.resolve(defaults: scratch, info: plist(nil)) == nil
               && GoogleAppClient.resolve(defaults: scratch, info: plist("")) == nil
               && GoogleAppClient.resolve(defaults: scratch, info: plist("not-a-client-id")) == nil,
               "a missing, blank or malformed client reads as not configured")
        let app = GoogleAppClient.resolve(defaults: scratch, info: plist(real))
        expect(app?.source == .app && app?.clientID == real && app?.clientSecret == "S",
               "a registered build client is used, with nothing for the person to paste")
        scratch.set("own.apps.googleusercontent.com", forKey: "googleClientID")
        expect(GoogleAppClient.resolve(defaults: scratch, info: plist(real))?.source == .own,
               "a person's own client still wins (the advanced route)")
        scratch.removeObject(forKey: "googleClientID")

        // The built bundle's own Info.plist: keys present, and — when this Mac holds the private
        // client file the build injects from — a real client id. Only the *shape* is read and
        // printed, never the id or the secret.
        let info = Bundle.main.infoDictionary ?? [:]
        let isBundle = Bundle.main.bundleURL.pathExtension == "app"
        if isBundle {
            expect(info[GoogleAppClient.plistIDKey] != nil && info[GoogleAppClient.plistSecretKey] != nil,
                   "the built bundle carries the two client keys")
            let shipped = GoogleAppClient.resolve(defaults: scratch, info: { info[$0] })
            expect(shipped == nil || shipped?.source == .app,
                   "the built value is the placeholder or a registered client, never a stray string")
            let privateFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NextNotesBuild/google-oauth-client.json").path
            if FileManager.default.fileExists(atPath: privateFile) {
                let id = (info[GoogleAppClient.plistIDKey] as? String) ?? ""
                expect(GoogleAppClient.isRegisteredID(id) && ((info[GoogleAppClient.plistSecretKey] as? String)?.isEmpty == false),
                       "the private client file is present, so the build injected an id ending in .apps.googleusercontent.com and a secret")
            } else {
                SelfTest.diagnostic("  note the private client file is absent on this Mac, so the placeholder is expected")
            }
        } else {
            SelfTest.diagnostic("  note not run from a built .app, so the bundled client keys are not checked")
        }

        // Scopes (owner decision, 2026-10-04): one list, the whole Workspace set, asked once.
        let ownerScopes: Set<String> = [
            "gmail.modify", "calendar", "drive", "documents", "spreadsheets", "presentations", "tasks", "contacts", "forms.body",
        ].reduce(into: []) { $0.insert("https://www.googleapis.com/auth/" + $1) }
        expect(Set(GoogleScopes.connect) == ownerScopes, "the sign-in asks for the full Workspace set and nothing else")
        expect(GoogleScopes.connect.count == Set(GoogleScopes.connect).count, "no scope is asked for twice")
        expect(Set(GoogleCapability.allCases.map(\.scope)) == Set(GoogleScopes.connect),
               "there is one scope list: every capability is backed by exactly one of its scopes")
        expect(Set(GoogleScopes.required).isSubset(of: Set(GoogleScopes.connect)), "the sign-in asks for what mail and calendar need")
        expect(!GoogleScopes.coversWorkspace([GoogleScopes.legacyCalendar]), "a calendar-only sign-in does not cover mail")
        expect(!GoogleScopes.coversCalendar([]) && GoogleScopes.coversCalendar([GoogleScopes.legacyCalendar]),
               "an older calendar-only sign-in still reads the calendar")
        // A box unticked on Google's page: every mapped capability, and only that one,
        // is withheld by the actual manifest builder. Grants for future tools remain recorded.
        let tools = AgentToolRegistry.shared.tools(upTo: .privileged)
        let reader = AgentCapabilityManifest.Reader(provider: .appLLM, displayName: "Fixture", contextTokens: 8_192)
        for capability in GoogleCapability.allCases {
            let partial = Set(GoogleScopes.connect).subtracting([capability.scope])
            var inputs = AgentCapabilityInputs.allEnabled(tools: tools, reader: reader)
            inputs.workspaceGaps = GoogleSource.scopeGaps(granted: partial, tools: GoogleSource.allTools)
            let manifest = AgentCapabilityManifestBuilder.build(inputs, request: "help with my Google account")
            for tool in GoogleSource.allTools {
                let expected: AgentCapabilityManifest.Readiness = GoogleCapability.needed(byTool: tool) == capability
                    ? .needsSetup(capability.permissionSentence) : .ready
                let observed = (manifest.allowed + manifest.unavailable).first { $0.id == tool }?.readiness
                expect(observed == expected && (manifest.entry(named: tool) != nil) == expected.isReady,
                       "unticking \(capability.rawValue) changes only its tools in the real manifest (\(tool))")
            }
        }
        // A box unticked on Google's page: that capability, and only that one, is named.
        let withoutDrive = Set(GoogleScopes.connect).subtracting([GoogleScopes.drive])
        let gaps = GoogleSource.scopeGaps(granted: withoutDrive, tools: GoogleSource.allTools)
        expect(Set(gaps.keys) == ["find_drive_files", "upload_to_drive"],
               "an unticked Drive box makes the Drive tools need setup and nothing else: \(gaps.keys.sorted())")
        expect(gaps["find_drive_files"]?.hasPrefix("Google Drive needs one more permission") == true,
               "…in one plain sentence: \(gaps["find_drive_files"] ?? "")")
        expect(GoogleSource.scopeGaps(granted: Set(GoogleScopes.connect), tools: GoogleSource.allTools).isEmpty,
               "everything ticked: no gap")
        expect(!GoogleSource.scopeGaps(granted: [GoogleScopes.mail, GoogleScopes.calendar], tools: GoogleSource.allTools).isEmpty
               && GoogleScopes.coversWorkspace([GoogleScopes.mail, GoogleScopes.calendar]),
               "mail and calendar alone still connect, with Docs and Drive marked as needing setup")
        let url = GoogleOAuthClient.authorizationURL(
            clientID: "c", redirectURI: "http://127.0.0.1:50000/callback", challenge: "ch", state: "st",
            scopes: GoogleScopes.connect)
        let items = URLComponents(url: url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        expect(value("scope") == GoogleScopes.connect.joined(separator: " "), "the consent page is asked for exactly those scopes")
        expect(value("code_challenge_method") == "S256" && value("access_type") == "offline" && value("prompt") == "consent",
               "PKCE S256, offline, explicit consent")
        expect(value("redirect_uri")?.hasPrefix("http://127.0.0.1:") == true && value("client_secret") == nil,
               "loopback redirect; no secret in the browser URL")

        let states: [(Bool, Bool, Set<String>, WorkspaceAuthState, GoogleConnection.State)] = [
            (false, false, [], .notInstalled, .unavailable),
            (true, false, [], .notInstalled, .notConnected),
            (true, true, Set(GoogleScopes.connect), .notInstalled, .gettingReady),
            (true, true, Set(GoogleScopes.connect), .signedIn(method: "x"), .connected),
            (true, true, [GoogleScopes.legacyCalendar], .signedOut, .needsMoreAccess),
            (true, true, [GoogleScopes.mail, GoogleScopes.calendar], .notInstalled, .gettingReady),
            (false, false, [], .signedIn(method: "x"), .connected),
        ]
        for (index, row) in states.enumerated() {
            let derived = GoogleConnection.derive(
                clientConfigured: row.0, hasToken: row.1, grantedScopes: row.2, workspace: row.3)
            expect(derived == row.4, "state row \(index) is \(row.4): \(derived)")
        }
    }

    // MARK: - Plain words

    private static func plainWordsCases(_ expect: Expect) {
        let banned = UIStringsLint.technicalWords + ["cli", "scope", "client", "api"]
        var spoken: [String] = []
        let states: [GoogleConnection.State] = [
            .unavailable, .notConnected, .connecting, .gettingReady, .connected, .needsMoreAccess,
        ]
        for state in states {
            spoken += [state.label, state.detail, state.buttonTitle, state.buttonTitle(addOn: true), state.detail(addOn: true)]
        }
        spoken += GoogleSource.scopeGaps(granted: [], tools: GoogleSource.allTools).values
        spoken += [WorkspaceAuthState.notInstalled, .needsOAuthClient, .signedOut, .signedIn(method: "x"), .failed("y")]
            .flatMap { [$0.displayName, $0.detail] }
        spoken += [
            ManagedWorkspaceTool.Failure.couldNotFetch, .damaged, .wouldNotRun,
        ].compactMap(\.errorDescription)
        spoken += [
            GoogleCalendarError.noClientID, .notSignedIn, .accessRevoked, .noRefreshToken,
            .callbackListenerFailed, .authorizationTimedOut, .authorizationDenied("access_denied"), .stateMismatch,
        ].compactMap(\.errorDescription)
        spoken += [WorkspaceCLIError.notInstalled, .notAuthenticated].compactMap(\.errorDescription)
        for text in spoken {
            for word in banned where text.lowercased().range(
                of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "s?\\b", options: .regularExpression) != nil {
                expect(false, "plain words: \u{201C}\(text)\u{201D} says \u{201C}\(word)\u{201D}")
            }
        }
        expect(spoken.allSatisfy { !$0.isEmpty }, "every state and error has words")
        expect(GoogleConnection.State.notConnected.buttonTitle == "Connect your Google account",
               "the one action is called what a person would call it")
    }

    // MARK: - The one button, with fakes

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var nextToken: (@Sendable () -> Void)?
        func hit(_ name: String) {
            lock.lock(); counts[name, default: 0] += 1
            let callback = name == "token" ? nextToken : nil
            if name == "token" { nextToken = nil }
            lock.unlock(); callback?()
        }
        func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[name, default: 0] }
        func onNextToken(_ callback: @escaping @Sendable () -> Void) {
            lock.lock(); nextToken = callback; lock.unlock()
        }
    }

    private static func orchestrationCases(_ expect: Expect) async {
        let client = GoogleAppClient(clientID: "x.apps.googleusercontent.com", clientSecret: "s", source: .app)
        func make(
            client: GoogleAppClient?, scopes: [String] = GoogleScopes.connect,
            signInError: (any Error)? = nil, toolError: (any Error)? = nil, counter: Counter
        ) -> GoogleConnection {
            GoogleConnection(dependencies: GoogleConnection.Dependencies(
                client: { client },
                signIn: { _ in
                    counter.hit("signIn")
                    if let signInError { throw signInError }
                    GoogleTokenStore.save(refreshToken: "r", grantedScopes: Set(scopes))
                    return GoogleOAuthClient.SignInResult(refreshToken: "r", grantedScopes: Set(scopes))
                },
                ensureTool: { counter.hit("tool"); if let toolError { throw toolError } },
                afterConnect: { counter.hit("after") },
                disconnect: { counter.hit("disconnect"); GoogleTokenStore.clear(forgetSelection: true) },
                workspace: { GoogleTokenStore.hasRefreshToken && GoogleScopes.coversWorkspace(GoogleTokenStore.grantedScopes)
                    ? .signedIn(method: "x") : .signedOut }))
        }

        var counter = Counter()
        var connection = make(client: nil, counter: counter)
        await connection.refresh()
        expect(connection.state == .unavailable, "no client in this build: fail closed, in plain words")
        await connection.connect()
        expect(counter.count("signIn") == 0 && connection.state == .unavailable, "…and the button never starts a sign-in")

        GoogleTokenStore.clear()
        counter = Counter()
        connection = make(client: client, counter: counter)
        await connection.refresh()
        expect(connection.state == .notConnected, "a fresh Mac is simply not connected")
        await connection.connect()
        expect(connection.state == .connected, "one press connects: \(connection.state)")
        expect(counter.count("signIn") == 1 && counter.count("tool") == 1 && counter.count("after") == 1,
               "one sign-in, the tool fetched once, everything that reads Google re-read once")
        await connection.disconnect()
        expect(counter.count("disconnect") == 1 && connection.state == .notConnected, "Disconnect puts it back")

        GoogleTokenStore.clear()
        counter = Counter()
        connection = make(client: client, scopes: [GoogleScopes.legacyCalendar], counter: counter)
        await connection.connect()
        expect(connection.state == .needsMoreAccess, "a box unticked on Google's page is named, not hidden")
        GoogleTokenStore.clear()

        counter = Counter()
        connection = make(client: client, signInError: GoogleCalendarError.authorizationDenied("access_denied"), counter: counter)
        await connection.connect()
        if case .failed(let message) = connection.state {
            expect(message == "You chose not to share, so nothing was connected.", "declining is said kindly: \(message)")
        } else { expect(false, "a declined sign-in is a failed state") }
        expect(counter.count("tool") == 0, "nothing is fetched after a declined sign-in")

        GoogleTokenStore.clear()
        counter = Counter()
        connection = make(client: client, toolError: ManagedWorkspaceTool.Failure.couldNotFetch, counter: counter)
        await connection.connect()
        if case .failed(let message) = connection.state {
            expect(message.contains("Check your connection"), "offline: one clear next step: \(message)")
        } else { expect(false, "a failed fetch is a failed state") }
        GoogleTokenStore.clear()
    }

    // MARK: - Loopback fixture standing in for Google

    private struct FixtureRequest: Sendable { let method: String; let path: String; let body: String }

    private final class FixtureServer: @unchecked Sendable {
        typealias Handler = @Sendable (FixtureRequest) -> (status: Int, type: String, body: Data)
        private let listener: NWListener
        private let handler: Handler
        private let lock = NSLock()
        private var seen: [FixtureRequest] = []
        private var connections: [NWConnection] = []

        init?(handler: @escaping Handler) {
            guard let listener = try? NWListener(using: .tcp, on: .any) else { return nil }
            self.listener = listener
            self.handler = handler
        }

        var requests: [FixtureRequest] { lock.lock(); defer { lock.unlock() }; return seen }

        func start() async -> UInt16? {
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            return await withCheckedContinuation { continuation in
                let once = OnceGuard()
                listener.stateUpdateHandler = { [listener] state in
                    switch state {
                    case .ready: if once.claim() { continuation.resume(returning: listener.port?.rawValue) }
                    case .failed, .cancelled: if once.claim() { continuation.resume(returning: nil) }
                    default: break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
        }

        func stop() {
            lock.lock(); let all = connections; connections = []; lock.unlock()
            all.forEach { $0.cancel() }
            listener.cancel()
        }

        private func accept(_ connection: NWConnection) {
            lock.lock(); connections.append(connection); lock.unlock()
            connection.start(queue: .global(qos: .userInitiated))
            read(connection, Data())
        }

        private func read(_ connection: NWConnection, _ buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
                var all = buffer
                if let data { all.append(data) }
                if let request = Self.parse(all) {
                    lock.lock(); seen.append(request); lock.unlock()
                    let answer = handler(request)
                    let head = "HTTP/1.1 \(answer.status) OK\r\nContent-Type: \(answer.type)\r\n"
                        + "Content-Length: \(answer.body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + answer.body,
                                    completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                if isComplete || error != nil || all.count > 2_000_000 { connection.cancel(); return }
                read(connection, all)
            }
        }

        private static func parse(_ data: Data) -> FixtureRequest? {
            guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: Data(data[..<separator.lowerBound]), encoding: .utf8) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count >= 2 else { return nil }
            let length = lines.compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            let body = Data(data[separator.upperBound...])
            guard body.count >= length else { return nil }
            return FixtureRequest(method: String(first[0]), path: String(first[1]),
                                  body: String(decoding: body.prefix(length), as: UTF8.self))
        }
    }

    private final class OnceGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
    }

    nonisolated private static func form(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return fields
    }

    nonisolated private static func json(_ object: [String: Any], status: Int = 200) -> (status: Int, type: String, body: Data) {
        (status, "application/json", (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    // MARK: - The sign-in, end to end

    private static func signInCases(_ expect: Expect) async {
        let granted = GoogleCapability.allCases.map(\.scope).joined(separator: " ")
        let grantMode = ModeBox()
        let refreshMode = ModeBox()
        guard let server = FixtureServer(handler: { request in
            switch request.path {
            case "/token":
                let fields = Self.form(request.body)
                if fields["grant_type"] == "refresh_token" {
                    if refreshMode.value == "revoked" {
                        return Self.json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."], status: 400)
                    }
                    return Self.json(["access_token": "access-\(UUID().uuidString.prefix(6))", "expires_in": 3600])
                }
                var response: [String: Any] = ["access_token": "access-1", "expires_in": 3600,
                                               "refresh_token": "refresh-1"]
                if grantMode.value != "missing" {
                    response["scope"] = grantMode.value == "empty" ? ""
                        : (grantMode.value == "partial" ? GoogleScopes.documents : granted)
                }
                return Self.json(response)
            case "/revoke": return Self.json([:])
            default: return (404, "text/plain", Data())
            }
        }), let port = await server.start() else {
            expect(false, "fixture server started"); return
        }
        defer { server.stop() }
        let endpoints = GoogleOAuthClient.Endpoints(
            authorization: "http://127.0.0.1:\(port)/auth", token: "http://127.0.0.1:\(port)/token",
            revoke: "http://127.0.0.1:\(port)/revoke")
        let client = GoogleAppClient(clientID: "fixture.apps.googleusercontent.com", clientSecret: "fixture-secret", source: .app)

        /// Plays the browser: reads the consent URL, then sends the redirect Google would.
        func browser(code: String?, error: String? = nil, wrongState: Bool = false) -> @Sendable (URL) -> Void {
            { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func v(_ n: String) -> String { items.first { $0.name == n }?.value ?? "" }
                var query = "state=\(wrongState ? "forged" : v("state"))"
                if let code { query += "&code=\(code)" }
                if let error { query += "&error=\(error)" }
                guard let target = URL(string: "\(v("redirect_uri"))?\(query)") else { return }
                Task { _ = try? await URLSession.shared.data(from: target) }
            }
        }

        do {
            let result = try await GoogleOAuthClient.signIn(
                clientID: client.clientID, clientSecret: client.clientSecret,
                endpoints: endpoints, openBrowser: browser(code: "auth-code-1"))
            expect(result.refreshToken == "refresh-1", "the sign-in returns the refresh token")
            expect(result.grantedScopes == Set(GoogleScopes.connect), "…and what Google actually granted")
            expect(GoogleTokenStore.refreshToken == "refresh-1" && GoogleTokenStore.grantedScopes == Set(GoogleScopes.connect),
                   "both are in the Keychain store, nothing in preferences")
            expect(GoogleScopes.coversWorkspace(GoogleTokenStore.grantedScopes), "mail and calendar are covered by the one sign-in")
        } catch {
            expect(false, "sign-in completed: \(error.localizedDescription)")
        }
        let exchange = server.requests.first { $0.path == "/token" }.map { Self.form($0.body) } ?? [:]
        expect(exchange["grant_type"] == "authorization_code" && exchange["code"] == "auth-code-1"
               && exchange["client_id"] == client.clientID && exchange["client_secret"] == "fixture-secret",
               "the token request carries the code, the client and its secret")
        let verifier = exchange["code_verifier"] ?? ""
        expect(verifier.count >= 43 && exchange["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true,
               "PKCE verifier sent, loopback redirect reused")

        for (mode, expected) in [("partial", Set([GoogleScopes.documents])), ("empty", Set<String>()),
                                 ("missing", Set(GoogleScopes.connect))] {
            grantMode.value = mode
            do {
                let result = try await GoogleOAuthClient.signIn(
                    clientID: client.clientID, clientSecret: client.clientSecret,
                    endpoints: endpoints, openBrowser: browser(code: "auth-code-1"))
                expect(result.grantedScopes == expected && GoogleTokenStore.grantedScopes == expected,
                       "actual \(mode) token response retains exactly its granted permissions in Keychain")
            } catch { expect(false, "\(mode) token response: sign-in failed") }
        }
        grantMode.value = ""

        // Hold the old refresh, then hold a real successful reconnect immediately after
        // grant replacement. The old invalid_grant must not delete the new Keychain row.
        let oldRefresh = GoogleReviewFixture.Gate()
        let saved = GoogleReviewFixture.Gate()
        let shared = GoogleAccessTokens.shared
        await shared.useRequestForTesting { request in
            await oldRefresh.pause()
            return GoogleReviewFixture.response(request, status: 400, body: #"{"error":"invalid_grant"}"#)
        }
        GoogleTokenStore.save(refreshToken: "old-reconnect", grantedScopes: [GoogleScopes.documents])
        let old = Task { try await shared.token(clientID: client.clientID, clientSecret: client.clientSecret) }
        await oldRefresh.wait()
        let reconnect = Task {
            try await GoogleOAuthClient.signIn(clientID: client.clientID, clientSecret: client.clientSecret,
                endpoints: endpoints, openBrowser: browser(code: "reconnect-code"),
                afterGrantSaveForTesting: { await saved.pause() })
        }
        await saved.wait()
        await oldRefresh.release()
        _ = try? await old.value
        expect(GoogleTokenStore.refreshToken == "refresh-1" && GoogleTokenStore.grantedScopes == Set(GoogleScopes.connect),
            "R3 outstanding old invalid_grant cannot delete a real successful reconnect")
        await saved.release()
        let connected = try? await reconnect.value
        expect(connected?.grantedScopes == Set(GoogleScopes.connect) && GoogleTokenStore.hasRefreshToken,
            "R3 real sign-in returns a grant that is still stored after the old refresh settles")
        await shared.useRequestForTesting(nil)

        // A forged redirect (another process feeding its own code) is refused.
        do {
            _ = try await GoogleOAuthClient.signIn(
                clientID: client.clientID, clientSecret: "", endpoints: endpoints,
                openBrowser: browser(code: "evil", wrongState: true))
            expect(false, "a forged redirect is refused")
        } catch GoogleCalendarError.stateMismatch {
            expect(true, "a forged redirect is refused")
        } catch { expect(false, "forged redirect: wrong error \(error)") }

        // Declining on Google's page.
        do {
            _ = try await GoogleOAuthClient.signIn(
                clientID: client.clientID, clientSecret: "", endpoints: endpoints,
                openBrowser: browser(code: nil, error: "access_denied"))
            expect(false, "declining is an error")
        } catch GoogleCalendarError.authorizationDenied(let reason) {
            expect(reason == "access_denied", "declining reaches the app as a refusal, nothing stored over the old one")
        } catch { expect(false, "decline: wrong error \(error)") }

        // Access tokens: minted once, shared, and a revoked grant is noticed.
        let tokens = GoogleAccessTokens.shared
        await tokens.useEndpoints(endpoints)
        await tokens.useClient(client)
        await tokens.invalidate()
        let before = await tokens.refreshCount
        let first = try? await tokens.token(clientID: client.clientID, clientSecret: client.clientSecret)
        let second = try? await tokens.token(clientID: client.clientID, clientSecret: client.clientSecret)
        let after = await tokens.refreshCount
        expect(first != nil && first == second && after == before + 1,
               "Calendar and the Workspace runner share one cached access token")

        refreshMode.value = "revoked"
        await tokens.invalidate()
        do {
            _ = try await tokens.token(clientID: client.clientID, clientSecret: client.clientSecret)
            expect(false, "a revoked grant is noticed")
        } catch GoogleCalendarError.accessRevoked {
            expect(!GoogleTokenStore.hasRefreshToken, "revoked in the Google account: the dead key is removed, one reconnect button remains")
        } catch { expect(false, "revoked: wrong error \(error)") }
        refreshMode.value = ""

        GoogleTokenStore.save(refreshToken: "refresh-2", grantedScopes: Set(GoogleScopes.connect))
        await GoogleOAuthClient.revoke(refreshToken: "refresh-2", endpoints: endpoints)
        expect(server.requests.contains { $0.path == "/revoke" && $0.body.contains("refresh-2") },
               "Disconnect tells Google to end the access too")
        GoogleTokenStore.clear()
        await tokens.useEndpoints(.google)
        await tokens.useClient(nil)
    }

    // MARK: - Review fixes: fail closed, pinned tool, revocation, one refresh, timeouts

    private static func hardeningCases(_ expect: Expect) async {
        // Test hooks are for this flag alone.
        expect(GoogleAccessTokens.hooksAdmitted(isRunning: true, requested: "--selftest-google-connect"),
               "the fixture hooks are open to this self-test")
        expect(!GoogleAccessTokens.hooksAdmitted(isRunning: false, requested: nil)
               && !GoogleAccessTokens.hooksAdmitted(isRunning: true, requested: "--selftest-gws")
               && !GoogleAccessTokens.hooksAdmitted(isRunning: true, requested: nil),
               "…and refused in a normal run and in every other self-test")

        let counter = Counter()
        let mode = ModeBox()
        guard let server = FixtureServer(handler: { request in
            guard request.path == "/token" else { return (404, "text/plain", Data()) }
            counter.hit("token")
            if mode.value == "slow" { Thread.sleep(forTimeInterval: 0.5) }
            if mode.value == "invalid_client" { return Self.json(["error": "invalid_client"], status: 400) }
            if mode.value == "server_error" { return Self.json(["error": "backend_error"], status: 500) }
            return Self.json(["access_token": "tok-\(counter.count("token"))", "expires_in": 3600])
        }), let port = await server.start() else { expect(false, "hardening fixture server started"); return }
        defer { server.stop() }
        let endpoints = GoogleOAuthClient.Endpoints(authorization: "", token: "http://127.0.0.1:\(port)/token", revoke: "")
        let client = GoogleAppClient(clientID: "fixture.apps.googleusercontent.com", clientSecret: "s", source: .app)
        let tokens = GoogleAccessTokens.shared
        await tokens.useEndpoints(endpoints)
        await tokens.useClient(client)
        defer { Task { await tokens.useClient(nil); await tokens.useEndpoints(.google); await tokens.invalidate(); GoogleTokenStore.clear() } }

        // Five callers starting together spend one round trip, and all get the same token.
        GoogleTokenStore.save(refreshToken: "refresh-h", grantedScopes: Set(GoogleScopes.connect))
        await tokens.invalidate()
        mode.value = "slow"
        let results = await withTaskGroup(of: String?.self) { group -> [String?] in
            for _ in 0..<5 { group.addTask { try? await tokens.token(clientID: client.clientID, clientSecret: client.clientSecret) } }
            var all: [String?] = []
            for await value in group { all.append(value) }
            return all
        }
        expect(counter.count("token") == 1 && Set(results.compactMap { $0 }).count == 1 && results.compactMap({ $0 }).count == 5,
               "five concurrent callers share one refresh round trip (saw \(counter.count("token")))")

        // Only `invalid_grant` signs somebody out. A wrong client or a Google outage does not.
        for (label, failure) in [("a rejected client", "invalid_client"), ("a Google outage", "server_error")] {
            mode.value = failure
            await tokens.invalidate()
            do {
                _ = try await tokens.token(clientID: client.clientID, clientSecret: client.clientSecret)
                expect(false, "\(label) is an error")
            } catch GoogleCalendarError.accessRevoked {
                expect(false, "\(label) must not read as a revoked grant")
            } catch {
                expect(GoogleTokenStore.hasRefreshToken, "\(label) keeps the sign-in (nothing was revoked)")
            }
        }

        // Fail closed: if the token cannot be had, the tool is never run, and in particular is
        // never run with whatever login the person has of their own.
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("NextNotesGoogleConnect-closed-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: work) }
        let exe = work.appendingPathComponent("gws")
        let ran = work.appendingPathComponent("ran")
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            try "#!/bin/sh\ntouch \"$(dirname \"$0\")/ran\"\necho \"token=$GOOGLE_WORKSPACE_CLI_TOKEN\"\n".write(to: exe, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        } catch { expect(false, "fail-closed fixture written"); return }
        if let runner = GoogleWorkspaceCLI.appAccountFixture(executable: exe) {
            mode.value = "server_error"
            await tokens.invalidate()
            do {
                _ = try await runner.run(["anything"])
                expect(false, "a token failure stops the call")
            } catch let error as WorkspaceCLIError {
                expect(error.outcomeIsKnown && !fileManager.fileExists(atPath: ran.path),
                       "a token failure stops the call before the tool starts, and says nothing left the Mac: \(error)")
            } catch { expect(false, "token failure: wrong error \(error)") }
            mode.value = ""
            await tokens.invalidate()
            _ = try? await runner.run(["anything"])
            expect(fileManager.fileExists(atPath: ran.path), "…while with a token the very same fixture does run")

            // Cancel at the actual shared refresh request, before executable entry.
            // That waiter must stop, while the same successful refresh remains usable.
            try? fileManager.removeItem(at: ran)
            await tokens.invalidate()
            let before = counter.count("token")
            let cancelled = Task { try await runner.run(["anything"]) }
            counter.onNextToken { cancelled.cancel() }
            do {
                _ = try await cancelled.value
                expect(false, "a caller cancelled during shared refresh cannot start a tool")
            } catch is CancellationError {
                expect(true, "a caller cancelled during shared refresh receives cancellation")
            } catch { expect(false, "cancelled shared-refresh caller: wrong error") }
            expect(!fileManager.fileExists(atPath: ran.path),
                   "the cancelled shared-refresh caller never enters executable backing")
            _ = try? await runner.run(["anything"])
            expect(fileManager.fileExists(atPath: ran.path) && counter.count("token") == before + 1,
                   "another caller uses the same completed refresh and enters backing once")
        } else { expect(false, "fail-closed runner admitted") }

        // A supplied alternate login is real executable backing, but is never managed.
        // Mutating managed admission to use this fallback must start it and turn this red.
        try? fileManager.removeItem(at: ran)
        if let fallback = GoogleWorkspaceCLI.appAccountFixture(executable: exe, isManaged: false) {
            expect(await fallback.authState() == .notInstalled, "a separate installed login cannot make the app ready")
            do {
                _ = try await fallback.run(["anything"])
                expect(false, "an unpinned alternate executable cannot receive the app token")
            } catch let error as WorkspaceCLIError {
                expect(error == .notInstalled && !fileManager.fileExists(atPath: ran.path),
                       "the actual unpinned alternate executable remains unstarted")
            } catch { expect(false, "alternate executable: wrong refusal") }
        } else { expect(false, "alternate executable fixture admitted") }

        // Pinned: the app's sign-in runs only the copy the app fetched and verified itself.
        // This Mac may well have its own `gws`; with no pinned copy the answer is "not ready".
        let real = GoogleWorkspaceCLI()
        GoogleTokenStore.save(refreshToken: "refresh-h", grantedScopes: Set(GoogleScopes.connect))
        let state = await real.authState()
        expect(state == .notInstalled, "with the app's sign-in and no pinned copy, a `gws` of the person's own is not used: \(state)")
        do {
            _ = try await real.run(["anything"])
            expect(false, "the app's sign-in never runs an unpinned tool")
        } catch let error as WorkspaceCLIError {
            expect(error == .notInstalled, "…and a call is refused, not run: \(error)")
        } catch { expect(false, "pinned: wrong error \(error)") }

        // A tool that hangs while it is being checked does not hold "Getting ready" open.
        let source = work.appendingPathComponent("hang/pkg", isDirectory: true)
        let archive = work.appendingPathComponent("hang.tar.gz")
        do {
            try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
            let script = "#!/bin/sh\nexec sleep 60\n"
            try script.write(to: source.appendingPathComponent("gws"), atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("gws").path)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", archive.path, "-C", work.appendingPathComponent("hang").path, "."]
            try tar.run(); tar.waitUntilExit()
        } catch { expect(false, "hanging-tool fixture built: \(error)"); return }
        guard let bytes = try? Data(contentsOf: archive) else { expect(false, "hanging-tool archive readable"); return }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = ManagedWorkspaceTool.Asset(name: "hang.tar.gz", bytes: Int64(bytes.count), sha256: digest)
        guard let toolServer = FixtureServer(handler: { _ in (200, "application/gzip", bytes) }),
              let toolPort = await toolServer.start() else { expect(false, "hanging-tool server started"); return }
        defer { toolServer.stop() }
        let started = Date()
        do {
            _ = try await ManagedWorkspaceTool.install(
                root: work.appendingPathComponent("tools"), asset: asset, version: ManagedWorkspaceTool.version,
                base: "http://127.0.0.1:\(toolPort)/", commandTimeout: 1)
            expect(false, "a tool that never answers is not installed")
        } catch let failure as ManagedWorkspaceTool.Failure {
            expect(failure == .wouldNotRun && Date().timeIntervalSince(started) < 15,
                   "a tool that never answers is stopped and refused in plain words, in \(Int(Date().timeIntervalSince(started))) s")
        } catch { expect(false, "hanging tool: wrong error \(error)") }
    }

    private final class ModeBox: @unchecked Sendable {
        private let lock = NSLock(); private var stored = ""
        var value: String { get { lock.lock(); defer { lock.unlock() }; return stored }
                            set { lock.lock(); stored = newValue; lock.unlock() } }
    }

    // MARK: - The managed tool

    private static func toolInstallCases(_ expect: Expect) async {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("NextNotesGoogleConnect-tool-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: work) }
        let version = ManagedWorkspaceTool.version
        let source = work.appendingPathComponent("src/google-workspace-cli-fixture", isDirectory: true)
        let root = work.appendingPathComponent("tools", isDirectory: true)
        do {
            try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
            let script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"gws \(version)\"; exit 0; fi\necho \"token=$GOOGLE_WORKSPACE_CLI_TOKEN\"\necho \"{}\"\n"
            try script.write(to: source.appendingPathComponent("gws"), atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("gws").path)
            try Data("licence".utf8).write(to: source.appendingPathComponent("LICENSE"))
        } catch { expect(false, "fixture written: \(error)"); return }
        let archive = work.appendingPathComponent("fixture.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", work.appendingPathComponent("src").path, "."]
        try? tar.run(); tar.waitUntilExit()
        guard let bytes = try? Data(contentsOf: archive), tar.terminationStatus == 0 else { expect(false, "fixture archive built"); return }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = ManagedWorkspaceTool.Asset(name: "fixture.tar.gz", bytes: Int64(bytes.count), sha256: digest)

        guard let server = FixtureServer(handler: { request in
            request.path.hasSuffix("/fixture.tar.gz") ? (200, "application/gzip", bytes) : (404, "text/plain", Data())
        }), let port = await server.start() else { expect(false, "tool fixture server started"); return }
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)/"

        expect(ManagedWorkspaceTool.executable(root: root, version: version, asset: asset) == nil, "nothing is installed before the first connect")
        do {
            let installed = try await ManagedWorkspaceTool.install(root: root, asset: asset, version: version, base: base)
            expect(installed.lastPathComponent == "gws" && fileManager.isExecutableFile(atPath: installed.path),
                   "the tool is fetched, checked, unpacked and made runnable with no Terminal")
            expect(ManagedWorkspaceTool.executable(root: root, version: version, asset: asset) == installed, "…and found afterwards")
            let original = try Data(contentsOf: installed)
            try Data("#!/bin/sh\necho replaced\n".utf8).write(to: installed)
            expect(ManagedWorkspaceTool.executable(root: root, version: version, asset: asset) == nil,
                   "a replaced executable is refused after the cached admission")
            try original.write(to: installed)
            expect(ManagedWorkspaceTool.executable(root: root, version: version, asset: asset) == installed,
                   "the restored exact executable is admitted again")
            let linked = installed.deletingLastPathComponent().appendingPathComponent("alternate")
            try original.write(to: linked)
            try fileManager.removeItem(at: installed)
            try fileManager.createSymbolicLink(at: installed, withDestinationURL: linked)
            expect(ManagedWorkspaceTool.executable(root: root, version: version, asset: asset) == nil,
                   "a symlink cannot replace the verified executable")
            try fileManager.removeItem(at: installed)
            try original.write(to: installed)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
            expect(server.requests.count == 1, "one transfer")
            _ = try await ManagedWorkspaceTool.install(root: root, asset: asset, version: version, base: base)
            expect(server.requests.count == 1, "installed once, never fetched again")
            expect(!fileManager.fileExists(atPath: root.appendingPathComponent("fixture.tar.gz").path)
                   && ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).allSatisfy { !$0.contains("staging") },
                   "no archive or staging folder is left behind")
        } catch { expect(false, "install succeeded: \(error)") }

        // A file that does not match its pinned checksum is never used.
        let bad = ManagedWorkspaceTool.Asset(name: asset.name, bytes: asset.bytes, sha256: String(repeating: "0", count: 64))
        let badRoot = work.appendingPathComponent("bad", isDirectory: true)
        do {
            _ = try await ManagedWorkspaceTool.install(root: badRoot, asset: bad, version: version, base: base)
            expect(false, "a wrong checksum is refused")
        } catch let failure as ManagedWorkspaceTool.Failure {
            expect(failure == .damaged, "a wrong checksum is refused, in plain words")
        } catch { expect(false, "wrong checksum: unexpected error \(error)") }
        expect(ManagedWorkspaceTool.executable(root: badRoot, version: version, asset: bad) == nil, "…and nothing runnable was left")

        // Offline.
        do {
            _ = try await ManagedWorkspaceTool.install(
                root: work.appendingPathComponent("off"), asset: asset, version: version, base: "http://127.0.0.1:1/")
            expect(false, "an unreachable download fails")
        } catch let failure as ManagedWorkspaceTool.Failure {
            expect(failure == .couldNotFetch, "offline is \u{201C}check your connection\u{201D}, not a stack trace")
        } catch { expect(false, "offline: unexpected error \(error)") }

        // The pinned digests are the shape GitHub publishes.
        for pinned in [ManagedWorkspaceTool.appleSilicon, ManagedWorkspaceTool.intel] {
            expect(pinned.sha256.count == 64 && pinned.sha256.allSatisfy(\.isHexDigit) && pinned.bytes > 1_000_000,
                   "pinned release asset \(pinned.name) has a SHA-256 and a size")
            expect(ManagedWorkspaceTool.downloadURL(for: pinned)?.host == "github.com",
                   "…fetched from Google's own GitHub project")
        }
    }

    // MARK: - The runner hands the tool the app's own sign-in

    private static func runnerCases(_ expect: Expect) async {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("NextNotesGoogleConnect-run-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: work) }
        let exe = work.appendingPathComponent("gws")
        do {
            try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
            try "#!/bin/sh\necho \"token=$GOOGLE_WORKSPACE_CLI_TOKEN\"\n".write(to: exe, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        } catch { expect(false, "runner fixture written"); return }
        guard let runner = GoogleWorkspaceCLI.appAccountFixture(executable: exe) else {
            expect(false, "runner fixture admitted"); return
        }

        let revoked = ModeBox()
        guard let server = FixtureServer(handler: { request in
            if revoked.value == "revoked" {
                return Self.json(["error": "invalid_grant"], status: 400)
            }
            return Self.json(["access_token": "live-access-token", "expires_in": 3600])
        }), let port = await server.start() else { expect(false, "runner fixture server started"); return }
        defer { server.stop() }
        let endpoints = GoogleOAuthClient.Endpoints(
            authorization: "", token: "http://127.0.0.1:\(port)/token", revoke: "")
        let tokens = GoogleAccessTokens.shared
        await tokens.useEndpoints(endpoints)
        await tokens.useClient(GoogleAppClient(clientID: "fixture.apps.googleusercontent.com", clientSecret: "s", source: .app))
        await tokens.invalidate()
        defer { Task { await tokens.useClient(nil); await tokens.useEndpoints(.google); await tokens.invalidate(); GoogleTokenStore.clear() } }

        GoogleTokenStore.clear(forgetSelection: true)
        if let output = try? await runner.run(["anything"]) {
            expect(output.text.trimmingCharacters(in: .whitespacesAndNewlines) == "token=",
                   "signed out: the tool is handed no token and uses what it has itself")
        } else { expect(false, "runner ran with no account") }

        GoogleTokenStore.save(refreshToken: "refresh-run", grantedScopes: Set(GoogleScopes.connect))
        if let output = try? await runner.run(["anything"]) {
            expect(output.text.contains("token=live-access-token"),
                   "signed in: the one Workspace runner hands the tool the app's own access token")
        } else { expect(false, "runner ran with the account") }
        let state = await runner.authState()
        expect(state == .signedIn(method: "your Google account"),
               "auth state comes from what Google granted, not from an exit code: \(state)")

        GoogleTokenStore.save(refreshToken: "refresh-run", grantedScopes: [GoogleScopes.legacyCalendar])
        let partial = await runner.authState()
        expect(partial.isSignedIn && GoogleSource.scopeGaps(granted: GoogleTokenStore.grantedScopes, tools: GoogleSource.allTools)["send_email"] != nil,
               "a partial grant retains the app route and marks Mail as needing permission")

        // Only Docs shared: the actual status producer feeds its individual gaps to the
        // actual manifest, and the actual runner still uses this grant for Docs.
        GoogleTokenStore.save(refreshToken: "refresh-run", grantedScopes: [GoogleScopes.documents])
        let status = await GoogleSource.status(cli: runner)
        expect(status.state.isSignedIn && status.gaps["read_doc"] == nil && status.gaps["send_email"] != nil,
               "actual status keeps Docs ready while Mail needs one more permission")
        var inputs = AgentCapabilityInputs.allEnabled(tools: AgentToolRegistry.shared.tools(upTo: .privileged),
            reader: AgentCapabilityManifest.Reader(provider: .appLLM, displayName: "Fixture", contextTokens: 8_192))
        inputs.workspace = VoiceCapabilitySnapshot.WorkspaceStatus.cached(status.state, isProbing: false)
        inputs.workspaceGaps = status.gaps
        let manifest = AgentCapabilityManifestBuilder.build(inputs, request: "read my Google document")
        expect(manifest.entry(named: "read_doc")?.readiness == .ready
               && manifest.entry(named: "send_email") == nil
               && manifest.unavailable.first { $0.id == "send_email" }?.readiness == .needsSetup(GoogleCapability.mail.permissionSentence),
               "actual status gaps reach the real manifest without disabling Docs")
        let docsOutput = try? await runner.run(["docs", "documents", "get"])
        expect(docsOutput?.text.contains("token=live-access-token") == true,
               "the actual Docs-only runner uses the app token")
        do {
            _ = try await runner.run(["gmail", "users", "getProfile"])
            expect(false, "Mail with an unticked permission is refused before launch")
        } catch let error as WorkspaceCLIError {
            expect(error == .invalidRequest(GoogleCapability.mail.permissionSentence),
                   "unticked Mail has the same plain permission sentence at execution")
        } catch { expect(false, "unticked Mail: wrong refusal") }

        GoogleTokenStore.save(refreshToken: "refresh-run", grantedScopes: Set(GoogleScopes.connect))
        revoked.value = "revoked"
        await tokens.invalidate()
        do {
            _ = try await runner.run(["anything"])
            expect(false, "a revoked grant stops a Workspace call")
        } catch let error as WorkspaceCLIError {
            expect(error == .notAuthenticated && error.outcomeIsKnown,
                   "revoked: the call is refused before anything is sent, and says so (outcome known)")
        } catch { expect(false, "revoked call: wrong error \(error)") }
        expect(!GoogleTokenStore.hasRefreshToken, "…and the person is back to one reconnect button")
        expect(GoogleTokenStore.appSignInSelected, "revocation retains the chosen app route")
        do {
            _ = try await runner.run(["anything"])
            expect(false, "the next call after revocation cannot use another login")
        } catch let error as WorkspaceCLIError {
            expect(error == .notAuthenticated, "the next call after revocation also refuses before starting")
        } catch { expect(false, "subsequent revoked call: wrong error") }

        // A raw calendar-only record predates the selected-route preference. Exercise
        // the actual legacy Keychain reader and revocation, then call the same runner
        // again: deleting the token must not expose a separate CLI login.
        GoogleTokenStore.clear(forgetSelection: true)
        let service = GoogleTokenStore.service
        guard service == GoogleTokenStore.baseService + ".selftest-\(ProcessInfo.processInfo.processIdentifier)" else {
            expect(false, "legacy grant fixture is isolated"); return
        }
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "refresh-token",
                                    kSecValueData as String: Data("legacy-refresh-fixture".utf8)]
        guard SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess else {
            expect(false, "legacy grant fixture was saved"); return
        }
        expect(GoogleTokenStore.hasRefreshToken && GoogleTokenStore.appSignInSelected
               && GoogleTokenStore.grantedScopes == [GoogleScopes.legacyCalendar],
               "actual raw legacy grant reads as calendar-only and adopts the app route")
        await tokens.invalidate()
        do {
            _ = try await runner.run(["anything"])
            expect(false, "a revoked legacy grant stops the first call")
        } catch let error as WorkspaceCLIError {
            expect(error == .notAuthenticated, "a revoked legacy grant is refused before launch")
        } catch { expect(false, "legacy revoked call: wrong error") }
        expect(GoogleTokenStore.appSignInSelected && !GoogleTokenStore.hasRefreshToken,
               "revoking a raw legacy grant retains the selected app route")
        do {
            _ = try await runner.run(["anything"])
            expect(false, "the next call after legacy revocation cannot use another login")
        } catch let error as WorkspaceCLIError {
            expect(error == .notAuthenticated, "legacy revocation also refuses the next call before launch")
        } catch { expect(false, "subsequent legacy revoked call: wrong error") }
    }
    // Exact GoogleCalendarProvider consumers, using its admitted synthetic boundary.
    private static func calendarConsumerCases(_ expect: Expect) async {
        let counter = Counter()
        let provider = GoogleCalendarProvider(
            requestForTesting: { request in
                let body: Data
                let status: Int
                if request.url?.host == "oauth2.googleapis.com" {
                    counter.hit("token")
                    // Hold the real request so actor reentrancy exposes duplicate refreshes.
                    try await Task.sleep(for: .milliseconds(100))
                    body = Self.json(["access_token": "fixture", "expires_in": 3600]).body
                    status = 200
                } else {
                    counter.hit("read")
                    body = Data(#"{"items":[]}"#.utf8)
                    status = 200
                }
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }, refreshTokenForTesting: { "fixture-refresh" }, clearTokenForTesting: { counter.hit("clear") })
        await provider.configure(clientID: "fixture-client", clientSecret: "", calendarIDs: [])
        let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<5 { group.addTask { (try? await provider.calendars()) != nil } }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        expect(results.count == 5 && results.allSatisfy { $0 } && counter.count("token") == 1 && counter.count("read") == 5,
               "five actual Calendar consumers share one refresh and receive their own reads")
        let refusal = Counter()
        let rejected = GoogleCalendarProvider(
            requestForTesting: { request in
                let isToken = request.url?.host == "oauth2.googleapis.com"
                refusal.hit(isToken ? "token" : "read")
                let data = isToken ? Self.json(["access_token": "fixture", "expires_in": 3600]).body : Data()
                return (data, HTTPURLResponse(url: request.url!, statusCode: isToken ? 200 : 401, httpVersion: nil, headerFields: nil)!)
            }, refreshTokenForTesting: { "fixture-refresh" }, clearTokenForTesting: { refusal.hit("clear") })
        await rejected.configure(clientID: "fixture-client", clientSecret: "", calendarIDs: [])
        do {
            _ = try await rejected.calendars()
            expect(false, "two Calendar 401s are a failure")
        } catch GoogleCalendarError.accessTokenRejected {
            expect(refusal.count("token") == 2 && refusal.count("read") == 2 && refusal.count("clear") == 0,
                   "two actual Calendar 401s retain the grant and never claim revocation")
        } catch { expect(false, "Calendar 401s: wrong error") }
    }

}
