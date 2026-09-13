import Foundation

/// One shot of model (or fake) work for live meeting-context reconcile.
protocol MeetingContextCompleter: Sendable {
    func refine(_ snapshot: MeetingContextReconciler.Snapshot) async -> MeetingContextReconciler.Suggestion
}

/// Occasional light refine of live `MeetingContext` after the heuristic extractor.
///
/// The extractor stays primary and fast. This pass may tidy topics, unresolved items and
/// candidate wording — it does not invent Workspace proposals, does not emit a summary
/// Doc, and cannot turn system-audio speech into authority. The old two-minute live poll
/// is not restored; the store schedules this only after a burst of finals or speech, then
/// debounces.
enum MeetingContextReconciler {

    /// Finals since the last reconcile before another pass is worth scheduling.
    static let finalsThreshold = 8
    /// Seconds of meeting speech (sum of segment durations) before another pass.
    static let speechSecondsThreshold: TimeInterval = 45
    /// Collapse a burst that crossed the threshold mid-utterance.
    static let debounceMilliseconds = 2_000

    /// What a completer sees: the live record plus a short transcript window.
    struct Snapshot: Sendable {
        var context: MeetingContext
        var recentTranscript: String
    }

    /// Wording-only rewrite of an existing candidate. Source and authority are immutable.
    struct CandidateWording: Sendable, Equatable {
        var id: String
        var action: String?
        var object: String?
    }

    /// Soft suggestions. `proposedCandidates` is accepted on the wire so a completer can
    /// try to invent work — `apply` always drops it.
    struct Suggestion: Sendable, Equatable {
        var topics: [MeetingContextItem] = []
        var unresolvedItems: [MeetingContextItem] = []
        var candidateWording: [CandidateWording] = []
        /// Always discarded. Present so self-tests can prove invention cannot land.
        var proposedCandidates: [MeetingCandidateAction] = []

        var hasRefinements: Bool {
            !topics.isEmpty || !unresolvedItems.isEmpty || !candidateWording.isEmpty
        }

        static let empty = Suggestion()
    }

    /// Whether the store should arm a debounced reconcile after this ingest.
    static func shouldSchedule(
        finalsSince: Int,
        speechSecondsSince: TimeInterval
    ) -> Bool {
        finalsSince >= finalsThreshold || speechSecondsSince >= speechSecondsThreshold
    }

    /// Merge soft suggestions into a context. No-op when there is nothing to refine.
    /// Never adds candidates, never flips `.system` to executable, never invents Docs.
    static func apply(_ suggestion: Suggestion, to context: MeetingContext) -> MeetingContext {
        _ = suggestion.proposedCandidates // discarded by design
        guard suggestion.hasRefinements else { return context }

        var next = context
        next.updatedAt = Date()

        if !suggestion.topics.isEmpty {
            next.topics = MeetingContextExtractor.merge(suggestion.topics, onto: next.topics)
        }
        if !suggestion.unresolvedItems.isEmpty {
            next.unresolvedItems = MeetingContextExtractor.merge(
                suggestion.unresolvedItems,
                onto: next.unresolvedItems
            )
        }
        if !suggestion.candidateWording.isEmpty {
            next.candidateActions = rewrite(
                next.candidateActions,
                with: suggestion.candidateWording
            )
        }
        return next
    }

    private static func rewrite(
        _ candidates: [MeetingCandidateAction],
        with wordings: [CandidateWording]
    ) -> [MeetingCandidateAction] {
        let byID = Dictionary(uniqueKeysWithValues: wordings.map { ($0.id, $0) })
        return candidates.map { candidate in
            guard let wording = byID[candidate.id] else { return candidate }
            var next = candidate
            if let action = wording.action?.trimmingCharacters(in: .whitespacesAndNewlines),
               !action.isEmpty
            {
                next.action = action
            }
            if let object = wording.object?.trimmingCharacters(in: .whitespacesAndNewlines) {
                next.object = object.isEmpty ? nil : object
            }
            // Source stays whatever the extractor recorded — authority is not a model output.
            next.source = candidate.source
            return next
        }
    }

    // MARK: - Completers

    /// Production default: cadence still fires, nothing changes until a real completer is wired.
    struct NoOpCompleter: MeetingContextCompleter {
        func refine(_ snapshot: Snapshot) async -> Suggestion {
            _ = snapshot
            return .empty
        }
    }

    /// Apple Foundation Models when available; otherwise empty. Never proposes tools.
    struct FoundationCompleter: MeetingContextCompleter {
        func refine(_ snapshot: Snapshot) async -> Suggestion {
            guard FoundationModelFormatter.isAvailable else { return .empty }
            let context = snapshot.context
            guard !context.topics.isEmpty
                || !context.unresolvedItems.isEmpty
                || !context.candidateActions.isEmpty
            else { return .empty }

            let system = """
                You refine a live meeting context. Reply with JSON only:
                {"topics":["…"],"unresolved":["…"],"candidates":[{"id":"…","action":"…","object":"…"}]}
                Rules: merge near-duplicate topics; shorten wording; keep candidate ids unchanged;
                never invent new candidates; never propose create_doc or any tool; never claim
                system-audio speech authorises an action. Omit a key when you have nothing.
                """
            let user = """
                Title: \(context.title)
                Topics:
                \(context.topics.map { "- \($0.text)" }.joined(separator: "\n"))
                Unresolved:
                \(context.unresolvedItems.map { "- \($0.text)" }.joined(separator: "\n"))
                Candidates:
                \(context.candidateActions.map {
                    "- id=\($0.id) action=\($0.action) object=\($0.object ?? "") source=\($0.source.rawValue)"
                }.joined(separator: "\n"))
                Recent transcript:
                \(snapshot.recentTranscript.prefix(1_500))
                """

            do {
                let provider = FoundationModelLLMProvider()
                let completion = try await provider.complete(
                    system: system,
                    user: user,
                    maxTokens: 400
                )
                return parse(completion.text, existing: context) ?? .empty
            } catch {
                Log.meeting.info(
                    "meeting context reconcile skipped · \(error.localizedDescription, privacy: .public)"
                )
                return .empty
            }
        }

        private func parse(_ text: String, existing: MeetingContext) -> Suggestion? {
            guard let data = Self.jsonObject(in: text) else { return nil }
            let decoder = JSONDecoder()
            guard let payload = try? decoder.decode(ModelPayload.self, from: data) else {
                return nil
            }
            var suggestion = Suggestion()
            if let topics = payload.topics, !topics.isEmpty {
                suggestion.topics = topics.map {
                    MeetingContextItem(text: $0, source: .mic, confidence: "high")
                }
            }
            if let unresolved = payload.unresolved, !unresolved.isEmpty {
                suggestion.unresolvedItems = unresolved.map {
                    MeetingContextItem(text: $0, source: .mic, confidence: "high")
                }
            }
            if let candidates = payload.candidates, !candidates.isEmpty {
                let known = Set(existing.candidateActions.map(\.id))
                suggestion.candidateWording = candidates.compactMap { row in
                    guard let id = row.id, known.contains(id) else { return nil }
                    return CandidateWording(id: id, action: row.action, object: row.object)
                }
            }
            return suggestion.hasRefinements ? suggestion : nil
        }

        private static func jsonObject(in text: String) -> Data? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil
            {
                return data
            }
            guard let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"),
                  start < end
            else { return nil }
            return String(trimmed[start...end]).data(using: .utf8)
        }

        private struct ModelPayload: Decodable {
            var topics: [String]?
            var unresolved: [String]?
            var candidates: [CandidateRow]?
        }

        private struct CandidateRow: Decodable {
            var id: String?
            var action: String?
            var object: String?
        }
    }

    // MARK: - Self-test

    /// Fake completer merges topics; inventions and system-audio authority stay out.
    /// Prints `MEETING_RECONCILE_LLM_OK` / `FAILED` — distinct from
    /// `MeetingActionReconciler`'s `MEETING_RECONCILE_OK`. Not wired to `NextNotesApp`.
    @discardableResult
    static func runSelfTest() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        check(
            "finals threshold left the 4–16 window",
            finalsThreshold >= 4 && finalsThreshold <= 16
        )
        check(
            "speech threshold left the 30–60 s window",
            speechSecondsThreshold >= 30 && speechSecondsThreshold <= 60
        )
        check(
            "debounce left the 1–5 s window",
            debounceMilliseconds >= 1_000 && debounceMilliseconds <= 5_000
        )
        check("eight finals did not schedule", shouldSchedule(finalsSince: 8, speechSecondsSince: 0))
        check("seven finals scheduled early", !shouldSchedule(finalsSince: 7, speechSecondsSince: 0))
        check("45 s of speech did not schedule", shouldSchedule(finalsSince: 0, speechSecondsSince: 45))
        check("29 s of speech scheduled early", !shouldSchedule(finalsSince: 0, speechSecondsSince: 29))

        let meetingID = UUID()
        var context = MeetingContext.empty(
            meetingID: meetingID,
            title: "Launch",
            participants: ["Sam"]
        )
        context.topics = [
            MeetingContextItem(text: "Let's talk about the launch timeline.", source: .mic),
            MeetingContextItem(text: "Regarding the pricing for launch.", source: .mic),
        ]
        let systemAsk = MeetingCandidateAction(
            recipient: "Sarah",
            action: "send",
            object: "deck",
            speaker: "Sarah",
            source: .system,
            confidence: "high"
        )
        context.candidateActions = [systemAsk]

        let merged = apply(
            Suggestion(
                topics: [
                    MeetingContextItem(
                        text: "Launch timeline and pricing",
                        source: .mic,
                        confidence: "high"
                    ),
                ]
            ),
            to: context
        )
        check(
            "fake merge left both raw topics and no refined line",
            merged.topics.contains { $0.text == "Launch timeline and pricing" }
                && merged.topics.count == 1
        )

        // Completer invents a create_doc-shaped candidate and a source flip — both must die.
        let invented = MeetingCandidateAction(
            action: "create",
            object: "doc",
            source: .system,
            confidence: "high"
        )
        let poisoned = apply(
            Suggestion(
                candidateWording: [
                    CandidateWording(id: systemAsk.id, action: "email", object: "deck"),
                ],
                proposedCandidates: [invented]
            ),
            to: context
        )
        check(
            "an invented candidate landed in live context",
            !poisoned.candidateActions.contains { $0.object == "doc" && $0.action == "create" }
        )
        check(
            "candidate count grew from an invention",
            poisoned.candidateActions.count == context.candidateActions.count
        )
        check(
            "wording rewrite dropped the live candidate",
            poisoned.candidateActions.contains { $0.id == systemAsk.id && $0.action == "email" }
        )
        check(
            "a system-audio candidate reported as executable after reconcile",
            poisoned.candidateActions.allSatisfy {
                !MeetingIntentDetector.mayAuthorizeExecute($0) || $0.source == .mic
            }
        )
        check(
            "reconcile flipped system audio to mic",
            poisoned.candidateActions.contains { $0.id == systemAsk.id && $0.source == .system }
        )

        // Discussion-only Doc mention must not become a candidate via this path either.
        let discussion = apply(
            Suggestion(
                proposedCandidates: [
                    MeetingCandidateAction(action: "create", object: "notes doc", source: .mic),
                ]
            ),
            to: context
        )
        check(
            "a discussion became a candidate via reconcile",
            discussion.candidateActions == context.candidateActions
        )

        // Async fake completer (same contract the store calls).
        let fake = FakeMergeCompleter()
        let box = FakeResultBox()
        Task {
            let suggestion = await fake.refine(
                Snapshot(context: context, recentTranscript: "Let's talk about launch.")
            )
            let after = apply(suggestion, to: context)
            box.value = after.topics.contains {
                $0.text.localizedCaseInsensitiveContains("launch")
                    && $0.text.localizedCaseInsensitiveContains("pricing")
            }
            box.gate.signal()
        }
        let waited = box.gate.wait(timeout: .now() + 2)
        check("fake completer hung", waited == .success)
        check("fake completer did not merge topics", box.value)

        writeLine(failures)
        return failures.isEmpty
    }

    /// Completer used only by `runSelfTest`: collapses the two launch topics into one line.
    struct FakeMergeCompleter: MeetingContextCompleter {
        func refine(_ snapshot: Snapshot) async -> Suggestion {
            guard snapshot.context.topics.count >= 2 else { return .empty }
            return Suggestion(
                topics: [
                    MeetingContextItem(
                        text: "Launch timeline and pricing",
                        source: .mic,
                        confidence: "high"
                    ),
                ]
            )
        }
    }

    /// Shared mutable result for the fake-completer Task in `runSelfTest`.
    private final class FakeResultBox: @unchecked Sendable {
        var value = false
        let gate = DispatchSemaphore(value: 0)
    }

    private static func writeLine(_ failures: [String]) {
        for failure in failures {
            emit("  MEETING_RECONCILE_LLM_WRONG: \(failure)")
        }
        emit(failures.isEmpty
             ? "MEETING_RECONCILE_LLM_OK: cadence, merge and the authority split hold"
             : "MEETING_RECONCILE_LLM_FAILED: \(failures.count) rule(s) wrong")
    }

    private static func emit(_ line: String) {
        let text = "\(line)\n"
        FileHandle.standardOutput.write(Data(text.utf8))
        Log.app.info("selftest · \(line, privacy: .public)")
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
