import Foundation

/// Relabels existing evidence after the final transcript is committed. This is a
/// projection of diarization, never participant discovery or an authority decision.
enum MeetingSpeakerProjection {
    static func apply(_ context: MeetingContext, segments: [TranscriptSegment],
                      liveSegments: [TranscriptSegment] = [], speakerNames: [String: String]) -> MeetingContext {
        let speech = segments.filter { $0.includeInMeetingNotes }.map {
            (segment: $0, text: normalized($0.text))
        }
        func speaker(for quote: String, source: AudioSource, at start: TimeInterval, endingAt end: TimeInterval? = nil) -> String? {
            let wanted = normalized(quote)
            guard wanted.count >= 12 else { return nil }
            let matches = speech.filter {
                $0.segment.source == source
                    && $0.segment.start <= start && start < $0.segment.end
                    && $0.text.range(of: wanted) != nil
            }
            // Repeated speech belonging to different voices is not a binding. A source
            // default is retained until that source actually has a diarized label.
            var labels = Set(matches.map { $0.segment.displaySpeaker })
            if let end {
                // The complete live utterance must not span competing final labels.
                // Looking only at its first instant would miss a speaker overlap.
                labels.formUnion(speech.filter {
                    $0.segment.source == source && $0.segment.start < end && $0.segment.end > start
                }.map { $0.segment.displaySpeaker })
            }
            guard !matches.isEmpty else { return nil }
            guard labels.count == 1, let label = labels.first else { return nil }
            return speakerNames[label] ?? label
        }
        let live = liveSegments.filter { $0.includeInMeetingNotes }.map {
            (segment: $0, text: normalized($0.text))
        }
        func project(_ items: [MeetingContextItem]) -> [MeetingContextItem] {
            items.map { item in
                var updated = item
                let quote = normalized(item.text)
                let anchors = live.filter {
                    $0.segment.source == item.source && $0.text.range(of: quote) != nil
                }
                if anchors.count == 1,
                   let label = speaker(for: item.text, source: item.source, at: anchors[0].segment.start, endingAt: anchors[0].segment.end) {
                    updated.speaker = label
                }
                return updated
            }
        }
        var next = context
        next.topics = project(context.topics)
        next.decisions = project(context.decisions)
        next.questions = project(context.questions)
        next.commitments = project(context.commitments)
        next.deadlines = project(context.deadlines)
        next.documentsMentioned = project(context.documentsMentioned)
        next.actionItems = project(context.actionItems)
        next.unresolvedItems = project(context.unresolvedItems)
        next.candidateActions = context.candidateActions.map { candidate in
            var updated = candidate
            // Candidate evidence has a source and an exact clock anchor. Legacy rows
            // lacking that anchor keep their existing attribution.
            if let quote = candidate.evidence, let start = candidate.evidenceStart,
               let label = speaker(for: quote, source: candidate.source, at: start) {
                updated.speaker = label
            }
            return updated
        }
        return next
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
