import Foundation

/// Actual synchronous apply/merge on public-authored speech. No ASR/model/store/UI work.
enum MeetingAttributedContextDedupSelfTest {
    static func run(write: (String) -> Void = { print($0) }) -> Bool {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append(name) }
        }
        let quote = "I will send the deck tomorrow."
        func speech(_ index: Int, source: AudioSource = .system, speaker: String? = "Speaker A",
                    text: String = "I will send the deck tomorrow.", kind: TranscriptKind? = nil) -> TranscriptSegment {
            TranscriptSegment(start: Double(index * 4), end: Double(index * 4 + 3),
                              text: text, source: source, speaker: speaker, kind: kind)
        }
        func empty() -> MeetingContext {
            .empty(meetingID: UUID(), title: "Authored attribution fixture", participants: [])
        }
        func groups(_ context: MeetingContext) -> [[MeetingContextItem]] {
            [context.commitments, context.deadlines, context.documentsMentioned]
        }
        func hasDomain(_ rows: [MeetingContextItem], source: AudioSource, speaker: String?) -> Bool {
            rows.contains { $0.text == quote && $0.source == source && $0.speaker == speaker }
        }
        let a = speech(0)
        let b = speech(1, speaker: "Speaker B")
        let first = MeetingContextExtractor.apply([a], to: empty())
        let splitSpeakers = MeetingContextExtractor.apply([b], to: first)
        for (index, rows) in groups(splitSpeakers).enumerated() {
            check("apply-two-speakers-\(index)", rows.count == 2
                  && hasDomain(rows, source: .system, speaker: "Speaker A")
                  && hasDomain(rows, source: .system, speaker: "Speaker B"))
            check("apply-retains-first-identity-\(index)", rows.first == groups(first)[index].first)
            check("apply-system-authority-\(index)", rows.allSatisfy { !$0.isAuthoritative })
        }
        let repeated = MeetingContextExtractor.apply([speech(2)], to: splitSpeakers)
        check("apply-repeat-same-domain-keeps-exact-items", groups(repeated) == groups(splitSpeakers))
        check("apply-no-candidate-or-action-promotion", repeated.candidateActions.isEmpty && repeated.actionItems.isEmpty)
        for micFirst in [false, true] {
            let mic = speech(3, source: .mic, speaker: "Shared label")
            let system = speech(4, speaker: "Shared label")
            let rows = micFirst ? [mic, system] : [system, mic]
            let both = MeetingContextExtractor.apply(rows, to: empty())
            for (index, items) in groups(both).enumerated() {
                check("apply-two-tracks-order-\(micFirst)-\(index)", items.count == 2
                      && items.map(\.source) == rows.map(\.source)
                      && items.filter(\.isAuthoritative).count == 1
                      && items.first?.source == rows.first?.source)
            }
        }
        let renamed = MeetingContextExtractor.apply([a, b], to: empty(),
            speakerNames: ["Speaker A": "Alex", "Speaker B": "Briar"])
        check("apply-explicit-mapped-labels-retained", renamed.commitments.map(\.speaker) == ["Alex", "Briar"])
        let collidedNames = MeetingContextExtractor.apply([a, b], to: empty(),
            speakerNames: ["Speaker A": "Same saved label", "Speaker B": "Same saved label"])
        check("apply-saved-label-collision-not-new-identity", collidedNames.commitments.count == 1)
        let command = MeetingContextExtractor.apply([speech(5, kind: .agentCommand)], to: empty())
        check("apply-command-still-excluded", groups(command).allSatisfy(\.isEmpty)
              && command.candidateActions.isEmpty && command.actionItems.isEmpty)
        let trimmed = MeetingContextExtractor.apply([speech(6, text: " \n" + quote + " \n")], to: first)
        check("apply-edge-trim-repeat-preserves-identity", groups(trimmed) == groups(first))
        let casing = MeetingContextExtractor.apply([speech(7, text: quote.uppercased())], to: first)
        check("apply-exact-text-contract-not-new-normalizer", casing.commitments.count == 2)
        let allFields = "We decided I will send the deck tomorrow. We are talking about delivery. We still need to decide what about delivery?"
        let covered = MeetingContextExtractor.apply([speech(8, text: allFields),
            speech(9, speaker: "Speaker B", text: allFields)], to: empty())
        let lists = [covered.topics, covered.decisions, covered.questions, covered.commitments,
                     covered.deadlines, covered.documentsMentioned, covered.unresolvedItems]
        for (index, rows) in lists.enumerated() {
            check("apply-all-categories-preserve-speakers-\(index)", rows.count == 2
                  && rows.map(\.speaker) == ["Speaker A", "Speaker B"])
        }
        let hypothetical = "If asked, I will send the deck tomorrow."
        let past = "The old example said, I will send the deck tomorrow."
        let nonActions = MeetingContextExtractor.apply([speech(10, text: hypothetical), speech(11, text: past)], to: empty())
        check("apply-retained-phrases-not-semantic-proof", nonActions.commitments.count == 2
              && nonActions.actionItems.isEmpty && nonActions.candidateActions.isEmpty)

        func item(_ id: String, text: String = "I will send the deck tomorrow.",
                  source: AudioSource = .system, speaker: String? = "Speaker A",
                  confidence: String = "medium") -> MeetingContextItem {
            MeetingContextItem(id: id, text: text, speaker: speaker, source: source,
                               confidence: confidence, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let saved = item("retained")
        let anotherSpeaker = item("speaker-b", speaker: "Speaker B")
        let merged = MeetingContextExtractor.merge([anotherSpeaker], onto: [saved])
        check("merge-two-speakers", merged == [saved, anotherSpeaker])
        let anotherTrack = item("mic", source: .mic)
        let tracked = MeetingContextExtractor.merge([anotherTrack], onto: [saved])
        check("merge-two-tracks-retain-full-metadata", tracked == [saved, anotherTrack]
              && tracked.filter(\.isAuthoritative).count == 1)
        let normalizedRepeat = item("different-id", text: quote.uppercased() + "!", confidence: "high")
        check("merge-same-domain-normalized-repeat-keeps-old-metadata",
              MeetingContextExtractor.merge([normalizedRepeat], onto: [saved]) == [saved])
        let inference = item("inference", text: quote.uppercased() + "!", speaker: nil,
                             confidence: MeetingContextReconciler.inferredConfidence)
        check("merge-unattributed-model-echo-of-system-keeps-old-metadata",
              MeetingContextExtractor.merge([inference], onto: [saved]) == [saved])
        check("merge-unattributed-model-echo-of-mic-keeps-old-metadata",
              MeetingContextExtractor.merge([inference], onto: [anotherTrack]) == [anotherTrack])
        check("merge-attributed-quote-not-blocked-by-model-text",
              MeetingContextExtractor.merge([saved], onto: [inference]) == [inference, saved])
        let legacyNil = item("legacy", speaker: nil)
        check("merge-unknown-and-known-speakers-not-equated",
              MeetingContextExtractor.merge([saved], onto: [legacyNil]) == [legacyNil, saved])
        check("merge-unknown-track-domains-distinct",
              MeetingContextExtractor.merge([item("legacy-mic", source: .mic, speaker: nil)], onto: [legacyNil]).count == 2)
        let punctuation = item("punctuation", text: "… ! ", speaker: "Speaker B")
        check("merge-punctuation-empty-still-rejected",
              MeetingContextExtractor.merge([punctuation], onto: [saved]) == [saved])
        check("merge-no-input-preserves-exact-array", MeetingContextExtractor.merge([], onto: [saved]) == [saved])
        let enrichment = item("enrichment", text: quote + " The delivery route needs review.",
                              speaker: nil, confidence: MeetingContextReconciler.inferredConfidence)
        check("merge-enrichment-keeps-own-metadata",
              MeetingContextExtractor.merge([enrichment], onto: [saved]) == [saved, enrichment])
        check("merge-new-batch-cross-speaker-plus-repeat",
              MeetingContextExtractor.merge([anotherSpeaker, normalizedRepeat, anotherSpeaker], onto: [saved]) == [saved, anotherSpeaker])
        let inferredNovel = item("novel-inference", text: "A separate route needs discussion.", speaker: nil,
                                confidence: MeetingContextReconciler.inferredConfidence)
        let novelRepeat = item("novel-repeat", text: inferredNovel.text.uppercased(), speaker: nil,
                               confidence: MeetingContextReconciler.inferredConfidence)
        check("merge-batch-unattributed-normalized-echo-remains-one",
              MeetingContextExtractor.merge([inferredNovel, novelRepeat], onto: []) == [inferredNovel])
        var capacity: [MeetingContextItem] = []
        for value in 0..<39 {
            let index: Int = value
            capacity.append(item("capacity-\(index)", speaker: "Speaker \(index)"))
        }
        let fortieth = item("capacity-39", speaker: "Speaker 39")
        let fortyFirst = item("capacity-40", speaker: "Speaker 40")
        let filled = MeetingContextExtractor.merge([fortieth, fortyFirst], onto: capacity)
        check("merge-40-capacity-preserves-39-and-admits-one-domain", filled == capacity + [fortieth])
        check("merge-at-capacity-no-eviction", MeetingContextExtractor.merge([fortyFirst], onto: filled) == filled)
        var many: [TranscriptSegment] = []
        for value in 0..<41 {
            let index: Int = value
            many.append(speech(index + 20, speaker: "Speaker \(index)"))
        }
        let bounded = MeetingContextExtractor.apply(many, to: empty())
        for (index, rows) in groups(bounded).enumerated() {
            check("apply-40-bound-latest-retained-\(index)", rows.count == 40
                  && rows.first?.speaker == "Speaker 1" && rows.last?.speaker == "Speaker 40")
        }
        let boundedRepeat = MeetingContextExtractor.apply([many.last!], to: bounded)
        check("apply-at-capacity-repeat-does-not-evict", groups(boundedRepeat) == groups(bounded))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do {
            let bytes = try encoder.encode(tracked)
            let read = try decoder.decode([MeetingContextItem].self, from: bytes)
            check("actual-codec-metadata-roundtrip-not-real-store", read == tracked)
        } catch { check("actual-codec-metadata-roundtrip-not-real-store", false) }
        for failure in failures { write("FAIL: " + failure) }
        write("MEETING_ATTRIBUTED_CONTEXT_DEDUP_RESULT checks=\(checks) failed=\(failures.count) modelCalls=0 storeCalls=0 semanticProof=false")
        write(failures.isEmpty ? "MEETING_ATTRIBUTED_CONTEXT_DEDUP_OK" : "MEETING_ATTRIBUTED_CONTEXT_DEDUP_FAILED")
        return failures.isEmpty
    }
}
