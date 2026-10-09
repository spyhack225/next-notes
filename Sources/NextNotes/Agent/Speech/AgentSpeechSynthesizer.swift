import AVFoundation
import Foundation
import Observation

/// Playback receipt metadata. A diagnostic fake does not prove native playback.
struct PCMPlaybackBufferObservation: Sendable, Equatable {
    let token: UInt64
    let ordinal: Int
    let lowerFrame: Int64
    let upperFrame: Int64
    let sampleRate: Double
}
struct PCMPlaybackNativeObservation: Sendable, Equatable {
    let buffer: PCMPlaybackBufferObservation
    let originPhase: UInt64
    let callbackKind: Int
    let originHostTime: UInt64
    let originWasMainThread: Bool
}
struct PCMPlaybackCursorObservation: Sendable, Equatable {
    let frame: Int64
    let sampleRate: Double
    let nodeHostTime: UInt64
    let observedHostTime: UInt64
}
enum PCMPlaybackTimelineObservation: Sendable, Equatable {
    case scheduled(PCMPlaybackBufferObservation)
    case paused(token: UInt64, phase: UInt64)
    case resumed(token: UInt64, phase: UInt64, requestedHostTime: UInt64,
                 cursor: PCMPlaybackCursorObservation?, checkpoint: Int64?)
    case handled(PCMPlaybackNativeObservation, currentPhase: UInt64,
                 cursor: PCMPlaybackCursorObservation?, checkpointBefore: Int64?,
                 checkpointAfter: Int64?, currentOwner: Bool, candidate: Bool)
    case stopped(token: UInt64?, phaseBefore: UInt64)
}

struct PCMResumePlaybackReceipt: Sendable, Equatable {
    let packet: PCMPlaybackNativeObservation
    let earlier: PCMPlaybackCursorObservation
    let later: PCMPlaybackCursorObservation
    let checkpoint: Int64
    let checkpointBuffer: PCMPlaybackBufferObservation
}

struct RawPCMPlayedNotice: Sendable, Equatable {
    let buffer: PCMPlaybackBufferObservation
    let callbackKind: Int
    let nativeEntryHostTime: UInt64
}

/// Playback backend. Production uses the selected Pocket or Kokoro voice; the self-test
/// swaps in a recorder so interrupt can be asserted without a speaker.
@MainActor
protocol AgentSpeechBacking: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String, volume: Float, token: UInt64)
    func pauseForListening()
    func resumeAfterListening()
    func stop()
    var outputGain: Float { get }
    func setOutputGain(_ gain: Float)
}

extension AgentSpeechBacking {
    var outputGain: Float { 1 }
    func setOutputGain(_ gain: Float) { }
}

/// A backing that can supply fresh same-token playback proof after resume.
@MainActor
protocol AgentReceiptSpeechBacking: AgentSpeechBacking {
    var currentResumePhase: UInt64? { get }
    var onResumePlaybackAcknowledged: ((PCMResumePlaybackReceipt) -> Void)? { get set }
}

/// Reply-scoped native synthesis: clauses may be prepared before earlier playback ends.
/// The existing synthesizer still owns tokens, order and delivery acknowledgements.
@MainActor
protocol AgentReplySpeechBacking: AgentSpeechBacking {
    var onUtteranceStarted: ((UInt64) -> Void)? { get set }
    var onUtteranceFinished: ((UInt64) -> Void)? { get set }
    var onFailure: ((String, Float, UInt64) -> Void)? { get set }
    func beginReply(volume: Float)
    func enqueue(_ text: String, token: UInt64)
    func finishReply()
}

/// Speaks `AgentSpeechPolicy.spokenClauses` with a ready allowed voice
/// one utterance at a time, never waits for the queue to drain, and is always
/// interruptible — `stop()` cancels the current clause and clears the rest.
///
/// Dictation never calls this. The Pocket and Kokoro backings only
/// play audio; neither backing attaches to the input node.
@MainActor
@Observable
final class AgentSpeechSynthesizer {
    enum PlaybackEvent: Equatable {
        case began(UInt64)
        case enqueued(String)
        case startAcknowledged(String)
        case resumeRequested(token: UInt64, phase: UInt64)
        case resumeAcknowledged(PCMResumePlaybackReceipt)
        case completed(String)
        case interrupted(String, wasRendered: Bool)
    }
    static let shared = AgentSpeechSynthesizer()

    /// Capability of the currently selected output route, not a playback claim.
    /// Pocket/Kokoro resume their players but provide no qualified post-resume
    /// receipt. Their pending shadow status must never be adopted as live UI truth.
    var supportsQualifiedResumeReceipt: Bool { backing is any AgentReceiptSpeechBacking }
    var speechSynthesisCallsForTesting: Int { 0 }
    func setVoiceReadinessForTesting(engine: String, ready: Bool) {
        guard SelfTest.isRunning else { return }
        if engine == "pocket" { pocketReadinessForTesting = ready }
        if engine == "kokoro" { kokoroReadinessForTesting = ready }
    }
    func setVoiceFailureForTesting(_ failed: Bool) {
        guard SelfTest.isRunning else { return }
        selectedVoiceFailed = failed
    }
    private var selectedVoiceFailed = false
    private var launchPreparationStarted = false
    /// Settings and reply presentation observe the same existing voice owner.
    var availability: AgentVoiceAvailability {
        switch Self.selectedEngine {
        case "kokoro":
            return .resolve(ready: kokoroIsReady,
                            preparing: KokoroAgentVoice.shared.isPreparing,
                            failed: selectedVoiceFailed || !KokoroAgentVoice.isSupportedOS
                                || KokoroAgentVoice.shared.errorMessage != nil)
        case "pocket":
            return .resolve(ready: pocketIsReady,
                            preparing: PocketAgentVoice.shared.isPreparing,
                            failed: selectedVoiceFailed || PocketAgentVoice.shared.errorMessage != nil)
        default: return .failed
        }
    }

    /// Normal startup only. Pocket's existing prepareTask owns initialization,
    /// download, warmup and termination; Settings joins that same task.
    func prepareAtLaunch() {
        guard !SelfTest.isRunning, !launchPreparationStarted else { return }
        launchPreparationStarted = true
        Task { @MainActor in
            switch Self.selectedEngine {
            case "kokoro": await KokoroAgentVoice.shared.prepare(automatic: true)
            default: await PocketAgentVoice.shared.prepareAutomatically()
            }
        }
    }

    /// A file-synthesis failure belongs to the same selected availability policy.
    /// A changed selection and a cancelled render cannot poison another voice.
    func noteSelectedVoiceFailure(engine: String) {
        guard Self.selectedEngine == engine else { return }
        selectedVoiceFailed = true
    }

    func prepareSelectedVoice() async {
        selectedVoiceFailed = false
        switch Self.selectedEngine {
        case "kokoro": await KokoroAgentVoice.shared.prepare()
        default: await PocketAgentVoice.shared.prepare()
        }
    }

    private var backing: any AgentSpeechBacking
    private let unavailableBacking = UnavailableSpeechBacking()
    private(set) var outputAvailability: AgentVoiceAvailability?
    /// A reply's route is fixed at its beginning, even if preparation finishes later.
    private var replyCanSpeak = false
    var canSpeak: Bool { testingBacking || persistentPlaybackBacking != nil || availability == .ready }
    private let pocketBacking = PocketSpeechBacking()
    private let pocketSourceBacking = PocketSourceSpeechBacking()
    private let kokoroBacking = KokoroSpeechBacking()
    private var testingBacking = false
    /// A probe may keep one source graph alive for several clauses. This is
    /// selected only by the explicit self-test lifecycle below.
    private var persistentPlaybackBacking: (any AgentSpeechBacking)?
    private var persistentPlaybackUsesPocketSource = false
    private(set) var persistentPlaybackFailure: String?
    /// Remaining clauses after the one currently speaking (or just enqueued).
    private var pendingClauses: [String] = []
    // Native utterance identity aligned with currentClause + pendingClauses.
    // This is the same clause owner, not a second text/delivery queue.
    private var replyTokens: [UInt64] = []
    private var replyOpen = false
    private var replyFinished = false
    /// Set by `stop()`. The interrupt self-test fails unless this path ran.
    private(set) var didStop = false
    private(set) var isPausedForListening = false
    /// Current output has no fresh playback proof after its accepted pause.
    /// On Pocket/Kokoro this remains unsupported (capability is false), not a
    /// promise that a receipt will arrive. Physical resume stays immediate.
    /// Historical clauseRendered remains intact; shadow projection only.
    private var voiceResumePending = false
    struct ResumeBinding: Sendable, Equatable { let token: UInt64; let phase: UInt64 }
    private(set) var voiceResumeBinding: ResumeBinding?
    /// Applied to each utterance. Duplex ducking lowers this while speaking.
    var utteranceVolume: Float = 1.0
    private var listeningOutputGain: Float = 1
    var outputGain: Float { backing.outputGain }
    func setOutputGain(_ gain: Float) {
        listeningOutputGain = max(0, min(1, gain))
        backing.setOutputGain(listeningOutputGain)
    }
    /// Forces the output backend for one run without writing the user's preference
    /// (`Settings.agentVoiceEngine`). Honoured only under the self-test harness, because
    /// changing `Settings` from a self-test writes the owner's defaults.
    var engineOverrideForTesting: String?
    // Nil for ordinary playback; the existing scripted suspend flag drives
    // preparation availability without loading or changing the chosen voice.
    private var pocketReadinessForTesting: Bool?
    private var kokoroReadinessForTesting: Bool?
    private var kokoroIsReady: Bool {
        if SelfTest.isRunning, let kokoroReadinessForTesting { return kokoroReadinessForTesting }
        return KokoroAgentVoice.shared.isReady
    }
    private var pocketIsReady: Bool {
        if SelfTest.isRunning, let pocketReadinessForTesting { return pocketReadinessForTesting }
        return PocketAgentVoice.shared.isReady
    }
    /// Called on the backing's first output acknowledgement. Pocket reports
    /// the first completed player buffer;
    /// Kokoro reports a successful `play()`. These are different strengths of
    /// evidence and none proves the sample reached a person's ears.
    var onFirstAudio: (() -> Void)?
    /// Called when a pending first-audio callback is cancelled by barge-in.
    var onFirstAudioCancelled: (() -> Void)?
    /// Reports what the output backend acknowledged. `startAcknowledged` is
    /// backend-specific, not proof that a human heard a sample.
    var onPlaybackEvent: ((PlaybackEvent) -> Void)?
    private var currentClause: String?
    private var currentClauseRendered = false
    /// Monotonic output generation. A delegate callback from an interrupted
    /// utterance carries its old token and cannot close a new reply's span.
    private(set) var outputGeneration: UInt64 = 0
    struct VoiceLifecycleSnapshot {
        let generation: UInt64
        let hasClause: Bool
        let rendered: Bool
        let paused: Bool
        let resumePending: Bool
        /// False means positive resume proof is unavailable, rather than delayed.
        let supportsQualifiedResumeReceipt: Bool
        let resumeBinding: ResumeBinding?
    }
    var voiceLifecycleSnapshot: VoiceLifecycleSnapshot {
        .init(generation: outputGeneration, hasClause: currentClause != nil,
              rendered: currentClauseRendered, paused: isPausedForListening,
              resumePending: voiceResumePending, supportsQualifiedResumeReceipt: supportsQualifiedResumeReceipt,
              resumeBinding: voiceResumeBinding)
    }
    /// Observes only after clearing/advancing a clause; never controls playback.
    var onVoiceLifecycleSettled: (() -> Void)?
    private var playbackTokenCounter: UInt64 = 0
    private(set) var currentPlaybackToken: UInt64 = 0

    /// Clauses waiting after the current utterance. Zero when idle or after stop.
    var pendingClauseCount: Int { pendingClauses.count }

    init(backing: (any AgentSpeechBacking)? = nil) {
        self.backing = backing ?? unavailableBacking
        pocketBacking.onUtteranceFinished = { [weak self] token in
            self?.didFinishAudio(token: token)
        }
        pocketBacking.onUtteranceStarted = { [weak self] token in
            self?.didBeginAudio(token: token)
        }
        pocketBacking.onFailure = { [weak self] text, volume, token in
            self?.fallbackCurrentClause(text: text, token: token)
        }
        pocketSourceBacking.onUtteranceFinished = { [weak self] token in
            self?.didFinishAudio(token: token)
        }
        pocketSourceBacking.onUtteranceStarted = { [weak self] token in
            self?.didBeginAudio(token: token)
        }
        pocketSourceBacking.onFailure = { [weak self] text, volume, token in
            guard let self else { return }
            guard self.persistentPlaybackUsesPocketSource else {
                self.fallbackCurrentClause(text: text, token: token)
                return
            }
            // A source backing is used as an experimental probe. Switching voices
            // here would turn a failed source run into a false pass.
            guard token == self.currentPlaybackToken else { return }
            self.persistentPlaybackFailure =
                "Pocket source playback failed for token \(token)."
            Log.agent.error(
                "Pocket source playback failed token=\(token, privacy: .public)"
            )
            SelfTest.failed = true
            self.stop()
        }
        kokoroBacking.onUtteranceFinished = { [weak self] token in
            self?.didFinishAudio(token: token)
        }
        kokoroBacking.onUtteranceStarted = { [weak self] token in
            self?.didBeginAudio(token: token)
        }
        kokoroBacking.onFailure = { [weak self] text, volume, token in
            self?.fallbackCurrentClause(text: text, token: token)
        }

    }

    var isSpeaking: Bool { backing.isSpeaking || !pendingClauses.isEmpty }

    /// Enqueue speakable clauses and return immediately. An empty form is a no-op.
    /// Replaces any in-flight reply so a newer answer never stacks under an old one.
    /// Prefer `StreamingSpeechBuffer` when text arrives in chunks; this remains
    /// the one-shot path used by tests and non-streaming callers.
    func speak(_ reply: String) {
        let clauses = AgentSpeechPolicy.spokenClauses(reply)
        guard !clauses.isEmpty else { return }
        prepareForStream()
        if !replyCanSpeak {
            for clause in clauses { enqueueClause(clause) }
            finishStream()
            return
        }
        if backing is any AgentReplySpeechBacking {
            for clause in clauses { enqueueClause(clause) }
            finishStream()
            return
        }
        pendingClauses = Array(clauses.dropFirst())
        currentClause = clauses[0]
        currentClauseRendered = false
        onPlaybackEvent?(.enqueued(clauses[0]))
        for clause in pendingClauses { onPlaybackEvent?(.enqueued(clause)) }
        startClause(clauses[0])
    }

    /// Clear prior playback so a streamed reply can enqueue clauses one by one.
    /// Called by `StreamingSpeechBuffer.begin` — does not set `didStop`.
    func prepareForStream() {
        setOutputGain(1)
        voiceResumePending = false
        voiceResumeBinding = nil
        isPausedForListening = false
        outputAvailability = nil
        replyCanSpeak = true
        let closingReply = replyOpen
        interruptCurrentClause()
        replyTokens.removeAll()
        replyOpen = false
        replyFinished = false
        currentPlaybackToken = 0
        outputGeneration &+= 1
        onPlaybackEvent?(.began(outputGeneration))
        didStop = false
        pendingClauses.removeAll()
        if backing.isSpeaking || closingReply {
            backing.stop()
        }
        if !testingBacking {
            if let persistentPlaybackBacking {
                backing = persistentPlaybackBacking
                Log.agent.info(
                    "voice playback route selected=persistent \(self.persistentPlaybackUsesPocketSource ? "pocket-source" : "fixed-wav")"
                )
            } else {
                switch Self.selectedEngine {
                case "pocket" where availability == .ready:
                    backing = pocketBacking
                case "kokoro" where availability == .ready:
                    backing = kokoroBacking
                default:
                    backing = unavailableBacking
                    replyCanSpeak = false
                    outputAvailability = availability
                }
                Log.agent.info(
                    "voice playback route selected=settings \(String(describing: type(of: self.backing)))"
                )
            }
        }
        backing.setOutputGain(listeningOutputGain)
    }

    /// What `prepareForStream` picks. A self-test may name the engine instead of the
    /// person; nothing else may.
    private static var selectedEngine: String {
        if SelfTest.isRunning, let override = AgentSpeechSynthesizer.shared.engineOverrideForTesting {
            return override
        }
        return Settings.shared.agentVoiceEngine
    }

    /// Exact process diagnostic only; the saved voice choice is never changed.
    static func pocketProbeRequested(requested: String?, arguments: [String]) -> Bool {
        guard let requested,
              ["--selftest-voice-suspend-live", "--selftest-voice-barge"].contains(requested),
              arguments.contains("--voice-test-pocket") else { return false }
        let tests = arguments.filter {
            $0.hasPrefix("--selftest") && $0 != SelfTest.outputFlag && $0 != SelfTest.timeoutFlag
        }
        return tests == [requested]
    }

    var isPocketProbePlayback: Bool {
        Self.pocketProbeRequested(requested: SelfTest.requested, arguments: CommandLine.arguments)
            && (backing as AnyObject) === pocketBacking
    }

    /// Append one already-split clause. Starts playback when idle; otherwise
    /// queues behind the current utterance. No-op after `stop()` until
    /// `prepareForStream` / `speak` resets.
    func enqueueClause(_ clause: String) {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !didStop else { return }
        if !replyCanSpeak {
            // Preserve written text in its existing consumer and retain an unheard
            // speech fact. Preparation must never play this stale answer later.
            onPlaybackEvent?(.enqueued(trimmed))
            onPlaybackEvent?(.interrupted(trimmed, wasRendered: false))
            return
        }
        if let reply = backing as? any AgentReplySpeechBacking {
            let beginning = !replyOpen
            if beginning { replyOpen = true; replyFinished = false }
            playbackTokenCounter &+= 1
            let token = playbackTokenCounter
            replyTokens.append(token)
            if currentClause == nil && pendingClauses.isEmpty {
                currentClause = trimmed
                currentClauseRendered = false
                currentPlaybackToken = token
            } else { pendingClauses.append(trimmed) }
            onPlaybackEvent?(.enqueued(trimmed))
            if beginning { reply.beginReply(volume: utteranceVolume) }
            backing.setOutputGain(listeningOutputGain)
            reply.enqueue(trimmed, token: token)
            return
        }
        if backing.isSpeaking || !pendingClauses.isEmpty || isPausedForListening {
            pendingClauses.append(trimmed)
            onPlaybackEvent?(.enqueued(trimmed))
        } else {
            currentClause = trimmed
            currentClauseRendered = false
            onPlaybackEvent?(.enqueued(trimmed))
            startClause(trimmed)
        }
    }

    /// Text EOF is separate from playback drain, including a paused reply.
    func finishStream() {
        if !replyCanSpeak {
            let hadPendingAudio = onFirstAudio != nil
            onFirstAudio = nil
            if hadPendingAudio { onFirstAudioCancelled?() }
            RealtimeAudioSession.shared.noteOutputFinished()
            onVoiceLifecycleSettled?()
            return
        }
        guard !didStop, replyOpen, !replyFinished,
              let reply = backing as? any AgentReplySpeechBacking else { return }
        replyFinished = true
        reply.finishReply()
        if currentClause == nil && pendingClauses.isEmpty { advanceQueue() }
    }

    /// Barge-in / VAD / Stop. Immediate, not word-boundary. Clears every
    /// pending clause so mid-reply cut-off does not keep speaking the rest.
    /// Target <100 ms.
    func stop(advanceGeneration: Bool = true) {
        setOutputGain(1)
        voiceResumePending = false
        voiceResumeBinding = nil
        isPausedForListening = false
        interruptCurrentClause()
        replyTokens.removeAll()
        replyOpen = false
        replyFinished = false
        if advanceGeneration { outputGeneration &+= 1 }
        currentPlaybackToken = 0
        let hadPendingAudio = onFirstAudio != nil
        didStop = true
        pendingClauses.removeAll()
        onFirstAudio = nil
        if hadPendingAudio { onFirstAudioCancelled?() }
        backing.stop()
        onVoiceLifecycleSettled?()
    }

    /// Suspends the rendered player without invalidating the clause token,
    /// TTS producer, pending buffers, or queued follow-up clauses. The caller
    /// must later classify input and either resume or use the hard `stop()`.
    func pauseForListening() {
        guard !didStop, currentClause != nil, !isPausedForListening else { return }
        isPausedForListening = true
        voiceResumePending = true
        voiceResumeBinding = nil
        backing.pauseForListening()
    }

    func resumeAfterListening() {
        guard isPausedForListening, !didStop else { return }
        isPausedForListening = false
        backing.resumeAfterListening()
        if let receiptBacking = backing as? any AgentReceiptSpeechBacking,
           let phase = receiptBacking.currentResumePhase {
            voiceResumeBinding = .init(token: currentPlaybackToken, phase: phase)
            onPlaybackEvent?(.resumeRequested(token: currentPlaybackToken, phase: phase))
        }
        // A late completion can arrive while the player is paused. In that
        // case advanceQueue held the next clause; start it only now.
        if currentClause == nil { advanceQueue() }
    }

    /// Self-test only. Restored by interrupt / stream self-tests so a later
    /// turn reselects the requested allowed voice.
    /// Legacy fallback argument is accepted for parallel diagnostic callers but
    /// deliberately ignored: a failed selected voice always settles as text.
    func useTestingBacking(_ backing: any AgentSpeechBacking, fallback: (any AgentSpeechBacking)? = nil) {
        self.backing.stop()
        testingBacking = true
        self.backing = backing
        if let receipt = backing as? any AgentReceiptSpeechBacking {
            receipt.onResumePlaybackAcknowledged = { [weak self] value in self?.didResumeAudio(value) }
        }
        if let reply = backing as? any AgentReplySpeechBacking {
            reply.onUtteranceStarted = { [weak self] token in self?.didBeginAudio(token: token) }
            reply.onUtteranceFinished = { [weak self] token in self?.didFinishAudio(token: token) }
            reply.onFailure = { [weak self] text, volume, token in
                self?.fallbackCurrentClause(text: text, token: token)
            }
        }
    }

    /// Drive the real unavailable selector without a model load or saved choice.
    func useUnavailableVoiceForTesting() {
        guard SelfTest.isRunning else { return }
        backing.stop()
        testingBacking = false
        engineOverrideForTesting = "pocket"
        pocketReadinessForTesting = false
        selectedVoiceFailed = false
    }

    func clearVoiceReadinessForTesting() {
        guard SelfTest.isRunning else { return }
        engineOverrideForTesting = nil
        pocketReadinessForTesting = nil
        kokoroReadinessForTesting = nil
    }

    /// Prepare the experimental Pocket source renderer for a probe session.
    /// A supplied fixed WAV backing wins over the source flag and is assumed to
    /// have already been prepared by its owner (`PCMProbeSpeechBacking`
    /// follows that convention). Production calls are ignored deliberately.
    func preparePersistentPocketPlayback(
        fixedWAVOverride: (any AgentSpeechBacking)? = nil
    ) throws {
        guard SelfTest.isRunning else { return }

        if let fixedWAVOverride {
            endPersistentPocketPlayback()
            persistentPlaybackBacking = fixedWAVOverride
            persistentPlaybackUsesPocketSource = false
            persistentPlaybackFailure = nil
            Log.agent.info("voice playback route selected=fixed-wav override")
            return
        }

        guard CommandLine.arguments.contains("--voice-pocket-source") else {
            return
        }
        if persistentPlaybackUsesPocketSource,
           persistentPlaybackBacking != nil {
            return
        }

        endPersistentPocketPlayback()
        try pocketSourceBacking.prepare()
        persistentPlaybackBacking = pocketSourceBacking
        persistentPlaybackUsesPocketSource = true
        persistentPlaybackFailure = nil
        Log.agent.info("voice playback route selected=pocket-source")
    }

    /// End the probe session and release the source graph. The fixed WAV
    /// owner is stopped but not otherwise dismantled; its owner retains the
    /// `prepare/endTest` lifecycle used by the acoustic probe.
    func endPersistentPocketPlayback() {
        persistentPlaybackBacking?.stop()
        if persistentPlaybackUsesPocketSource {
            pocketSourceBacking.endSession()
        }
        persistentPlaybackBacking = nil
        persistentPlaybackUsesPocketSource = false
        persistentPlaybackFailure = nil
    }

    func restoreSystemBacking() {
        voiceResumePending = false
        voiceResumeBinding = nil
        if testingBacking { backing.stop() }
        testingBacking = false
        self.backing = persistentPlaybackBacking ?? unavailableBacking
        replyCanSpeak = false
        outputAvailability = nil
        selectedVoiceFailed = false
        setOutputGain(1)
        utteranceVolume = 1.0
        pendingClauses.removeAll()
        onFirstAudio = nil
        onFirstAudioCancelled = nil
        onPlaybackEvent = nil
        currentClause = nil
        currentClauseRendered = false
        replyTokens.removeAll()
        replyOpen = false
        replyFinished = false
    }

    private func didResumeAudio(_ receipt: PCMResumePlaybackReceipt) {
        guard let receiptBacking = backing as? any AgentReceiptSpeechBacking,
              currentClause != nil, !didStop, !isPausedForListening,
              voiceResumePending, receipt.packet.buffer.token == currentPlaybackToken,
              let binding = voiceResumeBinding,
              binding.token == receipt.packet.buffer.token,
              binding.phase == receipt.packet.originPhase,
              receiptBacking.currentResumePhase == binding.phase else { return }
        voiceResumePending = false
        onPlaybackEvent?(.resumeAcknowledged(receipt))
        onVoiceLifecycleSettled?()
    }

    private func didBeginAudio(token: UInt64) {
        guard token == currentPlaybackToken, currentClause != nil else { return }
        if let currentClause, !currentClauseRendered {
            currentClauseRendered = true
            onPlaybackEvent?(.startAcknowledged(currentClause))
            // Backend-agnostic, and the last mark of a voice turn: the output backend has
            // acknowledged its first sample. It is not proof that anybody heard it, and it
            // closes the turn rather than the P2-05 ducking measure.
            VoiceLatencyTimeline.shared.mark(.firstAudible)
        }
        let callback = onFirstAudio
        onFirstAudio = nil
        callback?()
    }

    private func didFinishAudio(token: UInt64) {
        guard token == currentPlaybackToken, currentClause != nil else { return }
        if let currentClause { onPlaybackEvent?(.completed(currentClause)) }
        if replyOpen, replyTokens.first == token { replyTokens.removeFirst() }
        currentClause = nil
        currentClauseRendered = false
        advanceQueue()
        onVoiceLifecycleSettled?()
    }

    /// Self-test seam for a fake backing. The token is explicit so the probe
    /// can prove an old delegate callback cannot close a new span.
    func notifyTestingFirstAudio(token: UInt64) {
        didBeginAudio(token: token)
    }

    func notifyTestingAudioFinished(token: UInt64) {
        didFinishAudio(token: token)
    }

    /// Next clause after the current utterance finishes. No-op after `stop()`
    /// or when the queue is empty (then duplex phase returns to listening).
    func advanceQueue() {
        guard !didStop else { return }
        guard !isPausedForListening || replyOpen else { return }
        guard !pendingClauses.isEmpty else {
            guard !isPausedForListening else { return }
            if replyOpen {
                guard replyFinished else { return }
                replyOpen = false
                replyTokens.removeAll()
            }
            RealtimeAudioSession.shared.noteOutputFinished()
            return
        }
        let next = pendingClauses.removeFirst()
        currentClause = next
        currentClauseRendered = false
        if replyOpen, let token = replyTokens.first {
            currentPlaybackToken = token // Already submitted: never restart synthesis.
            return
        }
        startClause(next)
    }

    private func startClause(_ clause: String) {
        playbackTokenCounter &+= 1
        currentPlaybackToken = playbackTokenCounter
        let detail = String(format: "Voice clause start %.3f token=%llu backing=%@ characters=%d",
                            Date().timeIntervalSince1970, currentPlaybackToken,
                            String(describing: type(of: self.backing)), clause.count)
        Log.agent.info("\(detail, privacy: .public)")
        if CommandLine.arguments.contains("--selftest-voice-pipeline") { SelfTest.diagnostic(detail) }
        MainActorSection.run("tts.clause") {
            backing.speak(clause, volume: utteranceVolume, token: currentPlaybackToken)
            backing.setOutputGain(listeningOutputGain)
        }
    }

    private func fallbackCurrentClause(text: String, token: UInt64) {
        guard token == currentPlaybackToken, !didStop,
              let currentClause, !currentClause.isEmpty,
              currentClause == text || (replyOpen && text.isEmpty) else { return }
        selectedVoiceFailed = true
        outputAvailability = .failed
        replyCanSpeak = false
        // Stop the existing producer. Completed clauses stay acknowledged; the
        // partial head and every remaining clause settle interrupted/unheard.
        stop(advanceGeneration: false)
        RealtimeAudioSession.shared.noteOutputFinished()
    }

    private func interruptCurrentClause() {
        if let currentClause {
            onPlaybackEvent?(.interrupted(currentClause, wasRendered: currentClauseRendered))
        }
        currentClause = nil
        currentClauseRendered = false
        for clause in pendingClauses {
            onPlaybackEvent?(.interrupted(clause, wasRendered: false))
        }
    }

    /// Fail unless `stop()` ran and cleared remaining clauses. Uses a recording
    /// backend — no speaker required. Also drives `RealtimeAgent.interrupt()` so
    /// the barge-in hook is under test.
    static func runInterruptSelfTest() -> [String] {
        let recorder = RecordingSpeechBacking()
        let previous = AgentSpeechSynthesizer.shared
        previous.useTestingBacking(recorder)
        previous.didStop = false
        defer { previous.restoreSystemBacking() }

        previous.speak("I found three files.")
        if recorder.spoken != ["I found three files."] {
            return ["interrupt: speak did not enqueue the short answer"]
        }

        RealtimeAgent.shared.interrupt()
        if !previous.didStop || recorder.stopCount == 0 {
            return ["interrupt: stop was not called"]
        }
        return []
    }

    static func runSuspendSelfTest() -> [String] {
        let synth = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking() }
        synth.speak("First sentence. The second sentence follows it.")
        let token = synth.currentPlaybackToken
        let pending = synth.pendingClauseCount
        synth.pauseForListening()
        synth.pauseForListening()
        guard synth.isPausedForListening, recorder.paused,
              recorder.pauseCount == 1, recorder.stopCount == 0,
              synth.currentPlaybackToken == token, synth.pendingClauseCount == pending else {
            return ["suspend: pause lost playback token, queue, or idempotence"]
        }
        synth.resumeAfterListening()
        synth.resumeAfterListening()
        guard !synth.isPausedForListening, !recorder.paused,
              recorder.resumeCount == 1, recorder.stopCount == 0,
              synth.currentPlaybackToken == token else {
            return ["suspend: resume changed playback or repeated"]
        }
        synth.pauseForListening()
        synth.stop()
        guard synth.didStop, !synth.isPausedForListening, !recorder.paused,
              synth.pendingClauseCount == 0, recorder.stopCount == 1 else {
            return ["suspend: hard stop did not clear held audio and clauses"]
        }

        recorder.reset()
        synth.prepareForStream()
        synth.enqueueClause("First sentence.")
        synth.enqueueClause("Second sentence.")
        let firstToken = synth.currentPlaybackToken
        synth.pauseForListening()
        synth.notifyTestingAudioFinished(token: firstToken)
        guard synth.isPausedForListening, synth.pendingClauseCount == 1,
              recorder.spoken == ["First sentence."] else {
            return ["suspend: late completion started the next clause during pause"]
        }
        synth.resumeAfterListening()
        guard !synth.isPausedForListening, synth.pendingClauseCount == 0,
              synth.currentPlaybackToken != firstToken,
              recorder.spoken == ["First sentence.", "Second sentence."] else {
            return ["suspend: held next clause did not start after resume"]
        }
        let suspend = "--selftest-voice-suspend-live", barge = "--selftest-voice-barge"
        let modifier = "--voice-test-pocket"
        let scoped = [
            pocketProbeRequested(requested: suspend, arguments: [suspend, modifier]),
            pocketProbeRequested(requested: barge, arguments: [barge, "fixture.wav", modifier, SelfTest.timeoutFlag, "120"]),
            !pocketProbeRequested(requested: suspend, arguments: [suspend]),
            !pocketProbeRequested(requested: suspend, arguments: [suspend, barge, modifier]),
            !pocketProbeRequested(requested: "--selftest-tts-pocket", arguments: ["--selftest-tts-pocket", modifier]),
            !pocketProbeRequested(requested: nil, arguments: [modifier])]
        guard scoped.allSatisfy({ $0 }) else { return ["suspend: Pocket probe escaped its exact diagnostic flags"] }
        return runFallbackSelfTest() + runPocketReadinessSelfTest()
            + SettingsVoicePolicySelfTest.run() + AgentVoicePolicySelfTest.run()
    }

    private static func runPocketReadinessSelfTest() -> [String] {
        guard SelfTest.isRunning else { return ["voice readiness: diagnostic admission missing"] }
        let synth = shared
        let savedEngine = synth.engineOverrideForTesting
        let savedReadiness = synth.pocketReadinessForTesting
        let savedKokoro = synth.kokoroReadinessForTesting
        let savedPreference = Settings.shared.agentVoiceEngine
        var failures = AgentVoiceAvailability.runSelfTest()
        var events: [PlaybackEvent] = []
        defer {
            synth.stop(); synth.restoreSystemBacking()
            synth.engineOverrideForTesting = savedEngine
            synth.pocketReadinessForTesting = savedReadiness
            synth.kokoroReadinessForTesting = savedKokoro
        }
        synth.restoreSystemBacking()
        synth.onPlaybackEvent = { events.append($0) }
        synth.engineOverrideForTesting = "pocket"
        synth.pocketReadinessForTesting = false
        synth.speak("Written answer. Still written.")
        if synth.backing !== synth.unavailableBacking || synth.isSpeaking
            || synth.currentPlaybackToken != 0 || synth.pendingClauseCount != 0
            || synth.outputAvailability == nil {
            failures.append("voice readiness: unavailable Pocket entered playback")
        }
        if synth.unavailableBacking.attemptedSpeechCount != 0 {
            failures.append("voice readiness: unavailable route invoked a speech backing")
        }
        if events.contains(where: { if case .startAcknowledged = $0 { return true }; if case .completed = $0 { return true }; return false })
            || !events.contains(.interrupted("Written answer.", wasRendered: false)) {
            failures.append("voice readiness: written answer claimed playback or lost unheard receipt")
        }
        synth.pocketReadinessForTesting = true
        synth.enqueueClause("Do not replay an old answer.")
        if synth.backing !== synth.unavailableBacking || synth.isSpeaking {
            failures.append("voice readiness: preparation replayed the stale answer")
        }
        synth.prepareForStream()
        if synth.backing !== synth.pocketBacking { failures.append("voice readiness: next ready reply did not select Pocket") }
        synth.stop()
        synth.selectedVoiceFailed = true
        synth.speak("A failed voice remains written on the next reply.")
        if synth.backing !== synth.unavailableBacking || synth.isSpeaking || synth.outputAvailability != .failed {
            failures.append("voice readiness: a new reply bypassed the failed selected voice")
        }
        synth.selectedVoiceFailed = false
        synth.engineOverrideForTesting = "kokoro"
        synth.kokoroReadinessForTesting = false
        synth.speak("Kokoro is not ready.")
        if synth.backing !== synth.unavailableBacking || synth.isSpeaking { failures.append("voice readiness: unready Kokoro spoke") }
        synth.engineOverrideForTesting = "apple"
        synth.speak("Legacy selection stays written.")
        if synth.backing !== synth.unavailableBacking || synth.isSpeaking { failures.append("voice readiness: legacy selection spoke") }
        if Settings.shared.agentVoiceEngine != savedPreference { failures.append("voice readiness: playback changed saved choice") }
        SelfTest.diagnostic("VOICE_POLICY_ROUTE_COUNTS unavailable_backing_calls=\(synth.unavailableBacking.attemptedSpeechCount) ready_route_selected=true stale_answer_replayed=false")
        return failures
    }

    private static func runFallbackSelfTest() -> [String] {
        let synth = shared
        let failedBackend = RecordingSpeechBacking()
        let savedPreference = Settings.shared.agentVoiceEngine
        synth.useTestingBacking(failedBackend)
        var events: [PlaybackEvent] = []
        synth.onPlaybackEvent = { events.append($0) }
        defer { synth.restoreSystemBacking() }
        synth.speak("The first sentence. The untouched sentence.")
        let failedToken = synth.currentPlaybackToken
        synth.notifyTestingFirstAudio(token: failedToken)
        synth.pauseForListening()
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken)
        let settled = events
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken)
        synth.notifyTestingAudioFinished(token: failedToken)
        synth.resumeAfterListening()
        guard synth.didStop, !synth.isSpeaking, synth.pendingClauseCount == 0,
              failedBackend.spoken == ["The first sentence."], events == settled,
              events.contains(.interrupted("The first sentence.", wasRendered: true)),
              events.contains(.interrupted("The untouched sentence.", wasRendered: false)),
              !events.contains(.completed("The first sentence.")),
              synth.outputAvailability == .failed,
              Settings.shared.agentVoiceEngine == savedPreference else {
            return ["voice failure: did not settle exact partial/unheard reply without switching voice"]
        }
        return []
    }

    /// Signed-app selected-voice gate. Silent mixer gain still runs real PCM,
    /// dataPlayedBack receipts, and clause drain without disturbing the room.
    static func runLiveSuspendSelfTest() async -> (Bool, String) {
        let synth = AgentSpeechSynthesizer.shared
        let pocketProbe = pocketProbeRequested(requested: SelfTest.requested, arguments: CommandLine.arguments)
        if CommandLine.arguments.contains("--voice-test-pocket") && !pocketProbe {
            return (false, "VOICE_SUSPEND_FAILED: Pocket modifier requires this diagnostic alone")
        }
        let oldVolume = synth.utteranceVolume
        let oldEngine = synth.engineOverrideForTesting
        let priorEvent = synth.onPlaybackEvent
        defer {
            synth.stop()
            synth.onPlaybackEvent = priorEvent
            synth.utteranceVolume = oldVolume
            synth.engineOverrideForTesting = oldEngine
        }
        if pocketProbe {
            synth.engineOverrideForTesting = "pocket"
            await PocketAgentVoice.shared.prepare()
            guard PocketAgentVoice.shared.isReady else { return (false, "VOICE_SUSPEND_FAILED: Pocket is unavailable") }
        }
        var started: [String] = [], completed: [String] = []
        var startedTokens: [UInt64] = []
        synth.utteranceVolume = 0
        synth.onPlaybackEvent = { event in
            if case .startAcknowledged(let text) = event { started.append(text); startedTokens.append(synth.currentPlaybackToken) }
            if case .completed(let text) = event { completed.append(text) }
        }
        let first = "The first sentence has enough duration to pause after audio begins and "
            + "should resume from the same place without cancelling the reply."
        let late = "A queued clause must follow the same paused reply."
        synth.prepareForStream()
        synth.enqueueClause(first)
        for _ in 0..<150 where started.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        guard started == [first] else { return (false, "VOICE_SUSPEND_FAILED: first PCM never played") }
        SelfTest.diagnostic("VOICE_SUSPEND_ROUTE requested=\(pocketProbe ? "pocket" : "selected") actual=\(String(describing: type(of: synth.backing))) muted=true")
        guard !pocketProbe || synth.isPocketProbePlayback else {
            return (false, "VOICE_SUSPEND_FAILED: explicit Pocket diagnostic used another backing")
        }
        let heldToken = synth.currentPlaybackToken
        synth.pauseForListening()
        synth.enqueueClause(late)
        synth.finishStream()
        let completedAtPause = completed
        try? await Task.sleep(for: .milliseconds(350))
        guard synth.isPausedForListening, completed == completedAtPause,
              synth.currentPlaybackToken == heldToken, synth.pendingClauseCount == 1 else {
            return (false, "VOICE_SUSPEND_FAILED: paused player drained or lost token/late clause")
        }
        synth.resumeAfterListening()
        for _ in 0..<800 where completed.count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
        guard !synth.isPausedForListening, completed == [first, late], started == [first, late],
              startedTokens.count == 2, startedTokens.first == heldToken,
              Set(startedTokens).count == 2, synth.pendingClauseCount == 0,
              !pocketProbe || (synth.isPocketProbePlayback && !synth.pocketBacking.isPlaybackEngineRunning) else {
            return (false, "VOICE_SUSPEND_FAILED: same reply did not resume/drain exact ordered clauses")
        }
        let fresh = "A second clause should start after the first engine was drained."
        synth.speak(fresh)
        for _ in 0..<400 where completed.count < 3 { try? await Task.sleep(for: .milliseconds(20)) }
        guard completed == [first, late, fresh], started == [first, late, fresh],
              !pocketProbe || (synth.isPocketProbePlayback && !synth.pocketBacking.isPlaybackEngineRunning) else {
            return (false, "VOICE_SUSPEND_FAILED: next reply did not restart and drain")
        }
        return (true, "VOICE_SUSPEND_OK: native software callbacks retained paused token; late clause and next reply drained exactly")
    }

    /// Multi-clause enqueue + barge-in clears the remainder. Recording backing
    /// only — no speaker. Failures are collected by `runSelfTest` / stream helper.
    static func runStreamSelfTest() -> [String] {
        var failures: [String] = []
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        synth.didStop = false
        defer { synth.restoreSystemBacking() }

        let reply = "I found three files. The latest is enclosure version seventeen."
        synth.speak(reply)

        if recorder.spoken != ["I found three files."] {
            failures.append(
                "stream: expected first clause only, got \(recorder.spoken)"
            )
        }
        if synth.pendingClauseCount != 1 {
            failures.append(
                "stream: expected 1 pending clause, got \(synth.pendingClauseCount)"
            )
        }

        // Advance once so the second clause is “speaking” and the queue is empty
        // of pending — then speak a fresh three-clause reply and interrupt mid-way.
        synth.advanceQueue()
        if recorder.spoken.count != 2 {
            failures.append(
                "stream: advance should speak second clause, got \(recorder.spoken)"
            )
        }
        if synth.pendingClauseCount != 0 {
            failures.append("stream: queue should be empty after last advance")
        }

        recorder.reset()
        synth.didStop = false
        let longer = "That's done. I created the event. It's on your calendar."
        synth.speak(longer)
        if recorder.spoken.count != 1 {
            failures.append(
                "stream: longer reply should start with one spoken clause, got \(recorder.spoken)"
            )
        }
        if synth.pendingClauseCount < 1 {
            failures.append(
                "stream: longer reply should leave pending clauses, got \(synth.pendingClauseCount)"
            )
        }
        let pendingBefore = synth.pendingClauseCount

        RealtimeAgent.shared.interrupt()
        if !synth.didStop || recorder.stopCount == 0 {
            failures.append("stream: interrupt did not stop synthesizer")
        }
        if synth.pendingClauseCount != 0 {
            failures.append(
                "stream: interrupt left \(synth.pendingClauseCount) pending (was \(pendingBefore))"
            )
        }
        // Only the clause that had started should appear — never the cleared rest.
        if recorder.spoken.count != 1 {
            failures.append(
                "stream: interrupt must not speak remaining clauses, got \(recorder.spoken)"
            )
        }

        return failures
    }

    /// Deterministic acknowledgement contract. The fake never drives a
    /// speaker; a render event must therefore require an explicit callback.
    static func runPlaybackLedgerSelfTest() -> [String] {
        let synth = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        synth.useTestingBacking(recorder)
        var events: [PlaybackEvent] = []
        synth.onPlaybackEvent = { events.append($0) }
        defer { synth.restoreSystemBacking() }

        synth.speak("First clause. Second clause.")
        let firstToken = synth.currentPlaybackToken
        guard events.contains(.began(synth.outputGeneration)),
              events.contains(.enqueued("First clause.")),
              !events.contains(.startAcknowledged("First clause.")) else {
            return ["playback ledger: enqueue claimed rendering"]
        }
        synth.notifyTestingFirstAudio(token: firstToken)
        synth.stop()
        guard events.contains(.startAcknowledged("First clause.")),
              events.contains(.interrupted("First clause.", wasRendered: true)),
              events.contains(.interrupted("Second clause.", wasRendered: false)),
              !events.contains(.completed("First clause.")) else {
            return ["playback ledger: interruption lost rendered versus queued state"]
        }
        events.removeAll()
        synth.speak("Replacement reply.")
        synth.notifyTestingFirstAudio(token: firstToken)
        guard !events.contains(.startAcknowledged("Replacement reply.")) else {
            return ["playback ledger: stale render started replacement"]
        }
        let replacementToken = synth.currentPlaybackToken
        synth.notifyTestingFirstAudio(token: replacementToken)
        synth.notifyTestingAudioFinished(token: replacementToken)
        guard events.contains(.startAcknowledged("Replacement reply.")),
              events.contains(.completed("Replacement reply.")) else {
            return ["playback ledger: completed playback lacks acknowledgements"]
        }
        events.removeAll()
        synth.speak("One clause. Two clauses.")
        let firstClauseToken = synth.currentPlaybackToken
        synth.notifyTestingAudioFinished(token: firstClauseToken)
        let secondClauseToken = synth.currentPlaybackToken
        guard firstClauseToken != secondClauseToken else {
            return ["playback ledger: clauses reused a callback identity"]
        }
        synth.notifyTestingAudioFinished(token: firstClauseToken)
        guard !events.contains(.completed("Two clauses.")) else {
            return ["playback ledger: duplicate old completion consumed next clause"]
        }
        synth.notifyTestingAudioFinished(token: secondClauseToken)
        guard events.contains(.completed("Two clauses.")) else {
            return ["playback ledger: current clause did not complete"]
        }
        return []
    }
}

// MARK: - Backends

@MainActor
final class RecordingSpeechBacking: AgentSpeechBacking {
    private(set) var spoken: [String] = []
    private(set) var volumes: [Float] = []
    private(set) var outputGain: Float = 1
    func setOutputGain(_ gain: Float) { outputGain = max(0, min(1, gain)) }
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private var speaking = false
    private(set) var paused = false

    var isSpeaking: Bool { speaking }

    func speak(_ text: String, volume: Float, token: UInt64) {
        spoken.append(text)
        volumes.append(volume)
        speaking = true
        paused = false
    }

    func pauseForListening() {
        guard speaking, !paused else { return }
        paused = true
        pauseCount += 1
    }

    func resumeAfterListening() {
        guard speaking, paused else { return }
        paused = false
        resumeCount += 1
    }

    /// A backing has stopped speaking before it reports natural completion.
    /// Keep that fixture fact distinct from a user stop and its stop counter.
    func finishNaturallyForTesting() {
        speaking = false
        paused = false
    }

    func stop() {
        stopCount += 1
        speaking = false
        paused = false
    }

    func reset() {
        spoken = []
        volumes = []
        stopCount = 0
        pauseCount = 0
        resumeCount = 0
        speaking = false
        paused = false
    }
}

/// Initial/unavailable state owns no audio engine and must never be asked to speak.
@MainActor
final class UnavailableSpeechBacking: AgentSpeechBacking {
    private(set) var attemptedSpeechCount = 0
    var isSpeaking: Bool { false }
    func speak(_ text: String, volume: Float, token: UInt64) { attemptedSpeechCount += 1 }
    func pauseForListening() {}
    func resumeAfterListening() {}
    func stop() {}
}
