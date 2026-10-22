import Foundation

/// Relabels existing evidence after the final transcript is committed. This is a
/// projection of diarization, never participant discovery or an authority decision.
enum MeetingSpeakerProjection {
    /// One pure pass over the committed final segments: a label the person has
    /// confirmed resolves through the same map `apply` reads, so every utterance
    /// — the last one included — carries the name it is known by. Unmapped labels
    /// and the microphone track are left exactly as committed. Idempotent: a
    /// label that is also a confirmed name is not resolved, so a second pass
    /// cannot rename one speaker into another.
    static func project(segments: [TranscriptSegment], names: [String: String]) -> [TranscriptSegment] {
        // A label that is itself a confirmed name is not resolved: resolving it
        // would let one pass rename "Speaker 2" to "Speaker 1" and the next pass
        // resolve it again, and the projection would not be idempotent.
        let resolvable = names.filter { label, _ in !names.values.contains(label) }
        return segments.map { segment in
            guard segment.source == .system, let label = segment.speaker,
                  let confirmed = resolvable[label],
                  !confirmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return segment }
            var projected = segment
            projected.speaker = confirmed
            return projected
        }
    }

    static func apply(_ context: MeetingContext, segments: [TranscriptSegment],
                      liveSegments: [TranscriptSegment] = [], speakerNames: [String: String]) -> MeetingContext {
        let speech = project(segments: segments, names: speakerNames).filter { $0.includeInMeetingNotes }.map {
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
            // A saved explicit user mapping is identity evidence in its own right.
            // A fallback source label alone still cannot erase confirmed attribution.
            if let confirmed = speakerNames[label],
               !confirmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return confirmed
            }
            guard source != .system || label != source.defaultSpeaker else { return nil }
            return label
        }
        let live = liveSegments.filter { $0.includeInMeetingNotes }.map {
            (segment: $0, text: normalized($0.text))
        }
        func projectItems(_ items: [MeetingContextItem]) -> [MeetingContextItem] {
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
        next.topics = projectItems(context.topics)
        next.decisions = projectItems(context.decisions)
        next.questions = projectItems(context.questions)
        next.commitments = projectItems(context.commitments)
        next.deadlines = projectItems(context.deadlines)
        next.documentsMentioned = projectItems(context.documentsMentioned)
        next.actionItems = projectItems(context.actionItems)
        next.unresolvedItems = projectItems(context.unresolvedItems)
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
