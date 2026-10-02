import Foundation

/// A supplied current observation, not reconstructed from a heartbeat or LAST cache.
/// No means only the named observation; it supplies no no-effect/retry authority.
enum TaskHeartbeatFact: String, Sendable, Equatable {
    case unknown, yes, no
}

/// Defaults remain unknown until an actual current producer supplies each observation.
/// Receipt-link absence is not a negative receipt fact; a running Process is not health.
struct TaskHeartbeatEvidence: Sendable, Equatable {
    var processAlive: TaskHeartbeatFact = .unknown
    var backendSessionAlive: TaskHeartbeatFact = .unknown
    var toolInFlight: TaskHeartbeatFact = .unknown
    var receiptCreated: TaskHeartbeatFact = .unknown
}

enum TaskHeartbeatUnknownReason: String, Sendable, Equatable {
    case missingRuntimeClass, missingHeartbeat, invalidClock, futureHeartbeat
}

/// Pure age evidence only. Neither a recent heartbeat nor an elapsed window is health
/// or a stale verdict. Current process/session/tool/receipt observations stay separate.
enum TaskHeartbeatAge: Sendable, Equatable {
    case excluded
    case waitingOnPerson
    case unknown(TaskHeartbeatUnknownReason)
    case withinWindow(age: TimeInterval, window: TimeInterval)
    case ageCandidate(age: TimeInterval, window: TimeInterval)

    /// A payload-free diagnostic label; no times, person content or health verdict.
    var diagnosticName: String {
        switch self {
        case .excluded: "excluded"
        case .waitingOnPerson: "waitingOnPerson"
        case .unknown: "unknown"
        case .withinWindow: "withinWindow"
        case .ageCandidate: "ageCandidate"
        }
    }
}

/// Roadmap §2.5/§2.10 starting windows for diagnostics, not failure/retry deadlines.
/// This policy performs no observation, heartbeat write, timer, I/O or state transition.
enum TaskHeartbeat {
    static func ageWindowSeconds(for runtimeClass: TaskRuntimeClass) -> TimeInterval? {
        switch runtimeClass {
        case .localDeterministic: 30
        case .cloudModel, .browserOrMCP: 300
        case .acpWorker: 900
        case .scheduledResearch: 1800
        case .waitingOnPerson: nil
        }
    }

    static func classify(status: AgentTaskStatus, runtimeClass: TaskRuntimeClass?,
                         heartbeatAt: Date?, permissionWait: Bool? = nil,
                         now: Date) -> TaskHeartbeatAge {
        switch status {
        case .queued, .recovering, .completed, .failed, .cancelled:
            return .excluded
        case .waitingForPermission, .waitingForCompatibilityCLI, .waitingForInput:
            return .waitingOnPerson
        case .running:
            break
        }
        guard permissionWait != true, runtimeClass != .waitingOnPerson else {
            return .waitingOnPerson
        }
        guard let runtimeClass, let window = ageWindowSeconds(for: runtimeClass) else {
            return .unknown(.missingRuntimeClass)
        }
        guard let heartbeatAt else { return .unknown(.missingHeartbeat) }
        let current = now.timeIntervalSinceReferenceDate
        let beat = heartbeatAt.timeIntervalSinceReferenceDate
        guard current.isFinite, beat.isFinite else { return .unknown(.invalidClock) }
        let age = current - beat
        guard age.isFinite else { return .unknown(.invalidClock) }
        guard age >= 0 else { return .unknown(.futureHeartbeat) }
        return age >= window ? .ageCandidate(age: age, window: window)
                             : .withinWindow(age: age, window: window)
    }
}
