import Foundation
// Explicit model-free component boundaries, not native capture/store/async bus proof.
enum SelfTest { static let isRunning = true; static let requested: String? = "--selftest-meeting-ingest-order" }
@MainActor final class Settings {
    static let shared = Settings(); var usesHarnessPreferencesForTesting = true
    var meetingLiveUnderstanding: Bool? = true
}
struct PressureSnapshot: Sendable { let allowsOptionalWork = true }
enum ModelResidencyPolicy { static var pressureSnapshot: PressureSnapshot { PressureSnapshot() } }
enum ModelRoleChoice: Sendable { case builtIn, appleFoundation, installedModel, cloud, localServer, app }
enum Role { case agent }
@MainActor final class ModelRoleStore {
    static let shared = ModelRoleStore()
    struct Resolution { var effective = ModelRoleChoice.builtIn }
    func resolution(for role: Role) -> Resolution { Resolution() }
}
struct Meeting: Sendable {
    enum Status: Sendable { case recording }
    var id = UUID(); var title: String; var start: Date; var status: Status
    var attendees: [String] = []; var speakerNames: [String:String] = [:]
}
@MainActor final class MeetingController { static let shared = MeetingController(); var session: SessionAdapter? }
@MainActor enum MeetingContextBusBridge { static func start(store: MeetingContextStore) { } }
enum MeetingSpeakerProjection {
    static func apply(_ context: MeetingContext, segments: [TranscriptSegment], liveSegments: [TranscriptSegment],
                      speakerNames: [String:String]) -> MeetingContext { context }
}
@MainActor enum MeetingLiveAgent { static func runSelfTest() -> Bool { true } }
extension Array where Element == TranscriptSegment {
    func plainText(speakerNames: [String:String]) -> String { map(\.text).joined(separator: "\n") }
}
@MainActor final class MeetingStore {
    static let shared = isolated()
    let root: URL; private var meetings: [UUID:Meeting] = [:]
    private init(root: URL) { self.root = root }
    static func isolated() -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesIngestOrder-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return MeetingStore(root: root)
    }
    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    @discardableResult func save(_ meeting: Meeting) -> Bool {
        do { try FileManager.default.createDirectory(at: directory(for: meeting.id), withIntermediateDirectories: true)
            meetings[meeting.id] = meeting; return true
        } catch { return false }
    }
    func meeting(id: UUID) -> Meeting? { meetings[id] }
    func transcript(for id: UUID) -> [TranscriptSegment] { [] }
    func liveTranscript(for id: UUID) -> [TranscriptSegment] { [] }
}
@MainActor final class ActivationController {
    static let shared = ActivationController()
    func handleWake(in row: TranscriptSegment) -> TranscriptSegment { row }
}
@MainActor enum LatencyTrace {
    enum Stage { case meetingSpeechToFinal, meetingTranscriptToContext, meetingActionPhraseToCandidate }
    struct Span { func end(note: String) { } }
    static func record(_ stage: Stage, seconds: Double, note: String) { }
    static func start(_ stage: Stage) -> Span { Span() }
}
struct Throttle {
    mutating func markPending() { }
    func shouldWrite(at clock: Double) -> Bool { false }
}
// Session.add keeps its actual publication Task. Only this bus transport is substituted;
// Main deterministically delivers recorded finals into the real ingestFinal consumer.
actor TranscriptBus {
    static let shared = TranscriptBus()
    private var values: [TranscriptEvent] = []
    func publish(_ event: TranscriptEvent) { values.append(event) }
    func take() -> [TranscriptEvent] { defer { values.removeAll() }; return values }
}
