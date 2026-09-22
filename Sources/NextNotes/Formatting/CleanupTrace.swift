import Foundation

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

    /// The model did not answer at all — unavailable, timed out, refused, not downloaded.
    func noteModelFailed(reason: String, seconds: Double) {
        mutate {
            $0.modelRan = $0.modelRan ?? false
            $0.guardVerdict = $0.guardVerdict ?? "not reached"
            $0.fallbackReason = $0.fallbackReason ?? reason
            $0.modelSeconds = ($0.modelSeconds ?? 0) + seconds
        }
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
    /// `accepted`, `rejected`, or `not reached`.
    var guardVerdict: String?
    /// Plain reason the model's answer was not used: a guard rejection, a timeout, an
    /// unavailable model.
    var fallbackReason: String?

    /// How many sentence groups a long transcript was split into. 1 for everything normal.
    var chunks: Int?

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

    var seconds: Double?
    var modelSeconds: Double?

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
