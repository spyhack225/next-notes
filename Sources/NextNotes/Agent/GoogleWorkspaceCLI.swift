import Foundation

/// Where the Workspace CLI is in its own setup, which is the only thing the app can say
/// about it without asking the user to do something.
///
/// Four states rather than a boolean because each one has a different next step, and
/// offering "Sign in" to a machine with no `gws` on it — or "Install" to one that is already
/// signed in — is how a settings pane stops being trusted.
enum WorkspaceAuthState: Equatable, Sendable {
    /// No `gws` binary anywhere this app knows to look.
    case notInstalled
    /// Installed, but Google has issued no OAuth client for it to sign in with.
    case needsOAuthClient
    /// Ready to sign in: a client exists, credentials don't.
    case signedOut
    /// Credentials on disk. The method is `gws`'s own word for where they are kept.
    case signedIn(method: String)
    /// The probe itself failed — a binary that won't run, or output that isn't JSON.
    case failed(String)

    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .notInstalled: "Not installed"
        case .needsOAuthClient: "No OAuth client"
        case .signedOut: "Signed out"
        case .signedIn: "Signed in"
        case .failed: "Unavailable"
        }
    }

    /// The sentence under the status, which is where the next step is named.
    var detail: String {
        switch self {
        case .notInstalled:
            "The Google Workspace CLI isn\u{2019}t on this Mac. Next Notes runs it to read and "
                + "write your Workspace; nothing is attempted without it."
        case .needsOAuthClient:
            "Google only issues Workspace access to an OAuth client you own. Set one up "
                + "before signing in."
        case .signedOut:
            "The CLI has a client but no account. Sign in to let Next Notes act as you."
        case .signedIn(let method):
            "Credentials are stored by \(method)."
        case .failed(let reason):
            reason
        }
    }
}

/// What one `gws` invocation produced.
struct WorkspaceCLIOutput: Sendable {
    let standardOutput: Data
    let standardError: String
    let exitCode: Int32

    var text: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    /// The parsed JSON, since every `gws` command prints some.
    func json() throws -> Any {
        try JSONSerialization.jsonObject(with: standardOutput, options: [.fragmentsAllowed])
    }
}

/// Why a `gws` invocation didn't produce an answer.
///
/// The exit codes are the CLI's own contract — 1 API error, 2 not authenticated, 3 bad
/// arguments — and they are kept apart because the app answers each differently: an API
/// error is worth showing the user, a 2 sends them to the Workspace settings tab, and a 3 is
/// a bug in the tool catalogue rather than anything the user did.
enum WorkspaceCLIError: LocalizedError, Equatable {
    case notInstalled
    case notAuthenticated
    case invalidRequest(String)
    case apiFailed(String)
    case timedOut(TimeInterval)
    case launchFailed(String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The Google Workspace CLI isn\u{2019}t installed."
        case .notAuthenticated:
            "The Google Workspace CLI isn\u{2019}t signed in."
        case .invalidRequest(let detail):
            "The Workspace CLI rejected the request: \(detail)"
        case .apiFailed(let detail):
            "Google refused the request: \(detail)"
        case .timedOut(let seconds):
            "The Workspace CLI didn\u{2019}t answer within \(Int(seconds)) seconds."
        case .launchFailed(let detail):
            "The Workspace CLI wouldn\u{2019}t start: \(detail)"
        case .badOutput:
            "The Workspace CLI printed something that isn\u{2019}t JSON."
        }
    }
}

/// The Google Workspace CLI (`gws`), as the app's tool layer.
///
/// `gws` is generated from Google's Discovery service, so it covers every Workspace API
/// without this app carrying a client for any of them, and it prints JSON on stdout with a
/// documented exit code — which is exactly the shape a tool call wants. The alternative was
/// a second OAuth flow, a second token store and four hand-written REST clients.
///
/// An actor because the located path is cached and because two proposals must not race
/// each other into `which`.
actor GoogleWorkspaceCLI {
    static let shared = GoogleWorkspaceCLI()

    /// Where Homebrew, npm and cargo put it, in the order the plan names them. Probed
    /// before the login shell because spawning a shell is tens of milliseconds and this
    /// runs behind a status row that redraws on every window focus.
    private static let candidatePaths = [
        "/opt/homebrew/bin/gws",
        "/usr/local/bin/gws",
        NSHomeDirectory() + "/.cargo/bin/gws",
        NSHomeDirectory() + "/.npm-global/bin/gws",
    ]

    /// Added to `PATH` for the child process. A GUI app inherits launchd's `PATH`, which is
    /// `/usr/bin:/bin:/usr/sbin:/sbin` — so `gws` shelling out to anything of its own (the
    /// keyring helper, `open`) would fail in the app and work from a terminal.
    private static let extraSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.cargo/bin",
        NSHomeDirectory() + "/.npm-global/bin",
    ]

    /// Long enough for an upload of a meeting's audio, short enough that a wedged CLI
    /// doesn't hold an approved action open for ever.
    static let defaultTimeout: TimeInterval = 60
    /// Status probes answer in milliseconds or they are broken.
    static let probeTimeout: TimeInterval = 10

    private var cachedPath: URL?

    // MARK: - Locating

    /// The binary, or nil when there isn't one. Cached; `forget()` drops the cache after an
    /// install so the Settings tab sees the new binary without a relaunch.
    func binaryURL() async -> URL? {
        if let cachedPath, FileManager.default.isExecutableFile(atPath: cachedPath.path) {
            return cachedPath
        }
        cachedPath = nil

        for path in Self.candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            cachedPath = URL(fileURLWithPath: path)
            return cachedPath
        }
        // Last resort: whatever the user's own login shell would run. This is the path that
        // finds an install in a version manager's directory — nvm, mise, asdf — which no
        // fixed list can enumerate.
        if let found = await Self.locateThroughLoginShell() {
            cachedPath = found
            return found
        }
        return nil
    }

    /// Drops the cached location, so the next probe looks again.
    func forget() {
        cachedPath = nil
    }

    var isInstalled: Bool {
        get async { await binaryURL() != nil }
    }

    private static func locateThroughLoginShell() async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let output = try? await spawn(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-lc", "command -v gws"],
            timeout: probeTimeout
        )
        guard let output, output.exitCode == 0 else { return nil }
        let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Probes

    /// `gws 0.22.5`, or nil when the binary won't answer.
    func version() async -> String? {
        guard let output = try? await run(["--version"], timeout: Self.probeTimeout) else {
            return nil
        }
        // The version line comes with a disclaimer under it; only the first line is the
        // version, and only its last word is the number.
        return output.text
            .split(separator: "\n")
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// Where `gws auth status` says the CLI's own setup has got to.
    ///
    /// Read from the JSON rather than from the exit code: `auth status` exits 0 whether or
    /// not anyone is signed in, and the four fields below are what separate "no client",
    /// "client but no account" and "ready".
    func authState() async -> WorkspaceAuthState {
        guard await binaryURL() != nil else { return .notInstalled }
        do {
            let output = try await run(["auth", "status"], timeout: Self.probeTimeout)
            let status = try JSONDecoder().decode(AuthStatus.self, from: output.standardOutput)
            if status.hasCredentials {
                return .signedIn(method: status.credentialDescription)
            }
            return status.clientConfigExists ? .signedOut : .needsOAuthClient
        } catch let error as WorkspaceCLIError {
            if case .notAuthenticated = error { return .signedOut }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Where `gws auth setup` expects the OAuth client JSON to be, so the Settings tab can
    /// copy a downloaded one into place.
    nonisolated static var clientConfigURL: URL {
        let override = ProcessInfo.processInfo.environment["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"]
        let directory = override.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".config/gws", isDirectory: true)
        return directory.appendingPathComponent("client_secret.json")
    }

    /// The subset of `gws auth status` this app reads. Everything else it prints is about
    /// where the credentials live, which is the CLI's business.
    private struct AuthStatus: Decodable {
        let authMethod: String
        let clientConfigExists: Bool
        let encryptedCredentialsExists: Bool
        let plainCredentialsExists: Bool
        let tokenCacheExists: Bool
        let storage: String?

        enum CodingKeys: String, CodingKey {
            case authMethod = "auth_method"
            case clientConfigExists = "client_config_exists"
            case encryptedCredentialsExists = "encrypted_credentials_exists"
            case plainCredentialsExists = "plain_credentials_exists"
            case tokenCacheExists = "token_cache_exists"
            case storage
        }

        /// Signed in means a credential exists *somewhere* — the CLI keeps them in the
        /// keyring, in an encrypted file or in a plain one depending on how it was set up,
        /// and any of the three is an account.
        var hasCredentials: Bool {
            encryptedCredentialsExists || plainCredentialsExists || tokenCacheExists
                || (authMethod != "none" && !authMethod.isEmpty)
        }

        var credentialDescription: String {
            if let storage, storage != "none", !storage.isEmpty { return storage }
            return authMethod
        }
    }

    // MARK: - Running

    /// Runs one `gws` invocation and hands back what it printed.
    ///
    /// Every exit code the CLI documents is turned into a typed error here rather than at
    /// each call site, so a tool that forgets to check gets an error thrown at it instead of
    /// an empty result that looks like success.
    @discardableResult
    func run(
        _ arguments: [String],
        timeout: TimeInterval = GoogleWorkspaceCLI.defaultTimeout
    ) async throws -> WorkspaceCLIOutput {
        guard let executable = await binaryURL() else { throw WorkspaceCLIError.notInstalled }

        // Arguments, never the values inside them: a proposal's body is an email the user
        // is about to send, and a log is not where it belongs.
        Log.agent.info("gws \(arguments.first ?? "", privacy: .public) \(arguments.dropFirst().first ?? "", privacy: .public)")

        let output = try await Self.spawn(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        switch output.exitCode {
        case 0:
            return output
        case 1:
            throw WorkspaceCLIError.apiFailed(Self.firstLine(of: output.standardError))
        case 2:
            throw WorkspaceCLIError.notAuthenticated
        case 3:
            throw WorkspaceCLIError.invalidRequest(Self.firstLine(of: output.standardError))
        default:
            throw WorkspaceCLIError.apiFailed(
                "exit \(output.exitCode): \(Self.firstLine(of: output.standardError))"
            )
        }
    }

    /// Lines `gws` writes to stderr on every run, successful or not.
    ///
    /// It announces its credential backend before doing anything, so this text is present
    /// on stderr even when the command works. Taking the first stderr line as the reason
    /// therefore reported *every* failure as "Using keyring backend: keyring" — a sentence
    /// that is not an error, does not name one, and sent an hour of debugging at the
    /// Keychain instead of at the request that was actually refused.
    private static let informationalPrefixes = [
        "Using keyring backend",
        "Using credentials from",
        "Warning:",
    ]

    /// The first line of stderr that is plausibly about the failure.
    ///
    /// Falls back to the whole text rather than to "no detail": a message that was filtered
    /// down to nothing is still better read in full than discarded.
    private static func firstLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "no detail" }

        let meaningful = trimmed
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                !line.isEmpty && !informationalPrefixes.contains { line.hasPrefix($0) }
            }
        return meaningful ?? trimmed
    }

    // MARK: - Process

    /// Spawns a child, collects both pipes, and gives up after `timeout`.
    ///
    /// Both pipes are drained on their own queues rather than after the process exits: a
    /// `gws` command that prints more than a pipe buffer — any Drive listing — would
    /// otherwise block writing while this waited for it to finish, and neither side would
    /// ever move again.
    private static func spawn(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> WorkspaceCLIOutput {
        let box = ProcessBox(process: Process())
        box.process.executableURL = executable
        box.process.arguments = arguments
        box.process.environment = childEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        box.process.standardOutput = outPipe
        box.process.standardError = errPipe
        box.process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let buffers = OutputBuffers()
                let group = DispatchGroup()
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    buffers.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                }
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    buffers.setError(errPipe.fileHandleForReading.readDataToEndOfFile())
                }

                box.process.terminationHandler = { process in
                    group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                        guard !box.timedOut else {
                            box.resume(continuation, with: .failure(WorkspaceCLIError.timedOut(timeout)))
                            return
                        }
                        box.resume(continuation, with: .success(WorkspaceCLIOutput(
                            standardOutput: buffers.out,
                            standardError: String(decoding: buffers.error, as: UTF8.self),
                            exitCode: process.terminationStatus
                        )))
                    }
                }

                do {
                    try box.process.run()
                } catch {
                    // The two readers above are blocked on pipes whose write ends nobody
                    // now holds open, and `readDataToEndOfFile` on those never returns.
                    // Closing them by hand is what stops a failed launch leaking two
                    // threads every time the Settings tab probes a missing binary.
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    box.resume(
                        continuation,
                        with: .failure(WorkspaceCLIError.launchFailed(error.localizedDescription))
                    )
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard box.process.isRunning else { return }
                    box.timedOut = true
                    box.process.terminate()
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// `PATH` for the child, plus whatever the app already had.
    private static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let additions = extraSearchPaths.filter { !existing.split(separator: ":").contains(Substring($0)) }
        environment["PATH"] = (additions + [existing]).joined(separator: ":")
        environment["HOME"] = NSHomeDirectory()
        // The CLI colours its own output when it thinks it is on a terminal, and escape
        // codes in the middle of JSON are not JSON.
        environment["NO_COLOR"] = "1"
        return environment
    }
}

/// Holds the `Process` across the isolation boundaries `withTaskCancellationHandler` and
/// `terminationHandler` put it on. `Process` is not `Sendable` and the cancellation closure
/// is; the box is the smallest honest way to say "this one is shared deliberately".
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var isResumed = false
    private var timedOutFlag = false

    init(process: Process) {
        self.process = process
    }

    var timedOut: Bool {
        get { lock.withLock { timedOutFlag } }
        set { lock.withLock { timedOutFlag = newValue } }
    }

    /// Resumes at most once. A process that is terminated on timeout and then exits by
    /// itself reaches this twice, and resuming a continuation twice traps.
    func resume(
        _ continuation: CheckedContinuation<WorkspaceCLIOutput, any Error>,
        with result: Result<WorkspaceCLIOutput, any Error>
    ) {
        lock.lock()
        let alreadyResumed = isResumed
        isResumed = true
        lock.unlock()
        guard !alreadyResumed else { return }
        continuation.resume(with: result)
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}

/// Both pipes' contents, written from two queues and read from a third.
private final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errorData = Data()

    func setOut(_ data: Data) { lock.withLock { outData = data } }
    func setError(_ data: Data) { lock.withLock { errorData = data } }

    var out: Data { lock.withLock { outData } }
    var error: Data { lock.withLock { errorData } }
}
