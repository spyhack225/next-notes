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
/// model there loses the tag outright instead of merely roughening the text. Qwen is never
/// forced on.
///
/// S1-mini still takes no instructions. The router will not pretend a target profile or
/// the screen-name harvest can reach it. Qwen is constructible as a seam and is never
/// chosen from Settings; `QwenCleanupFormatter` must not call `beginCleanup()`.
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

    init(
        semantic: any TextFormatter,
        engine: CleanupSemanticEngine,
        rules: any TextFormatter = RuleBasedFormatter(),
        formatsLists: Bool = false,
        targetRendersLists: Bool = false,
        mentionsScreenName: Bool = false,
        skipsModelWhenBusy: Bool = false,
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
        self.pressureSample = pressureSample
    }

    func format(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let afterRules = await rules.format(trimmed)
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
        Log.speech.info("\(decision.logLine, privacy: .public)")

        switch decision.stage {
        case .rules:
            return afterRules
        case .semantic:
            guard !afterRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return afterRules
            }
            // Stage B sees the rules output, not the raw ASR: the model is repairing
            // what is left, and a timeout must keep that work (`KeepAsIsFormatter`
            // on Apple / Qwen) rather than fall back through rules a second time.
            return await semantic.format(afterRules)
        }
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

    /// Stage B formatter for a named engine. Qwen is here so a later picker can
    /// construct it; production never passes `.qwen`.
    ///
    /// Apple and Qwen used as Stage B fall back to `KeepAsIsFormatter`: the input has
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
        context: ScreenContext
    ) -> any TextFormatter {
        switch engine {
        case .apple:
            return FoundationModelFormatter(
                preferences: preferences,
                fixesGrammar: fixesGrammar,
                target: target,
                context: context,
                fallback: KeepAsIsFormatter()
            )
        case .s1Mini:
            return S1MiniFormatter(preferences: preferences)
        case .qwen:
            // Must not call LlamaBackend.beginCleanup — QwenCleanupFormatter is the
            // notes model, and announcing it to the gate deadlocks the load.
            return QwenCleanupFormatter(
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
        skipsModelWhenBusy: Bool
    ) -> CleanupRouter {
        let engine = preferredEngine(choice: choice, fixesGrammar: fixesGrammar)
        let semantic = makeSemantic(
            engine,
            preferences: preferences,
            fixesGrammar: fixesGrammar,
            target: target,
            context: context
        )
        let targetRendersLists = target.capabilities.contains(.bullets)
            || target.capabilities.contains(.numbered)
        return CleanupRouter(
            semantic: semantic,
            engine: engine,
            formatsLists: preferences.formatsLists,
            targetRendersLists: targetRendersLists,
            mentionsScreenName: context.mentionCount > 0,
            skipsModelWhenBusy: skipsModelWhenBusy
        )
    }

    /// Pure policy. `afterRules` is what would be injected if Stage B is skipped.
    ///
    /// Stage B runs on anything with text left in it, unless `skipsModelWhenBusy` is on and
    /// `pressure` is up: then short and soft-only ("borderline") transcripts stay on rules,
    /// while long transcripts that still need a hard repair, and any transcript that names
    /// something on screen, keep the caller's Stage B engine — never Qwen, never a forced
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
        if formatsLists, targetRendersLists, engine.acceptsInstructions, looksLikeSpokenList(cleaned) {
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

        let qwen = makeSemantic(
            .qwen,
            preferences: CleanupPreferences(tone: .balanced, formatsLists: true, context: .general),
            fixesGrammar: true,
            target: .plain(bundleID: "", displayName: "the focused app"),
            context: .empty
        )
        if !(qwen is QwenCleanupFormatter) {
            failures.append("makeSemantic(.qwen) did not return QwenCleanupFormatter")
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

        if failures.isEmpty {
            emit("CLEANUP_ROUTER_OK")
            return true
        }
        for failure in failures { emit("  \(failure)") }
        emit("CLEANUP_ROUTER_FAILED: \(failures.count) case(s)")
        return false
    }

    private static func emit(_ line: String) {
        let text = "\(line)\n"
        FileHandle.standardOutput.write(Data(text.utf8))
        Log.speech.info("selftest · \(line, privacy: .public)")
        guard let path = SelfTest.outputPath else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
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
