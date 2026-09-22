import Foundation

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

    func recordFalseAccept(keyword: String, reason: String) {
        falseAccepts += 1
        let detail = "keyword=\(keyword) reason=\(reason)"
        AgentAuditLog.shared.record(kind: .wakeFalse, title: "Wake false accept", detail: detail)
        LatencyTrace.record(.wakeFalse, seconds: 0, note: detail)
    }
}
