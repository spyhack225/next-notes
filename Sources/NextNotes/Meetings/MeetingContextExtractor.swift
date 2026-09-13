import Foundation

/// Turns transcript chunks into structured `MeetingContext`.
///
/// Heuristic first, so a meeting has a usable state without a model. A later LLM pass can
/// refine the same record. System-audio lines may create candidate actions; they never
/// become authorised work.
enum MeetingContextExtractor {
    private static let decisionMarks = ["we decided", "agreed to", "decision is", "we'll go with", "let's go with"]
    private static let actionMarks = [
        "can you", "could you", "would you", "please send", "please share", "please email",
        "action item", "i'll send", "i will send", "i'll do", "follow up",
        "send me", "share the", "send her", "send him", "send them",
    ]
    private static let questionMarks = ["?"]
    private static let commitmentMarks = ["i'll", "i will", "i can take", "i'll own", "i'll handle"]
    private static let deadlineMarks = ["by friday", "by monday", "tomorrow", "next week", "eod", "end of day", "deadline"]
    private static let documentMarks = [".step", ".stp", ".pdf", ".docx", ".xlsx", ".fig", "deck", "doc", "spec", "cad"]
    private static let topicMarks = [
        "let's talk about", "talking about", "let's discuss", "next topic",
        "on the agenda", "agenda item", "regarding the", "moving on to",
    ]
    private static let unresolvedMarks = [
        "still need", "still open", "haven't decided", "have not decided",
        "open question", "we need to figure", "come back to", "unresolved",
        "parking lot", "tbd", "to be decided",
    ]

    static func apply(
        _ segments: [TranscriptSegment],
        to context: MeetingContext,
        speakerNames: [String: String] = [:]
    ) -> MeetingContext {
        var next = context
        next.updatedAt = Date()

        for segment in segments where segment.kind != .agentCommand {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let lowered = text.lowercased()
            let speaker = speakerNames[segment.displaySpeaker] ?? segment.displaySpeaker
            let item = MeetingContextItem(text: text, speaker: speaker, source: segment.source, confidence: "medium")

            if decisionMarks.contains(where: lowered.contains) {
                append(item, to: &next.decisions)
            }
            if actionMarks.contains(where: lowered.contains) {
                append(item, to: &next.actionItems)
            }
            // Candidates are detected independently of the action-item marks: "send me the
            // deck" is a request even when it never said "can you".
            if let candidate = MeetingIntentDetector.candidate(in: segment, speakerNames: speakerNames) {
                if !next.candidateActions.contains(where: { Self.candidateFingerprint($0) == Self.candidateFingerprint(candidate) }) {
                    next.candidateActions.append(candidate)
                }
            }
            if questionMarks.contains(where: text.contains) {
                append(item, to: &next.questions)
                if looksUnresolved(lowered) {
                    append(item, to: &next.unresolvedItems)
                }
            }
            if commitmentMarks.contains(where: lowered.contains) {
                append(item, to: &next.commitments)
            }
            if deadlineMarks.contains(where: lowered.contains) {
                append(item, to: &next.deadlines)
            }
            if documentMarks.contains(where: lowered.contains) {
                append(item, to: &next.documentsMentioned)
            }
            if topicMarks.contains(where: lowered.contains) {
                append(item, to: &next.topics)
            }
            if looksUnresolved(lowered), !questionMarks.contains(where: text.contains) {
                append(item, to: &next.unresolvedItems)
            }
        }

        let names = Set(segments.compactMap { speakerNames[$0.displaySpeaker] ?? $0.displaySpeaker })
        next.participants = Array(Set(next.participants).union(names)).sorted()
        return next
    }

    private static func looksUnresolved(_ lowered: String) -> Bool {
        unresolvedMarks.contains(where: lowered.contains)
            || lowered.contains("what about")
            || lowered.contains("should we")
    }

    private static func append(_ item: MeetingContextItem, to list: inout [MeetingContextItem]) {
        if list.contains(where: { $0.text == item.text }) { return }
        list.append(item)
        if list.count > 40 { list.removeFirst(list.count - 40) }
    }

    private static func candidateFingerprint(_ candidate: MeetingCandidateAction) -> String {
        [
            candidate.action,
            candidate.object ?? "",
            candidate.source.rawValue,
            candidate.recipient ?? "",
            candidate.speaker ?? "",
        ].map { normalize($0).lowercased() }.joined(separator: "|")
    }

    /// Prefer refined wording when it covers an existing item; otherwise append.
    /// Used by the occasional LLM reconcile — never invents rows the extractor did not seed.
    static func merge(
        _ refined: [MeetingContextItem],
        onto existing: [MeetingContextItem]
    ) -> [MeetingContextItem] {
        var next = existing
        for item in refined {
            let needle = normalize(item.text)
            guard !needle.isEmpty else { continue }
            if let index = next.firstIndex(where: { overlaps(normalize($0.text), needle) }) {
                var replaced = next[index]
                // Keep the original source/speaker — refine wording only.
                replaced.text = item.text
                if item.confidence == "high" { replaced.confidence = "high" }
                next[index] = replaced
                // Drop siblings that also overlap the refined line (near-duplicate collapse).
                next = next.enumerated().compactMap { offset, existing in
                    if offset == index { return existing }
                    return overlaps(normalize(existing.text), needle) ? nil : existing
                }
            } else {
                append(item, to: &next)
            }
        }
        return next
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Shared stem or mutual containment — enough to collapse "launch timeline" variants.
    private static func overlaps(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.contains(b) || b.contains(a) { return true }
        let aTokens = Set(a.split(separator: " ").map(String.init).filter { $0.count > 3 })
        let bTokens = Set(b.split(separator: " ").map(String.init).filter { $0.count > 3 })
        guard !aTokens.isEmpty, !bTokens.isEmpty else { return false }
        return !aTokens.isDisjoint(with: bTokens)
    }

    /// Prints through `MeetingLiveAgent.runSelfTest()` — one last `MEETING_LIVE_OK` /
    /// `FAILED` line, including the extractor cases and the bus-bridge probe.
    @MainActor
    @discardableResult
    static func runSelfTest() -> Bool {
        MeetingLiveAgent.runSelfTest()
    }

    /// Cases the extractor and the authority split have to keep. Returns the names of the
    /// ones that failed; the caller prints the one last line.
    static func selfTestFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let meetingID = UUID()
        var context = MeetingContext.empty(meetingID: meetingID, title: "Pricing", participants: ["Sarah"])
        let deck = TranscriptSegment(
            start: 0, end: 2,
            text: "Can you send the deck?",
            source: .system,
            speaker: "Sarah"
        )
        let deckSystemSara = TranscriptSegment(
            start: 18, end: 20,
            text: "Can you send the deck?",
            source: .system,
            speaker: "Sara"
        )
        let deckSystemTerry = TranscriptSegment(
            start: 22, end: 24,
            text: "Can you send the deck?",
            source: .system,
            speaker: "Terry"
        )
        let deckSystemSaraRepeat = TranscriptSegment(
            start: 26, end: 28,
            text: "Can you send the deck?",
            source: .system,
            speaker: "Sara"
        )
        let decision = TranscriptSegment(
            start: 3, end: 5,
            text: "We decided to ship on Friday.",
            source: .mic
        )
        let command = TranscriptSegment(
            start: 6, end: 8,
            text: "Hey Next, email the proposal",
            source: .mic,
            kind: .agentCommand
        )
        let discussion = TranscriptSegment(
            start: 9, end: 11,
            text: "We should write this up in a doc later.",
            source: .mic
        )
        let topic = TranscriptSegment(
            start: 12, end: 14,
            text: "Let's talk about the launch timeline.",
            source: .mic
        )
        let open = TranscriptSegment(
            start: 15, end: 17,
            text: "We still need to pick a date.",
            source: .system
        )
        context = apply([
            deck,
            deckSystemSara,
            deckSystemTerry,
            deckSystemSaraRepeat,
            decision,
            command,
            discussion,
            topic,
            open,
        ], to: context)

        check("can you send the deck produced no candidate", context.candidateActions.contains {
            $0.object == "deck" && $0.source == .system
        })
        check("a decision was missed", context.decisions.contains { $0.text.contains("Friday") })
        check("a topic was missed", context.topics.contains { $0.text.localizedCaseInsensitiveContains("launch") })
        check("an unresolved item was missed", context.unresolvedItems.contains { $0.text.localizedCaseInsensitiveContains("date") })
        check("a mention was missed", context.documentsMentioned.contains { $0.text.localizedCaseInsensitiveContains("doc") })
        check("system-only duplicate asks stayed as three separate entries", context.candidateActions.filter {
            $0.action == "send" && $0.object == "deck" && $0.source == .system
        }.count == 3)
        check(
            "an identical ask from the same source and recipient was still deduped",
            context.candidateActions.filter {
                $0.action == "send" && $0.object == "deck" && $0.source == .system && $0.recipient == "Sara"
            }.count == 1
        )
        check("an agent command polluted the notes text", !context.actionItems.contains { $0.text.contains("email the proposal") })

        check(
            "a system segment authorised execute",
            !MeetingIntentDetector.mayAuthorizeExecute(deck)
        )
        check(
            "a system candidate authorised execute",
            context.candidateActions.allSatisfy { !MeetingIntentDetector.mayAuthorizeExecute($0) || $0.source == .mic }
        )
        check(
            "system audio became authority",
            !MeetingIntentDetector.mayExecute(source: .system)
        )
        if let candidate = MeetingIntentDetector.candidate(in: deck) {
            check("a system candidate reported as executable", !MeetingIntentDetector.mayAuthorizeExecute(candidate))
        } else {
            failures.append("can you send the deck produced no candidate")
        }

        let micAsk = TranscriptSegment(start: 20, end: 22, text: "Can you send the deck", source: .mic)
        check(
            "mic speech was refused authority",
            MeetingIntentDetector.mayAuthorizeExecute(micAsk)
        )
        context = apply([micAsk], to: context)
        check(
            "system and mic asks with the same object were treated as distinct entries",
            context.candidateActions.filter { $0.action == "send" && $0.object == "deck" }.count == 4
        )
        check(
            "mic confirmation was treated as separate from system ask",
            context.candidateActions.contains(where: { $0.action == "send" && $0.object == "deck" && $0.source == .mic })
        )
        check(
            "distinct system speakers remained distinct",
            context.candidateActions.filter { $0.action == "send" && $0.object == "deck" && $0.source == .system }.count == 3
        )
        check(
            "system requests captured distinct recipients",
            Set(context.candidateActions.filter {
                $0.action == "send" && $0.object == "deck" && $0.source == .system
            }.map { normalize($0.recipient ?? "").lowercased() }).count == 3
        )

        return failures
    }
}

/// The hard security invariant: system audio is context, the microphone is authority.
enum MeetingIntentDetector {
    static func candidate(
        in segment: TranscriptSegment,
        speakerNames: [String: String] = [:]
    ) -> MeetingCandidateAction? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        let looksLikeAsk = [
            "can you", "could you", "would you",
            "please send", "please share", "please email",
            "send me", "share the", "send her", "send him", "send them",
        ].contains { lowered.contains($0) }
        guard looksLikeAsk else { return nil }

        return MeetingCandidateAction(
            recipient: segment.source == .system ? (speakerNames[segment.displaySpeaker] ?? segment.displaySpeaker) : nil,
            action: actionVerb(in: lowered),
            object: object(in: text),
            speaker: speakerNames[segment.displaySpeaker] ?? segment.displaySpeaker,
            source: segment.source,
            confidence: "high"
        )
    }

    /// Other people provide context, never authority.
    static func mayExecute(source: AudioSource) -> Bool {
        mayAuthorizeExecute(source: source)
    }

    /// Card and execute time both call this. A `.system` segment can never say yes.
    static func mayAuthorizeExecute(source: AudioSource) -> Bool {
        source == .mic
    }

    static func mayAuthorizeExecute(_ segment: TranscriptSegment) -> Bool {
        mayAuthorizeExecute(source: segment.source)
    }

    static func mayAuthorizeExecute(_ candidate: MeetingCandidateAction) -> Bool {
        mayAuthorizeExecute(source: candidate.source)
    }

    static func resolveThat(in context: MeetingContext) -> MeetingCandidateAction? {
        context.candidateActions.last
    }

    private static func actionVerb(in lowered: String) -> String {
        if lowered.contains("email") { return "email" }
        if lowered.contains("share") { return "share" }
        if lowered.contains("send") { return "send" }
        return "share or send"
    }

    private static func object(in text: String) -> String? {
        let markers = ["step", "stp", "cad", "deck", "doc", "file", "proposal", "spec", "pdf", "slide"]
        let lowered = text.lowercased()
        return markers.first { lowered.contains($0) }
    }
}
