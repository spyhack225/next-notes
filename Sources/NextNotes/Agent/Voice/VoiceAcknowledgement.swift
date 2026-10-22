import AVFoundation
import Foundation
import Observation

/// A committed-turn courtesy sound owns no answer, history or task delivery.
@MainActor
final class VoiceAcknowledgement {
    static let shared = VoiceAcknowledgement()
    struct Environment {
        var session = true
        var speaking = false
        var dictating = false
        var meeting = false
        var output = false
        var interaction = false
        var permits: Bool { session && !speaking && !dictating && !meeting && !output && !interaction }
    }
    private var environmentOverride: (() -> Environment)?
    private var testClips: [String]?
    private(set) var playedForTesting: [String] = []
    private var task: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var committed: TurnID?
    private var played = false
    private var lastTestClip: String?
    private var observing = false
    private var admissionObserver: NSObjectProtocol?
    private var output: OutputToken?
    private var permitsTest: Bool {
        SelfTest.isRunning && SelfTest.requested == "--selftest-voice-latency"
            && CommandLine.arguments.contains("--voice-latency-ack-policy")
    }
    var environmentForTesting: (() -> Environment)? {
        get { permitsTest ? environmentOverride : nil }
        set { if permitsTest { environmentOverride = newValue } }
    }
    var clipsForTesting: [String]? {
        get { permitsTest ? testClips : nil }
        set { if permitsTest { testClips = newValue } }
    }
    var testActive: Bool { permitsTest && output != nil }
    var pendingForTesting: Bool { permitsTest && task != nil }
    var isPlaying: Bool { output != nil }
    private func environment(interaction: Bool) -> Environment {
        if permitsTest, var injected = environmentOverride?() {
            injected.interaction = injected.interaction || interaction
            return injected
        }
        return Environment(session: AgentCaptureController.shared.isSessionActive,
            speaking: RealtimeAgent.shared.voiceInputActive,
            dictating: AppDelegate.current?.controller.state.isActive ?? false,
            meeting: MeetingController.shared.session != nil,
            output: RealtimeAudioSession.shared.isSpeaking
                || (AgentSpeechSynthesizer.shared.isSpeaking && !isPlaying),
            interaction: interaction || PermissionGate.shared.pending != nil)
    }
    var idleForPrewarm: Bool {
        let state = environment(interaction: false)
        return !state.speaking && !state.dictating && !state.meeting && !state.output
            && !isPlaying && !RealtimeAgent.shared.isThinking
            && !AgentCaptureController.shared.voiceShadowHasFloor
            && !VoiceConversationCoordinator.shared.inputPending
    }
    static func eligibleText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !VoiceTurnPolicy.isHesitation(text),
              !VoiceTurnPolicy.isBackchannel(text, whileAssistantSpeaking: true),
              VoiceTurnPolicy.knownNoiseFragment(in: text) == nil,
              !VoiceTurnPolicy.isBareAcknowledgment(text),
              !VoiceTurnPolicy.isExplicitWorkCancellation(text),
              !VoiceTurnPolicy.isClosingTurn(text) else { return false }
        switch SpokenApproval.read(text) {
        case .approve, .deny, .hold: return false
        default: return true
        }
    }
    func commit(_ turn: TurnID, text: String, interaction: Bool) {
        guard committed != turn else { return }
        cancel()
        committed = turn; played = false
        if SelfTest.isRunning, SelfTest.requested == "--selftest-voice-latency",
           CommandLine.arguments.contains("--voice-no-ack") { return }
        guard environment(interaction: interaction).permits, Self.eligibleText(text),
              ready else { return }
        let owned = revision
        // Off the answer path. 120ms grace plus historical94ms render cost would
        // miss200ms;40ms leaves headroom. A ready answer cancels synchronously.
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled, revision == owned else { return }
            task = nil
            guard environment(interaction: interaction).permits, ready else { return }
            OutputScheduler.shared.playAcknowledgement(turn: turn)
        }
    }
    private var ready: Bool {
        guard ["pocket", "kokoro"].contains(VoiceAcknowledgementClips.Selection.current.engine) else { return false }
        if permitsTest, let testClips { return testClips.count >= 2 }
        return VoiceAcknowledgementClips.shared.readyCount >= 2
    }
    /// Only OutputScheduler can supply the minted output capability.
    @discardableResult
    func play(_ token: OutputToken, turn: TurnID) -> Bool {
        guard ready, output == nil, committed == turn, !played else { return false }
        if permitsTest, let testClips {
            guard let clip = testClips.first(where: { $0 != lastTestClip }) else { return false }
            played = true; lastTestClip = clip; playedForTesting.append(clip); output = token
            return true
        }
        guard let clip = VoiceAcknowledgementClips.shared.next() else { return false }
        played = true; output = token
        AgentSpeechSynthesizer.shared.playAcknowledgement(clip, token: token, first: { [weak self] in
            guard self?.output?.output == token.output else { return }
            VoiceLatencyTimeline.shared.mark(.acknowledgementAudible)
        }, finished: { [weak self] in
            if self?.output?.output == token.output { self?.output = nil }
        })
        return true
    }
    func cancel() {
        revision &+= 1; task?.cancel(); task = nil
        VoiceAcknowledgementClips.shared.stopPrewarm()
        if output != nil {
            output = nil
            AgentSpeechSynthesizer.shared.cancelAcknowledgement()
        }
    }
    /// The existing Settings writer retires old PCM synchronously, before any
    /// observation callback or new selected voice preparation can run.
    func voiceSelectionChanged() {
        cancel()
        VoiceAcknowledgementClips.shared.invalidate()
    }
    func prewarm() {
        guard !SelfTest.isRunning || VoiceAcknowledgementClips.shared.permitsPrewarmForTesting else { return }
        observePrewarmInputs()
        VoiceAcknowledgementClips.shared.prewarm()
    }
    private func observePrewarmInputs() {
        if admissionObserver == nil {
            admissionObserver = NotificationCenter.default.addObserver(
                forName: ModelResidencyPolicy.admissionChanged, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.prewarm() }
            }
        }
        guard !observing else { return }
        observing = true
        withObservationTracking {
            _ = Settings.shared.agentVoiceEngine
            _ = Settings.shared.agentPocketVoice
            _ = PocketAgentVoice.shared.isReady
            _ = KokoroAgentVoice.shared.isReady
            _ = AgentSpeechSynthesizer.shared.availability
            _ = AppDelegate.current?.controller.state.isActive
            _ = MeetingController.shared.session
            _ = RealtimeAgent.shared.voiceInputActive
            _ = RealtimeAgent.shared.isThinking
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observing = false
                if !self.environment(interaction: false).permits || !VoiceAcknowledgementClips.Selection.current.ready { self.cancel() }
                if let selection = VoiceAcknowledgementClips.shared.selection, selection != .current {
                    self.cancel(); VoiceAcknowledgementClips.shared.invalidate()
                }
                self.prewarm()
            }
        }
    }
}
