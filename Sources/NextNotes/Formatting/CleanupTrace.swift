import Foundation

/// What happened to one sentence group of a chunked pass, in the order a person would
/// rank them: a group the model tidied is a group the user got, and a group that was not
/// reached is a group left as spoken. (D-08.)
enum CleanupGroupVerdict: String {
    case accepted
    case partlyAccepted = "partly accepted"
    case rejected
    case notReached = "not reached"

    /// Bigger is worse. The run-level `guardVerdict` is the worst of a chunked pass's
    /// groups, because a run that lost a group must not report the groups it kept.
    var rank: Int {
        switch self {
        case .accepted: return 0
        case .partlyAccepted: return 1
        case .rejected: return 2
        case .notReached: return 3
        }
    }

    /// The worse of two recorded verdicts, tolerating a value this build does not know (an
    /// old row, or a hand-edited one): anything unrecognised is treated as not reached,
    /// which is the answer that never hides a lost group.
    static func worse(_ a: String?, _ b: String?) -> String? {
        guard let b else { return a }
        guard let a else { return b }
        let rankA = CleanupGroupVerdict(rawValue: a)?.rank ?? 3
        let rankB = CleanupGroupVerdict(rawValue: b)?.rank ?? 3
        return rankA >= rankB ? a : b
    }
}

/// What one cleanup pass actually did, recorded as it happens.
///
/// ## Why this exists
///
/// "Check the dictation logs and you will see the model does no grammar" was not a question
/// anyone could answer from `runs.jsonl`, because that file stores exactly one string: the
/// text that was typed. Whether the model ran, which model it was, whether its answer was
/// thrown away by `CleanupGuard`, whether it timed out and fell back to the rules pass,
/// whether grammar was even switched on — none of it survived the run. Every one of those is
/// a different bug with the same symptom, so the first fix had to be that they stop looking
/// alike.
///
/// A mutable class rather than a return value because the pass is a chain of formatters
/// behind a `Sendable` protocol with a fixed signature, and threading a result back out of
/// `format(_:)` would have changed that protocol for every implementer. The box is handed
/// down and written into; the controller reads it once at the end.
///
/// Nothing here is on the hot path in any meaningful sense — a handful of string writes
/// behind one lock, per dictation.
final class CleanupTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var record = CleanupRecord()

    init() {}

    /// The finished record. Safe to call once the pass has returned.
    var snapshot: CleanupRecord {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    private func mutate(_ body: (inout CleanupRecord) -> Void) {
        lock.lock()
        body(&record)
        lock.unlock()
    }

    // MARK: - Written by the router

    func noteInput(raw: String, afterRules: String) {
        mutate {
            $0.rawText = raw
            $0.ruleText = afterRules
        }
    }

    func noteSettings(
        engine: String,
        fixesGrammar: Bool,
        formatsStructure: Bool,
        targetName: String,
        targetRenders: [String]
    ) {
        mutate {
            $0.engine = engine
            $0.fixesGrammar = fixesGrammar
            $0.formatsStructure = formatsStructure
            $0.targetName = targetName
            $0.targetRenders = targetRenders
        }
    }

    func noteRoute(_ route: String, reasons: [String]) {
        mutate {
            $0.route = route
            $0.reasons = reasons
        }
    }

    func noteChunks(_ count: Int) {
        mutate { $0.chunks = count }
    }

    /// How many sentence groups the key-up pass took from the work done while the key was
    /// still down, and why it took none of them. (D-12.)
    ///
    /// Both nil on every run whose hold closed no group, which is most short dictations and
    /// every pass outside a live hold. A zero with no reason is a hold whose sentences were
    /// tidied during the hold and then not needed at all.
    func notePrecleanedGroups(_ count: Int) {
        mutate { $0.precleanedGroups = count }
    }

    /// Nonempty formatter answers available when the head is selected. This may
    /// include a formatter's own fallback; it is not a model-quality verdict.
    func notePrecleanAnsweredGroups(_ count: Int) {
        mutate { $0.precleanAnsweredGroups = count }
    }

    func notePrecleanFallback(_ reason: String) {
        mutate { $0.precleanFallback = $0.precleanFallback ?? reason }
    }

    func noteStructure(markersSeen: Bool, applied: [SpokenStructure.Kind]) {
        mutate {
            $0.structureMarkersSeen = markersSeen
            $0.structureApplied = applied.map(\.rawValue)
        }
    }

    /// What laid the text out: the model's plan, this app's rules, or nothing.
    ///
    /// Three outcomes that look identical in every other log the app writes, and the reason
    /// the 2026-09-20 dictation took a day to explain. "The model was never asked" and "the
    /// model answered something that did not validate" lead to opposite fixes.
    func noteStructurePlan(model: String, seconds: Double, rejection: String?) {
        mutate {
            $0.structurePlanModel = model
            $0.structurePlanSeconds = seconds
            $0.structurePlanRejected = rejection
        }
    }

    /// Whether the layout pass ran on a session staged at key-down. Nil when no plan
    /// was asked for, or the planner does not report it. (D-01a.)
    func noteStructurePlanPrewarmed(_ used: Bool?) {
        mutate { if let used { $0.structurePlanPrewarmed = used } }
    }

    func noteStructureSource(_ source: String) {
        mutate { $0.structureSource = source }
    }

    /// Why this run came out with no structure in it. Written only on a run where none was
    /// applied, and first-writer-wins so the earliest and most specific reason survives.
    func noteNoStructure(_ reason: String) {
        mutate { $0.noStructureReason = $0.noStructureReason ?? reason }
    }

    func noteOutput(_ text: String, seconds: Double) {
        mutate {
            $0.cleanedText = text
            $0.seconds = seconds
        }
    }

    // MARK: - Written by the model formatters

    /// The model answered and the guard let it through.
    ///
    /// A long transcript is several calls, so this can be written more than once. The verdict
    /// sticks on the *worse* outcome: three good groups and one rejected one is a run where
    /// something was thrown away, and a record that said "accepted" would be hiding the only
    /// part of it worth reading.
    func noteModelAccepted(seconds: Double) {
        mutate {
            $0.modelRan = true
            if $0.guardVerdict == nil { $0.guardVerdict = "accepted" }
            $0.modelSeconds = ($0.modelSeconds ?? 0) + seconds
        }
    }

    /// The transcript was long enough that the tail of it was left as spoken rather than
    /// risk the whole pass missing the controller's deadline.
    func noteTruncated(reason: String) {
        mutate { $0.fallbackReason = $0.fallbackReason ?? reason }
    }

    /// The model answered and the guard threw the answer away. The single most important
    /// line in this file: it is indistinguishable from "the model changed nothing" in every
    /// other log the app writes.
    func noteModelRejected(reason: String, seconds: Double) {
        mutate {
            $0.modelRan = true
            $0.guardVerdict = "rejected"
            $0.fallbackReason = $0.fallbackReason ?? reason
            $0.modelSeconds = ($0.modelSeconds ?? 0) + seconds
        }
    }

    /// The model answered, the guard turned the answer down as a whole, and the sentences
    /// that were actually at fault were put back as spoken. The rest of the repair stands.
    ///
    /// Its own verdict rather than "rejected", because the two lead to opposite conclusions
    /// about a run: "rejected" means nothing the model did survived.
    func noteModelSalvaged(reason: String, seconds: Double) {
        mutate {
            $0.modelRan = true
            $0.guardVerdict = "partly accepted"
            $0.fallbackReason = $0.fallbackReason ?? reason
            $0.modelSeconds = ($0.modelSeconds ?? 0) + seconds
        }
    }

    /// Whether any model call in this run used a session staged at key-down.
    /// OR-accumulated across chunks: true when the prewarm paid off at least once.
    /// Nil when no model ran. The 0.6s-vs-4s spread on short dictations is the
    /// question this answers.
    func noteSessionPrewarmed(_ used: Bool) {
        mutate { $0.sessionPrewarmed = ($0.sessionPrewarmed ?? false) || used }
    }

    /// The warmth the per-call budget was computed for — `.staged` when a key-down
    /// session served the call, otherwise the process's warmth at that moment. Last
    /// writer wins across chunked runs, like `sessionPrewarmed`'s per-call values.
    /// (D-07.)
    func noteAssumedWarmth(_ warmth: Warmth) {
        mutate { $0.assumedWarmth = warmth.rawValue }
    }

    /// The model did not answer at all — unavailable, timed out, refused, not downloaded.
    func noteModelFailed(reason: String, seconds: Double) {
        mutate {
            $0.modelRan = $0.modelRan ?? false
            $0.guardVerdict = $0.guardVerdict ?? "not reached"
            $0.fallbackReason = $0.fallbackReason ?? reason
            $0.modelSeconds = ($0.modelSeconds ?? 0) + seconds
        }
    }

    /// Which engine actually produced (or was handed) this pass's text — `miniCPM`,
    /// `apple` — accumulated in first-use order across chunks. The settings' `engine`
    /// says what was *chosen*; this says what *ran*, which is what the usage row files.
    func noteEngineUsed(_ engine: String) {
        mutate {
            var used = $0.enginesUsed ?? []
            if !used.contains(engine) { used.append(engine) }
            $0.enginesUsed = used
        }
    }

    /// Whether the cleanup model's weights were already resident when the pass asked.
    /// False on any chunk wins: one cold group is a cold run.
    func noteCleanupModelResident(_ resident: Bool) {
        mutate { $0.cleanupModelResident = ($0.cleanupModelResident ?? true) && resident }
    }

    /// Exact counts from the in-process tokenizer for a local cleanup pass, summed across
    /// chunks.
    func noteTokens(prompt: Int, cached: Int, completion: Int) {
        mutate {
            $0.promptTokens = ($0.promptTokens ?? 0) + prompt
            $0.cachedTokens = ($0.cachedTokens ?? 0) + cached
            $0.completionTokens = ($0.completionTokens ?? 0) + completion
        }
    }

    /// One local-model attempt, whatever became of it — including the attempts that never
    /// produced a token. A timed-out pass used to leave only "ran out of time" behind, which
    /// could not say whether it waited on a parked lane, re-read a 1,300-token prompt or
    /// paged 1.5 GB of weights back in. Appended in call order; a chunked run has several.
    func noteLocalAttempt(_ attempt: CleanupLocalAttempt) {
        mutate { $0.localAttempts = ($0.localAttempts ?? []) + [attempt] }
    }

    // MARK: - One row per sentence group (D-08)

    /// Whether *this* group ran on a session staged for it. Filed before the call, like the
    /// run-level bit, so a group that never answers still says whether it was prewarmed.
    func noteGroupPrewarmed(index: Int, _ used: Bool) {
        mutate {
            $0.groupPrewarmed = Self.row($0.groupPrewarmed, at: index, value: used, gap: false)
        }
    }

    /// One group's verdict and how long it took. The run-level writers still run, so the
    /// totals are unchanged; what this adds is the per-group row beside them, and the
    /// run-level *verdict* as the worst of them — a chunked pass that lost a group must not
    /// report the groups it kept, which is exactly what the last writer used to decide.
    func noteGroup(index: Int, verdict: String, seconds: Double) {
        mutate {
            $0.groupVerdicts = Self.row(
                $0.groupVerdicts, at: index, value: verdict, gap: CleanupGroupVerdict.notReached.rawValue
            )
            $0.groupSeconds = Self.row($0.groupSeconds, at: index, value: seconds, gap: 0)
            $0.guardVerdict = CleanupGroupVerdict.worse(verdict, $0.guardVerdict)
        }
    }

    /// The pass is over, so the reason can finally say how much of the dictation it covers.
    ///
    /// A per-group row answers "which group failed"; only here can the run say "one of two
    /// parts", which is what a person reads in the Settings panel. Skipped when the pass ran
    /// out of budget, because then the reason is the truncation and the count would be
    /// describing a different failure.
    func noteGroupsFinished(total: Int, truncated: Bool) {
        guard !truncated else { return }
        mutate {
            guard let verdicts = $0.groupVerdicts, let reason = $0.fallbackReason else { return }
            let failed = verdicts.filter { CleanupGroupVerdict(rawValue: $0) != .accepted }.count
            guard failed > 0 else { return }
            $0.fallbackReason = "\(failed) of \(total) parts could not be tidied: \(reason)"
        }
    }

    /// Grows an optional per-group array so index `at` exists, padding with `gap` for a
    /// group that has not reported yet.
    private static func row<T>(_ rows: [T]?, at index: Int, value: T, gap: T) -> [T] {
        var rows = rows ?? []
        while rows.count <= index { rows.append(gap) }
        rows[index] = value
        return rows
    }
}

/// The per-run snapshot filed beside the transcript.
///
/// Every field is optional and every key is decoded with `decodeIfPresent`, because
/// `runs.jsonl` already holds the user's whole history and a row written before this existed
/// must still load. `DictationRun` carries it as `cleanup`.
struct CleanupRecord: Codable, Sendable, Hashable {
    /// Straight out of the recogniser, before anything touched it.
    var rawText: String?
    /// After the deterministic rules pass, before any model.
    var ruleText: String?
    /// What was handed on to the dictionary and then typed.
    var cleanedText: String?

    /// `apple`, `s1Mini`, `appLLM` (`qwen` in runs recorded before the rename),
    /// or `rules` when no model was reached for.
    var engine: String?
    /// `rules` or `semantic`.
    var route: String?
    /// Why the router decided what it decided.
    var reasons: [String]?

    /// The two switches, as they actually were for this run.
    var fixesGrammar: Bool?
    var formatsStructure: Bool?

    /// Where the text was going, and what that app renders.
    var targetName: String?
    var targetRenders: [String]?

    /// Whether a model produced an answer at all.
    var modelRan: Bool?
    /// True when a key-down-staged session served at least one model call in this
    /// run. Nil when no model ran.
    var sessionPrewarmed: Bool?
    /// The warmth the timeout was budgeted against: `staged`, `warmProcess`, or `cold`.
    /// Nil on a run where no model call reached the budget. Old rows decode as nil.
    /// (D-07.)
    var assumedWarmth: String?
    /// `accepted`, `rejected`, or `not reached`.
    var guardVerdict: String?
    /// Plain reason the model's answer was not used: a guard rejection, a timeout, an
    /// unavailable model.
    var fallbackReason: String?

    /// How many sentence groups a long transcript was split into. 1 for everything normal.
    var chunks: Int?

    /// Sentence groups tidied while the key was still held and joined into the text that
    /// was typed (D-12). Nil when the hold closed none, and 0 with no
    /// `precleanFallback` when it did and the rules were enough on their own. Old rows
    /// decode as nil.
    var precleanedGroups: Int?
    /// Selected head groups whose formatter returned a nonempty answer before final
    /// selection. Includes formatter fallbacks, never proves accepted semantic repair.
    /// Nil in old records and for legacy heads without completion boxes.
    var precleanAnsweredGroups: Int?
    /// Why a hold's pre-cleaned groups could not be used: a sentence one of them was built
    /// from was revised by the speech model before the key came up. The whole dictation is
    /// then cleaned in one pass, as it always was. Nil on a run that never had a group to
    /// use, and on every row written before D-12.
    var precleanFallback: String?

    /// One entry per sentence group of a chunked pass, in transcript order: what happened
    /// to it, how long it took, and whether it ran on a session staged for it. Nil on a run
    /// that was not chunked, and on every row written before D-08.
    var groupVerdicts: [String]?
    var groupSeconds: [Double]?
    var groupPrewarmed: [Bool]?

    /// Whether spoken structure markers were still in the text at Stage C, and what was
    /// rendered from them.
    var structureMarkersSeen: Bool?
    var structureApplied: [String]?

    /// `model plan`, `rules`, or `none`. Which of the two layout passes produced the text.
    var structureSource: String?
    /// On a run with no structure at all, the one thing that stopped there being any:
    /// nothing was spoken, the layout pass was skipped, it ran out of time, or its answer
    /// was turned down and why. Nil on a run that *did* format something.
    var noStructureReason: String?
    /// Which model was asked for a layout plan, how long it took, and why its answer was not
    /// used. All three nil on a run where no plan was asked for at all.
    var structurePlanModel: String?
    var structurePlanSeconds: Double?
    var structurePlanRejected: String?
    /// Whether the layout pass ran on a session staged at key-down. Nil when no plan
    /// was asked for. Old rows decode as nil (every key here is `decodeIfPresent`).
    var structurePlanPrewarmed: Bool?

    var seconds: Double?
    var modelSeconds: Double?
    /// What actually ran (see `noteEngineUsed`). Nil on rows written before it existed.
    var enginesUsed: [String]?
    /// Whether the local cleanup model was resident when asked. Nil when it was never asked.
    var cleanupModelResident: Bool?
    /// Local cleanup token counts. Nil when no local model generated.
    var promptTokens: Int?
    var cachedTokens: Int?
    var completionTokens: Int?
    /// Every local-model attempt with its phase timing (see `CleanupLocalAttempt`). Nil
    /// when no local model was asked, and on rows written before it existed.
    var localAttempts: [CleanupLocalAttempt]?

    init() {}

    /// Did grammar repair actually have a chance to happen on this run?
    ///
    /// Three things have to be true at once and the user can only see one of them in
    /// Settings, which is the whole reason this is a computed property and not a flag.
    var grammarWasPossible: Bool {
        guard fixesGrammar ?? false, modelRan ?? false else { return false }
        // "partly accepted" is a run where some sentences were repaired and some were put
        // back as spoken. Grammar happened on that run, and reporting it as a run where
        // none did would be the same kind of untruth this record exists to end.
        return guardVerdict == "accepted" || guardVerdict == "partly accepted"
    }

    /// One plain-language line, for the Settings panel. No jargon: the person reading it
    /// does not know what a guard, an engine or a token is.
    var plainSummary: String {
        var parts: [String] = []
        if route == "rules" {
            parts.append("Tidied with quick rules only")
        } else if modelRan == true, guardVerdict == "accepted" {
            parts.append(fixesGrammar == true
                ? "Grammar and spelling checked"
                : "Punctuation tidied (grammar is off)")
        } else if modelRan == true, guardVerdict == "partly accepted", let reason = fallbackReason {
            parts.append("Mostly tidied \u{2014} \(reason)")
        } else if let reason = fallbackReason {
            parts.append("Left as spoken \u{2014} \(reason)")
        } else {
            parts.append("Tidied")
        }
        if let applied = structureApplied, !applied.isEmpty {
            let names = applied.compactMap { SpokenStructure.Kind(rawValue: $0)?.displayName }
            if !names.isEmpty {
                parts.append("formatted the \(Self.list(names)) you spoke")
            }
        } else if structureMarkersSeen == true {
            parts.append("the formatting you spoke was not applied")
            if let noStructureReason { parts.append(noStructureReason) }
        }
        if let seconds { parts.append(String(format: "%.1fs", seconds)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}

/// One local cleanup attempt, phase by phase, filed in `CleanupRecord.localAttempts`.
///
/// Numbers and fixed words only: no prompt, no transcript, no target. Milliseconds are
/// rounded integers so a `runs.jsonl` row stays short. Every timing field is nil when the
/// attempt never reached that phase, which is the point — a timed-out pass that stopped
/// in prefill and one that stopped in decode used to read alike.
struct CleanupLocalAttempt: Codable, Sendable, Hashable {
    /// `accepted`, `rejected`, `timedOut`, `failed`, `refused`, `pagedOut`, `notLoaded`.
    var outcome: String
    /// Why admission was refused, from `CleanupAdmissionRefused`'s fixed sentences.
    var refusal: String?
    /// How much of the weight file was in memory when the attempt asked, sampled with
    /// `mincore` (`WeightPageResidency`), in thousandths. `resident=true` used to mean only
    /// that the runtime held a pointer to mapped weights the kernel may already have evicted.
    var weightsResidentPermille: Int?
    /// Ask → lane granted.
    var admissionMs: Int?
    /// The furthest phase reached: `admitted`, `context`, `prefill`, `decode`, `done`.
    var phase: String?
    /// The context was created or grown for this pass, discarding every cached entry.
    var contextRebuilt: Bool?
    var promptTokens: Int?
    /// Prompt tokens the KV cache already held (prefix reuse).
    var reusedTokens: Int?
    /// Prompt tokens actually decoded by the time the attempt ended.
    var prefilledTokens: Int?
    var prefillMs: Int?
    /// Time parked at scheduler checkpoints behind more urgent work, after admission.
    var parkedMs: Int?
    /// Admission → first sampled token.
    var firstTokenMs: Int?
    var generatedTokens: Int?
    /// First token → last token.
    var decodeMs: Int?
    /// Ask → outcome, as the dictation saw it.
    var totalMs: Int

    init(outcome: String, totalSeconds: Double, refusal: String? = nil,
         weightsResidentPermille: Int? = nil) {
        self.outcome = outcome
        self.totalMs = Self.ms(totalSeconds)
        self.refusal = refusal
        self.weightsResidentPermille = weightsResidentPermille
    }

    /// Copies the live probe's counters in, as they stood when the attempt ended.
    mutating func apply(_ phases: CleanupPassProbe.Snapshot, admissionSeconds: Double?) {
        admissionMs = admissionSeconds.map(Self.ms)
        phase = phases.phase
        contextRebuilt = phases.contextRebuilt
        promptTokens = phases.promptTokens
        reusedTokens = phases.reusedTokens
        prefilledTokens = phases.prefilledTokens
        prefillMs = phases.prefillSeconds.map(Self.ms)
        parkedMs = Self.ms(phases.parkedSeconds)
        firstTokenMs = phases.firstTokenSeconds.map(Self.ms)
        generatedTokens = phases.generatedTokens
        decodeMs = phases.decodeSeconds.map(Self.ms)
    }

    static func ms(_ seconds: Double) -> Int { max(0, Int((seconds * 1_000).rounded())) }
}

/// Live phase counters for one local cleanup pass, written by `NotesModelRuntime` while it
/// runs and read by `MiniCPMCleanupFormatter` whenever the pass ends — including at its
/// timeout, while the native job is still finishing its current chunk. Lock-protected so the
/// runtime's actor and the formatter's task never need to meet to share it.
final class CleanupPassProbe: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var phase: String?
        var contextRebuilt: Bool?
        var promptTokens: Int?
        var reusedTokens: Int?
        var prefilledTokens: Int?
        var prefillSeconds: Double?
        var parkedSeconds: Double = 0
        var firstTokenSeconds: Double?
        var generatedTokens: Int?
        var decodeSeconds: Double?
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var admittedAt: ContinuousClock.Instant?
    private var firstTokenAt: ContinuousClock.Instant?

    init() {}

    var snapshot: Snapshot { lock.withLock { state } }

    /// When the lane was granted, or nil when it never was.
    var admittedInstant: ContinuousClock.Instant? { lock.withLock { admittedAt } }

    func admitted() {
        lock.withLock {
            if admittedAt == nil { admittedAt = .now }
            state.phase = "admitted"
        }
    }

    func noteContext(rebuilt: Bool) {
        lock.withLock {
            state.contextRebuilt = rebuilt
            state.phase = "context"
        }
    }

    func notePrefillStarted(promptTokens: Int, reused: Int) {
        lock.withLock {
            state.promptTokens = promptTokens
            state.reusedTokens = reused
            state.prefilledTokens = 0
            state.phase = "prefill"
        }
    }

    /// Cumulative prompt tokens decoded in this pass so far.
    func notePrefilled(_ decoded: Int) {
        lock.withLock { state.prefilledTokens = decoded }
    }

    func notePrefillFinished(seconds: Double) {
        lock.withLock { state.prefillSeconds = seconds }
    }

    func noteParked(seconds: Double) {
        lock.withLock { state.parkedSeconds += seconds }
    }

    func noteToken() {
        lock.withLock {
            let now = ContinuousClock.now
            if firstTokenAt == nil {
                firstTokenAt = now
                if let admittedAt {
                    state.firstTokenSeconds = Self.seconds(admittedAt.duration(to: now))
                }
                state.phase = "decode"
            }
            state.generatedTokens = (state.generatedTokens ?? 0) + 1
            if let firstTokenAt {
                state.decodeSeconds = Self.seconds(firstTokenAt.duration(to: now))
            }
        }
    }

    func noteDone() {
        lock.withLock { state.phase = "done" }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
