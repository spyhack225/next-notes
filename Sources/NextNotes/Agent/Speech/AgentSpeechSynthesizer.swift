import AVFoundation
import Foundation
import Synchronization

/// Diagnostic-only actual Apple player observations; never playback/UI authority.
struct ApplePlaybackBufferObservation: Sendable, Equatable {
    let token: UInt64
    let ordinal: Int
    let lowerFrame: Int64
    let upperFrame: Int64
    let sampleRate: Double
}
struct ApplePlaybackNativeObservation: Sendable, Equatable {
    let buffer: ApplePlaybackBufferObservation
    let originPhase: UInt64
    let callbackKind: Int
    let originHostTime: UInt64
    let originWasMainThread: Bool
}
struct ApplePlaybackCursorObservation: Sendable, Equatable {
    let frame: Int64
    let sampleRate: Double
    let nodeHostTime: UInt64
    let observedHostTime: UInt64
}
enum ApplePlaybackTimelineObservation: Sendable, Equatable {
    case scheduled(ApplePlaybackBufferObservation)
    case paused(token: UInt64, phase: UInt64)
    case resumed(token: UInt64, phase: UInt64, requestedHostTime: UInt64,
                 cursor: ApplePlaybackCursorObservation?, checkpoint: Int64?)
    case handled(ApplePlaybackNativeObservation, currentPhase: UInt64,
                 cursor: ApplePlaybackCursorObservation?, checkpointBefore: Int64?,
                 checkpointAfter: Int64?, currentOwner: Bool, candidate: Bool)
    case stopped(token: UInt64?, phaseBefore: UInt64)
}

struct AppleResumePlaybackReceipt: Sendable, Equatable {
    let packet: ApplePlaybackNativeObservation
    let earlier: ApplePlaybackCursorObservation
    let later: ApplePlaybackCursorObservation
    let checkpoint: Int64
    let checkpointBuffer: ApplePlaybackBufferObservation
}

struct RawApplePlayedNotice: Sendable, Equatable {
    let buffer: ApplePlaybackBufferObservation
    let callbackKind: Int
    let nativeEntryHostTime: UInt64
}

/// Playback backend. Production talks to `AVSpeechSynthesizer`; the self-test
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

/// `AVSpeechSynthesizer` baseline. Speaks `AgentSpeechPolicy.spokenClauses`
/// one utterance at a time, never waits for the queue to drain, and is always
/// interruptible — `stop()` cancels the current clause and clears the rest.
///
/// Dictation never calls this. The optional Pocket and Kokoro backings only
/// play audio; neither backing attaches to the input node.
@MainActor
final class AgentSpeechSynthesizer {
    enum PlaybackEvent: Equatable {
        case began(UInt64)
        case enqueued(String)
        case startAcknowledged(String)
        case resumeRequested(token: UInt64, phase: UInt64)
        case resumeAcknowledged(AppleResumePlaybackReceipt)
        case completed(String)
        case interrupted(String, wasRendered: Bool)
    }
    static let shared = AgentSpeechSynthesizer()

    private var backing: any AgentSpeechBacking
    private let systemBacking = AVSpeechBacking()
    /// Exact existing Apple backing only; nil/default, SelfTest-only diagnostic.
    var appleTimelineObserverForTesting: (@MainActor (ApplePlaybackTimelineObservation) -> Void)? {
        get { systemBacking.timelineObserverForTesting }
        set { if SelfTest.isRunning { systemBacking.timelineObserverForTesting = newValue } }
    }
    var appleNativeCompletionInterceptorForTesting:
        (@Sendable (ApplePlaybackNativeObservation, @escaping @Sendable () -> Void) -> Void)? {
        get { systemBacking.nativeCompletionInterceptorForTesting }
        set { if SelfTest.isRunning { systemBacking.nativeCompletionInterceptorForTesting = newValue } }
    }
    var appleRawCompletionDeferralForTesting:
        (@Sendable (RawApplePlayedNotice, @escaping @Sendable () -> Void) -> Void)? {
        get { systemBacking.rawCompletionDeferralForTesting }
        set { if SelfTest.isRunning { systemBacking.rawCompletionDeferralForTesting = newValue } }
    }
    var appleResumeProofObserverForTesting: (@MainActor (AppleResumePlaybackReceipt) -> Void)? {
        get { systemBacking.resumeProofObserverForTesting }
        set { if SelfTest.isRunning { systemBacking.resumeProofObserverForTesting = newValue } }
    }
    private let pocketBacking = PocketSpeechBacking()
    private let pocketSourceBacking = PocketSourceSpeechBacking()
    private let kokoroBacking = KokoroSpeechBacking()
    private let qwenBacking = PocketSourceSpeechBacking(synthesis: { text, consume in
        try await NativeAgentVoice.qwen.synthesize(text, consume: consume)
    })
    private let phononBacking = PocketSourceSpeechBacking(synthesis: { text, consume in
        try await NativeAgentVoice.phonon.synthesize(text, consume: consume)
    })
    private var testingBacking = false
    /// A probe may keep one source graph alive for several clauses. This is
    /// selected only by the explicit self-test lifecycle below.
    private var persistentPlaybackBacking: (any AgentSpeechBacking)?
    private var persistentPlaybackUsesPocketSource = false
    private(set) var persistentPlaybackFailure: String?
    /// A failed optional voice falls back only for the current reply. The
    /// saved user preference is kept for the next request.
    private var usingSystemFallbackForReply = false
    private var deferredFallbackClause = false
    private var fallbackBackingForTesting: (any AgentSpeechBacking)?
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
    /// Current output needs fresh playback proof after its accepted pause.
    /// Historical clauseRendered remains intact; no physical playback gate.
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
    private var pocketIsReady: Bool {
        if SelfTest.isRunning, let pocketReadinessForTesting { return pocketReadinessForTesting }
        return PocketAgentVoice.shared.isReady
    }
    /// Called on the backing's first output acknowledgement. Pocket reports
    /// the first completed player buffer; Apple reports its delegate start;
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
        let resumeBinding: ResumeBinding?
    }
    var voiceLifecycleSnapshot: VoiceLifecycleSnapshot {
        .init(generation: outputGeneration, hasClause: currentClause != nil,
              rendered: currentClauseRendered, paused: isPausedForListening,
              resumePending: voiceResumePending, resumeBinding: voiceResumeBinding)
    }
    /// Observes only after clearing/advancing a clause; never controls playback.
    var onVoiceLifecycleSettled: (() -> Void)?
    private var playbackTokenCounter: UInt64 = 0
    private(set) var currentPlaybackToken: UInt64 = 0

    /// Clauses waiting after the current utterance. Zero when idle or after stop.
    var pendingClauseCount: Int { pendingClauses.count }

    init(backing: (any AgentSpeechBacking)? = nil) {
        self.backing = backing ?? systemBacking
        systemBacking.onResumePlaybackAcknowledged = { [weak self] receipt in
            self?.didResumeAudio(receipt)
        }
        systemBacking.onUtteranceFinished = { [weak self] token in
            self?.didFinishAudio(token: token)
        }
        systemBacking.onUtteranceStarted = { [weak self] token in
            self?.didBeginAudio(token: token)
        }
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
            // A source backing is used as an experimental probe. Falling back
            // to Apple here would turn a failed source run into a false pass.
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
        for optional in [qwenBacking, phononBacking] {
            optional.onUtteranceStarted = { [weak self] token in self?.didBeginAudio(token: token) }
            optional.onUtteranceFinished = { [weak self] token in self?.didFinishAudio(token: token) }
            optional.onFailure = { [weak self] text, _, token in
                self?.fallbackCurrentClause(text: text, token: token)
            }
        }
        if !SelfTest.isRunning {
            switch Settings.shared.agentVoiceEngine {
            case "qwen": Task { await NativeAgentVoice.qwen.prepare() }
            case "phonon": Task { await NativeAgentVoice.phonon.prepare() }
            default: break
            }
        }
        // Scripted speech tests install their backing after construction. Real audio
        // probes explicitly prepare their engine; startup must not load models here.
        if !SelfTest.isRunning, Settings.shared.agentVoiceEngine == "pocket" {
            Task { await PocketAgentVoice.shared.prepare() }
        } else if !SelfTest.isRunning, Settings.shared.agentVoiceEngine == "kokoro" {
            if KokoroAgentVoice.isSupportedOS {
                Task { await KokoroAgentVoice.shared.prepare() }
            }
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
        usingSystemFallbackForReply = false
        deferredFallbackClause = false
        isPausedForListening = false
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
            // Release a previously selected source graph before another output
            // owns the speaker/reference. Keep it alive across the same engine's clauses.
            if Self.selectedEngine != "qwen" || !NativeAgentVoice.qwen.isReady { qwenBacking.endSession() }
            if Self.selectedEngine != "phonon" || !NativeAgentVoice.phonon.isReady { phononBacking.endSession() }
            if let persistentPlaybackBacking {
                backing = persistentPlaybackBacking
                Log.agent.info(
                    "voice playback route selected=persistent \(self.persistentPlaybackUsesPocketSource ? "pocket-source" : "fixed-wav")"
                )
            } else {
                switch Self.selectedEngine {
                case "pocket" where pocketIsReady:
                    backing = pocketBacking
                case "qwen" where NativeAgentVoice.qwen.isReady:
                    backing = qwenBacking
                case "phonon" where NativeAgentVoice.phonon.isReady:
                    backing = phononBacking
                case "kokoro" where KokoroAgentVoice.isSupportedOS:
                    backing = kokoroBacking
                default:
                    backing = systemBacking
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
        guard !didStop, replyOpen, !replyFinished,
              let reply = backing as? any AgentReplySpeechBacking else { return }
        replyFinished = true
        reply.finishReply()
        if currentClause == nil && pendingClauses.isEmpty { advanceQueue() }
    }

    /// Barge-in / VAD / Stop. Immediate, not word-boundary. Clears every
    /// pending clause so mid-reply cut-off does not keep speaking the rest.
    /// Target <100 ms.
    func stop() {
        setOutputGain(1)
        voiceResumePending = false
        voiceResumeBinding = nil
        isPausedForListening = false
        deferredFallbackClause = false
        interruptCurrentClause()
        replyTokens.removeAll()
        replyOpen = false
        replyFinished = false
        outputGeneration &+= 1
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
        if (backing as AnyObject) === systemBacking,
           let phase = systemBacking.currentResumePhase {
            voiceResumeBinding = .init(token: currentPlaybackToken, phase: phase)
            onPlaybackEvent?(.resumeRequested(token: currentPlaybackToken, phase: phase))
        }
        if deferredFallbackClause, let currentClause {
            deferredFallbackClause = false
            startClause(currentClause)
            return
        }
        // A late completion can arrive while the player is paused. In that
        // case advanceQueue held the next clause; start it only now.
        if currentClause == nil { advanceQueue() }
    }

    /// Self-test only. Restored by interrupt / stream self-tests so a later
    /// turn still uses the system voice.
    func useTestingBacking(_ backing: any AgentSpeechBacking, fallback: (any AgentSpeechBacking)? = nil) {
        self.backing.stop()
        fallbackBackingForTesting = fallback
        testingBacking = true
        self.backing = backing
        if let reply = backing as? any AgentReplySpeechBacking {
            reply.onUtteranceStarted = { [weak self] token in self?.didBeginAudio(token: token) }
            reply.onUtteranceFinished = { [weak self] token in self?.didFinishAudio(token: token) }
            reply.onFailure = { [weak self] text, volume, token in
                self?.fallbackCurrentClause(text: text, token: token)
            }
        }
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
        qwenBacking.endSession()
        phononBacking.endSession()
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
        usingSystemFallbackForReply = false
        deferredFallbackClause = false
        fallbackBackingForTesting = nil
        testingBacking = false
        self.backing = persistentPlaybackBacking ?? systemBacking
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

    private func didResumeAudio(_ receipt: AppleResumePlaybackReceipt) {
        guard (backing as AnyObject) === systemBacking,
              currentClause != nil, !didStop, !isPausedForListening,
              voiceResumePending, receipt.packet.buffer.token == currentPlaybackToken,
              let binding = voiceResumeBinding,
              binding.token == receipt.packet.buffer.token,
              binding.phase == receipt.packet.originPhase,
              systemBacking.currentResumePhase == binding.phase else { return }
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
        guard token == currentPlaybackToken, !usingSystemFallbackForReply,
              let currentClause, !currentClause.isEmpty,
              currentClause == text || (replyOpen && text.isEmpty) else { return }
        usingSystemFallbackForReply = true
        if (backing as AnyObject) === qwenBacking { qwenBacking.endSession() }
        if (backing as AnyObject) === phononBacking { phononBacking.endSession() }
        let partialReply = replyOpen && currentClauseRendered
        replyTokens.removeAll()
        replyOpen = false
        replyFinished = false
        backing = fallbackBackingForTesting ?? systemBacking
        backing.setOutputGain(listeningOutputGain)
        if partialReply {
            // Completed clauses are gone. A partially rendered head is interrupted,
            // never repeated; only untouched pending clauses use the old fallback.
            onPlaybackEvent?(.interrupted(currentClause, wasRendered: true))
            self.currentClause = nil
            currentClauseRendered = false
            if !isPausedForListening { advanceQueue() }
            return
        }
        currentClauseRendered = false
        if isPausedForListening {
            deferredFallbackClause = true
            return
        }
        startClause(currentClause)
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
    }

    private static func runPocketReadinessSelfTest() -> [String] {
        guard SelfTest.isRunning else { return ["voice readiness: diagnostic admission missing"] }
        let synth = AgentSpeechSynthesizer.shared
        let savedEngine = synth.engineOverrideForTesting
        let savedReadiness = synth.pocketReadinessForTesting
        let savedPreference = Settings.shared.agentVoiceEngine
        var failures: [String] = []
        defer {
            synth.stop()
            synth.restoreSystemBacking()
            synth.engineOverrideForTesting = savedEngine
            synth.pocketReadinessForTesting = savedReadiness
        }
        synth.restoreSystemBacking()
        synth.engineOverrideForTesting = "pocket"
        synth.pocketReadinessForTesting = false
        synth.prepareForStream()
        if (synth.backing as AnyObject) !== synth.systemBacking {
            failures.append("voice readiness: preparing Pocket did not immediately select Apple")
        }
        synth.stop()
        if !synth.didStop || synth.currentClause != nil || synth.pendingClauseCount != 0 {
            failures.append("voice readiness: cancellation retained cold playback")
        }
        synth.pocketReadinessForTesting = true
        synth.prepareForStream()
        if (synth.backing as AnyObject) !== synth.pocketBacking {
            failures.append("voice readiness: next ready reply did not select chosen Pocket")
        }
        synth.stop()
        synth.pocketReadinessForTesting = false
        synth.prepareForStream()
        if (synth.backing as AnyObject) !== synth.systemBacking || synth.didStop {
            failures.append("voice readiness: replacement unavailable reply entered Pocket or stayed canceled")
        }
        synth.stop()
        if Settings.shared.agentVoiceEngine != savedPreference {
            failures.append("voice readiness: temporary playback changed saved preference")
        }
        return failures
    }

    private static func runFallbackSelfTest() -> [String] {
        let synth = AgentSpeechSynthesizer.shared
        let failedBackend = RecordingSpeechBacking()
        let safeBackend = RecordingSpeechBacking()
        let savedPreference = Settings.shared.agentVoiceEngine
        synth.useTestingBacking(failedBackend)
        synth.fallbackBackingForTesting = safeBackend
        defer { synth.restoreSystemBacking() }
        synth.speak("The first sentence.")
        let failedToken = synth.currentPlaybackToken
        synth.pauseForListening()
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken)
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken)
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken &- 1)
        guard synth.isPausedForListening, safeBackend.spoken.isEmpty,
              Settings.shared.agentVoiceEngine == savedPreference else {
            return ["voice fallback: paused, duplicate, or stale failure spoke or changed preference"]
        }
        synth.resumeAfterListening()
        guard safeBackend.spoken == ["The first sentence."],
              synth.currentPlaybackToken != failedToken else {
            return ["voice fallback: resume did not speak exactly once with a new token"]
        }
        synth.stop()
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken)
        guard safeBackend.spoken.count == 1,
              Settings.shared.agentVoiceEngine == savedPreference else {
            return ["voice fallback: stale callback replayed after stop or changed preference"]
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
final class AVSpeechBacking: NSObject, AgentSpeechBacking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var pendingBuffers = 0
    private var synthesisFinished = false
    private var didBegin = false
    private var delivery: PCMDelivery?
    private var speaking = false
    private var pausedForListening = false
    private var activeToken: UInt64?
    /// One atomic stamp crosses the real callback thread; no PCM queue is added.
    private final class TimelinePhase: @unchecked Sendable {
        let value = Atomic<UInt64>(0)
    }
    private let timelinePhase = TimelinePhase()
    private var timelineEnd: Int64 = 0
    private var timelineOrdinal = 0
    private var timelineRate: Double?
    private var timelineResumeHost: UInt64?
    private var timelineCheckpoint: Int64?
    private var resumeEarlierCursor: ApplePlaybackCursorObservation?
    private var resumeLaterCursor: ApplePlaybackCursorObservation?
    private var resumeStrongCut: Int64?
    private var resumeCheckpointBuffer: ApplePlaybackBufferObservation?
    private var resumeReceiptDelivered = false
    var onResumePlaybackAcknowledged: ((AppleResumePlaybackReceipt) -> Void)?
    var resumeProofObserverForTesting: (@MainActor (AppleResumePlaybackReceipt) -> Void)?
    var rawCompletionDeferralForTesting:
        (@Sendable (RawApplePlayedNotice, @escaping @Sendable () -> Void) -> Void)?
    private var timelineEnabled: Bool {
        onResumePlaybackAcknowledged != nil || (SelfTest.isRunning && timelineObserverForTesting != nil)
    }
    var currentResumePhase: UInt64? {
        let phase = timelinePhase.value.load(ordering: .acquiring)
        return speaking && !pausedForListening && phase != 0 && phase % 2 == 0
            && timelineResumeHost != nil ? phase : nil
    }
    private func clearResumeProof() {
        resumeEarlierCursor = nil; resumeLaterCursor = nil; resumeStrongCut = nil
        resumeCheckpointBuffer = nil; resumeReceiptDelivered = false
    }
    var timelineObserverForTesting: (@MainActor (ApplePlaybackTimelineObservation) -> Void)?
    var nativeCompletionInterceptorForTesting:
        (@Sendable (ApplePlaybackNativeObservation, @escaping @Sendable () -> Void) -> Void)?
    /// Wired by `AgentSpeechSynthesizer` to pump the next clause (or finish).
    var onUtteranceFinished: ((UInt64) -> Void)?
    /// Wired by `AgentSpeechSynthesizer` for truthful first-audio timing.
    var onUtteranceStarted: ((UInt64) -> Void)?
    private var tokens: [ObjectIdentifier: UInt64] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
        playbackEngine.attach(player)
        playbackEngine.connect(player, to: playbackEngine.mainMixerNode,
                               format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)
        VoicePlaybackReference.install(on: playbackEngine)
    }

    var isSpeaking: Bool { speaking }
    var outputGain: Float { player.volume }
    func setOutputGain(_ gain: Float) { player.volume = max(0, min(1, gain)) }

    func speak(_ text: String, volume: Float, token: UInt64) {
        // Do not clear the AVSpeech queue here — clause streaming feeds one
        // utterance at a time after `didFinish`. A replacing reply calls `stop()`
        // first from `AgentSpeechSynthesizer.speak`.
        speaking = true
        pausedForListening = false
        activeToken = token
        clearResumeProof()
        if timelineEnabled {
            timelinePhase.value.store(2, ordering: .releasing)
            timelineEnd = 0
            timelineOrdinal = 0
            timelineRate = nil
            timelineResumeHost = nil
            timelineCheckpoint = nil
        }
        pendingBuffers = 0
        synthesisFinished = false
        didBegin = false
        let delivery = PCMDelivery()
        self.delivery = delivery
        let utterance = AVSpeechUtterance(string: text)
        // Output gain lives at the mixer. The render tap observes the resulting
        // PCM with the same ducking applied to the physical speaker path.
        utterance.volume = 1
        playbackEngine.mainMixerNode.outputVolume = max(0, min(1, volume))
        if !Settings.shared.agentVoiceIdentifier.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: Settings.shared.agentVoiceIdentifier)
        }
        tokens[ObjectIdentifier(utterance)] = token
        synthesizer.write(utterance, toBufferCallback: Self.makeRenderCallback(
            for: self, delivery: delivery, token: token))
    }

    /// AVSpeechSynthesizer invokes its PCM callback on a private render queue.
    /// Form it outside MainActor isolation, just like the microphone tap, or
    /// Swift's actor assertion can terminate the live app on the first buffer.
    nonisolated private static func makeRenderCallback(
        for backing: AVSpeechBacking, delivery: PCMDelivery, token: UInt64
    ) -> @Sendable (AVAudioBuffer) -> Void {
        { [weak backing] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0,
                  let owned = AudioConversion.copy(pcm) else {
                delivery.enqueue(nil, for: backing, token: token)
                return
            }
            delivery.enqueue(owned, for: backing, token: token)
        }
    }

    /// One scheduled drain per synthesizer generation. Core Audio callback
    /// order is preserved across the MainActor hop: an EOF cannot close a
    /// clause while earlier PCM is still waiting in another Task.
    private final class PCMDelivery: @unchecked Sendable {
        private struct Item: @unchecked Sendable { let buffer: AVAudioPCMBuffer? }
        private let lock = NSLock()
        private var pending: [Item] = []
        private var draining = false

        func enqueue(_ buffer: AVAudioPCMBuffer?, for backing: AVSpeechBacking?, token: UInt64) {
            lock.lock()
            pending.append(Item(buffer: buffer))
            let schedule = !draining
            draining = true
            lock.unlock()
            if schedule {
                Task { @MainActor [weak backing] in
                    while let next = self.take() {
                        if let buffer = next.buffer { backing?.play(buffer, token: token) }
                        else { backing?.synthesisEnded(token: token) }
                    }
                }
            }
        }

        private func take() -> Item? {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else { draining = false; return nil }
            return pending.removeFirst()
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, token: UInt64) {
        guard activeToken == token else { return }
        do {
            if !playbackEngine.isRunning {
                playbackEngine.connect(player, to: playbackEngine.mainMixerNode,
                                       format: buffer.format)
                try playbackEngine.start()
            }
            pendingBuffers += 1
            if timelineEnabled {
                let lower = timelineEnd
                let addition = lower.addingReportingOverflow(Int64(buffer.frameLength))
                guard !addition.overflow, buffer.frameLength > 0,
                      buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
                      timelineRate == nil || timelineRate == buffer.format.sampleRate else {
                    throw NSError(domain: "ApplePlaybackTimelineDiagnostic", code: 1)
                }
                timelineRate = buffer.format.sampleRate
                timelineEnd = addition.partialValue
                timelineOrdinal += 1
                let observation = ApplePlaybackBufferObservation(token: token,
                    ordinal: timelineOrdinal, lowerFrame: lower, upperFrame: timelineEnd,
                    sampleRate: buffer.format.sampleRate)
                timelineObserverForTesting?(.scheduled(observation))
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
                    completionHandler: Self.makeTimelineCompletion(for: self,
                        buffer: observation, phase: timelinePhase,
                        interceptor: nativeCompletionInterceptorForTesting,
                        rawDeferral: SelfTest.isRunning ? rawCompletionDeferralForTesting : nil))
            } else {
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
                    [weak self] _ in
                    Task { @MainActor in self?.bufferPlayed(token: token) }
                }
            }
            if !pausedForListening && !player.isPlaying { player.play() }
        } catch {
            Log.agent.error("Apple TTS PCM playback failed: \(error.localizedDescription, privacy: .public)")
            stop()
            onUtteranceFinished?(token)
        }
    }

    /// Captures immutable provenance BEFORE either the hook or MainActor hop.
    nonisolated private static func makeTimelineCompletion(
        for backing: AVSpeechBacking, buffer: ApplePlaybackBufferObservation,
        phase: TimelinePhase,
        interceptor: (@Sendable (ApplePlaybackNativeObservation,
            @escaping @Sendable () -> Void) -> Void)?,
        rawDeferral: (@Sendable (RawApplePlayedNotice,
            @escaping @Sendable () -> Void) -> Void)?
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak backing] kind in
            let raw = RawApplePlayedNotice(buffer: buffer,
                callbackKind: Int(kind.rawValue), nativeEntryHostTime: mach_absolute_time())
            let observe: @Sendable () -> Void = { [weak backing] in
                let packet = ApplePlaybackNativeObservation(buffer: buffer,
                    originPhase: phase.value.load(ordering: .acquiring),
                    callbackKind: Int(kind.rawValue), originHostTime: mach_absolute_time(),
                    originWasMainThread: Thread.isMainThread)
                let forward: @Sendable () -> Void = { [weak backing] in
                    Task { @MainActor in backing?.receiveTimelineCompletion(packet) }
                }
                if let interceptor { interceptor(packet, forward) }
                else { forward() }
            }
            if let rawDeferral { rawDeferral(raw, observe) }
            else { observe() }
        }
    }

    private func timelineCursor() -> ApplePlaybackCursorObservation? {
        guard player.isPlaying, let node = player.lastRenderTime,
              node.isHostTimeValid, let position = player.playerTime(forNodeTime: node),
              position.isSampleTimeValid, position.sampleTime >= 0, position.sampleTime <= timelineEnd,
              let rate = timelineRate, rate == position.sampleRate,
              rate.isFinite, rate > 0 else { return nil }
        return .init(frame: position.sampleTime, sampleRate: rate,
            nodeHostTime: node.hostTime, observedHostTime: mach_absolute_time())
    }

    private func diagnosticCheckpoint(cursor: ApplePlaybackCursorObservation?,
        completedEnd: Int64?) -> Int64? {
        guard let host = timelineResumeHost, let cursor,
              cursor.nodeHostTime >= host else { return nil }
        // This is a POST-resume cursor, never a purported pre-pause cut.
        // First callback checkpoint excludes that entire completed buffer too.
        return max(cursor.frame, completedEnd ?? cursor.frame)
    }

    private func qualifiedResumeReceipt(_ packet: ApplePlaybackNativeObservation,
        cursor: ApplePlaybackCursorObservation?) -> AppleResumePlaybackReceipt? {
        let phase = timelinePhase.value.load(ordering: .acquiring)
        guard !resumeReceiptDelivered, let requestedHost = timelineResumeHost,
              activeToken == packet.buffer.token, speaking, !pausedForListening,
              phase != 0, phase % 2 == 0, packet.originPhase == phase,
              packet.callbackKind == Int(AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack.rawValue),
              packet.originHostTime >= requestedHost,
              packet.buffer.upperFrame > packet.buffer.lowerFrame,
              packet.buffer.sampleRate == timelineRate else { return nil }
        if let cut = resumeStrongCut, let earlier = resumeEarlierCursor,
           let later = resumeLaterCursor, let checkpointBuffer = resumeCheckpointBuffer {
            guard packet.buffer.upperFrame > cut,
                  packet.originHostTime >= later.observedHostTime else { return nil }
            resumeReceiptDelivered = true
            return .init(packet: packet, earlier: earlier, later: later, checkpoint: cut, checkpointBuffer: checkpointBuffer)
        }
        guard let cursor, cursor.sampleRate == packet.buffer.sampleRate,
              cursor.frame >= 0, cursor.frame <= timelineEnd,
              cursor.observedHostTime >= requestedHost,
              cursor.nodeHostTime >= requestedHost else { return nil }
        guard let earlier = resumeEarlierCursor else {
            resumeEarlierCursor = cursor
            return nil
        }
        // Future-dated node timestamps are NOT equated with wall-clock completion.
        // Require actual successive node/player observations to advance together.
        guard cursor.frame > earlier.frame,
              cursor.nodeHostTime > earlier.nodeHostTime,
              cursor.observedHostTime > earlier.observedHostTime,
              cursor.sampleRate == earlier.sampleRate else { return nil }
        resumeLaterCursor = cursor
        resumeStrongCut = max(cursor.frame, packet.buffer.upperFrame)
        resumeCheckpointBuffer = packet.buffer
        // The checkpoint-building packet itself never establishes fresh speaking.
        return nil
    }

    private func receiveTimelineCompletion(_ packet: ApplePlaybackNativeObservation) {
        let phase = timelinePhase.value.load(ordering: .acquiring)
        let current = activeToken == packet.buffer.token && speaking && !pausedForListening
            && phase != 0 && phase % 2 == 0 && packet.originPhase == phase
            && packet.callbackKind == Int(AVAudioPlayerNodeCompletionCallbackType.dataPlayedBack.rawValue)
            && (timelineResumeHost.map { packet.originHostTime >= $0 } ?? true)
        // Existing initial onset keeps its fast path: player query only for a
        // pending resume or an explicitly installed SelfTest observer.
        let cursor = timelineObserverForTesting != nil || (timelineResumeHost != nil && !resumeReceiptDelivered)
            ? timelineCursor() : nil
        let before = timelineCheckpoint
        if current, timelineResumeHost != nil, before == nil {
            timelineCheckpoint = diagnosticCheckpoint(cursor: cursor,
                completedEnd: packet.buffer.upperFrame)
        }
        // Observation candidate only; does not restore any status or publish UI.
        let candidate: Bool
        if let before {
            candidate = current && timelineResumeHost != nil
                && packet.buffer.upperFrame > before
                && packet.buffer.upperFrame > packet.buffer.lowerFrame
        } else { candidate = false }
        timelineObserverForTesting?(.handled(packet, currentPhase: phase,
            cursor: cursor, checkpointBefore: before, checkpointAfter: timelineCheckpoint,
            currentOwner: current, candidate: candidate))
        if let receipt = qualifiedResumeReceipt(packet, cursor: cursor) {
            if SelfTest.isRunning { resumeProofObserverForTesting?(receipt) }
            onResumePlaybackAcknowledged?(receipt)
        }
        // Never suppress the existing drain bookkeeping for an unusable packet.
        bufferPlayed(token: packet.buffer.token)
    }

    private func synthesisEnded(token: UInt64) {
        guard activeToken == token else { return }
        synthesisFinished = true
        finishIfDrained(token: token)
    }

    private func bufferPlayed(token: UInt64) {
        guard activeToken == token, pendingBuffers > 0 else { return }
        if !didBegin {
            didBegin = true
            onUtteranceStarted?(token)
        }
        pendingBuffers -= 1
        finishIfDrained(token: token)
    }

    private func finishIfDrained(token: UInt64) {
        guard activeToken == token, synthesisFinished, pendingBuffers == 0 else { return }
        speaking = false
        pausedForListening = false
        clearResumeProof()
        if timelineEnabled {
            let phase = timelinePhase.value.load(ordering: .acquiring)
            timelinePhase.value.store(0, ordering: .releasing)
            timelineObserverForTesting?(.stopped(token: activeToken, phaseBefore: phase))
        }
        activeToken = nil
        delivery = nil
        player.stop()
        playbackEngine.stop()
        VoicePlaybackReference.stopped()
        onUtteranceFinished?(token)
    }

    func stop() {
        speaking = false
        pausedForListening = false
        clearResumeProof()
        if timelineEnabled {
            let phase = timelinePhase.value.load(ordering: .acquiring)
            timelinePhase.value.store(0, ordering: .releasing)
            timelineObserverForTesting?(.stopped(token: activeToken, phaseBefore: phase))
        }
        activeToken = nil
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        playbackEngine.stop()
        VoicePlaybackReference.stopped()
        pendingBuffers = 0
    }

    func pauseForListening() {
        guard speaking, !pausedForListening else { return }
        pausedForListening = true
        clearResumeProof()
        if timelineEnabled, let token = activeToken {
            let phase = timelinePhase.value.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
            timelineResumeHost = nil
            timelineCheckpoint = nil
            timelineObserverForTesting?(.paused(token: token, phase: phase))
        }
        if player.isPlaying { player.pause() }
    }

    func resumeAfterListening() {
        guard speaking, pausedForListening else { return }
        pausedForListening = false
        clearResumeProof()
        if timelineEnabled {
            _ = timelinePhase.value.wrappingAdd(1, ordering: .acquiringAndReleasing)
            timelineResumeHost = mach_absolute_time()
            timelineCheckpoint = nil
        }
        if pendingBuffers > 0 && !player.isPlaying { player.play() }
        if timelineEnabled, let token = activeToken {
            let cursor = timelineCursor()
            if let cursor, let host = timelineResumeHost,
               cursor.sampleRate == timelineRate, cursor.frame >= 0, cursor.frame <= timelineEnd,
               cursor.observedHostTime >= host, cursor.nodeHostTime >= host {
                resumeEarlierCursor = cursor
            }
            timelineCheckpoint = diagnosticCheckpoint(cursor: cursor, completedEnd: nil)
            timelineObserverForTesting?(.resumed(token: token,
                phase: timelinePhase.value.load(ordering: .acquiring),
                requestedHostTime: timelineResumeHost ?? 0, cursor: cursor,
                checkpoint: timelineCheckpoint))
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let token = self.tokens[utteranceID] else { return }
            self.tokens[utteranceID] = nil
            guard self.activeToken == token else { return }
            // `write` may report synthesizer completion before queued PCM has
            // reached the player; only its zero-frame sentinel and playback
            // callbacks close the clause.
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            // The synthesis delegate marks generation, not speaker playback.
            _ = self.tokens[utteranceID]
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let token = self.tokens[utteranceID] else { return }
            self.tokens[utteranceID] = nil
            guard self.activeToken == token else { return }
            self.speaking = false
            self.activeToken = nil
            // Barge-in / stop already cleared pending clauses and session state.
        }
    }
}

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
