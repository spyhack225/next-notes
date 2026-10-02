import Foundation

/// Records exactly one `UsageRecord` for one model pass (P0-20a).
///
/// The call-site pattern is the same as `LatencyCorrelation`: an unstructured `Task { }`
/// created inside a provider's streaming scope inherits the task-local, so the provider can
/// report counts when its stream ends even though the caller created it earlier. The row is
/// written once, from `finish`, and only after the caller has had the chance to add the
/// tools a planner round proposed and ran.
///
/// A pass's `totalMs` must not swallow tool execution or an approval wait: a planner round
/// calls `noteModelEnd()` the moment its stream ends, and `finish` then reports that frozen
/// time even though the calls it lists ran afterwards.
final class ModelPassRecorder: @unchecked Sendable {
    @TaskLocal static var current: ModelPassRecorder?

    /// Correlation for a pass whose call site cannot thread ids through directly. A routine's
    /// model is built by an environment seam that never sees the schedule, so
    /// `ScheduledRunner` installs the schedule id here and `ProviderMemoryReviewModel` reads
    /// it when it builds the recorder.
    @TaskLocal static var correlation: UsageCorrelation?

    private let feature: UsageFeature
    private let pass: String
    private let round: Int?
    private let provider: any LLMProvider
    private let ids: UsageCorrelation
    private let requestedRole: ModelRole?
    private let log: UsageLog
    private let startedAt = ContinuousClock.now
    private let lock = NSLock()

    private var endedAt: ContinuousClock.Instant?
    private var firstTokenAt: ContinuousClock.Instant?
    private var warm: Bool?
    private var loadMs: Int?
    private var promptTokens: Int?
    private var cachedTokens: Int?
    private var completionTokens: Int?
    private var reasoningTokens: Int?
    private var countsEstimated: Bool?
    private var reportedFinishReason: String?
    private var proposedToolIDs: [String] = []
    private var toolRuns: [UsageToolRun] = []
    private var errorClass: UsageErrorClass?
    private var errorMessage: String?
    private var fallbackReason: UsageFallback?
    private var counts: [String: Int] = [:]
    private var finished = false

    init(
        feature: UsageFeature,
        pass: String,
        provider: any LLMProvider,
        round: Int? = nil,
        ids: UsageCorrelation,
        requestedRole: ModelRole? = nil,
        log: UsageLog = .shared
    ) {
        self.feature = feature
        self.pass = pass
        self.provider = provider
        self.round = round
        self.ids = ids
        self.requestedRole = requestedRole
        self.log = log
    }

    /// The first call wins: the trace marks the first visible text, not the first report.
    func noteFirstToken() {
        lock.lock()
        defer { lock.unlock() }
        if firstTokenAt == nil { firstTokenAt = .now }
    }

    /// Whether this pass paid a model load, and how long that load took.
    func noteLoad(warm: Bool, ms: Int?) {
        lock.lock()
        defer { lock.unlock() }
        self.warm = warm
        if let ms { self.loadMs = ms }
    }

    /// Reports measured or estimated counts. Only the fields that are present replace what
    /// an earlier report set, so a usage object and a finish reason can arrive separately.
    func report(
        promptTokens: Int?,
        cachedTokens: Int?,
        completionTokens: Int?,
        reasoningTokens: Int?,
        finishReason: String?,
        estimated: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let promptTokens { self.promptTokens = promptTokens }
        if let cachedTokens { self.cachedTokens = cachedTokens }
        if let completionTokens { self.completionTokens = completionTokens }
        if let reasoningTokens { self.reasoningTokens = reasoningTokens }
        if let finishReason { self.reportedFinishReason = finishReason }
        if promptTokens != nil || cachedTokens != nil || completionTokens != nil
            || reasoningTokens != nil {
            self.countsEstimated = estimated
        }
    }

    /// P0-17's stream summary, for the providers that decode a `usage` object.
    func report(openRouter usage: OpenRouterUsage?) {
        guard let usage else { return }
        report(
            promptTokens: usage.promptTokens,
            cachedTokens: usage.cachedTokens,
            completionTokens: usage.completionTokens,
            reasoningTokens: usage.reasoningTokens,
            finishReason: nil,
            estimated: false)
    }

    /// The canonical tool ids this pass proposed, in the order the model wrote them.
    func proposed(_ toolIDs: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for id in toolIDs where !proposedToolIDs.contains(id) {
            proposedToolIDs.append(id)
        }
    }

    /// One tool call that ran inside this pass, with execution time only.
    func executed(_ run: UsageToolRun) {
        lock.lock()
        defer { lock.unlock() }
        toolRuns.append(run)
    }

    /// Merges named counters into the row's `counts`.
    func noteCounts(_ counts: [String: Int]) {
        lock.lock()
        defer { lock.unlock() }
        self.counts.merge(counts) { _, new in new }
    }

    /// Why this pass ran on a model other than the one its role named.
    func fellBack(_ reason: UsageFallback) {
        lock.lock()
        defer { lock.unlock() }
        fallbackReason = reason
    }

    /// The exact instant the model pass ended, called before tool execution begins. Without
    /// it a planner round's `totalMs` would include every tool it ran.
    func noteModelEnd() {
        lock.lock()
        defer { lock.unlock() }
        if endedAt == nil { endedAt = .now }
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        errorClass = UsageErrorClass.classify(error)
        errorMessage = error.localizedDescription
    }

    /// For a failure a caller only has text for (a stream that reported its own error).
    func fail(message: String) {
        lock.lock()
        defer { lock.unlock() }
        if errorClass == nil { errorClass = .other }
        if errorMessage == nil { errorMessage = message }
    }

    /// Writes one row once; later calls are ignored.
    func finish(reason: String) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let ended = endedAt ?? .now
        let totalMs = Self.milliseconds(startedAt.duration(to: ended))
        let ttftMs = firstTokenAt.map { Self.milliseconds(startedAt.duration(to: $0)) }
        let finishReason = reportedFinishReason ?? reason
        let tokensPerSecond: Double? = {
            guard let completionTokens, let ttftMs, totalMs - ttftMs > 0 else { return nil }
            return Double(completionTokens) / (Double(totalMs - ttftMs) / 1_000)
        }()
        let row = UsageRecord(
            v: 1,
            id: UUID(),
            ts: Date(),
            feature: feature.rawValue,
            pass: pass,
            round: round,
            provider: Self.usageProvider(for: provider.id).rawValue,
            modelID: provider.displayModelName,
            locality: provider.id == .openRouter ? "cloud" : "local",
            requestedRole: requestedRole?.rawValue,
            requestedModel: requestedRole == nil ? nil : provider.displayModelName,
            fallbackReason: fallbackReason?.rawValue,
            warm: warm,
            loadMs: loadMs,
            promptTokens: promptTokens,
            cachedTokens: cachedTokens,
            completionTokens: completionTokens,
            reasoningTokens: reasoningTokens,
            countsEstimated: countsEstimated,
            ttftMs: ttftMs,
            totalMs: totalMs,
            tokensPerSec: tokensPerSecond,
            finishReason: finishReason,
            truncated: finishReason == "length",
            toolsProposed: proposedToolIDs.isEmpty ? nil : proposedToolIDs,
            toolsExecuted: toolRuns.isEmpty ? nil : toolRuns,
            errorClass: errorClass?.rawValue,
            errorMessage: errorMessage.map(UsageLog.sanitise),
            audioSeconds: nil,
            realtimeFactor: nil,
            stages: nil,
            counts: counts.isEmpty ? nil : counts,
            turnID: ids.turnID,
            conversationID: ids.conversationID,
            workID: ids.workID,
            revision: ids.revision,
            meetingID: ids.meetingID,
            dictationRunID: ids.dictationRunID,
            scheduleID: ids.scheduleID
        )
        lock.unlock()
        log.record(row)
    }

    /// The `UsageProvider` raw value for a provider kind.
    static func usageProvider(for id: LLMProviderID) -> UsageProvider {
        switch id {
        case .appLLM: .llama
        case .appleFoundation: .appleFM
        case .openRouter: .openrouter
        case .localServer: .openaiCompatible
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(0, Int(milliseconds.rounded()))
    }
}

/// Times one tool call's execution, excluding anything a person waited on (P0-20a).
///
/// The planner installs one of these around each `AgentToolExecutor.run`; the executor's
/// post-approval `fire` closure is what calls `begin`, so the `ms` a row carries is the
/// execution alone and never the minutes an approval card sat on screen.
final class ToolExecutionTimer: @unchecked Sendable {
    @TaskLocal static var current: ToolExecutionTimer?

    private let lock = NSLock()
    private var startedAt: ContinuousClock.Instant?
    private var endedAt: ContinuousClock.Instant?

    /// The first instant of the real call, after any approval. First call wins.
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        if startedAt == nil { startedAt = .now }
    }

    /// The tool returned or threw.
    func end() {
        lock.lock()
        defer { lock.unlock() }
        if startedAt != nil, endedAt == nil { endedAt = .now }
    }

    /// Execution milliseconds; nil when the call never reached the post-approval path (a
    /// refusal, a missing argument), so the caller can fall back to the whole call's time.
    var executionMs: Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAt, let endedAt else { return nil }
        return ModelPassRecorder.milliseconds(startedAt.duration(to: endedAt))
    }
}
