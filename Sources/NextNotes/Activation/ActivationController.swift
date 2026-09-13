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
        WakeWordAudioMonitor.shared.sync()
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
        WakeWordAudioMonitor.shared.sync()
        IslandState.shared.showAgentListening(transcript: utterance ?? "")
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
