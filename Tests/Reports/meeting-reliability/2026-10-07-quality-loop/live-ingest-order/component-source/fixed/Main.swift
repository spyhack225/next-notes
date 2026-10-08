import Darwin
import Foundation
@main enum Main {
    @MainActor static func main() async { exit(Int32(await run())) }
    @MainActor static func run() async -> Int {
        var wrong = 0
        func check(_ label: String, _ value: Bool) {
            if !value { wrong += 1 }
            print("INGEST_COMPONENT_CHECK case=\(label) pass=\(value)")
        }
        let backing = MeetingStore.shared
        let meeting = Meeting(title: "Authored coupled producer", start: Date(), status: .recording)
        precondition(backing.save(meeting))
        defer {
            MeetingController.shared.session = nil
            MeetingContextStore.shared.reset()
            try? FileManager.default.removeItem(at: backing.root)
        }
        let session = SessionAdapter(meeting)
        MeetingController.shared.session = session
        let mic = TranscriptSegment(start: 10, end: 40, text: "Let's talk about the current microphone topic.", source: .mic)
        let system = TranscriptSegment(start: 0, end: 40, text: "I will ask for the delivery schedule.", source: .system)
        // Real lifted add->insertSegment->ingest before publication Task may run.
        session.accept(mic); session.accept(system)
        check("actual-session-ordered-insert", session.segments.map(\.start) == [0, 10])
        let beforeBus = MeetingContextStore.shared.recentEvidenceSegments(for: meeting.id)
        check("actual-caller-keeps-late-source-before-bus", beforeBus.contains { $0 == system })
        check("actual-caller-cadence-before-bus", MeetingContextStore.shared.reconcileScheduledForTesting)
        check("actual-caller-source-authority", MeetingContextStore.shared.current?.commitments.contains {
            $0.text == system.text && $0.source == .system && !$0.isAuthoritative
        } == true)
        var events: [TranscriptEvent] = []
        for _ in 0..<64 where events.count < 2 {
            await Task.yield(); events.append(contentsOf: await TranscriptBus.shared.take())
        }
        check("existing-publication-tasks-delivered", events.count == 2)
        for event in events { MeetingContextStore.shared.ingestFinal(event) }
        let afterBus = MeetingContextStore.shared.recentEvidenceSegments(for: meeting.id)
        check("existing-bus-consumer-dedups", afterBus == beforeBus)
        check("existing-bus-consumer-speech-order", afterBus.map(\.start) == [0, 10])
        MeetingController.shared.session = nil
        MeetingContextStore.shared.reset()
        let maintained = await MeetingContextIngestOrderSelfTest.run { print($0) }
        check("unchanged-maintained-regression", maintained)
        print("INGEST_COMPONENT_SCOPE actualContextStore=true exactSessionAddBody=true exactReader=true substitutedCapture=true substitutedWake=true substitutedBusTransport=true substitutedMeetingStore=true nativeSession=false modelIntent=false")
        print("INGEST_COMPONENT_\(wrong == 0 ? "OK" : "FAILED"): \(wrong) wrong")
        return wrong == 0 ? 0 : 1
    }
}
