import Foundation
import FoundationModels

/// How warm Apple's on-device model is, and what launch does about it (D-06).
///
/// Apple's model wakes per process: the first call in a fresh process measured **4.69 s**
/// here against 1.42–1.58 s for later fresh sessions and 0.94 s prewarmed (the
/// `CleanupSessionWarmer` table). Every launch made the next dictation a first call, and
/// the cleanup timeout floor sat below that first call, so a short first dictation was
/// guaranteed to time out. Launch and wake are the two moments the app knows a dictation
/// may come and has nothing else to spend the model on, so they are where it is woken —
/// never during a hold or a voice turn, which would compete for the same model.
///
/// Which warm-up actually removes the cold start is **measured, not assumed**:
/// `--selftest-cleanup-router --probe-cleanup-warmth <none|prewarm|respond>` times one
/// real cleanup in a fresh process after each mode, and `mode` is set from that result.
enum Warmth: String, Sendable { case staged, warmProcess, cold }

@MainActor
enum AppleModelWarmth {
    /// How long a completed Apple model answer is trusted to have left the process warm.
    /// An estimate; D-07 tunes it from D-01a rows (cleanup seconds against the minutes
    /// since the last Apple call).
    static var warmWindow: Duration = .seconds(600)

    /// The last completed Apple model activity: a cleanup answer, a layout plan, or a
    /// warm-up. Every successful `respond` on this model notes itself here.
    static private(set) var lastActivity: Date?

    static func noteActivity(_ date: Date = Date()) { lastActivity = date }

    /// `.warmProcess` within `warmWindow` of the last activity, `.cold` outside it and
    /// before any activity. `.staged` is reported by nothing yet; D-07 reads this.
    static func current(now: Date = Date()) -> Warmth {
        guard let last = lastActivity else { return .cold }
        let elapsed = now.timeIntervalSince(last)
        let window = Double(warmWindow.components.seconds)
            + Double(warmWindow.components.attoseconds) / 1e18
        return elapsed >= 0 && elapsed <= window ? .warmProcess : .cold
    }

    /// Which warm-up the probe chose. `.respond` is the assumption the decision table
    /// ships with until a probe run says otherwise.
    enum Mode: String { case prewarm, respond }
    static var mode: Mode = .respond

    /// Applies the probe's choice from a nonisolated caller.
    static func setMode(_ newMode: Mode) { mode = newMode }

    /// Handed over at launch so `warmProcess` can skip a hold that is already running.
    /// Weak: the controller belongs to the app delegate for the process lifetime.
    static weak var dictation: DictationController?

    /// The settings a warm session is built against: the user's current cleanup choices
    /// against a plain target and no screen context. A real hold stages its own session
    /// at key-down with its real target, so a warm staged session is never *taken* by
    /// one — what it buys is the process waking, which is the thing being measured.
    static var warmPreferences: CleanupPreferences {
        CleanupPreferences(
            tone: Settings.shared.cleanupTone,
            formatsLists: Settings.shared.cleanupFormatsLists,
            context: Settings.shared.cleanupContext
        )
    }

    static var warmFixesGrammar: Bool { Settings.shared.cleanupFixesGrammar }

    static var warmInstructions: String {
        CleanupInstructions.system(
            for: warmPreferences,
            fixesGrammar: warmFixesGrammar,
            target: .plain(bundleID: "", displayName: "the focused app"),
            context: .empty
        )
    }

    /// Wakes Apple's model when nothing is using it.
    ///
    /// Skips itself while a dictation hold is active or the agent's voice session is
    /// live — the same principle AGENT-OVERHAUL P0-06 gives warm-ups there: a warm-up
    /// must never compete with the work it is meant to speed up.
    static func warmProcess() async {
        guard FoundationModelFormatter.isAvailable else { return }
        if dictation?.state.isActive == true { return }
        if ActivationController.shared.mode != .idle { return }
        let instructions = warmInstructions
        switch mode {
        case .prewarm:
            await CleanupSessionWarmer.shared.stage(instructions: instructions)
            noteActivity()
        case .respond:
            do {
                let session = LanguageModelSession(instructions: instructions)
                _ = try await session.respond(
                    to: "Hello.",
                    options: GenerationOptions(
                        temperature: 0.1,
                        maximumResponseTokens: 1
                    )
                )
                noteActivity()
            } catch {
                Log.speech.info(
                    "launch warm-up: Apple's model did not answer (\(error.localizedDescription, privacy: .public))"
                )
            }
        }
    }

    /// A Settings change to a combination whose plan contains `.warmApple` warms once.
    /// Called from the two places the Settings tab writes the engine and grammar keys.
    static func warmForSettings(
        cleanupEnabled: Bool,
        choice: CleanupEngineChoice,
        fixesGrammar: Bool
    ) async {
        guard LaunchWarmup.plan(
            cleanupEnabled: cleanupEnabled,
            choice: choice,
            fixesGrammar: fixesGrammar,
            s1Downloaded: S1MiniModels.isDownloaded,
            appleAvailable: FoundationModelFormatter.isAvailable
        ).contains(.warmApple) else { return }
        await warmProcess()
    }
}

/// The single launch decision for the cleanup model (D-06).
///
/// S1-mini loads at launch only when it is the engine a real hold would reach: with
/// grammar repair on, `CleanupRouter.preferredEngine` sends every cleanup to Apple, and
/// loading 484 MB behind that routing is residency for nothing on a 16 GB Mac. Apple's
/// model warms at launch and after wake whenever it is the engine that will actually run.
enum LaunchWarmup {
    enum Action: Hashable { case loadS1Mini, warmApple }

    static func plan(
        cleanupEnabled: Bool,
        choice: CleanupEngineChoice,
        fixesGrammar: Bool,
        s1Downloaded: Bool,
        appleAvailable: Bool
    ) -> Set<Action> {
        // The decision table. Cleanup off does nothing — a switch that is off must not
        // warm anything. Grammar repair is Apple's work (S1-mini takes no instructions),
        // so `.s1Mini` with it on routes to Apple and S1-mini stays unloaded; loading on
        // demand later remains the first S1-mini call's own behaviour.
        guard cleanupEnabled else { return [] }
        var actions: Set<Action> = []
        switch choice {
        case .apple:
            if appleAvailable { actions.insert(.warmApple) }
        case .s1Mini:
            if fixesGrammar {
                if appleAvailable { actions.insert(.warmApple) }
            } else if s1Downloaded {
                actions.insert(.loadS1Mini)
            }
        }
        return actions
    }
}