import Foundation

/// Identity of an existing worker call stack; child tasks inherit it.
/// No Task, queue, store or execution authority is created here.
enum VoiceWorkerScope { @TaskLocal static var isWorker = false }
enum IslandWriteScope { @TaskLocal static var isVoiceSession = false }
struct IslandTaskIndicator: Equatable, Sendable {
    let label: String
    let count: Int
}
@MainActor enum IslandOwnership {
    // A route without post-resume proof keeps the reducer diagnostic only.
    // It cannot claim presentation ownership or suppress legacy Island writes.
    static var isEnabled: Bool { AgentSpeechSynthesizer.shared.supportsQualifiedResumeReceipt }
    private(set) static var rejected: [String: Int] = [:]
    private(set) static var workerAttempts: [String: Int] = [:]
    static var workerAttemptTotal: Int { workerAttempts.values.reduce(0, +) }
    private static var actualSessionOpen: Bool {
        guard VoiceSession.shared.state.phase == .open, let id = VoiceSession.shared.state.sessionID else { return false }
        return AgentCaptureController.shared.isSessionActive && AgentCaptureController.shared.sessionID == id
    }
    static var sessionOwnsIsland: Bool { actualSessionOpen && isEnabled }
    static func mayWrite(_ site: String) -> Bool {
        let open = actualSessionOpen
        if open && VoiceWorkerScope.isWorker && !IslandWriteScope.isVoiceSession {
            workerAttempts[site, default: 0] += 1
        }
        guard sessionOwnsIsland, !IslandWriteScope.isVoiceSession else { return true }
        rejected[site, default: 0] += 1
        return false
    }
    static func resetCountersForTesting() {
        guard SelfTest.isRunning else { return }
        rejected.removeAll(); workerAttempts.removeAll()
    }
}
