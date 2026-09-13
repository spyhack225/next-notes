import Foundation

/// Two-stage dictation cleanup: deterministic rules first, a model only when gated.
///
/// Every utterance pays Stage A (`RuleBasedFormatter`). Stage B is the engine the user
/// already picked in Settings — Apple, or S1-mini when grammar is off — and it runs only
/// when the rules pass left something a model is for: a long hold, a false start, a
/// stutter, broken agreement, a spoken list the target can actually render.
///
/// Short and already-clean text never touches a model. That is the whole point of this
/// type: a four-word "The build is green." used to wait on Apple or S1 for work rules
/// had already finished.
///
/// Under compute pressure (memory warning, thermal / low-power, or live scheduler
/// occupancy for realtime-ASR / notes `.background`) borderline and short-messy
/// transcripts stay on rules so Stage B does not fight the live path for GPU. Idle
/// keeps the user's Stage B engine. Qwen is never forced on.
///
/// S1-mini still takes no instructions. The router will not pretend a target profile or
/// the screen-name harvest can reach it. Qwen is constructible as a seam and is never
/// chosen from Settings; `QwenCleanupFormatter` must not call `beginCleanup()`.
struct CleanupRouter: TextFormatter {
    /// One spoken sentence, give or take. Above this, even tidy prose goes to Stage B.
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
    private let pressureSample: @Sendable () async -> CleanupComputePressure

    init(
        semantic: any TextFormatter,
        engine: CleanupSemanticEngine,
        rules: any TextFormatter = RuleBasedFormatter(),
        formatsLists: Bool = false,
        targetRendersLists: Bool = false,
        pressureSample: @escaping @Sendable () async -> CleanupComputePressure = {
            await CleanupPressureProbe.sample()
        }
    ) {
        self.rules = rules
        self.semantic = semantic
        self.engine = engine
        self.formatsLists = formatsLists
        self.targetRendersLists = targetRendersLists
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
        context: ScreenContext
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
            targetRendersLists: targetRendersLists
        )
    }

    /// Pure policy. `afterRules` is what would be injected if Stage B is skipped.
    ///
    /// Under `pressure`, short-messy and soft-only ("borderline") transcripts stay on
    /// rules. Long transcripts that still need a hard repair keep the caller's Stage B
    /// engine — never Qwen, never a forced upgrade.
    static func decide(
        raw: String,
        afterRules: String,
        engine: CleanupSemanticEngine,
        formatsLists: Bool = false,
        targetRendersLists: Bool = false,
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

        if issues.isEmpty {
            return CleanupDecision(
                stage: .rules,
                engine: engine,
                reasons: [.shortAndClean],
                wordCount: wordCount,
                pressure: pressure
            )
        }

        if pressure.isUnderPressure, shouldDeferUnderPressure(issues: issues, wordCount: wordCount) {
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
    /// Not wired into `NextNotesApp.runRequestedSelfTest` this wave. Call this
    /// directly, or later as `--selftest-cleanup-router`.
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
            let formatsLists: Bool
            let targetRendersLists: Bool
            let pressure: CleanupComputePressure
            let expectModel: Bool
        }

        let underPressure = CleanupComputePressure.simulated(realtimeASRBusy: true)
        let notesPressure = CleanupComputePressure.simulated(notesBusy: true)
        let memoryPressure = CleanupComputePressure.simulated(memoryWarning: true)

        let cases: [Case] = [
            Case(id: "short-clean", input: "The build is green.",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: .idle, expectModel: false),
            Case(id: "short-raw", input: "hello",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: .idle, expectModel: false),
            Case(id: "ship-it", input: "Ship it.",
                 engine: .s1Mini, formatsLists: false, targetRendersLists: false,
                 pressure: .idle, expectModel: false),
            Case(id: "question-stays-a-question", input: "what is the capital of france",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: .idle, expectModel: false),
            Case(id: "filler-only", input: "um uh",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: .idle, expectModel: false),
            Case(id: "agreement",
                 input: "the tests is passing on my machine but they was failing in ci yesterday",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: .idle, expectModel: true),
            Case(id: "self-correction",
                 input: "so um i need to send the report by friday no wait make that thursday",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: .idle, expectModel: true),
            Case(id: "stutter",
                 input: "we we need to to check the the database connection again",
                 engine: .s1Mini, formatsLists: false, targetRendersLists: false,
                 pressure: .idle, expectModel: true),
            Case(id: "long-clean",
                 input: "We finished the review this morning and everyone signed off on the plan. "
                    + "The release is scheduled for Friday afternoon as discussed.",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: .idle, expectModel: true),
            Case(id: "spoken-list",
                 input: "First milk. Second eggs. Third bread.",
                 engine: .apple, formatsLists: true, targetRendersLists: true,
                 pressure: .idle, expectModel: true),
            Case(id: "spoken-list-s1-cannot-format",
                 input: "First milk. Second eggs. Third bread.",
                 engine: .s1Mini, formatsLists: true, targetRendersLists: true,
                 pressure: .idle, expectModel: false),
            // Wave 3: under pressure, messy-but-short stays on rules.
            Case(id: "pressure-messy-short-asr",
                 input: "the tests is passing on my machine but they was failing in ci yesterday",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: underPressure, expectModel: false),
            Case(id: "pressure-messy-short-notes",
                 input: "we we need to to check the the database connection again",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: notesPressure, expectModel: false),
            Case(id: "pressure-messy-short-memory",
                 input: "so um i need to send the report by friday no wait make that thursday",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: memoryPressure, expectModel: false),
            // Soft-only / borderline under pressure → rules.
            Case(id: "pressure-borderline-long-clean",
                 input: "We finished the review this morning and everyone signed off on the plan. "
                    + "The release is scheduled for Friday afternoon as discussed.",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: underPressure, expectModel: false),
            Case(id: "pressure-borderline-spoken-list",
                 input: "First milk. Second eggs. Third bread.",
                 engine: .apple, formatsLists: true, targetRendersLists: true,
                 pressure: underPressure, expectModel: false),
            // Long + hard under pressure still reaches the user's Stage B engine.
            Case(id: "pressure-long-hard-still-semantic",
                 input: "We finished the review this morning and everyone signed off on the plan. "
                    + "The release is scheduled for Friday afternoon as discussed, but the tests is "
                    + "still red on main and they was failing all morning.",
                 engine: .apple, formatsLists: false, targetRendersLists: false,
                 pressure: underPressure, expectModel: true),
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
                pressure: test.pressure
            )
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
