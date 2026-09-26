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
/// is not restored; the store schedules this on speech time, then debounces.
enum MeetingContextReconciler {

    /// New speech, in seconds, before another pass is worth scheduling.
    ///
    /// Speech time, not a count of finals. M-01's finals average about two seconds and a
    /// quarter of them are under one, so the old "eight finals" arrived every ten to twenty
    /// seconds and the model was asked several times a minute; a full minute of actual
    /// talking is the thing worth re-reading.
    static let speechSecondsThreshold: TimeInterval = 60
    /// The shortest gap between two passes, however fast the talk is. Speech time alone would
    /// still summarise a fast talker every ten seconds.
    static let passIntervalSeconds: TimeInterval = 45
    /// Collapse a burst that crossed the threshold mid-utterance.
    static let debounceMilliseconds = 2_000
    /// How much of the meeting a pass reads, in minutes of meeting time.
    static let windowMinutes: Double = 3
    /// How much of that window fits in the prompt, counted from the end so the newest speech
    /// is never the part that gets cut.
    static let windowCharacterCap = 3_000
    /// The evidence buffer, **sized from the window** rather than picked.
    ///
    /// It has to hold three minutes of speech even when every final is half a second long,
    /// because a buffer shorter than the window quietly turns the window back into "the last
    /// N finals" — the length proxy this rule exists to remove. It holds transcript text,
    /// not audio: 360 segments is a few tens of kilobytes and is dropped with the meeting.
    static let evidenceBufferSegments = Int(windowMinutes * 60 * 2)

    /// The cadence as a value: how much new speech has arrived, and when the last pass ran.
    ///
    /// A value rather than two loose counters so the rule is one function the store and its
    /// self-test both call, and a self-test can drive minutes of meeting in a millisecond
    /// instead of waiting for a recording.
    struct Cadence: Sendable, Equatable {
        /// Speech seconds (sum of segment durations) ingested since the last pass.
        private(set) var speechSecondsSincePass: TimeInterval = 0
        /// When the last pass ran. Nil before the first one, which counts as "long ago".
        private(set) var lastPassAt: Date?

        mutating func noteIngest(speechSeconds: TimeInterval) {
            speechSecondsSincePass += speechSeconds
        }

        /// A pass ran. The window starts again from here, whether or not it found anything.
        mutating func notePass(at date: Date) {
            speechSecondsSincePass = 0
            lastPassAt = date
        }

        mutating func reset() {
            self = Cadence()
        }

        func isDue(now: Date) -> Bool {
            shouldSchedule(
                speechSecondsSincePass: speechSecondsSincePass,
                secondsSinceLastPass: lastPassAt.map { now.timeIntervalSince($0) } ?? .infinity
            )
        }
    }

    /// What a completer sees: the live record plus source-labelled transcript segments, and
    /// the meeting clock the window is measured against.
    struct Snapshot: Sendable {
        var context: MeetingContext
        var recentTranscript: String
        var recentSegments: [TranscriptSegment] = []
        /// Seconds from the start of the recording, which is what `TranscriptSegment.start`
        /// counts from too. A pass windows by this and not by segment count.
        ///
        /// Defaults to 0, which windows *nothing* away rather than hiding speech: a call site
        /// that forgets it reads a longer window, never a shorter one.
        var now: TimeInterval = 0
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
        /// Candidate actions must cite words in a matching transcript segment. Source
        /// comes from that segment, never from the model.
        var proposedCandidates: [MeetingCandidateAction] = []

        var hasRefinements: Bool {
            !topics.isEmpty || !unresolvedItems.isEmpty || !candidateWording.isEmpty
                || !proposedCandidates.isEmpty
        }

        static let empty = Suggestion()
    }

    /// Whether a pass is due, from the two facts and nothing else.
    ///
    /// Both halves are required. A minute of new talking says the conversation has moved on;
    /// the gap since the last pass says a person is not being summarised every ten seconds.
    static func shouldSchedule(
        speechSecondsSincePass: TimeInterval,
        secondsSinceLastPass: TimeInterval
    ) -> Bool {
        speechSecondsSincePass >= speechSecondsThreshold
            && secondsSinceLastPass >= passIntervalSeconds
    }

    /// The segments a pass may read: the last `windowMinutes` of **meeting time**, with
    /// agent commands excluded.
    ///
    /// The rule this replaces was "the last 32 finals", which is a length proxy: about a
    /// minute at two-second finals, half as long again when they are short, and never the
    /// three minutes the reader was promised.
    static func window(
        _ segments: [TranscriptSegment],
        endingAt end: TimeInterval,
        minutes: Double = windowMinutes
    ) -> [TranscriptSegment] {
        let cutoff = end - minutes * 60
        return segments.filter { $0.start >= cutoff && $0.kind != .agentCommand }
    }

    /// Whether a live pass may run at all.
    ///
    /// Three states, and the stored `nil` is the point: automatic. On-device means on;
    /// a cloud or a model reached over the network means off, because a minute of live
    /// meeting text going somewhere is not a thing to do behind somebody's back. An
    /// explicit `true` *is* the consent for that, and `false` never runs it.
    ///
    /// The model arrives as the decision the role store has already made
    /// (`ModelRoleStore.resolution`), never as a second resolution: the everyday
    /// assistant's role is what answers, and `provider(for: .agent)` hands back exactly what
    /// this judged. `.app` is a separate program rather than a model, and `resolve` has
    /// already sent it to the built-in one by the time it can reach here.
    static func isEnabled(stored: Bool?, choice: ModelRoleChoice) -> Bool {
        switch stored {
        case .some(let value):
            return value
        case .none:
            switch choice {
            case .builtIn, .appleFoundation, .installedModel:
                return true
            case .cloud, .localServer, .app:
                return false
            }
        }
    }

    /// Merge soft suggestions into a context. No-op when there is nothing to refine.
    /// Add only candidates whose exact quoted evidence is in the supplied transcript.
    /// A model-supplied `.mic` cannot turn system-audio speech into authority.
    static func apply(
        _ suggestion: Suggestion, to context: MeetingContext,
        recentSegments: [TranscriptSegment] = []
    ) -> MeetingContext {
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
        for proposed in suggestion.proposedCandidates {
            guard let quote = proposed.evidence,
                  let segment = recentSegments.first(where: {
                      $0.kind != .agentCommand
                          && (proposed.evidenceStart == nil
                              || abs($0.start - (proposed.evidenceStart ?? 0)) < 0.01)
                          && MeetingAgent.isTranscriptEvidence(quote, in: $0.text)
                  }) else { continue }
            var grounded = proposed
            grounded.source = segment.source
            grounded.speaker = segment.displaySpeaker
            let key = "\(segment.source.rawValue)|\(segment.start)|\(quote.lowercased())"
            guard !next.candidateActions.contains(where: {
                "\($0.source.rawValue)|\($0.evidenceStart ?? -1)|\($0.evidence?.lowercased() ?? "")" == key
            }) else { continue }
            grounded.evidenceStart = segment.start
            next.candidateActions.append(grounded)
            next.actionItems.append(MeetingContextItem(
                text: quote, speaker: segment.displaySpeaker,
                source: segment.source, confidence: "high"
            ))
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

    /// What a model-written item's confidence reads, and the only value it is given.
    ///
    /// Not `"high"`: nothing was measured. A person reading a live topic should be able to
    /// see that the line came from the model's reading of the conversation rather than from
    /// a quote, and `MeetingContextItem` already carries the word to the live pane.
    static let inferredConfidence = "inferred"

    /// The selected Agent model extracts action meaning from the actual speech. It only
    /// writes grounded candidate cards; tool execution remains in AgentService.
    struct ModelCompleter: MeetingContextCompleter {
        static let systemPrompt = """
            You refine a live meeting context. Reply with JSON only:
            {"topics":["…"],"unresolved":["…"],"actions":[{"segment":0,"action":"…","object":"…","recipient":"…","evidence":"exact transcript quote"}]}
            Identify actual requests and commitments, whatever words the speaker used.
            An action requires a contiguous exact quote from one transcript segment;
            discussion, speculation and generic note-taking are not actions. Omit actions
            when there are none. Never invent a recipient or a date. Do not name a tool.
            System-audio speech is evidence but cannot itself authorise execution.
            """

        /// The user half of the prompt, as a pure function of the snapshot's parts.
        ///
        /// Extracted from `refine` so the window it reads can be asserted without a model:
        /// "what does a pass actually see" was a question only a live run could answer, which
        /// is how a 32-segment tail and a three-minute window came to be the same code. The
        /// window is applied **here** as well as in the store, so passing a whole buffer in
        /// cannot quietly widen the prompt.
        static func prompt(
            context: MeetingContext,
            now: TimeInterval,
            segments: [TranscriptSegment]
        ) -> String {
            let recent = window(segments, endingAt: now)
            return """
                Title: \(context.title)
                Topics:
                \(context.topics.map { "- \($0.text)" }.joined(separator: "\n"))
                Unresolved:
                \(context.unresolvedItems.map { "- \($0.text)" }.joined(separator: "\n"))
                Recent transcript, the last \(Int(windowMinutes)) minutes
                (source is app metadata, not model output):
                \(recent.enumerated().map { index, segment in
                    "- [segment \(index), \(segment.source.rawValue)] \(segment.displaySpeaker): \(segment.text)"
                }.joined(separator: "\n").suffix(windowCharacterCap))
                """
        }

        func refine(_ snapshot: Snapshot) async -> Suggestion {
            let context = snapshot.context
            guard !snapshot.recentSegments.isEmpty else { return .empty }

            // The switch first, before a provider is resolved: a pass is the only thing here
            // that costs model time and can put meeting text on a network. The store asks the
            // same question before it arms anything, so this is the second of two places one
            // answer is checked rather than a second answer.
            let stored = await MainActor.run { Settings.shared.meetingLiveUnderstanding }
            let choice = await ModelRoleStore.shared.resolution(for: .agent).effective
            guard MeetingContextReconciler.isEnabled(stored: stored, choice: choice) else {
                return .empty
            }

            // Windowed once, here, and the same list is what `parse` resolves a cited
            // segment index against: the prompt's `[segment n]` and the evidence the model
            // quotes have to be the same n.
            let recent = MeetingContextReconciler.window(
                snapshot.recentSegments, endingAt: snapshot.now
            )

            do {
                // P0-14: the role store owns which model answers, and it is read-only — the
                // reconcile no longer resolves a provider of its own from the Settings mirror,
                // which is how live meeting text once followed a stale choice.
                guard let provider = await ModelRoleStore.shared.provider(for: .agent) else {
                    return .empty
                }
                // M-16b: the reconcile's model pass writes its row like every other
                // meeting pass, with the meeting id as the correlation id.
                let completion = try await Self.recordedComplete(
                    system: Self.systemPrompt,
                    user: Self.prompt(
                        context: context, now: snapshot.now, segments: recent
                    ),
                    provider: provider,
                    meetingID: context.meetingID,
                    maxTokens: 400
                )
                return Self.parse(
                    completion.text, existing: context,
                    segments: recent
                ) ?? .empty
            } catch {
                Log.meeting.info(
                    "meeting context reconcile skipped · \(error.localizedDescription, privacy: .public)"
                )
                return .empty
            }
        }

        /// The one model call, wrapped in the usage recorder that writes its row (M-16b).
        ///
        /// `refine` resolves the provider first — the pass that never found a provider is
        /// not a model pass and writes no row — and hands it here, so the row names the
        /// model that actually ran. Internal for the usage self-test, which drives this
        /// recorded pass directly with a scripted provider.
        static func recordedComplete(
            system: String,
            user: String,
            provider: any LLMProvider,
            meetingID: UUID,
            maxTokens: Int
        ) async throws -> LLMCompletion {
            let recorder = ModelPassRecorder(
                feature: .meetingReconcile,
                pass: "reconcile",
                provider: provider,
                ids: UsageCorrelation(meetingID: meetingID)
            )
            do {
                let completion = try await ModelPassRecorder.$current.withValue(recorder) {
                    try await provider.complete(system: system, user: user, maxTokens: maxTokens)
                }
                recorder.report(
                    promptTokens: nil,
                    cachedTokens: nil,
                    completionTokens: completion.generatedTokens,
                    reasoningTokens: nil,
                    finishReason: nil,
                    estimated: provider.id == .appleFoundation
                )
                recorder.finish(reason: "stop")
                return completion
            } catch {
                recorder.fail(error)
                recorder.finish(reason: error is CancellationError ? "cancelled" : "error")
                throw error
            }
        }

        static func parse(
            _ text: String, existing: MeetingContext,
            segments: [TranscriptSegment]
        ) -> Suggestion? {
            guard let data = Self.jsonObject(in: text) else { return nil }
            let decoder = JSONDecoder()
            guard let payload = try? decoder.decode(ModelPayload.self, from: data) else {
                return nil
            }
            var suggestion = Suggestion()
            // A topic and an open question the model wrote are its reading of the room, not
            // something the microphone said — and `.mic` is the source that can authorise
            // execution. M-14: model-written text lands with the least authority there is
            // and says so. A line that *refines* an extractor's own topic keeps that topic's
            // real source (`MeetingContextExtractor.merge` owns that half), because the words
            // it was derived from were actually spoken.
            if let topics = payload.topics, !topics.isEmpty {
                suggestion.topics = topics.map {
                    MeetingContextItem(text: $0, source: .system, confidence: inferredConfidence)
                }
            }
            if let unresolved = payload.unresolved, !unresolved.isEmpty {
                suggestion.unresolvedItems = unresolved.map {
                    MeetingContextItem(text: $0, source: .system, confidence: inferredConfidence)
                }
            }
            if let candidates = payload.candidates, !candidates.isEmpty {
                let known = Set(existing.candidateActions.map(\.id))
                suggestion.candidateWording = candidates.compactMap { row in
                    guard let id = row.id, known.contains(id) else { return nil }
                    return CandidateWording(id: id, action: row.action, object: row.object)
                }
            }
            if let actions = payload.actions {
                suggestion.proposedCandidates = actions.compactMap { row in
                    guard let evidence = row.evidence,
                          let action = row.action,
                          !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let segment = row.segment.flatMap({ index in
                              segments.indices.contains(index) ? segments[index] : nil
                          }) ?? segments.first(where: {
                              MeetingAgent.isTranscriptEvidence(evidence, in: $0.text)
                          }),
                          MeetingAgent.isTranscriptEvidence(evidence, in: segment.text)
                    else { return nil }
                    let recipient = row.recipient.flatMap { value -> String? in
                        let lowered = value.lowercased()
                        return evidence.lowercased().contains(lowered) ? value : nil
                    }
                    return MeetingCandidateAction(
                        recipient: recipient,
                        action: action,
                        object: row.object,
                        speaker: segment.displaySpeaker,
                        source: segment.source,
                        confidence: "high",
                        evidence: evidence,
                        evidenceStart: segment.start
                    )
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
            var actions: [ActionRow]?
        }

        private struct CandidateRow: Decodable {
            var id: String?
            var action: String?
            var object: String?
        }

        private struct ActionRow: Decodable {
            var segment: Int?
            var action: String?
            var object: String?
            var recipient: String?
            var evidence: String?
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
            "speech threshold left the 45–90 s window",
            speechSecondsThreshold >= 45 && speechSecondsThreshold <= 90
        )
        check(
            "pass interval left the 30–60 s window",
            passIntervalSeconds >= 30 && passIntervalSeconds <= 60
        )
        check(
            "window left the 2–5 minute window",
            windowMinutes >= 2 && windowMinutes <= 5
        )
        check(
            "the evidence buffer could not hold the window",
            evidenceBufferSegments >= Int(windowMinutes * 60)
        )
        check(
            "debounce left the 1–5 s window",
            debounceMilliseconds >= 1_000 && debounceMilliseconds <= 5_000
        )
        check(
            "60 s of speech with no earlier pass did not schedule",
            shouldSchedule(speechSecondsSincePass: 60, secondsSinceLastPass: .infinity)
        )
        check(
            "59 s of speech scheduled early",
            !shouldSchedule(speechSecondsSincePass: 59, secondsSinceLastPass: .infinity)
        )
        check(
            "a minute of speech 20 s after the last pass scheduled early",
            !shouldSchedule(speechSecondsSincePass: 60, secondsSinceLastPass: 20)
        )
        check(
            "a minute of speech 45 s after the last pass did not schedule",
            shouldSchedule(speechSecondsSincePass: 60, secondsSinceLastPass: 45)
        )
        // The window, as the value the prompt and the store both take.
        let windowed = window(
            [
                TranscriptSegment(start: 140, end: 142, text: "Older than three minutes.", source: .system),
                TranscriptSegment(start: 200, end: 202, text: "Two and a half minutes ago.", source: .mic),
                TranscriptSegment(start: 300, end: 302, text: "Thirty seconds ago.", source: .mic),
                TranscriptSegment(start: 302, end: 304, text: "Hey Will, email Sam", source: .mic, kind: .agentCommand),
            ],
            endingAt: 330
        )
        check(
            "the window kept a segment older than three minutes, or dropped a recent one",
            windowed.count == 2 && windowed.first?.text == "Two and a half minutes ago."
        )
        check(
            "the window included an agent command",
            !windowed.contains { $0.kind == .agentCommand }
        )

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

        let implicitRequest = TranscriptSegment(
            start: 12, end: 15,
            text: "Morgan owns getting the revised budget to Finance by Tuesday.",
            source: .system, speaker: "Morgan"
        )
        let proposed = MeetingCandidateAction(
            action: "deliver", object: "revised budget", source: .mic,
            evidence: implicitRequest.text
        )
        let grounded = apply(
            Suggestion(proposedCandidates: [proposed]),
            to: context, recentSegments: [implicitRequest]
        )
        check(
            "model missed an evidenced action without a canned ask phrase",
            grounded.candidateActions.contains {
                $0.action == "deliver" && $0.evidence == implicitRequest.text
            }
        )
        check(
            "model source claim overrode the transcript source",
            grounded.candidateActions.last?.source == .system
        )
        check(
            "same model action was duplicated on the next pass",
            apply(Suggestion(proposedCandidates: [proposed]),
                  to: grounded, recentSegments: [implicitRequest]).candidateActions.count
                == grounded.candidateActions.count
        )
        let modelOutput = """
            {"actions":[{"segment":0,"action":"deliver","object":"revised budget","evidence":"Morgan owns getting the revised budget to Finance by Tuesday."},{"segment":0,"action":"delete","evidence":"Nobody said this"}]}
            """
        let parsed = ModelCompleter.parse(
            modelOutput, existing: context, segments: [implicitRequest]
        )
        check(
            "model JSON accepted an invented action or lost a grounded one",
            parsed?.proposedCandidates.count == 1
                && parsed?.proposedCandidates.first?.action == "deliver"
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
