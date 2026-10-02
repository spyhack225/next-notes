import Foundation

/// Identical pure age/evidence inputs for the missing-feature original and fixed policy.
/// No task/store/process/model is created and no stale/retry verdict is inferred.
@MainActor
enum TaskHeartbeatSelfTest {
    static func cases(check: (Bool, String) -> Void) {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let oldAge: TimeInterval = 40 * 24 * 60 * 60
        let old = now.addingTimeInterval(-oldAge)
        let windows: [(TaskRuntimeClass, TimeInterval)] = [
            (.localDeterministic, 30), (.cloudModel, 300), (.browserOrMCP, 300),
            (.acpWorker, 900), (.scheduledResearch, 1800)
        ]
        for (runtime, window) in windows {
            check(TaskHeartbeat.ageWindowSeconds(for: runtime) == window,
                  "Heartbeat policy: roadmap starting window missing for \(runtime.rawValue)")
            check(TaskHeartbeat.classify(status: .running, runtimeClass: runtime,
                heartbeatAt: now, now: now) == .withinWindow(age: 0, window: window),
                "Heartbeat policy: current beat not classified as age only for \(runtime.rawValue)")
            check(TaskHeartbeat.classify(status: .running, runtimeClass: runtime,
                heartbeatAt: now.addingTimeInterval(-(window - 0.5)), now: now)
                  == .withinWindow(age: window - 0.5, window: window),
                "Heartbeat policy: before-window boundary incorrect for \(runtime.rawValue)")
            check(TaskHeartbeat.classify(status: .running, runtimeClass: runtime,
                heartbeatAt: now.addingTimeInterval(-window), now: now)
                  == .ageCandidate(age: window, window: window),
                "Heartbeat policy: exact-window boundary missing for \(runtime.rawValue)")
            check(TaskHeartbeat.classify(status: .running, runtimeClass: runtime,
                heartbeatAt: now.addingTimeInterval(-(window + 0.5)), now: now)
                  == .ageCandidate(age: window + 0.5, window: window),
                "Heartbeat policy: elapsed-window boundary missing for \(runtime.rawValue)")
            check(TaskHeartbeat.classify(status: .running, runtimeClass: runtime,
                heartbeatAt: old, now: now) == .ageCandidate(age: oldAge, window: window),
                "Heartbeat policy: forty-day worker age did not remain only a candidate for \(runtime.rawValue)")
            check(TaskHeartbeat.classify(status: .running, runtimeClass: runtime,
                heartbeatAt: nil, now: now) == .unknown(.missingHeartbeat),
                "Heartbeat policy: missing beat inferred failure for \(runtime.rawValue)")
            check(TaskHeartbeat.classify(status: .running, runtimeClass: runtime,
                heartbeatAt: now.addingTimeInterval(1), now: now) == .unknown(.futureHeartbeat),
                "Heartbeat policy: future beat inferred health for \(runtime.rawValue)")
        }
        check(TaskHeartbeat.ageWindowSeconds(for: .waitingOnPerson) == nil,
              "Heartbeat policy: waiting on a person acquired an age window")
        for status in [AgentTaskStatus.queued, .recovering, .completed, .failed, .cancelled] {
            check(TaskHeartbeat.classify(status: status, runtimeClass: .acpWorker,
                heartbeatAt: old, permissionWait: true, now: now) == .excluded,
                "Heartbeat policy: excluded status became an age/wait candidate: \(status.rawValue)")
            check(TaskHeartbeat.classify(status: status, runtimeClass: nil,
                heartbeatAt: nil, now: Date(timeIntervalSinceReferenceDate: .nan)) == .excluded,
                "Heartbeat policy: excluded status required clock evidence: \(status.rawValue)")
        }
        let runtimes: [TaskRuntimeClass?] = [nil, .acpWorker, .waitingOnPerson]
        for status in [AgentTaskStatus.waitingForPermission, .waitingForCompatibilityCLI, .waitingForInput] {
            for runtime in runtimes {
                check(TaskHeartbeat.classify(status: status, runtimeClass: runtime,
                    heartbeatAt: old, permissionWait: false, now: now) == .waitingOnPerson,
                    "Heartbeat policy: forty-day pending person interaction became an age candidate: \(status.rawValue)")
                check(TaskHeartbeat.classify(status: status, runtimeClass: runtime,
                    heartbeatAt: nil, now: now) == .waitingOnPerson,
                    "Heartbeat policy: pending person interaction required a heartbeat: \(status.rawValue)")
            }
        }
        let beats: [Date?] = [old, nil, now.addingTimeInterval(1),
                              Date(timeIntervalSinceReferenceDate: .nan)]
        for beat in beats {
            check(TaskHeartbeat.classify(status: .running, runtimeClass: .waitingOnPerson,
                heartbeatAt: beat, now: now) == .waitingOnPerson,
                "Heartbeat policy: waiting-on-person class acquired an age verdict")
        }
        check(TaskHeartbeat.classify(status: .running, runtimeClass: .acpWorker,
            heartbeatAt: old, permissionWait: true, now: now) == .waitingOnPerson,
            "Heartbeat policy: real Gate wait did not exclude forty-day ACP age")
        check(TaskHeartbeat.classify(status: .running, runtimeClass: nil,
            heartbeatAt: nil, permissionWait: true, now: now) == .waitingOnPerson,
            "Heartbeat policy: current Gate wait required inferred runtime/beat")
        let waits: [Bool?] = [false, nil]
        for wait in waits {
            check(TaskHeartbeat.classify(status: .running, runtimeClass: .acpWorker,
                heartbeatAt: old, permissionWait: wait, now: now) == .ageCandidate(age: oldAge, window: 900),
                "Heartbeat policy: no/unknown Gate wait was treated as a stale verdict or positive wait")
        }
        check(TaskHeartbeat.classify(status: .running, runtimeClass: nil,
            heartbeatAt: old, now: now) == .unknown(.missingRuntimeClass),
            "Heartbeat policy: missing runtime silently acquired a default window")
        for invalid in [Double.nan, .infinity, -.infinity] {
            check(TaskHeartbeat.classify(status: .running, runtimeClass: .acpWorker,
                heartbeatAt: old, now: Date(timeIntervalSinceReferenceDate: invalid)) == .unknown(.invalidClock),
                "Heartbeat policy: nonfinite current clock acquired an age verdict")
            check(TaskHeartbeat.classify(status: .running, runtimeClass: .acpWorker,
                heartbeatAt: Date(timeIntervalSinceReferenceDate: invalid), now: now) == .unknown(.invalidClock),
                "Heartbeat policy: nonfinite heartbeat acquired an age verdict")
        }
        check(TaskHeartbeat.classify(status: .running, runtimeClass: .acpWorker,
            heartbeatAt: Date(timeIntervalSinceReferenceDate: -1e308),
            now: Date(timeIntervalSinceReferenceDate: 1e308)) == .unknown(.invalidClock),
            "Heartbeat policy: overflowed elapsed age acquired an age verdict")
        let labels: [(TaskHeartbeatAge, String)] = [
            (.excluded, "excluded"), (.waitingOnPerson, "waitingOnPerson"),
            (.withinWindow(age: 0, window: 30), "withinWindow"),
            (.ageCandidate(age: oldAge, window: 900), "ageCandidate"),
            (.unknown(.missingRuntimeClass), "unknown"), (.unknown(.missingHeartbeat), "unknown"),
            (.unknown(.invalidClock), "unknown"), (.unknown(.futureHeartbeat), "unknown")
        ]
        for (age, label) in labels {
            check(age.diagnosticName == label,
                  "Heartbeat policy: diagnostic label exposed payload or changed classification")
        }
        let unknown = TaskHeartbeatEvidence()
        check(unknown.processAlive == .unknown && unknown.backendSessionAlive == .unknown
              && unknown.toolInFlight == .unknown && unknown.receiptCreated == .unknown,
              "Heartbeat policy: absent current evidence was reconstructed as yes/no")
        var supplied = unknown
        supplied.processAlive = .yes
        supplied.backendSessionAlive = .no
        check(supplied.processAlive == .yes && supplied.backendSessionAlive == .no
              && supplied.toolInFlight == .unknown && supplied.receiptCreated == .unknown,
              "Heartbeat policy: one producer's observation fabricated other current facts")
        supplied.toolInFlight = .yes
        supplied.receiptCreated = .no
        check(supplied == TaskHeartbeatEvidence(processAlive: .yes, backendSessionAlive: .no,
              toolInFlight: .yes, receiptCreated: .no),
              "Heartbeat policy: explicit current evidence was not retained exactly")
        check(unknown == TaskHeartbeatEvidence(),
              "Heartbeat policy: supplied evidence mutated independent unknown defaults")
    }
}
