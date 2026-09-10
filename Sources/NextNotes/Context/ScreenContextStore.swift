import Foundation
import Observation

/// Holds the harvest for the dictation that is currently in flight.
///
/// This exists for the same reason `OutputProfileStore.captureTarget()` does, and is
/// deliberately shaped like it. The names have to be read at key-down, because the user may
/// switch away mid-utterance and because that is the one moment when a 120 ms tree walk costs
/// nothing. But they are *needed* twice and at two very different times: the ASR bias list is
/// wanted before the first audio buffer arrives, and the cleanup prompt is wanted seconds
/// later. So the harvest is a task started once and awaited twice, with two different
/// patiences — see `awaitCapture(within:)`.
@MainActor
@Observable
final class ScreenContextStore {
    static let shared = ScreenContextStore()

    /// The result once it has landed, for `awaitCapture` and the log. Nil during the walk, and
    /// again as soon as the text has been injected — which is why the one thing the *user* may
    /// need to be told outlives it in `stubRemediation` rather than being read off here.
    private(set) var captured: ScreenContext?

    /// The stub-tree hint from the most recent harvest that produced one, kept until the user
    /// dismisses it. Nil when no harvest has hit that failure this launch.
    ///
    /// Sticky, deliberately, and `clearCaptured()` does not touch it. `captured` lives for the
    /// few hundred milliseconds a dictation is in flight, and the Settings window cannot be
    /// frontmost during one — so a banner bound to the live capture would have rendered
    /// approximately never, which is how the remediation text sat unread in this file to begin
    /// with. It outlives the capture it came from because the *setting* it describes outlives
    /// it: nothing about "Cursor's accessibility support is off" stops being true when the
    /// dictation ends. Still written under the capture token, so a walk that returns after a
    /// later hold cannot post a hint for a window nobody is looking at.
    private(set) var stubRemediation: String?

    /// The walk in flight, kept so `awaitCapture` has something to wait on and so a result
    /// that lands after the user has started a *second* dictation can be recognised as stale.
    private var inFlight: Task<Void, Never>?
    /// Bumped by every `beginCapture` and every `clearCaptured`. The session counter in
    /// `DictationController` exists for the same reason and this is the same hazard one layer
    /// down: two holds can be in flight against one set of slots, and a walk that returns late
    /// must never overwrite the capture belonging to the hold that came after it.
    private var captureToken: UInt64 = 0

    private init() {}

    /// The kill switch. Lives on `Settings` like every other user preference, under the
    /// "screenContextEnabled" key it was first written with so nobody's choice is lost.
    var isEnabled: Bool {
        get { Settings.shared.screenContextEnabled }
        set { Settings.shared.screenContextEnabled = newValue }
    }

    /// Starts a harvest for the app captured at key-down. Returns immediately.
    ///
    /// A no-op returning false when the feature is off, when there is no target, when the
    /// bundle is on the deny list, or when no adapter covers it — all four are "this app is
    /// not one of the three", which is the normal case.
    ///
    /// - Parameter originBundleID: the bundle identifier of the process `processID` belongs to.
    ///   Required to equal `target.bundleID`, and that check is the reason this parameter
    ///   exists rather than the caller being trusted: the adapter lookup and the deny list are
    ///   consulted for the target's bundle while the walk runs against the origin's pid, and
    ///   `captureTarget()` is allowed to fall back to the last foreign app while
    ///   `captureOrigin()` is not. When they disagree, the honest answer is no harvest — a list
    ///   of names labelled "Cursor" that was read out of some other window would poison the log
    ///   line, the Settings hint and the prompt's own claim about where the names came from.
    @discardableResult
    func beginCapture(
        for target: OutputTarget?,
        processID: pid_t?,
        originBundleID: String?
    ) -> Bool {
        captureToken &+= 1
        let token = captureToken
        captured = nil
        inFlight = nil

        guard isEnabled,
              let target,
              let processID,
              let originBundleID,
              originBundleID == target.bundleID,
              AXHarvester.supports(bundleID: target.bundleID)
        else { return false }

        let bundleID = target.bundleID
        // `Task.detached`, not `Task {}`. A task started here would inherit the main actor —
        // this class is `@MainActor` — and spend the whole 120 ms budget on the thread drawing
        // the HUD's waveform, during the one window the user is watching it.
        inFlight = Task.detached(priority: .userInitiated) { [weak self] in
            let context = AXHarvester.harvest(bundleID: bundleID, processID: processID)
            await MainActor.run {
                guard let self, self.captureToken == token else { return }
                self.captured = context
                if context.truncation.contains(.stubTree) {
                    self.stubRemediation = AXAppAdapters.adapter(for: context.bundleID)?.remediation
                }
                Self.log(context)
            }
        }
        return true
    }

    /// Waits for the in-flight harvest, at most `budget`.
    ///
    /// Timing out does **not** cancel the walk, and that asymmetry is the point: the ASR path
    /// calls this with 60 ms and takes the dictionary alone if the harvest is not ready,
    /// because a missing bias name is invisible while a delayed recording start eats the first
    /// word of the sentence. The cleanup path calls it with a second and always gets the full
    /// list, because by then the walk finished long ago.
    ///
    /// Polling the landed value rather than racing the task against a sleep, and for a
    /// concrete reason: `await task.value` on a non-throwing task ignores the cancellation of
    /// whoever is awaiting it, so the loser of that race would keep the caller waiting for the
    /// whole walk — exactly the stall the 60 ms budget exists to avoid. `TextInjector`'s
    /// `waitUntilFrontmost` polls for the same kind of reason.
    ///
    /// - Returns: `.empty` when nothing was started or the budget expired.
    func awaitCapture(within budget: Duration = .seconds(1)) async -> ScreenContext {
        if let captured { return captured }
        guard inFlight != nil else { return .empty }

        let step = Duration.milliseconds(10)
        var waited = Duration.zero
        while waited < budget {
            try? await Task.sleep(for: step)
            if let captured { return captured }
            waited += step
        }
        return .empty
    }

    /// Forgets the harvest, called once text has been injected — the same contract as
    /// `OutputProfileStore.clearCapturedTarget()`, and for the same reason: a stale list of
    /// file names must never reach a later dictation that harvested nothing.
    func clearCaptured() {
        // The token moves as well as the value. Clearing without it would let a walk that is
        // still running land its result into the cleared slot a moment later, which is the
        // stale list this method exists to prevent, arriving by the back door.
        captureToken &+= 1
        captured = nil
        inFlight = nil
    }

    /// Forgets the stub-tree hint, for the button on the banner that shows it.
    ///
    /// The user may have flipped the setting, or may simply not want to be told again; either
    /// way the next harvest of that app will set it back if the tree is still a stub.
    func dismissStubRemediation() {
        stubRemediation = nil
    }

    /// One line per harvest, carrying the elapsed time on purpose: the argument for doing this
    /// at key-down is that 120 ms is free, and the only way anyone notices that stopped being
    /// true is by being able to read what it actually took.
    private static func log(_ context: ScreenContext) {
        let reasons = context.truncation.reasons
        let suffix = reasons.isEmpty ? "" : " — \(reasons.joined(separator: ", "))"
        // `Log.inject` rather than a category of its own: this is the same accessibility
        // plumbing, read instead of written, and the two are read together when a dictation
        // lands in the wrong shape.
        Log.inject.info(
            """
            screen context: \(context.candidates.count, privacy: .public) names from \
            \(context.appName, privacy: .public) in \
            \(context.elapsed.milliseconds, privacy: .public)ms\(suffix, privacy: .public)
            """
        )
    }
}

extension Duration {
    /// Whole milliseconds, for a log line. `components` rather than arithmetic on
    /// `TimeInterval` because attoseconds are what this type is actually made of.
    ///
    /// Not private, because `--selftest-context` prints the same number for the same reason the
    /// log line does: the argument for harvesting at key-down is that 120 ms is free, and both
    /// places exist so somebody can check whether that is still true.
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
