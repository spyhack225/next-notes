import Foundation

/// Reconstructs actual live producer windows on copied private speech. Original inference
/// snapshots were not saved: preceding state is deterministic extractor-only state, never
/// the final saved context, and no expected/target labels enter the model prompt.
@MainActor
enum MeetingActionIntentProductionReplaySelfTest {
    private struct Manifest: Decodable { let windows: [Window] }
    private struct Window: Decodable {
        let id: String
        let cutoff: TimeInterval
        let forbiddenStarts: [TimeInterval]
        let requiredAnyStarts: [TimeInterval]
        let review: String
    }

    static func run(directory: URL, provider: any LLMProvider,
                    write: (String) -> Void) async throws -> Bool {
        guard SelfTest.isRunning, Settings.shared.usesHarnessPreferencesForTesting,
              provider.id == .appLLM || provider.id == .appleFoundation else {
            throw CocoaError(.fileReadNoPermission)
        }
        func read(_ name: String) throws -> Data {
            let file = directory.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().path == file.path else {
                throw CocoaError(.fileReadNoPermission)
            }
            return try Data(contentsOf: file)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let originalMeeting = try decoder.decode(Meeting.self, from: read("meeting.json"))
        let transcript = try decoder.decode([TranscriptSegment].self, from: read("transcript.live.json"))
        let manifest = try decoder.decode(Manifest.self, from: read("windows.json"))
        guard !manifest.windows.isEmpty, manifest.windows.count <= 12,
              Set(manifest.windows.map(\.id)).count == manifest.windows.count,
              manifest.windows.allSatisfy({ $0.cutoff.isFinite && $0.cutoff > 60
                  && $0.id.range(of: #"^[a-z0-9-]{1,48}$"#, options: .regularExpression) != nil })
        else { throw CocoaError(.fileReadCorruptFile) }

        // Admission is explicit in the isolated harness only. Never alter an owner default
        // or resolve a second production model. The supplied provider stays unchanged.
        let previousUnderstanding = Settings.shared.meetingLiveUnderstanding
        Settings.shared.meetingLiveUnderstanding = true
        defer { Settings.shared.meetingLiveUnderstanding = previousUnderstanding }
        write("ACTION_INTENT_PRODUCTION_SCOPE reconstructed=true originalSnapshots=false"
            + " precedingContext=extractor-only targetInstructions=false isolatedStore=true")
        var failures = 0
        for item in manifest.windows {
            let admitted = transcript.filter { $0.end <= item.cutoff }
            guard !admitted.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            var meeting = originalMeeting
            meeting.id = UUID()
            meeting.status = .recording
            meeting.end = nil
            let store = MeetingStore.isolated()
            let root = store.directory(for: meeting.id).deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: root) }
            guard store.save(meeting) else { throw CocoaError(.fileWriteUnknown) }
            let capture = Capture()
            let forwarding = CapturingProvider(provider: provider, capture: capture)
            let actualCompleter = MeetingContextReconciler.ModelCompleter(
                enabled: { true }, resolveProvider: { forwarding })
            let completer = CapturingCompleter(actual: actualCompleter, capture: capture)
            let contextStore = MeetingContextStore.isolatedForTesting(
                store: store, completer: completer,
                optionalAdmission: { ModelResidencyPolicy.pressureSnapshot.allowsOptionalWork })
            contextStore.ingest(admitted, meeting: meeting)
            let before = contextStore.current
            await contextStore.runReconcileForTesting()
            let captured = await capture.state()
            let after = contextStore.current
            let persisted = contextStore.load(meetingID: meeting.id)
            let persistedEqual = contextsAgree(after, persisted)
            let extractionSeedEqual = before.map {
                let seed = MeetingContextExtractor.apply(admitted,
                    to: .empty(meetingID: meeting.id, title: meeting.title, participants: meeting.attendees),
                    speakerNames: meeting.speakerNames)
                return sameExtractedText($0, seed)
            } ?? false
            let candidates = after?.candidateActions ?? []
            let forbiddenHits = candidates.filter { candidate in
                item.forbiddenStarts.contains { near(candidate.evidenceStart, $0) }
            }.count
            let requiredHit = item.requiredAnyStarts.isEmpty || candidates.contains { candidate in
                item.requiredAnyStarts.contains { near(candidate.evidenceStart, $0) }
            }
            let sourceCorrect = candidates.allSatisfy { candidate in
                guard let start = candidate.evidenceStart, let quote = candidate.evidence else { return false }
                return admitted.contains { near($0.start, start) && $0.source == candidate.source
                    && $0.text.range(of: quote, options: .caseInsensitive) != nil }
            }
            let complete = captured.calls == 1 && captured.completions.count == 1 && captured.snapshot != nil
            let prompt = captured.user ?? ""
            let seenReferenceStarts = item.forbiddenStarts + item.requiredAnyStarts
            let visibleReferences = seenReferenceStarts.filter { start in
                admitted.contains { near($0.start, start) && prompt.contains($0.text) }
            }.count
            let raw = captured.completions.first?.text ?? ""
            let productionPayload = complete
                && MeetingContextReconciler.ModelCompleter.payloadDecodesForTesting(raw)
            let cutoff = captured.snapshot?.now ?? 0
            let cut = captured.completions.first?.finishedByLimit ?? false
            if !complete || !productionPayload || cut || !persistedEqual || !extractionSeedEqual || !sourceCorrect
                || forbiddenHits > 0 || !requiredHit { failures += 1 }
            write("ACTION_INTENT_PRODUCTION_RESULT case=\(item.id) requestedCutoff=\(item.cutoff)"
                + " actualCutoff=\(cutoff) calls=\(captured.calls) completions=\(captured.completions.count) finishedByLimit=\(cut)"
                + " productionParsed=\(productionPayload) candidates=\(candidates.count)"
                + " forbiddenCitationHits=\(forbiddenHits) requiredCitationHit=\(requiredHit)"
                + " referenceVisible=\(visibleReferences)/\(seenReferenceStarts.count)"
                + " extractorSeedEqual=\(extractionSeedEqual) persistedEqual=\(persistedEqual)"
                + " sourcesCorrect=\(sourceCorrect) semanticReviewed=false")
            // Everything between PRIVATE markers stays in the caller's private diagnostic
            // log. It contains the actual prompt, raw model output and saved action text.
            write("ACTION_INTENT_PRODUCTION_PRIVATE_BEGIN case=\(item.id)\n"
                + "REVIEW: \(item.review)\nSYSTEM:\n\(captured.system ?? "")\nUSER:\n\(prompt)"
                + "\nRAW:\n\(raw)\nCONTEXT:\n\(after?.summary ?? "")"
                + "\nACTION_INTENT_PRODUCTION_PRIVATE_END")
            contextStore.reset()
        }
        UsageLog.shared.flush()
        write("ACTION_INTENT_PRODUCTION_USAGE " + String(decoding:
            try JSONEncoder().encode(UsageLog.shared.load()), as: UTF8.self))
        write(failures == 0
            ? "ACTION_INTENT_PRODUCTION_OK: structural/citation fixtures pass; semantic review remains required"
            : "ACTION_INTENT_PRODUCTION_FAILED: \(failures) production fixture windows wrong; semantic review remains required")
        return failures == 0
    }

    private static func near(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool {
        value.map { abs($0 - expected) < 0.01 } ?? false
    }
    private static func contextsAgree(_ lhs: MeetingContext?, _ rhs: MeetingContext?) -> Bool {
        guard let lhs, let rhs else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // The real persistence format has second precision. Compare all actual fields
        // in that same encoding rather than discard dates, identity or ordering.
        guard let expected = try? encoder.encode(lhs), let actual = try? encoder.encode(rhs) else { return false }
        return expected == actual
    }
    private static func sameExtractedText(_ lhs: MeetingContext, _ rhs: MeetingContext) -> Bool {
        lhs.participants == rhs.participants && lhs.topics.map(\.text) == rhs.topics.map(\.text)
            && lhs.questions.map(\.text) == rhs.questions.map(\.text)
            && lhs.commitments.map(\.text) == rhs.commitments.map(\.text)
            && lhs.decisions.map(\.text) == rhs.decisions.map(\.text)
            && lhs.deadlines.map(\.text) == rhs.deadlines.map(\.text)
            && lhs.documentsMentioned.map(\.text) == rhs.documentsMentioned.map(\.text)
            && lhs.unresolvedItems.map(\.text) == rhs.unresolvedItems.map(\.text)
    }

    private actor Capture {
        struct State: Sendable {
            var snapshot: MeetingContextReconciler.Snapshot?
            var system: String?
            var user: String?
            var completions: [LLMCompletion] = []
            var calls = 0
        }
        private var value = State()
        func snapshot(_ snapshot: MeetingContextReconciler.Snapshot) { value.snapshot = snapshot }
        func call(system: String, user: String) { value.calls += 1; value.system = system; value.user = user }
        func completion(_ completion: LLMCompletion) { value.completions.append(completion) }
        func state() -> State { value }
    }
    private struct CapturingCompleter: MeetingContextCompleter {
        let actual: MeetingContextReconciler.ModelCompleter
        let capture: Capture
        func refine(_ snapshot: MeetingContextReconciler.Snapshot) async -> MeetingContextReconciler.Suggestion {
            await capture.snapshot(snapshot)
            return await actual.refine(snapshot)
        }
    }
    private struct CapturingProvider: LLMProvider {
        let provider: any LLMProvider
        let capture: Capture
        var id: LLMProviderID { provider.id }
        var displayModelName: String { provider.displayModelName }
        var contextTokens: Int { provider.contextTokens }
        var unavailableReason: String? { get async { await provider.unavailableReason } }
        func countTokens(_ text: String) async throws -> Int { try await provider.countTokens(text) }
        var enforcesGrammar: Bool { provider.enforcesGrammar }
        func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar) async throws -> LLMCompletion {
            await capture.call(system: system, user: user)
            let result = try await provider.complete(system: system, user: user, maxTokens: maxTokens, grammar: grammar)
            await capture.completion(result)
            return result
        }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            await capture.call(system: system, user: user)
            let result = try await provider.complete(system: system, user: user, maxTokens: maxTokens)
            await capture.completion(result)
            return result
        }
    }
}
