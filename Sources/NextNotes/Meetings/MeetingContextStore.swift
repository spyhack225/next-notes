import Foundation
import Observation

/// The live meeting's structured state, plus the last finished one the agent can still ask
/// about. Written beside `meeting.json` so a quit mid-call does not lose what was extracted.
@MainActor
@Observable
final class MeetingContextStore {
    static let shared = MeetingContextStore()
    static let fileName = "context.json"

    private(set) var current: MeetingContext?
    @ObservationIgnored private var lastSegments = 0

    private init() {}

    func ingest(_ segments: [TranscriptSegment], meeting: Meeting) {
        let fresh = segments.suffix(from: min(lastSegments, segments.count))
        lastSegments = segments.count
        var context = current?.meetingID == meeting.id
            ? current!
            : MeetingContext.empty(
                meetingID: meeting.id,
                title: meeting.title,
                participants: meeting.attendees
            )
        context = MeetingContextExtractor.apply(
            Array(fresh),
            to: context,
            speakerNames: meeting.speakerNames
        )
        current = context
        save(context, meetingID: meeting.id)
    }

    func load(meetingID: UUID) -> MeetingContext? {
        let url = MeetingStore.shared.directory(for: meetingID).appendingPathComponent(Self.fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(MeetingContext.self, from: data)
    }

    func reset() {
        replace(nil)
    }

    /// `--selftest-realtime` plants a fixture without a recording.
    func replace(_ context: MeetingContext?) {
        current = context
        lastSegments = 0
    }

    func recentTranscript(minutes: Double) -> String {
        guard let session = MeetingController.shared.session else { return "" }
        let cutoff = session.elapsed - (minutes * 60)
        return session.segments
            .filter { $0.start >= cutoff && $0.kind != .agentCommand }
            .plainText(speakerNames: session.meeting.speakerNames)
    }

    func searchTranscript(_ query: String) -> String {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return "" }
        let segments = MeetingController.shared.session?.segments
            ?? (current.flatMap { MeetingStore.shared.transcript(for: $0.meetingID) } ?? [])
        let hits = segments.filter {
            $0.kind != .agentCommand && $0.text.lowercased().contains(needle)
        }
        return hits.prefix(12).map { "\($0.displaySpeaker): \($0.text)" }.joined(separator: "\n")
    }

    private func save(_ context: MeetingContext, meetingID: UUID) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(context) else { return }
        let url = MeetingStore.shared.directory(for: meetingID).appendingPathComponent(Self.fileName)
        try? data.write(to: url, options: .atomic)
    }
}
