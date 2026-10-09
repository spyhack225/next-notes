import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import Observation

private final class TurnAudioSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// The sink can deliver 10 ms hardware buffers while a cold EOU model takes
/// seconds to prepare. Bound queued *audio time*, not the number of callbacks.
private final class TurnAudioBacklog: @unchecked Sendable {
    typealias Entry = (AudioChunk, Date, Int)
    private let lock = NSLock()
    private let maxFrames = 96_000 // six seconds of canonical 16 kHz mono
    private var entries: [Entry] = []
    private var frames = 0
    private var closed = false
    let events: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        signal = pair.continuation
    }

    func enqueue(_ entry: Entry) -> Int {
        lock.lock()
        guard !closed else { lock.unlock(); return 0 }
        entries.append(entry)
        frames += Int(entry.0.buffer.frameLength)
        var dropped = 0
        while frames > maxFrames && !entries.isEmpty {
            frames -= Int(entries.removeFirst().0.buffer.frameLength)
            dropped += 1
        }
        lock.unlock()
        signal.yield(())
        return dropped
    }

    func take() -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        frames -= Int(entry.0.buffer.frameLength)
        return entry
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func queuedFrames() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func finish() {
        lock.lock()
        closed = true
        entries.removeAll()
        frames = 0
        lock.unlock()
        signal.finish()
    }
}


/// Bounded input state within Capture's session. Capture closes admission and
/// joins the retained load/probe handles; this has no audio stream or backlog.
private final class CaptureVoiceActivityInput: @unchecked Sendable {
    struct Probe: Sendable {
        let captureID: UUID
        let outputGeneration: UInt64
        let probability: Float
        let echoOK: Bool
        let at: UInt64
    }
    struct Snapshot: Sendable {
        let ready: Bool
        let prepared: Bool
        let artifact: String?
        let failure: String?
        let nativeProbes: Int
    }
    private let lock = NSLock()
    private var captureID: UUID?
    private var pendingCaptureID: UUID?
    private let callback: @Sendable (Probe) async -> Void
    private var active = true
    private var closed = false
    private var manager: VadManager?
    private var artifact: String?
    private var failure: String?
    private var nativeProbes = 0
    private var samples: [Float] = []
    private var newSamples = 0
    private var nearEvidence: (generation: UInt64, at: UInt64)?
    private var windowGeneration: UInt64?
    private var busy = false
    private var loadTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?

    init(captureID: UUID?, retiring: Task<Void, Never>?,
         cachedOnly: Bool = false, cachedModel: URL? = nil, skipModelForTesting: Bool = false,
         callback: @escaping @Sendable (Probe) async -> Void) {
        self.captureID = captureID
        self.callback = callback
        active = captureID != nil
        if SelfTest.isRunning && skipModelForTesting { return }
        let offline = SelfTest.isRunning
        loadTask = Task.detached(priority: .utility) { [self] in
            await retiring?.value
            do {
                try Task.checkCancellation()
                if cachedOnly {
                    let quiet = await ComputeScheduler.shared.occupancy().busy.isEmpty
                    guard quiet, ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork,
                          ProcessInfo.processInfo.thermalState == .nominal else {
                        finishLoad(nil, artifact: nil, failure: "Optional VAD preparation was not admitted.")
                        return
                    }
                }
                let config = VadConfig(defaultThreshold: 0.5,
                    computeUnits: .cpuAndNeuralEngine)
                let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                    in: .userDomainMask)[0].appendingPathComponent("FluidAudio/Models/silero-vad-coreml")
                let present = cachedModel ?? Self.cachedModelURL(offline: offline)
                let loaded: VadManager
                let description: String
                if let present {
                    let configuration = MLModelConfiguration()
                    configuration.computeUnits = config.computeUnits
                    let model = try MLModel(contentsOf: present, configuration: configuration)
                    try Task.checkCancellation()
                    loaded = VadManager(config: config, vadModel: model)
                    description = present.absoluteString
                } else {
                    // Diagnostic/optional cached preparation never downloads. Only the
                    // unchanged ordinary capture fallback uses FluidAudio's ModelHub.
                    guard !offline && !cachedOnly else { throw CocoaError(.fileNoSuchFile) }
                    loaded = try await VadManager(config: config)
                    description = directory.appendingPathComponent(
                        "silero-vad-unified-256ms-v6.2.1.mlmodelc").absoluteString
                }
                try Task.checkCancellation()
                if cachedOnly {
                    // Prime the SAME stateless graph; no invented PCM enters capture's ring,
                    // no generation-bound probe/callback or conversation effect is emitted.
                    let primed = try await loaded.process([Float](repeating: 0, count: VadManager.chunkSize))
                    _ = try Self.validProbability(primed)
                    try Task.checkCancellation()
                    guard ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork else {
                        finishLoad(nil, artifact: nil, failure: "Optional VAD preparation was released under pressure.")
                        return
                    }
                }
                finishLoad(loaded, artifact: description, failure: nil)
            } catch {
                finishLoad(nil, artifact: nil, failure: error.localizedDescription)
            }
        }
    }

    static func cachedModelURL(offline: Bool) -> URL? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("FluidAudio/Models/silero-vad-coreml")
        let names = offline ? ["silero-vad-unified-256ms-v6.0.0.mlmodelc"]
            : ["silero-vad-unified-256ms-v6.2.1.mlmodelc",
               "silero-vad-unified-256ms-v6.0.0.mlmodelc"]
        return names.map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func finishLoad(_ manager: VadManager?, artifact: String?, failure: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        self.manager = manager
        self.artifact = artifact
        self.failure = failure
    }
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(ready: active && manager != nil, prepared: manager != nil, artifact: artifact,
                        failure: failure, nativeProbes: nativeProbes)
    }
    func waitUntilLoaded() async { await loadTask?.value }

    /// Reopen the SAME model owner; retire native work off the capture/key-down path.
    /// Incoming new-session PCM stays bounded while that native drain settles.
    func activate(captureID: UUID, retiring: Task<Void, Never>?) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        let loading = loadTask
        self.captureID = nil
        pendingCaptureID = captureID
        active = false
        samples.removeAll(keepingCapacity: true)
        newSamples = 0
        nearEvidence = nil
        windowGeneration = nil
        nativeProbes = 0
        loadTask = Task.detached(priority: .utility) { [self] in
            await retiring?.value
            await loading?.value
            guard !Task.isCancelled else { return }
            finishActivation(captureID)
        }
        lock.unlock()
    }
    private func finishActivation(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, pendingCaptureID == id else { return }
        captureID = id
        pendingCaptureID = nil
        active = true
    }

    /// Refuse callbacks/PCM now, join the existing native handles, retain only weights.
    func suspend() -> Task<Void, Never> {
        lock.lock()
        active = false
        captureID = nil
        pendingCaptureID = nil
        samples.removeAll(keepingCapacity: true)
        newSamples = 0
        nearEvidence = nil
        windowGeneration = nil
        let loading = loadTask, probing = probeTask
        lock.unlock()
        probing?.cancel()
        return Task.detached(priority: .utility) { [self] in
            await loading?.value
            await probing?.value
            // A pressure event may have arrived while this capture was active.
            if !ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork {
                releaseAfterSuspendIfIdle()
            }
        }
    }
    private func releaseAfterSuspendIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard !active, captureID == nil, pendingCaptureID == nil else { return }
        manager = nil
        artifact = nil
        failure = "Voice activity model was released under pressure."
    }
    private func retainedProbe() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return probeTask
    }
    func waitForProbe() async { await retainedProbe()?.value }

    func ingest(_ buffer: AVAudioPCMBuffer, evidence: AcousticEchoProcessor.Evidence,
                outputGeneration: UInt64?, at: UInt64) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
              !buffer.format.isInterleaved, let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        lock.lock()
        guard !closed, captureID != nil || pendingCaptureID != nil else { lock.unlock(); return }
        if windowGeneration != outputGeneration {
            samples.removeAll(keepingCapacity: true)
            newSamples = 0
            nearEvidence = nil
            windowGeneration = outputGeneration
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        if samples.count > VadManager.chunkSize { samples.removeFirst(samples.count - VadManager.chunkSize) }
        newSamples = min(VadManager.chunkSize, newSamples + count)
        // The probability describes the whole256ms window. Match independent
        // near evidence to that same window, rather than only its last10ms chunk.
        // Keep it bound to the current output so an older utterance cannot duck
        // a successor reply.
        if nearEvidence?.generation != outputGeneration { nearEvidence = nil }
        if let outputGeneration,
           evidence.independentNearCandidate || evidence.nearCandidate {
            nearEvidence = (outputGeneration, at)
        }
        guard active, samples.count == VadManager.chunkSize, newSamples >= 800,
              !busy, let manager, let captureID, let outputGeneration else { lock.unlock(); return }
        newSamples %= 800
        busy = true
        let window = samples
        let predecessor = probeTask
        let windowNanos = UInt64(VadManager.chunkSize) * 62_500
        let echoOK = !evidence.recentReference || (nearEvidence.map {
            $0.generation == outputGeneration && at >= $0.at && at - $0.at <= windowNanos
        } ?? false)
        probeTask = Task.detached(priority: .userInitiated) { [self] in
            await predecessor?.value
            do {
                try Task.checkCancellation()
                let results = try await manager.process(window)
                try Task.checkCancellation()
                let probability = try Self.validProbability(results)
                let admitted = completedProbe(captureID: captureID)
                if admitted {
                    await callback(Probe(captureID: captureID, outputGeneration: outputGeneration,
                        probability: probability, echoOK: echoOK, at: at))
                }
            } catch {
                if !(error is CancellationError) { disable(error.localizedDescription) }
            }
            finishProbe()
        }
        lock.unlock()
    }
    private static func validProbability(_ results: [VadResult]) throws -> Float {
        guard results.count == 1, let result = results.first,
              result.probability.isFinite, (0...1).contains(result.probability) else {
            throw CocoaError(.coderInvalidValue)
        }
        return result.probability
    }

    private func completedProbe(captureID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, self.captureID == captureID else { return false }
        nativeProbes += 1
        return true
    }
    private func disable(_ message: String) {
        lock.lock()
        manager = nil
        failure = message
        lock.unlock()
    }
    private func finishProbe() {
        lock.lock()
        busy = false
        lock.unlock()
    }


    /// The real ingest owns the window. This isolated test skips only model
    /// construction and observes its actual PCM/state before native submission.
    static func windowGenerationSelfTestFailures() async -> [String] {
        guard SelfTest.isRunning else { return ["VAD window fixture requires self-test mode"] }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
            let pcm = buffer.floatChannelData?[0] else { return ["VAD window fixture PCM unavailable"] }
        buffer.frameLength = 160
        let input = CaptureVoiceActivityInput(captureID: UUID(), retiring: nil,
            skipModelForTesting: true) { _ in }
        var failures: [String] = []
        var time: UInt64 = 1_000_000_000
        func ingest(_ generation: UInt64?, near: Bool, value: Float) {
            for index in 0..<160 { pcm[index] = value }
            time += 10_000_000
            let evidence = AcousticEchoProcessor.Evidence(aecProcessed: true,
                recentReference: true, nearCandidate: near, independentNearCandidate: near,
                echoCoherence: 0, bestCoherence: 0, bestLagSamples: 0,
                referenceUnderflow: false, queuedReferenceSamples: 160,
                rawRMS: 0.1, cleanedRMS: 0.1, referenceRMS: 0.1)
            input.ingest(buffer, evidence: evidence, outputGeneration: generation, at: time)
        }
        func window() -> (frames: Int, pending: Int, first: Float?, near: UInt64?) {
            input.lock.lock()
            defer { input.lock.unlock() }
            return (input.samples.count, input.newSamples, input.samples.first,
                    input.nearEvidence?.generation)
        }
        ingest(1, near: true, value: 0.25)
        ingest(1, near: false, value: 0.25)
        if window().frames != 320 || window().pending != 320 || window().near != 1 {
            failures.append("same output generation failed to retain actual warm PCM/evidence")
        }
        ingest(2, near: false, value: -0.5)
        if window().frames != 160 || window().pending != 160
            || window().first != -0.5 || window().near != nil {
            failures.append("successor VAD window retained prior output PCM or pending frames")
        }
        ingest(nil, near: false, value: 0.125)
        if window().frames != 160 || window().pending != 160
            || window().first != 0.125 || window().near != nil {
            failures.append("idle VAD window retained prior speaking output PCM")
        }
        ingest(nil, near: false, value: 0.125)
        if window().frames != 320 { failures.append("unchanged idle input failed to retain bounded PCM") }
        ingest(3, near: true, value: -0.25)
        if window().frames != 160 || window().pending != 160
            || window().first != -0.25 || window().near != 3 {
            failures.append("new output VAD window retained idle PCM or lost fresh near evidence")
        }
        ingest(3, near: false, value: -0.25)
        if window().frames != 320 || window().near != 3 {
            failures.append("same successor generation discarded warm PCM/near evidence")
        }
        for _ in 0..<30 { ingest(3, near: false, value: -0.25) }
        if window().frames != VadManager.chunkSize || window().pending != VadManager.chunkSize
            || input.snapshot().ready || input.snapshot().nativeProbes != 0 {
            failures.append("isolated actual VAD input lost its bounded window or launched a native probe")
        }
        await input.close().value
        ingest(4, near: true, value: 0.5)
        if window().frames != 0 || input.snapshot().ready || input.snapshot().nativeProbes != 0 {
            failures.append("closed input admitted new window PCM or native work")
        }
        return failures
    }
    func nativeManagerForResidentTesting() -> VadManager? {
        guard SelfTest.requested == "--selftest-voice-turns",
              CommandLine.arguments.contains("--voice-duck-resident") else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return manager
    }

    func holdProbeForResidentTesting(_ hold: VoiceInputProducerProbe) {
        guard SelfTest.requested == "--selftest-voice-turns",
              CommandLine.arguments.contains("--voice-duck-resident") else { return }
        lock.lock()
        let predecessor = probeTask
        probeTask = Task.detached {
            await predecessor?.value
            await hold.holdPreparedDecoder()
        }
        lock.unlock()
    }

    func resetSamplesForTesting() {
        guard SelfTest.isRunning else { return }
        lock.lock()
        samples.removeAll()
        newSamples = 0
        nearEvidence = nil
        lock.unlock()
    }
    func close() -> Task<Void, Never> {
        lock.lock()
        active = false
        closed = true
        captureID = nil
        pendingCaptureID = nil
        samples.removeAll()
        newSamples = 0
        nearEvidence = nil
        windowGeneration = nil
        manager = nil
        let loading = loadTask, probing = probeTask
        lock.unlock()
        loading?.cancel()
        probing?.cancel()
        return Task.detached(priority: .utility) {
            await loading?.value
            await probing?.value
        }
    }
}

/// Continuous agent listen: wake or ⇧⌘ Space opens a session; local EOU endpoints one
/// turn; the session stays open until Done, idle, or goodbye.
///
/// End-of-utterance comes from a local Parakeet streaming model when available.
/// Apple SpeechAnalyzer supplies the user-facing text. Dictation stays push-to-talk.
@MainActor
@Observable
final class AgentCaptureController {
    private static var loadedShared: AgentCaptureController?
    static var shared: AgentCaptureController {
        if let loadedShared { return loadedShared }
        let capture = AgentCaptureController()
        loadedShared = capture
        return capture
    }
    static var sharedIfLoaded: AgentCaptureController? { loadedShared }

    enum Limits {
        static let speechLevel: Float = 0.06
        static let silenceLevel: Float = 0.04
        /// After speech, this much quiet commits the turn. The local model's provider VAD is
        /// typically a sub-second endpoint; 900 ms is enough to finish a clause.
        static let endpointSilence: TimeInterval = 0.9
        /// A volatile recognition snapshot can arrive after mic energy falls.
        /// Give its last revision a brief chance to settle before submitting it.
        static let transcriptSettle: TimeInterval = 0.35
        static let minSpeech: TimeInterval = 0.25
        static let minCharacters = 2
        /// No speech after a reply: go back to sleep, like the local model's SleepController.
        static let idleSession: TimeInterval = 25
        static let tick: Duration = .milliseconds(100)
    }

    enum EndpointSource: String, Sendable {
        case localEOU
        case vad
        case goodbye
        case done
        case disowned
        case notAddressed
        case idle
        case none
    }

    /// What asked `tick` to evaluate the endpoint. The VAD loop owns `.loop`;
    /// a confirmed local EOU owns `.eou` (P0-10). Diagnostic and self-test only.
    enum EndpointTrigger: String, Sendable {
        case eou
        case loop
    }

    private(set) var transcript = ""
    private(set) var level: Float = 0
    /// VAD still tracks the mic while the model speaks. Keeping its 10 Hz meter
    /// out of Observation avoids repainting the Agent view during generation.
    @ObservationIgnored private var inputLevel: Float = 0
    private(set) var lastReply = ""
    private(set) var isSessionActive = false
    /// What closed the last turn. `--selftest-realtime` fails unless a reply came from `vad`.
    private(set) var lastEndpoint: EndpointSource = .none

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var voiceActivityInput: CaptureVoiceActivityInput?
    @ObservationIgnored private var voiceActivityDrain: Task<Void, Never>?
    @ObservationIgnored private var voiceActivityConsecutive = 0
    @ObservationIgnored private var voiceActivityGeneration: UInt64?
    @ObservationIgnored private var voiceActivityLastProbe: UInt64?
    @ObservationIgnored private var voiceActivityQuietSince: UInt64?
    @ObservationIgnored private var voiceActivityObserverForTesting:
        (@MainActor (CaptureVoiceActivityInput.Probe) -> Void)?
    private var fileFeedTask: Task<Void, Never>?
    private var fileFeedCompletedAt: Date?
    private var deferredFileFeed: (URL, AVAudioFormat, @Sendable (AudioChunk) -> Void)?
    private var fileCaptureFormat: AVAudioFormat?
    private var fileDeliveryForTesting: (@Sendable (AudioChunk) -> Void)?
    private var fileFeedFailure: String?
    private var fileCommittedTurns = 0
    private var fileInputStartedAt: Date?
    private var fileFirstVoiceAt: Date?
    private var fileSecondInputStartedAt: Date?
    private var fileLastVoiceAt: Date?
    private var fileEndpointAt: Date?
    private var fileFirstNovelASRAt: Date?
    private var fileMaxCleanedLevel: Float = 0
    private var fileASRChunkCount = 0
    private var fileFirstAppleASRAt: Date?
    private var fileLastASRText = ""
    private var fileLastFilteredASRText = ""
    private var fileASRFeedChunks = 0
    private var fileASRFeedPeak: Float = 0
    private var fileASRFeedFrames = 0
    private var fileModelPartialCount = 0
    private var fileLastModelPartialText = ""
    private var fileFirstEOUProcessSeconds: TimeInterval?
    private var fileEOUResets = 0
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?
    private var turnDetector: LocalVoiceTurnDetector?
    @ObservationIgnored private var inputProducerProbeForTesting: VoiceInputProducerProbe?
    // The latest task also retains/joins its retiring predecessor off the input path.
    private var turnDetectorTask: Task<Void, Never>?
    private var eouPreparationPending = false
    private var eouTerminationRequested = false
    private var turnAudioBacklog: TurnAudioBacklog?
    private var turnDetectorReady = false
    /// The local decoder owns the visible/preparation candidate only after it
    /// has reached live cadence and produced a nonempty partial for this turn.
    /// `localDecoderCaughtUp` is session-liveness state; ownership is per turn.
    private var localDecoderCaughtUp = false
    private var localOwnsPartial = false
    private var deferFrontendForEOU = false
    private var modelEOUAt: Date?
    /// One endpoint evaluation at a time. `tick` awaits, so the 100 ms VAD
    /// loop and an immediate EOU evaluation could otherwise interleave and
    /// commit the same turn twice (P0-10).
    @ObservationIgnored private var tickInFlight = false
    /// The trigger of the endpoint evaluation in flight. `startVAD` sets
    /// `.loop` before each of its ticks; the local EOU callback sets `.eou`
    /// before its own immediate evaluation (P0-10).
    @ObservationIgnored private var lastEndpointTrigger: EndpointTrigger = .loop
    /// The trigger of the commit that carried the last confirmed model EOU.
    /// `nil` when no EOU committed a turn. Read by `--selftest-voice-pipeline`.
    @ObservationIgnored private(set) var fileEOUCommitTrigger: EndpointTrigger?
    private var wordlessModelEOU = false
    private var modelPartialText = ""
    private var modelFinalText = ""
    private var appleEchoRecognition = RealtimeAudioSession.EchoRecognitionState()
    private var localEchoRecognition = RealtimeAudioSession.EchoRecognitionState()
    private var frontendStagedForTurn = false
    private var lastPreparedPartial = ""
    private var acousticFloorHeldForTurn = false
    private var eouDroppedChunks = 0
    /// A callback already queued from the preceding utterance cannot end this one.
    private var turnEpoch = 0
    private var vadTask: Task<Void, Never>?
    /// A tool or permission request belongs to a turn, not to the VAD timer.
    /// The timer must keep endpointing speech while this task is suspended.
    private var activeTurnTask: Task<Void, Never>?
    @ObservationIgnored private var islandTurnObserverForTesting:
        (@MainActor (Task<Void, Never>, String, Bool) -> Void)?
    @ObservationIgnored private var islandTurnScopeForTesting: (@MainActor () -> Bool)?
    private var turnGeneration = 0
    /// A suspended fake lets `--selftest-realtime` prove the next endpoint does
    /// not wait for a previous tool. Never installed during normal operation.
    @ObservationIgnored var turnHandlerForTesting: (@MainActor (String) async -> Void)?
    private var heardSpeech = false
    private var voiceShadowTurn: TurnID?
    private(set) var voiceShadowQueuedTurn: TurnID?
    var voiceShadowQueuedObserverForTesting: (@MainActor () -> Void)?
    var voiceShadowCurrentTurn: TurnID? { voiceShadowTurn }
    var heardSpeechForTesting: Bool { heardSpeech }
    var voiceShadowHasFloor: Bool {
        isSessionActive && ((heardSpeech && (acousticFloorHeldForTurn
            || (!lastPreparedPartial.isEmpty && speechBeganAt.map {
                Date().timeIntervalSince($0) >= Limits.minSpeech
            } == true)))
            || VoiceTurnPolicy.isHesitation(lastEmittedRequest))
            && VoiceConversationCoordinator.shared.inputPending
    }
    private func shadowTurnIfNeeded() -> TurnID {
        if let voiceShadowTurn { return voiceShadowTurn }
        let turn = VoiceSession.shared.beginTurnIfNeeded()
        voiceShadowTurn = turn
        return turn
    }
    /// A short backchannel only has its conversational meaning if it began
    /// while assistant audio was playing. Playback can finish before endpoint.
    private var overlappedAssistantSpeech = false
    private var speechBeganAt: Date?
    private var lastSpeechAt: Date?
    private var lastActivityAt: Date?
    /// Last full SpeechAnalyzer snapshot accepted at an endpoint. Using the
    /// full snapshot matters: the analyzer can revise its volatile tail later.
    private var committedPrefix = ""
    private var latestFullTranscript = ""
    private var lastTranscriptChangeAt: Date?
    /// Unfiltered SpeechAnalyzer turn. Keep this for cumulative-prefix tracking;
    /// `transcript` is the person-only form shown and sent to the Agent.
    private var rawTranscript = ""
    private var lastEmittedRequest = ""
    private var captureAudio = true
    private var captureSessionID: UUID?
    var sessionID: UUID? { captureSessionID }
    var echoProbeReceiptsForTesting: (asrFrames: Int, eouProcessed: Bool, eouReady: Bool) {
        (fileASRFeedFrames, fileFirstEOUProcessSeconds != nil, turnDetectorReady)
    }

    /// UUID ownership keeps a late prewarm from pinning a newer conversation.
    private var modelConversationID: UUID?

    func begin() async {
        await beginSession(captureAudio: !SelfTest.isRunning)
    }

    private(set) var wakeConfirmationPending = false
    private var wakeRemainder = ""

    func beginSession(captureAudio: Bool = true, origin: VoiceSessionOrigin = .other,
        wakeConfirmationPending: Bool = false,
        onOpened: (@MainActor (UUID) -> Void)? = nil) async {
        guard !eouTerminationRequested else { return }
        if isSessionActive {
            if origin == .wake { VoiceConversationCoordinator.shared.noteSessionOpened(origin: origin, at: Date()) }
            return
        }
        let captureID = UUID()
        captureSessionID = captureID
        voiceShadowQueuedTurn = nil
        // P2-01: a voice session is the only window in which a main-actor stall delays
        // anything a person is waiting on, so the probe lives exactly here.
        MainActorStallProbe.shared.start()
        VoiceLatencyTimeline.shared.beginSession(captureID)
        turnGeneration &+= 1
        activeTurnTask?.cancel()
        activeTurnTask = nil
        self.captureAudio = captureAudio
        fileFeedFailure = nil
        fileFeedCompletedAt = nil
        fileCaptureFormat = nil
        fileDeliveryForTesting = nil
        fileCommittedTurns = 0
        fileInputStartedAt = nil
        fileFirstVoiceAt = nil
        fileSecondInputStartedAt = nil
        fileLastVoiceAt = nil
        fileEndpointAt = nil
        fileFirstNovelASRAt = nil
        fileMaxCleanedLevel = 0
        fileASRChunkCount = 0
        fileFirstAppleASRAt = nil
        fileLastASRText = ""
        fileLastFilteredASRText = ""
        fileASRFeedChunks = 0
        fileASRFeedPeak = 0
        fileASRFeedFrames = 0
        fileModelPartialCount = 0
        fileLastModelPartialText = ""
        fileFirstEOUProcessSeconds = nil
        fileEOUResets = 0
        fileEOUCommitTrigger = nil
        isSessionActive = true
        VoiceConversationCoordinator.shared.noteSessionOpened(origin: origin, at: Date())
        // A voice conversation does not share the CPU with an embedding backfill.
        Task { await EmbeddingRuntime.shared.stopNow() }
        RealtimeAudioSession.shared.begin(captureID: captureID)
        VoicePlaybackDelivery.shared.outputSessionOpened()
        RealtimeAgent.shared.userSpeechEnded()
        lastEndpoint = .none
        lastReply = ""
        lastEmittedRequest = ""
        committedPrefix = ""
        latestFullTranscript = ""
        localDecoderCaughtUp = false
        localOwnsPartial = false
        deferFrontendForEOU = false
        resetTurn(resetDecoder: false)
        VoiceSession.shared.send(.sessionOpened(sessionID: captureID))
        turnDetectorReady = false
        modelEOUAt = nil
        eouDroppedChunks = 0
        self.wakeConfirmationPending = wakeConfirmationPending
        onOpened?(captureID)

        if captureAudio {
            prepareVoiceFrontend()
            guard await Permissions.requestMicrophone() else {
                guard captureSessionID == captureID else { return }
                IslandState.shared.showAgentReply("Microphone access is off.")
                await endSession(source: .done)
                return
            }
            guard captureSessionID == captureID else { return }
            do {
                try await startEngine(for: captureID)
                // Configure microphone hardware before the experimental output
                // graph; a sink buffer-size change can stop an existing engine.
                try AgentSpeechSynthesizer.shared.preparePersistentPocketPlayback()
            } catch {
                guard captureSessionID == captureID else { return }
                IslandState.shared.showAgentReply(error.localizedDescription)
                await endSession(source: .done)
                return
            }
            guard captureSessionID == captureID else { return }
            startVAD()
            prepareConversationModel()
        }
    }

    func resolveWakeConfirmation(sessionID: UUID, result: WakePhraseConfirmation.Result?,
        spottedAt: Date, audioSeconds: TimeInterval) async {
        guard isSessionActive, captureSessionID == sessionID, wakeConfirmationPending else { return }
        if let result, !result.accepted {
            WakeWordTelemetry.shared.recordFalseAccept(
                keyword: WakeWordAudioMonitor.shared.lastDetection?.keyword ?? "",
                reason: "audio-confirmation")
            await endSession(source: .notAddressed)
            return
        }
        wakeConfirmationPending = false
        // These are actual recognized words from the capture prefix, not simulated
        // speech/levels. Keep live post-hit input and its endpoint ownership intact.
        if let result, !result.remainder.isEmpty {
            wakeRemainder = result.remainder
            heardSpeech = true
            if speechBeganAt == nil { speechBeganAt = spottedAt.addingTimeInterval(-audioSeconds) }
            if lastSpeechAt.map({ $0 < spottedAt }) ?? true { lastSpeechAt = spottedAt }
            lastTranscriptChangeAt = Date()
        }
        // nil explicitly means confirmation unavailable; preserve wake availability.
        // The ordinary VAD/EOU decides when retained speech ends, without a new timer.
    }

    /// What a file-fed session has reached, for `--selftest-voice-latency` (P2-01), which
    /// drives this same pipeline from outside the file. Read-only: the latency self-test
    /// watches the turn, it does not steer it.
    var fileSessionProgress: (
        committedTurns: Int, feedFailure: String?, feed: Task<Void, Never>?,
        heardWords: Bool
    ) {
        (fileCommittedTurns, fileFeedFailure, fileFeedTask, !lastEmittedRequest.isEmpty)
    }

    /// Self-test source: no microphone grant or hub subscription. The decoder
    /// and all subsequent turn handling are the production instances.
    func beginFileSession(wav: URL, deferFeed: Bool = false,
        appleFastResults: Bool = true, prepareResources: Bool = true) async throws {        await beginSession(captureAudio: false)
        // The file feeder owns the voice marks, so `voice.speech_end_to_endpoint` means the
        // same thing here as it does for a live microphone: the source level, not the
        // cleaned one, and stamped where the feeder already keeps its own dates.
        VoiceLatencyTimeline.shared.fileFedOwnsVoiceMarks = true
        guard let captureID = captureSessionID else { throw TranscriptionError.notRunning }
        let eouFirst = SelfTest.isRunning && prepareResources
            && CommandLine.arguments.contains("--voice-eou-first")
        deferFrontendForEOU = eouFirst
        if prepareResources && !eouFirst { prepareVoiceFrontend() }
        try await startEngine(for: captureID, fileURL: wav,
            deferFileFeed: deferFeed, appleFastResults: appleFastResults,
            prepareFrontendAfterEOU: eouFirst)
        try AgentSpeechSynthesizer.shared.preparePersistentPocketPlayback()
        guard captureSessionID == captureID else { throw TranscriptionError.notRunning }
        startVAD()
        if prepareResources { prepareConversationModel() }
    }

    private func prepareVoiceFrontend() {
        Task.detached(priority: .userInitiated) {
            do {
                try await LocalVoiceFrontend.shared.prepare()
            } catch {
                Log.agent.error("local voice frontend prewarm: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Retain the background worker if it becomes loaded during microphone or paced
    /// file input. Synthetic captureAudio:false policy tests never call this.
    private func prepareConversationModel() {
        let conversationID = UUID()
        modelConversationID = conversationID
        Task { @MainActor [weak self] in
            await NotesModelRuntime.shared.beginConversationSession(conversationID)
            if self?.modelConversationID != conversationID {
                await NotesModelRuntime.shared.endConversationSession(conversationID)
            }
        }
    }

    /// Island Done / second shortcut: leave the conversation. Not how a turn ends.
    func endSession(source: EndpointSource = .done) async {
        guard isSessionActive else { return }
        let unconfirmedWake = wakeConfirmationPending
        let activity = voiceActivityInput
        let activityDrain = activity?.suspend() ?? voiceActivityDrain
        voiceActivityDrain = activityDrain
        resetVoiceActivity()
        isSessionActive = false
        voiceShadowQueuedTurn = nil
        captureSessionID = nil
        wakeConfirmationPending = false
        wakeRemainder = ""
        VoiceConversationCoordinator.shared.closeSession()
        // No staged frontend/speculation exists while this wake is pending.
        // Skip its unnecessary hop so old capture handles are owned before await.
        if !unconfirmedWake { await LocalVoiceFrontend.shared.clearStagedTurn() }
        let conversationID = modelConversationID
        modelConversationID = nil
        if let conversationID {
            Task { await NotesModelRuntime.shared.endConversationSession(conversationID) }
        }
        RealtimeAgent.shared.userSpeechEnded()
        turnGeneration &+= 1
        activeTurnTask?.cancel()
        activeTurnTask = nil
        _ = ACPConfirmationGate.shared.cancel()
        if source == .disowned {
            // The person withdrew the words this turn was built from: drop the
            // in-flight input and cancel any response it is generating, whether
            // or not a reply had started. Background work keeps its owners.
            RealtimeAgent.shared.discardVoiceInput()
            RealtimeAgent.shared.cancel()
        } else if RealtimeAgent.shared.isThinking {
            RealtimeAgent.shared.cancel()
        }
        lastEndpoint = source
        VoicePlaybackDelivery.shared.outputSessionClosed()
        RealtimeAudioSession.shared.end()
        let shadowReason: VoiceSessionCloseReason = source == .idle ? .idle : ([.disowned, .notAddressed].contains(source) ? .notAddressed : .done)
        VoiceSession.shared.send(.sessionClosed(shadowReason))
        stopVAD()
        VoiceLatencyTimeline.shared.endSession()
        MainActorStallProbe.shared.stop()
        await stopEngine(closeVoiceActivity: false)
        await activityDrain?.value
        // Done closes the session. The VAD endpoint is the only path that
        // submits speech; a cumulative ASR tail after Done is often playback
        // or a revision of a request already in flight.
        // A new session may have opened while the detached engine drained.
        // Its card and capture state belong to that newer session.
        guard captureSessionID == nil else { return }
        if source == .notAddressed {
            IslandState.shared.showAgentReply("Going quiet.")
            ActivationController.shared.finishAgent()
        } else if source == .disowned {
            IslandState.shared.showAgentReply("Okay, I'll ignore that.")
            ActivationController.shared.finishAgent()
        } else if lastReply.isEmpty {
            IslandState.shared.showAgentReply(source == .idle ? "Going quiet." : "Stopped.")
            ActivationController.shared.finishAgent()
        } else {
            IslandState.shared.showAgentReply(lastReply)
            ActivationController.shared.finishAgent()
        }
        transcript = ""
        heardSpeech = false
        lastEmittedRequest = ""
    }

    /// Old name: callers that meant “user pressed Done” now end the session.
    func finish() async {
        await endSession(source: .done)
    }

    /// "That wasn't for you": the person disowns the speech the session heard.
    /// Telemetry is counted once per session, then the session ends as `.disowned`
    /// and its in-flight turn is dropped.
    func disown() async {
        guard isSessionActive else { return }
        WakeWordTelemetry.shared.recordFalseAccept(
            keyword: WakeWordAudioMonitor.shared.lastDetection?.keyword ?? "unknown",
            reason: "that-wasnt-for-you"
        )
        await endSession(source: .disowned)
    }

    /// Self-test / wake remainder: speech then silence, no Done.
    func simulateSpeech(_ text: String, level: Float = 0.3) {
        RealtimeAudioSession.shared.noteUserSpeech()
        self.level = level
        inputLevel = level
        heardSpeech = true
        if speechBeganAt == nil { speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05) }
        lastSpeechAt = Date()
        lastActivityAt = Date()
        transcript = text
        rawTranscript = text
        latestFullTranscript = committedPrefix.isEmpty ? text : committedPrefix + " " + text
        VoiceSession.shared.listeningFeed(transcript: text, level: level, force: RealtimeAgent.shared.voiceInputActive)
    }

    /// Self-test seam for SpeechAnalyzer's cumulative snapshots. The normal
    /// `simulateSpeech` helper supplies one fresh turn at a time.
    func simulateCumulativeSpeech(_ full: String, level: Float = 0.3) {
        self.level = level
        inputLevel = level
        heardSpeech = true
        if speechBeganAt == nil { speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05) }
        lastSpeechAt = Date()
        lastActivityAt = Date()
        latestFullTranscript = full
        lastTranscriptChangeAt = Date()
        rawTranscript = Self.pending(full: full, committed: committedPrefix)
        if !localOwnsPartial {
            transcript = filterAppleRecognition(rawTranscript)
            considerSpeechInterruption(transcript, source: .apple)
        }
    }

    func simulateSilence() {
        level = 0
        inputLevel = 0
        lastSpeechAt = Date().addingTimeInterval(-Limits.endpointSilence - 0.05)
        lastTranscriptChangeAt = Date().addingTimeInterval(-Limits.transcriptSettle - 0.05)
    }

    func simulateLateTranscriptRevisionForTesting() {
        lastTranscriptChangeAt = Date()
    }

    func simulateSettledTranscriptForTesting() {
        lastTranscriptChangeAt = Date().addingTimeInterval(-Limits.transcriptSettle - 0.05)
    }

    @discardableResult
    func considerEndpoint() async -> Bool {
        await tick(force: true)
    }

    /// One SpeechAnalyzer snapshot, as the main-actor consumer loop handles it. Split out of
    /// the loop so the loop body can be one labelled main-actor section (P2-01) without a
    /// closure capture per chunk.
    private func consumeAppleChunk(_ chunk: TranscriptionChunk, captureID: UUID) {
        let full = chunk.text
        if fileFeedTask != nil {
            fileASRChunkCount += 1
            fileLastASRText = full
            if fileFirstAppleASRAt == nil, !full.isEmpty {
                fileFirstAppleASRAt = Date()
                let fromVoice = fileFirstVoiceAt.map {
                    String(format: "%.3f", Date().timeIntervalSince($0))
                } ?? "none"
                SelfTest.diagnostic("VOICE_APPLE_FIRST_RESULT=voice+\(fromVoice)s text=\(full)")
            }
        }
        if full != latestFullTranscript {
            lastTranscriptChangeAt = Date()
        }
        latestFullTranscript = full
        let turn = Self.pending(full: full, committed: committedPrefix)
        rawTranscript = turn
        let userTurn = filterAppleRecognition(turn, provisional: !chunk.isFinal)
        echoProbeDiagnostic("apple raw=\(turn) filtered=\(userTurn)")
        if fileFeedTask != nil { fileLastFilteredASRText = userTurn }
        // Apple remains the raw/cumulative fallback. Once the
        // local decoder owns this turn, late Apple revisions are
        // diagnostics only and cannot replace its shorter or
        // corrected visible/preparation candidate.
        if !localOwnsPartial {
            transcript = userTurn
            considerSpeechInterruption(userTurn, source: .apple)
        }
        if !userTurn.isEmpty {
            VoiceLatencyTimeline.shared.mark(.asrFirstPartial)
        }
        if RealtimeAgent.shared.voiceInputActive
            || (!RealtimeAgent.shared.isThinking && !RealtimeAudioSession.shared.isSpeaking) {
            VoiceSession.shared.listeningFeed(transcript: transcript, level: level, force: RealtimeAgent.shared.voiceInputActive)
        }
        if chunk.isFinal, userTurn.count >= Limits.minCharacters {
            heardSpeech = true
            lastSpeechAt = Date().addingTimeInterval(-Limits.endpointSilence)
        }
    }

    /// The same capture-owned VAD entry used by live/file input and its lifecycle fixture.
    private func startVoiceActivity(for captureID: UUID) {
        if let activity = voiceActivityInput, activity.snapshot().failure == nil {
            activity.activate(captureID: captureID, retiring: voiceActivityDrain)
        } else {
            if let old = voiceActivityInput { voiceActivityDrain = old.close() }
            voiceActivityInput = makeVoiceActivity(captureID: captureID)
        }
        resetVoiceActivity()
    }

    private func makeVoiceActivity(captureID: UUID?, cachedOnly: Bool = false,
        cachedModel: URL? = nil) -> CaptureVoiceActivityInput {
        CaptureVoiceActivityInput(captureID: captureID, retiring: voiceActivityDrain,
            cachedOnly: cachedOnly, cachedModel: cachedModel) { [weak self] probe in
            guard let self else { return }
            await MainActor.run { self.noteVoiceActivity(probe) }
        }
    }

    @discardableResult
    private func prepareResidentVoiceActivity() -> Bool {
        guard !eouTerminationRequested, !isSessionActive,
              !SelfTest.isRunning || (SelfTest.requested == "--selftest-voice-turns"
                && CommandLine.arguments.contains("--voice-duck-resident")),
              ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork,
              ProcessInfo.processInfo.thermalState == .nominal,
              let cached = CaptureVoiceActivityInput.cachedModelURL(offline: SelfTest.isRunning)
        else { return false }
        if let existing = voiceActivityInput {
            guard existing.snapshot().failure != nil else { return false }
            voiceActivityDrain = existing.close()
            voiceActivityInput = nil
        }
        // The admitted URL is immutable for this load; disappearance cannot download.
        voiceActivityInput = makeVoiceActivity(captureID: nil, cachedOnly: true, cachedModel: cached)
        return true
    }

    private func startEngine(for captureID: UUID, fileURL: URL? = nil,
        deferFileFeed: Bool = false, appleFastResults: Bool = true,
        prepareFrontendAfterEOU: Bool = false) async throws {
        let engine = AppleSpeechEngine(fastResults: appleFastResults)
        guard let format = await engine.preferredInputFormat() else {
            throw TranscriptionError.noAudioFormat
        }
        guard let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw TranscriptionError.noAudioFormat
        }
        Log.agent.info("voice capture format float32/16000 → Apple ASR \(format.commonFormat.rawValue)/\(format.sampleRate, format: .fixed(precision: 0))")
        if fileURL != nil {
            SelfTest.diagnostic("VOICE_INPUT_FORMAT=canonical Float32/16000/mono; Apple \(format.commonFormat.rawValue)/\(format.sampleRate)/\(format.channelCount)")
        }
        guard captureSessionID == captureID else { return }
        let stream = try await engine.start()
        guard captureSessionID == captureID else {
            await engine.finish()
            return
        }
        self.engine = engine
        startVoiceActivity(for: captureID)
        guard let activity = voiceActivityInput else { throw TranscriptionError.notRunning }
        consumeTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in stream {
                    MainActorSection.run("asr.apple") {
                        guard let self, self.captureSessionID == captureID else { return }
                        self.consumeAppleChunk(chunk, captureID: captureID)
                    }
                }
            } catch {
                Log.agent.error("agent capture: \(error.localizedDescription, privacy: .public)")
            }
        }
        // The tap calls back in order, but independent Tasks can enter the
        // SpeechAnalyzer in a different order. One drain owns the feed lane.
        let (audioStream, continuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let turnAudioBacklog = TurnAudioBacklog()
        let turnAudioSequence = TurnAudioSequence()
        let producerProbeForTesting = SelfTest.isRunning ? inputProducerProbeForTesting : nil
        let retiringDecoderTask = turnDetectorTask
        let detector = turnDetector ?? LocalVoiceTurnDetector(producerProbeForTesting: producerProbeForTesting)
        turnDetector = detector
        self.turnAudioBacklog = turnAudioBacklog
        let eouCallback = makeEOUCallback(captureID: captureID, epoch: turnEpoch)
        let partialCallback = makePartialCallback(captureID: captureID, epoch: turnEpoch)
        turnDetectorTask = Task.detached(priority: .userInitiated) {
            var nativeFailure = false
            do {
                // Mic/Apple ASR and their feed already opened. Rebind only after
                // the retiring native session (or pressure release) settles.
                let prepareStarted = Date()
                await retiringDecoderTask?.value
                try Task.checkCancellation()
                try await detector.prepare(onEndOfUtterance: eouCallback,
                    onPartial: partialCallback, sessionID: captureID,
                    producerProbeForTesting: producerProbeForTesting)
                try Task.checkCancellation()
                await MainActor.run {
                    guard AgentCaptureController.shared.captureSessionID == captureID else { return }
                    AgentCaptureController.shared.turnDetectorReady = true
                    if prepareFrontendAfterEOU {
                        AgentCaptureController.shared.deferFrontendForEOU = false
                        AgentCaptureController.shared.prepareVoiceFrontend()
                        AgentCaptureController.shared.prepareResponseForRecognizedSpeech(
                            AgentCaptureController.shared.transcript)
                    }
                    // P2-01: the EOU model is resident. Written for every session, not only
                    // the file-fed ones that print it, and read with `--usage-report
                    // --usage-feature voice`.
                    let prepared = Date().timeIntervalSince(prepareStarted)
                    LatencyTrace.record(.voiceEOUPrepare, seconds: prepared,
                        note: "session", source: "voice")
                    if fileURL != nil {
                        SelfTest.diagnostic("VOICE_EOU_PREPARE=\(prepared)s")
                    }
                }
                var hadDiscontinuity = false
                var lastSequence: Int?
                var measuredFirstProcess = false
                let startupBufferedChunks = turnAudioBacklog.count()
                let startupBufferedFrames = turnAudioBacklog.queuedFrames()
                var catchingUpFromStartup = startupBufferedChunks > 0
                var warnedStartupLag = false
                if fileURL != nil {
                    await MainActor.run {
                        SelfTest.diagnostic("VOICE_EOU_STARTUP_BUFFERED=\(startupBufferedChunks) chunks / \(startupBufferedFrames) frames")
                    }
                }
                if !catchingUpFromStartup {
                    await MainActor.run {
                        let capture = AgentCaptureController.shared
                        guard capture.captureSessionID == captureID else { return }
                        capture.markLocalDecoderCaughtUp(captureID: captureID,
                            reason: "no startup backlog")
                    }
                }
                for await _ in turnAudioBacklog.events {
                  while let (chunk, capturedAt, sequence) = turnAudioBacklog.take() {
                    if Task.isCancelled { break }
                    if let lastSequence, sequence != lastSequence + 1 {
                        hadDiscontinuity = true
                        catchingUpFromStartup = true
                        await MainActor.run {
                            let capture = AgentCaptureController.shared
                            guard capture.captureSessionID == captureID else { return }
                            capture.fileEOUResets += 1
                            capture.turnDetectorReady = false
                            capture.releaseLocalDecoderOwnership(reason: "audio sequence discontinuity")
                        }
                        await detector.resetForDiscontinuity()
                        Log.agent.warning("local EOU skipped \(sequence - lastSequence - 1) audio chunks; resetting decoder")
                    }
                    lastSequence = sequence
                    let lag = Date().timeIntervalSince(capturedAt)
                    if catchingUpFromStartup && lag <= 0.4 {
                        catchingUpFromStartup = false
                        await MainActor.run {
                            let capture = AgentCaptureController.shared
                            guard capture.captureSessionID == captureID else { return }
                            capture.markLocalDecoderCaughtUp(captureID: captureID,
                                reason: "startup lag \(String(format: "%.3f", lag))s")
                        }
                    }
                    if catchingUpFromStartup && lag > 4 && !warnedStartupLag {
                        warnedStartupLag = true
                        Log.agent.warning("local EOU startup catch-up lag \(lag, format: .fixed(precision: 2))s")
                    }
                    if lag > 0.5 && !catchingUpFromStartup {
                        if !hadDiscontinuity {
                            hadDiscontinuity = true
                            catchingUpFromStartup = true
                            await MainActor.run {
                                let capture = AgentCaptureController.shared
                                guard capture.captureSessionID == captureID else { return }
                                capture.fileEOUResets += 1
                                capture.turnDetectorReady = false
                                capture.releaseLocalDecoderOwnership(reason: "audio lag discontinuity")
                            }
                            await detector.resetForDiscontinuity()
                            Log.agent.warning("local EOU audio lag \(lag, format: .fixed(precision: 2))s; resetting decoder")
                        }
                        await MainActor.run {
                            guard AgentCaptureController.shared.captureSessionID == captureID else { return }
                            AgentCaptureController.shared.turnDetectorReady = false
                            AgentCaptureController.shared.releaseLocalDecoderOwnership(reason: "audio lag")
                        }
                        continue
                    }
                    if hadDiscontinuity {
                        await detector.resetForDiscontinuity()
                        hadDiscontinuity = false
                        await MainActor.run {
                            guard AgentCaptureController.shared.captureSessionID == captureID else { return }
                            AgentCaptureController.shared.turnDetectorReady = true
                        }
                    }
                    let started = Date()
                    if let producerProbeForTesting {
                        try await detector.process(chunk,
                            producerInputForTesting: producerProbeForTesting.input(sequence: sequence))
                    } else {
                        try await detector.process(chunk)
                    }
                    if !measuredFirstProcess {
                        measuredFirstProcess = true
                        let duration = Date().timeIntervalSince(started)
                        await MainActor.run {
                            let capture = AgentCaptureController.shared
                            guard capture.captureSessionID == captureID else { return }
                            capture.fileFirstEOUProcessSeconds = duration
                            if fileURL != nil {
                                SelfTest.diagnostic("VOICE_EOU_FIRST_PROCESS=\(duration)s lag=\(lag)s")
                            }
                        }
                    }
                  }
                }
            } catch {
                nativeFailure = !(error is CancellationError)
                if nativeFailure {
                    Log.agent.error("local voice EOU unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
            await MainActor.run {
                guard AgentCaptureController.shared.captureSessionID == captureID else { return }
                AgentCaptureController.shared.turnDetectorReady = false
                AgentCaptureController.shared.releaseLocalDecoderOwnership(reason: "local decoder failure")
                if prepareFrontendAfterEOU {
                    AgentCaptureController.shared.deferFrontendForEOU = false
                    AgentCaptureController.shared.prepareVoiceFrontend()
                }
            }
            let failed = nativeFailure
            let keepPrepared = await MainActor.run {
                let capture = AgentCaptureController.shared
                return !failed && !capture.eouTerminationRequested
                    && capture.turnDetector === detector
                    && (capture.isSessionActive || ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork)
            }
            await detector.close(keepingPrepared: keepPrepared)
        }
        let feedTask = Task.detached(priority: .userInitiated) {
            let converter = captureFormat == format
                ? nil : AVAudioConverter(from: captureFormat, to: format)
            if captureFormat != format && converter == nil {
                Log.agent.error("Apple ASR input converter unavailable")
                return
            }
            for await chunk in audioStream {
                if let converter {
                    guard let converted = AudioConversion.convert(chunk.buffer,
                        to: format, using: converter) else { continue }
                    if SelfTest.isRunning {
                        let peak = Self.pcmPeak(converted)
                        let frames = Int(converted.frameLength)
                        Task { @MainActor in
                            let capture = AgentCaptureController.shared
                            guard capture.captureSessionID == captureID else { return }
                            capture.fileASRFeedChunks += 1
                            capture.fileASRFeedFrames += frames
                            capture.fileASRFeedPeak = max(capture.fileASRFeedPeak, peak)
                        }
                    }
                    await engine.feed(AudioChunk(buffer: converted))
                } else {
                    if SelfTest.isRunning {
                        let peak = Self.pcmPeak(chunk.buffer)
                        let frames = Int(chunk.buffer.frameLength)
                        Task { @MainActor in
                            let capture = AgentCaptureController.shared
                            guard capture.captureSessionID == captureID else { return }
                            capture.fileASRFeedChunks += 1
                            capture.fileASRFeedFrames += frames
                            capture.fileASRFeedPeak = max(capture.fileASRFeedPeak, peak)
                        }
                    }
                    await engine.feed(chunk)
                }
            }
        }
        let deliver: @Sendable (AudioChunk) -> Void = { chunk in
            let cleaned = AcousticEchoProcessor.shared.process(chunk)
            let acoustic = AcousticEchoProcessor.shared.evidenceSnapshot()
            let output = RealtimeAudioSession.voiceActivityOutputGeneration
            // The capture timestamp is the first frame. Freshness follows the final
            // frame of the supplied 16k buffer, never the later native callback time.
            activity.ingest(cleaned.buffer, evidence: acoustic,
                outputGeneration: output?.0 == captureID ? output?.1 : nil,
                at: chunk.captureHostTime.map { VoiceLatencyTimeline.nanos(hostTime: $0)
                    + UInt64(cleaned.buffer.frameLength) * 62_500 }
                    ?? VoiceLatencyTimeline.nowNanos())
            continuation.yield(cleaned)
            let sequence = turnAudioSequence.next()
            if let producerProbeForTesting {
                let format = cleaned.buffer.format
                if format.commonFormat != .pcmFormatFloat32 || format.sampleRate != 16_000
                    || format.channelCount != 1 || format.isInterleaved {
                    producerProbeForTesting.record("capture.format.invalid")
                }
            }
            producerProbeForTesting?.captured(sequence: sequence,
                frames: Int(cleaned.buffer.frameLength))
            let dropped = turnAudioBacklog.enqueue((cleaned, Date(), sequence))
            if dropped > 0 {
                Task { @MainActor in
                    let capture = AgentCaptureController.shared
                    guard capture.captureSessionID == captureID else { return }
                    capture.eouDroppedChunks += dropped
                    if capture.eouDroppedChunks == 1 || capture.eouDroppedChunks.isMultiple(of: 32) {
                        Log.agent.warning("local EOU dropped \(capture.eouDroppedChunks) queued audio chunks")
                    }
                }
            }
            let cleanedLevel = Self.cleanedMicLevel(cleaned.buffer)
            // P2-01: the onset is the turn's own clock start and `lastVoice` is its speech
            // end. The capture buffer's host time is used when it has one, so the boundary
            // is the instant the audio was captured rather than the instant this closure ran.
            if !VoiceLatencyTimeline.shared.fileFedOwnsVoiceMarks,
               cleanedLevel >= Limits.speechLevel {
                let at = chunk.captureHostTime.map(VoiceLatencyTimeline.nanos(hostTime:))
                    ?? VoiceLatencyTimeline.nowNanos()
                VoiceLatencyTimeline.shared.mark(.voiceOnset, at: at)
                VoiceLatencyTimeline.shared.mark(.lastVoice, at: at, overwrite: true)
            }
            Task { @MainActor in
                let capture = AgentCaptureController.shared
                guard capture.captureSessionID == captureID else { return }
                capture.fileMaxCleanedLevel = max(capture.fileMaxCleanedLevel, cleanedLevel)
                capture.noteAcousticLevel(cleanedLevel,
                    nearCandidate: acoustic.aecProcessed && acoustic.recentReference
                        && acoustic.nearCandidate)
            }
        }
        if let fileURL {
            audioContinuation = continuation
            self.feedTask = feedTask
            fileCaptureFormat = captureFormat
            fileDeliveryForTesting = deliver
            deferredFileFeed = (fileURL, captureFormat, deliver)
            if !deferFileFeed {
                startDeferredFileFeed()
            }
            return
        }
        do {
            guard captureSessionID == captureID else {
                continuation.finish()
                feedTask.cancel()
                self.engine = nil
                consumeTask?.cancel()
                consumeTask = nil
                await engine.finish()
                return
            }
            try AudioCaptureHub.shared.subscribe(.agent, outputFormat: captureFormat, onBuffer: deliver)
            audioContinuation = continuation
            self.feedTask = feedTask
        } catch {
            continuation.finish()
            feedTask.cancel()
            self.engine = nil
            await engine.finish()
            throw error
        }
    }

    private func startDeferredFileFeed() {
        guard let (fileURL, format, deliver) = deferredFileFeed else { return }
        deferredFileFeed = nil
        fileFeedTask = Task { @MainActor [weak self] in
            do { try await self?.feedFile(fileURL, outputFormat: format, deliver: deliver) }
            catch is CancellationError { }
            catch { self?.fileFeedFailure = error.localizedDescription }
            self?.fileFeedCompletedAt = Date()
        }
    }

    /// A self-test file enters the identical echo processor, ASR, EOU and VAD
    /// delivery closure as live microphone audio, paced at its recorded rate.
    private func feedFile(
        _ url: URL,
        outputFormat: AVAudioFormat,
        deliver: @escaping @Sendable (AudioChunk) -> Void,
        markSecondInput: Bool = false
    ) async throws {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let formatsMatch = sourceFormat == outputFormat
        let converter = formatsMatch
            ? nil : AVAudioConverter(from: sourceFormat, to: outputFormat)
        if !formatsMatch && converter == nil { throw TranscriptionError.noAudioFormat }
        let feedSeconds = CommandLine.arguments.contains("--voice-feed-10ms") ? 0.01 : 0.08
        if fileInputStartedAt == nil {
            SelfTest.diagnostic("VOICE_FILE_FEED_CADENCE=\(Int(feedSeconds * 1_000))ms")
        }
        let frames = AVAudioFrameCount(max(1, Int(sourceFormat.sampleRate * feedSeconds)))
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else {
            throw TranscriptionError.noAudioFormat
        }
        let pacingClock = ContinuousClock()
        var nextFeed = pacingClock.now
        var maximumPacingLag: Duration = .zero
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: source)
            guard source.frameLength > 0 else { break }
            let delivered = if let converter {
                AudioConversion.convert(source, to: outputFormat, using: converter)
            } else {
                AudioConversion.copy(source)
            }
            guard let delivered else { throw TranscriptionError.noAudioFormat }
            let now = Date()
            if markSecondInput, fileSecondInputStartedAt == nil {
                fileSecondInputStartedAt = now
            }
            if fileInputStartedAt == nil { fileInputStartedAt = now }
            if AudioConversion.level(of: source) >= Limits.speechLevel {
                if fileFirstVoiceAt == nil {
                    fileFirstVoiceAt = now
                    // P2-01: same instants as the dates above, so a file-fed run's
                    // `voice.speech_end_to_endpoint` is the same measurement a live
                    // microphone makes rather than a second number beside it.
                    VoiceLatencyTimeline.shared.mark(.voiceOnset)
                }
                fileLastVoiceAt = now
                VoiceLatencyTimeline.shared.mark(.lastVoice, overwrite: true)
            }
            deliver(AudioChunk(buffer: delivered))
            maximumPacingLag = max(maximumPacingLag, nextFeed.duration(to: pacingClock.now))
            nextFeed += .seconds(Double(source.frameLength) / sourceFormat.sampleRate)
            try await pacingClock.sleep(until: nextFeed)
        }
        guard let silence = AVAudioPCMBuffer(pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(max(1, Int(outputFormat.sampleRate * feedSeconds)))) else {
            throw TranscriptionError.noAudioFormat
        }
        silence.frameLength = silence.frameCapacity
        for _ in 0..<Int(1.52 / feedSeconds) {
            try Task.checkCancellation()
            let channels = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for channel in channels {
                if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
            }
            guard let owned = AudioConversion.copy(silence) else {
                throw TranscriptionError.noAudioFormat
            }
            deliver(AudioChunk(buffer: owned))
            maximumPacingLag = max(maximumPacingLag, nextFeed.duration(to: pacingClock.now))
            nextFeed += .seconds(Double(silence.frameLength) / outputFormat.sampleRate)
            try await pacingClock.sleep(until: nextFeed)
        }
        SelfTest.diagnostic("VOICE_FILE_MAX_PACING_LAG=\(maximumPacingLag)")
    }

    private func stopEngine(closeVoiceActivity: Bool = true) async {
        let activity = closeVoiceActivity ? voiceActivityInput : nil
        let activityDrain = closeVoiceActivity ? (activity?.close() ?? voiceActivityDrain) : nil
        if closeVoiceActivity {
            voiceActivityInput = nil
            voiceActivityDrain = activityDrain
            resetVoiceActivity()
        }
        AudioCaptureHub.shared.unsubscribe(.agent)
        fileFeedTask?.cancel()
        fileFeedTask = nil
        deferredFileFeed = nil
        audioContinuation?.finish()
        audioContinuation = nil
        turnAudioBacklog?.finish()
        turnAudioBacklog = nil
        // Keep the same task/owner until its native drain settles. A new session
        // joins that handle inside its detached preparation, never at key-down.
        turnDetectorTask?.cancel()
        fileCaptureFormat = nil
        fileDeliveryForTesting = nil
        turnDetectorReady = false
        localDecoderCaughtUp = false
        localOwnsPartial = false
        modelEOUAt = nil
        let draining = feedTask
        feedTask = nil
        let finishing = engine
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        let drained: Void? = await withBoundedWait(RealtimeAgent.Limits.captureFinish) {
            if let draining { await draining.value }
        }
        if drained == nil { draining?.cancel() }
        await activityDrain?.value
        if let finishing {
            _ = await withBoundedWait(RealtimeAgent.Limits.captureFinish) {
                await finishing.finish()
            }
        }
    }

    /// Wake/activation intent, never a microphone wait. The existing decoder handle
    /// owns the optional load and is joined by capture reopen, pressure release and quit.
    @discardableResult
    func prepareResidentEOU() -> Bool {
        _ = prepareResidentVoiceActivity()
        guard !eouTerminationRequested, !isSessionActive, !eouPreparationPending,
              !SelfTest.isRunning || (SelfTest.requested == "--selftest-voice-eou"
                && CommandLine.arguments.contains("--voice-eou-reuse")),
              ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork,
              ProcessInfo.processInfo.thermalState == .nominal,
              let directory = LocalVoiceTurnDetector.cachedModelDirectory() else { return false }
        let detector = turnDetector ?? LocalVoiceTurnDetector(
            producerProbeForTesting: inputProducerProbeForTesting)
        turnDetector = detector
        let retiring = turnDetectorTask
        let probe = SelfTest.isRunning ? inputProducerProbeForTesting : nil
        eouPreparationPending = true
        turnDetectorTask = Task.detached(priority: .utility) {
            await retiring?.value
            let quiet = await ComputeScheduler.shared.occupancy().busy.isEmpty
            let admitted = await MainActor.run {
                !Task.isCancelled && !self.eouTerminationRequested && !self.isSessionActive
                    && self.turnDetector === detector
                    && ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork
                    && ProcessInfo.processInfo.thermalState == .nominal
            }
            if quiet && admitted {
                do { try await detector.prepareCachedModels(from: directory, producerProbeForTesting: probe) }
                catch { await detector.close() }
                let release = await MainActor.run {
                    !self.isSessionActive && !ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork
                }
                if release { await detector.close() }
            }
            await MainActor.run { self.eouPreparationPending = false }
        }
        return true
    }

    // EOU_REUSE_COMMON_BEGIN
    func releaseIdleEOUUnderPressure() async {
        guard !isSessionActive else { return }
        let activity = voiceActivityInput
        voiceActivityInput = nil
        let activityDrain = activity?.close() ?? voiceActivityDrain
        voiceActivityDrain = activityDrain
        await activityDrain?.value
        // A session may reopen during that join; do not release its EOU weights.
        guard !isSessionActive, let detector = turnDetector else { return }
        let retiring = turnDetectorTask
        // Chain cleanup through the existing handle so reopen and quit can join it.
        let release = Task.detached(priority: .utility) {
            await retiring?.value
            let stillIdle = await MainActor.run {
                let capture = AgentCaptureController.shared
                return !capture.isSessionActive && capture.turnDetector === detector
            }
            if stillIdle { await detector.close() }
        }
        turnDetectorTask = release
        await release.value
    }

    func beginEOUTermination() -> Task<Void, Never>? {
        guard !eouTerminationRequested else { return nil }
        eouTerminationRequested = true
        // Refuse callbacks/new admission synchronously before any shutdown await.
        captureSessionID = nil
        let activity = voiceActivityInput
        voiceActivityInput = nil
        let activityDrain = activity?.close() ?? voiceActivityDrain
        voiceActivityDrain = activityDrain
        let decoder = turnDetectorTask
        let detector = turnDetector
        turnDetectorTask = nil
        turnDetector = nil
        fileFeedTask?.cancel()
        turnAudioBacklog?.finish()
        decoder?.cancel()
        return Task { @MainActor in
            await self.endSession(source: .done)
            await decoder?.value
            await activityDrain?.value
            await detector?.close()
        }
    }

    /// Native EOU lifecycle only. The authored file and actual capture/decoder are unchanged;
    /// the existing turn handler records commits without starting LLM/TTS work.
    static func runEOUReuseSelfTest(wav: URL) async -> [String] {
        guard SelfTest.requested == "--selftest-voice-eou",
              CommandLine.arguments.contains("--voice-eou-reuse") else {
            return ["EOU reuse requires its exact diagnostic flag"]
        }
        let capture = AgentCaptureController.shared
        await capture.endSession(source: .done)
        let priorHandler = capture.turnHandlerForTesting
        let priorProbe = capture.inputProducerProbeForTesting
        let probe = VoiceInputProducerProbe(holdPrepare: false, holdFirstCommit: false)
        capture.inputProducerProbeForTesting = probe
        var records: [(UUID, String, EndpointSource)] = []
        capture.turnHandlerForTesting = { text in
            if let id = capture.captureSessionID {
                records.append((id, text, capture.lastEndpoint))
            }
        }
        var failures: [String] = []
        @MainActor func count(_ name: String, in probe: VoiceInputProducerProbe) -> Int {
            probe.snapshot().filter { $0.kind == name }.count
        }
        @MainActor func waitFor(_ predicate: @MainActor () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while !predicate(), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return predicate()
        }
        do {
            // Same actual owner, native load/prime and handle before any PCM/capture.
            await capture.releaseIdleEOUUnderPressure()
            if LocalVoiceTurnDetector.cachedModelDirectory() == nil {
                throw AgentError.backendUnavailable("EOU resident fixture needs its installed model files.")
            }
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("EOUResidentMissing-\(UUID().uuidString)")
            if LocalVoiceTurnDetector.cachedModelDirectory(root: missing) != nil {
                failures.append("missing EOU cache admitted optional preparation")
            }
            if !capture.prepareResidentEOU() {
                failures.append("EOU arm did not admit callback-free resident preparation")
            }
            await capture.turnDetectorTask?.value
            let resident = capture.turnDetector
            let prepared = await resident?.modelsPreparedForTesting() ?? false
            if !prepared || count("prepare.loaded", in: probe) != 1 {
                failures.append("EOU arm did not load and prime its actual decoder before first capture")
            }
            if capture.isSessionActive || capture.captureSessionID != nil || !records.isEmpty
                || probe.snapshot().contains(where: { $0.kind == "captured" || $0.kind == "native.eou" }) {
                failures.append("resident preparation opened capture or admitted a user turn")
            }
            var sessionIDs: [UUID] = []
            for index in 0..<2 {
                try await capture.beginFileSession(wav: wav, prepareResources: false)
                guard let id = capture.captureSessionID else { throw TranscriptionError.notRunning }
                sessionIDs.append(id)
                if capture.prepareResidentEOU() {
                    failures.append("optional resident preparation was admitted during active capture")
                }
                if let resident, capture.turnDetector !== resident {
                    failures.append("first capture replaced its prepared EOU owner")
                }
                await capture.fileFeedTask?.value
                if !(await waitFor({ records.count > index })) {
                    failures.append("session \(index): native EOU did not commit its authored file")
                }
                await capture.waitForActiveTurnForTesting()
                if index == 1, let detector = capture.turnDetector {
                    let staleResetRan = await detector.resetForNextTurn(
                        onEndOfUtterance: { _ in }, onPartial: { _ in },
                        sessionID: sessionIDs.first)
                    if staleResetRan {
                        failures.append("retired session reset rebound the next native decoder callbacks")
                    }
                }
                // Capture before normal stop so original cleanup cannot hide an unjoined task.
                let decoder = capture.turnDetectorTask
                await capture.endSession(source: .done)
                await decoder?.value
            }
            if count("prepare.load", in: probe) != 1 || count("prepare.loaded", in: probe) != 1 {
                failures.append("two actual sessions reloaded EOU: load=\(count("prepare.load", in: probe)) completed=\(count("prepare.loaded", in: probe))")
            }
            if count("native.eou", in: probe) < 2 || records.count != 2
                || records.contains(where: { $0.1.isEmpty || $0.2 != .localEOU })
                || Set(records.map { $0.0 }) != Set(sessionIDs) || Set(sessionIDs).count != 2 {
                failures.append("native endpoints did not retain two distinct session identities")
            }
            if let detector = capture.turnDetector {
                if !(await detector.modelsPreparedForTesting()) {
                    failures.append("normal session close did not retain prepared EOU weights")
                }
            } else { failures.append("normal session close discarded the EOU owner") }
            let closedBefore = count("models.closed", in: probe)
            let idlePressure = ModelResidencyGuardian(releaseForTesting: {
                await capture.releaseIdleEOUUnderPressure()
            })
            idlePressure.receive(.warning)
            if !(await waitFor({ count("models.closed", in: probe) > closedBefore })) {
                failures.append("idle pressure did not release actual EOU models")
            }
            if let detector = capture.turnDetector, await detector.modelsPreparedForTesting() {
                failures.append("idle pressure left prepared EOU weights resident")
            }
            // Cold reload after pressure, held inside the SAME real preparation operation.
            let held = VoiceInputProducerProbe(holdPrepare: true, holdFirstCommit: false)
            capture.inputProducerProbeForTesting = held
            var warmPressureJoined = false
            let warmPressure: Task<Void, Never>?
            if capture.prepareResidentEOU() {
                if !(await waitFor({ count("prepare.held", in: held) == 1 })) {
                    failures.append("idle resident preparation never reached its owned native load/prime")
                }
                if capture.prepareResidentEOU() {
                    failures.append("held resident preparation admitted a second warm task")
                }
                warmPressure = Task { @MainActor in
                    await capture.releaseIdleEOUUnderPressure()
                    warmPressureJoined = true
                }
                for _ in 0..<20 { await Task.yield() }
                if warmPressureJoined {
                    failures.append("idle pressure returned before its held native preparation joined")
                }
                if capture.prepareResidentEOU() {
                    failures.append("pressure handle replacement lost pending warm admission")
                }
            } else {
                warmPressure = nil
                failures.append("pressure restart did not admit optional EOU preparation before capture")
            }
            try await capture.beginFileSession(wav: wav, deferFeed: true, prepareResources: false)
            let decoder = capture.turnDetectorTask
            if !(await waitFor({ count("prepare.held", in: held) == 1 })) {
                failures.append("pressure restart never reached the actual held load/prime")
            }
            let busyPressure = ModelResidencyGuardian(releaseForTesting: {
                await capture.releaseIdleEOUUnderPressure()
            })
            busyPressure.receive(.warning)
            for _ in 0..<20 { await Task.yield() }
            if count("models.closed", in: held) != 0 {
                failures.append("pressure released an active held decoder")
            }
            let quit = capture.beginEOUTermination()
            var joined = false
            let observeQuit = Task { @MainActor in
                if let quit { await quit.value }
                joined = true
            }
            for _ in 0..<20 { await Task.yield() }
            if quit == nil || joined { failures.append("quit did not join its held native preparation") }
            held.releaseAll()
            await observeQuit.value
            await warmPressure?.value
            if capture.eouPreparationPending {
                failures.append("joined quit retained stale resident preparation admission")
            }
            if let decoder { decoder.cancel(); await decoder.value }
            if quit == nil { await capture.endSession(source: .done) }
            await capture.beginSession(captureAudio: false)
            if capture.isSessionActive || capture.captureSessionID != nil {
                failures.append("quit reopened native capture admission")
            }
            if count("prepare.load", in: held) != 1 || count("prepare.loaded", in: held) != 1
                || count("models.closed", in: held) == 0 {
                failures.append("pressure reload/quit did not bind the same actual models")
            }
            capture.inputProducerProbeForTesting?.releaseAll()
        } catch {
            failures.append("EOU reuse native flow: \(error.localizedDescription)")
            capture.inputProducerProbeForTesting?.releaseAll()
        }
        let decoder = capture.turnDetectorTask
        await capture.endSession(source: .done)
        decoder?.cancel()
        await decoder?.value
        await capture.releaseIdleEOUUnderPressure()
        capture.turnHandlerForTesting = priorHandler
        capture.inputProducerProbeForTesting = priorProbe
        SelfTest.diagnostic("VOICE_EOU_REUSE_NATIVE sessions=\(records.count) load=\(count("prepare.load", in: probe)) completed=\(count("prepare.loaded", in: probe)) eou=\(count("native.eou", in: probe))")
        return failures
    }
    // EOU_REUSE_COMMON_END

    private func resetVoiceActivity() {
        voiceActivityConsecutive = 0
        voiceActivityGeneration = nil
        voiceActivityLastProbe = nil
        voiceActivityQuietSince = nil
    }
    private func noteVoiceActivity(_ probe: CaptureVoiceActivityInput.Probe,
                                  now: UInt64 = VoiceLatencyTimeline.nowNanos()) {
        defer { if SelfTest.isRunning { voiceActivityObserverForTesting?(probe) } }
        // A model that fell behind cannot interpret an old buffer as current speech.
        let windowNanos: UInt64 = 256_000_000
        let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared
        guard isSessionActive, captureSessionID == probe.captureID,
              speech.outputGeneration == probe.outputGeneration,
              now >= probe.at, now - probe.at <= windowNanos else { return }
        if voiceActivityGeneration != probe.outputGeneration
            || voiceActivityLastProbe.map({ probe.at < $0 || probe.at - $0 > windowNanos }) == true {
            resetVoiceActivity()
            voiceActivityGeneration = probe.outputGeneration
        }
        voiceActivityLastProbe = probe.at
        if probe.probability >= 0.6 && probe.echoOK {
            voiceActivityQuietSince = nil
            voiceActivityConsecutive = min(2, voiceActivityConsecutive + 1)
            if voiceActivityConsecutive == 2 {
                _ = audio.duckForListening(captureID: probe.captureID,
                    outputGeneration: probe.outputGeneration)
            }
        } else {
            voiceActivityConsecutive = 0
            if probe.probability < 0.35 {
                if voiceActivityQuietSince == nil { voiceActivityQuietSince = probe.at }
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let novel = !text.isEmpty && !VoiceTurnPolicy.isHesitation(text)
                    && !VoiceTurnPolicy.isBackchannel(text, whileAssistantSpeaking: true)
                if !novel, let quiet = voiceActivityQuietSince,
                   probe.at >= quiet, probe.at - quiet >= 300_000_000 {
                    audio.releaseDuck(captureID: probe.captureID,
                        outputGeneration: probe.outputGeneration)
                }
            } else { voiceActivityQuietSince = nil }
        }
    }

    private func startVAD() {
        vadTask?.cancel()
        vadTask = Task { @MainActor [weak self] in
            while let self, self.isSessionActive, !Task.isCancelled {
                // A confirmed model EOU owns the trigger until its turn
                // commits; the loop must not relabel that commit `.loop`.
                if self.modelEOUAt == nil {
                    self.lastEndpointTrigger = .loop
                }
                _ = await self.tick(force: false)
                try? await Task.sleep(for: Limits.tick)
            }
        }
    }

    private func stopVAD() {
        vadTask?.cancel()
        vadTask = nil
    }

    /// A residual-energy/coherence candidate is useful for scheduling, but does
    /// not identify a speaker. Never latch it into transcript echo policy: one
    /// false candidate used to admit all subsequent playback words for a turn.
    private func noteAcousticLevel(_ level: Float, nearCandidate: Bool) {
        noteLevel(level, nearCandidate: nearCandidate)
    }

    private func noteLevel(_ level: Float, nearCandidate: Bool = false) {
        let shadowFloorBefore = voiceShadowHasFloor
        defer { if voiceShadowHasFloor != shadowFloorBefore { VoiceSession.shared.producerDidSettle() } }
        inputLevel = level
        guard isSessionActive else { return }
        if level >= Limits.speechLevel {
            // A loud sample is not a user speech-start event, including while
            // the model is thinking. Keep capture live and wait for a novel
            // transcript fragment above before interrupting output or work.
            heardSpeech = true
            if speechBeganAt == nil { speechBeganAt = Date() }
            if let began = speechBeganAt,
               Date().timeIntervalSince(began) >= 0.12,
               (!RealtimeAudioSession.shared.isSpeaking || nearCandidate) {
                if !acousticFloorHeldForTurn {
                    acousticFloorHeldForTurn = true
                    _ = shadowTurnIfNeeded()
                    // Pause new worker effects as soon as sustained near speech
                    // is plausible. Only novel words may stop spoken output.
                    VoiceConversationCoordinator.shared.inputActivityStarted()
                }
                stageFrontendIfNeeded()
            }
            lastSpeechAt = Date()
            lastActivityAt = Date()
        }
        // Mic levels continue arriving while the answer model or a tool runs.
        // They must not replace the work/reply card on every audio buffer.
        if RealtimeAgent.shared.voiceInputActive
            || (!RealtimeAgent.shared.isThinking && !RealtimeAudioSession.shared.isSpeaking) {
            self.level = level
            MainActorSection.run("island.listening") {
                VoiceSession.shared.listeningFeed(transcript: transcript, level: level, force: RealtimeAgent.shared.voiceInputActive)
            }
        }
    }

    /// Kept off the live mic path until the physical false-near gate passes.
    /// A candidate pauses only the current playback token; lexical policy
    /// still decides whether to hard-stop it.
    private func considerListeningCandidate(_ nearCandidate: Bool, now: Date = Date()) {
        guard isSessionActive, let captureID = captureSessionID else { return }
        let audio = RealtimeAudioSession.shared
        if nearCandidate {
            _ = audio.pauseForListening(captureID: captureID, now: now)
        }
        // Once playback is paused its render reference disappears. Continued
        // cleaned mic energy is then the person's speech, not a reason to
        // resume after the 250 ms near-quiet release window.
        let heldSpeech = AgentSpeechSynthesizer.shared.isPausedForListening
            && inputLevel >= Limits.speechLevel
        audio.reviewListeningPause(captureID: captureID,
            nearSpeech: nearCandidate || heldSpeech,
            recognizedSpeech: !transcript.isEmpty, now: now)
    }

    private func resumeListeningAfterDiscard() {
        guard let captureID = captureSessionID else { return }
        _ = RealtimeAudioSession.shared.resumeAfterListening(captureID: captureID)
    }

    private func stageFrontendIfNeeded() {
        guard isSessionActive, !wakeConfirmationPending, turnHandlerForTesting == nil,
              !frontendStagedForTurn, !deferFrontendForEOU else { return }
        frontendStagedForTurn = true
        let request = VoiceConversationCoordinator.shared.stagingRequest()
        let captureID = captureSessionID
        let epoch = turnEpoch
        Task {
            guard isSessionActive, captureSessionID == captureID, turnEpoch == epoch else { return }
            do {
                try await LocalVoiceFrontend.shared.stageNextTurn(
                    system: request.system, messages: request.messages)
            } catch {
                Log.agent.error("local voice turn stage: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static func cleanedMicLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        AudioConversion.level(of: buffer)
    }

    nonisolated private static func pcmPeak(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let stride = buffer.stride
        var peak: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<count { peak = max(peak, abs(samples[index * stride])) }
        } else if let samples = buffer.int16ChannelData?[0] {
            for index in 0..<count {
                peak = max(peak, abs(Float(samples[index * stride]) / 32768))
            }
        }
        return peak
    }

    private func markLocalDecoderCaughtUp(captureID: UUID, reason: String) {
        guard captureSessionID == captureID else { return }
        localDecoderCaughtUp = true
    }

    private func releaseLocalDecoderOwnership(reason: String) {
        localEchoRecognition = .init()
        wordlessModelEOU = false
        let owned = localOwnsPartial
        localDecoderCaughtUp = false
        localOwnsPartial = false
        modelPartialText = ""
        modelFinalText = ""
        modelEOUAt = nil
        if owned {
            transcript = filterAppleRecognition(rawTranscript)
            prepareResponseForRecognizedSpeech(transcript)
            Log.agent.info("voice partial owner: Apple fallback · \(reason, privacy: .public)")
        }
    }

    private func noteModelEOU(_ modelText: String) {
        guard isSessionActive, turnDetectorReady else { return }
        echoProbeDiagnostic("local endpoint=\(modelText) wordlessEligible=\(canSettleWordlessModelEOU)")
        guard !modelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Preserve the event without manufacturing a transcript or a turn.
            // Recheck at tick: a subsequent Apple/local revision may have words.
            wordlessModelEOU = canSettleWordlessModelEOU
            return
        }
        wordlessModelEOU = false
        heardSpeech = true
        if speechBeganAt == nil {
            speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech)
        }
        if lastSpeechAt == nil { lastSpeechAt = Date() }
        modelFinalText = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        modelEOUAt = Date()
        VoiceLatencyTimeline.shared.mark(.eouConfirmed)
        // A confirmed local endpoint owns its own wording, including a shorter
        // correction. Text length is not a measure of decoder progress.
        localOwnsPartial = true
        transcript = filterLocalRecognition(modelFinalText, provisional: false)
        prepareResponseForRecognizedSpeech(transcript)
        if fileFeedTask != nil {
            let fromVoiceEnd = fileLastVoiceAt.map {
                String(format: "%.3f", Date().timeIntervalSince($0))
            } ?? "none"
            let appleAge = lastTranscriptChangeAt.map {
                String(format: "%.3f", Date().timeIntervalSince($0))
            } ?? "none"
            SelfTest.diagnostic("VOICE_MODEL_EOU=sinceVoiceEnd \(fromVoiceEnd)s appleRevisionAge \(appleAge)s text=\(modelFinalText)")
        }
        // P0-10: a confirmed model endpoint evaluates the turn immediately
        // instead of waiting for the next VAD tick. `force: false` keeps every
        // gate, including the silence check that protects against echo.
        lastEndpointTrigger = .eou
        Task { @MainActor [weak self] in
            _ = await self?.tick(force: false)
        }
    }

    private func noteModelPartial(_ modelText: String) {
        guard isSessionActive, turnDetectorReady else { return }
        let candidate = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate != modelPartialText else { return }
        echoProbeDiagnostic("local partial=\(candidate) caughtUp=\(localDecoderCaughtUp)")
        wordlessModelEOU = false
        modelPartialText = candidate
        VoiceLatencyTimeline.shared.mark(.asrFirstPartial)
        if fileFeedTask != nil {
            fileModelPartialCount += 1
            fileLastModelPartialText = candidate
        }
        if localDecoderCaughtUp, !candidate.isEmpty, !localOwnsPartial {
            localOwnsPartial = true
            Log.agent.info("voice partial owner: local decoder caught up")
        }
        if fileFeedTask != nil {
            let fromVoice = fileFirstVoiceAt.map { String(format: "%.3f", Date().timeIntervalSince($0)) } ?? "none"
            SelfTest.diagnostic("VOICE_MODEL_PARTIAL=voice+\(fromVoice)s text=\(candidate) apple=\(!rawTranscript.isEmpty)")
        }
        // A backlog partial cannot prove a new interruption. Apple owns live
        // input until the local audio watermark catches up, regardless of how
        // many words either recognizer has emitted.
        guard localOwnsPartial else { return }
        let userTurn = filterLocalRecognition(candidate)
        if fileFeedTask != nil {
            SelfTest.diagnostic("VOICE_MODEL_PARTIAL_FILTERED=\(userTurn)")
        }
        guard !userTurn.isEmpty else {
            if localOwnsPartial {
                transcript = ""
                prepareResponseForRecognizedSpeech("")
            }
            return
        }
        if localOwnsPartial { transcript = userTurn }
        heardSpeech = true
        if speechBeganAt == nil {
            speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech)
        }
        if lastSpeechAt == nil { lastSpeechAt = Date() }
        lastActivityAt = Date()
        considerSpeechInterruption(userTurn, source: .local)
    }

    private func makeEOUCallback(captureID: UUID, epoch: Int) -> @Sendable (String) -> Void {
        let producerProbeForTesting = inputProducerProbeForTesting
        return { modelText in
            producerProbeForTesting?.record("callback.eou", epoch: epoch)
            // P2-01: stamped on FluidAudio's own thread, before the hop to the main actor,
            // because that hop is `voice.eou_hop` — the part nobody could see before.
            VoiceLatencyTimeline.shared.mark(.eouRaw)
            VoiceLatencyTimeline.shared.mark(.eouCallback)
            Task { @MainActor in
                defer { producerProbeForTesting?.record("callback.eou.handled", epoch: epoch) }
                let capture = AgentCaptureController.shared
                guard capture.captureSessionID == captureID,
                      capture.turnEpoch == epoch else { return }
                MainActorSection.run("asr.local") { capture.noteModelEOU(modelText) }
            }
        }
    }

    private func makePartialCallback(captureID: UUID, epoch: Int) -> @Sendable (String) -> Void {
        { modelText in
            Task { @MainActor in
                let capture = AgentCaptureController.shared
                guard capture.captureSessionID == captureID,
                      capture.turnEpoch == epoch else { return }
                MainActorSection.run("asr.local") { capture.noteModelPartial(modelText) }
            }
        }
    }

    private enum PartialSource { case apple, local, selected }

    private func considerSpeechInterruption(_ userTurn: String, source: PartialSource = .selected) {
        let shadowFloorBefore = voiceShadowHasFloor
        defer { if voiceShadowHasFloor != shadowFloorBefore { VoiceSession.shared.producerDidSettle() } }
        // A standalone hesitation is conversational timing, not a barge-in.
        // Keep it available for endpoint delivery, but do not let its two
        // letters stop playback or mark the turn as overlapping speech.
        let isHesitation = VoiceTurnPolicy.isHesitation(userTurn)
        // A revised partial that collapses into a filler must also cancel an
        // older speculative request, without starting a new generation.
        let ownsPreparation = source == .selected
            || (source == .apple && !localOwnsPartial)
            || (source == .local && localOwnsPartial)
        if ownsPreparation {
            prepareResponseForRecognizedSpeech(isHesitation ? "" : userTurn)
        }
        if RealtimeAudioSession.shared.isSpeaking && !userTurn.isEmpty && !isHesitation {
            overlappedAssistantSpeech = true
        }
        // Energy alone is not a user speech-start event: TTS crosses the VAD
        // threshold. A short backchannel holds no new objective; an extended
        // correction must still yield the speaker on its next ASR revision.
        if (RealtimeAudioSession.shared.isSpeaking || RealtimeAgent.shared.isThinking
            || VoiceConversationCoordinator.shared.hasActiveWork),
           userTurn.count >= Limits.minCharacters,
           !Self.isInFlightRepeat(userTurn, previous: lastEmittedRequest),
           !Self.isCommittedTranscriptRevision(userTurn, committed: committedPrefix),
           !isHesitation,
           !VoiceTurnPolicy.isBackchannel(userTurn,
               whileAssistantSpeaking: overlappedAssistantSpeech),
           let began = speechBeganAt,
           Date().timeIntervalSince(began) >= Limits.minSpeech {
            stageFrontendIfNeeded()
            if fileFeedTask != nil && fileFirstNovelASRAt == nil {
                fileFirstNovelASRAt = Date()
            }
            // This is still a provisional recognizer hypothesis. Hold the
            // current output token and its queued clauses in place so an echo
            // or revised empty tail can resume it. The input barrier is held
            // once per turn; repeatedly revising the same partial must not
            // churn its epoch or release a generated effect.
            if !acousticFloorHeldForTurn {
                echoProbeDiagnostic("provisional hold text=\(userTurn) source=\(source)")
                acousticFloorHeldForTurn = true
                _ = shadowTurnIfNeeded()
                VoiceConversationCoordinator.shared.inputActivityStarted()
            }
            if let captureID = captureSessionID {
                _ = RealtimeAudioSession.shared.pauseForListening(
                    captureID: captureID)
            }
        }
    }

    /// Useful lexical input may start cancelable speculative inference before
    /// the acoustic floor. Stable floor publication keeps its duration gate;
    /// an empty revision cancels preparation. Do not clear the final
    /// partial in resetTurn: handle() compares the exact committed request.
    private func prepareResponseForRecognizedSpeech(_ userTurn: String) {
        guard isSessionActive, !wakeConfirmationPending, captureSessionID != nil,
              turnHandlerForTesting == nil, !deferFrontendForEOU else { return }
        let trimmed = userTurn.trimmingCharacters(in: .whitespacesAndNewlines)
        let beganLongEnough = speechBeganAt.map {
            Date().timeIntervalSince($0) >= Limits.minSpeech
        } ?? false
        let candidate = trimmed.count >= Limits.minCharacters
            && !Self.isInFlightRepeat(trimmed, previous: lastEmittedRequest)
            && !Self.isCommittedTranscriptRevision(trimmed, committed: committedPrefix)
            && !VoiceTurnPolicy.isHesitation(trimmed)
            && !VoiceTurnPolicy.isBackchannel(trimmed,
                whileAssistantSpeaking: overlappedAssistantSpeech)
            ? trimmed : ""
        let changed = candidate != lastPreparedPartial
        if changed { lastPreparedPartial = candidate }
        if !candidate.isEmpty, beganLongEnough {
            let shadow = VoiceSession.shared
            let turn = shadowTurnIfNeeded()
            if changed || shadow.state.floor != .userProvisional(turn) {
                shadow.noteFloorProducer()
                shadow.send(.partial(turn, text: candidate, stable: true))
            }
        }
        guard changed else { return }
        VoiceConversationCoordinator.shared.prepareResponseIfUseful(candidate)
    }

    @discardableResult
    private func tick(force: Bool) async -> Bool {
        guard !wakeConfirmationPending else { return false }
        defer {
            if isSessionActive {
                VoiceSession.shared.send(.timer(.quietWindow))
                VoiceSession.shared.send(.timer(.idleCheck))
            }
        }
        guard !tickInFlight else { return false }
        tickInFlight = true
        defer { tickInFlight = false }
        guard isSessionActive else { return false }
        let now = Date()

        // A first ASR fragment can arrive before minSpeech. Reconsider its
        // retained words when the VAD timer reaches that duration, even if the
        // recognizer emits no second fragment. The agent guards a turn from
        // stopping playback more than once.
        if !RealtimeAgent.shared.voiceInputActive, !transcript.isEmpty {
            considerSpeechInterruption(transcript)
        }

        let wordlessEndpoint = wordlessModelEOU && canSettleWordlessModelEOU
        if heardSpeech,
           let lastSpeechAt,
           let began = speechBeganAt,
           (wordlessEndpoint || modelEOUAt != nil || now.timeIntervalSince(lastSpeechAt) >=
                (turnDetectorReady ? 2.5 : Limits.endpointSilence)),
           now.timeIntervalSince(began) >= Limits.minSpeech,
           (wordlessEndpoint || modelEOUAt != nil ||
                (lastTranscriptChangeAt.map { now.timeIntervalSince($0) >= Limits.transcriptSettle } ?? true)),
           (inputLevel <= Limits.silenceLevel || force) {
            let text = wordlessEndpoint ? "" : pendingTurn(provisional: false)
            if text.isEmpty {
                echoProbeDiagnostic("discard wordlessEndpoint=\(wordlessEndpoint)")
                Log.agent.info("realtime · discarded speech activity without usable words")
                commitRawTurn()
                VoiceSession.shared.send(.inputDiscarded(shadowTurnIfNeeded(), .noWords))
                resumeListeningAfterDiscard()
                RealtimeAgent.shared.discardVoiceInput()
                await LocalVoiceFrontend.shared.clearStagedTurn()
                // P2-01: a discarded utterance has no endpoint and no request, so none of
                // its intervals are a measurement. Forget them rather than writing spans
                // between two moments that were never part of a turn.
                VoiceLatencyTimeline.shared.discardTurn("no-usable-words")
                resetTurn()
                return true
            }
            if text.count >= Limits.minCharacters {
                if VoiceTurnPolicy.isBackchannel(text,
                    whileAssistantSpeaking: overlappedAssistantSpeech) {
                    Log.agent.info("realtime · absorbed conversational acknowledgment")
                    commitRawTurn()
                    VoiceSession.shared.send(.inputDiscarded(shadowTurnIfNeeded(), .backchannel))
                    resumeListeningAfterDiscard()
                    RealtimeAgent.shared.discardVoiceInput()
                    await LocalVoiceFrontend.shared.clearStagedTurn()
                    VoiceLatencyTimeline.shared.discardTurn("backchannel")
                    resetTurn()
                    return true
                }
                if text != rawTranscript {
                    Log.agent.info("realtime · removed playback from mixed turn")
                }
                if RealtimeAgent.shared.isThinking,
                   Self.isInFlightRepeat(text, previous: lastEmittedRequest) {
                    // A repeated question or its unfinished prefix is not a new
                    // command. Keep listening briefly for a different ending;
                    // otherwise absorb the duplicate without cancelling the read.
                    if now.timeIntervalSince(lastSpeechAt) < 2.5,
                       Self.isPartialRepeat(text, previous: lastEmittedRequest) {
                        return false
                    }
                    Log.agent.info("realtime · ignored repeated in-flight request")
                    commitRawTurn()
                    VoiceSession.shared.send(.inputDiscarded(shadowTurnIfNeeded(), .inFlightRepeat))
                    resumeListeningAfterDiscard()
                    RealtimeAgent.shared.discardVoiceInput()
                    await LocalVoiceFrontend.shared.clearStagedTurn()
                    VoiceLatencyTimeline.shared.discardTurn("in-flight-repeat")
                    resetTurn()
                    return true
                }
                if RealtimeAudioSession.shared.isLikelyPlaybackEcho(text) {
                    Log.agent.info("realtime · discarded playback echo")
                    commitRawTurn()
                    VoiceSession.shared.send(.inputDiscarded(shadowTurnIfNeeded(), .playbackEcho))
                    resumeListeningAfterDiscard()
                    RealtimeAgent.shared.discardVoiceInput()
                    await LocalVoiceFrontend.shared.clearStagedTurn()
                    VoiceLatencyTimeline.shared.discardTurn("playback-echo")
                    resetTurn()
                    return true
                }
                if Self.isCommittedTranscriptRevision(text, committed: committedPrefix) {
                    Log.agent.info("realtime · discarded revised transcript")
                    commitRawTurn()
                    VoiceSession.shared.send(.inputDiscarded(shadowTurnIfNeeded(), .revisedTranscript))
                    resumeListeningAfterDiscard()
                    RealtimeAgent.shared.discardVoiceInput()
                    await LocalVoiceFrontend.shared.clearStagedTurn()
                    VoiceLatencyTimeline.shared.discardTurn("committed-revision")
                    resetTurn()
                    return true
                }
                if Self.isGoodbye(text) {
                    isSessionActive = false
                    VoiceConversationCoordinator.shared.closeSession()
                    VoiceSession.shared.send(.sessionClosed(.goodbye))
                    await LocalVoiceFrontend.shared.clearStagedTurn()
                    VoicePlaybackDelivery.shared.outputSessionClosed()
                    RealtimeAudioSession.shared.end()
                    await emitTurn(text, source: .goodbye, continueSession: false)
                    stopVAD()
                    await stopEngine()
                } else {
                    await emitTurn(text, source: modelEOUAt == nil ? .vad : .localEOU,
                        continueSession: true)
                }
                return true
            }
        }

        if VoiceConversationCoordinator.shared.notAddressedCloseDue(now: now) {
            await endSession(source: .notAddressed)
            return true
        }
        if VoicePlaybackDelivery.shared.flushOutput(userHasFloor: heardSpeech || !pendingTurn().isEmpty) {
            lastActivityAt = now
            return false
        }
        if !heardSpeech,
           !RealtimeAgent.shared.isThinking,
           !VoiceConversationCoordinator.shared.hasActiveWork,
           !RealtimeAudioSession.shared.isSpeaking,
           pendingTurn().isEmpty,
           let lastActivityAt,
           now.timeIntervalSince(lastActivityAt) >= Limits.idleSession {
            await endSession(source: .idle)
            return true
        }
        return false
    }

    private func emitTurn(
        _ text: String,
        source: EndpointSource,
        continueSession: Bool
    ) async {
        guard !wakeConfirmationPending else { return }
        if let inputProducerProbeForTesting {
            // Harness-only: text/endpoint eligibility was selected by the real
            // tick; permit the next file's input to arrive before this commit.
            let selectedCaptureID = captureSessionID
            await inputProducerProbeForTesting.holdFirstCommit(epoch: turnEpoch)
            guard isSessionActive, captureSessionID == selectedCaptureID,
                !Task.isCancelled else {
                inputProducerProbeForTesting.record("commit.aborted")
                return
            }
        }
        inputProducerProbeForTesting?.record("commit.emitted", epoch: turnEpoch)
        let shadowTurn = shadowTurnIfNeeded()
        // P2-01: the turn's endpoint. The source is part of the measurement, because a VAD
        // fallback and a confirmed model EOU are two different latencies wearing one name.
        VoiceLatencyTimeline.shared.mark(.endpoint)
        VoiceLatencyTimeline.shared.note("endpoint_source", source.rawValue)
        lastEndpoint = source
        if fileFeedTask != nil {
            fileCommittedTurns += 1
            fileEndpointAt = Date()
            if let modelEOUAt {
                fileEOUCommitTrigger = lastEndpointTrigger
                SelfTest.diagnostic("VOICE_ENDPOINT_TRIGGER=\(lastEndpointTrigger.rawValue)")
                SelfTest.diagnostic("VOICE_MODEL_EOU_TO_ENDPOINT=\(Date().timeIntervalSince(modelEOUAt))s")
            }
        }
        // A committed non-filler turn is now user-owned. Hard-stop the held
        // output before ending the input phase; a provisional partial never
        // reaches this path and therefore cannot destroy a reply that later
        // turns out to be playback echo.
        if !(continueSession && VoiceTurnPolicy.isHesitation(text)) {
            VoiceSession.shared.interrupt(.committed(shadowTurn))
            VoiceSession.shared.send(.committed(shadowTurn, text: text))
            RealtimeAgent.shared.userSpeechStarted()
        }
        // The acoustic floor ended. Keep the coordinator's inputPending effect
        // barrier until the committed text reaches the frontend below.
        RealtimeAgent.shared.userSpeechEnded()
        lastEmittedRequest = text
        wakeRemainder = ""
        let modelSuppliedText = shouldUseModelText() || localOwnsPartial
        let committedModelText = shouldUseModelText() ? modelFinalText : modelPartialText
        commitRawTurn()
        if modelSuppliedText {
            // Apple can publish its cumulative late result after this EOU.
            // Use the model's committed words as a prefix so it cannot become
            // a duplicate command when SpeechAnalyzer catches up.
            let base = latestFullTranscript.isEmpty
                ? committedPrefix : latestFullTranscript
            committedPrefix = Self.mergedCommittedPrefix(base: base,
                appleTurn: rawTranscript, localTurn: committedModelText)
        }
        resetTurn()
        // Commit input independently of work. An active work item receives this
        // as a revision; playback interruption alone never cancels its producer.
        Log.agent.info("realtime · endpoint \(source.rawValue, privacy: .public)")
        // A standalone filler is committed so the coordinator can hold the
        // user's thought open, but it must not cancel a response or stop TTS.
        // Keep the testing sink on this path so the self-test proves delivery
        // without writing user history or invoking a model.
        if continueSession, VoiceTurnPolicy.isHesitation(text) {
            VoiceSession.shared.send(.inputActivity(shadowTurn))
            VoiceSession.shared.send(.hesitation(shadowTurn, text: text))
            if let testHandler = turnHandlerForTesting {
                await testHandler(text)
            } else {
                VoiceConversationCoordinator.shared.noteHesitation(text)
            }
            lastActivityAt = Date()
            return
        }
        if RealtimeAgent.shared.isThinking {
            RealtimeAgent.shared.interrupt()
        }
        activeTurnTask?.cancel()
        _ = ACPConfirmationGate.shared.cancel()
        turnGeneration &+= 1
        let generation = turnGeneration
        if continueSession {
            // `startVAD` awaits `tick`. Awaiting a tool here would prevent the
            // next utterance from reaching another endpoint until that tool
            // returned (up to twenty seconds). Own the reply separately.
            voiceShadowQueuedTurn = shadowTurn
            if SelfTest.isRunning { voiceShadowQueuedObserverForTesting?() }
            activeTurnTask = Task { @MainActor [weak self] in
                self?.voiceShadowQueuedTurn = nil
                if let testHandler = self?.turnHandlerForTesting {
                    await testHandler(text)
                } else {
                    _ = await RealtimeAgent.shared.handle(text, source: .voice, turn: shadowTurn)
                }
                guard let self, self.turnGeneration == generation, self.isSessionActive else {
                    return
                }
                self.activeTurnTask = nil
                VoiceSession.shared.producerDidSettle()
                self.lastActivityAt = Date()
                VoiceSession.shared.listeningFeed(transcript: "", level: 0)
            }
            if SelfTest.isRunning, SelfTest.requested == "--selftest-island",
               let activeTurnTask, let observer = islandTurnObserverForTesting {
                // Capture the existing Task synchronously before its first actor hop.
                // An expired installed scope still exposes its handle for joined cleanup.
                observer(activeTurnTask, text, islandTurnScopeForTesting?() == true)
            }
            return
        }
        _ = await RealtimeAgent.shared.handle(text, source: .voice, turn: shadowTurn)
        lastActivityAt = Date()
    }

    /// Observe the SAME entered capture Task before internal slot clearing.
    /// No product Task, query, await, or ownership transfer is added.
    @discardableResult
    func observeIslandTurnForTesting(root: URL, bridge: TaskBridge,
        _ observer: (@MainActor (Task<Void, Never>, String, Bool) -> Void)?) -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-island",
              bridge.permitsHarness,
              VoiceConversationCoordinator.shared.taskBridgeOverrideForTesting === bridge,
              VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: root, bridge: bridge),
              IslandState.sharedContextMatchesForTesting(root: root, bridge: bridge),
              !isSessionActive, activeTurnTask == nil else { return false }
        islandTurnObserverForTesting = observer
        if observer == nil { islandTurnScopeForTesting = nil }
        else { islandTurnScopeForTesting = { [weak self, weak bridge] in
            guard let self, let bridge, bridge.permitsHarness, self.isSessionActive,
                  VoiceSession.shared.state.sessionID == self.captureSessionID else { return false }
            return VoiceConversationCoordinator.shared.taskBridgeOverrideForTesting === bridge
                && VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: root, bridge: bridge)
                && IslandState.sharedContextMatchesForTesting(root: root, bridge: bridge)
        } }
        return true
    }

    /// Wait for a lightweight test turn before asserting its reply.
    func waitForActiveTurnForTesting() async {
        await activeTurnTask?.value
    }

    func noteAssistantReply(_ text: String) {
        lastReply = text
    }

    /// Support for the controlled producer regression. This emits no pass marker.
    /// The flag's conductor must apply the recipe in the retained report and
    /// require actual native callbacks, frame coverage and expected commit counts.
    func beginInputProducerFixtureForTesting(wav: URL,
        holdPrepare: Bool, holdFirstCommit: Bool,
        committed: @escaping @MainActor (String) async -> Void) async throws
        -> VoiceInputProducerProbe {
        guard SelfTest.isRunning else { throw TranscriptionError.notRunning }
        await endSession(source: .done)
        let probe = VoiceInputProducerProbe(holdPrepare: holdPrepare,
            holdFirstCommit: holdFirstCommit)
        inputProducerProbeForTesting = probe
        turnHandlerForTesting = committed
        do {
            try await beginFileSession(wav: wav, deferFeed: true,
                prepareResources: false)
            return probe
        } catch {
            probe.releaseAll()
            inputProducerProbeForTesting = nil
            turnHandlerForTesting = nil
            await endSession(source: .done)
            throw error
        }
    }

    func startInputProducerFixtureFeedForTesting() {
        guard SelfTest.isRunning, inputProducerProbeForTesting != nil else { return }
        startDeferredFileFeed()
    }

    func feedInputProducerFixtureSecondForTesting(wav: URL) async throws {
        guard SelfTest.isRunning, let probe = inputProducerProbeForTesting,
            let format = fileCaptureFormat, let deliver = fileDeliveryForTesting else {
            throw TranscriptionError.notRunning
        }
        fileFeedTask?.cancel()
        await fileFeedTask?.value
        probe.beginSecondInput()
        try await feedFile(wav, outputFormat: format,
            deliver: deliver, markSecondInput: true)
    }

    func endInputProducerFixtureForTesting(secondFeed: Task<Void, Error>? = nil) async -> [String] {
        guard SelfTest.isRunning else { return ["input fixture cleanup requires self-test mode"] }
        // Existing stopEngine drops these handles after cancellation. Retain
        // them before releasing held operations so the next fixture cannot
        // mistake returned session cleanup for completed native cleanup.
        let tasks: [(String, Task<Void, Never>?)] = [
            ("first feed", fileFeedTask), ("native decoder", turnDetectorTask),
            ("VAD", vadTask), ("turn handler", activeTurnTask),
            ("Apple feed", feedTask), ("Apple results", consumeTask)
        ]
        // Release continuations before endSession waits for the real decoder.
        inputProducerProbeForTesting?.releaseAll()
        secondFeed?.cancel()
        await endSession(source: .done)
        var failures: [String] = []
        for (name, task) in tasks {
            guard let task else { continue }
            task.cancel()
            let joined: Void? = await withBoundedWait(RealtimeAgent.Limits.captureFinish) {
                await task.value
            }
            if joined == nil { failures.append("cleanup did not join \(name)") }
        }
        if let secondFeed {
            let joined: Bool? = await withBoundedWait(RealtimeAgent.Limits.captureFinish) {
                _ = await secondFeed.result
                return true
            }
            if joined == nil { failures.append("cleanup did not join second feed") }
        }
        inputProducerProbeForTesting = nil
        turnHandlerForTesting = nil
        return failures
    }

    /// Two paced requests share one decoder and one microphone-session epoch.
    /// The second starts as soon as the first endpoint is observed. This
    /// exercises the asynchronous decoder reset at a real turn boundary while
    /// routing committed text only to an in-memory recorder.
    static func runVoiceRapidTurnsSelfTest(first: URL, second: URL) async -> [String] {
        let capture = AgentCaptureController.shared
        await capture.endSession(source: .done)
        var turns: [(text: String, source: EndpointSource, at: Date)] = []
        let priorHandler = capture.turnHandlerForTesting
        capture.turnHandlerForTesting = { text in
            turns.append((text, capture.lastEndpoint, Date()))
        }
        var failures = await LocalVoiceTurnDetector.operationGateSelfTestFailures()
        do {
            try await capture.beginFileSession(wav: first, prepareResources: false)
            let firstDeadline = Date().addingTimeInterval(8)
            while turns.isEmpty && Date() < firstDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            // The first feed is still supplying its silence tail when EOU
            // commits. Remove that tail and start the next request at once.
            if capture.fileFeedCompletedAt != nil {
                failures.append("first file feed ended before EOU; rapid tail cancellation was not exercised")
            }
            capture.fileFeedTask?.cancel()
            await capture.fileFeedTask?.value
            if let error = capture.fileFeedFailure { failures.append("first file feed: \(error)") }
            guard let format = capture.fileCaptureFormat,
                let deliver = capture.fileDeliveryForTesting else {
                throw TranscriptionError.notRunning
            }
            if turns.count != 1 {
                failures.append("first request did not commit exactly once before the next onset: \(turns.count)")
            }
            try await capture.feedFile(second, outputFormat: format,
                deliver: deliver, markSecondInput: true)
            let secondDeadline = Date().addingTimeInterval(4)
            while turns.count < 2 && Date() < secondDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            failures.append("rapid turn capture failed: \(error.localizedDescription)")
        }
        SelfTest.diagnostic("VOICE_RAPID_TURNS=\(turns.map { "\($0.source.rawValue):\($0.text)" }) "
            + "eouResets=\(capture.fileEOUResets) drops=\(capture.eouDroppedChunks)")
        if let firstCommit = turns.first?.at,
           let secondSample = capture.fileSecondInputStartedAt {
            let gap = secondSample.timeIntervalSince(firstCommit)
            SelfTest.diagnostic("VOICE_RAPID_COMMIT_TO_SECOND_SAMPLE=\(gap)s")
            if gap < 0 || gap >= 0.1 {
                failures.append("second request began too late to test decoder reset: \(gap)s")
            }
        } else {
            failures.append("rapid probe did not measure commit-to-second-sample gap")
        }
        if turns.count != 2 { failures.append("expected two turns, got \(turns.count)") }
        if turns.first?.text.lowercased().contains("haiku") != true {
            failures.append("first request lost its haiku text")
        }
        if turns.dropFirst().first?.text.lowercased().contains("stop speaking") != true {
            failures.append("rapid second request lost its stop-speaking text")
        }
        if turns.contains(where: { $0.source != .localEOU }) {
            failures.append("a rapid turn did not close from the local EOU model")
        }
        capture.turnHandlerForTesting = priorHandler
        await capture.endSession(source: .done)
        return failures
    }

    /// File-paced, model-backed integration probe. The file enters the same
    /// capture delivery closure as the mic; the real frontend and TTS remain
    /// active. No output is mixed back into this file, so this is not a live
    /// acoustic double-talk or physical audibility test.
    static func runVoicePipelineSelfTest(wav: URL,
        appleFastResults: Bool = true) async -> [String] {
        guard let speechProof = await VoiceDiagnosticSpeech.preparePocket() else {
            return ["Pocket is unavailable; no alternate voice was used"]
        }
        defer { _ = speechProof.finish() }
        let capture = AgentCaptureController.shared
        await capture.endSession(source: .done)
        do {
            try await capture.beginFileSession(wav: wav,
                appleFastResults: appleFastResults)
        } catch {
            await capture.endSession(source: .done)
            return ["could not open file-fed voice session: \(error.localizedDescription)"]
        }
        let speech = AgentSpeechSynthesizer.shared
        let priorPlaybackEvent = speech.onPlaybackEvent
        var firstAudioAcknowledged = false
        var firstAudioAt: Date?
        speech.onPlaybackEvent = { event in
            priorPlaybackEvent?(event)
            if case .startAcknowledged = event {
                firstAudioAcknowledged = true
                if firstAudioAt == nil { firstAudioAt = Date() }
            }
        }
        var failures: [String] = []
        await capture.fileFeedTask?.value
        if let failure = capture.fileFeedFailure { failures.append("file feed: \(failure)") }
        let deadline = Date().addingTimeInterval(55)
        while Date() < deadline,
              (capture.fileCommittedTurns == 0 || capture.lastReply.isEmpty
                || !firstAudioAcknowledged) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if capture.fileCommittedTurns != 1 {
            failures.append("expected one committed spoken turn, got \(capture.fileCommittedTurns)")
        }
        if capture.lastEndpoint != .localEOU {
            failures.append("file speech did not end from local EOU model: \(capture.lastEndpoint.rawValue)")
        }
        // P0-10: a confirmed model EOU must evaluate the endpoint itself. A
        // commit from the 100 ms VAD loop means the person waited up to a tick
        // after Parakeet had already ended their turn.
        if let trigger = capture.fileEOUCommitTrigger, trigger != .eou {
            failures.append("model EOU waited for the VAD tick")
        }
        if capture.lastReply.isEmpty { failures.append("local frontend produced no answer") }
        if !firstAudioAcknowledged { failures.append("TTS supplied no first-audio acknowledgement") }
        let recognized = capture.lastEmittedRequest
        SelfTest.diagnostic("VOICE_PIPELINE_TRANSCRIPT=\(recognized)")
        SelfTest.diagnostic("VOICE_PIPELINE_REPLY=\(capture.lastReply)")
        SelfTest.diagnostic("VOICE_PIPELINE_ASR_FEED=chunks \(capture.fileASRFeedChunks), frames \(capture.fileASRFeedFrames), peak \(capture.fileASRFeedPeak), results \(capture.fileASRChunkCount)")
        SelfTest.diagnostic("VOICE_PIPELINE_APPLE_MODE=fast \(appleFastResults), firstResult \(capture.fileFirstAppleASRAt.map { String($0.timeIntervalSince(capture.fileFirstVoiceAt ?? $0)) } ?? "none")")
        SelfTest.diagnostic("VOICE_PIPELINE_MODEL_PARTIALS=\(capture.fileModelPartialCount), last \(capture.fileLastModelPartialText)")
        SelfTest.diagnostic("VOICE_PIPELINE_EOU_QUEUE=firstProcess \(capture.fileFirstEOUProcessSeconds.map(String.init(describing:)) ?? "none"), resets \(capture.fileEOUResets), drops \(capture.eouDroppedChunks)")
        if CommandLine.arguments.contains("--voice-feed-10ms"),
           capture.fileEOUResets != 0 || capture.eouDroppedChunks != 0 {
            failures.append("10ms cold capture lost EOU input: resets \(capture.fileEOUResets), drops \(capture.eouDroppedChunks)")
        }
        if !recognized.lowercased().contains("haiku") {
            failures.append("real ASR did not recognize the fixture's haiku request")
        }
        if !recognized.lowercased().contains("tell me") {
            failures.append("streaming ASR lost the beginning of the fixture request")
        }
        let reply = capture.lastReply.lowercased()
        if !reply.contains("poem") || !(reply.contains("three") || reply.contains("3")) {
            failures.append("voice answer did not explain the fixture's three-line poem; nonempty fallback is not success")
        }
        if let lastVoice = capture.fileLastVoiceAt, let endpoint = capture.fileEndpointAt {
            SelfTest.diagnostic("VOICE_PIPELINE_VOICE_TO_ENDPOINT=\(endpoint.timeIntervalSince(lastVoice))")
        }
        if let endpoint = capture.fileEndpointAt, let firstAudioAt {
            SelfTest.diagnostic("VOICE_PIPELINE_ENDPOINT_TO_FIRST_AUDIO=\(firstAudioAt.timeIntervalSince(endpoint))")
        }
        if let inputStart = capture.fileInputStartedAt, let firstAudioAt {
            SelfTest.diagnostic("VOICE_PIPELINE_INPUT_TO_FIRST_AUDIO=\(firstAudioAt.timeIntervalSince(inputStart))")
        }
        await capture.endSession(source: .done)
        speech.onPlaybackEvent = priorPlaybackEvent
        failures += speechProof.finish()
        return failures
    }

    /// Real TTS plays while the file-fed production recognizers listen. This
    /// proves a novel ASR fragment can interrupt an active output queue; the
    /// separately measured live microphone probe is needed for room acoustics.
    static func runVoiceBargeSelfTest(wav: URL,
        appleFastResults: Bool = true) async -> [String] {
        let capture = AgentCaptureController.shared
        let speech = AgentSpeechSynthesizer.shared
        if let far = SelfTest.value(after: "--voice-duck-replay") {
            return await voiceDuckReplay(far: URL(fileURLWithPath: far), near: wav)
        }
        let pocketProbe = AgentSpeechSynthesizer.pocketProbeRequested(
            requested: SelfTest.requested, arguments: CommandLine.arguments)
        if CommandLine.arguments.contains("--voice-test-pocket") && !pocketProbe {
            return ["Pocket modifier requires the barge diagnostic alone"]
        }
        let oldEngine = speech.engineOverrideForTesting
        defer { speech.engineOverrideForTesting = oldEngine }
        if pocketProbe {
            speech.engineOverrideForTesting = "pocket"
            await PocketAgentVoice.shared.prepare()
            guard PocketAgentVoice.shared.isReady else { return ["Pocket is unavailable"] }
        }
        await capture.endSession(source: .done)
        do { try await capture.beginFileSession(wav: wav, deferFeed: true,
            appleFastResults: appleFastResults) }
        catch { return ["could not open barge-in session: \(error.localizedDescription)"] }
        if CommandLine.arguments.contains("--voice-feed-10ms") {
            await capture.voiceActivityInput?.waitUntilLoaded()
            let state = capture.voiceActivityInput?.snapshot()
            SelfTest.diagnostic("VOICE_DUCK_MODEL=\(state?.artifact ?? "unavailable") source=FluidInference/silero-vad-coreml")
            if state?.ready != true {
                SelfTest.diagnostic("VOICE_BARGE_ABSENT: VAD artifact unavailable: \(state?.failure ?? "not prepared")")
                await capture.endSession(source: .done)
                return ["VAD artifact unavailable; live duck measurement cannot run"]
            }
        }
        let audio = RealtimeAudioSession.shared
        let priorPlaybackEvent = speech.onPlaybackEvent
        let priorTurnHandler = capture.turnHandlerForTesting
        let priorActivityObserver = capture.voiceActivityObserverForTesting
        defer { capture.voiceActivityObserverForTesting = priorActivityObserver }
        if pocketProbe && CommandLine.arguments.contains("--voice-feed-10ms") {
            capture.voiceActivityObserverForTesting = { probe in
                let sinceVoice = capture.fileFirstVoiceAt.map { Date().timeIntervalSince($0) }
                let age = (Double(VoiceLatencyTimeline.nowNanos()) - Double(probe.at)) / 1e9
                SelfTest.diagnostic("VOICE_DUCK_PROBE probability=\(probe.probability) echoOK=\(probe.echoOK) age_s=\(age) sinceVoice_s=\(sinceVoice.map(String.init(describing:)) ?? "none") gain=\(speech.outputGain)")
            }
        }
        // A successful interruption is the subject of this probe. Do not let
        // the fixture's imperative sentence launch a tool task afterward.
        capture.turnHandlerForTesting = { _ in }
        var firstOutputAt: Date?
        var interruptedAt: Date?
        var acknowledgedClauses = 0
        speech.onPlaybackEvent = { event in
            priorPlaybackEvent?(event)
            switch event {
            case .startAcknowledged:
                acknowledgedClauses += 1
                if firstOutputAt == nil { firstOutputAt = Date() }
            case .interrupted:
                if interruptedAt == nil { interruptedAt = Date() }
            default: break
            }
        }
        let longReply = "Let me explain this carefully. A haiku is a short poem with a vivid image. "
            + "It often notices a small change in nature or daily life. "
            + "The sound and the pause matter as much as the words. "
            + "I can give you several examples and explain each one in turn."
        audio.speak(OutputScheduler.tokenForTesting(), longReply)
        let outputDeadline = Date().addingTimeInterval(20)
        while firstOutputAt == nil && Date() < outputDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var failures: [String] = []
        SelfTest.diagnostic("VOICE_BARGE_ROUTE requested=\(pocketProbe ? "pocket" : "selected") pocketProbeBacking=\(speech.isPocketProbePlayback) scope=file-fed-asr")
        if pocketProbe && !speech.isPocketProbePlayback {
            failures.append("explicit Pocket barge diagnostic used another backing")
        } else if firstOutputAt == nil || !audio.isSpeaking {
            failures.append("real TTS was not playing before voice input began")
        } else {
            capture.startDeferredFileFeed()
            await capture.fileFeedTask?.value
            if let failure = capture.fileFeedFailure { failures.append("file feed: \(failure)") }
            let stopDeadline = Date().addingTimeInterval(8)
            while interruptedAt == nil && Date() < stopDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let pausedAt = audio.lastListeningPauseAt
            if interruptedAt == nil || audio.lastBargeInStopSeconds == nil {
                failures.append("novel ASR did not interrupt real TTS")
            }
            if capture.fileFirstNovelASRAt == nil {
                failures.append("no novel ASR fragment reached barge-in policy")
            }
            if let pausedAt {
                if let stopped = interruptedAt, pausedAt > stopped {
                    failures.append("reversible pause was observed after the hard stop")
                }
            } else {
                failures.append("novel ASR hard-stopped TTS without a reversible pause")
            }
            SelfTest.diagnostic("VOICE_BARGE_DIAGNOSTIC=inputStarted:\(capture.fileInputStartedAt != nil) "
                + "appleFast:\(appleFastResults) "
                + "firstVoice:\(capture.fileFirstVoiceAt != nil) "
                + "maxCleanedLevel:\(capture.fileMaxCleanedLevel) "
                + "asrFeedChunks:\(capture.fileASRFeedChunks) "
                + "asrFeedFrames:\(capture.fileASRFeedFrames) "
                + "asrFeedPeak:\(capture.fileASRFeedPeak) "
                + "asrChunks:\(capture.fileASRChunkCount) "
                + "modelPartials:\(capture.fileModelPartialCount) "
                + "eouFirstProcess:\(capture.fileFirstEOUProcessSeconds.map(String.init(describing:)) ?? "none") "
                + "eouResets:\(capture.fileEOUResets) eouDrops:\(capture.eouDroppedChunks) "
                + "lastModelPartial:\(capture.fileLastModelPartialText) "
                + "raw:\(capture.fileLastASRText) "
                + "filtered:\(capture.fileLastFilteredASRText) "
                + "emitted:\(capture.lastEmittedRequest)")
            if let voice = capture.fileFirstVoiceAt, let stopped = interruptedAt {
                SelfTest.diagnostic("VOICE_BARGE_VOICE_TO_STOP=\(stopped.timeIntervalSince(voice))")
            }
            if let novel = capture.fileFirstNovelASRAt, let stopped = interruptedAt {
                SelfTest.diagnostic("VOICE_BARGE_ASR_TO_STOP=\(stopped.timeIntervalSince(novel))")
            }
            if let voice = capture.fileFirstVoiceAt, let pausedAt {
                SelfTest.diagnostic("VOICE_BARGE_VOICE_TO_PAUSE=\(pausedAt.timeIntervalSince(voice))")
            }
            if let novel = capture.fileFirstNovelASRAt, let pausedAt {
                SelfTest.diagnostic("VOICE_BARGE_ASR_TO_PAUSE=\(pausedAt.timeIntervalSince(novel))")
            }
            if CommandLine.arguments.contains("--voice-feed-10ms") {
                let nativeProbes = capture.voiceActivityInput?.snapshot().nativeProbes ?? 0
                SelfTest.diagnostic("VOICE_DUCK_NATIVE_PROBES=\(nativeProbes)")
                if nativeProbes == 0 { failures.append("no native Silero callback consumed cleaned capture") }
                if let duckAt = audio.lastListeningDuckAt,
                   let voice = capture.fileFirstVoiceAt {
                    let seconds = duckAt.timeIntervalSince(voice)
                    SelfTest.diagnostic("VOICE_BARGE_VOICE_TO_DUCK=\(seconds)")
                    if seconds < 0 || seconds > 0.200 {
                        failures.append("voice to duck \(seconds)s exceeds 0.200s")
                    }
                    if pausedAt == nil || duckAt >= pausedAt! {
                        failures.append("no duck before reversible pause")
                    }
                } else { failures.append("no duck before reversible pause") }
            }
            if pocketProbe && !speech.isPocketProbePlayback { failures.append("Pocket failed over during barge diagnostic") }
            let countAtStop = acknowledgedClauses
            try? await Task.sleep(for: .seconds(1))
            if acknowledgedClauses != countAtStop {
                failures.append("an old queued TTS clause restarted after barge-in")
            }
        }
        await capture.endSession(source: .done)
        speech.onPlaybackEvent = priorPlaybackEvent
        capture.turnHandlerForTesting = priorTurnHandler
        return failures
    }

    private func resetTurn(resetDecoder: Bool = true) {
        inputProducerProbeForTesting?.record("capture.reset", epoch: turnEpoch)
        voiceShadowTurn = nil
        appleEchoRecognition = .init()
        localEchoRecognition = .init()
        wordlessModelEOU = false
        turnEpoch &+= 1
        if resetDecoder, let turnDetector {
            if let captureID = captureSessionID {
                let callback = makeEOUCallback(captureID: captureID, epoch: turnEpoch)
                let partial = makePartialCallback(captureID: captureID, epoch: turnEpoch)
                Task { await turnDetector.resetForNextTurn(
                    onEndOfUtterance: callback, onPartial: partial, sessionID: captureID) }
            }
        }
        transcript = ""
        rawTranscript = ""
        wakeRemainder = ""
        latestFullTranscript = ""
        lastTranscriptChangeAt = nil
        heardSpeech = false
        overlappedAssistantSpeech = false
        speechBeganAt = nil
        lastSpeechAt = nil
        lastActivityAt = Date()
        level = 0
        inputLevel = 0
        modelEOUAt = nil
        modelPartialText = ""
        modelFinalText = ""
        localOwnsPartial = false
        frontendStagedForTurn = false
        lastPreparedPartial = ""
        acousticFloorHeldForTurn = false
    }

    private func pendingTurn(provisional: Bool = true) -> String {
        let live: String
        if shouldUseModelText() {
            live = filterLocalRecognition(modelFinalText, provisional: false)
        } else if localOwnsPartial {
            live = filterLocalRecognition(modelPartialText, provisional: provisional)
        } else {
            live = filterAppleRecognition(rawTranscript, provisional: provisional)
        }
        let prior = Self.normalized(wakeRemainder)
        let current = Self.normalized(live)
        let repeatsPrefix = !prior.isEmpty && (current == prior
            || current.hasPrefix(prior + " ") || prior.hasPrefix(current + " "))
        let tail = repeatsPrefix ? Self.pending(full: live, committed: wakeRemainder) : live
        return [wakeRemainder, tail].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // Each recognizer owns its cumulative revisions. Echo labels may follow
    // unchanged leading words in that stream, but never cross recognizers or
    // turn/decoder resets. Final endpoints do not inherit temporary word-prefix
    // suppression used while a decoder is still completing its last word.
    private func filterAppleRecognition(_ text: String, provisional: Bool = true) -> String {
        RealtimeAudioSession.shared.userSpeechExcludingPlayback(text,
            recognition: &appleEchoRecognition, provisional: provisional).text
    }

    private func filterLocalRecognition(_ text: String, provisional: Bool = true) -> String {
        RealtimeAudioSession.shared.userSpeechExcludingPlayback(text,
            recognition: &localEchoRecognition, provisional: provisional).text
    }

    /// A wordless local endpoint may release only an existing provisional
    /// hold. During decoder startup Apple owns the turn; neither its usable
    /// text nor a local final may be erased by an empty local callback.
    private var canSettleWordlessModelEOU: Bool {
        guard turnDetectorReady, localDecoderCaughtUp, acousticFloorHeldForTurn,
              !RealtimeAgent.shared.voiceInputActive, modelFinalText.isEmpty else { return false }
        return filterAppleRecognition(rawTranscript, provisional: false).isEmpty
            && filterLocalRecognition(modelPartialText, provisional: false).isEmpty
    }

    /// Explicit acoustic probe diagnostics only; never persist live user
    /// transcripts through this channel during ordinary conversation.
    private func echoProbeDiagnostic(_ detail: @autoclosure () -> String) {
        guard SelfTest.isRunning,
              CommandLine.arguments.contains("--selftest-voice-echo-live") else { return }
        SelfTest.diagnostic("VOICE_ECHO_EVENT=\(Date().timeIntervalSince1970) epoch=\(turnEpoch) \(detail())")
    }

    /// The decoder that confirms the endpoint owns its wording. Apple remains
    /// the fallback when no local endpoint exists, regardless of text length.
    private func shouldUseModelText() -> Bool {
        modelEOUAt != nil && !modelFinalText.isEmpty
    }

    private func commitRawTurn() {
        guard !latestFullTranscript.isEmpty else { return }
        committedPrefix = latestFullTranscript
    }

    /// This cursor belongs to Apple's cumulative stream. Extend its current
    /// fragment only when the local words actually extend that same fragment;
    /// concatenating two alternative transcriptions invents a duplicate turn.
    private static func mergedCommittedPrefix(base: String, appleTurn: String, localTurn: String) -> String {
        let apple = normalized(appleTurn)
        let local = normalized(localTurn)
        let prefix = normalized(base)
        guard !local.isEmpty else { return base }
        if prefix == local || prefix.hasSuffix(" " + local) { return base }
        if apple.isEmpty { return [base, localTurn].filter { !$0.isEmpty }.joined(separator: " ") }
        if local.hasPrefix(apple + " "), prefix == apple || prefix.hasSuffix(" " + apple) {
            let preceding = prefix.dropLast(apple.count).trimmingCharacters(in: .whitespaces)
            return [preceding, local].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return base
    }

    private static func pending(full: String, committed: String) -> String {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return trimmed }
        if trimmed.hasPrefix(committed) {
            return String(trimmed.dropFirst(committed.count))
                .replacingOccurrences(of: #"^[\s\p{P}]+"#, with: "", options: .regularExpression)
        }
        let normalizedFull = normalized(trimmed)
        let normalizedCommitted = normalized(committed)
        if normalizedFull == normalizedCommitted { return "" }
        if normalizedCommitted.hasPrefix(normalizedFull + " ") { return "" }
        if normalizedFull.hasPrefix(normalizedCommitted + " ") {
            // Use normalized words only to locate the boundary. Preserve the
            // original casing and punctuation of the newly spoken request.
            let wordCount = normalizedCommitted.split(separator: " ").count
            let original = trimmed as NSString
            let range = NSRange(location: 0, length: original.length)
            let words = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
                .matches(in: trimmed, range: range)
            if let words, words.count >= wordCount, wordCount > 0 {
                let last = words[wordCount - 1].range
                return original.substring(from: last.location + last.length)
                    .replacingOccurrences(of: #"^[\s\p{P}]+"#, with: "", options: .regularExpression)
            }
        }
        if let revisedTail = pendingAfterRevisedPrefix(full: trimmed, committed: committed) {
            return revisedTail
        }
        return trimmed
    }

    /// A volatile SpeechAnalyzer phrase can change words already emitted at a
    /// VAD endpoint. Match the tail of the prior full snapshot as a *sequence*
    /// so an insertion such as "up the two" → "up the to two" does not replay
    /// the entire conversation. This is bounded to the tail for live ASR cost.
    private static func pendingAfterRevisedPrefix(full: String, committed: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
        func words(_ text: String) -> [(value: String, range: NSRange)] {
            let source = text as NSString
            return pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
                .map { (source.substring(with: $0.range).lowercased(), $0.range) }
        }
        let earlier = Array(words(committed).suffix(24))
        let current = Array(words(full).suffix(48))
        let m = earlier.count
        let n = current.count
        guard m >= 4, n >= m - 3 else { return nil }

        let width = n + 1
        var score = Array(repeating: 0, count: (m + 1) * width)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                let index = i * width + j
                score[index] = earlier[i].value == current[j].value
                    ? 1 + score[(i + 1) * width + j + 1]
                    : max(score[(i + 1) * width + j], score[i * width + j + 1])
            }
        }
        guard score[0] >= max(3, m - 3) else { return nil }
        var i = 0
        var j = 0
        var lastOld = -1
        var lastNew = -1
        while i < m, j < n {
            if earlier[i].value == current[j].value,
               score[i * width + j] == 1 + score[(i + 1) * width + j + 1] {
                lastOld = i
                lastNew = j
                i += 1
                j += 1
            } else if score[(i + 1) * width + j] > score[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        guard lastOld >= m - 4, lastNew >= 0 else { return nil }
        let end = current[lastNew].range.location + current[lastNew].range.length
        return (full as NSString).substring(from: end)
            .replacingOccurrences(of: #"^[\s\p{P}]+"#, with: "", options: .regularExpression)
    }

    /// Apple SpeechAnalyzer publishes cumulative volatile text. A punctuation
    /// or casing revision of the just-committed turn must not become a second
    /// tool request after `pending` can no longer strip an exact prefix.
    private static func isCommittedTranscriptRevision(_ text: String, committed: String) -> Bool {
        let heard = normalized(text)
        let earlier = normalized(committed)
        guard heard.count >= Limits.minCharacters, !earlier.isEmpty else { return false }
        return earlier == heard || earlier.hasSuffix(" " + heard)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func repeatWords(_ text: String) -> String {
        normalized(text.lowercased()
            .replacingOccurrences(of: "what's", with: "what is")
            .replacingOccurrences(of: "what’s", with: "what is"))
    }

    private static func isPartialRepeat(_ text: String, previous: String) -> Bool {
        let current = repeatWords(text)
        let earlier = repeatWords(previous)
        guard !earlier.isEmpty, current.split(separator: " ").count <= 3 else { return false }
        return earlier.hasPrefix(current + " ")
    }

    private static func isInFlightRepeat(_ text: String, previous: String) -> Bool {
        let current = repeatWords(text)
        return !current.isEmpty &&
            (current == repeatWords(previous) || isPartialRepeat(text, previous: previous))
    }

    static func transcriptBoundarySelfTestFailures() -> [String] {
        var failures: [String] = []
        for (base, apple, local, expected) in [
            ("Open Safari now", "Open Safari now", "Open Safari", "Open Safari now"),
            ("Hello. Open", "Open", "Open Safari", "hello open safari"),
            ("Hello.", "", "Open Safari", "Hello. Open Safari"),
            ("Hello. Tell me a poem", "Tell me a poem", "Explain a haiku", "Hello. Tell me a poem")
        ] {
            if mergedCommittedPrefix(base: base, appleTurn: apple, localTurn: local) != expected {
                failures.append("local endpoint manufactured a duplicate Apple cursor: \(base) / \(local)")
            }
        }
        if pending(full: "Check email.", committed: "check email") != "" {
            failures.append("a revised cumulative transcript became a new turn")
        }
        if pending(full: "Check email. What about the calendar?", committed: "Check email")
            != "What about the calendar?" {
            failures.append("a new turn was lost after a punctuation revision")
        }
        if pending(full: "Check email. Open Safari now.", committed: "check email")
            != "Open Safari now." {
            failures.append("a revised prefix changed the new request's casing")
        }
        let prior = "Can you hear me? Yes, I can hear you clearly. How would...? "
            + "Why did you stop talking? I up the two"
        let revised = "Can you hear me? Yes, I can hear you clearly. How would...? "
            + "Why did you stop talking? I... I... up the to two long."
        if pending(full: revised, committed: prior) != "long." {
            failures.append("a revised ASR tail replayed the whole 09:07 conversation")
        }
        if pending(full: "Check email", committed: "Check email. Open Safari now.") != "" {
            failures.append("a revoked cumulative tail became a new request")
        }
        if pending(full: revised + " Open my calendar.", committed: prior)
            != "long. Open my calendar." {
            failures.append("a new request after a revised ASR tail was lost")
        }
        if !isCommittedTranscriptRevision("check email", committed: "Check email.") {
            failures.append("the old request could be re-emitted")
        }
        if isCommittedTranscriptRevision("what about the calendar", committed: "Check email") {
            failures.append("a novel request was mistaken for an old revision")
        }
        if !isInFlightRepeat("What is", previous: "What's the content of my calendar for today?") {
            failures.append("a partial repeat interrupted its original calendar read")
        }
        if isInFlightRepeat("Open Safari", previous: "What's on my calendar?") {
            failures.append("a different request was suppressed as a repeat")
        }
        return failures
    }

    static func turnPolicySelfTestFailures() -> [String] {
        var failures = VoiceTurnPolicy.selfTestFailures()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
            let samples = buffer.floatChannelData?[0] else {
            failures.append("could not construct quiet-speech PCM")
            return failures
        }
        buffer.frameLength = 160
        for i in 0..<160 { samples[i] = 0.01 }
        if cleanedMicLevel(buffer) < Limits.speechLevel {
            failures.append("quiet speech did not reach mic speech threshold")
        }
        for i in 0..<160 { samples[i] = 0 }
        if cleanedMicLevel(buffer) > Limits.silenceLevel {
            failures.append("silent PCM held the mic floor")
        }
        return failures
    }

    /// Authored far-only and double-talk, actual Silero and actual AEC -> gain.
    /// Captured timestamps use sample time; this is not a physical room or wall-clock gate.
    private static func voiceDuckReplay(far: URL, near: URL) async -> [String] {
        func samples(_ url: URL) throws -> [Float] {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
            guard file.processingFormat.sampleRate == 16_000,
                  file.processingFormat.channelCount == 1,
                  file.length > 0, file.length < 16_000 * 120,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                      frameCapacity: AVAudioFrameCount(file.length)) else { throw CocoaError(.coderInvalidValue) }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.coderInvalidValue) }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        let farSamples: [Float], nearSamples: [Float]
        do { farSamples = try samples(far); nearSamples = try samples(near) }
        catch {
            SelfTest.diagnostic("VOICE_BARGE_ABSENT: authored16k VAD replay fixtures unavailable: \(error.localizedDescription)")
            return ["authored VAD replay fixtures unavailable; measurement cannot run"]
        }
        guard let onset = nearSamples.firstIndex(where: { abs($0) >= 0.06 }),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000, channels: 1, interleaved: false),
              let render = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
              let mic = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
              let rendered = render.floatChannelData?[0], let captured = mic.floatChannelData?[0] else {
            return ["authored VAD replay has no measurable speech/PCM"]
        }
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared
        await capture.endSession(source: .done)
        let backing = RecordingSpeechBacking()
        speech.useTestingBacking(backing)
        let priorObserver = capture.voiceActivityObserverForTesting
        defer { capture.voiceActivityObserverForTesting = priorObserver; speech.restoreSystemBacking() }
        await capture.beginSession(captureAudio: false)
        guard let id = capture.captureSessionID else { return ["VAD replay capture unavailable"] }
        let input = CaptureVoiceActivityInput(captureID: id, retiring: capture.voiceActivityDrain) { probe in
            await MainActor.run { capture.noteVoiceActivity(probe, now: probe.at) }
        }
        capture.voiceActivityInput = input
        await input.waitUntilLoaded()
        let state = input.snapshot()
        SelfTest.diagnostic("VOICE_DUCK_MODEL=\(state.artifact ?? "unavailable") source=FluidInference/silero-vad-coreml scope=authored-sample-replay")
        guard state.ready else {
            SelfTest.diagnostic("VOICE_BARGE_ABSENT: VAD replay model unavailable: \(state.failure ?? "not prepared")")
            await capture.endSession(source: .done)
            return ["VAD replay artifact unavailable; measurement cannot run"]
        }
        var failures: [String] = []
        for doubleTalk in [false, true] {
            await input.waitForProbe()
            input.resetSamplesForTesting()
            capture.resetVoiceActivity()
            audio.speak(OutputScheduler.tokenForTesting(), "This same reply keeps playing during the replay.")
            speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
            AcousticEchoProcessor.shared.reset()
            let generation = speech.outputGeneration
            let before = input.snapshot().nativeProbes
            let anchor = VoiceLatencyTimeline.nowNanos()
            var duckAt: UInt64?
            var lastGain: Float = 1
            capture.voiceActivityObserverForTesting = { probe in
                if backing.outputGain < lastGain && duckAt == nil { duckAt = probe.at }
                lastGain = backing.outputGain
            }
            let frames = max(farSamples.count + 480, 16_000 + nearSamples.count + 8_000)
            for start in stride(from: 0, to: frames, by: 160) {
                render.frameLength = 160; mic.frameLength = 160
                for i in 0..<160 {
                    let at = start + i
                    rendered[i] = at < farSamples.count ? farSamples[at] : 0
                    let echoIndex = at - 480
                    let echo: Float = echoIndex >= 0 && echoIndex < farSamples.count ? farSamples[echoIndex] * 0.35 : 0
                    let nearIndex = at - 16_000
                    let own: Float = doubleTalk && nearIndex >= 0 && nearIndex < nearSamples.count ? nearSamples[nearIndex] : 0
                    captured[i] = echo + own
                }
                AcousticEchoProcessor.shared.feedRendered(render)
                let cleaned = AcousticEchoProcessor.shared.process(AudioChunk(buffer: mic))
                input.ingest(cleaned.buffer, evidence: AcousticEchoProcessor.shared.evidenceSnapshot(),
                    outputGeneration: generation, at: anchor + UInt64(start + 160) * 62_500)
                await input.waitForProbe()
            }
            let probes = input.snapshot().nativeProbes - before
            let delay = duckAt.map { (Double($0) - Double(anchor)) / 1e9 - Double(16_000 + onset) / 16_000 }
            SelfTest.diagnostic("VOICE_DUCK_REPLAY mode=\(doubleTalk ? "double-talk" : "echo-only") nativeProbes=\(probes) duck=\(duckAt != nil) onsetToDuckSample=\(delay.map(String.init(describing:)) ?? "none")")
            if probes == 0 { failures.append("native VAD replay produced no callback") }
            if !doubleTalk && duckAt != nil { failures.append("pure authored echo ducked playback") }
            if doubleTalk && (delay == nil || delay! < 0 || delay! > 0.200) {
                failures.append("actual cleaned double-talk VAD did not duck within0.200s of authored onset")
            }
            if backing.paused || speech.currentPlaybackToken == 0 { failures.append("VAD replay paused/stopped output") }
        }
        let completed = input.snapshot().nativeProbes
        await capture.endSession(source: .done)
        input.ingest(mic, evidence: AcousticEchoProcessor.shared.evidenceSnapshot(),
            outputGeneration: speech.outputGeneration, at: VoiceLatencyTimeline.nowNanos())
        await input.waitForProbe()
        if input.snapshot().ready || input.snapshot().nativeProbes != completed || backing.outputGain != 1 {
            failures.append("closed native VAD input remained admitted or left output ducked")
        }
        return failures
    }

    /// Scripted probabilities test actual Capture -> AudioSession -> backing ownership.
    /// Native Silero/AEC qualification remains the unchanged authored barge/replay path.
    private static func voiceDuckHostCases() async -> [String] {
        let windowFailures = await CaptureVoiceActivityInput.windowGenerationSelfTestFailures()
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared
        await capture.endSession(source: .done)
        let backing = RecordingSpeechBacking()
        speech.useTestingBacking(backing)
        let priorHandler = capture.turnHandlerForTesting
        capture.turnHandlerForTesting = { _ in }
        defer {
            capture.turnHandlerForTesting = priorHandler
            speech.restoreSystemBacking()
        }
        await capture.beginSession(captureAudio: false)
        guard let id = capture.captureSessionID else { return ["duck host capture unavailable"] }
        audio.speak(OutputScheduler.tokenForTesting(), "The same reply must keep playing.")
        speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
        let generation = speech.outputGeneration
        let token = speech.currentPlaybackToken
        let stopCount = backing.stopCount
        let events = VoiceSession.shared.eventCount
        let pending = VoiceConversationCoordinator.shared.inputPending
        let start: UInt64 = 1_000_000_000
        func probe(_ probability: Float, _ echoOK: Bool, _ at: UInt64,
                   captureID: UUID? = nil, output: UInt64? = nil) {
            capture.noteVoiceActivity(.init(captureID: captureID ?? id,
                outputGeneration: output ?? generation, probability: probability,
                echoOK: echoOK, at: at), now: at)
        }
        var failures = windowFailures
        probe(0.9, false, start)
        probe(0.9, false, start + 50_000_000)
        probe(0.9, true, start + 100_000_000, captureID: UUID())
        probe(0.9, true, start + 150_000_000, output: generation &+ 1)
        if backing.outputGain != 1 { failures.append("echo or stale capture/output ducked playback") }
        probe(0.9, true, start + 200_000_000)
        if backing.outputGain != 1 { failures.append("one probability probe ducked playback") }
        probe(0.9, true, start + 250_000_000)
        let duckAt = audio.lastListeningDuckAt
        if backing.outputGain != RealtimeAudioSession.bargeDuckGain || duckAt == nil {
            failures.append("two valid probes did not duck actual current backing")
        }
        if speech.currentPlaybackToken != token || backing.paused || backing.stopCount != stopCount
            || VoiceSession.shared.eventCount != events
            || VoiceConversationCoordinator.shared.inputPending != pending {
            failures.append("VAD-only duck paused/stopped playback or raised a conversational barrier")
        }
        probe(0.9, true, start + 300_000_000)
        if audio.lastListeningDuckAt != duckAt { failures.append("duplicate VAD restamped first duck") }
        audio.releaseDuck(captureID: UUID(), outputGeneration: generation)
        audio.releaseDuck(captureID: id, outputGeneration: generation &+ 1)
        if backing.outputGain != RealtimeAudioSession.bargeDuckGain {
            failures.append("stale release changed the current duck")
        }
        probe(0.1, true, start + 350_000_000)
        probe(0.1, true, start + 450_000_000)
        probe(0.1, true, start + 550_000_000)
        if backing.outputGain != RealtimeAudioSession.bargeDuckGain {
            failures.append("duck released before300ms of observed silence")
        }
        probe(0.1, true, start + 650_000_000)
        if backing.outputGain != 1 { failures.append("observed300ms quiet did not release duck") }
        probe(0.9, true, start + 700_000_000)
        probe(0.9, true, start + 750_000_000)
        if backing.outputGain != RealtimeAudioSession.bargeDuckGain { failures.append("fresh speech could not duck again") }
        capture.transcript = "I need another answer"
        probe(0.1, true, start + 800_000_000)
        probe(0.1, true, start + 900_000_000)
        probe(0.1, true, start + 1_000_000_000)
        probe(0.1, true, start + 1_100_000_000)
        if backing.outputGain != RealtimeAudioSession.bargeDuckGain {
            failures.append("quiet VAD released an unresolved novel lexical turn")
        }
        capture.transcript = ""
        // Existing lexical provisional pause/resume retains the same token and gain.
        _ = audio.pauseForListening(captureID: id)
        _ = audio.resumeAfterListening(captureID: id)
        if speech.currentPlaybackToken != token || backing.paused
            || backing.outputGain != RealtimeAudioSession.bargeDuckGain {
            failures.append("lexical pause/resume changed the ducked reply")
        }
        audio.noteUserSpeech()
        if backing.outputGain != 1 || audio.isSpeaking || backing.stopCount != stopCount + 1 {
            failures.append("committed stop did not restore gain and stop exactly once")
        }
        audio.speak(OutputScheduler.tokenForTesting(), "A successor reply starts at normal gain.")
        speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
        let successor = speech.currentPlaybackToken
        probe(0.9, true, start + 800_000_000)
        probe(0.9, true, start + 850_000_000)
        if backing.outputGain != 1 || speech.currentPlaybackToken != successor {
            failures.append("old native output generation ducked a successor")
        }
        let nextGeneration = speech.outputGeneration
        probe(0.9, true, start + 900_000_000, output: nextGeneration)
        probe(0.9, true, start + 950_000_000, output: nextGeneration)
        audio.noteOutputFinished()
        if backing.outputGain != 1 { failures.append("natural completion did not restore gain") }
        await capture.endSession(source: .done)
        return failures
    }

    /// Actual cached-model owner across two distinct sessions, plus held join/pressure/quit.
    /// This checks residency and native probe consumption, never a wall-clock duck threshold.
    @MainActor
    private static func voiceDuckResidentCases() async -> [String] {
        guard SelfTest.requested == "--selftest-voice-turns",
              CommandLine.arguments.contains("--voice-duck-resident") else {
            return ["resident VAD fixture requires its exact self-test modifier"]
        }
        let capture = AgentCaptureController()
        let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared
        let backing = RecordingSpeechBacking()
        speech.useTestingBacking(backing)
        var failures: [String] = []
        capture.turnHandlerForTesting = { _ in }
        func check(_ text: String, _ good: Bool) { if !good { failures.append(text) } }
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SileroResident-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("missing.mlmodelc")
        let missing = CaptureVoiceActivityInput(captureID: UUID(), retiring: nil,
            cachedModel: missingURL) { _ in }
        await missing.waitUntilLoaded()
        check("missing admitted cache silently selected another model", !missing.snapshot().prepared
            && missing.snapshot().failure != nil && missing.snapshot().nativeProbes == 0)
        await missing.close().value
        check("cached Silero prewarm was not admitted through Capture", capture.prepareResidentVoiceActivity())
        await capture.voiceActivityInput?.waitUntilLoaded()
        let warmed = capture.voiceActivityInput
        check("idle prewarm did not retain prepared inert VAD", warmed?.snapshot().prepared == true
            && warmed?.snapshot().ready == false && warmed?.snapshot().nativeProbes == 0)
        await capture.beginSession(captureAudio: false)
        guard let firstID = capture.captureSessionID else {
            speech.restoreSystemBacking(); return failures + ["first fixture capture unavailable"]
        }
        capture.startVoiceActivity(for: firstID)
        guard let first = capture.voiceActivityInput else {
            await capture.endSession(); speech.restoreSystemBacking()
            return failures + ["first fixture VAD owner unavailable"]
        }
        await first.waitUntilLoaded()
        guard first.snapshot().ready else {
            await capture.endSession(); speech.restoreSystemBacking()
            return failures + ["VAD artifact unavailable: \(first.snapshot().failure ?? "unknown")"]
        }
        var firstManager = first.nativeManagerForResidentTesting()
        check("first session discarded prewarmed VAD owner/manager", warmed === first
            && firstManager != nil && warmed?.nativeManagerForResidentTesting() === firstManager)
        // One actual stateless native process consumes real ingest and reaches Capture.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
            let channel = buffer.floatChannelData?[0] else {
            await capture.endSession(); speech.restoreSystemBacking()
            return failures + ["VAD fixture PCM unavailable"]
        }
        buffer.frameLength = 4096
        for index in 0..<4096 { channel[index] = 0 }
        var seen: [UUID] = []
        capture.voiceActivityObserverForTesting = { seen.append($0.captureID) }
        func probe(_ input: CaptureVoiceActivityInput) async {
            audio.speak(OutputScheduler.tokenForTesting(), "The same reply keeps playing.")
            speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
            let evidence = AcousticEchoProcessor.Evidence(aecProcessed: true,
                recentReference: true, nearCandidate: false, independentNearCandidate: false,
                echoCoherence: 1, bestCoherence: 1, bestLagSamples: 0,
                referenceUnderflow: false, queuedReferenceSamples: 4096,
                rawRMS: 0, cleanedRMS: 0, referenceRMS: 0)
            input.ingest(buffer, evidence: evidence, outputGeneration: speech.outputGeneration,
                at: VoiceLatencyTimeline.nowNanos())
            await input.waitForProbe()
            check("native current-session VAD probe was not consumed", input.snapshot().nativeProbes == 1)
            check("silent echo-control native probe changed output gain", backing.outputGain == 1)
        }
        await probe(first)
        await capture.releaseIdleEOUUnderPressure()
        check("idle-pressure entry released an active VAD owner", capture.voiceActivityInput === first
            && first.snapshot().ready)
        await capture.endSession()
        check("ordinary close discarded prepared Silero weights", capture.voiceActivityInput === first
            && first.snapshot().prepared && !first.snapshot().ready)
        await capture.beginSession(captureAudio: false)
        guard let secondID = capture.captureSessionID else {
            speech.restoreSystemBacking(); return failures + ["second fixture capture unavailable"]
        }
        capture.startVoiceActivity(for: secondID)
        guard let second = capture.voiceActivityInput else {
            await capture.endSession(); speech.restoreSystemBacking()
            return failures + ["second fixture VAD owner unavailable"]
        }
        await second.waitUntilLoaded()
        check("second session reloaded a new Silero owner/manager", second === first && secondID != firstID
            && firstManager != nil && second.nativeManagerForResidentTesting() === firstManager)
        firstManager = nil
        await probe(second)
        check("native probe callbacks lost distinct capture ownership", seen == [firstID, secondID])
        let hold = VoiceInputProducerProbe(holdPrepare: true, holdFirstCommit: false)
        second.holdProbeForResidentTesting(hold)
        for _ in 0..<200 {
            if hold.snapshot().contains(where: { $0.kind == "prepare.held" }) { break }
            await Task.yield()
        }
        check("held VAD owner fixture never entered its existing task", hold.snapshot().contains { $0.kind == "prepare.held" })
        var ended = false
        let ending = Task { @MainActor in await capture.endSession(); ended = true }
        for _ in 0..<20 { await Task.yield() }
        check("normal VAD close returned before retained probe joined", !ended)
        hold.releaseAll()
        await ending.value
        await capture.releaseIdleEOUUnderPressure()
        check("idle pressure left Silero model/owner resident", capture.voiceActivityInput == nil && !second.snapshot().prepared)
        let before = seen.count
        second.ingest(buffer, evidence: AcousticEchoProcessor.Evidence(aecProcessed: true,
            recentReference: false, nearCandidate: true, independentNearCandidate: true,
            echoCoherence: 0, bestCoherence: 0, bestLagSamples: 0,
            referenceUnderflow: false, queuedReferenceSamples: 0,
            rawRMS: 1, cleanedRMS: 1, referenceRMS: 0),
            outputGeneration: speech.outputGeneration, at: VoiceLatencyTimeline.nowNanos())
        await second.waitForProbe()
        check("released VAD owner admitted new native work", seen.count == before && !second.snapshot().ready)
        _ = capture.prepareResidentVoiceActivity()
        await capture.voiceActivityInput?.waitUntilLoaded()
        let terminating = capture.voiceActivityInput
        await capture.beginEOUTermination()?.value
        check("quit failed to close/join idle prepared Silero", capture.voiceActivityInput == nil
            && terminating?.snapshot().prepared != true)
        check("terminated Capture admitted a Silero prewarm", !capture.prepareResidentVoiceActivity())
        capture.voiceActivityObserverForTesting = nil
        speech.restoreSystemBacking()
        SelfTest.diagnostic("VOICE_DUCK_RESIDENT: native probe captures=\(seen.count); scope=residency-not-latency")
        return failures
    }

    @MainActor
    static func disownSelfTestFailures() async -> [String] {
        if CommandLine.arguments.contains("--voice-duck-resident") { return await voiceDuckResidentCases() }
        if CommandLine.arguments.contains("--voice-duck-host") { return await voiceDuckHostCases() }
        var failures = await voiceDuckHostCases()

        let capture = AgentCaptureController.shared
        let island = IslandState.shared
        await capture.endSession(source: .done)
        await capture.beginSession(captureAudio: false)
        var turns: [String] = []
        let priorTurnHandler = capture.turnHandlerForTesting
        capture.turnHandlerForTesting = { turns.append($0) }

        let telemetryBefore = WakeWordTelemetry.shared.falseAccepts
        capture.simulateCumulativeSpeech("DJ Burger King is on the menu tonight")
        await capture.disown()
        let telemetryAfterFirst = WakeWordTelemetry.shared.falseAccepts
        if telemetryAfterFirst != telemetryBefore + 1 {
            failures.append("disown recorded \(telemetryAfterFirst - telemetryBefore) false accepts, expected one")
        }
        capture.simulateCumulativeSpeech("Yeah. Yeah.")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        await capture.waitForActiveTurnForTesting()

        if !turns.isEmpty {
            failures.append("a disowned session committed another turn: \(turns)")
        }
        if capture.isSessionActive {
            failures.append("a disowned session stayed active")
        }
        if capture.lastEndpoint != .disowned {
            failures.append("a disowned session ended from \(capture.lastEndpoint.rawValue), not disowned")
        }
        if island.kind != .agentReply("Okay, I'll ignore that.") {
            failures.append("a disowned session did not say it would ignore the speech: \(island.kind)")
        }
        await capture.disown()
        if WakeWordTelemetry.shared.falseAccepts != telemetryAfterFirst {
            failures.append("a repeat disown counted a second false accept")
        }

        capture.turnHandlerForTesting = priorTurnHandler
        await capture.endSession(source: .done)
        return failures
    }

    /// Exercises the production transcript/endpoint path with synthetic ASR
    /// while a recording TTS backing is active. No microphone or model needed.
    @MainActor
    static func overlappingBackchannelSelfTestFailures() async -> [String] {
        var failures: [String] = []
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        await capture.endSession(source: .done)
        speech.useTestingBacking(recorder)
        await capture.beginSession(captureAudio: false)
        var turns: [String] = []
        let priorTurnHandler = capture.turnHandlerForTesting
        capture.turnHandlerForTesting = { turns.append($0) }
        let priorPlaybackEvent = speech.onPlaybackEvent
        defer {
            speech.restoreSystemBacking()
            speech.onPlaybackEvent = priorPlaybackEvent
            capture.turnHandlerForTesting = priorTurnHandler
        }
        var interruptedPlaybackCount = 0
        speech.onPlaybackEvent = { event in
            priorPlaybackEvent?(event)
            if case .interrupted = event { interruptedPlaybackCount += 1 }
        }

        // A novel provisional partial yields the floor immediately, but must
        // retain the current token and queued clause until the recognizer
        // revises it into the exact playback echo. The endpoint then resumes
        // the same reply without producing an interruption receipt or turn.
        audio.speak(OutputScheduler.tokenForTesting(), "I can help with questions. I can also walk you through it.")
        speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
        let provisionalToken = speech.currentPlaybackToken
        let queuedBeforeProvisional = speech.pendingClauseCount
        capture.speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05)
        capture.simulateCumulativeSpeech("Please stop speaking")
        if !speech.isPausedForListening || !audio.isSpeaking
            || speech.currentPlaybackToken != provisionalToken
            || speech.pendingClauseCount != queuedBeforeProvisional
            || recorder.stopCount != 0 {
            failures.append("a provisional novel partial did not reversibly hold the same reply")
        }
        capture.simulateCumulativeSpeech("I can help with questions.")
        capture.turnDetectorReady = true
        capture.localDecoderCaughtUp = false
        capture.noteModelEOU("")
        if capture.wordlessModelEOU {
            failures.append("an empty endpoint from a backlogged decoder settled live Apple input")
        }
        capture.localDecoderCaughtUp = true
        capture.simulateCumulativeSpeech("Please stop speaking")
        capture.noteModelEOU("")
        if capture.wordlessModelEOU || capture.pendingTurn() != "Please stop speaking" {
            failures.append("a wordless local endpoint erased usable Apple words")
        }
        capture.simulateCumulativeSpeech("I can help with questions.")
        capture.noteModelEOU("")
        // No backdated 2.5-second silence: a confirmed wordless endpoint must
        // promptly settle this existing hold once input is quiet.
        capture.inputLevel = 0
        if !(await capture.tick(force: false)) {
            failures.append("a confirmed wordless endpoint waited for the fallback silence deadline")
        }
        await capture.waitForActiveTurnForTesting()
        if !turns.isEmpty || speech.isPausedForListening || !audio.isSpeaking
            || speech.currentPlaybackToken != provisionalToken
            || speech.pendingClauseCount != queuedBeforeProvisional
            || interruptedPlaybackCount != 0 || recorder.stopCount != 0 {
            failures.append("an echo revision did not resume the held reply without interruption")
        }
        capture.noteModelEOU("")
        if capture.wordlessModelEOU || capture.heardSpeech || capture.modelEOUAt != nil {
            failures.append("an idle wordless endpoint manufactured speech activity")
        }
        // A streaming decoder may stop midway through the last echoed word.
        // Its matching multiword context must not be discarded and leave that
        // temporary suffix looking like a new interruption (build66: quest).
        capture.noteModelPartial("I can help with quest")
        if !capture.transcript.isEmpty || speech.isPausedForListening
            || speech.currentPlaybackToken != provisionalToken {
            failures.append("an unfinished playback word caused a provisional interruption")
        }
        capture.noteModelEOU("I can help with questions")
        capture.inputLevel = 0
        _ = await capture.tick(force: false)
        if !turns.isEmpty || speech.isPausedForListening || recorder.stopCount != 0 {
            failures.append("completion of an echoed partial word created a turn or stopped output")
        }
        // Tear down the synthetic reply between cases. This deliberate test
        // teardown interruption is outside the echo-only assertion; the next
        // case records its own baseline.
        speech.stop()
        audio.noteOutputFinished()
        let interruptionsBeforeGenuineTurn = interruptedPlaybackCount
        let stopsBeforeGenuineTurn = recorder.stopCount

        // Reproduce the 18:48 feedback loop through the live acoustic advisory
        // entry point and both transcript producers, without a real microphone.
        audio.speak(OutputScheduler.tokenForTesting(), "I can help with questions or tasks—do you have anything in mind?")
        speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
        capture.noteAcousticLevel(0.8, nearCandidate: true)
        capture.speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05)
        capture.simulateCumulativeSpeech("I can help with questions.")
        if !capture.transcript.isEmpty || !audio.isSpeaking {
            failures.append("an acoustic candidate admitted playback or stopped the reply")
        }
        capture.noteAcousticLevel(0, nearCandidate: false)
        capture.turnDetectorReady = true
        capture.localDecoderCaughtUp = true
        capture.noteModelPartial("I can help with questions")
        capture.noteModelEOU("I can help with questions")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        await capture.waitForActiveTurnForTesting()
        if !turns.isEmpty || !audio.isSpeaking {
            failures.append("a stale acoustic candidate turned a local echo endpoint into user input")
        }
        capture.noteAcousticLevel(0.8, nearCandidate: true)
        capture.speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05)
        capture.simulateCumulativeSpeech("I can help with questions. Stop. I can help with questions.")
        capture.noteModelEOU("Stop. I can help with questions.")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        await capture.waitForActiveTurnForTesting()
        if turns != ["Stop."] || audio.isSpeaking {
            failures.append("echo protection lost the genuine interruption: \(turns)")
        }
        if recorder.stopCount != stopsBeforeGenuineTurn + 1
            || interruptedPlaybackCount <= interruptionsBeforeGenuineTurn {
            failures.append("a committed novel turn did not hard-stop playback exactly once")
        }
        await capture.endSession(source: .done)
        await capture.beginSession(captureAudio: false)
        turns.removeAll()

        // A standalone filler keeps the current reply alive and reaches the
        // endpoint sink without creating a model/work turn. A real phrase
        // beginning with the same filler must still barge in once it settles.
        let workBeforeHesitation = RealtimeAgent.shared.voiceWork?.id
        audio.speak(OutputScheduler.tokenForTesting(), "I am describing the result in detail.")
        speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
        capture.simulateCumulativeSpeech("Uh")
        if !audio.isSpeaking {
            failures.append("a standalone hesitation stopped playback on partial ASR")
        }
        if RealtimeAgent.shared.voiceInputActive {
            failures.append("a standalone hesitation became active voice input")
        }
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        await capture.waitForActiveTurnForTesting()
        if turns != ["Uh"] {
            failures.append("standalone hesitation was not delivered once: \(turns)")
        }
        if !audio.isSpeaking {
            failures.append("hesitation endpoint stopped playback")
        }
        if RealtimeAgent.shared.voiceWork?.id != workBeforeHesitation {
            failures.append("standalone hesitation created or replaced voice work")
        }

        let stopCountBeforeCorrection = recorder.stopCount
        // The recognizer is cumulative: the first Uh was already committed.
        // This second phrase begins with its own filler, which must survive.
        capture.simulateCumulativeSpeech("Uh uh stop")
        if !audio.isSpeaking || !speech.isPausedForListening {
            failures.append("meaningful provisional continuation did not pause playback")
        }
        if RealtimeAgent.shared.voiceInputActive || !VoiceConversationCoordinator.shared.inputPending {
            failures.append("provisional continuation did not hold input without committing it")
        }
        if recorder.stopCount != stopCountBeforeCorrection {
            failures.append("provisional continuation destroyed the paused reply")
        }
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        await capture.waitForActiveTurnForTesting()
        if turns != ["Uh", "uh stop"] || recorder.stopCount != stopCountBeforeCorrection + 1
            || audio.isSpeaking || speech.isPausedForListening {
            failures.append("meaningful continuation did not commit once and stop the held reply: \(turns)")
        }
        turns.removeAll()

        audio.speak(OutputScheduler.tokenForTesting(), "I am describing the result in detail.")
        speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
        capture.simulateCumulativeSpeech("mm hmm")
        if !audio.isSpeaking { failures.append("a brief acknowledgment stopped playback") }
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        if !turns.isEmpty { failures.append("an acknowledgment became a work turn") }
        if !audio.isSpeaking { failures.append("acknowledgment endpoint stopped playback") }

        // A volatile ASR prefix must not prevent its longer correction from
        // yielding the floor; this is the same method used by the live stream.
        capture.simulateCumulativeSpeech("mm hmm")
        if !audio.isSpeaking { failures.append("partial acknowledgment stopped playback") }
        capture.simulateCumulativeSpeech("mm hmm actually open Safari")
        if !audio.isSpeaking || !speech.isPausedForListening {
            failures.append("extended provisional correction did not pause playback")
        }
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        await capture.waitForActiveTurnForTesting()
        if turns != ["actually open Safari"] || audio.isSpeaking || speech.isPausedForListening {
            failures.append("extended correction did not commit once and stop playback: \(turns)")
        }

        // Mic energy without words must relinquish the input barrier after
        // silence. Otherwise a tool result can wait forever for a turn that
        // SpeechAnalyzer and the local EOU model never produced.
        RealtimeAgent.shared.userSpeechStarted()
        capture.heardSpeech = true
        capture.speechBeganAt = Date().addingTimeInterval(-3)
        capture.lastSpeechAt = Date().addingTimeInterval(-3)
        capture.inputLevel = 0
        capture.rawTranscript = ""
        capture.modelFinalText = ""
        capture.modelEOUAt = nil
        _ = await capture.considerEndpoint()
        if capture.heardSpeech || RealtimeAgent.shared.voiceInputActive
            || VoiceConversationCoordinator.shared.inputPending {
            failures.append("wordless mic activity kept the voice input floor or effect barrier")
        }

        audio.speak(OutputScheduler.tokenForTesting(), "I am describing the result in detail.")
        speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
        // simulateCumulativeSpeech backdates a fresh onset for endpoint tests;
        // this case needs a real just-started onset before its first fragment.
        capture.speechBeganAt = Date()
        capture.simulateCumulativeSpeech("Stop now")
        if !audio.isSpeaking {
            failures.append("an early ASR fragment skipped the minimum speech gate")
        }
        capture.speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05)
        _ = await capture.tick(force: false)
        if !audio.isSpeaking || !speech.isPausedForListening
            || RealtimeAgent.shared.voiceInputActive || !VoiceConversationCoordinator.shared.inputPending {
            failures.append("the VAD tick did not provisionally pause for an early ASR fragment")
        }
        RealtimeAgent.shared.discardVoiceInput()
        capture.resetTurn()
        capture.committedPrefix = ""
        capture.latestFullTranscript = "Hello"
        capture.rawTranscript = "Hello"
        capture.transcript = "Hello"
        capture.modelFinalText = "Hello there please tell me"
        capture.modelEOUAt = Date()
        capture.heardSpeech = true
        capture.speechBeganAt = Date().addingTimeInterval(-1)
        capture.lastSpeechAt = Date()
        capture.lastTranscriptChangeAt = Date()
        capture.inputLevel = 0
        let beforeEOU = turns.count
        let endedAtEOU = await capture.tick(force: true)
        await capture.waitForActiveTurnForTesting()
        if !endedAtEOU || turns.count != beforeEOU + 1
            || turns.last != "Hello there please tell me" {
            failures.append("confirmed local EOU waited for volatile Apple text or lost its full request")
        }
        audio.speak(OutputScheduler.tokenForTesting(), "I am describing the result in detail.")
        speech.notifyTestingFirstAudio(token: speech.currentPlaybackToken)
        capture.rawTranscript = "Wait"
        capture.transcript = "Wait"
        capture.speechBeganAt = Date().addingTimeInterval(-1)
        capture.turnDetectorReady = true
        capture.localDecoderCaughtUp = true
        capture.noteModelPartial("Wait stop speaking")
        if !audio.isSpeaking || !speech.isPausedForListening
            || capture.transcript != "Wait stop speaking" {
            failures.append("a stale Apple fragment blocked a newer local provisional interruption")
        }
        // The remaining preparation assertions exercise the production path,
        // then restore the caller's sink before this self-test returns.
        capture.turnHandlerForTesting = nil
        capture.speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05)
        capture.prepareResponseForRecognizedSpeech("Uh")
        if !capture.lastPreparedPartial.isEmpty {
            failures.append("a standalone hesitation started response preparation")
        }
        capture.speechBeganAt = Date()
        let beforeEarlyPartialEvents = VoiceSession.shared.eventCount
        capture.prepareResponseForRecognizedSpeech("Open Safari now")
        if VoiceSession.shared.eventCount != beforeEarlyPartialEvents {
            failures.append("an early speculative partial published a stable speech floor")
        }
        capture.speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05)
        capture.prepareResponseForRecognizedSpeech("Open Safari now")
        if capture.lastPreparedPartial != "Open Safari now" {
            failures.append("sustained novel speech did not prepare the conversational response")
        }
        capture.considerSpeechInterruption("Uh")
        if !capture.lastPreparedPartial.isEmpty {
            failures.append("a partial revised into hesitation kept stale response preparation")
        }
        capture.resetTurn()
        if !capture.lastPreparedPartial.isEmpty {
            failures.append("a new turn inherited the previous partial")
        }
        // Model progress chooses one text producer. A second recognizer may
        // revise its fallback snapshot without invalidating that preparation.
        let coordinator = VoiceConversationCoordinator.shared
        let priorStream = coordinator.streamForTesting
        coordinator.streamForTesting = { _, _ in AsyncThrowingStream { $0.finish() } }
        capture.committedPrefix = ""
        capture.localDecoderCaughtUp = false
        capture.turnDetectorReady = true
        capture.simulateCumulativeSpeech("Please tell me about a haiku")
        capture.noteModelPartial("Please tell me about a haiku poem in detail")
        if capture.localOwnsPartial || capture.lastPreparedPartial != "Please tell me about a haiku" {
            failures.append("local startup backlog replaced live Apple preparation")
        }
        if let id = capture.captureSessionID {
            capture.markLocalDecoderCaughtUp(captureID: id, reason: "self-test live watermark")
        }
        capture.noteModelPartial("Please explain a haiku briefly")
        capture.simulateCumulativeSpeech("Please tell me about a haiku and its many traditions")
        if !capture.localOwnsPartial || capture.transcript != "Please explain a haiku briefly"
            || capture.lastPreparedPartial != "Please explain a haiku briefly" {
            failures.append("late Apple revision replaced the local owner or cancelled its preparation")
        }
        capture.noteModelPartial("Explain a haiku")
        if capture.transcript != "Explain a haiku" || capture.pendingTurn() != "Explain a haiku"
            || capture.lastPreparedPartial != "Explain a haiku" {
            failures.append("shorter local correction lost source ownership")
        }
        capture.noteModelPartial("")
        if !capture.transcript.isEmpty || !capture.lastPreparedPartial.isEmpty
            || !capture.pendingTurn().isEmpty {
            failures.append("empty local correction retained stale text or preparation")
        }
        capture.noteModelEOU("Explain haiku")
        if capture.pendingTurn() != "Explain haiku" || !capture.shouldUseModelText() {
            failures.append("authoritative local endpoint lost to a longer Apple snapshot")
        }
        capture.releaseLocalDecoderOwnership(reason: "self-test decoder failure")
        if capture.localOwnsPartial || capture.localDecoderCaughtUp || capture.shouldUseModelText()
            || capture.pendingTurn() != capture.rawTranscript
            || capture.lastPreparedPartial != capture.rawTranscript {
            failures.append("decoder failure did not restore Apple fallback and preparation")
        }
        capture.localDecoderCaughtUp = true
        capture.noteModelPartial("Explain the next poem")
        capture.resetTurn()
        if capture.localOwnsPartial || !capture.localDecoderCaughtUp {
            failures.append("turn reset did not clear ownership while preserving decoder liveness")
        }
        coordinator.streamForTesting = priorStream
        await capture.endSession(source: .done)
        return failures
    }

    /// Same local partial consumer and coordinator/frontend as capture. The
    /// authored onset controls eligibility; it does not measure native ASR latency.
    static func earlyLexicalPreparationSelfTestFailures(
        source: VoicePreparationSelfTest.Source
    ) async -> [String] {
        guard SelfTest.requested == "--selftest-voice-latency",
              CommandLine.arguments.contains("--voice-latency-partials") else {
            return ["early lexical preparation fixture was not explicitly requested"]
        }
        let capture = AgentCaptureController.shared
        let coordinator = VoiceConversationCoordinator.shared
        let frontend = FrontendResponder.shared
        let speech = AgentSpeechSynthesizer.shared
        let shadow = VoiceSession.shared
        var failures: [String] = []
        capture.localDecoderCaughtUp = true
        capture.turnDetectorReady = true
        let messagesBefore = AgentSession.shared.messages.count
        let workBefore = RealtimeAgent.shared.voiceWork?.id
        let playbackBefore = speech.currentPlaybackToken
        let queueBefore = speech.pendingClauseCount
        let pauseBefore = speech.isPausedForListening
        let eventsBefore = shadow.eventCount
        let sourceBefore = source.count
        capture.speechBeganAt = Date().addingTimeInterval(-0.160)
        capture.noteModelPartial("How does rain form")
        if shadow.eventCount != eventsBefore || capture.voiceShadowHasFloor
            || capture.activeTurnTask != nil || coordinator.inputPending
            || speech.currentPlaybackToken != playbackBefore
            || speech.pendingClauseCount != queueBefore
            || speech.isPausedForListening != pauseBefore {
            failures.append("160 ms speculative input published a floor, changed playback, or submitted a turn")
        }
        if !(await source.waitForCount(sourceBefore + 1, within: .milliseconds(150))) {
            failures.append("160 ms capture partial did not reach the actual speculative generator")
        }
        let firstCount = source.count
        capture.speechBeganAt = Date().addingTimeInterval(-0.199)
        capture.noteModelPartial("How does rain form in clouds")
        if shadow.eventCount != eventsBefore || capture.voiceShadowHasFloor {
            failures.append("199 ms local revision published an early stable floor")
        }
        if !(await source.waitForCount(firstCount + 1, within: .milliseconds(150))) {
            failures.append("199 ms capture revision did not replace the actual speculative generator")
        }
        if firstCount > sourceBefore,
           !(await source.waitForCancellation(firstCount - 1)) {
            failures.append("actual revised capture input did not cancel the old speculative generator")
        }
        let revisedCount = source.count
        capture.speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05)
        capture.considerSpeechInterruption(capture.transcript, source: .local)
        let lateEvents = shadow.eventCount
        if lateEvents != eventsBefore + 1 {
            failures.append("unchanged early words did not publish their stable floor after minSpeech")
        }
        capture.considerSpeechInterruption(capture.transcript, source: .local)
        if shadow.eventCount != lateEvents || source.count != revisedCount {
            failures.append("repeated eligible words duplicated stable publication or inference")
        }
        capture.speechBeganAt = Date().addingTimeInterval(-0.199)
        capture.noteModelPartial("Uh")
        if revisedCount > sourceBefore,
           !(await source.waitForCancellation(revisedCount - 1)) {
            failures.append("capture hesitation revision did not cancel the actual speculative generator")
        }
        coordinator.discardInput()
        capture.resetTurn()
        // An already-pending barrier must not turn early speculative words into
        // a captured acoustic floor. Preserve its existing reducer state exactly.
        coordinator.inputActivityStarted()
        let pendingEvents = shadow.eventCount
        let pendingFloor = shadow.state.floor
        let pendingHeld = shadow.state.effectsHeld
        let final = "How does rain form in the sky"
        let finalBefore = source.count
        capture.speechBeganAt = Date().addingTimeInterval(-0.199)
        capture.noteModelPartial(final)
        if capture.voiceShadowHasFloor || shadow.eventCount != pendingEvents
            || shadow.state.floor != pendingFloor || shadow.state.effectsHeld != pendingHeld {
            failures.append("199 ms preparation acquired or republished an already-pending shadow floor")
        }
        if await source.waitForCount(finalBefore + 1, within: .milliseconds(150)),
           let request = source.last {
            source.finishLast()
            do {
                let stream = await ModelPassRecorder.$correlation.withValue(request.correlation) {
                    await frontend.stream(system: VoiceConversationCoordinator.systemPrompt,
                        messages: request.messages, maxTokens: 256)
                }
                var answer = ""
                for try await delta in stream { answer += delta }
                if answer != "<answer/> Prepared \(final)." || source.count != finalBefore + 1 {
                    failures.append("exact committed stream did not consume the early capture preparation once")
                }
            } catch { failures.append("early capture preparation adoption failed: \(error.localizedDescription)") }
        } else { failures.append("pending-input early capture partial did not reach the actual frontend") }
        if AgentSession.shared.messages.count != messagesBefore
            || RealtimeAgent.shared.voiceWork?.id != workBefore
            || capture.activeTurnTask != nil
            || speech.currentPlaybackToken != playbackBefore
            || speech.pendingClauseCount != queueBefore
            || speech.isPausedForListening != pauseBefore {
            failures.append("speculative capture/cancellation/adoption changed speech, work, or committed history")
        }
        coordinator.discardInput()
        capture.resetTurn()
        return failures
    }

    /// Reversible listening is exercised with explicit candidates until
    /// physical AEC proves that live speaker echo cannot trigger this path.
    static func reversibleListeningSelfTestFailures() async -> [String] {
        var failures: [String] = []
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        await capture.endSession(source: .done)
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking() }
        await capture.beginSession(captureAudio: false)
        guard let oldID = capture.captureSessionID else {
            return ["listening pause test did not open capture"]
        }
        audio.speak(OutputScheduler.tokenForTesting(), "I am describing the result in detail.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        let candidateAt = Date()
        capture.considerListeningCandidate(true, now: candidateAt)
        if !synth.isPausedForListening || synth.didStop || !audio.isSpeaking {
            failures.append("near candidate did not reversibly pause active playback")
        }
        if let pausedAt = audio.lastListeningPauseAt {
            SelfTest.diagnostic("VOICE_LISTEN_CANDIDATE_TO_PAUSE=\(pausedAt.timeIntervalSince(candidateAt))s")
        } else {
            failures.append("near candidate produced no first-pause timing receipt")
        }
        capture.considerListeningCandidate(false, now: candidateAt.addingTimeInterval(0.3))
        if synth.isPausedForListening || synth.didStop || !audio.isSpeaking {
            failures.append("unrecognized quiet did not resume the original playback token")
        }

        capture.considerListeningCandidate(true)
        capture.simulateCumulativeSpeech("mm hmm")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        if synth.isPausedForListening || synth.didStop || !audio.isSpeaking {
            failures.append("backchannel did not resume the original reply")
        }

        capture.considerListeningCandidate(true)
        capture.simulateCumulativeSpeech("Wait stop speaking")
        if synth.didStop || !synth.isPausedForListening || !audio.isSpeaking {
            failures.append("provisional words destroyed a paused reply")
        }
        let priorHandler = capture.turnHandlerForTesting
        capture.turnHandlerForTesting = { _ in }
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        await capture.waitForActiveTurnForTesting()
        capture.turnHandlerForTesting = priorHandler
        if !synth.didStop || synth.isPausedForListening || audio.isSpeaking {
            failures.append("committed novel words did not hard-stop a paused reply")
        }
        if audio.resumeAfterListening(captureID: oldID) {
            failures.append("hard-stopped audio could be resumed by a stale hold")
        }
        await capture.endSession(source: .done)
        await capture.beginSession(captureAudio: false)
        audio.speak(OutputScheduler.tokenForTesting(), "A new reply belongs to a new session.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        capture.considerListeningCandidate(true)
        if audio.resumeAfterListening(captureID: oldID) || !synth.isPausedForListening {
            failures.append("an old capture ID resumed a newer reply")
        }
        if let newID = capture.captureSessionID {
            _ = audio.resumeAfterListening(captureID: newID)
        }
        await capture.endSession(source: .done)
        return failures
    }

    /// The wrapper stays so the goodbye branch is one line, and the rule is P1-15's.
    ///
    /// It was a `contains` over a phrase list, so any fragment anywhere in a turn closed the
    /// session before the request was handed on — and the branch closes the coordinator, ends
    /// the audio session and clears the announcement queue **first**, so the answer was
    /// probably never spoken. Now it is whole-turn signatures, in `VoiceTurnPolicy`, graded
    /// there against a positive corpus of ordinary speech.
    private static func isGoodbye(_ text: String) -> Bool {
        VoiceTurnPolicy.isClosingTurn(text)
    }
}

// Applied native diagnostic. Compilation and actual native verdict are pending.
// Root owns registration and the one final OK/FAILED marker. No fake/native fallback.
extension AgentCaptureController {
    private enum NativeInputFixtureMode: String, CaseIterable {
        case cold
        case precommit
        case overlap
    }

    /// Start with coldOnly=true to retain the original one-WAV native red first.
    /// ColdOnly=false additionally requires the two genuine B-preservation cases.
    static func runNativeInputProducerFixtureSelfTest(first: URL, second: URL,
        coldOnly: Bool = true) async -> [String] {
        guard SelfTest.isRunning else { return ["input producer fixture requires isolated self-test mode"] }
        var failures: [String] = []
        let modes = coldOnly ? [NativeInputFixtureMode.cold] : NativeInputFixtureMode.allCases
        for mode in modes {
            if Task.isCancelled {
                failures.append("input producer conductor cancelled before \(mode.rawValue)")
                break
            }
            let result = await runNativeInputProducerCase(mode, first: first, second: second)
            failures += result.failures
            if !result.cleanupComplete { break }
        }
        return failures
    }

    private static func runNativeInputProducerCase(_ mode: NativeInputFixtureMode,
        first: URL, second: URL) async -> (failures: [String], cleanupComplete: Bool) {
        let capture = AgentCaptureController.shared
        let previousHandler = capture.turnHandlerForTesting
        var failures: [String] = []
        var probe: VoiceInputProducerProbe?
        var secondFeed: Task<Void, Error>?
        var turns: [(text: String, source: EndpointSource)] = []
        let label = "input.\(mode.rawValue)"

        @MainActor func require(_ value: Bool, _ message: String) {
            if !value { failures.append("\(label): \(message)") }
        }
        @MainActor func wait(_ name: String, seconds: TimeInterval,
            until condition: @escaping @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            while !condition() {
                if Task.isCancelled {
                    failures.append("\(label): cancelled waiting for \(name)")
                    return false
                }
                if ContinuousClock.now >= deadline {
                    failures.append("\(label): bounded wait expired for \(name)")
                    return false
                }
                // Test conductor polling only; no production wait or endpoint change.
                do { try await Task.sleep(for: .milliseconds(5)) }
                catch {
                    failures.append("\(label): cancelled polling \(name)")
                    return false
                }
            }
            return true
        }
        @MainActor func events(_ kind: String) -> [VoiceInputProducerProbe.Event] {
            probe?.snapshot().filter { $0.kind == kind } ?? []
        }
        @MainActor func haveCompleteProcessCoverage() -> Bool {
            let captured = events("captured").compactMap(\.input)
            let processed = events("process.end").compactMap(\.input)
            let coveredSequences = Set(processed.map(\.sequence))
            return !captured.isEmpty && captured.allSatisfy { coveredSequences.contains($0.sequence) }
        }
        @MainActor func settled() -> Bool {
            haveCompleteProcessCoverage()
                && events("callback.eou").count == events("callback.eou.handled").count
                && capture.modelEOUAt == nil && capture.activeTurnTask == nil
        }

        // No async defer: release holders synchronously, then await all cleanup
        // below the do/catch, before restoring the previous handler.
        do {
            let newProbe = try await capture.beginInputProducerFixtureForTesting(
                wav: first, holdPrepare: mode != .overlap,
                holdFirstCommit: mode != .cold) { text in
                    turns.append((text, capture.lastEndpoint))
                }
            probe = newProbe
            guard let format = capture.fileCaptureFormat,
                format.commonFormat == .pcmFormatFloat32, format.sampleRate == 16_000,
                format.channelCount == 1, !format.isInterleaved else {
                throw NativeInputFixtureError.stage("actual capture format was not Float32/16000/mono")
            }
            let preparationEvent = mode == .overlap ? "prepare.ready" : "prepare.held"
            guard await wait(preparationEvent, seconds: 90,
                until: { !events(preparationEvent).isEmpty }) else {
                throw NativeInputFixtureError.stage("native preparation checkpoint unavailable")
            }
            capture.startInputProducerFixtureFeedForTesting()

            if mode == .cold {
                guard await wait("first actual VAD commit", seconds: 12,
                    until: { !turns.isEmpty }) else {
                    throw NativeInputFixtureError.stage("actual Apple/VAD initial commit absent")
                }
                require(turns.count == 1, "first input committed \(turns.count) times before decoder release")
                require(turns.first?.source == .vad, "initial endpoint was not actual VAD fallback")
                guard await wait("unchanged first WAV/tail completion", seconds: 8,
                    until: { capture.fileFeedCompletedAt != nil }) else {
                    throw NativeInputFixtureError.stage("first WAV did not finish")
                }
                if let feed = capture.fileSessionProgress.feed { await feed.value }
                require(!events("reset.requested").isEmpty,
                    "first commit did not queue an actual detector reset behind preparation")
                newProbe.releasePrepare()
            } else {
                guard await wait("first selected commit held", seconds: 12,
                    until: { !events("commit.selected").isEmpty }) else {
                    throw NativeInputFixtureError.stage("real endpoint did not select first commit")
                }
                require(events("commit.emitted").isEmpty, "first commit was not held")
                secondFeed = Task { @MainActor in
                    defer { newProbe.record("second.feed.completed") }
                    try await capture.feedInputProducerFixtureSecondForTesting(wav: second)
                }
                guard await wait("B captured before A commit", seconds: 5,
                    until: { events("captured").contains { $0.input?.second == true } }) else {
                    throw NativeInputFixtureError.stage("precommit B buffer absent")
                }
                if mode == .overlap {
                    guard await wait("first B frame inside actual decoder suffix", seconds: 8,
                        until: { nativeInputSuffixContainsFirstB(newProbe.snapshot()) }) else {
                        throw NativeInputFixtureError.stage("retained 80 ms overlap was not exercised")
                    }
                }
                newProbe.releaseCommit()
                newProbe.releasePrepare()
                guard await wait("unchanged second WAV/tail completion", seconds: 15,
                    until: { !events("second.feed.completed").isEmpty }) else {
                    throw NativeInputFixtureError.stage("second WAV did not finish")
                }
                if let secondFeed { try await secondFeed.value }
            }

            guard await wait("actual native EOU", seconds: 30,
                until: { !events("native.eou").isEmpty }) else {
                throw NativeInputFixtureError.stage("native EOU absent; no scripted substitute")
            }
            guard await wait("actual decoder/EOU/handler drain", seconds: 30,
                until: { settled() }) else {
                throw NativeInputFixtureError.stage("native input/callback delivery did not settle")
            }
            await capture.waitForActiveTurnForTesting()
            require(capture.fileFeedFailure == nil, "first file feed failed")
            require(capture.eouDroppedChunks == 0, "actual backlog dropped \(capture.eouDroppedChunks) chunks")
            require(events("capture.format.invalid").isEmpty, "delivered PCM broke canonical format")
            require(events("process.failed").isEmpty, "native processing failed; failed input cannot count as completed coverage")
            let trace = newProbe.snapshot()
            failures += validateNativeInputFrameTrace(trace, label: label)
            require(turns.first?.text.lowercased().contains("haiku") == true,
                "actual first transcript lost the fixture's haiku request")

            if mode == .cold {
                require(turns.count == 1, "original single WAV committed \(turns.count) turns")
                require(events("commit.emitted").count == 1,
                    "old decoded input reached the actual emit/reset producer again")
                if let firstCommit = events("commit.emitted").first {
                    require(events("native.eou").contains {
                        guard let input = $0.input else { return false }
                        return !input.second && input.frames.upperBound <= firstCommit.capturedEnd
                    }, "native endpoint did not cover an actual precommit input process interval")
                } else {
                    require(false, "first commit's captured boundary missing")
                }
            } else {
                require(turns.count == 2, "two input files committed \(turns.count) turns")
                let secondText = turns.dropFirst().first?.text.lowercased() ?? ""
                require(secondText.contains("wait") && secondText.contains("stop speaking"),
                    "native B did not retain its initial Wait and stop-speaking request")
                require(turns.dropFirst().first?.source == .localEOU,
                    "B endpoint was not native local EOU; Apple/VAD wording is not native preservation")
                let commitIndices = trace.indices.filter { trace[$0].kind == "commit.emitted" }
                if commitIndices.count >= 2 {
                    let secondCommit = commitIndices[1]
                    require(trace[..<secondCommit].contains {
                        $0.kind == "native.eou" && $0.input?.second == true
                    }, "no actual B-associated native endpoint preceded B commit")
                } else {
                    require(false, "second emitted commit missing for native B causality")
                }
                let firstB = events("captured").compactMap(\.input).first { $0.second }
                let selected = events("commit.selected").first
                let emitted = events("commit.emitted").first
                if let firstB, let selected, let emitted {
                    require(selected.capturedEnd <= firstB.frames.lowerBound
                        && firstB.frames.lowerBound < firstB.frames.upperBound
                        && firstB.frames.upperBound <= emitted.capturedEnd,
                        "frame trace did not prove B arrived after A selection but before A commit")
                } else {
                    require(false, "actual precommit B/selection/emission frame evidence missing")
                }
                if mode == .overlap {
                    failures += validateNativeInputResetSuffix(trace, label: label)
                }
            }
            SelfTest.diagnostic("NATIVE_INPUT_CASE=\(mode.rawValue) commits=\(turns.count) "
                + "nativeEOU=\(events("native.eou").count) captures=\(events("captured").count) "
                + "processed=\(events("process.end").count) resetGrants=\(events("reset.granted").count)")
            for event in trace where event.kind != "captured" && event.kind != "process.begin" {
                let interval = event.input.map { "\($0.frames.lowerBound)..<\($0.frames.upperBound)" } ?? "none"
                SelfTest.diagnostic("NATIVE_INPUT_EVENT=\(mode.rawValue):\(event.kind) "
                    + "processInput=\(interval) epoch=\(event.epoch.map(String.init) ?? "none") "
                    + "capturedEnd=\(event.capturedEnd)")
            }
        } catch {
            failures.append("\(label): \(error.localizedDescription)")
        }

        // Every exit, including cancellation/failed preparation, releases both
        // continuations before awaiting feed/decoder cleanup. No fire-and-forget defer.
        // The cleanup method snapshots task handles before releasing either
        // holder, ends the session, then bounds their actual completion joins.
        let cleanupFailures = await capture.endInputProducerFixtureForTesting(secondFeed: secondFeed)
        failures += cleanupFailures.map { "\(label): \($0)" }
        capture.turnHandlerForTesting = previousHandler
        return (failures, cleanupFailures.isEmpty)
    }

    private enum NativeInputFixtureError: Error, LocalizedError {
        case stage(String)
        var errorDescription: String? {
            switch self { case .stage(let message): return message }
        }
    }

    private static func validateNativeInputFrameTrace(_ trace: [VoiceInputProducerProbe.Event],
        label: String) -> [String] {
        let captured = trace.filter { $0.kind == "captured" }.compactMap(\.input)
        let processed = trace.filter { $0.kind == "process.end" }.compactMap(\.input)
        guard !captured.isEmpty else { return ["\(label): no canonical captured intervals"] }
        var failures: [String] = []
        var nextFrame = 0
        var previousSequence: Int?
        for input in captured {
            if input.frames.lowerBound != nextFrame || input.frames.isEmpty {
                failures.append("\(label): noncontiguous/empty actual capture interval \(input.sequence)")
            }
            if let previousSequence, input.sequence != previousSequence + 1 {
                failures.append("\(label): actual capture sequence discontinuity")
            }
            nextFrame = input.frames.upperBound
            previousSequence = input.sequence
            if !processed.contains(where: { $0.sequence == input.sequence && $0.frames == input.frames }) {
                failures.append("\(label): captured interval \(input.sequence) never completed actual processing")
            }
        }
        if processed.contains(where: { item in !captured.contains { $0.sequence == item.sequence && $0.frames == item.frames } }) {
            failures.append("\(label): processing claimed an interval not captured by the real delivery closure")
        }
        return failures
    }

    /// Computes only the inspected manager's retained PCM suffix, never a
    /// spoken utterance end or token timestamp. Reset/format/discontinuity invalidate origin.
    private static func nativeInputSuffix(_ trace: ArraySlice<VoiceInputProducerProbe.Event>) -> Range<Int>? {
        let lastReset = trace.lastIndex { $0.kind == "reset.completed" }
        let afterReset = lastReset.map { trace.index(after: $0) } ?? trace.startIndex
        let inputs = trace[afterReset...].filter { $0.kind == "process.end" }.compactMap(\.input)
        guard let first = inputs.first, let last = inputs.last else { return nil }
        var next = first.frames.lowerBound
        for input in inputs {
            guard input.frames.lowerBound == next else { return nil }
            next = input.frames.upperBound
        }
        let count = last.frames.upperBound - first.frames.lowerBound
        let shifts = count < 2_560 ? 0 : 1_280 * (1 + (count - 2_560) / 1_280)
        return (first.frames.lowerBound + shifts)..<last.frames.upperBound
    }

    private static func nativeInputSuffixContainsFirstB(_ trace: [VoiceInputProducerProbe.Event]) -> Bool {
        guard let firstB = trace.first(where: { $0.kind == "captured" && $0.input?.second == true })?.input,
            let suffix = nativeInputSuffix(trace[...]) else { return false }
        return suffix.contains(firstB.frames.lowerBound)
            && trace.contains { $0.kind == "process.end" && $0.input?.sequence == firstB.sequence }
    }

    private static func validateNativeInputResetSuffix(_ trace: [VoiceInputProducerProbe.Event],
        label: String) -> [String] {
        let secondInputs = trace.filter { $0.kind == "captured" }.compactMap(\.input).filter(\.second)
        var exercised = false
        var failures: [String] = []
        for index in trace.indices where trace[index].kind == "reset.granted" {
            guard let suffix = nativeInputSuffix(trace[..<index]) else { continue }
            for input in secondInputs {
                let low = max(input.frames.lowerBound, suffix.lowerBound)
                let high = min(input.frames.upperBound, suffix.upperBound)
                guard low < high else { continue }
                exercised = true
                // The original reset clears this real buffered PCM. A correct
                // implementation must avoid clearing it or truthfully replay it.
                // Future reset-preserves-buffer implementations need their real
                // producer observation here; no unverified preservation marker passes.
                let later = trace[(index + 1)...].filter { $0.kind == "process.end" }.compactMap(\.input)
                var cursor = low
                for replay in later.sorted(by: { $0.frames.lowerBound < $1.frames.lowerBound }) {
                    if replay.frames.lowerBound <= cursor && replay.frames.upperBound > cursor {
                        cursor = min(high, replay.frames.upperBound)
                    }
                }
                if cursor < high {
                    failures.append("\(label): actual reset cleared B suffix \(low)..<\(high) without input resubmission")
                }
            }
        }
        if !exercised {
            failures.append("\(label): no reset of B's actual 80 ms suffix observed; preservation mechanism remains unverified")
        }
        return failures
    }
}
