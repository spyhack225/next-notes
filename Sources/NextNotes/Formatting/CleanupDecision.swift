import Foundation

/// Which Stage B model the user (or a caller) asked for.
///
/// Settings still only offers Apple and S1-mini. `qwen` is a seam for a later picker —
/// `CleanupRouter` never selects it from `CleanupEngineChoice`, and
/// `QwenCleanupFormatter` must not announce itself to `LlamaBackend`'s cleanup gate.
enum CleanupSemanticEngine: String, Sendable, Equatable {
    case apple
    case s1Mini
    case qwen

    var displayName: String {
        switch self {
        case .apple: "Apple Foundation Model"
        case .s1Mini: "S1-mini"
        case .qwen: "Qwen"
        }
    }

    /// S1-mini has no prompt. A target profile and the on-screen name list cannot reach it.
    var acceptsInstructions: Bool { self != .s1Mini }
}

/// Whether Stage B runs at all.
enum CleanupStage: Sendable, Equatable {
    /// Stage A was enough. No model is invoked.
    case rules
    /// Stage A ran, then this engine.
    case semantic(CleanupSemanticEngine)
}

/// Why the router skipped or reached for a model.
enum CleanupReason: String, Sendable, Equatable {
    case empty
    case shortAndClean
    case long
    case disfluent
    case selfCorrection
    case stutter
    case grammar
    case unpunctuated
    case spokenList
    /// The transcript plausibly names a file, folder or tab visible in the target app, and the
    /// engine takes instructions. Only a model can turn the spoken name into the reference.
    case namesScreenItem
    /// Stage B was warranted but skipped because the machine is under load and the user
    /// asked for that (`Settings.cleanupSkipsModelWhenBusy`).
    case deferredUnderPressure

    var logLabel: String {
        switch self {
        case .empty: "empty"
        case .shortAndClean: "short and clean"
        case .long: "long"
        case .disfluent: "disfluent"
        case .selfCorrection: "self-correction"
        case .stutter: "stutter"
        case .grammar: "grammar"
        case .unpunctuated: "unpunctuated"
        case .spokenList: "spoken list"
        case .namesScreenItem: "names something on screen"
        case .deferredUnderPressure: "deferred under compute pressure"
        }
    }
}

/// Public load signals the cleanup router can see without private GPU / ANE APIs.
///
/// Live sampling covers `DispatchSource` memory pressure, `ProcessInfo` thermal /
/// low-power, and `ComputeScheduler` occupancy (`.realtimeASR` / `.background` for
/// notes). Self-tests may still inject those occupancy bits via overlays.
struct CleanupComputePressure: Sendable, Equatable {
    var memoryWarning: Bool
    var thermalElevated: Bool
    var lowPower: Bool
    /// Scheduler currently holds, queues, or parks a `realtimeASR` job.
    var realtimeASRBusy: Bool
    /// Notes model is loading or generating (scheduler `.background` occupancy).
    var notesBusy: Bool

    var isUnderPressure: Bool {
        memoryWarning || thermalElevated || lowPower || realtimeASRBusy || notesBusy
    }

    static let idle = CleanupComputePressure(
        memoryWarning: false,
        thermalElevated: false,
        lowPower: false,
        realtimeASRBusy: false,
        notesBusy: false
    )

    /// Test / overlay constructor. Any true flag marks the system under pressure.
    static func simulated(
        memoryWarning: Bool = false,
        thermalElevated: Bool = false,
        lowPower: Bool = false,
        realtimeASRBusy: Bool = false,
        notesBusy: Bool = false
    ) -> CleanupComputePressure {
        CleanupComputePressure(
            memoryWarning: memoryWarning,
            thermalElevated: thermalElevated,
            lowPower: lowPower,
            realtimeASRBusy: realtimeASRBusy,
            notesBusy: notesBusy
        )
    }
}

/// The policy result for one transcript: rules only, or rules then the chosen engine.
struct CleanupDecision: Sendable, Equatable {
    let stage: CleanupStage
    /// The engine that would run if Stage B is needed. Kept even on a rules-only
    /// decision so a log line can say which model was skipped.
    let engine: CleanupSemanticEngine
    let reasons: [CleanupReason]
    let wordCount: Int
    /// Snapshot that shaped this decision. Idle when pressure was not considered.
    let pressure: CleanupComputePressure

    init(
        stage: CleanupStage,
        engine: CleanupSemanticEngine,
        reasons: [CleanupReason],
        wordCount: Int,
        pressure: CleanupComputePressure = .idle
    ) {
        self.stage = stage
        self.engine = engine
        self.reasons = reasons
        self.wordCount = wordCount
        self.pressure = pressure
    }

    var usesModel: Bool {
        if case .semantic = stage { return true }
        return false
    }

    var logLine: String {
        let labels = reasons.map(\.logLabel).joined(separator: ", ")
        switch stage {
        case .rules:
            return "cleanup router · rules · \(wordCount) words · \(labels)"
        case .semantic(let engine):
            return "cleanup router · semantic \(engine.rawValue) · \(wordCount) words · \(labels)"
        }
    }
}
