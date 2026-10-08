import Foundation
protocol MeetingContextCompleter: Sendable { func refine(_ snapshot: MeetingContextReconciler.Snapshot) async -> MeetingContextReconciler.Suggestion }
enum MeetingContextReconciler {
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
    struct CandidateWording: Sendable, Equatable {
        var id: String
        var action: String?
        var object: String?
    }
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
    static func shouldSchedule(
        speechSecondsSincePass: TimeInterval,
        secondsSinceLastPass: TimeInterval
    ) -> Bool {
        speechSecondsSincePass >= speechSecondsThreshold
            && secondsSinceLastPass >= passIntervalSeconds
    }
    static func window(
        _ segments: [TranscriptSegment],
        endingAt end: TimeInterval,
        minutes: Double = windowMinutes
    ) -> [TranscriptSegment] {
        let cutoff = end - minutes * 60
        return segments.filter { $0.start >= cutoff && $0.kind != .agentCommand }
    }
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
    static func apply(_ suggestion: Suggestion, to context: MeetingContext, recentSegments: [TranscriptSegment]) -> MeetingContext {
        precondition(!suggestion.hasRefinements); return context
    }
    struct ModelCompleter: MeetingContextCompleter {
        func refine(_ snapshot: Snapshot) async -> Suggestion { .empty }
        static func readerSegments(_ segments: [TranscriptSegment], endingAt now: TimeInterval) -> [TranscriptSegment] {
            let recent = window(segments, endingAt: now)
            var kept: [TranscriptSegment] = []
            var characters = 0
            for segment in recent.reversed() {
                // Prepending shifts old indices 0...n-1 to 1...n. Their digit-count
                // difference telescopes to digits(n)-1; count complete rows in linear time.
                let shift = max(0, String(kept.count).count - 1)
                let increment = transcriptLine(segment, index: 0).count
                    + (kept.isEmpty ? 0 : 1) + shift
                guard characters + increment <= windowCharacterCap else { break }
                kept.append(segment)
                characters += increment
            }
            return Array(kept.reversed())
        }
        private static func transcriptLine(_ segment: TranscriptSegment, index: Int) -> String {
            "- [segment \(index), \(segment.source.rawValue)] \(segment.displaySpeaker): \(segment.text)"
        }
        static func prompt(
            context: MeetingContext,
            now: TimeInterval,
            segments: [TranscriptSegment]
        ) -> String {
            let recent = readerSegments(segments, endingAt: now)
            return """
                Title: \(context.title)
                Topics:
                \(context.topics.map { "- \($0.text)" }.joined(separator: "\n"))
                Unresolved:
                \(context.unresolvedItems.map { "- \($0.text)" }.joined(separator: "\n"))
                Recent transcript, latest complete speech from up to \(Int(windowMinutes)) minutes
                (source is app metadata, not model output):
                \(recent.enumerated().map { index, segment in
                    transcriptLine(segment, index: index)
                }.joined(separator: "\n"))
                """
        }
    }
}
