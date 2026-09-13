import Foundation

/// Turns transcript chunks into structured `MeetingContext`.
///
/// Heuristic first, so a meeting has a usable state without a model. A later LLM pass can
/// refine the same record. System-audio lines may create candidate actions; they never
/// become authorised work.
enum MeetingContextExtractor {
    private static let decisionMarks = ["we decided", "agreed to", "decision is", "we'll go with", "let's go with"]
    private static let actionMarks = ["can you", "could you", "please send", "please share", "action item", "i'll send", "i will send", "i'll do", "follow up"]
    private static let questionMarks = ["?"]
    private static let commitmentMarks = ["i'll", "i will", "i can take", "i'll own", "i'll handle"]
    private static let deadlineMarks = ["by friday", "by monday", "tomorrow", "next week", "eod", "end of day", "deadline"]
    private static let documentMarks = [".step", ".stp", ".pdf", ".docx", ".xlsx", ".fig", "deck", "doc", "spec", "cad"]

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
                if let candidate = MeetingIntentDetector.candidate(in: segment, speakerNames: speakerNames) {
                    if !next.candidateActions.contains(where: { $0.action == candidate.action && $0.object == candidate.object }) {
                        next.candidateActions.append(candidate)
                    }
                }
            }
            if questionMarks.contains(where: text.contains) {
                append(item, to: &next.questions)
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
        }

        let names = Set(segments.compactMap { speakerNames[$0.displaySpeaker] ?? $0.displaySpeaker })
        next.participants = Array(Set(next.participants).union(names)).sorted()
        return next
    }

    private static func append(_ item: MeetingContextItem, to list: inout [MeetingContextItem]) {
        if list.contains(where: { $0.text == item.text }) { return }
        list.append(item)
        if list.count > 40 { list.removeFirst(list.count - 40) }
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
        let looksLikeAsk = ["can you", "could you", "please send", "please share", "send me", "share the"]
            .contains { lowered.contains($0) }
        guard looksLikeAsk else { return nil }

        return MeetingCandidateAction(
            recipient: segment.source == .system ? (speakerNames[segment.displaySpeaker] ?? segment.displaySpeaker) : nil,
            action: "share or send",
            object: object(in: text),
            speaker: speakerNames[segment.displaySpeaker] ?? segment.displaySpeaker,
            source: segment.source,
            confidence: "high"
        )
    }

    /// Other people provide context, never authority.
    static func mayExecute(source: AudioSource) -> Bool {
        source == .mic
    }

    static func resolveThat(in context: MeetingContext) -> MeetingCandidateAction? {
        context.candidateActions.last
    }

    private static func object(in text: String) -> String? {
        let markers = ["step", "cad", "deck", "doc", "file", "proposal", "spec"]
        let lowered = text.lowercased()
        return markers.first { lowered.contains($0) }
    }
}
