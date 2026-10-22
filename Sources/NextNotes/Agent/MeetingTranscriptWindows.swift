import Foundation

/// Transcript-only selection. Related context can locate a window; it never contributes
/// words to the transcript or supplies authority to execute a follow-up.
enum MeetingTranscriptWindows {
    static func anchors(in segments: [TranscriptSegment], context: MeetingContext?, meetingID: UUID) -> [TimeInterval] {
        guard let context, context.meetingID == meetingID else { return [] }
        let speech = segments.filter(\.includeInMeetingNotes).sorted { $0.start < $1.start }
        var anchors = context.candidateActions.compactMap(\.evidenceStart).filter { $0.isFinite && $0 >= 0 }
        for item in context.actionItems {
            let wanted = Set(MemoryGuard.contentTokens(item.text))
            guard !wanted.isEmpty else { continue }
            if let segment = speech.first(where: {
                Double(wanted.intersection(Set(MemoryGuard.contentTokens($0.text))).count) / Double(wanted.count) >= 0.6
            }) {
                anchors.append(segment.start)
            }
        }
        return Array(Set(anchors)).sorted(by: >)
    }

    /// Whole windows around the newest asks, then the longest remaining contiguous tail.
    /// Uses the existing fitter's measured character budget; it does not retokenize or wait.
    static func build(
        segments: [TranscriptSegment], anchors: [TimeInterval], speakerNames: [String: String],
        budgetCharacters: Int, radius: TimeInterval = 30
    ) -> String {
        guard budgetCharacters > 0 else { return "" }
        let speech = segments.enumerated().filter { $0.element.includeInMeetingNotes }
            .sorted { a, b in a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start }
            .map(\.element)
        let whole = speech.plainText(speakerNames: speakerNames)
        guard whole.count > budgetCharacters else { return whole }
        var selected: Set<Int> = []
        func render(_ selected: Set<Int>) -> String {
            var groups: [[TranscriptSegment]] = []
            var last: Int?
            for index in selected.sorted() {
                if last == nil || index != last! + 1 { groups.append([]) }
                groups[groups.count - 1].append(speech[index])
                last = index
            }
            return groups.map { $0.plainText(speakerNames: speakerNames) }.joined(separator: "\n…\n")
        }
        for anchor in Array(Set(anchors.filter { $0.isFinite && $0 >= 0 })).sorted(by: >) {
            let window = Set(speech.indices.filter { speech[$0].start >= anchor - radius && speech[$0].start <= anchor + radius })
            let candidate = selected.union(window)
            if render(candidate).count <= budgetCharacters { selected = candidate }
        }
        for index in speech.indices.reversed() {
            if selected.contains(index) { continue }
            let candidate = selected.union([index])
            guard render(candidate).count <= budgetCharacters else { break }
            selected = candidate
        }
        return render(selected)
    }
}
