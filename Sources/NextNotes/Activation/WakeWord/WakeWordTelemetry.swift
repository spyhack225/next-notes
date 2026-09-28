import Foundation
import os

/// Production wake tallies: misses and false accepts, written where D7 can read them.
///
/// Detections already land in `agent-audit.jsonl` as `kind: "wake"` (via
/// `ActivationController.beginAgent`) and in `metrics.jsonl` as the
/// `agent.wake_to_listening_ui` span. Nothing counted the other two outcomes,
/// the other two outcomes, so "often fails" stayed unfalsifiable. These two functions
/// are the other half:
///
/// - `recordMiss` — the configured listener did not fire. Today the only producer with
///   ground truth is the calibrator's timeout path (`WakeWordCalibrator.listen`): the
///   user was asked to say the phrase inside a 6 s window and the configured ears did
///   not fire. `reason` names the shape (`heard-only-at-maximum`, `silence-or-no-mic`,
///   `unheard-at-configured-sensitivity`); `heardAs` carries the generous listener's
///   variant attribution when it heard what the configured one missed.
/// - `recordFalseAccept` — the spotter fired on speech the user disowned. The only
///   producer is the island's "That wasn't for you" affordance, which is owned by the
///   surface agent — this type only provides the sink (see the hook spec returned with
///   this change).
///
/// Each call writes two durable lines beside the existing wake logging, and bumps an
/// in-memory counter for the session:
///
/// - `agent-audit.jsonl`: `kind` `.wakeMiss` / `.wakeFalse` (additive cases on
///   `AgentAuditEntry.Kind`; the existing `kind: "wake"` lines are untouched).
/// - `metrics.jsonl`: a zero-duration marker span, `wake.miss` / `wake.false`, with the
///   reason in `note` (additive cases on `LatencySpanID`; existing spans untouched).
///
/// The D7 manual tally reads off-device, e.g.:
///
/// ```bash
/// grep -c '"kind":"wakeMiss"' "$HOME/Library/Application Support/Next Notes/agent-audit.jsonl"
/// grep -c '"kind":"wakeFalse"' "$HOME/Library/Application Support/Next Notes/agent-audit.jsonl"
/// grep -c 'wake\.miss' "$HOME/Library/Application Support/Next Notes/metrics.jsonl"
/// ```
///
/// Under `--selftest-*` both sinks stay hermetic: `AgentAuditLog` keeps entries in
/// memory without touching the user's audit file, and `MetricsStore.shared` points at
/// a per-process temp directory. Calling either from a self-test is safe.
@MainActor
final class WakeWordTelemetry {
    static let shared = WakeWordTelemetry()

    /// Misses recorded this launch (durable count lives in the two JSONL files).
    private(set) var misses = 0
    /// False accepts recorded this launch.
    private(set) var falseAccepts = 0

    private init() {}

    func recordMiss(reason: String, heardAs: String?) {
        misses += 1
        let detail = heardAs == nil
            ? "reason=\(reason)"
            : "reason=\(reason) heardAs=\(heardAs!)"
        AgentAuditLog.shared.record(kind: .wakeMiss, title: "Wake missed", detail: detail)
        LatencyTrace.record(.wakeMiss, seconds: 0, note: detail)
    }

    /// P1-29: an utterance that sounded close enough to the phrase to be worth a second look
    /// but was not accepted. The score and the reason, **never the transcript** — this row is
    /// written while a person is talking to their computer, and the words that came out of
    /// their mouth are exactly the thing an activity log must not become a copy of.
    ///
    /// At most one row per `nearMissMinimumInterval`: the wake listener is armed for whole
    /// working sessions, and a per-utterance row would turn a calibration signal into a
    /// transcript log with extra steps.
    /// The entry point for the detector, which is **nonisolated and real-time**: the wake
    /// listener must not hop to the main actor to decide whether to log, and must not wait for
    /// a row to be written before returning a `Detection`.
    ///
    /// So the two cheap checks — the floor and the interval — happen here on the calling
    /// thread, and only a row that will actually be written crosses to the main actor. That
    /// ordering is the whole point: doing the throttle inside the hop would spawn a task per
    /// rejected utterance for the length of a working session.
    nonisolated static func recordNearMiss(closeness: Double, reason: String) {
        guard shouldRecordNearMiss(closeness: closeness) else { return }
        Task { @MainActor in
            shared.writeNearMiss(closeness: closeness, reason: reason)
        }
    }

    /// The floor, then the interval. Lock-guarded because two audio deliveries can reach this
    /// concurrently and the interval is what keeps the row count honest.
    private nonisolated static func shouldRecordNearMiss(closeness: Double) -> Bool {
        guard closeness >= nearMissFloor else { return false }
        return nearMissGate.withLock { stamp in
            let now = Date()
            // Blocked only when there **is** a previous row and it is recent. The first
            // version wrote this as `guard let last = stamp, … else { return false }`, which
            // read as "no previous row means do not record" — so the first near miss of a
            // session, the one the calibration actually wants, was the only one ever dropped.
            // Every later one was blocked by the 10 s interval and the row never appeared at
            // all; `--selftest-wake` caught it with a direct call at a measured score.
            if let last = stamp, now.timeIntervalSince(last) < nearMissMinimumInterval {
                return false
            }
            stamp = now
            return true
        }
    }

    private func writeNearMiss(closeness: Double, reason: String) {
        misses += 1
        let detail = String(format: "closeness=%.2f reason=%@", closeness, reason)
        AgentAuditLog.shared.record(kind: .wakeMiss, title: "Wake near miss", detail: detail)
        LatencyTrace.record(.wakeMiss, seconds: 0, note: detail)
    }

    /// One row per this many seconds at most.
    nonisolated static let nearMissMinimumInterval: TimeInterval = 10
    /// Closeness at or above which a rejection is a *near* miss rather than unrelated speech.
    ///
    /// Measured on this Mac rather than guessed, and the measurement is the reason this is not
    /// "half the accept threshold". `WakePhraseConfirmation` scores **any** speech with vowels
    /// in it against the phrase, so ordinary conversation lands close to the bar by accident:
    /// "so what did you think about the roadmap" scores 0.260 and "the weather is nice today"
    /// 0.333, while the sound-alikes that are genuinely worth tuning on — "hey world this is a
    /// long sentence about the weather" at 0.667, "hey there we should probably talk about this
    /// later on" at 0.720 — sit well above it. A floor of 0.325 (half the bar) put idle
    /// chit-chat inside the signal; 0.50 separates the two groups with room on both sides, and
    /// it is written as an offset from the bar so moving `acceptedCloseness` moves it too.
    nonisolated static let nearMissFloor = WakePhraseConfirmation.acceptedCloseness - 0.15

    private nonisolated static let nearMissGate = OSAllocatedUnfairLock<Date?>(initialState: nil)

    func recordFalseAccept(keyword: String, reason: String) {
        falseAccepts += 1
        let detail = "keyword=\(keyword) reason=\(reason)"
        AgentAuditLog.shared.record(kind: .wakeFalse, title: "Wake false accept", detail: detail)
        LatencyTrace.record(.wakeFalse, seconds: 0, note: detail)
    }
}
