import Foundation

/// Two-stage dictation cleanup: deterministic rules first, then a model.
///
/// Every utterance pays Stage A (`RuleBasedFormatter`). Stage B is the engine the user
/// picked in Settings — Apple, or S1-mini when grammar is off — and by default it runs on
/// every transcript the rules pass leaves any text in.
///
/// It used to run only when the rules pass looked like it had left work behind, so a short,
/// tidy-looking sentence never reached a model. On real dictation that shortcut produced
/// text nobody could use: rules keep "acoustic dash echo dot md file" exactly as spoken,
/// leave a repeated clause in, and cannot fix a misheard word — and a short command is
/// precisely where one wrong word ruins it. So quality is the default and a four-word
/// sentence waits on the model again. `reasons` still records what the rules pass noticed,
/// so the log says why a model was needed even when it would have run anyway.
///
/// The one shortcut left is opt-in, `Settings.cleanupSkipsModelWhenBusy`. With it on, under
/// compute pressure (memory warning, thermal / low-power, or live scheduler occupancy for
/// realtime-ASR / notes `.background`) short and soft-only transcripts stay on rules so Stage
/// B does not fight the live path for GPU; a long transcript needing a hard repair still
/// reaches the engine. A transcript that names something on screen reaches an engine that
/// takes instructions even then: rules cannot write a file reference at all, so skipping the
/// model there loses the tag outright instead of merely roughening the text. The on-device
/// engine is never forced on.
///
/// S1-mini still takes no instructions. The router will not pretend a target profile or
/// the screen-name harvest can reach it. The on-device engine is constructible as a seam
/// and is never chosen from Settings; `AppLLMCleanupFormatter` must not call `beginCleanup()`.
struct CleanupRouter: TextFormatter {
    /// One spoken sentence, give or take. Only the opt-in busy shortcut reads it: at or under
    /// this, a transcript under pressure stays on rules when the user asked for speed.
    static let shortWordLimit = 20

    /// Reasons that are "hard" repairs: under pressure, a *short* transcript with only
    /// these still skips Stage B; a longer one may still reach the user's engine.
    private static let hardReasons: Set<CleanupReason> = [
        .grammar, .stutter, .selfCorrection
    ]

    private let rules: any TextFormatter
    private let semantic: any TextFormatter
    private let engine: CleanupSemanticEngine
    private let formatsLists: Bool
    private let targetRendersLists: Bool
    private let mentionsScreenName: Bool
    private let skipsModelWhenBusy: Bool
    private let pressureSample: @Sendable () async -> CleanupComputePressure
    /// Stage C. What the receiving app renders, so structure the speaker spoke is written in
    /// a syntax that app can show — and in plain text when it can show none.
    private let target: OutputProfile
    /// Per-run record, filed beside the transcript. Nil outside the live dictation path.
    private let trace: CleanupTrace?
    /// Stage D. Asks a model for a *layout* of the finished text — never for the text. Nil
    /// on a Mac with no instruction-following model, which is exactly the case Stage C's
    /// rules exist to cover.
    private let structurePlanner: (any StructurePlanning)?

    init(
        semantic: any TextFormatter,
        engine: CleanupSemanticEngine,
        rules: any TextFormatter = RuleBasedFormatter(),
        formatsLists: Bool = false,
        targetRendersLists: Bool = false,
        mentionsScreenName: Bool = false,
        skipsModelWhenBusy: Bool = false,
        target: OutputProfile = .plain(bundleID: "", displayName: "the focused app"),
        trace: CleanupTrace? = nil,
        structurePlanner: (any StructurePlanning)? = nil,
        pressureSample: @escaping @Sendable () async -> CleanupComputePressure = {
            await CleanupPressureProbe.sample()
        }
    ) {
        self.rules = rules
        self.semantic = semantic
        self.engine = engine
        self.formatsLists = formatsLists
        self.targetRendersLists = targetRendersLists
        self.mentionsScreenName = mentionsScreenName
        self.skipsModelWhenBusy = skipsModelWhenBusy
        self.target = target
        self.trace = trace
        self.structurePlanner = structurePlanner
        self.pressureSample = pressureSample
    }

    func format(_ raw: String) async -> String {
        let began = Date()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let afterRules = await rules.format(trimmed)
        trace?.noteInput(raw: trimmed, afterRules: afterRules)
        let decision = Self.decide(
            raw: trimmed,
            afterRules: afterRules,
            engine: engine,
            formatsLists: formatsLists,
            targetRendersLists: targetRendersLists,
            mentionsScreenName: mentionsScreenName,
            skipsModelWhenBusy: skipsModelWhenBusy,
            pressure: await pressureSample()
        )
        trace?.noteRoute(
            decision.usesModel ? "semantic" : "rules",
            reasons: decision.reasons.map(\.rawValue)
        )
        Log.speech.info("\(decision.logLine, privacy: .public)")

        // Stage C runs before Stage B as well as after it.
        //
        // Measured on Apple's on-device model, 2026-09-20: handed "quote … end quote" it
        // deleted both markers and wrote prose, so by the time the post-model pass looked
        // there was nothing left to render and the quotation the speaker asked for was
        // simply gone. Running first means the model is handed *structure* rather than
        // instructions it can eat, and the pass afterwards is idempotent on text that
        // already carries it. It is also what makes the "before" answer recordable: asking
        // the final text whether any structure was spoken answers "no" for a run where it
        // plainly was.
        let beforeModel = SpokenStructure.apply(
            to: afterRules,
            target: target,
            isEnabled: formatsLists
        )
        // Asked of the full scope whatever Stage C was allowed to render, because "did the
        // speaker speak structure" is a question about the speaker, not about this pass.
        let markersBeforeModel = SpokenStructure.containsMarkers(afterRules)

        // Stage D is started *here*, before Stage B is awaited, and finished after it.
        //
        // It used to run after the grammar pass had returned, which put its whole cost on
        // the end of a wait the user was already having: on 2026-09-20T20:47:25Z, 6.35 s in
        // the cleanup model and then a layout pass that was given three seconds, spent all
        // of them and timed out — 9.37 s for a forty-one second dictation that came out as
        // one paragraph. The two passes need nothing from each other. The layout pass asks
        // only where the sentence boundaries are, and the rules pass has already fixed
        // those; the grammar pass changes words inside sentences, which is a question the
        // layout pass never asks. So they overlap, and the plan is mapped onto the
        // grammar-cleaned sentences afterwards.
        let planSentences = SpokenStructure.sentenceSplit(beforeModel.text)
        var planTask: Task<StructurePlanOutcome, Never>?
        if let planner = structurePlanner, formatsLists,
           // Stage C already found the list, so there is nothing to ask about. The gate is
           // read here rather than after Stage B because that is when the decision has to
           // be made, and it is the *pre*-model answer for the same reason Stage C runs
           // twice: a model that ate the markers has not un-made the list it already made.
           beforeModel.applied.isEmpty,
           StructurePlan.isWorthPlanning(
               sentences: planSentences,
               wordCount: decision.wordCount,
               sawMarkers: markersBeforeModel
           ) {
            planTask = Task { await planner.plan(for: planSentences) }
        }

        var text: String
        switch decision.stage {
        case .rules:
            text = beforeModel.text
        case .semantic:
            if beforeModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = beforeModel.text
            } else {
                // Stage B sees the rules output, not the raw ASR: the model is repairing
                // what is left, and a timeout must keep that work (`KeepAsIsFormatter`
                // on Apple / on-device) rather than fall back through rules a second time.
                let answered = await semantic.format(beforeModel.text)
                // ...and if the model flattened the structure back into prose, the version
                // that had it wins. What the speaker asked for out loud is not the model's
                // to remove, and a pass that lets it go is the bug this stage exists for.
                if beforeModel.didChange,
                   SpokenStructure.renderedLineCount(answered)
                       < SpokenStructure.renderedLineCount(beforeModel.text) {
                    Log.speech.error("""
                        cleanup structure · \(self.engine.rawValue, privacy: .public) \
                        un-formatted spoken structure; keeping the formatted text
                        """)
                    trace?.noteTruncated(
                        reason: "the cleanup model undid the formatting you asked for, "
                            + "so the formatted version was kept"
                    )
                    text = beforeModel.text
                } else {
                    text = answered
                }
            }
        }

        // Stage C. Deterministic, and therefore the one stage every route reaches: the rules
        // route, the model route, and the fallback a rejected or timed-out model lands on.
        // That is the point of it — structure the speaker asked for out loud must not depend
        // on which engine happened to run, and before this it depended on nothing else.
        let structured = SpokenStructure.apply(
            to: text,
            target: target,
            isEnabled: formatsLists
        )
        // Applied before the model *or* after it. The second pass is a no-op on text the
        // first one already rendered, so reading only the second would file "nothing
        // formatted" on the runs where formatting worked perfectly.
        var laidOut = structured.text
        var applied = beforeModel.applied.isEmpty ? structured.applied : beforeModel.applied
        var source = applied.isEmpty ? "none" : "rules"

        // Stage D. The model is shown the finished text as numbered sentences and asked for
        // an arrangement — never for words.
        //
        // It runs only where Stage C found nothing, and that ordering is a measurement
        // rather than a preference. On the dictation this workstream started from, the
        // rules find all four items in no time at all and Apple's model finds three of them
        // in one and a half seconds; on four sentences of ordinary prose the model proposed
        // a two-item list that did not exist. Deterministic and right beats probabilistic
        // and nearly right, every time, for free. What the model is genuinely better at is
        // the case the rules decline: prose with no ordinal in it, where it supplies the
        // paragraph breaks, and enumerations announced without numbers at all.
        var planRejection: String?
        if let planTask, let planner = structurePlanner {
            let outcome = await planTask.value
            let sentences = SpokenStructure.sentenceSplit(text)
            planRejection = outcome.rejection
            if let plan = outcome.plan {
                // The plan was made against the rule-cleaned sentences; it is rendered
                // against the grammar-cleaned ones. Usually the same sentences with
                // different words in them, and where they are not, `remapped` either finds
                // the boundaries again or the plan is dropped. Never rendered against the
                // text the plan was made from — that would type back the version the
                // grammar pass had just repaired.
                let mapped = plan.remapped(from: planSentences, to: sentences)
                if mapped == nil {
                    planRejection = "the wording changed while the layout was being worked out"
                }
                if let mapped {
                    // Why a plan that arrived was not used, asked in the order the checks
                    // run so the record names the first thing that was wrong with it.
                    planRejection = planRejection
                        ?? mapped.rejection(sentenceCount: sentences.count)
                        ?? mapped.corroborationFailure(sentences: sentences)
                    if planRejection == nil, applied.isEmpty,
                       let rendered = mapped.rendered(sentences: sentences, target: target) {
                        if rendered.changed {
                            laidOut = rendered.text
                            applied = rendered.applied
                            source = "model plan"
                        } else {
                            planRejection = "the layout was the one the text already had"
                        }
                    } else if planRejection == nil, !applied.isEmpty {
                        // The rules found the list while the model was still thinking.
                        // Deterministic and already right wins, and the record says so
                        // rather than reporting a plan that was never consulted.
                        planRejection = "the rules had already laid the text out"
                    } else {
                        planRejection = planRejection ?? "the layout could not be rendered"
                    }
                }
            }
            trace?.noteStructurePlan(
                model: planner.planName,
                seconds: outcome.seconds,
                rejection: planRejection
            )
            if source != "model plan", let reason = planRejection {
                Log.speech.info("""
                    cleanup structure · layout plan not used \
                    (\(reason, privacy: .public))
                    """)
            }
        }
        trace?.noteStructureSource(source)

        let markersSeen = markersBeforeModel || structured.markersSeen
        trace?.noteStructure(markersSeen: markersSeen, applied: applied)
        if !applied.isEmpty {
            let names = applied.map(\.rawValue).joined(separator: ", ")
            Log.speech.info("cleanup structure · \(names, privacy: .public)")
        } else {
            // One field, in plain language, naming the *first* thing that stopped a layout
            // happening. Four outcomes that are four different bugs and that every log this
            // app writes used to render identically as an empty `structureApplied`.
            trace?.noteNoStructure(Self.whyNoStructure(
                markersSeen: markersSeen,
                planWasAsked: planTask != nil,
                planRejection: planRejection
            ))
            if markersSeen {
                Log.speech.error("""
                    cleanup structure · the speaker spoke structure and none was rendered \
                    (\(self.engine.rawValue, privacy: .public) may have removed the markers)
                    """)
            }
        }
        // Last of all, and deterministic: a model that put a bullet inside a numbered line
        // it was handed.
        laidOut = SpokenStructure.collapsingDoubledMarkers(laidOut)
        trace?.noteOutput(laidOut, seconds: Date().timeIntervalSince(began))
        return laidOut
    }

    /// Why this run has no structure in it, in one line a person can read.
    ///
    /// The 2026-09-20T20:47:25Z investigation took a day, and most of it was spent
    /// establishing which of four things had happened — the speaker said nothing
    /// list-shaped, the model was never asked, the model was asked and ran out of time, or
    /// the model answered and its answer was turned down. The record said `structureApplied:
    /// []` for all four. It now says which.
    static func whyNoStructure(
        markersSeen: Bool,
        planWasAsked: Bool,
        planRejection: String?
    ) -> String {
        if let planRejection {
            return "the layout pass was asked and its answer was not used: \(planRejection)"
        }
        if planWasAsked {
            return "the layout pass was asked and proposed no arrangement"
        }
        if markersSeen {
            return "the speaker spoke structure but the rules could not lay it out, "
                + "and the layout pass was not worth a model call on a dictation this short"
        }
        return "nothing in the dictation asked for a list, and the layout pass was skipped"
    }

    /// The engine a real hold would reach for, given today's Settings keys.
    ///
    /// Grammar repair is instruction-following work S1-mini cannot do. The live path
    /// already spent that budget on Apple alone rather than chaining the two; this
    /// mapping is that same rule, so the router does not reintroduce the stacked wait.
    static func preferredEngine(
        choice: CleanupEngineChoice,
        fixesGrammar: Bool
    ) -> CleanupSemanticEngine {
        switch choice {
        case .apple:
            return .apple
        case .s1Mini:
            return fixesGrammar ? .apple : .s1Mini
        }
    }

    /// How long one chunked call to this engine is allowed to take, read from the engine
    /// itself rather than restated here — `ChunkedFormatter` subtracts it from the whole
    /// pass's budget before starting a group, so the two numbers must not be able to drift.
    static func perCallTimeout(
        for engine: CleanupSemanticEngine
    ) -> @Sendable (String) -> Duration {
        switch engine {
        case .apple:
            return { FoundationModelFormatter.timeout(for: $0) }
        case .s1Mini, .appLLM:
            // The on-device engine has no separate ceiling; S1-mini's is the larger of the
            // two that do, which is the safe way to be wrong about it.
            return { S1MiniFormatter.timeout(for: $0) }
        }
    }

    /// Stage B formatter for a named engine. The on-device engine is here so a later picker
    /// can construct it; production never passes `.appLLM`.
    ///
    /// Apple and the on-device engine used as Stage B fall back to `KeepAsIsFormatter`: the input has
    /// already been through rules, and running `RuleBasedFormatter` again would undo
    /// nothing useful and could undo model work if this were ever chained further.
    /// S1-mini's own fallback stays rule-based — that type does not take one.
    ///
    /// `target` and `context` are forwarded only to engines that accept instructions.
    /// S1-mini discards both, on purpose.
    static func makeSemantic(
        _ engine: CleanupSemanticEngine,
        preferences: CleanupPreferences,
        fixesGrammar: Bool,
        target: OutputProfile,
        context: ScreenContext,
        trace: CleanupTrace? = nil
    ) -> any TextFormatter {
        switch engine {
        case .apple:
            return FoundationModelFormatter(
                preferences: preferences,
                fixesGrammar: fixesGrammar,
                target: target,
                context: context,
                fallback: KeepAsIsFormatter(),
                trace: trace
            )
        case .s1Mini:
            return S1MiniFormatter(preferences: preferences, trace: trace)
        case .appLLM:
            // Must not call LlamaBackend.beginCleanup — AppLLMCleanupFormatter is the
            // on-device notes model, and announcing it to the gate deadlocks the load.
            return AppLLMCleanupFormatter(
                preferences: preferences,
                fixesGrammar: fixesGrammar,
                target: target,
                context: context
            )
        }
    }

    /// Production wiring: Stage A plus the user's existing engine choice.
    static func production(
        choice: CleanupEngineChoice,
        preferences: CleanupPreferences,
        fixesGrammar: Bool,
        target: OutputProfile,
        context: ScreenContext,
        skipsModelWhenBusy: Bool,
        trace: CleanupTrace? = nil
    ) -> CleanupRouter {
        let engine = preferredEngine(choice: choice, fixesGrammar: fixesGrammar)
        // Long utterances go to the model in sentence groups rather than in one call that
        // misses its deadline and hands back the raw transcript. Below the threshold this
        // wrapper is one word count and one passthrough.
        let semantic = ChunkedFormatter(
            inner: makeSemantic(
                engine,
                preferences: preferences,
                fixesGrammar: fixesGrammar,
                target: target,
                context: context,
                trace: trace
            ),
            trace: trace,
            perCallTimeout: Self.perCallTimeout(for: engine)
        )
        let targetRendersLists = target.capabilities.contains(.bullets)
            || target.capabilities.contains(.numbered)
        trace?.noteSettings(
            engine: engine.rawValue,
            fixesGrammar: fixesGrammar,
            formatsStructure: preferences.formatsLists,
            targetName: target.displayName.isEmpty ? "the focused app" : target.displayName,
            targetRenders: target.sortedCapabilities.map(\.rawValue)
        )
        // Stage D only where there is a model that takes instructions and a switch that
        // asked for formatting. Apple's is the one that is already resident and already
        // warm; the on-device model can do this too (`LLMStructurePlanner`) but loading it costs
        // gigabytes and seconds inside a dictation somebody is waiting on, so it is a seam
        // rather than a default.
        let planner: (any StructurePlanning)? =
            preferences.formatsLists && FoundationModelFormatter.isAvailable
                ? AppleStructurePlanner()
                : nil
        return CleanupRouter(
            semantic: semantic,
            engine: engine,
            formatsLists: preferences.formatsLists,
            targetRendersLists: targetRendersLists,
            mentionsScreenName: context.mentionCount > 0,
            skipsModelWhenBusy: skipsModelWhenBusy,
            target: target,
            trace: trace,
            structurePlanner: planner
        )
    }

    /// Pure policy. `afterRules` is what would be injected if Stage B is skipped.
    ///
    /// Stage B runs on anything with text left in it, unless `skipsModelWhenBusy` is on and
    /// `pressure` is up: then short and soft-only ("borderline") transcripts stay on rules,
    /// while long transcripts that still need a hard repair, and any transcript that names
    /// something on screen, keep the caller's Stage B engine — never the on-device engine, never a forced
    /// upgrade.
    static func decide(
        raw: String,
        afterRules: String,
        engine: CleanupSemanticEngine,
        formatsLists: Bool = false,
        targetRendersLists: Bool = false,
        mentionsScreenName: Bool = false,
        skipsModelWhenBusy: Bool = false,
        pressure: CleanupComputePressure = .idle
    ) -> CleanupDecision {
        let cleaned = afterRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return CleanupDecision(
                stage: .rules,
                engine: engine,
                reasons: [.empty],
                wordCount: 0,
                pressure: pressure
            )
        }

        let wordCount = words(in: cleaned).count
        var issues: [CleanupReason] = []

        if wordCount > shortWordLimit { issues.append(.long) }
        if isDisfluent(raw) || isDisfluent(cleaned) { issues.append(.disfluent) }
        if hasSelfCorrection(raw) || hasSelfCorrection(cleaned) { issues.append(.selfCorrection) }
        if hasStutter(cleaned) { issues.append(.stutter) }
        if hasGrammarMarker(cleaned) { issues.append(.grammar) }
        if needsTerminalPunctuation(cleaned) { issues.append(.unpunctuated) }
        // No longer gated on the target rendering Markdown or on the engine taking
        // instructions. Stage C renders spoken structure in code, for every engine and for a
        // plain target too, so "this transcript contains a spoken list" is now simply true or
        // false rather than true-only-where-something-could-have-acted-on-it.
        if formatsLists, looksLikeSpokenList(cleaned) {
            issues.append(.spokenList)
        }
        // Only for an engine that can be told the names. S1-mini has no prompt to put them in,
        // so for it a mentioned name is not a reason for anything.
        if mentionsScreenName, engine.acceptsInstructions {
            issues.append(.namesScreenItem)
        }
        // Nothing the rules pass could see. Not a reason to skip the model any more — see the
        // type's doc — but still the true description of the transcript for the log line.
        if issues.isEmpty {
            issues = [.shortAndClean]
        }

        if skipsModelWhenBusy,
           pressure.isUnderPressure,
           !issues.contains(.namesScreenItem),
           shouldDeferUnderPressure(issues: issues, wordCount: wordCount) {
            var deferred = issues
            deferred.append(.deferredUnderPressure)
            return CleanupDecision(
                stage: .rules,
                engine: engine,
                reasons: deferred,
                wordCount: wordCount,
                pressure: pressure
            )
        }

        return CleanupDecision(
            stage: .semantic(engine),
            engine: engine,
            reasons: issues,
            wordCount: wordCount,
            pressure: pressure
        )
    }

    /// Soft / borderline under load, or any short transcript that would have taken a
    /// model, stays on rules. Long + hard still reaches Stage B.
    private static func shouldDeferUnderPressure(
        issues: [CleanupReason],
        wordCount: Int
    ) -> Bool {
        if wordCount <= shortWordLimit { return true }
        let hasHard = issues.contains { hardReasons.contains($0) }
        return !hasHard
    }
}

extension CleanupRouter {
    /// Short + clean must not invoke a model seam. A counting formatter is the
    /// model; the last printed line is `CLEANUP_ROUTER_OK` or `CLEANUP_ROUTER_FAILED`.
    ///
    /// Under simulated pressure, messy-but-short and soft-only borderline cases
    /// must also skip the model seam.
    ///
    /// Runs as `--selftest-cleanup-router`. Pure policy plus a counting seam, so it needs no
    /// model and no permission.
    @discardableResult
    static func runSelfTest() async -> Bool {
        var failures: [String] = []

        let s1 = preferredEngine(choice: .s1Mini, fixesGrammar: false)
        if s1 != .s1Mini {
            failures.append("preferredEngine(s1, grammar off) was \(s1), expected s1Mini")
        }
        let s1Grammar = preferredEngine(choice: .s1Mini, fixesGrammar: true)
        if s1Grammar != .apple {
            failures.append("preferredEngine(s1, grammar on) was \(s1Grammar), expected apple")
        }
        let apple = preferredEngine(choice: .apple, fixesGrammar: true)
        if apple != .apple {
            failures.append("preferredEngine(apple) was \(apple), expected apple")
        }

        let onDevice = makeSemantic(
            .appLLM,
            preferences: CleanupPreferences(tone: .balanced, formatsLists: true, context: .general),
            fixesGrammar: true,
            target: .plain(bundleID: "", displayName: "the focused app"),
            context: .empty
        )
        if !(onDevice is AppLLMCleanupFormatter) {
            failures.append("makeSemantic(.appLLM) did not return AppLLMCleanupFormatter")
        }

        struct Case {
            let id: String
            let input: String
            let engine: CleanupSemanticEngine
            var formatsLists = false
            var targetRendersLists = false
            var mentionsScreenName = false
            var skipsModelWhenBusy = false
            var pressure: CleanupComputePressure = .idle
            let expectModel: Bool
        }

        let underPressure = CleanupComputePressure.simulated(realtimeASRBusy: true)
        let notesPressure = CleanupComputePressure.simulated(notesBusy: true)
        let memoryPressure = CleanupComputePressure.simulated(memoryWarning: true)

        let messyShort = "the tests is passing on my machine but they was failing in ci yesterday"
        let longClean = "We finished the review this morning and everyone signed off on the plan. "
            + "The release is scheduled for Friday afternoon as discussed."
        let spokenList = "First milk. Second eggs. Third bread."
        let namesFile = "Open the acoustic echo file."

        let cases: [Case] = [
            // Quality by default: an idle Mac sends short, tidy text to the model too.
            Case(id: "short-clean", input: "The build is green.", engine: .apple, expectModel: true),
            Case(id: "short-raw", input: "hello", engine: .apple, expectModel: true),
            Case(id: "ship-it", input: "Ship it.", engine: .s1Mini, expectModel: true),
            Case(id: "question-stays-a-question", input: "what is the capital of france",
                 engine: .apple, expectModel: true),
            // Nothing left after the rules pass is still nothing to send.
            Case(id: "filler-only", input: "um uh", engine: .apple, expectModel: false),
            Case(id: "agreement", input: messyShort, engine: .apple, expectModel: true),
            Case(id: "self-correction",
                 input: "so um i need to send the report by friday no wait make that thursday",
                 engine: .apple, expectModel: true),
            Case(id: "stutter", input: "we we need to to check the the database connection again",
                 engine: .s1Mini, expectModel: true),
            Case(id: "long-clean", input: longClean, engine: .apple, expectModel: true),
            Case(id: "spoken-list", input: spokenList, engine: .apple,
                 formatsLists: true, targetRendersLists: true, expectModel: true),
            Case(id: "spoken-list-s1-still-cleans", input: spokenList, engine: .s1Mini,
                 formatsLists: true, targetRendersLists: true, expectModel: true),
            Case(id: "names-screen-item", input: namesFile, engine: .apple,
                 mentionsScreenName: true, expectModel: true),

            // A busy Mac with the setting off — the default — skips nothing.
            Case(id: "busy-setting-off-short-clean", input: "The build is green.", engine: .apple,
                 pressure: underPressure, expectModel: true),
            Case(id: "busy-setting-off-messy-short", input: messyShort, engine: .apple,
                 pressure: memoryPressure, expectModel: true),

            // Setting on: short and soft-only stay on rules while the Mac is busy.
            Case(id: "busy-short-clean", input: "The build is green.", engine: .apple,
                 skipsModelWhenBusy: true, pressure: underPressure, expectModel: false),
            Case(id: "busy-messy-short-asr", input: messyShort, engine: .apple,
                 skipsModelWhenBusy: true, pressure: underPressure, expectModel: false),
            Case(id: "busy-messy-short-notes",
                 input: "we we need to to check the the database connection again", engine: .apple,
                 skipsModelWhenBusy: true, pressure: notesPressure, expectModel: false),
            Case(id: "busy-messy-short-memory",
                 input: "so um i need to send the report by friday no wait make that thursday",
                 engine: .apple, skipsModelWhenBusy: true, pressure: memoryPressure, expectModel: false),
            Case(id: "busy-borderline-long-clean", input: longClean, engine: .apple,
                 skipsModelWhenBusy: true, pressure: underPressure, expectModel: false),
            Case(id: "busy-borderline-spoken-list", input: spokenList, engine: .apple,
                 formatsLists: true, targetRendersLists: true,
                 skipsModelWhenBusy: true, pressure: underPressure, expectModel: false),
            // Setting on and busy: long + hard still reaches the user's Stage B engine.
            Case(id: "busy-long-hard-still-semantic",
                 input: longClean.replacingOccurrences(of: "as discussed.", with: "as discussed, but ")
                    + "the tests is still red on main and they was failing all morning.",
                 engine: .apple, skipsModelWhenBusy: true, pressure: underPressure, expectModel: true),
            // Setting on and busy: a named file keeps the model, because rules cannot tag it.
            Case(id: "busy-names-screen-item", input: namesFile, engine: .apple,
                 mentionsScreenName: true, skipsModelWhenBusy: true, pressure: underPressure,
                 expectModel: true),
            // ...but S1-mini cannot use the names, so they buy it no exemption.
            Case(id: "busy-names-screen-item-s1", input: namesFile, engine: .s1Mini,
                 mentionsScreenName: true, skipsModelWhenBusy: true, pressure: underPressure,
                 expectModel: false),
        ]

        let rules = RuleBasedFormatter()
        for test in cases {
            let afterRules = await rules.format(test.input)
            let decision = decide(
                raw: test.input,
                afterRules: afterRules,
                engine: test.engine,
                formatsLists: test.formatsLists,
                targetRendersLists: test.targetRendersLists,
                mentionsScreenName: test.mentionsScreenName,
                skipsModelWhenBusy: test.skipsModelWhenBusy,
                pressure: test.pressure
            )
            let expectsNameReason = test.mentionsScreenName && test.engine.acceptsInstructions
            if decision.reasons.contains(.namesScreenItem) != expectsNameReason {
                failures.append(
                    "\(test.id): namesScreenItem reason was "
                        + "\(decision.reasons.contains(.namesScreenItem)), expected \(expectsNameReason)"
                )
            }
            if decision.usesModel != test.expectModel {
                failures.append(
                    "\(test.id): decide used model=\(decision.usesModel) "
                        + "(\(decision.reasons.map(\.rawValue).joined(separator: ","))), "
                        + "expected \(test.expectModel)"
                )
            }
            if test.pressure.isUnderPressure, !test.expectModel {
                let idleWouldModel = decide(
                    raw: test.input,
                    afterRules: afterRules,
                    engine: test.engine,
                    formatsLists: test.formatsLists,
                    targetRendersLists: test.targetRendersLists,
                    mentionsScreenName: test.mentionsScreenName,
                    skipsModelWhenBusy: test.skipsModelWhenBusy,
                    pressure: .idle
                ).usesModel
                if idleWouldModel, !decision.reasons.contains(.deferredUnderPressure) {
                    failures.append(
                        "\(test.id): deferred under pressure without deferredUnderPressure "
                            + "(\(decision.reasons.map(\.rawValue).joined(separator: ",")))"
                    )
                }
            }

            let counter = CounterBox()
            let router = CleanupRouter(
                semantic: CountingFormatter(box: counter),
                engine: test.engine,
                rules: rules,
                formatsLists: test.formatsLists,
                targetRendersLists: test.targetRendersLists,
                mentionsScreenName: test.mentionsScreenName,
                skipsModelWhenBusy: test.skipsModelWhenBusy,
                pressureSample: { test.pressure }
            )
            _ = await router.format(test.input)
            let calls = await counter.count
            if test.expectModel, calls == 0 {
                failures.append("\(test.id): expected the model seam to run, it was not invoked")
            }
            if !test.expectModel, calls != 0 {
                failures.append("\(test.id): model seam invoked \(calls) time(s) on a rules-only case")
            }
        }

        // Probe shape: idle sample is a value type; simulated flags raise isUnderPressure.
        if CleanupComputePressure.idle.isUnderPressure {
            failures.append("CleanupComputePressure.idle reported under pressure")
        }
        if !CleanupComputePressure.simulated(realtimeASRBusy: true).isUnderPressure {
            failures.append("simulated realtimeASRBusy did not raise pressure")
        }
        if !CleanupComputePressure.simulated(notesBusy: true).isUnderPressure {
            failures.append("simulated notesBusy did not raise pressure")
        }

        // Stage C, end to end through the router rather than through `SpokenStructure`
        // alone: a list the speaker spoke has to survive the whole pipeline, including the
        // engine that takes no instructions and including a target app that renders nothing.
        failures += SpokenStructure.selfTestFailures()
        failures += await structureThroughRouterFailures()
        failures += await structurePlanFailures()
        failures += CleanupGuard.selfTestFailures()
        failures += salvageFailures()
        failures += traceFailures()

        // Opt-in, and off by default for a reason: this suite is the fast one every other
        // build runs, and the probe makes a dozen live model calls. `--probe-layout`
        // alongside the flag turns it on.
        if StructurePlanProbe.isRequested {
            await StructurePlanProbe.run()
        }

        if failures.isEmpty {
            emit("CLEANUP_ROUTER_OK")
            return true
        }
        for failure in failures { emit("  \(failure)") }
        emit("CLEANUP_ROUTER_FAILED: \(failures.count) case(s)")
        return false
    }

    /// The regression this whole workstream exists to stop: "first point… second point…
    /// third point…" dictated with the shipping settings (S1-mini, grammar off, a plain
    /// target) and arriving as prose.
    ///
    /// `KeepAsIsFormatter` stands in for the model so the check needs no download — which is
    /// exactly right, because the claim under test is that structure no longer depends on the
    /// model at all.
    private static func structureThroughRouterFailures() async -> [String] {
        var failures: [String] = []
        let spoken = "Here is the plan. Start the list. First point, ship the installer. "
            + "Second point, write the release note. Third point, tell the beta group. "
            + "Close the list."

        let targets: [(String, OutputProfile)] = [
            ("markdown target", OutputProfile(
                bundleID: "md.obsidian",
                displayName: "Obsidian",
                capabilities: [.markdown, .bullets, .numbered, .tables, .code]
            )),
            ("plain target", .plain(bundleID: "com.apple.MobileSMS", displayName: "Messages")),
        ]

        for (label, target) in targets {
            for engine in [CleanupSemanticEngine.s1Mini, .apple] {
                let router = CleanupRouter(
                    semantic: KeepAsIsFormatter(),
                    engine: engine,
                    formatsLists: true,
                    targetRendersLists: !target.isPlain,
                    target: target
                )
                let output = await router.format(spoken)
                for line in ["1. Ship the installer", "2. Write the release note",
                             "3. Tell the beta group"] where !output.contains(line) {
                    failures.append(
                        "\(label)/\(engine.rawValue): spoken list was not formatted, "
                            + "missing \(line.debugDescription) \u{2014} got "
                            + output.replacingOccurrences(of: "\n", with: " \u{21B5} ")
                    )
                }
                if output.localizedCaseInsensitiveContains("start the list") {
                    failures.append("\(label)/\(engine.rawValue): the spoken marker was typed out")
                }
            }

            // ...and the switch has to work in the other direction too.
            let off = CleanupRouter(
                semantic: KeepAsIsFormatter(),
                engine: .s1Mini,
                formatsLists: false,
                target: target
            )
            let unformatted = await off.format(spoken)
            if unformatted.contains("1. Ship the installer") {
                failures.append("\(label): formatting was applied with the switch off")
            }
        }

        // The grammar route, stated as an assertion rather than as a comment: the engine a
        // hold reaches has to be one that can do what the switch promises.
        if !preferredEngine(choice: .s1Mini, fixesGrammar: true).acceptsInstructions {
            failures.append("grammar on still routes to an engine that takes no instructions")
        }
        if preferredEngine(choice: .s1Mini, fixesGrammar: false).acceptsInstructions {
            failures.append("grammar off no longer routes to the punctuation-only engine")
        }

        // Long transcripts are split rather than dropped.
        let long = Array(repeating: "The build is green and the tests are passing.", count: 40)
            .joined(separator: " ")
        let chunks = SentenceChunker.chunks(long, maxWords: 120)
        if chunks.count < 2 {
            failures.append("a \(SentenceChunker.wordCount(long))-word transcript was not chunked")
        }
        if chunks.joined(separator: " ") != long {
            failures.append("chunking did not preserve the transcript")
        }
        if let overlong = chunks.first(where: { SentenceChunker.wordCount($0) > 120 }) {
            failures.append("a chunk of \(SentenceChunker.wordCount(overlong)) words exceeds the budget")
        }

        // Out of time, the tail is left as spoken rather than the whole pass being lost —
        // and the record has to say so, because otherwise it is a silent partial cleanup.
        let budgetTrace = CleanupTrace()
        let starved = ChunkedFormatter(
            inner: KeepAsIsFormatter(),
            trace: budgetTrace,
            budget: .zero
        )
        let survived = await starved.format(long)
        if survived != long {
            failures.append("an out-of-budget chunked pass changed the transcript")
        }
        if budgetTrace.snapshot.fallbackReason == nil {
            failures.append("an out-of-budget chunked pass recorded no reason")
        }

        // The budget has to hold when it runs out *during* the pass, which is the only way
        // it ever runs out in production. A zero budget starts no call at all and so proves
        // nothing about the case that lost this user their cleanup: a group dispatched with
        // a sliver of budget left, running for its own full ceiling, and carrying the whole
        // stage past the controller's deadline.
        //
        // Five groups, so the third wave is the one that hits the wall: the shared `long`
        // fixture splits into four, two waves of 200 ms fit inside the 500 ms budget, and
        // the mid-pass case this block exists to prove is never exercised — a green run
        // that tested nothing, until the record assertion below caught the absence.
        let stallLong = Array(repeating: "The build is green and the tests are passing.", count: 60)
            .joined(separator: " ")
        let stallGroups = SentenceChunker.chunks(stallLong, maxWords: 120)
        if stallGroups.count < 5 {
            failures.append(
                "the mid-pass budget fixture split into \(stallGroups.count) group(s), "
                    + "too few to outlast two waves"
            )
        }
        let stallTrace = CleanupTrace()
        let stallBox = CounterBox()
        let ceiling = Duration.milliseconds(200)
        let stallBudget = Duration.milliseconds(500)
        let stalled = ChunkedFormatter(
            inner: StallingFormatter(ceiling: ceiling, box: stallBox),
            trace: stallTrace,
            budget: stallBudget,
            perCallTimeout: { _ in ceiling }
        )
        let stallBegan = ContinuousClock.now
        let stalledOutput = await stalled.format(stallLong)
        let stallElapsed = ContinuousClock.now - stallBegan
        let calls = await stallBox.count
        if calls == 0 {
            failures.append("the mid-pass budget case started no call, so it proves nothing")
        }
        // Generous slack for a loaded machine; the point is that it cannot be `budget` plus
        // a whole extra call, which is what the old check-before-dispatch allowed.
        if stallElapsed > stallBudget + ceiling {
            failures.append(
                "a chunked pass with a \(stallBudget) budget and a \(ceiling) per-call "
                    + "ceiling ran for \(stallElapsed)"
            )
        }
        if SentenceChunker.wordCount(stalledOutput) != SentenceChunker.wordCount(stallLong) {
            failures.append("the out-of-budget tail was not left as spoken")
        }
        if stallTrace.snapshot.fallbackReason == nil {
            failures.append("a pass that ran out of budget mid-way recorded no reason")
        }

        // A model that flattens the formatting back into prose must not be allowed to. This
        // is Apple's on-device model on a spoken quotation, and before Stage C moved in
        // front of the model it was the reason "quote … end quote" came out as neither.
        for (label, target) in targets {
            let prosifyTrace = CleanupTrace()
            let router = CleanupRouter(
                semantic: ProsifyingFormatter(),
                engine: .apple,
                formatsLists: true,
                targetRendersLists: !target.isPlain,
                target: target,
                trace: prosifyTrace
            )
            let output = await router.format(spoken)
            for line in ["1. Ship the installer", "2. Write the release note"]
            where !output.contains(line) {
                failures.append(
                    "\(label): a model that un-formats the text lost \(line.debugDescription) "
                        + "\u{2014} got " + output.replacingOccurrences(of: "\n", with: " \u{21B5} ")
                )
            }
            if prosifyTrace.snapshot.structureApplied?.isEmpty != false {
                failures.append("\(label): structure was applied but the record does not say so")
            }
        }

        return failures
    }

    /// Stage D: the model-led layout.
    ///
    /// Everything here is model-free. The claim under test is not "the model lays out this
    /// passage well" — that is a matter for the eval — it is that a plan, once given, is
    /// checked before it is trusted, rendered from the user's own sentences, and cleanly
    /// abandoned for the rules when it is nonsense. A scripted planner stands in for the
    /// model so those three things are testable on any Mac.
    private static func structurePlanFailures() async -> [String] {
        var failures: [String] = []
        let markdownApp = OutputProfile(
            bundleID: "md.obsidian",
            displayName: "Obsidian",
            capabilities: [.markdown, .bullets, .numbered, .tables, .code]
        )
        let text = StructureFixtures.realDictation
        let sentences = SpokenStructure.sentenceSplit(text)

        guard sentences.count >= 12 else {
            failures.append(
                "the real dictation split into \(sentences.count) sentences; the layout "
                    + "fixtures need it to split into at least 12"
            )
            return failures
        }
        if sentences.joined(separator: " ") != text.replacingOccurrences(of: "\n", with: " ") {
            failures.append("the sentence split did not preserve the dictation")
        }

        /// The sentence the speaker began with these words. The plan is scripted, but its
        /// numbers are found rather than typed, so a change to the sentence split shows up
        /// as a failure here instead of as four silently wrong item boundaries.
        func sentence(startingWith prefix: String) -> Int? {
            sentences.firstIndex { $0.hasPrefix(prefix) }.map { $0 + 1 }
        }

        guard let firstItem = sentence(startingWith: "Let's see how we can improve the graph"),
              let secondItem = sentence(startingWith: "The second thing"),
              let thirdItem = sentence(startingWith: "Third thing"),
              let fourthItem = sentence(startingWith: "Last but not least"),
              let signOff = sentence(startingWith: "That is it")
        else {
            failures.append("the real dictation no longer splits where the layout fixtures expect")
            return failures
        }

        // What a model that read this passage properly would answer.
        let good = StructurePlan(blocks: [
            .init(kind: .prose, from: 1, to: firstItem - 1),
            .init(
                kind: .numbered,
                from: firstItem,
                to: signOff - 1,
                itemStarts: [firstItem, secondItem, thirdItem, fourthItem],
                stripWords: [0, 3, 2, 4]
            ),
            .init(kind: .prose, from: signOff, to: sentences.count),
        ])

        if let problem = good.rejection(sentenceCount: sentences.count) {
            failures.append("a correct layout plan was rejected: \(problem)")
        }
        guard let rendered = good.rendered(sentences: sentences, target: markdownApp) else {
            failures.append("a correct layout plan rendered nothing")
            return failures
        }
        for needle in [
            "Okay, a few things that I need to change here.",
            "1. Let's see how we can improve the graph",
            "2. The skills, the skills it seems like",
            "3. On the setting page",
            "4. On the search tab does it include",
            // Long items must keep every sentence they hold.
            "make it more sleek, improved, modern, etc.",
            "Keep going with the black and white design that we have.",
            "Make sure that this is all served by the retrieval engine",
            "\nThat is it.",
        ] where !rendered.text.contains(needle) {
            failures.append(
                "the rendered layout is missing \(needle.debugDescription)\n      got: "
                    + oneLine(rendered.text)
            )
        }
        for needle in ["5. ", "Last but not least", "The second thing,"]
        where rendered.text.contains(needle) {
            failures.append("the rendered layout still contains \(needle.debugDescription)")
        }
        if rendered.applied != [.list] {
            failures.append("the rendered layout applied \(rendered.applied.map(\.rawValue)), expected [list]")
        }
        // The list numbering is this app's punctuation, not the speaker's, so it comes off
        // before the "nothing was invented" question is asked.
        func withoutSyntax(_ rendered: String) -> String {
            rendered.split(separator: "\n", omittingEmptySubsequences: true).map { line in
                var text = line.trimmingCharacters(in: .whitespaces)
                if let match = text.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                    text = String(text[match.upperBound...])
                }
                for marker in ["- ", "\u{2022} ", "> "] where text.hasPrefix(marker) {
                    text = String(text.dropFirst(marker.count))
                }
                return text
            }.joined(separator: " ")
        }
        if !StructurePlan.saysNothingNew(withoutSyntax(rendered.text), source: text) {
            failures.append("rendering a layout plan produced a word the speaker never said")
        }
        // Nothing may be invented even when the plan asks for the maximum strip everywhere.
        let greedy = StructurePlan(blocks: [
            .init(
                kind: .numbered,
                from: 1,
                to: sentences.count,
                itemStarts: [1, secondItem, thirdItem, fourthItem],
                stripWords: Array(repeating: StructurePlan.Limits.maxStripWords, count: 4)
            ),
        ])
        if let greedyRender = greedy.rendered(sentences: sentences, target: markdownApp) {
            if !StructurePlan.saysNothingNew(withoutSyntax(greedyRender.text), source: text) {
                failures.append("a maximum-strip layout invented a word")
            }
            if StructurePlan.dropping(99, from: "Third thing on the setting page").isEmpty {
                failures.append("a large marker strip emptied a sentence")
            }
        } else {
            failures.append("a valid plan with the maximum marker strip rendered nothing")
        }

        // Every way a plan can be wrong has to be caught before it is rendered, because a
        // plan is the one thing in this pass that a model wrote.
        let hostile: [(String, StructurePlan)] = [
            ("a gap between blocks", StructurePlan(blocks: [
                .init(kind: .prose, from: 1, to: 3),
                .init(kind: .prose, from: 5, to: sentences.count),
            ])),
            ("overlapping blocks", StructurePlan(blocks: [
                .init(kind: .prose, from: 1, to: 5),
                .init(kind: .prose, from: 4, to: sentences.count),
            ])),
            ("a block past the end", StructurePlan(blocks: [
                .init(kind: .prose, from: 1, to: sentences.count + 40),
            ])),
            ("a plan that stops early", StructurePlan(blocks: [
                .init(kind: .prose, from: 1, to: 3),
            ])),
            ("a plan that starts late", StructurePlan(blocks: [
                .init(kind: .prose, from: 2, to: sentences.count),
            ])),
            ("an empty plan", StructurePlan(blocks: [])),
            ("a one-item list", StructurePlan(blocks: [
                .init(kind: .numbered, from: 1, to: sentences.count, itemStarts: [1]),
            ])),
            ("a list whose first item does not start it", StructurePlan(blocks: [
                .init(
                    kind: .numbered, from: 1, to: sentences.count,
                    itemStarts: [2, secondItem, thirdItem]
                ),
            ])),
            ("list items out of order", StructurePlan(blocks: [
                .init(
                    kind: .numbered, from: 1, to: sentences.count,
                    itemStarts: [1, thirdItem, secondItem]
                ),
            ])),
            ("a list item past its block", StructurePlan(blocks: [
                .init(kind: .numbered, from: 1, to: 4, itemStarts: [1, 3, 9]),
                .init(kind: .prose, from: 5, to: sentences.count),
            ])),
            ("an outsized marker strip", StructurePlan(blocks: [
                .init(
                    kind: .numbered, from: 1, to: sentences.count,
                    itemStarts: [1, secondItem, thirdItem], stripWords: [0, 3, 99]
                ),
            ])),
            ("marker lengths that do not match the items", StructurePlan(blocks: [
                .init(
                    kind: .numbered, from: 1, to: sentences.count,
                    itemStarts: [1, secondItem, thirdItem], stripWords: [0, 3]
                ),
            ])),
        ]
        for (label, plan) in hostile {
            if plan.rejection(sentenceCount: sentences.count) == nil {
                failures.append("\(label) was accepted as a layout plan")
            }
            if plan.rendered(sentences: sentences, target: markdownApp) != nil {
                failures.append("\(label) was rendered instead of refused")
            }
        }

        // A model that finds a list in prose is the failure this pass has actually been
        // measured doing, so it is the one the fixtures lead with. Corroboration is what
        // stops it: the speaker has to have announced the items out loud.
        for (label, sentence, announced) in [
            ("an ordinal opener", "The second thing, the skills need more room.", true),
            ("a spoken closer", "Last but not least, look at the search tab.", true),
            ("an additive opener", "Another thing, the settings page is too tall.", true),
            ("a conjunction and an opener", "And one more thing, check the search tab.", true),
            ("ordinary prose", "The release is scheduled for Friday afternoon.", false),
            ("a mid-sentence ordinal", "I will send the notes round for the second time.", false),
            ("prose about a first time", "The first time I tried it nothing happened.", false),
        ] where SpokenStructure.opensAnItem(sentence) != announced {
            failures.append(
                "\(label): \(sentence.debugDescription) was read as "
                    + "\(announced ? "not announcing" : "announcing") an item"
            )
        }

        let inventedList = StructurePlan(blocks: [
            .init(
                kind: .numbered, from: 1, to: sentences.count,
                itemStarts: [1, firstItem, firstItem + 1]
            ),
        ])
        if inventedList.rejection(sentenceCount: sentences.count) != nil {
            failures.append("the invented-list fixture is malformed, so it tests nothing")
        }
        if inventedList.corroborationFailure(sentences: sentences) == nil {
            failures.append("a list whose items nobody announced was corroborated anyway")
        }
        if inventedList.rendered(sentences: sentences, target: markdownApp) != nil {
            failures.append("a list whose items nobody announced was rendered anyway")
        }
        if good.corroborationFailure(sentences: sentences) != nil {
            failures.append("the four items the speaker really announced were not corroborated")
        }

        // End to end through the router, which is the only place that can prove the plan
        // path *runs*. A pass that quietly never asks for a plan would satisfy every check
        // above and be exactly the bug this workstream started from.
        //
        // The passage is prose with no ordinal in it, because that is where Stage D earns
        // its keep: Stage C declines it, and one block of eighty words becomes paragraphs.
        let longProse = "We finished the review this morning and everyone signed off on "
            + "the plan. The release is scheduled for Friday afternoon as discussed. "
            + "I will send the notes round once the build is green. Separately, the "
            + "onboarding copy still reads as though we charge for the trial. "
            + "Marketing have a rewrite in hand and it should land this week. "
            + "There is nothing else outstanding on my side at the moment."
        // The plan is built from the sentences the planner is actually handed, not from a
        // count taken here: the rules pass runs first in the router, and a fixture that
        // assumed its own numbering would fail for a reason that has nothing to do with
        // what is under test.
        let paragraphs = ScriptedStructurePlanner { sentences in
            guard sentences.count >= 4 else { return .failed("too short to lay out", seconds: 0) }
            return StructurePlanOutcome(
                plan: StructurePlan(blocks: [
                    .init(kind: .prose, from: 1, to: 3),
                    .init(kind: .prose, from: 4, to: sentences.count),
                ]),
                rejection: nil,
                seconds: 0
            )
        }
        let planTrace = CleanupTrace()
        let plannedOutput = await CleanupRouter(
            semantic: KeepAsIsFormatter(),
            engine: .apple,
            formatsLists: true,
            targetRendersLists: true,
            target: markdownApp,
            trace: planTrace,
            structurePlanner: paragraphs
        ).format(longProse)
        if !plannedOutput.contains("build is green.\n\nSeparately") {
            failures.append(
                "the router did not use the layout plan's paragraph break\n      got: "
                    + oneLine(plannedOutput)
            )
        }
        let plannedRecord = planTrace.snapshot
        if plannedRecord.structureSource != "model plan" {
            failures.append(
                "the record says the layout came from "
                    + "\(plannedRecord.structureSource ?? "nothing"), expected the model plan"
            )
        }
        if plannedRecord.structurePlanModel != "scripted" {
            failures.append("the record does not name the model that laid the text out")
        }
        if plannedRecord.structurePlanRejected != nil {
            failures.append("a plan that was used was also recorded as rejected")
        }

        // The same prose, with a model that claims to have found a list in it. Nothing
        // announced an item, so the text must come out exactly as it went in.
        let hallucinationTrace = CleanupTrace()
        let hallucinated = await CleanupRouter(
            semantic: KeepAsIsFormatter(),
            engine: .apple,
            formatsLists: true,
            targetRendersLists: true,
            target: markdownApp,
            trace: hallucinationTrace,
            structurePlanner: ScriptedStructurePlanner { sentences in
                StructurePlanOutcome(
                    plan: StructurePlan(blocks: [
                        .init(
                            kind: .numbered, from: 1, to: sentences.count,
                            itemStarts: [1, 2, 3]
                        ),
                    ]),
                    rejection: nil,
                    seconds: 0
                )
            }
        ).format(longProse)
        if hallucinated.contains("1. ") || hallucinated.contains("2. ") {
            failures.append(
                "a list the model invented in ordinary prose was rendered\n      got: "
                    + oneLine(hallucinated)
            )
        }
        if hallucinationTrace.snapshot.structureSource != "none" {
            failures.append("an uncorroborated list was recorded as structure anyway")
        }
        if hallucinationTrace.snapshot.structurePlanRejected == nil {
            failures.append("a layout plan that was turned down recorded no reason")
        }

        // The dictation this workstream started from. Stage C finds all four items with no
        // model at all, so the plan pass must not be reached — and the guard must not turn
        // down a list that is only the user's own sentences rearranged.
        let fallbackTrace = CleanupTrace()
        let fallbackOutput = await CleanupRouter(
            semantic: KeepAsIsFormatter(),
            engine: .apple,
            formatsLists: true,
            targetRendersLists: true,
            target: markdownApp,
            trace: fallbackTrace,
            structurePlanner: ScriptedStructurePlanner { _ in
                .failed("should not have been asked", seconds: 0)
            }
        ).format(text)
        for needle in ["1. Let's see how we can improve the graph",
                       "2. The skills", "3. On the setting page", "4. On the search tab"]
        where !fallbackOutput.contains(needle) {
            failures.append(
                "the rule-based detector lost \(needle.debugDescription)\n      got: "
                    + oneLine(fallbackOutput)
            )
        }
        if let verdict = CleanupGuard.rejection(
            original: text,
            cleaned: fallbackOutput,
            mode: .grammar
        ) {
            failures.append("the guard rejected a layout of the user's own words: \(verdict)")
        }
        let fallbackRecord = fallbackTrace.snapshot
        if fallbackRecord.structureSource != "rules" {
            failures.append(
                "a rule-detected list left the record saying "
                    + "\(fallbackRecord.structureSource ?? "nothing"), expected the rules"
            )
        }
        if fallbackRecord.structurePlanModel != nil {
            failures.append("a list the rules had already found was sent for a layout plan")
        }
        if fallbackRecord.structureMarkersSeen != true {
            failures.append(
                "the record still says no spoken structure was seen in a dictation that "
                    + "enumerated four things"
            )
        }

        // Short dictation must not grow a model call for a list it cannot contain. The
        // planner records having been asked, so "was it reached" is a question the trace
        // answers rather than a counter this test has to keep.
        let shortTrace = CleanupTrace()
        _ = await CleanupRouter(
            semantic: KeepAsIsFormatter(),
            engine: .apple,
            formatsLists: true,
            target: markdownApp,
            trace: shortTrace,
            structurePlanner: ScriptedStructurePlanner(planName: "counted") { _ in
                StructurePlanOutcome(plan: nil, rejection: "should not have been asked", seconds: 0)
            }
        ).format("The build is green.")
        if shortTrace.snapshot.structurePlanModel != nil {
            failures.append("a four-word dictation was sent for a layout plan")
        }

        if StructurePlan.isWorthPlanning(
            sentences: ["The build is green."],
            wordCount: 4,
            sawMarkers: false
        ) {
            failures.append("a four-word dictation was considered worth a layout call")
        }
        if !StructurePlan.isWorthPlanning(
            sentences: sentences,
            wordCount: 220,
            sawMarkers: true
        ) {
            failures.append("the real dictation was not considered worth a layout call")
        }

        // An explicit envelope is an instruction Stage C has already carried out, so the
        // plan pass must not be asked to second-guess it.
        let envelopeTrace = CleanupTrace()
        _ = await CleanupRouter(
            semantic: KeepAsIsFormatter(),
            engine: .apple,
            formatsLists: true,
            target: markdownApp,
            trace: envelopeTrace,
            structurePlanner: ScriptedStructurePlanner(planName: "counted") { _ in
                StructurePlanOutcome(plan: nil, rejection: "should not have been asked", seconds: 0)
            }
        ).format(
            "Here is the plan. Start the list. First point, ship the installer. "
                + "Second point, write the release note. Third point, tell the beta group. "
                + "Close the list."
        )
        if envelopeTrace.snapshot.structurePlanModel != nil {
            failures.append("a spoken \u{201C}start the list\u{201D} envelope was sent for a layout plan anyway")
        }

        // The budget scales with the passage. A flat three seconds is what the 41-second
        // dictation of 2026-09-20T20:47:25Z hit, at 3.01s, and a ceiling that does not grow
        // with the work is a ceiling set by the shortest input.
        let budgets = [3, 12, 25, 40, 200].map {
            ($0, AppleStructurePlanner.budget(forSentences: $0))
        }
        for (count, budget) in budgets where budget < .seconds(2.5) || budget > .seconds(6) {
            failures.append("a \(count)-sentence passage was given a layout budget of \(budget)")
        }
        if AppleStructurePlanner.budget(forSentences: 25)
            <= AppleStructurePlanner.budget(forSentences: 5) {
            failures.append("the layout budget does not grow with the passage")
        }
        // The dictation that timed out has to be given more than it spent.
        let timedOut = SpokenStructure.sentenceSplit(StructureFixtures.labelledDictation)
        if AppleStructurePlanner.budget(forSentences: timedOut.count) <= .seconds(3.01) {
            failures.append(
                "the dictation that timed out at 3.01s would still be given "
                    + "\(AppleStructurePlanner.budget(forSentences: timedOut.count))"
            )
        }

        // The prompt is smaller than the passage, and still carries every boundary. A
        // boundary lives in the first words of a sentence and the last words of the one
        // before it, which is exactly what survives the elision.
        let full = sentences.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let compact = StructurePlanPrompt.user(sentences: sentences)
        if compact.count >= full.count {
            failures.append("the layout prompt is no smaller than the passage it describes")
        }
        for opener in ["The second thing", "Third thing on the setting page",
                       "Last but not least"] where !compact.contains(opener) {
            failures.append("the layout prompt elided the announcement \(opener.debugDescription)")
        }
        if StructurePlanPrompt.abbreviated("Short enough to show whole.")
            != "Short enough to show whole." {
            failures.append("a short sentence was elided")
        }

        // The plan is made against the rule-cleaned sentences and rendered against the
        // grammar-cleaned ones, because the two passes now run at the same time.
        if good.remapped(from: sentences, to: sentences) != good {
            failures.append("re-mapping a plan onto the same sentences changed it")
        }
        // One sentence split in two: every number after it moves by one, and the plan has
        // to follow. Split the sign-off, which is its own prose block at the end.
        var split = sentences
        split[signOff - 1] = "That is."
        split.insert("It.", at: signOff)
        guard let remapped = good.remapped(from: sentences, to: split) else {
            failures.append(
                "a plan could not be re-mapped after the model split one sentence in two"
            )
            return failures
        }
        if remapped.rejection(sentenceCount: split.count) != nil {
            failures.append("a re-mapped plan does not cover the sentences it was mapped onto")
        }
        if remapped.blocks.last?.from != signOff {
            failures.append(
                "a re-mapped plan put the closing prose at sentence "
                    + "\(remapped.blocks.last?.from ?? 0), expected \(signOff)"
            )
        }
        // ...and a passage that is no longer the same passage is refused rather than
        // rendered at the wrong boundaries.
        if good.remapped(
            from: sentences,
            to: ["Something else entirely.", "Nothing to do with it.", "Not this at all."]
        ) != nil {
            failures.append("a plan was re-mapped onto sentences that are not the same speech")
        }

        // Asked *while* the grammar pass runs, not after it. A planner that records when it
        // was called is the only way to assert an overlap without timing the suite.
        let concurrentTrace = CleanupTrace()
        let slowModel = SlowFormatter(delay: .milliseconds(300))
        let overlapBegan = ContinuousClock.now
        _ = await CleanupRouter(
            semantic: slowModel,
            engine: .apple,
            formatsLists: true,
            targetRendersLists: true,
            target: markdownApp,
            trace: concurrentTrace,
            structurePlanner: ScriptedStructurePlanner(planName: "slow") { _ in
                try? await Task.sleep(for: .milliseconds(300))
                return .failed("scripted", seconds: 0.3)
            }
        ).format(longProse)
        let overlapped = ContinuousClock.now - overlapBegan
        if concurrentTrace.snapshot.structurePlanModel != "slow" {
            failures.append("the layout pass was not asked on a long prose dictation")
        }
        // Two 300 ms passes run one after the other take 600; run together they take 300.
        // Generous slack for a loaded machine, and still nowhere near the sum.
        if overlapped > .milliseconds(520) {
            failures.append(
                "the layout pass did not overlap the cleanup pass: two 300ms passes took "
                    + "\(overlapped)"
            )
        }

        // A run with no structure has to say why, in one field, in plain language.
        let noStructureCases: [(String, Bool, Bool, String?, String)] = [
            ("nothing spoken", false, false, nil, "nothing in the dictation"),
            ("not worth asking", true, false, nil, "not worth a model call"),
            ("asked and refused", true, true, "the layout pass ran out of time after 6.0s",
             "ran out of time"),
            ("asked and silent", false, true, nil, "proposed no arrangement"),
        ]
        for (label, markers, asked, rejection, needle) in noStructureCases {
            let line = whyNoStructure(
                markersSeen: markers,
                planWasAsked: asked,
                planRejection: rejection
            )
            if !line.contains(needle) {
                failures.append("\(label): the record says \(line.debugDescription)")
            }
        }
        if concurrentTrace.snapshot.noStructureReason?.contains("scripted") != true {
            failures.append(
                "a run that formatted nothing did not record why: "
                    + (concurrentTrace.snapshot.noStructureReason ?? "nothing")
            )
        }
        // ...and a run that *did* format something must not claim it did not.
        if fallbackTrace.snapshot.noStructureReason != nil {
            failures.append("a run that rendered a list also recorded why it rendered none")
        }

        // The grammar the constrained providers use has to describe the same shape the
        // decoder accepts, or the on-device model's plans are refused on arrival.
        let grammar = StructurePlanPrompt.grammar()
        for problem in grammar.structuralProblems() {
            failures.append("the layout grammar is malformed: \(problem)")
        }
        let sample = #"{"blocks": [{"kind": "prose", "from": 1, "to": 2}, "#
            + #"{"kind": "numbered", "from": 3, "to": 9, "itemStarts": [3, 6], "stripWords": [0, 3]}]}"#
        if (try? JSONDecoder().decode(StructurePlan.self, from: Data(sample.utf8))) == nil {
            failures.append("a plan in the grammar's own shape did not decode")
        }
        if LLMStructurePlanner.firstJSONObject(in: "```json\n\(sample)\n```") != sample {
            failures.append("a fenced layout plan was not recovered from the answer")
        }

        return failures
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " \u{21B5} ")
    }

    /// One bad sentence must not cost the user every repair in the other five.
    ///
    /// The fixture is this user's own transcript and Apple's own answer to it, recorded on
    /// 2026-09-20: the plural they asked for was fixed, one clause was rewritten further
    /// than the guard allows, and the whole thing was discarded for it.
    private static func salvageFailures() -> [String] {
        var failures: [String] = []
        // Verbatim: `CleanupEvalCases.shipped` R1-agreement, and the answer Apple's model
        // gave it on this Mac.
        let original = "Also, there is some lags between when the user is recording. "
            + "When the animation shows, it doesn't show on the notch. "
            + "I don't know what's happening, so you need to make sure that the user can "
            + "see that the computer is actually recording."
        let cleaned = "Also, there are some lags between when the user is recording. "
            + "When the animation shows, it does not appear on the notch. "
            + "I do not know what is happening, so you need to make sure that the user can "
            + "see that the computer is actually recording."

        guard CleanupGuard.rejection(original: original, cleaned: cleaned, mode: .grammar) != nil
        else {
            failures.append("the salvage fixture is no longer rejected as a whole, so it "
                + "tests nothing")
            return failures
        }
        guard let salvage = CleanupGuard.salvage(
            original: original,
            cleaned: cleaned,
            mode: .grammar
        ) else {
            failures.append("a rejected answer with one bad sentence in it salvaged nothing")
            return failures
        }
        if salvage.text.contains("there is some lags") {
            failures.append("the salvaged text put back an agreement error the model had fixed")
        }
        if !salvage.text.contains("it doesn't show on the notch") {
            failures.append("the salvaged text kept a sentence the guard turned down")
        }
        if salvage.rejectedSentences != 1 {
            failures.append(
                "expected one sentence to be put back, got \(salvage.rejectedSentences) "
                    + "of \(salvage.totalSentences)"
            )
        }
        // A single sentence replaced wholesale cannot be salvaged, and must not be.
        if CleanupGuard.salvage(
            original: "Check localhost three thousand.",
            cleaned: "Paris is lovely this time of year.",
            mode: .grammar
        ) != nil {
            failures.append("a wholesale rewrite was salvaged instead of rejected")
        }
        // The four-letter mis-hearing the old edit budget called an invention.
        if !CleanupGuard.related("walk", "work") {
            failures.append("\"walk\"/\"work\" is still not recognised as a mis-hearing")
        }
        if CleanupGuard.related("paris", "what") {
            failures.append("\"paris\"/\"what\" is now being treated as a mis-hearing")
        }
        return failures
    }

    /// The record has to say what happened, or "check the dictation logs" is still not a
    /// thing anyone can do.
    private static func traceFailures() -> [String] {
        var failures: [String] = []
        let trace = CleanupTrace()
        trace.noteInput(raw: "the tests is passing", afterRules: "The tests is passing.")
        trace.noteSettings(
            engine: "apple",
            fixesGrammar: true,
            formatsStructure: true,
            targetName: "Obsidian",
            targetRenders: ["bullets"]
        )
        trace.noteRoute("semantic", reasons: ["grammar"])
        trace.noteModelRejected(reason: "changed too much", seconds: 0.4)
        trace.noteStructure(markersSeen: false, applied: [])
        trace.noteOutput("The tests is passing.", seconds: 0.5)

        let record = trace.snapshot
        if record.rawText != "the tests is passing" {
            failures.append("the trace lost the raw transcript")
        }
        if record.guardVerdict != "rejected" {
            failures.append("a rejected model answer was not recorded as rejected")
        }
        if record.grammarWasPossible {
            failures.append("a rejected answer still reports that grammar was applied")
        }
        // Old rows must still load: every key is optional, so an empty object decodes.
        guard let empty = "{}".data(using: .utf8),
              (try? JSONDecoder().decode(CleanupRecord.self, from: empty)) != nil else {
            failures.append("CleanupRecord cannot decode a row written before it existed")
            return failures
        }
        guard let encoded = try? JSONEncoder().encode(record),
              let cycled = try? JSONDecoder().decode(CleanupRecord.self, from: encoded),
              cycled == record else {
            failures.append("CleanupRecord does not survive a round trip")
            return failures
        }
        return failures
    }

    private static func emit(_ line: String) {
        CleanupSelfTestLog.emit(line)
    }
}

extension CleanupRouter {
    private static func words(in text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }

    private static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static let leftoverFillers: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mhm"
    ]

    private static func isDisfluent(_ text: String) -> Bool {
        let haystack = folded(text)
        if haystack.contains("i mean") || haystack.contains("you know") { return true }
        let tokens = haystack.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.filter { leftoverFillers.contains($0) }.count >= 2
    }

    private static func hasSelfCorrection(_ text: String) -> Bool {
        let haystack = folded(text)
        return haystack.contains("no wait")
            || haystack.contains("make that")
            || haystack.contains("actually,")
    }

    private static func hasStutter(_ text: String) -> Bool {
        let tokens = words(in: folded(text)).map {
            $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }.filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return false }
        for index in 1..<tokens.count where tokens[index] == tokens[index - 1] {
            return true
        }
        return false
    }

    private static let grammarMarkers = [
        "tests is", "they was", "we was", "they is", "we is",
        "i were", "he were", "she were", "it are",
        "gotta fixes", "need for me", "yesterday i go",
    ]

    private static func hasGrammarMarker(_ text: String) -> Bool {
        let haystack = folded(text)
        return grammarMarkers.contains { haystack.contains($0) }
    }

    private static func needsTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.isLetter || last.isNumber
    }

    private static func looksLikeSpokenList(_ text: String) -> Bool {
        let haystack = folded(text)
        let markers = ["first", "second", "third", "number one", "number two"]
        return markers.filter { haystack.contains($0) }.count >= 2
    }
}

/// Increments on every `format` call so the self-test can see a model invocation
/// without loading one.
private struct CountingFormatter: TextFormatter {
    let box: CounterBox

    func format(_ raw: String) async -> String {
        await box.increment()
        return raw
    }
}

private actor CounterBox {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// A model that always spends its whole ceiling, the way a stalled one does. Stands in for
/// the timeout `ChunkedFormatter` has to budget around, with no model to download.
private struct StallingFormatter: TextFormatter {
    let ceiling: Duration
    let box: CounterBox

    func format(_ raw: String) async -> String {
        await box.increment()
        try? await Task.sleep(for: ceiling)
        return raw
    }
}

/// A model that takes a fixed time to answer. Stands in for the cleanup pass when what is
/// under test is whether something else ran *beside* it.
private struct SlowFormatter: TextFormatter {
    let delay: Duration

    func format(_ raw: String) async -> String {
        try? await Task.sleep(for: delay)
        return raw
    }
}

/// A model that flattens formatting back into prose — what Apple's on-device model does to
/// a spoken quotation, reproduced deterministically.
private struct ProsifyingFormatter: TextFormatter {
    func format(_ raw: String) async -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                var text = line.trimmingCharacters(in: .whitespaces)
                for marker in ["- ", "\u{2022} ", "> ", "```"] where text.hasPrefix(marker) {
                    text = String(text.dropFirst(marker.count))
                }
                if let match = text.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                    text = String(text[match.upperBound...])
                }
                return text
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
