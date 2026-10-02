import Foundation

struct TurnID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    let raw: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
    var description: String { "turn#\(raw)" }
}
struct OutputID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    let raw: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
    var description: String { "output#\(raw)" }
}
struct TaskID: Hashable, Sendable, Codable, CustomStringConvertible {
    let raw: String
    init(_ raw: String) { self.raw = raw }
    init(_ uuid: UUID) { raw = uuid.uuidString }
    var description: String { "task#\(raw.prefix(8))" }
}
@MainActor final class VoiceIDMint {
    static let shared = VoiceIDMint()
    private var turn: UInt64 = 0
    private var output: UInt64 = 0
    func nextTurn() -> TurnID { turn &+= 1; return .init(raw: turn) }
    func nextOutput() -> OutputID { output &+= 1; return .init(raw: output) }
}
struct VoiceSessionInstant: Comparable, Sendable, Codable {
    let milliseconds: Int64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.milliseconds < rhs.milliseconds }
    func adding(_ duration: Duration) -> Self { .init(milliseconds: milliseconds + duration.wholeMilliseconds) }
}
extension Duration {
    var wholeMilliseconds: Int64 { components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000 }
}
enum AgentDeliveryTiming { static let quietWindow: Duration = .milliseconds(350) }
enum VoiceSessionCloseReason: String, Sendable, Codable { case done, goodbye, idle, stopButton, error, notAddressed }
enum InputDiscardReason: String, Sendable, Codable { case noWords, backchannel, playbackEcho, inFlightRepeat, revisedTranscript }
enum ResponseOutcome: Sendable, Equatable, Codable {
    case answered, fixedReply, failed(code: String), cancelled
}
enum PlaybackPhase: Sendable, Equatable, Codable {
    case began, firstAudio, clauseCompleted, finished, interrupted(byUser: Bool)
}
enum OutputKind: Sendable, Equatable, Codable {
    case answer(TurnID), fixed(TurnID), delivery([TaskID]), approvalPrompt(requestID: String, task: TaskID), taskQuestion(TaskID)
}
enum VoiceTimer: String, Sendable, Codable { case quietWindow, idleCheck, deliveryRetry }
enum Interruption: Sendable, Equatable, Codable {
    case provisional(TurnID), committed(TurnID), explicitCancel(TaskID?)
}
enum SpokenPermissionDecision: String, Sendable, Codable { case approve, deny }
enum FrontendDecision: Sendable, Equatable, Codable {
    case answer, capabilities
    case spawn(objective: String, userWords: String, backend: AgentBackendKind?)
    case revise(TaskID, text: String), cancel(TaskID?), status(TaskID?)
    case respondPermission(requestID: String?, decision: SpokenPermissionDecision, amendment: String?)
    case notAddressed
}
// Value contracts for the forthcoming single TaskBridge. No mutable task mirror is introduced.
enum TaskState: String, Sendable, Codable, CaseIterable {
    case queued, running, delegated, finalizing, needsInput, needsPermission, cancelling, completed, failed, cancelled
    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
    var isCancellable: Bool { !isTerminal && self != .cancelling }
    static let legal: [Self: Set<Self>] = [
        .queued: [.running, .cancelled, .failed],
        .running: [.delegated, .finalizing, .needsInput, .needsPermission, .cancelling, .completed, .failed],
        .delegated: [.finalizing, .needsInput, .needsPermission, .cancelling, .completed, .failed],
        .finalizing: [.cancelling, .completed, .failed],
        .needsInput: [.running, .cancelling, .failed],
        .needsPermission: [.running, .delegated, .cancelling, .failed],
        .cancelling: [.cancelled, .failed]
    ]
}
enum TaskOrigin: Sendable, Equatable, Codable {
    case voice(sessionID: UUID, turn: TurnID), typed, remote(ActionOriginContext), scheduled, meeting(UUID), selfTest
}
enum TaskDelivery: String, Sendable, Codable {
    case none, pending, delivering, delivered, deliveredInContext, consumedByStatus, silent, failed
}
enum TaskEvent: Sendable, Equatable, Codable {
    case accepted(TaskID, title: String, origin: TaskOrigin)
    case stateChanged(TaskID, from: TaskState, to: TaskState)
    case progress(TaskID, step: Int, title: String), revised(TaskID, revision: Int)
    case needsInput(TaskID, question: String), needsPermission(TaskID, requestID: String)
    case permissionResolved(TaskID, requestID: String, approved: Bool)
    case completed(TaskID, result: String, artifacts: [String]), failed(TaskID, reason: String), cancelled(TaskID)
    case deliveryChanged(TaskID, TaskDelivery), deliveryQueued(count: Int)
}
enum VoiceEvent: Sendable, Equatable, Codable {
    case sessionOpened(sessionID: UUID), sessionClosed(VoiceSessionCloseReason)
    case inputActivity(TurnID), inputEnded(TurnID), partial(TurnID, text: String, stable: Bool), rawEndOfUtterance(TurnID, text: String)
    case inputDiscarded(TurnID, InputDiscardReason), inputWithdrawn, hesitation(TurnID, text: String), committed(TurnID, text: String)
    case decisionMade(TurnID, FrontendDecision), responseStarted(TurnID, OutputID), responseEnded(TurnID, ResponseOutcome)
    case outputQueued(OutputID, OutputKind), playback(OutputID, PlaybackPhase), task(TaskEvent)
    case approvalPending(requestID: String, task: TaskID), approvalResolved(requestID: String)
    case timer(VoiceTimer), interruption(Interruption)
}
enum IslandProjection: Sendable, Equatable, Codable { case none, listening, thinking, speaking, proposal(String) }
struct VoiceSessionState: Sendable, Equatable, Codable {
    enum Phase: String, Sendable, Codable { case closed, open }
    enum Floor: Sendable, Equatable, Codable { case free, userProvisional(TurnID) }
    struct Response: Sendable, Equatable, Codable { var turn: TurnID; var decided: Bool; var output: OutputID? }
    struct Output: Sendable, Equatable, Codable {
        enum Status: String, Sendable, Codable { case queued, playing, paused }
        var id: OutputID; var kind: OutputKind; var status: Status; var heard: Bool
    }
    var phase: Phase = .closed
    var sessionID: UUID?
    var floor: Floor = .free
    var unclassified: Set<TurnID> = []
    var failedInputHold: TurnID?
    var effectsHeld: Bool { !unclassified.isEmpty || failedInputHold != nil }
    var turnPending: TurnID?
    var lastCommittedTurn: TurnID?
    var response: Response?
    var output: Output?
    var lastUserSpeechAt: VoiceSessionInstant?
    var lastOutputEndAt: VoiceSessionInstant?
    var openedAt: VoiceSessionInstant?
    var activeTasks: Set<TaskID> = []
    var pendingDeliveries = 0
    var pendingApproval: String?
    var island: IslandProjection = .none
    func deliveryWindowOpen(now: VoiceSessionInstant) -> Bool {
        guard phase == .open, floor == .free, turnPending == nil, response == nil, output == nil, unclassified.isEmpty else { return false }
        return now >= quietUntil
    }
    var quietUntil: VoiceSessionInstant {
        max(lastUserSpeechAt ?? openedAt ?? .init(milliseconds: 0), lastOutputEndAt ?? openedAt ?? .init(milliseconds: 0)).adding(AgentDeliveryTiming.quietWindow)
    }
}
enum VoiceCommand: Sendable, Equatable, Codable {
    case setEffectsHeld(Bool), pauseOutput(OutputID), resumeOutput(OutputID), stopOutput(OutputID, byUser: Bool)
    case cancelResponse(TurnID), startResponse(TurnID, text: String), speculate(TurnID, text: String), cancelTask(TaskID?)
    case openDeliveryWindow, scheduleTimer(VoiceTimer, after: Duration), publishIsland(IslandProjection), closeSession(VoiceSessionCloseReason)
}
enum VoiceSessionReducer {
    static func reduce(_ state: VoiceSessionState, _ event: VoiceEvent, at now: VoiceSessionInstant) -> (VoiceSessionState, [VoiceCommand]) {
        var next = state
        var commands: [VoiceCommand] = []
        let held = state.effectsHeld
        let oldIsland = state.island
        func project(_ island: IslandProjection) { next.island = island }
        func quietTimer() { commands.append(.scheduleTimer(.quietWindow, after: AgentDeliveryTiming.quietWindow)) }
        func stopForCommitted(_ turn: TurnID) {
            if let output = next.output {
                commands.append(.stopOutput(output.id, byUser: true))
                switch output.kind {
                case .answer(let old), .fixed(let old): if next.turnPending == old { next.turnPending = nil }
                default: break
                }
                next.output = nil
                next.lastOutputEndAt = now
            }
            if let response = next.response, response.turn < turn {
                commands.append(.cancelResponse(response.turn))
                next.unclassified.remove(response.turn)
                next.response = nil
            }
        }
        func close() {
            if let output = next.output { commands.append(.stopOutput(output.id, byUser: false)) }
            if let response = next.response { commands.append(.cancelResponse(response.turn)) }
            next.phase = .closed
            next.unclassified.removeAll()
            next.failedInputHold = nil
            next.floor = .free
            next.response = nil
            next.output = nil
            next.turnPending = nil
            next.pendingApproval = nil
            project(.none)
        }
        if case .sessionOpened(let sessionID) = event {
            if next.phase == .open { close() }
            next = VoiceSessionState()
            next.phase = .open
            next.sessionID = sessionID
            next.openedAt = now
            project(.listening)
            quietTimer()
            commands.append(.scheduleTimer(.idleCheck, after: .seconds(1)))
        } else if next.phase == .open {
            switch event {
            case .sessionOpened: break
            case .sessionClosed: close()
            case .inputActivity(let turn), .partial(let turn, _, _):
                guard next.lastCommittedTurn == nil || turn > next.lastCommittedTurn! else { return (state, []) }
                if case .userProvisional(let current) = next.floor, turn < current { return (state, []) }
                next.lastUserSpeechAt = now
                next.floor = .userProvisional(turn)
                next.unclassified.insert(turn)
                if case .partial(_, let text, stable: true) = event { commands.append(.speculate(turn, text: text)) }
            case .inputEnded(let turn):
                guard next.floor == .userProvisional(turn) else { return (state, []) }
                // The acoustic/control floor can end before text is classified.
                // Keep pending input and any failed-epoch effect hold intact.
                next.floor = .free
                next.lastUserSpeechAt = now
            case .rawEndOfUtterance: break // P2-03 remains the input producer's authority.
            case .inputDiscarded(let turn, _):
                guard next.floor == .userProvisional(turn) else { return (state, []) }
                next.floor = .free
                next.unclassified.remove(turn)
                if var output = next.output, output.status == .paused {
                    output.status = output.heard ? .playing : .queued
                    next.output = output
                    commands.append(.resumeOutput(output.id))
                }
                quietTimer()
            case .inputWithdrawn:
                next.floor = .free
                next.unclassified.removeAll()
                next.failedInputHold = nil
                quietTimer()
            case .hesitation(let turn, _):
                guard next.floor == .userProvisional(turn) else { return (state, []) }
                next.lastUserSpeechAt = now
            case .interruption(.provisional(let turn)):
                guard next.lastCommittedTurn == nil || turn > next.lastCommittedTurn! else { return (state, []) }
                if case .userProvisional(let current) = next.floor, turn < current { return (state, []) }
                next.floor = .userProvisional(turn)
                next.unclassified.insert(turn)
                next.lastUserSpeechAt = now
                if var output = next.output, output.status == .playing {
                    output.status = .paused
                    next.output = output
                    commands.append(.pauseOutput(output.id))
                }
            case .interruption(.committed(let turn)):
                guard next.lastCommittedTurn == nil || turn > next.lastCommittedTurn! else { return (state, []) }
                if case .userProvisional(let current) = next.floor, turn < current { return (state, []) }
                stopForCommitted(turn)
            case .interruption(.explicitCancel(let task)): commands.append(.cancelTask(task))
            case .committed(let turn, let text):
                guard next.lastCommittedTurn == nil || turn > next.lastCommittedTurn! else { return (state, []) }
                if case .userProvisional(let current) = next.floor, turn < current { return (state, []) }
                stopForCommitted(turn)
                next.lastCommittedTurn = turn
                next.floor = .free
                next.turnPending = turn
                next.unclassified.insert(turn)
                next.response = .init(turn: turn, decided: false, output: nil)
                next.lastUserSpeechAt = now
                project(.thinking)
                commands.append(.startResponse(turn, text: text))
            case .decisionMade(let turn, _):
                if var response = next.response, response.turn == turn, !response.decided {
                    response.decided = true
                    next.response = response
                    next.unclassified = next.unclassified.filter { $0 > turn }
                    if let failed = next.failedInputHold, turn > failed { next.failedInputHold = nil }
                } else if next.response?.turn != turn { next.unclassified.remove(turn) }
            case .responseStarted(let turn, let output):
                guard var response = next.response, response.turn == turn else {
                    commands.append(.stopOutput(output, byUser: false)); break
                }
                if let active = next.output {
                    if active.id != output { commands.append(.stopOutput(output, byUser: false)) }
                    break
                }
                response.output = output
                next.response = response
                next.output = .init(id: output, kind: .answer(turn), status: .queued, heard: false)
            case .responseEnded(let turn, let outcome):
                if next.response?.turn == turn {
                    if case .failed = outcome { next.failedInputHold = turn }
                    next.response = nil
                    next.unclassified.remove(turn)
                    if next.output?.kind != .answer(turn) && next.output?.kind != .fixed(turn) { next.turnPending = nil }
                    project(.listening)
                    quietTimer()
                } else { next.unclassified.remove(turn) }
            case .outputQueued(let id, let kind):
                guard next.output == nil else { break }
                next.output = .init(id: id, kind: kind, status: .queued, heard: false)
            case .playback(let id, let phase):
                guard var output = next.output, output.id == id else { break }
                switch phase {
                case .began, .clauseCompleted: break
                case .firstAudio:
                    output.status = .playing; output.heard = true; next.output = output; project(.speaking)
                case .finished:
                    next.output = nil; next.lastOutputEndAt = now
                    switch output.kind {
                    case .answer(let turn), .fixed(let turn): if next.turnPending == turn { next.turnPending = nil }
                    default: break
                    }
                    project(.listening); quietTimer()
                case .interrupted:
                    next.output = nil; next.lastOutputEndAt = now
                    switch output.kind {
                    case .answer(let old), .fixed(let old):
                        if next.turnPending == old && next.response?.turn != old { next.turnPending = nil }
                    default: break
                    }
                }
            case .task(let taskEvent):
                switch taskEvent {
                case .accepted(let id, _, .voice(let session, _)) where session == next.sessionID: next.activeTasks.insert(id)
                case .completed(let id, _, _), .failed(let id, _), .cancelled(let id): next.activeTasks.remove(id)
                case .deliveryQueued(let count): next.pendingDeliveries = count; commands.append(.scheduleTimer(.quietWindow, after: .zero))
                default: break
                }
            case .approvalPending(let request, _): next.pendingApproval = request; project(.proposal(request))
            case .approvalResolved(let request):
                guard next.pendingApproval == request else { break }
                next.pendingApproval = nil; project(.listening)
            case .timer(.quietWindow), .timer(.deliveryRetry):
                if next.pendingDeliveries > 0 {
                    if next.deliveryWindowOpen(now: now) { commands.append(.openDeliveryWindow) }
                    else if next.floor == .free && next.turnPending == nil && next.response == nil && next.output == nil && next.unclassified.isEmpty && now < next.quietUntil {
                        commands.append(.scheduleTimer(.quietWindow, after: .milliseconds(next.quietUntil.milliseconds - now.milliseconds)))
                    }
                }
            case .timer(.idleCheck):
                let last = max(next.openedAt ?? now, max(next.lastUserSpeechAt ?? next.openedAt ?? now, next.lastOutputEndAt ?? next.openedAt ?? now))
                if next.floor == .free && next.response == nil && next.output == nil && next.turnPending == nil && next.activeTasks.isEmpty && next.pendingApproval == nil && now >= last.adding(.seconds(25)) {
                    commands.append(.closeSession(.idle))
                } else { commands.append(.scheduleTimer(.idleCheck, after: .seconds(1))) }
            }
        }
        if held != next.effectsHeld { commands.insert(.setEffectsHeld(next.effectsHeld), at: 0) }
        if oldIsland != next.island { commands.append(.publishIsland(next.island)) }
        return (next, commands)
    }
}
