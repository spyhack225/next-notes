import Darwin
import Foundation

/// Needle 3 by Cactus Compute: the small model that turns speech into tool calls.
///
/// ## Why this one, and why as a child process
///
/// Needle 3 is 121M parameters quantized to ~2 bits, shipped as a single 35 MB `.cact` file
/// that the engine memory-maps and reads in place. Measured on this Mac on 2026-09-19,
/// wall clock for a complete proposal including process launch and model load:
///
/// | Tools declared | Per proposal | Peak RSS |
/// |---|---|---|
/// | 2 | **126 ms** | 92 MB |
/// | 8 (what this app offers) | **~0.97 s** | ~105 MB |
/// | 14 | ~4 s | ~105 MB |
///
/// The cost is in the tool schemas, not the sentence, which is why `FunctionCallCatalogue`
/// is short rather than complete. At eight tools a card lands about a second and a half
/// after the speaker stops — inside the same breath of conversation — on ~100 MB of RSS in
/// a process that exits afterwards, which is the property the feature needs: it runs while
/// Parakeet is still transcribing without taking a lane the ASR wants.
///
/// The repo ships four ways to run it on macOS, and only one of them is honest here:
///
/// | Route | Verdict |
/// |---|---|
/// | `macos-arm64/libneedle.a` + `needle.h`, linked in | Needs `Package.swift` (a hot file), a committed 1.1 MB binary, and the app's hardened runtime would have to accept a library it did not sign. |
/// | ONNX via the sherpa runtime already vendored | There is no ONNX export. `.cact` is Cactus's own container. |
/// | Core ML conversion | The architecture (Monarch Hadamard MLP, engram gather, multi-lane hyper-connections) has no Core ML equivalent, and the confidence head and byte-level grammar live in the engine rather than the graph. |
/// | `macos-arm64/needle`, the 825 KB CLI, spawned | **This.** Nothing is committed, nothing is linked, `Package.swift` is untouched, and both files are ordinary runtime downloads with pinned hashes. |
///
/// Spawning also sidesteps the header's own warning — "one process-global, non-thread-safe
/// model" — because two proposals in flight are two processes, not one contended runtime.
/// And it is the pattern this app already uses for `gws`, so the failure modes are known.
///
/// ## Licence
///
/// Apache-2.0, which is one-way compatible with AGPL-3.0-or-later. Neither the engine nor
/// the weights are redistributed: both are fetched from Hugging Face at runtime, exactly as
/// Local model and Parakeet already are, so `THIRD-PARTY-NOTICES.md` does not change.
enum NeedleModels {
    /// The `macos-arm64` runner from `Cactus-Compute/needle3`. Ad-hoc *linker-signed*, which
    /// is what lets it execute at all on Apple Silicon — an unsigned arm64 Mach-O is killed
    /// by the kernel, not by Gatekeeper, and there would be nothing to fall back to.
    static let engine = ModelSpec(
        displayName: "Fast listening engine",
        fileName: "needle3-macos-arm64",
        url: URL(string: "https://huggingface.co/Cactus-Compute/needle3/resolve/main/macos-arm64/needle")!,
        expectedBytes: 824_744,
        // Pinned from a verified download on 2026-09-19: fetched, size-checked, hashed, and
        // only then allowed near Application Support. This one matters more than a weights
        // hash does — it is an executable.
        expectedSHA256: "bfcc14c38a7ebf670bf7ade3849b617d268120dc4cc75d3aa12c88bc7c0ba75c"
    )

    static let weights = ModelSpec(
        displayName: "Fast listening model",
        fileName: "needle3.cact",
        url: URL(string: "https://huggingface.co/Cactus-Compute/needle3/resolve/main/needle3.cact")!,
        expectedBytes: 35_335_380,
        expectedSHA256: "c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38"
    )

    /// A directory to read the two files from instead of Application Support.
    ///
    /// Set by `--selftest-function-calls <dir>` and by nothing else. It exists so the probe
    /// can exercise the real engine from a scratch copy on a machine where nobody has asked
    /// for the download — a self-test that writes 36 MB into the user's own model folder to
    /// prove itself is not a self-test, it is an install.
    nonisolated(unsafe) static var overrideDirectory: URL?

    static var engineURL: URL {
        overrideDirectory?.appendingPathComponent(engine.fileName) ?? engine.fileURL
    }

    static var weightsURL: URL {
        overrideDirectory?.appendingPathComponent(weights.fileName) ?? weights.fileURL
    }

    static var totalBytes: Int64 { engine.expectedBytes + weights.expectedBytes }

    /// "36 MB" — what the Settings row puts next to the download button.
    static var displaySize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .binary)
    }

    /// Presence is judged by size, not existence, for the reason `ModelSpec` gives: a
    /// transfer that was interrupted and then moved into place would otherwise look ready.
    static var isDownloaded: Bool {
        isFullSize(engineURL, expected: engine.expectedBytes)
            && isFullSize(weightsURL, expected: weights.expectedBytes)
    }

    private static func isFullSize(_ url: URL, expected: Int64) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return false }
        return Int64(values.fileSize ?? 0) == expected
    }

    /// Only ever true on Apple Silicon: the repo has no `macos-x86_64` engine, so an Intel
    /// Mac gets the fallback proposer and is told nothing about it.
    static var isSupportedHardware: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Fetches both files, reporting one combined 0…1 fraction.
    static func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let engineShare = Double(engine.expectedBytes) / Double(totalBytes)
        try await ModelDownloader.download(engine) { fraction in
            progress(fraction * engineShare)
        }
        try makeExecutable(engine.fileURL)
        try await ModelDownloader.download(weights) { fraction in
            progress(engineShare + fraction * (1 - engineShare))
        }
        progress(1)
    }

    /// `chmod +x`, and strip the quarantine flag if anything put one on.
    ///
    /// `URLSession` does not set `com.apple.quarantine` the way a browser does, but a file
    /// that arrives with it cannot be executed and the error — "killed: 9" — says nothing
    /// about why. Removing an attribute that is usually absent costs one syscall.
    static func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        _ = url.path.withCString { path in
            removexattr(path, "com.apple.quarantine", 0)
        }
    }
}

/// One turn's answer from the runner, as the CLI prints it.
///
/// Decoded rather than pattern-matched because the two fields this feature is built on —
/// `confidence` and `validation.ungrounded` — are the reason Needle was chosen over a
/// general small model, and a regex over the line would lose them silently.
struct NeedleResponse: Decodable, Sendable {
    struct Call: Decodable, Sendable {
        let name: String
        let arguments: [String: String]

        private enum CodingKeys: String, CodingKey { case name, arguments }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            // Arguments come back typed — a number stays a number — and everything on this
            // side of the app is a string, because every value ends up as a command-line
            // argument or a text field the user edits before approving.
            arguments = (try? container.decode([String: JSONScalar].self, forKey: .arguments))?
                .mapValues(\.stringValue) ?? [:]
        }
    }

    struct Validation: Decodable, Sendable {
        /// `"send_email.to"` — arguments the engine could not find in the input. This is the
        /// feature's safety net and it is honoured unconditionally.
        var ungrounded: [String] = []
        /// The request was phrased as a refusal ("don't send that"). Any call is dropped.
        var negation = false

        private enum CodingKeys: String, CodingKey { case ungrounded, negation }

        /// Hand-written because the synthesized initializer does not fall back to a
        /// property's default for a missing key: one absent field would make the whole
        /// object fail to decode, and `ungrounded` — the list this feature's safety rests
        /// on — would be silently lost rather than empty.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ungrounded = (try? container.decodeIfPresent([String].self, forKey: .ungrounded)) ?? []
            negation = (try? container.decodeIfPresent(Bool.self, forKey: .negation)) ?? false
        }
    }

    let type: String?
    let success: Bool?
    let error: String?
    /// `"truncated"` when the turn ran out of its token budget. The runner still exits 0
    /// and still prints a complete object, so this is the only field that says so.
    let errorCode: String?
    let functionCalls: [Call]
    let reasoning: String?
    let confidence: Double?
    let validation: Validation?

    private enum CodingKeys: String, CodingKey {
        case type, success, error, reasoning, confidence, validation
        case errorCode = "error_code"
        case functionCalls = "function_calls"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        success = try? container.decodeIfPresent(Bool.self, forKey: .success)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        errorCode = try? container.decodeIfPresent(String.self, forKey: .errorCode)
        functionCalls = (try? container.decodeIfPresent([Call].self, forKey: .functionCalls)) ?? []
        reasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        confidence = try? container.decodeIfPresent(Double.self, forKey: .confidence)
        validation = try? container.decodeIfPresent(Validation.self, forKey: .validation)
    }

    /// Argument names the engine itself flagged, for one tool.
    func ungroundedArguments(for toolID: String) -> Set<String> {
        var names = Set<String>()
        for entry in validation?.ungrounded ?? [] {
            let parts = entry.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == toolID {
                names.insert(parts[1])
            } else if parts.count == 1 {
                names.insert(parts[0])
            }
        }
        return names
    }
}

/// Any JSON leaf, flattened to the string this app stores.
struct JSONScalar: Decodable, Sendable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            stringValue = text
        } else if let number = try? container.decode(Double.self) {
            stringValue = number == number.rounded() && abs(number) < 1e15
                ? String(Int64(number))
                : String(number)
        } else if let flag = try? container.decode(Bool.self) {
            stringValue = flag ? "true" : "false"
        } else if container.decodeNil() {
            stringValue = ""
        } else {
            stringValue = ""
        }
    }
}

/// Runs the Needle CLI, one turn at a time.
///
/// An actor for the same reason `MeetingAgent` is one: the watcher can be asked twice inside
/// a second by two transcript windows, and two runners racing would double the machine's
/// load for an answer that is 130 ms away anyway.
actor NeedleRunner {
    static let shared = NeedleRunner()

    /// Generous against a cold page cache and a machine that is also transcribing. A normal
    /// turn is a fifth of a second; anything near this bound is a failure, not slow work.
    static let timeout: TimeInterval = 8

    /// The runner's own default. Measured: at 256 an utterance that is not a request at all
    /// ("yeah, I totally agree…") sends the model wandering and the turn dies with
    /// `token budget exhausted` — a failure that says nothing about the sentence. The cap
    /// also reserves context, so raising it is not free; 512 is the runner's default and it
    /// is where the truncations stopped.
    static let maxNewTokens = 512

    private var preparedToolsHash: String?
    private var toolsFileURL: URL?

    /// Where the tool list and the system-facts file are written between turns.
    ///
    /// A self-test writes nowhere near the user's own Application Support, for the same
    /// reason `--selftest-dictation` does not file its fixtures into `runs.jsonl`: a probe
    /// that leaves state behind on a real machine is a probe somebody has to clean up.
    private var workingDirectory: URL {
        if SelfTest.isRunning {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "NextNotesSelfTest-needle-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        }
        return AppIdentity.applicationSupportDirectory
            .appendingPathComponent("FunctionCalling", isDirectory: true)
    }

    /// Why the engine cannot run, or nil.
    func unavailableReason() -> String? {
        guard NeedleModels.isSupportedHardware else {
            return "Fast listening needs an Apple silicon Mac."
        }
        guard NeedleModels.isDownloaded else {
            return "Fast listening has not been downloaded yet."
        }
        return nil
    }

    /// Makes sure the engine is executable and the tool list on disk matches `tools`.
    func prepare(tools: [FunctionCallTool]) throws {
        if let reason = unavailableReason() { throw FunctionCallError.notReady(reason) }
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        try NeedleModels.makeExecutable(NeedleModels.engineURL)

        let hash = Self.hash(of: tools)
        guard hash != preparedToolsHash || toolsFileURL == nil else { return }
        let url = workingDirectory.appendingPathComponent("tools-\(hash).json")
        let payload = try JSONSerialization.data(
            withJSONObject: tools.map(\.json),
            options: [.sortedKeys]
        )
        try payload.write(to: url, options: .atomic)
        preparedToolsHash = hash
        toolsFileURL = url
    }

    /// One turn. `facts` become the `--system` file: today's date, who the user is.
    func run(input: String, tools: [FunctionCallTool], facts: [String]) async throws -> NeedleResponse {
        try prepare(tools: tools)
        guard let toolsFileURL else { throw FunctionCallError.notReady("no tool list") }

        var systemURL: URL?
        if !facts.isEmpty {
            let url = workingDirectory.appendingPathComponent("system.txt")
            try facts.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            systemURL = url
        }

        var arguments = [
            "--model", NeedleModels.weightsURL.path,
            "--tools", toolsFileURL.path,
            "--max", String(Self.maxNewTokens),
            "--prompt", input,
        ]
        if let systemURL {
            arguments.append(contentsOf: ["--system", systemURL.path])
        }

        let output = try await Self.spawn(
            executable: NeedleModels.engineURL,
            arguments: arguments,
            timeout: Self.timeout
        )
        guard output.status == 0 else {
            throw FunctionCallError.engineFailed(
                Self.firstLine(of: output.standardError, fallback: "exit \(output.status)")
            )
        }
        // The runner prints one JSON object per turn, but a warning on stdout would make the
        // whole thing unparseable — so take the last line that starts an object.
        guard let line = output.standardOutput
            .split(separator: "\n")
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
            let data = line.data(using: .utf8) else {
            throw FunctionCallError.badOutput("no JSON on stdout")
        }
        do {
            return try JSONDecoder().decode(NeedleResponse.self, from: data)
        } catch {
            throw FunctionCallError.badOutput(String(describing: error))
        }
    }

    /// Stable, short identity for a tool set, so the file on disk is reused between turns.
    static func hash(of tools: [FunctionCallTool]) -> String {
        let joined = tools
            .map { "\($0.id)|\($0.description)|\($0.parameters.map(\.name).joined(separator: ","))" }
            .sorted()
            .joined(separator: "\n")
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(joined.utf8) {
            value ^= UInt64(byte)
            value &*= 0x100_0000_01b3
        }
        return String(value, radix: 36)
    }

    static func firstLine(of text: String, fallback: String) -> String {
        let line = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? fallback
    }

    // MARK: - Process

    struct Output: Sendable {
        let standardOutput: String
        let standardError: String
        let status: Int32
    }

    /// Spawns the runner and drains both pipes off the calling thread.
    ///
    /// Both pipes are read on their own queues rather than after exit, for the reason
    /// `GoogleWorkspaceCLI.spawn` documents: a child that writes more than a pipe buffer
    /// blocks, and a parent waiting for it to finish never reads, and neither moves again.
    /// Needle's output is one short line today; that is not a guarantee worth betting on.
    private static func spawn(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> Output {
        let box = NeedleProcessBox()
        box.process.executableURL = executable
        box.process.arguments = arguments
        box.process.standardInput = FileHandle.nullDevice
        // Nothing from the parent's environment matters, and a child that inherits a shell's
        // locale prints numbers with a comma in them.
        box.process.environment = ["PATH": "/usr/bin:/bin", "NO_COLOR": "1", "LC_ALL": "C"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        box.process.standardOutput = outPipe
        box.process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            let buffers = NeedleBuffers()
            let group = DispatchGroup()
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                buffers.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
            }
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                buffers.setError(errPipe.fileHandleForReading.readDataToEndOfFile())
            }

            box.process.terminationHandler = { process in
                group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                    if box.timedOut {
                        box.resume(continuation, with: .failure(FunctionCallError.timedOut(timeout)))
                        return
                    }
                    box.resume(continuation, with: .success(Output(
                        standardOutput: String(decoding: buffers.out, as: UTF8.self),
                        standardError: String(decoding: buffers.error, as: UTF8.self),
                        status: process.terminationStatus
                    )))
                }
            }

            do {
                try box.process.run()
            } catch {
                // The two readers are blocked on pipes whose write ends nobody holds open
                // now, and `readDataToEndOfFile` on those never returns. Closing them by
                // hand is what stops a failed launch leaking two threads per attempt.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                box.resume(
                    continuation,
                    with: .failure(FunctionCallError.engineFailed(error.localizedDescription))
                )
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard box.process.isRunning else { return }
                box.timedOut = true
                box.process.terminate()
            }
        }
    }
}

/// One-shot continuation guard around a `Process`. `terminationHandler` and the timeout can
/// both fire; resuming a continuation twice traps.
private final class NeedleProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var resumed = false
    private var _timedOut = false

    var timedOut: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _timedOut }
        set { lock.lock(); _timedOut = newValue; lock.unlock() }
    }

    func resume(
        _ continuation: CheckedContinuation<NeedleRunner.Output, Error>,
        with result: Result<NeedleRunner.Output, Error>
    ) {
        lock.lock()
        let alreadyResumed = resumed
        resumed = true
        lock.unlock()
        guard !alreadyResumed else { return }
        continuation.resume(with: result)
    }
}

private final class NeedleBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _error = Data()

    var out: Data { lock.lock(); defer { lock.unlock() }; return _out }
    var error: Data { lock.lock(); defer { lock.unlock() }; return _error }

    func setOut(_ data: Data) { lock.lock(); _out = data; lock.unlock() }
    func setError(_ data: Data) { lock.lock(); _error = data; lock.unlock() }
}
