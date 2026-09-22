import Foundation
import Observation

/// Three activation paths, one session: push-to-talk stays dictation; the shortcut and
/// the wake phrase open the agent.
@MainActor
@Observable
final class ActivationController {
    static let shared = ActivationController()

    enum Mode: Equatable {
        case idle
        case agentListening
        case agentWorking
    }

    private(set) var mode: Mode = .idle
    private(set) var lastWake: WakeWordDetector.Detection?

    private init() {}

    func start() {
        ShortcutActivation.shared.onTrigger = { [weak self] in
            self?.toggleAgent()
        }
        ShortcutActivation.shared.start()
        // After the rest of launch has returned: a bad keywords.txt used to abort inside
        // sherpa during `applicationDidFinishLaunching`, so the Dock icon flashed and the
        // process was gone. Deferring keeps the window up even if wake setup fails later.
        Task { @MainActor in
            WakeWordAudioMonitor.shared.sync()
        }
    }

    func toggleAgent() {
        switch mode {
        case .agentListening:
            Task { await AgentCaptureController.shared.endSession(source: .done) }
        case .agentWorking:
            if AgentCaptureController.shared.isSessionActive {
                RealtimeAgent.shared.interrupt()
                markListening()
            } else {
                RealtimeAgent.shared.cancel()
            }
        case .idle:
            beginAgent(source: "shortcut")
        }
    }

    func beginAgent(source: String, utterance: String? = nil) {
        if mode == .agentWorking {
            RealtimeAgent.shared.interrupt()
        }
        mode = .agentListening
        // The island is the acknowledgement, so it goes first. This used to sit behind
        // `WakeWordAudioMonitor.sync()`, which — being the only microphone subscriber —
        // stopped the shared AVAudioEngine synchronously on this actor before anything
        // was drawn. Feedback now costs a paint; the monitor idles itself afterwards
        // and keeps its seat, so no engine is stopped on the wake path at all.
        IslandState.shared.showAgentListening(transcript: utterance ?? "")
        WakeWordAudioMonitor.shared.sync()
        AgentAuditLog.shared.record(kind: .wake, title: "Agent woke", detail: source)
        Task {
            await AgentCaptureController.shared.beginSession(captureAudio: !SelfTest.isRunning)
            if let utterance, !utterance.isEmpty {
                AgentCaptureController.shared.simulateSpeech(utterance)
                AgentCaptureController.shared.simulateSilence()
                _ = await AgentCaptureController.shared.considerEndpoint()
            }
        }
    }

    func markListening() {
        mode = .agentListening
    }

    func handleWake(in segment: TranscriptSegment) -> TranscriptSegment {
        guard Settings.shared.voiceWakeEnabled else { return segment }
        let configuration = WakeWordConfiguration.current
        guard let detection = WakeWordDetector.command(in: segment, configuration: configuration) else {
            return segment
        }
        lastWake = detection
        var marked = segment
        marked.kind = .agentCommand
        beginAgent(source: "wake", utterance: detection.remainder)
        return marked
    }

    func markWorking() {
        mode = .agentWorking
    }

    func finishAgent() {
        mode = .idle
        WakeWordAudioMonitor.shared.sync()
    }
}
