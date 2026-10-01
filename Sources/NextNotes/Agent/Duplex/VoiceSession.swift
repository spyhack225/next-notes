import Foundation

/// Additive observer during P3-06a. Commands are recorded; existing producers
/// remain the sole owners of work, response cancellation and physical playback.
@MainActor final class VoiceSession {
    enum Mode { case shadow }
    let mode = Mode.shadow
    static let shared = VoiceSession()
    private(set) var state = VoiceSessionState()
    var nowForTesting: VoiceSessionInstant?
    private(set) var divergences: [String] = []
    private(set) var divergenceCount = 0
    private(set) var recentCommands: [VoiceCommand] = []
    private(set) var eventCount = 0
    private(set) var outputPresenceComparisonCount = 0
    private(set) var comparisonCounts: [String: Int] = [:]
    private(set) var unavailableCounts: [String: Int] = [:]
    private let reference = ContinuousClock.now
    private var observers: [UUID: AsyncStream<VoiceEvent>.Continuation] = [:]
    private var comparison: Task<Void, Never>?
    private var comparisonEvent = ""
    private var recorder: FileHandle?
    private var reservedTurn: TurnID?
    private var bareBarrierFloor = false

    struct LegacyProjection {
        var effectsHeld: Bool
        var turnPending: TurnID?
        var output: VoiceSessionState.Output?
        var floor: Bool?
    }

    private init() {
        guard SelfTest.isRunning, let index = CommandLine.arguments.firstIndex(of: "--record-voice-trace"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.resolvingSymlinksInPath()
        if let support, url.path == support.path || url.path.hasPrefix(support.path + "/") {
            print("VOICE_SESSION_TRACE_REFUSED: trace path is inside Application Support")
            SelfTest.failed = true
            return
        }
        do {
            if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
            recorder = try FileHandle(forWritingTo: url)
            try recorder?.truncate(atOffset: 0)
        } catch { print("VOICE_SESSION_TRACE_FAILED: \(error.localizedDescription)"); SelfTest.failed = true }
    }
    func beginTurnIfNeeded() -> TurnID {
        if case .userProvisional(let turn) = state.floor { return turn }
        if let turn = reservedTurn, state.lastCommittedTurn == nil || turn > state.lastCommittedTurn! { return turn }
        let turn = VoiceIDMint.shared.nextTurn()
        reservedTurn = turn
        return turn
    }
    func currentTurn() -> TurnID? {
        if case .userProvisional(let turn) = state.floor { return turn }
        return state.response?.turn ?? state.turnPending
    }
    func send(_ event: VoiceEvent) { apply(event) }
    func interrupt(_ value: Interruption) { apply(.interruption(value)) }
    func events() -> AsyncStream<VoiceEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.onTermination = { _ in Task { @MainActor in VoiceSession.shared.observers.removeValue(forKey: id) } }
        }
    }
    /// A bare coordinator fixture raises a real barrier without an acoustic
    /// producer. Its floor reference is explicitly unavailable, not fabricated.
    func noteBareBarrierActivity() { bareBarrierFloor = true }
    func noteFloorProducer() { bareBarrierFloor = false }
    private func apply(_ event: VoiceEvent) {
        let now = nowForTesting ?? .init(milliseconds: reference.duration(to: .now).wholeMilliseconds)
        let (next, commands) = VoiceSessionReducer.reduce(state, event, at: now)
        state = next
        eventCount += 1
        recentCommands += commands
        if recentCommands.count > 200 { recentCommands.removeFirst(recentCommands.count - 200) }
        if case .sessionClosed = event { reservedTurn = nil; bareBarrierFloor = false }
        if case .inputWithdrawn = event { reservedTurn = nil; bareBarrierFloor = false }
        for observer in observers.values { observer.yield(event) }
        if let recorder {
            do {
                var data = try JSONEncoder().encode(VoiceSessionReducerSelfTest.RecordedFrame(at: now.milliseconds, event: event))
                data.append(10)
                try recorder.write(contentsOf: data)
            } catch { print("VOICE_SESSION_TRACE_FAILED: \(error.localizedDescription)"); SelfTest.failed = true }
        }
        // No new timer, task, output or island owner in shadow mode. Existing
        // capture ticks supply timer facts; commands remain diagnostics only.
        producerDidSettle(after: event)
    }
    /// Coalesces only the comparison, never ordered events. Runs after the
    /// synchronous producer stack, with no await added to the user's path.
    func producerDidSettle(after event: VoiceEvent? = nil) {
        if let event { comparisonEvent = String(describing: event).split(separator: "(").first.map(String.init) ?? "event" }
        guard comparison == nil else { return }
        comparison = Task { @MainActor [weak self] in
            guard let self else { return }
            self.comparison = nil
            self.compareLegacy(after: self.comparisonEvent)
        }
    }
    private func compareLegacy(after event: String) {
        let coordinator = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let agent = RealtimeAgent.shared
        guard capture.isSessionActive || state.phase == .open else { return }
        let output = audio.voiceShadowOutputSnapshot
        if output != nil { outputPresenceComparisonCount += 1 }
        let frontend = coordinator.voiceShadowResponseTurn
        let queued = capture.voiceShadowQueuedTurn
        let outputTurn: TurnID? = switch output?.kind {
        case .answer(let turn), .fixed(let turn): turn
        default: nil
        }
        let floor: Bool? = bareBarrierFloor && !capture.heardSpeechForTesting && !agent.voiceInputActive
            ? nil : (capture.voiceShadowHasFloor || agent.voiceInputActive)
        let projection = LegacyProjection(effectsHeld: coordinator.inputPending || coordinator.effectHoldEpoch != nil,
            turnPending: frontend ?? queued ?? outputTurn, output: output, floor: floor)
        check("effectsHeld", state.effectsHeld, projection.effectsHeld, after: event)
        check("turnPending", state.turnPending, projection.turnPending, after: event)
        check("output", state.output, projection.output, after: event)
        if let floor = projection.floor { check("floor", state.floor != .free, floor, after: event) }
        else { unavailableCounts["floor", default: 0] += 1 }
    }
    private func check<T: Equatable>(_ field: String, _ reducer: T, _ legacy: T, after event: String) {
        comparisonCounts[field, default: 0] += 1
        guard reducer != legacy else { return }
        let message = "field=\(field) event=\(event) reducer=\(reducer) legacy=\(legacy)"
        divergenceCount += 1
        if divergences.count < 200 { divergences.append(message) }
        if SelfTest.isRunning, divergenceCount <= 200 { print("VOICE_SESSION_DIVERGENCE: \(message)") }
        else if divergenceCount <= 10 { Log.agent.debug("voice shadow divergence \(message, privacy: .public)") }
    }
    func resetDiagnosticsForTesting() {
        guard SelfTest.isRunning else { return }
        divergences.removeAll(); divergenceCount = 0; comparisonCounts.removeAll(); unavailableCounts.removeAll(); eventCount = 0; outputPresenceComparisonCount = 0
    }
    func printDiagnostics() {
        print("VOICE_SESSION_SHADOW: events=\(eventCount) divergences=\(divergenceCount) coverage=\(comparisonCounts) output_present=\(outputPresenceComparisonCount) unavailable=\(unavailableCounts)")
    }
}
