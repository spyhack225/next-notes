import Foundation

/// One model or engine pass, as written to `usage.jsonl` (P0-20a).
///
/// The row answers "which model or engine ran, how did it go": provider and the concrete
/// model that ran, local or cloud, warm or cold, token counts, first-token and total time,
/// the tools proposed and run, the finish reason and the error class. It carries **no**
/// prompt, reply, reasoning, transcript, dictated text, tool arguments or tool output.
/// Optional keys are omitted when nil, so an older reader is never forced to know a field
/// a newer writer invented.
struct UsageRecord: Codable, Sendable, Equatable {
    /// Schema version. A reader skips a row whose `v` is greater than the version it knows.
    var v: Int = 1
    var id: UUID
    /// When the pass ended.
    var ts: Date
    /// `UsageFeature.rawValue`.
    var feature: String
    /// "answer" | "planner" | "final" | "frontend-route" | "frontend-answer" | "round" |
    /// "single" | "map" | "collapse" | "reduce" | "reconcile" | "review" | "live" |
    /// "window-batch" | "cluster" | "engine" | "cleanup" | "handoff" | "turn" |
    /// "hold" | "press".
    var pass: String
    var round: Int?
    /// `UsageProvider.rawValue`.
    var provider: String
    /// The model or engine that actually ran (`displayModelName` / engine id).
    var modelID: String
    /// "local" | "cloud".
    var locality: String
    /// `ModelRole.rawValue` when a role chose the provider.
    var requestedRole: String?
    /// What that role named; differs from `modelID` on a fallback.
    var requestedModel: String?
    /// `UsageFallback.rawValue`.
    var fallbackReason: String?
    /// False when this pass paid a model load.
    var warm: Bool?
    var loadMs: Int?
    var promptTokens: Int?
    /// OpenRouter prompt cache, or a reused llama prefix (P0-18).
    var cachedTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    /// True when the counts are characters / 4 rather than measured.
    var countsEstimated: Bool?
    /// First visible token; nil for engines and non-streamed passes.
    var ttftMs: Int?
    /// The pass itself, excluding tool execution and waiting for a person.
    var totalMs: Int
    /// `completionTokens / (totalMs − ttftMs)`, when both exist.
    var tokensPerSec: Double?
    /// "stop" | "length" | "cancelled" | "error" | "timeout".
    var finishReason: String?
    /// True when the pass hit its answer limit or an engine deadline.
    var truncated: Bool?
    /// Canonical tool ids only, never arguments.
    var toolsProposed: [String]?
    var toolsExecuted: [UsageToolRun]?
    /// `UsageErrorClass.rawValue`.
    var errorClass: String?
    /// `UsageLog.sanitise(_:)`, at most 160 characters.
    var errorMessage: String?
    /// Speech engines and speaker separation.
    var audioSeconds: Double?
    /// Compute seconds / audio seconds.
    var realtimeFactor: Double?
    /// Named sub-stage seconds (the dictation split, P2-01's voice headline stages).
    var stages: [String: Double]?
    /// Counters such as proposals, refusals, windows, speakers, facts, budget.
    var counts: [String: Int]?

    // MARK: Correlation ids
    // These are how a row joins to the other stores. All optional.

    /// One user turn (typed, voice) or one worker revision.
    var turnID: UUID?
    /// `AgentSession.shared.sessionID`.
    var conversationID: UUID?
    var workID: UUID?
    var revision: Int?
    /// `Meetings/<id>/meeting.json`.
    var meetingID: UUID?
    /// `DictationRun.id` in `runs.jsonl`.
    var dictationRunID: UUID?
    /// A routine.
    var scheduleID: UUID?
}

/// One tool call that ran inside a model pass. `ms` is execution time only — a write's
/// approval wait is not execution.
struct UsageToolRun: Codable, Sendable, Equatable {
    var id: String
    var ok: Bool
    var ms: Int
    var errorClass: String?
}

/// Which feature a usage row belongs to. A reader must tolerate a raw value it does not
/// know (a newer build), which is why `UsageRecord.feature` is a `String`.
enum UsageFeature: String, Codable, Sendable, CaseIterable {
    case agentTyped = "agent.typed"
    case agentVoice = "agent.voice"
    case agentWorker = "agent.worker"
    case agentRoutine = "agent.routine"
    case agentHandoff = "agent.handoff"
    case meetingTranscribe = "meeting.transcribe"
    case meetingDiarize = "meeting.diarize"
    case meetingNotesSingle = "meeting.notes.single"
    case meetingNotesMap = "meeting.notes.map"
    case meetingNotesCollapse = "meeting.notes.collapse"
    case meetingNotesReduce = "meeting.notes.reduce"
    case meetingReconcile = "meeting.reconcile"
    case meetingProposals = "meeting.proposals"
    case meetingLive = "meeting.live"
    case meetingNeedle = "meeting.needle"
    case dictationASR = "dictation.asr"
    case dictationCleanup = "dictation.cleanup"
    /// One row per hold, whatever happened (D-01b).
    case dictationHold = "dictation.hold"
    /// One row per press the state machine refused (D-01b).
    case dictationPressRefused = "dictation.press_refused"
    case memoryReview = "memory.review"
    case knowledgeAsk = "knowledge.ask"
}

/// The model or engine that produced a pass.
enum UsageProvider: String, Codable, Sendable, CaseIterable {
    case appleFM
    case llama
    case openrouter
    case openaiCompatible
    case codex
    case acp
    case needle
    case parakeet
    case appleSpeech
    case s1mini
    case rules
    case diarizer
}

/// Why a model pass failed, in the few classes a summary can group by.
enum UsageErrorClass: String, Codable, Sendable, CaseIterable {
    case timeout
    case modelUnavailable
    case loadFailed
    case contextTooSmall
    case inputTooLong
    case rateLimited
    case network
    case parse
    case cutOff
    case cancelled
    case permission
    case other

    /// Best-effort mapping from a thrown error. `ModelPassRecorder.fail` calls this, and
    /// hand-off sites call it for the errors their own seams throw.
    static func classify(_ error: Error) -> UsageErrorClass {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .network
            }
        }
        if let llama = error as? LlamaError {
            switch llama {
            case .modelMissing: return .modelUnavailable
            case .modelLoadFailed, .modelUnopenable, .contextLoadFailed, .notLoaded:
                return .loadFailed
            case .inputTooLong: return .inputTooLong
            case .decodeFailed, .tokenizationFailed, .samplerFailed: return .other
            case .grammarInvalid: return .parse
            }
        }
        if let openRouter = error as? OpenRouterError {
            switch openRouter {
            case .missingKey, .missingModel: return .modelUnavailable
            case .invalidResponse: return .parse
            case .keychain: return .other
            case .http(429, _): return .rateLimited
            case .http(let status, _): return status >= 500 ? .network : .other
            case .speedProbe: return .other
            case .cutOff: return .cutOff
            case .visionBlocked: return .permission
            }
        }
        if let localServer = error as? LocalServerError {
            switch localServer {
            case .noModel: return .modelUnavailable
            case .emptyAnswer, .unreadable: return .parse
            case .http(_, let status): return status == 429 ? .rateLimited : .network
            case .server: return .other
            case .needsVision: return .permission
            }
        }
        if let handoff = error as? CodexComputerUse.HandoffError {
            switch handoff {
            case .notReady: return .modelUnavailable
            case .declined: return .permission
            case .timedOut: return .timeout
            case .couldNotStart: return .modelUnavailable
            case .failed: return .other
            }
        }
        if let agent = error as? AgentError {
            switch agent {
            case .contextTooSmall: return .contextTooSmall
            case .permissionDenied, .needsPermission: return .permission
            case .cancelled: return .cancelled
            case .unknownTool, .missingArgument, .noProposals, .emptyTranscript,
                 .disabled, .notSignedIn, .noProvider, .noIntegration, .notFound:
                return .other
            case .backendUnavailable, .acpHandshakeUnavailable: return .modelUnavailable
            }
        }
        return .other
    }
}

/// Why a pass ran on a model other than the one its role named.
enum UsageFallback: String, Codable, Sendable, CaseIterable {
    case modelUnavailable
    case loadFailed
    case noKey
    case consent
    case busy
    case roleUnanswerable
    case preferredOverride
}

/// The correlation ids of one pass, as read from the caller's context.
struct UsageCorrelation: Sendable, Equatable {
    var turnID: UUID?
    var conversationID: UUID?
    var workID: UUID?
    var revision: Int?
    var meetingID: UUID?
    var dictationRunID: UUID?
    var scheduleID: UUID?

    init(
        turnID: UUID? = nil,
        conversationID: UUID? = nil,
        workID: UUID? = nil,
        revision: Int? = nil,
        meetingID: UUID? = nil,
        dictationRunID: UUID? = nil,
        scheduleID: UUID? = nil
    ) {
        self.turnID = turnID
        self.conversationID = conversationID
        self.workID = workID
        self.revision = revision
        self.meetingID = meetingID
        self.dictationRunID = dictationRunID
        self.scheduleID = scheduleID
    }
}
