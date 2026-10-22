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
    private var progress: (@Sendable (String) -> Void)?
    /// Stage C. What the receiving app renders, so structure the speaker spoke is written in
    /// a syntax that app can show — and in plain text when it can show none.
    private let target: OutputProfile
    /// Per-run record, filed beside the transcript. Nil outside the live dictation path.
    private let trace: CleanupTrace?
    /// Stage D. Asks a model for a *layout* of the finished text — never for the text. Nil
    /// on a Mac with no instruction-following model, which is exactly the case Stage C's
    /// rules exist to cover.
    private let structurePlanner: (any StructurePlanning)?
    /// How long the router is willing to keep waiting for a layout plan once the cleanup
    /// pass has finished, as a function of the passage's sentence count. The default is the
    /// planner's own scaled budget, because that is the wait the plan was started on. (D-09.)
    private let layoutWait: @Sendable (Int) -> Duration
    /// ...and the floor on that wait, so a plan that is nearly there when the cleanup
    /// returns is not thrown away over a rounding error.
    private let layoutGrace: Duration
    /// The hard ceiling the layout pass itself runs under on the model route. A model call
    /// has to end even when nobody is waiting for it any more — cancellation is a request,
    /// and a CoreML decode runs to completion regardless.
    private let layoutCeiling: Duration

    /// What a hold tidied while the key was still down (D-12). Nil for every pass that did
    /// not come from a live hold, which is every pass today.
    private let head: CleanupHead?

    /// How long the key-up pass waits for a pre-clean that has not landed yet.
    ///
    /// A group closes only once it holds fifteen words of *finished* speech, so a pre-clean
    /// has had seconds of hold to answer — a warm Apple call is 0.9–1.5 s — and the common
    /// case costs nothing at all. The grace is for the group that closed a moment before
    /// key-up, and it is deliberately short: the tail's own budget is the one the user is
    /// waiting on, and a group that misses it is typed as the rules left it, which is what
    /// the same call returns when it runs out of time.
    private let precleanGrace: Duration

    /// The grace above, named so the router's other ceilings can be quoted next to it.
    static let precleanGraceDefault: Duration = .milliseconds(2_000)

    /// The layout pass's hard ceiling on the model route. Twelve seconds is an estimate
    /// rather than a measurement, and it is deliberately not the number the user waits:
    /// inside the 26 s whole-pass budget and the 30 s outer bound, and past the point where
    /// the router has already given up and cancelled. (D-09.)
    static let layoutPassCeiling: Duration = .seconds(12)

    /// The floor on the wait after the cleanup, when a plan is already over its nominal
    /// budget: half a second of a dictation nobody notices, against four answers thrown
    /// away for nothing.
    static let layoutPassGrace: Duration = .milliseconds(500)

    /// The layout pass: what Stage D is given. Two cases, because the only question anyone
    /// has ever asked about it is whether it is worth running beside the cleanup — and that
    /// is a question about a *difference*. (D-09.)
    enum LayoutPass: Sendable {
        /// Apple's planner, where the switch and the model both allow it.
        case automatic
        /// No layout pass. The control leg of `--probe-layout`.
        case omitted
    }

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
        layoutWait: @escaping @Sendable (Int) -> Duration = {
            AppleStructurePlanner.budget(forSentences: $0)
        },
        layoutGrace: Duration = CleanupRouter.layoutPassGrace,
        layoutCeiling: Duration = CleanupRouter.layoutPassCeiling,
        precleanGrace: Duration = CleanupRouter.precleanGraceDefault,
        head: CleanupHead? = nil,
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
        self.layoutWait = layoutWait
        self.layoutGrace = layoutGrace
        self.layoutCeiling = layoutCeiling
        self.precleanGrace = precleanGrace
        self.head = head
        self.pressureSample = pressureSample
    }

    /// The pass a hold runs, using whatever head it collected while the key was down.
    func format(_ raw: String) async -> String {
        await format(raw, head: head)
    }

    /// Displays completed cleanup while the final layout is still running. This
    /// synchronous sink must not wait for UI or insert text into another app.
    func reportingProgress(_ sink: @escaping @Sendable (String) -> Void) -> Self {
        var copy = self
        copy.progress = sink
        return copy
    }

    /// What a dictation pass does, and how much of it this hold had already done. (D-12.)
    ///
    /// `head` is the work `IncrementalCleanupSession` got through while the key was still
    /// held: the finished sentences, tidied, and the Stage-A text they were tidied from.
    /// When the final transcript's own Stage-A output still begins with that text, Stage B
    /// runs on the remainder only and the two halves are joined; when it does not — a later
    /// partial revised a sentence that had been tidied already — the whole transcript is
    /// cleaned the way it always was and the record says so. The parameter wins over the
    /// head the router was built with, which is how a hold passes its own.
    func format(_ raw: String, head carried: CleanupHead? = nil) async -> String {
        await withTaskCancellationHandler {
            await finish(raw, head: carried)
        } onCancel: {
            // The outer finishing deadline / a new hold must reach the same owned
            // pre-cleans even while this router is awaiting its tail.
            for task in carried?.cleaned ?? [] { task.cancel() }
        }
    }

    private func finish(_ raw: String, head carried: CleanupHead?) async -> String {
        // No group remains useful after this formatter returns, including empty/rules
        // outcomes. Cancellation is forwarded without waiting for native completion.
        defer { for task in carried?.cleaned ?? [] { task.cancel() } }
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
        // The full-scope pass above already scanned this exact text and records
        // the same marker predicate, even when formatting is disabled.
        let markersBeforeModel = beforeModel.markersSeen

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
        //
        // And it is given a deadline of its own (`layoutCeiling`) rather than the scaled
        // per-passage one it used to carry, because the deadline is not the user's patience
        // any more: the wait is. The pass is only ever *awaited* for as long as the user
        // was already waiting anyway plus a grace, so the ceiling's whole job is to make a
        // model call end even after the router has stopped caring — which cancellation
        // alone does not do, because a CoreML decode runs to completion regardless.
        let planSentences = SpokenStructure.sentenceSplit(beforeModel.text)
        // When the pass was started, whether or not one was: the wait below is what is left
        // of a budget this much of which has already gone. (D-09.)
        let planBegan = ContinuousClock.now
        // The answer, the moment it lands. Read after Stage B so a plan that came back while
        // the cleanup was still running is taken whatever the clock says — otherwise a
        // loaded machine's scheduler can let the grace timer beat an already-finished task,
        // which is the exact failure this pass is being untangled from.
        let planAnswered = LockedBox<StructurePlanOutcome?>(nil)
        let planTask: Task<StructurePlanOutcome, Never>?
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
            // The rules route has no cleanup pass to hide a slow plan inside: the planner
            // keeps its own budget, and the router waits only `layoutGrace` for it.
            let ceiling: Duration? = decision.usesModel ? layoutCeiling : nil
            planTask = Task {
                let outcome = await planner.plan(for: planSentences, deadline: ceiling)
                planAnswered.value = outcome
                return outcome
            }
        } else {
            planTask = nil
        }

        // Cancellation reaches the same layout task while semantic cleanup is held.
        return await withTaskCancellationHandler {
            defer { planTask?.cancel() }
            var text: String
            // D-12: what this hold had already tidied while the key was down, and the reason a
            // head was not used when it had one. Both filed into the run's record below, and
            // neither is read again here.
            var precleanedGroups: Int?
            var precleanFallback: String?
            // No model pin here. MiniCPM answers only when it is already resident
            // (`MiniCPMCleanupFormatter`), so the tail has nothing to select or hand back —
            // and both were actor hops into a runtime whose cold load runs synchronously on
            // its executor, which put up to a whole 14–49 s load in front of every model
            // pass, outside any timeout.
            switch decision.stage {
            case .rules:
                // The pre-cleans are not waited for and not used: this dictation did not need
                // tidying, so the whole pass is the rules pass and nothing else. Recorded as
                // zero groups used rather than left silent, because the work was done and then
                // thrown away and the record should say which.
                if let carried, !carried.stageA.isEmpty { precleanedGroups = 0 }
                for task in carried?.cleaned ?? [] { task.cancel() }
                text = beforeModel.text
            case .semantic:
                if beforeModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = beforeModel.text
                } else {
                    // Stage B sees the rules output, not the raw ASR: the model is repairing
                    // what is left, and a timeout must keep that work (`KeepAsIsFormatter`
                    // on Apple / on-device) rather than fall back through rules a second time.
                    let answered: String
                    switch resolvePreclean(carried, of: beforeModel.text) {
                    case .usable(let head, let remainder):
                        // Only the tail reaches the model here. The groups were sent while the
                        // key was down, and they are joined in transcript order — so the text
                        // that comes out is what one pass over the whole dictation would have
                        // written, with the same joining `ChunkedFormatter` uses.
                        precleanedGroups = head.cleaned.count
                        // Both are already independent work. Waiting on an unfinished head
                        // before even starting the tail added their times at key-up and could
                        // discard a head whose answer the tail would have allowed to finish.
                        async let groups = resolvePrecleanGroups(head)
                        let tail = remainder.isEmpty ? "" : await semantic.format(remainder)
                        var pieces = await groups
                        // The existing head deadline may have expired while this independent
                        // tail was still running. Take any answer its SAME producer has now
                        // published; do not add another grace or wait for unfinished work.
                        var answeredGroups = 0
                        for (index, completed) in head.completed.enumerated() where pieces.indices.contains(index) {
                            if let landed = completed.value,
                               !landed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                pieces[index] = landed
                                answeredGroups += 1
                            }
                        }
                        if head.completed.count == head.cleaned.count {
                            trace?.notePrecleanAnsweredGroups(answeredGroups)
                        }
                        answered = CleanedText.joined(pieces + (tail.isEmpty ? [] : [tail]))
                        // Keep every answer that arrived during tail polishing. Once the
                        // immutable result is assembled, unfinished groups cannot affect it:
                        // stop them now, before a possible layout wait / the next hold.
                        for task in head.cleaned { task.cancel() }
                    case .unusable(let reason):
                        precleanFallback = reason
                        for task in carried?.cleaned ?? [] { task.cancel() }
                        answered = await semantic.format(beforeModel.text)
                    case .none:
                        answered = await semantic.format(beforeModel.text)
                    }
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
            if let precleanedGroups { trace?.notePrecleanedGroups(precleanedGroups) }
            if let precleanFallback { trace?.notePrecleanFallback(precleanFallback) }

            // Stage C. Deterministic, and therefore the one stage every route reaches: the rules
            // route, the model route, and the fallback a rejected or timed-out model lands on.
            // That is the point of it — structure the speaker asked for out loud must not depend
            // on which engine happened to run, and before this it depended on nothing else.
            let structured = text == afterRules ? beforeModel : SpokenStructure.apply(
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
            if planTask != nil, applied.isEmpty, planAnswered.value == nil, !Task.isCancelled {
                progress?(laidOut)
            }

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
                let outcome: StructurePlanOutcome
                if !applied.isEmpty {
                    // Post-cleanup rules have already rendered the structure that wins.
                    // This plan cannot affect the result, so do not spend its remaining
                    // budget waiting to reject it. Keep the authoritative formatting.
                    planTask.cancel()
                    let ready = planAnswered.value
                    outcome = .failed(
                        "the rules had already laid the text out",
                        seconds: ready?.seconds ?? Self.seconds(ContinuousClock.now - planBegan),
                        prewarmed: ready?.prewarmed
                    )
                } else {
                    outcome = await resolveLayoutPlan(
                        planTask,
                        answered: planAnswered,
                        sentences: planSentences,
                        began: planBegan,
                        waitIsBounded: decision.usesModel
                    )
                }
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
                // D-01a: the layout session's prewarm, filed beside the plan verdict —
                // including on timeouts, where the outcome still carries it.
                trace?.noteStructurePlanPrewarmed(outcome.prewarmed)
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
        } onCancel: { planTask?.cancel() }
    }

    /// What a head is worth for this pass. (D-12.)
    private enum PrecleanOutcome {
        /// Nothing was pre-cleaned: the hold closed no group, so there is nothing to match
        /// and nothing to wait for.
        case none
        /// A head was offered and the final transcript no longer begins with it, so all of
        /// it is cleaned as one pass. The reason is in plain words because the record shows
        /// it to a person.
        case unusable(String)
        /// The groups, tidied (or as the rules left them, for one that ran out of grace),
        /// and the text that is left over.
        case usable(head: CleanupHead, remainder: String)
    }

    private func resolvePreclean(
        _ head: CleanupHead?,
        of text: String
    ) -> PrecleanOutcome {
        guard let head, !head.stageA.isEmpty else { return .none }
        guard let remainder = Self.remainder(of: text, afterPrefix: head.rawPrefix) else {
            return .unusable(
                "the final text no longer matched the sentences prepared while you were "
                    + "speaking, so all of it was tidied at the end"
            )
        }
        return .usable(head: head, remainder: remainder)
    }

    private func resolvePrecleanGroups(_ head: CleanupHead) async -> [String] {
        let deadline = ContinuousClock.now.advanced(by: precleanGrace)
        var pieces: [String] = []
        for (index, pair) in zip(head.stageA, head.cleaned).enumerated() {
            let (spoken, task) = pair
            let left = deadline - ContinuousClock.now
            // The same producer publishes this result just before returning its Task.
            // Ready groups need no deadline task pair or await. Preserve expiration,
            // cancellation and empty-answer behavior of the existing bounded wait.
            if left > .zero, !Task.isCancelled, head.completed.indices.contains(index),
               let landed = head.completed[index].value {
                pieces.append(landed.isEmpty ? spoken : landed)
                continue
            }
            if left > .zero, let landed = await withBoundedWait(left, { await task.value }),
               !landed.isEmpty {
                pieces.append(landed)
            } else {
                // Not yet, or cancelled with the hold: the rules' own text, which is what
                // the same call returns when it runs out of time. Never a cancellation —
                // a landed answer is never thrown away to save a moment.
                pieces.append(spoken)
            }
        }
        return pieces
    }

    /// The text after `prefix`, or nil when `text` does not begin with it.
    ///
    /// Compared with whitespace squeezed to single spaces, because a group's text and the
    /// slice of the final transcript it came from were each written by the rules pass and
    /// can differ in spacing; everything else has to match character for character, or one
    /// of the sentences was revised and the group is stale. The remainder is cut out of the
    /// *original* text rather than the squeezed one, so the tail keeps its own spacing and
    /// its own paragraph breaks.
    static func remainder(of text: String, afterPrefix prefix: String) -> String? {
        let target = Array(squeeze(prefix))
        if target.isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var matched = 0
        var index = text.startIndex
        // Match the same whitespace contract squeeze() applies to the saved prefix.
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        while index < text.endIndex, matched < target.count {
            let character = text[index]
            if character.isWhitespace || character.isNewline {
                guard target[matched] == " " else { return nil }
                repeat { index = text.index(after: index) }
                while index < text.endIndex && text[index].isWhitespace
                matched += 1
                continue
            }
            guard character == target[matched] else { return nil }
            matched += 1
            index = text.index(after: index)
        }
        guard matched == target.count else { return nil }
        // A prefix can finish at a word boundary; it cannot consume part of a revised word.
        if index < text.endIndex, let last = target.last,
           (last.isLetter || last.isNumber),
           (text[index].isLetter || text[index].isNumber) { return nil }
        return String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One space per run of whitespace, and no leading or trailing space.
    private static func squeeze(_ text: String) -> String {
        var out = ""
        for character in text {
            if character.isWhitespace || character.isNewline {
                if !out.isEmpty, !out.hasSuffix(" ") { out.append(" ") }
            } else {
                out.append(character)
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// How long to wait for the layout pass once the cleanup has finished, and what to do
    /// when the wait is up. (D-09.)
    ///
    /// The pass runs *beside* the cleanup, so the only question left is what to do with its
    /// answer. Three cases, in order:
    ///
    /// - **it is already here** — take it, whatever the clock says. This is the whole point
    ///   of starting it early, and it is read from a box rather than from the task so a
    ///   finished plan cannot lose a race to a timer on a loaded machine;
    /// - **the model route** — the user has waited as long as this passage's plan is worth,
    ///   so wait out whatever is left of that budget and at least the grace, then cancel
    ///   and say so;
    /// - **the rules route** — there is no cleanup to hide a slow plan inside, so the user
    ///   would wait the whole plan (3.5–9.2 s measured) for text the rules finished in
    ///   milliseconds. The route exists because the user asked for speed, so it waits
    ///   `layoutGrace` and no more; the plan keeps its own deadline in the background.
    private func resolveLayoutPlan(
        _ planTask: Task<StructurePlanOutcome, Never>,
        answered: LockedBox<StructurePlanOutcome?>,
        sentences: [String],
        began: ContinuousClock.Instant,
        waitIsBounded: Bool
    ) async -> StructurePlanOutcome {
        if let ready = answered.value { return ready }

        let spent = ContinuousClock.now - began
        let wait = waitIsBounded
            ? max(layoutWait(sentences.count) - spent, layoutGrace)
            : layoutGrace
        if let finished = await withBoundedWait(wait) { await planTask.value } {
            return finished
        }
        // The wait is the user's, not the plan's: it goes on inside the pass's own ceiling,
        // and nothing here waits for it.
        planTask.cancel()
        let total = Self.seconds(spent + wait)
        return .failed(
            String(format: "the layout pass ran out of time after %.1fs", total),
            seconds: total
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
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
    private static func words(in text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
    }

    private static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static let leftoverFillers: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mhm", "heu", "euh"
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
