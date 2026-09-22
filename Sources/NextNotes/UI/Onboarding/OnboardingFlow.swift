import Foundation
import Observation

/// The screens of first run, in the order they are shown.
///
/// One question per screen. The order is the contract: it is what `--selftest-onboarding`
/// asserts, and what a resumed run comes back to.
enum OnboardingStep: String, CaseIterable, Sendable, Identifiable, Codable {
    /// What Next Notes does, and what the assistant is called.
    case welcome
    /// Microphone and Accessibility — the two grants without which nothing works.
    case dictation
    /// Which key to hold, which key toggles hands-free, and a place to try it.
    case shortcut
    /// Calendar and the other side of a call.
    case meetings
    /// Which folders the assistant may look through.
    case files
    /// Fetching the model that writes and thinks, on this Mac.
    case brain
    /// Three things to try, and the door out.
    case allSet

    var id: String { rawValue }

    /// Whether this screen carries a quiet "Skip" beside "Continue".
    ///
    /// Only meetings and files. Everything else is either free (welcome, all set) or is the
    /// thing the app *is* (dictation, the key, the assistant), and a screen you can dismiss
    /// without reading is a screen that teaches nothing. Passing through a required screen
    /// is always allowed — it is *skipping* it, jumping the queue without seeing it, that
    /// is not.
    var isOptional: Bool {
        switch self {
        case .meetings, .files: true
        case .welcome, .dictation, .shortcut, .brain, .allSet: false
        }
    }
}

/// Where a first run has got to. A value, with no storage, no views and no side effects, so
/// the whole of "can this be bypassed?" is answerable from a test.
struct OnboardingFlow: Equatable, Sendable {
    /// Every screen, in order. `OnboardingStep.allCases` is declaration order, and the
    /// declaration order *is* the running order — the self-test pins it so a case added in
    /// the middle cannot silently reorder a shipped flow.
    static let order: [OnboardingStep] = OnboardingStep.allCases

    private(set) var current: OnboardingStep = .welcome
    /// Screens the user chose to pass over. Kept rather than discarded so going back and
    /// forward does not quietly un-skip something, and so "Run setup again" can start clean.
    private(set) var skipped: Set<OnboardingStep> = []
    private(set) var isComplete = false

    init() {}

    /// Rebuilds a flow saved by a previous launch. Invalid input lands on the first screen
    /// rather than throwing: a corrupt preference must not be able to lock a user out of
    /// their own setup.
    init(resumingAt step: OnboardingStep?, skipped: Set<OnboardingStep> = [], isComplete: Bool = false) {
        current = step ?? .welcome
        self.skipped = skipped
        self.isComplete = isComplete
    }

    var index: Int { Self.order.firstIndex(of: current) ?? 0 }
    var total: Int { Self.order.count }

    /// Whether the user has got as far as `step`.
    ///
    /// Reaching a screen is what turns what it says into a promise: the assistant screen
    /// tells somebody their download will be picked up again, and `OnboardingModelResume`
    /// only picks it up for a Mac that was actually shown that sentence. A Mac that finished
    /// setup before this flow existed has been told nothing, and must not wake up to a
    /// multi-gigabyte transfer nobody offered it.
    func hasReached(_ step: OnboardingStep) -> Bool {
        guard let target = Self.order.firstIndex(of: step) else { return false }
        return index >= target
    }
    var isLast: Bool { index == total - 1 }
    var canGoBack: Bool { index > 0 }

    /// "Continue". Moves to the next screen, or finishes on the last one.
    ///
    /// Continuing off a screen clears any skip mark it carried: the user has now been
    /// through it deliberately.
    @discardableResult
    mutating func advance() -> Bool {
        skipped.remove(current)
        guard !isLast else {
            finish()
            return false
        }
        current = Self.order[index + 1]
        return true
    }

    /// "Skip". Refused on a required screen, and refusing is the point — this is the one
    /// line that decides whether setup can be jumped.
    @discardableResult
    mutating func skip() -> Bool {
        guard current.isOptional else { return false }
        // Unreachable while no optional step is last, but written so that making one last
        // later cannot turn "Skip" into a silent no-op.
        guard !isLast else {
            skipped.insert(current)
            finish()
            return true
        }
        let next = Self.order[index + 1]
        skipped.insert(current)
        current = next
        return true
    }

    /// The back chevron. Never clears anything: going back to look at a screen is not a
    /// decision about it.
    @discardableResult
    mutating func back() -> Bool {
        guard canGoBack else { return false }
        current = Self.order[index - 1]
        return true
    }

    mutating func finish() {
        isComplete = true
    }
}

/// The running first-run flow: the value above, plus somewhere to keep it.
///
/// Feature-local storage rather than a property on `Settings`, in the house style — except
/// for the one bit the rest of the app already reads. `Settings.hasCompletedOnboarding` has
/// always been that bit and stays it: this writes the *same* `UserDefaults` key, and tells
/// the live `Settings` object to re-read its cache through `onCompletionChanged`. One flag,
/// one key, no second source of truth to drift.
@MainActor
@Observable
final class OnboardingModel {
    static let shared: OnboardingModel = {
        let model = OnboardingModel()
        model.onCompletionChanged = { completed in
            Settings.shared.hasCompletedOnboarding = completed
        }
        return model
    }()

    private(set) var flow: OnboardingFlow

    /// Told when the completion bit changes, so `Settings.shared`'s in-memory copy follows
    /// the one on disk. Injected rather than called directly so the self-test can run the
    /// whole machine without touching the user's real preferences.
    @ObservationIgnored var onCompletionChanged: ((Bool) -> Void)?

    private let defaults: UserDefaults

    enum Key {
        static let step = "onboardingStep"
        static let skipped = "onboardingSkippedSteps"
        /// Deliberately the key `Settings` already uses.
        static let completed = "hasCompletedOnboarding"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let step = defaults.string(forKey: Key.step).flatMap(OnboardingStep.init(rawValue:))
        let marks = (defaults.array(forKey: Key.skipped) as? [String] ?? [])
            .compactMap(OnboardingStep.init(rawValue:))
        flow = OnboardingFlow(
            resumingAt: step,
            skipped: Set(marks),
            isComplete: defaults.bool(forKey: Key.completed)
        )
    }

    var step: OnboardingStep { flow.current }
    var isComplete: Bool { flow.isComplete }
    var canGoBack: Bool { flow.canGoBack }
    var canSkip: Bool { flow.current.isOptional }
    var isLast: Bool { flow.isLast }

    @discardableResult
    func advance() -> Bool {
        let moved = flow.advance()
        persist()
        return moved
    }

    @discardableResult
    func skip() -> Bool {
        let moved = flow.skip()
        persist()
        return moved
    }

    @discardableResult
    func back() -> Bool {
        let moved = flow.back()
        persist()
        return moved
    }

    func finish() {
        flow.finish()
        persist()
    }

    /// "Run setup again". Clears the completion bit and every skip mark, so the second run
    /// is a first run rather than a replay of one.
    func restart() {
        flow = OnboardingFlow()
        persist()
    }

    /// Whether a given screen was passed over rather than answered — the tick the "All set"
    /// screen reads so it never claims a user set up something they declined.
    func wasSkipped(_ step: OnboardingStep) -> Bool { flow.skipped.contains(step) }

    /// Whether the user has been shown the screen that says their assistant is being set up.
    /// Read by `OnboardingModelResume` before it starts a download nobody is watching.
    var hasPromisedTheAssistant: Bool { flow.hasReached(.brain) }

    private func persist() {
        defaults.set(flow.current.rawValue, forKey: Key.step)
        defaults.set(flow.skipped.map(\.rawValue).sorted(), forKey: Key.skipped)
        let wasCompleted = defaults.bool(forKey: Key.completed)
        defaults.set(flow.isComplete, forKey: Key.completed)
        if wasCompleted != flow.isComplete { onCompletionChanged?(flow.isComplete) }
    }
}

/// When first run is put on screen. Pure, so the "never during a self-test" rule is a thing
/// a test can check rather than a thing a comment claims.
enum OnboardingPolicy {
    /// - Parameters:
    ///   - hasCompleted: the persisted completion bit.
    ///   - isSelfTest: whether the process was launched with a `--selftest-…` flag. A window
    ///     on screen keeps `NSApp.terminate` from ever completing, so a self-test that
    ///     raised this one would hang instead of reporting.
    static func shouldPresent(hasCompleted: Bool, isSelfTest: Bool) -> Bool {
        !hasCompleted && !isSelfTest
    }
}
