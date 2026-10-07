import Foundation

/// Exercises the actual router with a head that can finish only once tail cleanup starts.
/// No model, microphone, history, defaults or owner data is used.
enum DictationCleanupLatencySelfTest {
    private struct Tail: TextFormatter {
        let started: CleanupAdmission
        func format(_ raw: String) async -> String {
            started.admit()
            return raw.uppercased()
        }
    }

    private struct DelayedHead: TextFormatter {
        let started: CleanupAdmission
        func format(_ raw: String) async -> String {
            _ = await started.wait()
            try? await Task.sleep(for: .milliseconds(100))
            return raw.uppercased()
        }
    }

    private struct JoinHead: TextFormatter {
        let started: CleanupAdmission
        let task: Task<String, Never>
        func format(_ raw: String) async -> String {
            started.admit()
            _ = await task.value
            return raw.uppercased()
        }
    }

    static func failures() async -> [String] {
        var failures: [String] = []
        let prefix = "The first sentence. The second sentence."
        for text in [
            "The first sentence.  The second sentence. Tail here.",
            "The first sentence.\n\nThe second sentence. Tail here.",
            "  The first sentence.\t The second sentence. Tail here."
        ] {
            if CleanupRouter.remainder(of: text, afterPrefix: prefix) != "Tail here." {
                failures.append("pre-clean matching rejects equivalent whitespace")
            }
        }
        if CleanupRouter.remainder(of: "Reported today.", afterPrefix: "Report") != nil {
            failures.append("pre-clean matching accepts a prefix ending inside a word")
        }
        if CleanupRouter.remainder(of: "The first sentence.\n\nA new paragraph.\nAnother line.",
                                   afterPrefix: "The first sentence.") != "A new paragraph.\nAnother line." {
            failures.append("pre-clean matching changes the remainder's paragraph breaks")
        }

        let started = CleanupAdmission()
        let spoken = "The first sentence is ready."
        let task = Task {
            _ = await started.wait()
            return spoken.uppercased()
        }
        let head = CleanupHead(rawPrefix: spoken, cleaned: [task], stageA: [spoken])
        let trace = CleanupTrace()
        let output = await CleanupRouter(
            semantic: Tail(started: started), engine: .apple,
            rules: KeepAsIsFormatter(), trace: trace, precleanGrace: .milliseconds(100)
        ).format(spoken + " The remaining sentence arrives.", head: head)
        if output != "THE FIRST SENTENCE IS READY. THE REMAINING SENTENCE ARRIVES." {
            failures.append("tail cleanup waits behind the head and loses its finished polishing")
        }
        if trace.snapshot.precleanedGroups != 1 {
            failures.append("the actual router did not use the pre-cleaned head")
        }
        started.close()
        _ = await task.value

        let tailStarted = CleanupAdmission()
        let preclean = IncrementalCleanupSession(semantic: DelayedHead(started: tailStarted), rules: { $0 })
        await preclean.notePartial(spoken, committed: spoken)
        let producedHead = await preclean.head()
        guard let lateHead = producedHead.cleaned.first else {
            failures.append("late-head fixture never entered the actual pre-clean producer")
            return failures
        }
        let lateTrace = CleanupTrace()
        let lateOutput = await CleanupRouter(
            semantic: JoinHead(started: tailStarted, task: lateHead), engine: .apple,
            rules: KeepAsIsFormatter(), trace: lateTrace, precleanGrace: .milliseconds(10)
        ).format(spoken + " The remaining sentence arrives.", head: producedHead)
        if lateOutput != "THE FIRST SENTENCE IS READY. THE REMAINING SENTENCE ARRIVES." {
            failures.append("router discards a polished head that completed during tail cleanup")
        }
        _ = await lateHead.value
        if lateTrace.snapshot.precleanAnsweredGroups != 1 {
            failures.append("completed-head measurement misses the answer retained during tail polishing")
        }

        // Apple's response can be executing native work that ignores cancellation.
        // Exercise the real formatter's deadline, then release that same response so
        // this fixture leaves no background job behind.
        let entered = CleanupAdmission()
        let release = CleanupAdmission()
        let raw = "The project is ready for review."
        var apple = FoundationModelFormatter(fallback: KeepAsIsFormatter())
        apple.timeScale = 0.01
        apple.modelCall = CleanupModelCall(
            takeSession: { _ in true },
            respond: { _ in
                entered.admit()
                _ = await release.wait()
                return raw
            }
        )
        let formatter = apple
        let response = Task { await formatter.format(raw) }
        if await withBoundedWait(.seconds(1), { await entered.wait() }) != true {
            failures.append("Apple deadline fixture never entered the actual response")
        }
        let timed = await withBoundedWait(.milliseconds(250), { await response.value })
        release.admit()
        _ = await response.value
        if timed != raw {
            failures.append("Apple cleanup deadline waits for a response that ignores cancellation")
        }
        failures += await DictationController.fileTaggingLatencyFailures()
        failures += await DictationController.incrementalClosureFailures()
        failures += await cancelledPrecleanFailures()
        failures += await layoutDeadlineFailures()
        failures += await localLayoutDeadlineFailures()
        failures += await quotedPrefixFailures()
        failures += await unusedPrecleanFailures()
        failures += await expiredPrecleanFailures()
        failures += await supersededLayoutFailures()
        failures += await cancelledLayoutFailures()
        return failures
    }

    private static let layoutProse = "We reviewed the recording with the team and checked whether everyone could follow the instructions. The first question was about improving the welcome experience before the next release. We also discussed how people find their documents and how they recover changes after an interruption. Please keep the existing behavior and make the interface easier to understand for everyone who uses it. Tomorrow the team can verify the result and prepare the final update together."

    private static func cancelledLayoutFailures() async -> [String] {
        struct HeldPlanner: StructurePlanning {
            let entered: CleanupAdmission
            let release: CleanupAdmission
            let returned: CleanupAdmission
            let cancelled: LockedBox<Bool>
            var planName: String { "held fixture" }
            func plan(for sentences: [String], deadline: Duration?) async -> StructurePlanOutcome {
                await withTaskCancellationHandler {
                    entered.admit()
                    _ = await release.wait()
                    returned.admit()
                    return .failed("released", seconds: 0)
                } onCancel: { cancelled.value = true }
            }
        }
        struct HeldSemantic: TextFormatter {
            let entered: CleanupAdmission
            let release: CleanupAdmission
            func format(_ raw: String) async -> String {
                entered.admit()
                _ = await release.wait()
                return raw
            }
        }
        let entered = CleanupAdmission(), release = CleanupAdmission(), returned = CleanupAdmission()
        let semanticEntered = CleanupAdmission(), semanticRelease = CleanupAdmission()
        let cancelled = LockedBox(false)
        let router = CleanupRouter(semantic: HeldSemantic(entered: semanticEntered, release: semanticRelease),
            engine: .apple, rules: KeepAsIsFormatter(), formatsLists: true,
            structurePlanner: HeldPlanner(entered: entered, release: release, returned: returned, cancelled: cancelled))
        let task = Task { await router.format(layoutProse) }
        let didEnter = await withBoundedWait(.seconds(1)) { await entered.wait() } == true
        _ = await withBoundedWait(.seconds(1)) { await semanticEntered.wait() }
        task.cancel()
        let forwarded = cancelled.value
        release.admit(); semanticRelease.admit()
        _ = await task.value; _ = await returned.wait()
        return !didEnter || !forwarded
            ? ["cancelling actual router while semantic cleanup is held leaves layout work entered"] : []
    }

    private static func supersededLayoutFailures() async -> [String] {
        struct HeldPlanner: StructurePlanning {
            let entered: CleanupAdmission
            let release: CleanupAdmission
            let returned: CleanupAdmission
            let cancelled: LockedBox<Bool>
            var planName: String { "fixture" }
            func plan(for sentences: [String], deadline: Duration?) async -> StructurePlanOutcome {
                await withTaskCancellationHandler {
                    entered.admit()
                    _ = await release.wait()
                    returned.admit()
                    return .failed("fixture released", seconds: 0)
                } onCancel: { cancelled.value = true }
            }
        }
        struct Cleaned: TextFormatter {
            let plannerEntered: CleanupAdmission
            let text: String
            func format(_ raw: String) async -> String {
                _ = await plannerEntered.wait()
                return text
            }
        }
        let raw = "We have the first point to review the login page before the next release because people cannot find the recovery button. We have the second point to check the settings page because the save button does not stay visible while scrolling through the options. We have the third point to check the welcome page because the introductory text needs a clearer explanation of what happens next. The whole update should be ready for review tomorrow."
        let cleaned = "First point, review the login page before the next release because people cannot find the recovery button. Second point, check the settings page because the save button does not stay visible while scrolling through the options. Third point, check the welcome page because the introductory text needs a clearer explanation of what happens next. The whole update should be ready for review tomorrow."
        let target = OutputProfile(bundleID: "fixture", displayName: "fixture", capabilities: [.markdown, .bullets, .numbered])
        let before = SpokenStructure.apply(to: raw, target: target, isEnabled: true)
        let after = SpokenStructure.apply(to: cleaned, target: target, isEnabled: true)
        guard before.applied.isEmpty, !after.applied.isEmpty,
              StructurePlan.isWorthPlanning(sentences: SpokenStructure.sentenceSplit(raw),
                                            wordCount: SentenceChunker.wordCount(raw), sawMarkers: before.markersSeen) else {
            return ["superseded layout fixture did not exercise structure found after cleanup"]
        }
        let entered = CleanupAdmission(), release = CleanupAdmission(), returned = CleanupAdmission()
        let cancelled = LockedBox(false)
        let planner = HeldPlanner(entered: entered, release: release, returned: returned, cancelled: cancelled)
        let trace = CleanupTrace()
        let began = ContinuousClock.now
        let output = await CleanupRouter(
            semantic: Cleaned(plannerEntered: entered, text: cleaned), engine: .apple,
            rules: KeepAsIsFormatter(), formatsLists: true, targetRendersLists: true,
            target: target, trace: trace, structurePlanner: planner,
            layoutWait: { _ in .seconds(1) }, layoutGrace: .seconds(1)
        ).format(raw)
        let elapsed = ContinuousClock.now - began
        let stopped = cancelled.value
        release.admit(); _ = await returned.wait()
        var failures: [String] = []
        if elapsed >= .milliseconds(500) {
            failures.append("router waits for a layout plan after its own rules already produced the final structure")
        }
        if output != after.text || !stopped || trace.snapshot.structureSource != "rules" {
            failures.append("superseded layout cancellation loses the authoritative rendered list")
        }
        return failures
    }

    private static func expiredPrecleanFailures() async -> [String] {
        struct Held: TextFormatter {
            let entered: CleanupAdmission
            let release: CleanupAdmission
            let cancelled: LockedBox<Bool>
            let calls: LockedBox<Int>
            func format(_ raw: String) async -> String {
                calls.value += 1
                return await withTaskCancellationHandler {
                    entered.admit()
                    _ = await release.wait()
                    return raw.uppercased()
                } onCancel: { cancelled.value = true }
            }
        }
        let entered = CleanupAdmission(), release = CleanupAdmission()
        let cancelled = LockedBox(false), calls = LockedBox(0)
        let producer = IncrementalCleanupSession(
            semantic: Held(entered: entered, release: release, cancelled: cancelled, calls: calls),
            rules: { $0 })
        let first = "The first sentence is ready."
        let second = "The next sentence is ready."
        await producer.notePartial(first, committed: first)
        _ = await withBoundedWait(.seconds(1)) { await entered.wait() }
        let all = first + " " + second
        await producer.notePartial(all, committed: all)
        let head = await producer.head()
        let expiredTrace = CleanupTrace()
        let output = await CleanupRouter(
            semantic: KeepAsIsFormatter(), engine: .apple, rules: KeepAsIsFormatter(),
            trace: expiredTrace, precleanGrace: .milliseconds(10), head: head
        ).format(all)
        let stoppedAtDelivery = cancelled.value
        release.admit()
        for task in head.cleaned { _ = await task.value }
        var failures: [String] = []
        if expiredTrace.snapshot.precleanedGroups != 2 || expiredTrace.snapshot.precleanAnsweredGroups != 0 {
            failures.append("expired-head measurement reports pending groups as completed answers")
        }
        if output != all || !stoppedAtDelivery {
            failures.append("a usable head whose grace expired keeps entered cleanup active after delivery")
        }
        if calls.value != 1 {
            failures.append("queued expired head cleanup starts after its result can no longer be used")
        }

        // A new hold / outer finishing deadline can cancel the router while its tail
        // still has native work entered. Cancellation must reach the carried head now.
        let headEntered = CleanupAdmission(), headRelease = CleanupAdmission()
        let tailEntered = CleanupAdmission(), tailRelease = CleanupAdmission()
        let headCancelled = LockedBox(false)
        let other = IncrementalCleanupSession(
            semantic: Held(entered: headEntered, release: headRelease,
                           cancelled: headCancelled, calls: LockedBox(0)), rules: { $0 })
        await other.notePartial(first, committed: first)
        _ = await withBoundedWait(.seconds(1)) { await headEntered.wait() }
        let carried = await other.head()
        let tail = Held(entered: tailEntered, release: tailRelease,
                        cancelled: LockedBox(false), calls: LockedBox(0))
        let router = CleanupRouter(semantic: tail, engine: .apple,
                                   rules: KeepAsIsFormatter(), head: carried)
        let finishing = Task { await router.format(all) }
        _ = await withBoundedWait(.seconds(1)) { await tailEntered.wait() }
        finishing.cancel()
        let forwarded = headCancelled.value
        headRelease.admit(); tailRelease.admit()
        _ = await finishing.value
        for task in carried.cleaned { _ = await task.value }
        if !forwarded {
            failures.append("cancelling actual finishing router leaves its carried pre-clean entered")
        }
        return failures
    }

    private static func unusedPrecleanFailures() async -> [String] {
        struct Held: TextFormatter {
            let entered: CleanupAdmission
            let release: CleanupAdmission
            let cancelled: LockedBox<Bool>
            func format(_ raw: String) async -> String {
                await withTaskCancellationHandler {
                    entered.admit()
                    _ = await release.wait()
                    return raw
                } onCancel: { cancelled.value = true }
            }
        }
        var failures: [String] = []
        for usesRules in [false, true] {
            let entered = CleanupAdmission(), release = CleanupAdmission()
            let cancelled = LockedBox(false)
            let producer = IncrementalCleanupSession(
                semantic: Held(entered: entered, release: release, cancelled: cancelled), rules: { $0 })
            let committed = "The original sentence is ready."
            await producer.notePartial(committed, committed: committed)
            _ = await withBoundedWait(.seconds(1)) { await entered.wait() }
            let head = await producer.head()
            let trace = CleanupTrace()
            let output = await CleanupRouter(
                semantic: KeepAsIsFormatter(), engine: .apple, rules: KeepAsIsFormatter(),
                skipsModelWhenBusy: usesRules, trace: trace, head: head,
                pressureSample: { usesRules ? .simulated(notesBusy: true) : .idle }
            ).format("The revised sentence is ready.")
            let stopped = cancelled.value
            release.admit()
            for task in head.cleaned { _ = await task.value }
            if !stopped || output != "The revised sentence is ready."
                || trace.snapshot.route != (usesRules ? "rules" : "semantic") {
                failures.append(usesRules
                    ? "rules router discards a head but leaves its model job active"
                    : "prefix rejection leaves the discarded pre-clean competing with full cleanup")
            }
        }
        return failures
    }

    private static func quotedPrefixFailures() async -> [String] {
        var failures: [String] = []
        let middle = "The team discussed premièrement before choosing how the document should be arranged. We compared deuxièmement with the other label and agreed to preserve the existing wording. The designer mentioned enfin while describing the closing rehearsal rather than announcing another task. Tomorrow everyone will review the entire passage together and check that the original names, context, and wording have been kept intact for the reader."
        let sentences = SpokenStructure.sentenceSplit(middle)
        let middlePlan = StructurePlan(blocks: [
            .init(kind: .numbered, from: 1, to: 3, itemStarts: [1, 2, 3],
                  stripWords: [0, 0, 0], announcerQuotes: ["premièrement", "deuxièmement", "enfin"]),
            .init(kind: .prose, from: 4, to: sentences.count)
        ])
        // Keep the existing language-general evidence policy. A quote found inside
        // an item must never authorize deleting its unrelated opening words.
        if !StructurePlan.quoteVerifies("premièrement", against: sentences[0])
            || middlePlan.corroborationFailure(sentences: sentences) != nil {
            failures.append("quoted-word repair removed existing non-prefix evidence support")
        }
        if middlePlan.rendered(sentences: sentences, target: CleanupEvalCases.target)?.text
            .contains("1. " + sentences[0]) != true {
            failures.append("layout renderer deletes unquoted opening words for a non-prefix quote")
        }
        guard StructurePlan.isWorthPlanning(sentences: sentences,
                                            wordCount: SentenceChunker.wordCount(middle), sawMarkers: false) else {
            return failures + ["quoted-word fixture does not enter the layout path"]
        }
        let middleTrace = CleanupTrace()
        let middleOutput = await CleanupRouter(
            semantic: KeepAsIsFormatter(), engine: .apple, rules: KeepAsIsFormatter(),
            target: CleanupEvalCases.target, trace: middleTrace,
            structurePlanner: ScriptedStructurePlanner { _ in
                StructurePlanOutcome(plan: middlePlan, rejection: nil, seconds: 0)
            }, pressureSample: { .idle }
        ).format(middle)
        if !middleOutput.contains("1. " + sentences[0]) || middleTrace.snapshot.structurePlanModel == nil {
            failures.append("actual router loses literal opening words for a non-prefix quote")
        }

        for (quote, first, expected) in [
            ("D'abord", "D'abord on règle la facturation.", "On règle la facturation."),
            ("D’abord", "D’abord on règle la facturation.", "On règle la facturation."),
            ("First point", "First-point, ship the installer tonight.", "Ship the installer tonight.")
        ] {
            let input = [first, "Ensuite on déplace la réunion de jeudi."]
            let plan = StructurePlan(blocks: [.init(kind: .numbered, from: 1, to: 2,
                itemStarts: [1, 2], stripWords: [0, 0], announcerQuotes: [quote, "Ensuite"])])
            if plan.rendered(sentences: input, target: CleanupEvalCases.target)?.text
                .contains("1. " + expected) != true {
                failures.append("quoted \(quote) counts lexical pieces as removable whitespace words")
            }
        }
        let french = CleanupEvalCases.planCases.first { $0.id == "P4-fr-announced" }!.input
        let tail = "Tomorrow everyone will review the entire passage together and check that the original names, context, and wording have been kept intact for the reader. The team will preserve the same information while making the final document easier to read after the discussion has finished."
        let raw = french + " " + tail
        let split = SpokenStructure.sentenceSplit(raw)
        // These exact four French sentences, quotes and zero counts came from the
        // native MiniCPM trace. Extra unchanged prose exercises production admission.
        let nativePlan = StructurePlan(blocks: [
            .init(kind: .prose, from: 1, to: 1),
            .init(kind: .numbered, from: 2, to: 4, itemStarts: [2, 3, 4],
                  stripWords: [0, 0, 0], announcerQuotes: ["D'abord", "Ensuite", "Pour finir"]),
            .init(kind: .prose, from: 5, to: split.count)
        ])
        let trace = CleanupTrace()
        let output = await CleanupRouter(
            semantic: KeepAsIsFormatter(), engine: .apple, rules: KeepAsIsFormatter(),
            target: CleanupEvalCases.target, trace: trace,
            structurePlanner: ScriptedStructurePlanner { _ in
                StructurePlanOutcome(plan: nativePlan, rejection: nil, seconds: 0)
            }, pressureSample: { .idle }
        ).format(raw)
        let expected = "J'ai trois points pour toi.\n\n1. On règle la facturation.\n2. On déplace la réunion de jeudi.\n3. On appelle le comptable.\n\n" + tail
        if output != expected || trace.snapshot.structureSource != "model plan" {
            failures.append("actual router/native-plan consumer removes French content after a correctly quoted announcement")
        }
        let eight = "D'abord nous vérifions l'équipe et l'état du projet"
        let longer = eight + " puis nous envoyons tous les documents aux collègues demain."
        let bounds = StructurePlan(blocks: [.init(kind: .numbered, from: 1, to: 2,
            itemStarts: [1, 2], announcerQuotes: [eight, "Ensuite"])])
        if bounds.rejection(sentenceCount: 2) != nil
            || !StructurePlan.quoteVerifies(eight, against: longer) {
            failures.append("eight spoken announcement words are rejected as eleven lexical pieces")
        }
        var over = bounds
        over.blocks[0].announcerQuotes[0] = eight + " puis"
        if over.rejection(sentenceCount: 2) == nil {
            failures.append("the unchanged eight-word announcement bound accepts nine spoken words")
        }
        return failures
    }

    private static func localLayoutDeadlineFailures() async -> [String] {
        struct Held: LLMProvider {
            let id = LLMProviderID.appLLM
            let contextTokens = 4_096
            let holdsAvailability: Bool
            let entered: CleanupAdmission
            let release: CleanupAdmission
            let returned: CleanupAdmission
            let cancelled: LockedBox<Bool>
            let calls: LockedBox<Int>
            var unavailableReason: String? {
                get async {
                    if holdsAvailability { await hold() }
                    return nil
                }
            }
            func countTokens(_ text: String) async throws -> Int { 0 }
            func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
                calls.value += 1
                if !holdsAvailability { await hold() }
                return LLMCompletion(text: "{\"blocks\":[{\"kind\":\"prose\",\"from\":1,\"to\":2}]}",
                                     generatedTokens: 1, duration: 0)
            }
            private func hold() async {
                await withTaskCancellationHandler {
                    entered.admit()
                    _ = await release.wait()
                    returned.admit()
                } onCancel: { cancelled.value = true }
            }
        }
        var failures: [String] = []
        for availability in [false, true] {
            let entered = CleanupAdmission(), release = CleanupAdmission(), returned = CleanupAdmission()
            let cancelled = LockedBox(false), calls = LockedBox(0)
            let provider = Held(holdsAvailability: availability, entered: entered, release: release,
                                returned: returned, cancelled: cancelled, calls: calls)
            let planner = LLMStructurePlanner(provider: provider)
            let task = Task { await planner.plan(for: ["First sentence.", "Next sentence."],
                                                deadline: .milliseconds(10)) }
            let didEnter = await withBoundedWait(.seconds(1)) { await entered.wait() }
            let outcome = await withBoundedWait(.milliseconds(150)) { await task.value }
            let didCancel = cancelled.value
            release.admit()
            _ = await returned.wait()
            _ = await task.value
            if availability && calls.value != 0 {
                failures.append("local layout starts a provider request after its availability deadline")
            }
            if didEnter != true || outcome?.rejection?.contains("ran out of time") != true || !didCancel {
                failures.append(availability
                    ? "local layout deadline leaves provider availability outside its budget"
                    : "local layout deadline joins an uncancellable provider response")
            }
        }
        return failures
    }

    private static func layoutDeadlineFailures() async -> [String] {
        let entered = CleanupAdmission()
        let release = CleanupAdmission()
        let returned = CleanupAdmission()
        var planner = AppleStructurePlanner()
        planner.draftCall = {
            entered.admit()
            _ = await release.wait()
            returned.admit()
            return StructurePlanDraft(blocks: [])
        }
        let actual = planner
        let task = Task {
            await actual.plan(for: ["The first sentence.", "The next sentence."],
                              deadline: .milliseconds(10))
        }
        _ = await withBoundedWait(.seconds(1)) { await entered.wait() }
        let outcome = await withBoundedWait(.milliseconds(150)) { await task.value }
        release.admit()
        _ = await returned.wait()
        _ = await task.value
        if outcome?.rejection?.contains("ran out of time") != true {
            return ["actual layout planner deadline waits for an uncancellable response"]
        }
        return []
    }

    private static func cancelledPrecleanFailures() async -> [String] {
        let entered = CleanupAdmission()
        let release = CleanupAdmission()
        let returned = CleanupAdmission()
        let cancelled = LockedBox(false)
        let fallback = LockedBox(0)
        struct Apple: TextFormatter {
            let calls: LockedBox<Int>
            func format(_ raw: String) async -> String {
                calls.value += 1
                return raw
            }
        }
        let formatter = MiniCPMCleanupFormatter(
            preferences: CleanupPreferences(tone: .balanced, formatsLists: false, context: .general),
            runner: { raw, admission in
                admission.admit()
                entered.admit()
                return try await withTaskCancellationHandler {
                    _ = await release.wait()
                    returned.admit()
                    try Task.checkCancellation()
                    return MiniCPMPass(text: raw)
                } onCancel: { cancelled.value = true }
            },
            apple: Apple(calls: fallback), filePresent: { true }, resident: { true }, warm: {}
        )
        let producer = IncrementalCleanupSession(semantic: formatter, rules: { $0 })
        let text = "The first sentence is ready."
        await producer.notePartial(text, committed: text)
        _ = await withBoundedWait(.seconds(1)) { await entered.wait() }
        let head = await producer.head()
        await producer.cancel()
        let stopped = await withBoundedWait(.milliseconds(150)) {
            for task in head.cleaned { _ = await task.value }
            return true
        }
        let wasCancelled = cancelled.value
        let appleCalls = fallback.value
        // Always join this same fixture responder; it ignores cancellation until released.
        release.admit()
        _ = await returned.wait()
        for task in head.cleaned { _ = await task.value }
        var failures: [String] = []
        if stopped != true || !wasCancelled {
            failures.append("cancelling actual pre-clean leaves its admitted model job running")
        }
        if appleCalls != 0 || fallback.value != 0 {
            failures.append("cancelled pre-clean starts an Apple fallback that the next hold competes with")
        }
        return failures
    }
}
