import Foundation

/// Live measurements of the layout pass, against the model actually on this Mac.
///
/// ## Why this is a probe and not a self-test
///
/// Everything in `CleanupRouter.structurePlanFailures` is deterministic and model-free,
/// because a suite that needs Apple Intelligence is a suite that does not run on CI, on a
/// Mac with the feature off, or in under a second. But the three numbers that decide
/// whether Stage D is worth having at all — how long a plan takes cold, warm and prewarmed;
/// whether eliding the middle of a sentence changes the answer; whether a whole dictation
/// now fits in the budget — cannot be answered without the model.
///
/// So this runs only when `--probe-layout` is passed alongside `--selftest-cleanup-router`,
/// prints what it measured, and asserts nothing. Reading its output is the point.
enum StructurePlanProbe {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--probe-layout")
    }

    static func run() async {
        emit("")
        emit("=== layout probe (live Apple Intelligence) ===")
        guard FoundationModelFormatter.isAvailable else {
            emit("  unavailable: \(FoundationModelFormatter.unavailableReason ?? "unknown")")
            return
        }

        // End to end first, in a process that has made no other model call: the cold start
        // is part of what a real dictation pays, and a dozen measurement calls ahead of it
        // would hide that and warm the model into the bargain.
        await measureEndToEnd()
        await measurePlanLatency()
        await measurePromptSize()
        await measureOverlapCost()
    }

    // MARK: - What the layout pass costs the cleanup it runs beside

    /// The cleanup alone, then the same cleanup with the layout pass running beside it.
    ///
    /// I1-03's risk, stated as a number: two requests on one on-device model slow each
    /// other, and if the plan costs the cleanup more than the plan saves then starting it
    /// early is a loss dressed as a win. The rule from the task is that if the difference
    /// is against the pass, the plan moves to after Stage B — and moving it is a design
    /// change, so the decision needs a measurement behind it rather than an intuition.
    ///
    /// Both legs are the real router over the same dictation, and the order is alone-then-
    /// beside so the model is already resident in both. The second leg is deliberately not
    /// re-run: a third call would measure a warmer model than the first two and quietly
    /// flatter the pass.
    /// Twelve sentences of ordinary prose: no ordinal, no "first thing", nothing Stage C's
    /// rules can lay out.
    ///
    /// It has to be like that, and it is worth saying why rather than reaching for a real
    /// dictation. A dictation the rules *can* handle never reaches the layout pass at all —
    /// `measureEndToEnd` above runs the 2026-09-20 dictation and records `structure: rules`,
    /// `layout 0.00s`, because Stage C found both of its items without a model. Measuring
    /// the overlap on that passage measures the overlap on nothing, which is exactly what
    /// the first run of this probe did before the fixture was fixed.
    private static let proseFixture = """
        We finished the review this morning and everyone signed off on the plan. \
        The release is scheduled for Friday afternoon as discussed. \
        I will send the notes round once the build is green. \
        Separately, the onboarding copy still reads as though we charge for the trial. \
        Marketing have a rewrite in hand and it should land this week. \
        The installer is signed and packaged, and it copies the models across on the first run. \
        Support will keep an eye on the forum through the weekend. \
        The dashboard shows how many holds reached a finished sentence without an error. \
        Nobody has looked at the failure list since the thirtieth. \
        The search page is slow on a cold cache, which is most first runs. \
        We can ship with that and fix it after the launch, or hold the release for a week. \
        There is nothing else outstanding on my side at the moment.
        """

    private static func measureOverlapCost() async {
        emit("")
        emit("  -- overlap cost --")
        let target = OutputProfile(
            bundleID: "com.anthropic.claudefordesktop",
            displayName: "Claude",
            capabilities: [.markdown, .bullets, .numbered, .tables, .code]
        )
        let preferences = CleanupPreferences(tone: .balanced, formatsLists: true, context: .general)
        let sentences = SpokenStructure.sentenceSplit(proseFixture)
        emit("  fixture: \(sentences.count) sentences, \(SentenceChunker.wordCount(proseFixture)) words")
        emit("  order: cleanup alone, then the same cleanup with the layout pass beside it")

        // Warm first, or the first leg pays the wake-up and the difference *is* the wake-up.
        _ = try? await FoundationModelFormatter.clean(
            "okay so um I think we should ship it on friday",
            preferences: AppleModelWarmth.warmPreferences,
            fixesGrammar: AppleModelWarmth.warmFixesGrammar
        )

        func leg(_ layoutPass: CleanupRouter.LayoutPass) async -> (cleanup: Double, plan: Double?, record: CleanupRecord) {
            let trace = CleanupTrace()
            let router = CleanupRouter.production(
                choice: .apple,
                preferences: preferences,
                fixesGrammar: true,
                target: target,
                context: .empty,
                skipsModelWhenBusy: false,
                trace: trace,
                layoutPass: layoutPass
            )
            let began = Date()
            _ = await router.format(proseFixture)
            let record = trace.snapshot
            return (Date().timeIntervalSince(began), record.structurePlanSeconds, record)
        }

        let alone = await leg(.omitted)
        let beside = await leg(.automatic)
        // A plan of 0.00 s with nothing asked of it is not a fast layout, it is no layout:
        // say which, rather than report a number that reads like a good result.
        let asked = beside.record.structurePlanModel != nil
        let planText = beside.plan.map { String(format: "%.2f", $0) } ?? "unavailable"
        emit(String(
            format: "LAYOUT_OVERLAP cleanup_alone=%.2f cleanup_beside_plan=%.2f plan=%@",
            alone.cleanup, beside.cleanup, planText
        ))
        guard asked, let plan = beside.plan else {
            emit("LAYOUT_OVERLAP_RULE: the layout pass was not asked on this fixture, "
                + "so the overlap is unmeasured — the two numbers above are the same pass twice")
            return
        }
        emit("  beside: layout by \(beside.record.structurePlanModel ?? "?") in "
            + String(format: "%.2f", plan) + "s · structure: "
            + (beside.record.structureSource ?? "none"))
        let cost = beside.cleanup - alone.cleanup
        emit(String(
            format: "LAYOUT_OVERLAP_RULE: the pass costs the cleanup %.2fs and saves up to %.2fs"
                + " of layout, so running it beside is %@",
            cost, plan, cost <= plan ? "the cheaper trade" : "NOT the cheaper trade"
        ))
    }

    // MARK: - How long a plan takes

    /// Cold, warm and prewarmed, at three passage lengths.
    ///
    /// "Cold" is the first call in this process, which is the latency a real dictation gets
    /// on a Mac where the model has idled out. "Warm" is a fresh session against a model
    /// that is already resident. "Prewarmed" is a session staged a moment earlier, which is
    /// what `DictationController` now does at key-down for this prompt as well as for the
    /// cleanup prompt.
    private static func measurePlanLatency() async {
        emit("")
        emit("  -- plan latency --")
        emit("  words  sentences  state        seconds  blocks  outcome")
        // Twenty seconds, which is not a budget anyone would ship — the point of this table
        // is to find out how long the pass actually takes, and a measurement that stops at
        // the shipping deadline only ever reports the deadline back.
        let planner = AppleStructurePlanner(budget: .seconds(20))

        for target in [100, 200, 300] {
            let sentences = passage(ofAbout: target)
            let words = sentences.reduce(0) { $0 + SentenceChunker.wordCount($1) }

            for state in ["cold", "warm", "prewarmed"] {
                if state == "prewarmed" {
                    await CleanupSessionWarmer.shared.stage(
                        instructions: StructurePlanPrompt.system
                    )
                    // A staged session is only worth anything once the framework has had a
                    // moment to act on `prewarm()`; at key-down it gets seconds of speech.
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    await CleanupSessionWarmer.shared.clear()
                }
                let began = Date()
                let outcome = await planner.plan(for: sentences)
                let seconds = Date().timeIntervalSince(began)
                emit("  " + pad("\(words)", 7) + pad("\(sentences.count)", 11)
                    + pad(state, 13)
                    + pad(String(format: "%.2f", seconds), 9)
                    + pad("\(outcome.plan?.blocks.count ?? 0)", 8)
                    + (outcome.rejection ?? "ok"))
            }
        }
    }

    // MARK: - Does the smaller prompt still find the boundaries

    /// The elided prompt against the whole one, on the two real dictations.
    ///
    /// The claim under test is narrow and checkable: a block boundary is announced in the
    /// first few words of a sentence and lands in the last few of the one before it, so the
    /// middle of a long sentence is not evidence about where a boundary is. If that is true
    /// the two prompts produce the same plan and the elided one produces it sooner.
    private static func measurePromptSize() async {
        emit("")
        emit("  -- prompt size --")
        let planner = AppleStructurePlanner(budget: .seconds(20))

        for (name, text) in [
            ("2026-09-20T15:37:30Z (89s, four items)", StructureFixtures.realDictation),
            ("2026-09-20T20:47:25Z (41s, two items)", StructureFixtures.labelledDictation),
        ] {
            let sentences = SpokenStructure.sentenceSplit(text)
            let whole = sentences.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            let elided = StructurePlanPrompt.user(sentences: sentences)
            emit("  \(name)")
            emit(String(
                format: "    prompt %d chars whole, %d chars elided (%.0f%%)",
                whole.count,
                elided.count,
                100.0 * Double(elided.count) / Double(max(1, whole.count))
            ))
            for eliding in [false, true] {
                var variant = planner
                variant.elides = eliding
                await CleanupSessionWarmer.shared.clear()
                let began = Date()
                let outcome = await variant.plan(for: sentences)
                emit(String(
                    format: "    %@  %.2fs  %@",
                    eliding ? "elided" : "whole ",
                    Date().timeIntervalSince(began),
                    describe(outcome, sentences: sentences)
                ))
            }
        }
    }

    // MARK: - The whole pass, end to end

    /// The real dictation through the real router, with the real model, twice.
    ///
    /// Twice because the first call in a process pays the cold start and a real dictation
    /// does not — `DictationController` stages both sessions while the key is still down.
    /// The second run is the one the target of "40 seconds of speech, cleaned and structured
    /// in seven" should be read against.
    private static func measureEndToEnd() async {
        emit("")
        emit("  -- end to end, 2026-09-20T20:47:25Z (41s of speech) --")
        let target = OutputProfile(
            bundleID: "com.anthropic.claudefordesktop",
            displayName: "Claude",
            capabilities: [.markdown, .bullets, .numbered, .tables, .code]
        )
        let preferences = CleanupPreferences(
            tone: .balanced,
            formatsLists: true,
            context: .general
        )

        for run in ["cold", "prewarmed"] {
            await CleanupSessionWarmer.shared.clear()
            let trace = CleanupTrace()
            let router = CleanupRouter.production(
                choice: .apple,
                preferences: preferences,
                fixesGrammar: true,
                target: target,
                context: .empty,
                skipsModelWhenBusy: false,
                trace: trace
            )
            if run == "prewarmed" {
                // Exactly what the key going down does.
                await CleanupSessionWarmer.shared.stage(
                    instructions: CleanupInstructions.system(
                        for: preferences,
                        fixesGrammar: true,
                        target: target
                    )
                )
                await CleanupSessionWarmer.shared.stage(
                    instructions: StructurePlanPrompt.system
                )
                try? await Task.sleep(for: .seconds(1))
            }
            let began = Date()
            let output = await router.format(StructureFixtures.labelledDictationRaw)
            let seconds = Date().timeIntervalSince(began)
            let record = trace.snapshot

            emit("")
            emit("  [\(run)] \(String(format: "%.2f", seconds))s total"
                + " · cleanup \(String(format: "%.2f", record.modelSeconds ?? 0))s"
                + " · layout \(String(format: "%.2f", record.structurePlanSeconds ?? 0))s"
                + " · \(record.chunks ?? 1) chunk(s)")
            emit("  guard: \(record.guardVerdict ?? "not reached")"
                + (record.fallbackReason.map { " (\($0))" } ?? ""))
            emit("  structure: \(record.structureSource ?? "none")"
                + " · markers seen: \(record.structureMarkersSeen ?? false)"
                + " · applied: \((record.structureApplied ?? []).joined(separator: ", "))")
            if let why = record.noStructureReason { emit("  why none: \(why)") }
            if let rejected = record.structurePlanRejected {
                emit("  layout plan not used: \(rejected)")
            }
            emit("  ---- rendered output ----")
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                emit("  | \(line)")
            }
            emit("  -------------------------")
        }
    }

    // MARK: - Helpers

    /// A passage of about `words` words, built by repeating the two real dictations rather
    /// than by generating filler: the thing being timed is how the model reads *speech*, and
    /// a paragraph of lorem ipsum has neither the sentence lengths nor the announcements.
    private static func passage(ofAbout words: Int) -> [String] {
        let pool = SpokenStructure.sentenceSplit(StructureFixtures.realDictation)
            + SpokenStructure.sentenceSplit(StructureFixtures.labelledDictation)
        var result: [String] = []
        var total = 0
        var index = 0
        while total < words, index < pool.count * 4 {
            let sentence = pool[index % pool.count]
            result.append(sentence)
            total += SentenceChunker.wordCount(sentence)
            index += 1
        }
        return result
    }

    private static func describe(
        _ outcome: StructurePlanOutcome,
        sentences: [String]
    ) -> String {
        guard let plan = outcome.plan else {
            return "none (\(outcome.rejection ?? "no reason given"))"
        }
        let shape = plan.blocks.map { block -> String in
            let range = "\(block.from)\u{2013}\(block.to)"
            guard block.kind.isList else { return "\(block.kind.rawValue) \(range)" }
            return "\(block.kind.rawValue) \(range) items \(block.itemStarts)"
        }.joined(separator: " | ")
        let refusal = plan.rejection(sentenceCount: sentences.count)
            ?? plan.corroborationFailure(sentences: sentences)
        return shape + (refusal.map { "  [turned down: \($0)]" } ?? "  [accepted]")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? text + " "
            : text + String(repeating: " ", count: width - text.count)
    }

    private static func emit(_ line: String) {
        CleanupSelfTestLog.emit(line)
    }
}
