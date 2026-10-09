import Foundation
import Observation

/// Google's own sign-in (Option C): one action, and where it has got to.
///
/// **The second way to connect, not the first.** The default is the Google account already on
/// the Mac (`MacAccountModel`); this is for Docs, Sheets, Slides, Drive, Tasks and Forms, which
/// only Google's API can open, and for a Mac with no Google account on it. A person presses one
/// button, Google's own page opens in their browser, and Google asks once for the whole set. No
/// Homebrew, no Terminal, no Cloud project, no client id or secret to paste (PL-09). The pieces are the ones that already existed — `GoogleOAuthClient` (loopback and
/// PKCE), `GoogleTokenStore` (Keychain) and `GoogleWorkspaceCLI` (the one Workspace runner,
/// now handed this sign-in and a tool the app fetched itself). Calendar and the agent share
/// the one sign-in; nothing here adds a second client, token store or runner.
@MainActor
@Observable
final class GoogleConnection {
    static let shared = GoogleConnection()

    enum State: Equatable, Sendable {
        /// This build has no registered Google client, so there is nothing that could work.
        case unavailable
        case notConnected
        /// Google's page is open in the browser.
        case connecting
        /// Signed in; the app is fetching the little it needs to reach mail and files.
        case gettingReady
        case connected
        /// Signed in, but Google was not given everything mail needs (a box was unticked, or
        /// the sign-in is from before mail was supported).
        case needsMoreAccess
        case failed(String)

        var buttonTitle: String { buttonTitle(addOn: false) }

        /// `addOn` is the wording when the Mac's own account already covers mail and calendar and
        /// this sign-in is only for what Google alone can open.
        func buttonTitle(addOn: Bool) -> String {
            switch self {
            case .connected: "Disconnect"
            case .connecting: "Waiting for Google\u{2026}"
            case .gettingReady: "Getting ready\u{2026}"
            default: addOn ? "Connect Google Docs, Sheets and Drive too" : "Connect your Google account"
            }
        }

        var isBusy: Bool { self == .connecting || self == .gettingReady }

        /// The status word beside the button.
        var label: String {
            switch self {
            case .connected: "Connected"
            case .connecting, .gettingReady: "Connecting"
            case .needsMoreAccess: "Needs a little more access"
            case .failed: "Couldn\u{2019}t connect"
            case .unavailable, .notConnected: "Not connected"
            }
        }

        /// The reason, or the next click, in one or two plain sentences.
        var detail: String { detail(addOn: false) }

        func detail(addOn: Bool) -> String {
            switch self {
            case .notConnected where addOn:
                "Connect Google once to use Docs, Sheets, Slides and Drive."
            case .connected where addOn:
                "Google Docs, Sheets, Slides and Drive are connected."
            case .unavailable:
                GoogleAppClient.unavailableMessage
            case .notConnected:
                "Connect Google to see your week and prepare replies for your approval."
            case .connecting:
                "Finish signing in on Google’s page in your browser."
            case .gettingReady:
                "Getting things ready to reach Google."
            case .connected:
                "Google is connected, with your approval required before anything is sent."
            case .needsMoreAccess:
                "Some Google features need one more permission; the others are ready to use."
            case .failed(let reason) where reason == GoogleCalendarError.tokenStoreUnreadable.localizedDescription
                || reason == GoogleCalendarError.signInChanged.localizedDescription:
                reason
            case .failed:
                "Google couldn’t connect; please try again."
            }
        }

    }

    /// What the state is, from facts alone. Pure, so a test can read every row of it.
    nonisolated static func derive(
        clientConfigured: Bool,
        hasToken: Bool,
        grantedScopes: Set<String>,
        workspace: WorkspaceAuthState
    ) -> State {
        if workspace.isSignedIn {
            return hasToken && !Set(GoogleScopes.connect).isSubset(of: grantedScopes) ? .needsMoreAccess : .connected
        }
        if hasToken {
            return workspace == .notInstalled ? .gettingReady : .needsMoreAccess
        }
        return clientConfigured ? .notConnected : .unavailable
    }

    /// Everything the flow touches, so it can be run with no account.
    struct Dependencies: Sendable {
        var client: @Sendable () -> GoogleAppClient?
        var signIn: @Sendable (GoogleAppClient) async throws -> GoogleOAuthClient.SignInResult
        var ensureTool: @Sendable () async throws -> Void
        /// Turns Calendar's Google reading on and re-reads everything that depends on the account.
        var afterConnect: @Sendable (Set<String>) async -> Void
        var disconnect: @Sendable () async -> Void
        var workspace: @Sendable () async -> WorkspaceAuthState

        static let live = Dependencies(
            client: { GoogleAppClient.current },
            signIn: { client in
                try await GoogleOAuthClient.signIn(clientID: client.clientID, clientSecret: client.clientSecret)
            },
            ensureTool: { try await ManagedWorkspaceTool.install() },
            afterConnect: { scopes in
                await applyCalendarGrant(scopes, setEnabled: { enabled in
                    await MainActor.run { Settings.shared.calendarGoogleEnabled = enabled }
                }, refreshCalendars: { await CalendarService.shared.refreshGoogleCalendars() })
                // Google's sign-in is the only way mail and calendar work on a Mac that has no
                // Google account of its own; otherwise the choice stays where the person put it.
                if await MacAccounts.shared.setup().accountFound == false {
                    await MainActor.run { Settings.shared.googleSource = .googleSignIn }
                }
                await refreshEverythingThatReadsGoogle()
            },
            disconnect: {
                if let token = GoogleTokenStore.refreshToken { await GoogleOAuthClient.revoke(refreshToken: token) }
                await GoogleAccessTokens.shared.disconnectGrant()
                await CalendarService.shared.refreshGoogleCalendars()
                // Back to resolving from facts: this Mac, unless a `gws` sign-in still works.
                await MainActor.run {
                    if Settings.shared.googleSource == .googleSignIn { Settings.shared.googleSource = nil }
                }
                await refreshEverythingThatReadsGoogle()
            },
            workspace: { await GoogleWorkspaceCLI.shared.authState() }
        )

        /// The existing connect consumer applies the returned grant before listing.
        static func applyCalendarGrant(_ scopes: Set<String>,
            setEnabled: @Sendable (Bool) async -> Void,
            refreshCalendars: @Sendable () async -> Void) async {
            let granted = GoogleScopes.coversCalendar(scopes)
            await setEnabled(granted)
            if granted { await refreshCalendars() }
        }

        @MainActor
        private static func refreshEverythingThatReadsGoogle() async {
            GoogleSource.forget()
            await GoogleWorkspaceCLI.shared.forget()
            await GoogleWorkspaceCLI.shared.forgetAccountTag()
            AgentService.shared.invalidateStatus()
            await AgentService.shared.refreshStatus(force: true)
            await CalendarService.shared.refresh()
        }
    }

    private(set) var state: State = .notConnected
    @ObservationIgnored private var transient: State?
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
        if !SelfTest.isRunning { Task { await refresh() } }
    }

    /// Re-reads where things stand. Cheap; called when a Settings pane appears.
    func refresh() async {
        guard transient == nil else { return }
        let grantState = GoogleTokenStore.readState
        if grantState == .unavailable {
            state = .failed(GoogleCalendarError.tokenStoreUnreadable.localizedDescription)
            return
        }
        let workspace = await dependencies.workspace()
        if workspace == .failed(GoogleCalendarError.tokenStoreUnreadable.localizedDescription) {
            state = .failed(GoogleCalendarError.tokenStoreUnreadable.localizedDescription)
            return
        }
        let grant: GoogleTokenStore.StoredGrant?
        if case .available(let saved) = grantState { grant = saved } else { grant = nil }
        let derived = Self.derive(
            clientConfigured: dependencies.client() != nil,
            hasToken: grant != nil,
            grantedScopes: grant?.scopes ?? [],
            workspace: workspace)
        state = derived
        // Signed in, but the tool is not here yet: fetch it quietly, once.
        if derived == .gettingReady { prepareTool() }
    }

    /// The one button.
    func connect() async {
        guard !state.isBusy, let client = dependencies.client() else { await refresh(); return }
        transient = .connecting
        state = .connecting
        do {
            let result = try await dependencies.signIn(client)
            transient = .gettingReady
            state = .gettingReady
            try await dependencies.ensureTool()
            await dependencies.afterConnect(result.grantedScopes)
            transient = nil
            state = Set(GoogleScopes.connect).isSubset(of: result.grantedScopes) ? .connected : .needsMoreAccess
            await refresh()
        } catch is CancellationError {
            transient = nil
            await refresh()
        } catch {
            transient = nil
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        transient = nil
        await dependencies.disconnect()
        await refresh()
    }

    /// Fetches the tool in the background after a sign-in that is already complete — for
    /// instance the app was quit while it was being fetched. Never during a self-test.
    func prepareTool() {
        guard !preparing, !SelfTest.isRunning else { return }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                try await dependencies.ensureTool()
                guard let grant = try GoogleTokenStore.savedGrant() else { await refresh(); return }
                await dependencies.afterConnect(grant.scopes)
                await refresh()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
