import Foundation
// Component compile dependencies only. None may execute in this apply/merge fixture.
enum MeetingLiveAgent {
    @MainActor static func runSelfTest() -> Bool { fatalError("Not exercised: live/native consumer") }
}
enum MeetingContextReconciler {
    // Same production constant, source pin retained separately.
    static let inferredConfidence = "inferred"
    struct Suggestion { var proposedCandidates: [MeetingCandidateAction] = [] }
    static func apply(_ suggestion: Suggestion, to context: MeetingContext,
                      recentSegments: [TranscriptSegment] = []) -> MeetingContext {
        fatalError("Not exercised: semantic action model consumer")
    }
}
