import Darwin
import Foundation

/// The persistent Needle engine: one `--serve` child, many turns.
///
/// ## Why this exists
///
/// The first version of this feature spawned `needle3-macos-arm64 --prompt …` once per
/// proposal, and that is what the decision-gate benchmark measured: **p50 615 ms per
/// decision** (`bench/decision-gate/report.md`), most of it process launch, weight mapping
/// and the prefill of a static prefix that never changes between turns. The engine ships a
/// server mode of its own — `--serve [--port N]` with `POST /complete {"input": …}` and
/// `POST /reset` — so the same 35 MB model can stay resident and only the turn is paid for.
///
/// Measured on this Mac on 2026-09-23, the benchmark's own fixtures, the app's own 8-tool
/// catalogue (`bench/decision-gate/report.md`):
///
/// | Route | Per proposal | Start-up |
/// |---|---|---|
/// | spawn per proposal | p50 290–615 ms, by machine load | — |
/// | `--serve`, warm | **p50 56–60 ms** | 180–430 ms once |
///
/// The start-up is paid once per run of the feature, not once per sentence, and the watcher
/// pays it on a meeting's first transcript rather than on its first proposal (`warm`).
/// `--reset` runs before every turn because the server keeps per-turn state the spawn path
/// never had: an identical prompt scored 0.78 on a fresh engine, 0.93 after another turn,
/// and 0.78 again after a reset. It costs 0.7 ms, and it is what keeps one proposal from
/// colouring the next.
///
/// ## Lifecycle
///
/// Started by the watcher's first transcript, or by the first proposal when that never
/// happened. Stopped when the feature is switched off, when the app terminates, after
/// `idleTimeout` of quiet, and at the end of a self-test. A crash can run none of those, so
/// every start first reaps a server whose owning process is gone — recorded as
/// `server-<owner>.json` in the working directory, and verified with `proc_pidpath` before
/// any signal so a recycled pid is never killed.
///
/// ## The fallback is not a courtesy
///
/// `NeedleRunner.run` still spawns one turn when this throws, because the difference between
/// the two routes is latency, not correctness. A machine where the port is taken, or the
/// serve mode fails for any other reason, must keep working at the old speed rather than
/// lose the feature.
actor NeedleServer {
    static let shared = NeedleServer()

    /// Ten quiet minutes — the same window the notes model and the avatar use before they
    /// let go of their resources. The resident cost is ~92 MB.
    static let idleTimeout: TimeInterval = 600

    /// One HTTP round trip's ceiling. A warm turn is ~60 ms; anything near this is a fault.
    static let requestTimeout: TimeInterval = 8

    /// How long the first turn may wait for the model to load and the socket to answer.
    static let startTimeout: TimeInterval = 20

    /// Ports are chosen by the kernel and a busy one is retried on a fresh port.
    static let maximumStartAttempts = 3

    /// Everything the child is launched with. A change to any field needs a new child: the
    /// tool schemas and the system facts are read once at startup, not per request.
    struct Configuration: Equatable, Sendable {
        var executable: URL
        var weights: URL
        var toolsFile: URL
        /// The joined `--system` text; empty means the child is launched without one.
        var facts: String
        /// Where the orphan record is written, and where a previous one is looked for.
        var workingDirectory: URL
    }

    enum ServerError: LocalizedError {
        case launchFailed(String)
        case exited(String)
        case neverBecameReady
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let why):
                "the fast listening server did not start: \(why)"
            case .exited(let why):
                "the fast listening server stopped: \(why)"
            case .neverBecameReady:
                "the fast listening server did not answer in time"
            case .badResponse(let why):
                "the fast listening server answered with something unusable: \(why)"
            }
        }
    }

    private var process: Process?
    private var port: Int?
    private var configuration: Configuration?
    private var startTask: Task<Child, Error>?
    private var idleTask: Task<Void, Never>?
    private var lastActivity: Date?
    /// Whether the static prefix has been prefilled. The first turn on a fresh child is the
    /// expensive one (worst measured: ~1.1 s on a loaded machine; 51 ms on a quiet one);
    /// every turn after is ~60 ms.
    private var isWarm = false
    /// Where the orphan record of the adopted child lives. Kept beside `configuration`
    /// because `stop()` has to remove the record after clearing it.
    private var lastWorkingDirectory: URL?
    /// Bumped by every `stop()`, so a start that was overtaken by one does not adopt a
    /// child nobody asked for any more.
    private var generation = 0

    /// Diagnostics for `--selftest-function-calls`: how many turns the resident child
    /// answered, and what starting it cost. Read through `NeedleRunner`.
    private(set) var servedTurns = 0
    private(set) var lastStartSeconds: TimeInterval?

    /// The live child, readable without the actor so `applicationWillTerminate` — which
    /// cannot await — can stop it.
    private let live = LiveServerProcess()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = NeedleServer.requestTimeout
        configuration.timeoutIntervalForResource = NeedleServer.requestTimeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }()

    // MARK: - One turn

    /// One turn through the resident engine. Starts the child if it is not running and
    /// restarts it when the configuration changed.
    func complete(input: String, configuration: Configuration) async throws -> NeedleResponse {
        let child = try await ensureRunning(configuration)
        do {
            let response = try await send(input, port: child.port)
            servedTurns += 1
            isWarm = true
            noteActivity()
            return response
        } catch {
            // A dead or wedged child is not worth keeping: clear it so the next call starts
            // a fresh one, and let the caller fall back to a spawn for this turn.
            stop()
            throw error
        }
    }

    /// Starts the child and pays the first turn's prefill before anybody needs it.
    ///
    /// The first inference on a fresh child is the expensive one — the tool schemas and the
    /// session facts are prefilled once and reused — and the first proposal of a meeting is
    /// exactly when that would be most visible. The spawn path this replaced paid only its
    /// own launch, so without a warm-up the first card of a meeting would be slower than the
    /// design the server removed. The watcher asks for this as soon as a meeting produces any
    /// transcript at all, usually minutes before anyone asks the app to do something.
    ///
    /// Never throws: the engine is a latency optimisation, and the first real proposal
    /// reports whatever is actually wrong.
    func warm(configuration: Configuration) async {
        do {
            if isWarm, configuration == self.configuration, process != nil { return }
            let child = try await ensureRunning(configuration)
            guard !isWarm else { return }
            // A sentence that names nothing, then a reset so the turn cannot be inherited.
            _ = try? await send(".", port: child.port)
            _ = try? await Self.post(
                "/reset", body: Data("{}".utf8), port: child.port, timeout: Self.requestTimeout
            )
            isWarm = true
            noteActivity()
        } catch {
            Log.agent.info(
                "fast listening engine not warmed (\(error.localizedDescription, privacy: .public))"
            )
        }
    }

    /// Stops the child without awaiting. For `applicationWillTerminate`, which cannot.
    nonisolated func terminateNow() {
        live.current?.terminate()
    }

    func stop() {
        generation &+= 1
        idleTask?.cancel()
        idleTask = nil
        let directory = lastWorkingDirectory
        if let process {
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
        }
        process = nil
        port = nil
        configuration = nil
        lastActivity = nil
        isWarm = false
        live.set(nil)
        if let directory {
            Self.removeRecord(owner: ProcessInfo.processInfo.processIdentifier, in: directory)
        }
        lastWorkingDirectory = nil
    }

    /// The child's pid while it is running, or nil. Self-test diagnostics only.
    func liveProcessIdentifier() -> pid_t? {
        process?.processIdentifier
    }

    // MARK: - Child management

    /// The live child. `@unchecked Sendable` because `Process` is not `Sendable` and the
    /// only thing that ever touches this value is the actor.
    private struct Child: @unchecked Sendable {
        var port: Int
        var process: Process
    }

    private func ensureRunning(_ configuration: Configuration) async throws -> Child {
        if configuration == self.configuration, let process, let port {
            return Child(port: port, process: process)
        }
        // A start already in flight answers this call too — two proposals a second apart
        // must not race two 35 MB loads. The winner adopts the child and sets
        // `configuration`; this caller simply asks again and finds it.
        if let startTask {
            _ = try? await startTask.value
            return try await ensureRunning(configuration)
        }
        stop()
        let generationAtStart = generation
        let task = Task { [live] in
            try await Self.launch(configuration: configuration, live: live)
        }
        startTask = task
        defer { startTask = nil }
        let started = Date()
        let child = try await task.value
        guard generation == generationAtStart else {
            // A stop overtook the launch — the feature was switched off, or the app is
            // going away. The child is not ours to keep.
            child.process.terminate()
            throw ServerError.launchFailed("stopped while starting")
        }
        process = child.process
        port = child.port
        self.configuration = configuration
        lastWorkingDirectory = configuration.workingDirectory
        lastStartSeconds = Date().timeIntervalSince(started)
        live.set(child.process)
        Self.writeRecord(
            owner: ProcessInfo.processInfo.processIdentifier,
            child: child.process.processIdentifier,
            port: child.port,
            in: configuration.workingDirectory
        )
        child.process.terminationHandler = { [weak self] finished in
            let pid = finished.processIdentifier
            Task { await self?.childExited(pid: pid) }
        }
        return child
    }

    /// The child died on its own. Clears the state so the next turn starts a fresh one, and
    /// says so — a silent restart would hide a machine that is killing the engine.
    private func childExited(pid: pid_t) {
        guard process?.processIdentifier == pid else { return }
        Log.agent.info("fast listening engine exited; the next proposal will start a new one")
        stop()
    }

    private func noteActivity() {
        lastActivity = Date()
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard process != nil, let lastActivity else { return }
        guard Date().timeIntervalSince(lastActivity) >= Self.idleTimeout else { return }
        Log.agent.info(
            "stopping the fast listening engine after \(Int(Self.idleTimeout / 60)) idle minutes"
        )
        stop()
    }

    // MARK: - Starting

    private static func launch(
        configuration: Configuration,
        live: LiveServerProcess
    ) async throws -> Child {
        try FileManager.default.createDirectory(
            at: configuration.workingDirectory,
            withIntermediateDirectories: true
        )
        reapOrphans(in: configuration.workingDirectory, engine: configuration.executable)

        var systemURL: URL?
        if !configuration.facts.isEmpty {
            let url = configuration.workingDirectory.appendingPathComponent("system.txt")
            try configuration.facts.write(to: url, atomically: true, encoding: .utf8)
            systemURL = url
        }

        var lastFailure = "the engine did not start"
        for _ in 0..<maximumStartAttempts {
            do {
                return try await start(
                    configuration: configuration,
                    systemURL: systemURL,
                    port: try freePort(),
                    live: live
                )
            } catch ServerError.exited(let why) {
                // A port collision is reported as an exit with "cannot serve on port N",
                // and it is the one failure worth retrying on a different port. Anything
                // else that exits this early will exit again, but two retries are cheap
                // next to giving up on the fast path for the rest of the session.
                lastFailure = why
            }
        }
        throw ServerError.launchFailed(lastFailure)
    }

    private static func start(
        configuration: Configuration,
        systemURL: URL?,
        port: Int,
        live: LiveServerProcess
    ) async throws -> Child {
        let process = Process()
        process.executableURL = configuration.executable
        var arguments = [
            "--model", configuration.weights.path,
            "--tools", configuration.toolsFile.path,
            "--serve",
            "--port", String(port),
        ]
        if let systemURL {
            arguments.append(contentsOf: ["--system", systemURL.path])
        }
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // Nothing from the parent's environment matters, and a child that inherits a shell's
        // locale prints numbers with a comma in them.
        process.environment = ["PATH": "/usr/bin:/bin", "NO_COLOR": "1", "LC_ALL": "C"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffers = NeedleBuffers()
        DispatchQueue.global(qos: .userInitiated).async {
            buffers.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global(qos: .userInitiated).async {
            buffers.setError(errPipe.fileHandleForReading.readDataToEndOfFile())
        }

        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw ServerError.launchFailed(error.localizedDescription)
        }
        // Before the socket answers, so a termination during start-up does not leak a child
        // whose only handle was this function's local.
        live.set(process)

        let started = Date()
        let deadline = started.addingTimeInterval(startTimeout)
        while Date() < deadline {
            if !process.isRunning {
                if live.current === process { live.set(nil) }
                let error = String(decoding: buffers.error, as: UTF8.self)
                throw ServerError.exited(
                    NeedleRunner.firstLine(of: error, fallback: "exit \(process.terminationStatus)")
                )
            }
            if (try? await post(
                "/reset", body: Data("{}".utf8), port: port, timeout: 1
            )) != nil {
                return Child(port: port, process: process)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if live.current === process { live.set(nil) }
        process.terminate()
        throw ServerError.neverBecameReady
    }

    // MARK: - HTTP

    private func send(_ input: String, port: Int) async throws -> NeedleResponse {
        // The engine accumulates per-turn state the spawn path never had; reset first so one
        // proposal cannot colour the next. Non-fatal: if reset fails the complete below will
        // fail too, and report something more useful than "reset failed".
        _ = try? await Self.post(
            "/reset", body: Data("{}".utf8), port: port, timeout: Self.requestTimeout
        )
        // **Compact JSON only.** The engine's serve-mode request parser does not accept
        // whitespace around the colon: `{"input": "…"}` is read as an empty input and the
        // model answers from the prefix alone — measured on 2026-09-23, every such turn came
        // back the same canned call at full speed, and a hand-written client with a space
        // after the colon reproduced it. `JSONEncoder` never emits that whitespace, which is
        // why this is a comment and not a formatter; a hand-rolled request must not be.
        let body: Data
        do {
            body = try JSONEncoder().encode(CompleteRequest(input: input))
        } catch {
            throw ServerError.badResponse(String(describing: error))
        }
        let data = try await Self.post(
            "/complete", body: body, port: port, timeout: Self.requestTimeout
        )
        do {
            return try JSONDecoder().decode(NeedleResponse.self, from: data)
        } catch {
            throw ServerError.badResponse(String(describing: error))
        }
    }

    private struct CompleteRequest: Encodable {
        let input: String
    }

    private static func post(
        _ path: String,
        body: Data,
        port: Int,
        timeout: TimeInterval
    ) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw ServerError.badResponse("bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerError.badResponse("not HTTP")
        }
        guard http.statusCode == 200 else {
            throw ServerError.badResponse("HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: - Ports

    /// A port the kernel says is free right now, reserved and released immediately.
    ///
    /// The child binds it milliseconds later, so there is a theoretical race; a collision is
    /// what `maximumStartAttempts` retries.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.launchFailed("no socket") }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ServerError.launchFailed("no free port") }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw ServerError.launchFailed("no free port") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    // MARK: - Orphans

    private static let recordPrefix = "server-"

    private struct Record: Codable {
        var owner: pid_t
        var pid: pid_t
        var port: Int
    }

    private static func recordURL(owner: pid_t, in directory: URL) -> URL {
        directory.appendingPathComponent("\(recordPrefix)\(owner).json")
    }

    private static func writeRecord(owner: pid_t, child: pid_t, port: Int, in directory: URL) {
        let record = Record(owner: owner, pid: child, port: port)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: recordURL(owner: owner, in: directory), options: .atomic)
    }

    private static func removeRecord(owner: pid_t, in directory: URL) {
        try? FileManager.default.removeItem(at: recordURL(owner: owner, in: directory))
    }

    /// Stops a server left behind by a crashed launch of this app.
    ///
    /// The record names the app pid that owned it. A record whose owner is still running
    /// belongs to another copy of the app and is left alone. The child is only signalled
    /// after `proc_pidpath` says that pid really is this engine — a record outlives the pid
    /// it names, and pids are recycled.
    private static func reapOrphans(in directory: URL, engine: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries
        where entry.lastPathComponent.hasPrefix(recordPrefix) && entry.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: entry) }
            guard let data = try? Data(contentsOf: entry),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  kill(record.owner, 0) != 0, errno == ESRCH else { continue }
            guard let path = processPath(record.pid) else { continue }
            let resolved = URL(fileURLWithPath: path)
            guard resolved.path == engine.path
                || resolved.lastPathComponent == engine.lastPathComponent else { continue }
            kill(record.pid, SIGTERM)
            Log.agent.info("stopped a fast listening engine left behind by a previous launch")
        }
    }

    private static func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The one piece of actor state a synchronous hook has to reach: the child process itself.
/// Every access is under the lock.
private final class LiveServerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    var current: Process? {
        lock.lock()
        defer { lock.unlock() }
        return process
    }

    func set(_ process: Process?) {
        lock.lock()
        self.process = process
        lock.unlock()
    }
}
