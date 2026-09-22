import AVFoundation
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

/// Continuous agent listen: wake or ⇧⌘ Space opens a session; local EOU endpoints one
/// turn; the session stays open until Done, idle, or goodbye.
///
/// End-of-utterance comes from a local Parakeet streaming model when available.
/// Apple SpeechAnalyzer supplies the user-facing text. Dictation stays push-to-talk.
@MainActor
@Observable
final class AgentCaptureController {
    static let shared = AgentCaptureController()

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
        case idle
        case none
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
    private var turnDetectorTask: Task<Void, Never>?
    private var turnAudioBacklog: TurnAudioBacklog?
    private var turnDetectorReady = false
    /// The local decoder owns the visible/preparation candidate only after it
    /// has reached live cadence and produced a nonempty partial for this turn.
    /// `localDecoderCaughtUp` is session-liveness state; ownership is per turn.
    private var localDecoderCaughtUp = false
    private var localOwnsPartial = false
    private var deferFrontendForEOU = false
    private var modelEOUAt: Date?
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
    private var turnGeneration = 0
    /// A suspended fake lets `--selftest-realtime` prove the next endpoint does
    /// not wait for a previous tool. Never installed during normal operation.
    @ObservationIgnored var turnHandlerForTesting: (@MainActor (String) async -> Void)?
    private var heardSpeech = false
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

    func beginSession(captureAudio: Bool = true) async {
        if isSessionActive { return }
        let captureID = UUID()
        captureSessionID = captureID
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
        isSessionActive = true
        // A voice conversation does not share the CPU with an embedding backfill.
        Task { await EmbeddingRuntime.shared.stopNow() }
        RealtimeAudioSession.shared.begin()
        RealtimeAgent.shared.userSpeechEnded()
        ActivationController.shared.markListening()
        lastEndpoint = .none
        lastReply = ""
        lastEmittedRequest = ""
        committedPrefix = ""
        latestFullTranscript = ""
        localDecoderCaughtUp = false
        localOwnsPartial = false
        deferFrontendForEOU = false
        resetTurn()
        turnDetectorReady = false
        modelEOUAt = nil
        eouDroppedChunks = 0
        IslandState.shared.showAgentListening(transcript: "", level: 0)

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

    /// Self-test source: no microphone grant or hub subscription. The decoder
    /// and all subsequent turn handling are the production instances.
    func beginFileSession(wav: URL, deferFeed: Bool = false,
        appleFastResults: Bool = true, prepareResources: Bool = true) async throws {
        await beginSession(captureAudio: false)
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
        isSessionActive = false
        captureSessionID = nil
        VoiceConversationCoordinator.shared.closeSession()
        await LocalVoiceFrontend.shared.clearStagedTurn()
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
        if RealtimeAgent.shared.isThinking {
            RealtimeAgent.shared.cancel()
        }
        lastEndpoint = source
        RealtimeAudioSession.shared.end()
        VoiceAnnouncementQueue.shared.clear()
        stopVAD()
        await stopEngine()
        // Done closes the session. The VAD endpoint is the only path that
        // submits speech; a cumulative ASR tail after Done is often playback
        // or a revision of a request already in flight.
        // A new session may have opened while the detached engine drained.
        // Its card and capture state belong to that newer session.
        guard captureSessionID == nil else { return }
        if lastReply.isEmpty {
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
        IslandState.shared.showAgentListening(transcript: text, level: level)
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
        consumeTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, self.captureSessionID == captureID else { return }
                    let full = chunk.text
                    if self.fileFeedTask != nil {
                        self.fileASRChunkCount += 1
                        self.fileLastASRText = full
                        if self.fileFirstAppleASRAt == nil, !full.isEmpty {
                            self.fileFirstAppleASRAt = Date()
                            let fromVoice = self.fileFirstVoiceAt.map {
                                String(format: "%.3f", Date().timeIntervalSince($0))
                            } ?? "none"
                            SelfTest.diagnostic("VOICE_APPLE_FIRST_RESULT=voice+\(fromVoice)s text=\(full)")
                        }
                    }
                    if full != self.latestFullTranscript {
                        self.lastTranscriptChangeAt = Date()
                    }
                    self.latestFullTranscript = full
                    let turn = Self.pending(full: full, committed: self.committedPrefix)
                    self.rawTranscript = turn
                    let userTurn = self.filterAppleRecognition(turn, provisional: !chunk.isFinal)
                    self.echoProbeDiagnostic("apple raw=\(turn) filtered=\(userTurn)")
                    if self.fileFeedTask != nil { self.fileLastFilteredASRText = userTurn }
                    // Apple remains the raw/cumulative fallback. Once the
                    // local decoder owns this turn, late Apple revisions are
                    // diagnostics only and cannot replace its shorter or
                    // corrected visible/preparation candidate.
                    if !self.localOwnsPartial {
                        self.transcript = userTurn
                        self.considerSpeechInterruption(userTurn, source: .apple)
                    }
                    if RealtimeAgent.shared.voiceInputActive
                        || (!RealtimeAgent.shared.isThinking && !RealtimeAudioSession.shared.isSpeaking) {
                        IslandState.shared.showAgentListening(transcript: self.transcript, level: self.level)
                    }
                    if chunk.isFinal, userTurn.count >= Limits.minCharacters {
                        self.heardSpeech = true
                        self.lastSpeechAt = Date().addingTimeInterval(-Limits.endpointSilence)
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
        let detector = LocalVoiceTurnDetector()
        turnDetector = detector
        self.turnAudioBacklog = turnAudioBacklog
        let eouCallback = makeEOUCallback(captureID: captureID, epoch: turnEpoch)
        let partialCallback = makePartialCallback(captureID: captureID, epoch: turnEpoch)
        turnDetectorTask = Task.detached(priority: .userInitiated) {
            do {
                let prepareStarted = Date()
                try await detector.prepare(onEndOfUtterance: eouCallback,
                    onPartial: partialCallback)
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
                    if fileURL != nil {
                        SelfTest.diagnostic("VOICE_EOU_PREPARE=\(Date().timeIntervalSince(prepareStarted))s")
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
                    try await detector.process(chunk)
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
                Log.agent.error("local voice EOU unavailable: \(error.localizedDescription, privacy: .public)")
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
            await detector.close()
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
            continuation.yield(cleaned)
            let dropped = turnAudioBacklog.enqueue((cleaned, Date(), turnAudioSequence.next()))
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
                if fileFirstVoiceAt == nil { fileFirstVoiceAt = now }
                fileLastVoiceAt = now
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

    private func stopEngine() async {
        AudioCaptureHub.shared.unsubscribe(.agent)
        fileFeedTask?.cancel()
        fileFeedTask = nil
        deferredFileFeed = nil
        audioContinuation?.finish()
        audioContinuation = nil
        turnAudioBacklog?.finish()
        turnAudioBacklog = nil
        turnDetectorTask?.cancel()
        turnDetectorTask = nil
        turnDetector = nil
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
        if let finishing {
            _ = await withBoundedWait(RealtimeAgent.Limits.captureFinish) {
                await finishing.finish()
            }
        }
    }

    private func startVAD() {
        vadTask?.cancel()
        vadTask = Task { @MainActor [weak self] in
            while let self, self.isSessionActive, !Task.isCancelled {
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
            IslandState.shared.showAgentListening(transcript: transcript, level: level)
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
        guard isSessionActive, turnHandlerForTesting == nil,
              !frontendStagedForTurn, !deferFrontendForEOU else { return }
        frontendStagedForTurn = true
        Task {
            do {
                try await LocalVoiceFrontend.shared.stageNextTurn(
                    system: VoiceConversationCoordinator.systemPrompt)
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
    }

    private func noteModelPartial(_ modelText: String) {
        guard isSessionActive, turnDetectorReady else { return }
        let candidate = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate != modelPartialText else { return }
        echoProbeDiagnostic("local partial=\(candidate) caughtUp=\(localDecoderCaughtUp)")
        wordlessModelEOU = false
        modelPartialText = candidate
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
        { modelText in
            Task { @MainActor in
                let capture = AgentCaptureController.shared
                guard capture.captureSessionID == captureID,
                      capture.turnEpoch == epoch else { return }
                capture.noteModelEOU(modelText)
            }
        }
    }

    private func makePartialCallback(captureID: UUID, epoch: Int) -> @Sendable (String) -> Void {
        { modelText in
            Task { @MainActor in
                let capture = AgentCaptureController.shared
                guard capture.captureSessionID == captureID,
                      capture.turnEpoch == epoch else { return }
                capture.noteModelPartial(modelText)
            }
        }
    }

    private enum PartialSource { case apple, local, selected }

    private func considerSpeechInterruption(_ userTurn: String, source: PartialSource = .selected) {
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
                VoiceConversationCoordinator.shared.inputActivityStarted()
            }
            if let captureID = captureSessionID {
                _ = RealtimeAudioSession.shared.pauseForListening(
                    captureID: captureID)
            }
        }
    }

    /// A partial is useful only after the same acoustic/lexical floor checks
    /// used for a real turn. Preparation has no speech or tool sink; a revised
    /// or empty partial cancels its pending debounce. Do not clear the final
    /// partial in resetTurn: handle() compares the exact committed request.
    private func prepareResponseForRecognizedSpeech(_ userTurn: String) {
        guard isSessionActive, captureSessionID != nil,
              turnHandlerForTesting == nil, !deferFrontendForEOU else { return }
        let trimmed = userTurn.trimmingCharacters(in: .whitespacesAndNewlines)
        let beganLongEnough = speechBeganAt.map {
            Date().timeIntervalSince($0) >= Limits.minSpeech
        } ?? false
        let candidate = beganLongEnough && trimmed.count >= Limits.minCharacters
            && !Self.isInFlightRepeat(trimmed, previous: lastEmittedRequest)
            && !Self.isCommittedTranscriptRevision(trimmed, committed: committedPrefix)
            && !VoiceTurnPolicy.isHesitation(trimmed)
            && !VoiceTurnPolicy.isBackchannel(trimmed,
                whileAssistantSpeaking: overlappedAssistantSpeech)
            ? trimmed : ""
        guard candidate != lastPreparedPartial else { return }
        lastPreparedPartial = candidate
        VoiceConversationCoordinator.shared.prepareResponseIfUseful(candidate)
    }

    @discardableResult
    private func tick(force: Bool) async -> Bool {
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
                resumeListeningAfterDiscard()
                RealtimeAgent.shared.discardVoiceInput()
                await LocalVoiceFrontend.shared.clearStagedTurn()
                resetTurn()
                return true
            }
            if text.count >= Limits.minCharacters {
                if VoiceTurnPolicy.isBackchannel(text,
                    whileAssistantSpeaking: overlappedAssistantSpeech) {
                    Log.agent.info("realtime · absorbed conversational acknowledgment")
                    commitRawTurn()
                    resumeListeningAfterDiscard()
                    RealtimeAgent.shared.discardVoiceInput()
                    await LocalVoiceFrontend.shared.clearStagedTurn()
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
                    resumeListeningAfterDiscard()
                    RealtimeAgent.shared.discardVoiceInput()
                    await LocalVoiceFrontend.shared.clearStagedTurn()
                    resetTurn()
                    return true
                }
                if RealtimeAudioSession.shared.isLikelyPlaybackEcho(text) {
                    Log.agent.info("realtime · discarded playback echo")
                    commitRawTurn()
                    resumeListeningAfterDiscard()
                    RealtimeAgent.shared.discardVoiceInput()
                    await LocalVoiceFrontend.shared.clearStagedTurn()
                    resetTurn()
                    return true
                }
                if Self.isCommittedTranscriptRevision(text, committed: committedPrefix) {
                    Log.agent.info("realtime · discarded revised transcript")
                    commitRawTurn()
                    resumeListeningAfterDiscard()
                    RealtimeAgent.shared.discardVoiceInput()
                    await LocalVoiceFrontend.shared.clearStagedTurn()
                    resetTurn()
                    return true
                }
                if Self.isGoodbye(text) {
                    isSessionActive = false
                    VoiceConversationCoordinator.shared.closeSession()
                    await LocalVoiceFrontend.shared.clearStagedTurn()
                    RealtimeAudioSession.shared.end()
                    VoiceAnnouncementQueue.shared.clear()
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

        if VoiceAnnouncementQueue.shared.flush(userHasFloor: heardSpeech || !pendingTurn().isEmpty) {
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
        lastEndpoint = source
        if fileFeedTask != nil {
            fileCommittedTurns += 1
            fileEndpointAt = Date()
            if let modelEOUAt {
                SelfTest.diagnostic("VOICE_MODEL_EOU_TO_ENDPOINT=\(Date().timeIntervalSince(modelEOUAt))s")
            }
        }
        // A committed non-filler turn is now user-owned. Hard-stop the held
        // output before ending the input phase; a provisional partial never
        // reaches this path and therefore cannot destroy a reply that later
        // turns out to be playback echo.
        if !(continueSession && VoiceTurnPolicy.isHesitation(text)) {
            RealtimeAgent.shared.userSpeechStarted()
        }
        // The acoustic floor ended. Keep the coordinator's inputPending effect
        // barrier until the committed text reaches the frontend below.
        RealtimeAgent.shared.userSpeechEnded()
        lastEmittedRequest = text
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
            if let testHandler = turnHandlerForTesting {
                await testHandler(text)
            } else {
                VoiceConversationCoordinator.shared.noteHesitation(text)
            }
            lastActivityAt = Date()
            return
        }
        if continueSession, turnHandlerForTesting == nil,
           RealtimeAgent.shared.appendVoiceFollowUp(text) {
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
            activeTurnTask = Task { @MainActor [weak self] in
                if let testHandler = self?.turnHandlerForTesting {
                    await testHandler(text)
                } else {
                    _ = await RealtimeAgent.shared.handle(text, source: .voice)
                }
                guard let self, self.turnGeneration == generation, self.isSessionActive else {
                    return
                }
                self.activeTurnTask = nil
                self.lastActivityAt = Date()
                ActivationController.shared.markListening()
                IslandState.shared.showAgentListening(transcript: "", level: 0)
            }
            return
        }
        _ = await RealtimeAgent.shared.handle(text, source: .voice)
        lastActivityAt = Date()
    }

    /// Wait for a lightweight test turn before asserting its reply.
    func waitForActiveTurnForTesting() async {
        await activeTurnTask?.value
    }

    func noteAssistantReply(_ text: String) {
        lastReply = text
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
        return failures
    }

    /// Real TTS plays while the file-fed production recognizers listen. This
    /// proves a novel ASR fragment can interrupt an active output queue; the
    /// separately measured live microphone probe is needed for room acoustics.
    static func runVoiceBargeSelfTest(wav: URL,
        appleFastResults: Bool = true) async -> [String] {
        let capture = AgentCaptureController.shared
        await capture.endSession(source: .done)
        do { try await capture.beginFileSession(wav: wav, deferFeed: true,
            appleFastResults: appleFastResults) }
        catch { return ["could not open barge-in session: \(error.localizedDescription)"] }
        let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared
        let priorPlaybackEvent = speech.onPlaybackEvent
        let priorTurnHandler = capture.turnHandlerForTesting
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
        audio.speak(longReply)
        let outputDeadline = Date().addingTimeInterval(20)
        while firstOutputAt == nil && Date() < outputDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var failures: [String] = []
        if firstOutputAt == nil || !audio.isSpeaking {
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

    private func resetTurn() {
        appleEchoRecognition = .init()
        localEchoRecognition = .init()
        wordlessModelEOU = false
        turnEpoch &+= 1
        if let turnDetector {
            if let captureID = captureSessionID {
                let callback = makeEOUCallback(captureID: captureID, epoch: turnEpoch)
                let partial = makePartialCallback(captureID: captureID, epoch: turnEpoch)
                Task { await turnDetector.resetForNextTurn(
                    onEndOfUtterance: callback, onPartial: partial) }
            }
        }
        transcript = ""
        rawTranscript = ""
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
        if shouldUseModelText() {
            return filterLocalRecognition(modelFinalText, provisional: false)
        }
        if localOwnsPartial {
            return filterLocalRecognition(modelPartialText, provisional: provisional)
        }
        return filterAppleRecognition(rawTranscript, provisional: provisional)
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
        audio.speak("I can help with questions. I can also walk you through it.")
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
        audio.speak("I can help with questions or tasks—do you have anything in mind?")
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
        audio.speak("I am describing the result in detail.")
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

        audio.speak("I am describing the result in detail.")
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

        audio.speak("I am describing the result in detail.")
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
        audio.speak("I am describing the result in detail.")
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
        capture.prepareResponseForRecognizedSpeech("Open Safari now")
        if !capture.lastPreparedPartial.isEmpty {
            failures.append("an early partial started response preparation before the speech floor")
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
        audio.speak("I am describing the result in detail.")
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
        audio.speak("A new reply belongs to a new session.")
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

    private static func isGoodbye(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return [
            "that's all", "thats all", "that's it", "thats it",
            "goodbye", "good bye", "stop listening", "go to sleep",
            "nothing else", "we're done", "we are done",
        ].contains { lowered.contains($0) }
    }
}
