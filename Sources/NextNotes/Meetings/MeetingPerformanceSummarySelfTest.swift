import Foundation

@MainActor
enum MeetingPerformanceSummarySelfTest {
    static func run(write: (String) -> Void) async -> Bool {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ value: Bool) {
            checks += 1
            if !value { failures.append(name) }
        }
        let began = Date()
        var sample = ProcessSnapshot.current()
        sample.physicalFootprintBytes = 900_000_000
        sample.residentMemoryBytes = 600_000_000
        var summary = MeetingPerformanceSummary(recordingStartedAt: began)
        for index in 1...700 {
            sample.physicalFootprintBytes = index == 350 ? 1_200_000_000 : 900_000_000
            summary.observe(at: began.addingTimeInterval(Double(index) * 10),
                process: sample, queuedBytes: index == 300 ? 40_000 : 0,
                activeBytes: 448_000, paused: index == 200)
        }
        check("middle observation survives beyond 512 rows", summary.samples == 700
            && summary.peakSampledFootprintBytes == 1_200_000_000)
        check("coverage and gap retained", summary.firstSampleAt == began.addingTimeInterval(10)
            && summary.lastSampleAt == began.addingTimeInterval(7000)
            && summary.maximumSampleGapSeconds == 10)
        check("queue, active and pause counters retained", summary.peakQueuedBytes == 40_000
            && summary.peakActiveBytes == 448_000 && summary.pausedSamples == 1)
        sample.physicalFootprintBytes = nil
        summary.observe(at: began.addingTimeInterval(7095), process: sample,
                        queuedBytes: 0, activeBytes: 0, paused: false)
        check("unobserved interval is visible", summary.maximumSampleGapSeconds == 95)
        check("failed memory query stays unknown", summary.samples == 701
            && summary.footprintSamples == 700 && summary.peakSampledFootprintBytes == 1_200_000_000)
        let accepted = summary
        summary.observe(at: began.addingTimeInterval(5), process: sample,
                        queuedBytes: .max, activeBytes: .max, paused: true)
        check("backward time supplies no coverage", summary == accepted)
        do {
            let store = MeetingStore.isolated()
            let root = store.directory(for: UUID()).deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: root) }
            let original = Meeting(title: "Performance coverage fixture", start: began, status: .recording)
            check("fixture saved", store.save(original))
            let session = MeetingSession(meeting: original, store: store,
                                         captureHub: AudioCaptureHub(probe: true))
            let safe = MeetingDiskCapacity(immediateBytes: 10_000_000_000,
                                           importantBytes: 10_000_000_000)
            // The real existing health/sample/metadata path; no microphone/model starts.
            await session.checkResourceHealth(now: began.addingTimeInterval(1),
                                              capacityForTesting: safe, criticalForTesting: false)
            await session.checkResourceHealth(now: began.addingTimeInterval(2),
                                              capacityForTesting: safe, criticalForTesting: false)
            let loaded = store.freshReaderForTesting().meeting(id: original.id)
            check("actual session emits persisted observations", loaded?.performanceSummary?.samples == 2
                && loaded?.performanceSummary?.lastSampleAt.map { $0 >= began && $0 <= Date() } == true)
            check("actual sample retains footprint independently of RSS",
                  loaded?.performanceSummary?.peakSampledFootprintBytes != nil
                    && loaded?.performanceSummary?.peakSampledResidentBytes != nil)
            check("older metadata save admitted", store.save(original))
            check("older nil snapshot cannot erase coverage",
                  store.freshReaderForTesting().meeting(id: original.id)?.performanceSummary == loaded?.performanceSummary)
            var newer = original
            newer.performanceSummary = accepted
            check("long aggregate saved", store.save(newer))
            var stale = original
            stale.performanceSummary = MeetingPerformanceSummary(recordingStartedAt: began)
            check("older nonnil snapshot admitted", store.save(stale))
            check("stale snapshot cannot erase middle peak",
                  store.freshReaderForTesting().meeting(id: original.id)?.performanceSummary == accepted)
            let restartedWriter = store.freshReaderForTesting()
            check("fresh writer admits older metadata", restartedWriter.save(stale))
            check("persisted clock still binds the same recording",
                  restartedWriter.freshReaderForTesting().meeting(id: original.id)?.performanceSummary == accepted)
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let encoded = try encoder.encode(newer)
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object.removeValue(forKey: "performanceSummary")
            let legacy = try decoder.decode(Meeting.self,
                from: JSONSerialization.data(withJSONObject: object))
            check("legacy meeting remains readable with unknown coverage", legacy.id == newer.id
                && legacy.performanceSummary == nil)
            let direct = try decoder.decode(Meeting.self, from: encoded)
            check("full aggregate round trips", direct.performanceSummary == accepted)
            check("aggregate storage stays bounded", try encoder.encode(accepted).count < 2000)
        } catch { failures.append(error.localizedDescription) }
        for failure in failures { write("MEETING_PERFORMANCE_WRONG: \(failure)") }
        write(failures.isEmpty ? "MEETING_PERFORMANCE_OK: \(checks) actual-session/persistence and bounded-coverage checks"
                              : "MEETING_PERFORMANCE_FAILED: \(failures.count)/\(checks)")
        return failures.isEmpty
    }
}
