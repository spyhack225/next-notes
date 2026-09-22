import Foundation

/// What setup actually achieved.
///
/// The last screen used to congratulate everybody: same headline, same three tips, whether
/// the user had granted both switches or walked past them both. "Hold Fn and talk — in any
/// app, let go, and your words are there" is a promise the app cannot keep on a Mac that was
/// never allowed to hear or to type, and the first thing that happens after a confident
/// "You're all set" is that the key does nothing.
///
/// Passing through a required screen stays allowed — that is the flow's rule, and a Continue
/// that refuses to move is a worse trap than a hopeful sentence. So the correction is here:
/// the ending reads back what is true and says which switch is still off, instead of
/// disabling a button.
///
/// A value with no views in it, so "does the ending ever claim something that did not
/// happen?" is a question `--selftest-onboarding` can answer without a screen.
struct OnboardingOutcome: Equatable, Sendable {
    /// macOS lets Next Notes hear.
    var hasMicrophone = false
    /// macOS lets Next Notes type into other apps.
    var hasAccessibility = false
    /// The switch reads as on and the key still did not arm — the stale-signature trap the
    /// dictation screen catches. Granted-but-not-armed is not dictation, so it must not
    /// count as it here either.
    var isTypingBlocked = false
    /// The meetings screen was passed over rather than answered.
    var skippedMeetings = false
    /// The files screen was passed over rather than answered.
    var skippedFiles = false
    /// The calendar was actually allowed.
    var hasCalendar = false
    /// At least one folder is being looked through.
    var indexesFiles = false
    /// What the user called their assistant.
    var assistantName = "your assistant"
    /// The key they chose, in the words the rest of the app uses for it.
    var holdKeyName = "Fn"
    /// The hands-free shortcut, or nil when they chose not to have one.
    var handsFreeName: String?

    /// The one thing setup exists to deliver. Everything else on this screen is optional by
    /// design; this is not, and it is the only claim worth checking before making it.
    var canDictate: Bool { hasMicrophone && hasAccessibility && !isTypingBlocked }

    var headline: String {
        canDictate ? "You're all set" : "Nearly there"
    }

    var subhead: String {
        if canDictate { return "Three things worth trying first." }
        if isTypingBlocked {
            return "macOS says Next Notes is allowed to type for you, but it still isn't working."
        }
        return "One switch in macOS is still off, so talking to your Mac won't work yet."
    }

    /// The rows in the card, in the order they are read. Never more than three, and the
    /// first one is whatever the user should do next.
    var tips: [OnboardingTip] {
        var rows: [OnboardingTip] = []

        if canDictate {
            rows.append(OnboardingTip(
                title: "Hold \(holdKeyName) and talk",
                detail: "In any app. Let go, and your words are there.",
                symbol: "mic"
            ))
            rows.append(OnboardingTip(
                title: "Highlight some text and say what to change",
                detail: "\u{201c}Make this shorter.\u{201d}",
                symbol: "text.cursor"
            ))
        } else {
            rows.append(OnboardingTip(
                title: outstandingTitle,
                detail: outstandingDetail,
                symbol: "exclamationmark.circle",
                isOutstanding: true
            ))
        }

        rows.append(closingTip)
        return rows
    }

    private var outstandingTitle: String {
        if isTypingBlocked { return "Dictation still isn't working" }
        switch (hasMicrophone, hasAccessibility) {
        case (false, false): return "Dictation isn't switched on yet"
        case (false, true): return "Next Notes can't hear you yet"
        case (true, false): return "Next Notes can't type for you yet"
        case (true, true): return "Dictation isn't switched on yet"
        }
    }

    private var outstandingDetail: String {
        if isTypingBlocked { return Permissions.accessibilityRepairAdvice }
        let what: String
        switch (hasMicrophone, hasAccessibility) {
        case (false, false): what = "the microphone, and permission to type for you"
        case (false, true): what = "the microphone"
        case (true, false): what = "permission to type for you"
        case (true, true): what = "the microphone, and permission to type for you"
        }
        return "Go back a step and allow \(what) — or do it any time in Settings, "
            + "under Permissions."
    }

    /// The third row. It only ever names something the user actually set up: a folder screen
    /// they skipped must not come back as "ask it to find a file", and a calendar they never
    /// allowed must not come back as "it'll take the notes".
    private var closingTip: OnboardingTip {
        if indexesFiles, !skippedFiles {
            return OnboardingTip(
                title: "Ask \(assistantName) to find something",
                detail: "\u{201c}Where's the invoice from March?\u{201d}",
                symbol: "folder"
            )
        }
        if hasCalendar, !skippedMeetings {
            return OnboardingTip(
                title: "Let \(assistantName) sit in on your next meeting",
                detail: "It starts when the meeting does, and writes the notes afterwards.",
                symbol: "calendar"
            )
        }
        return OnboardingTip(
            title: "Ask \(assistantName) for something",
            detail: handsFreeName.map { "Press \($0) and just say it." }
                ?? "Pick a hands-free key in Settings whenever you want one.",
            symbol: "bubble.left.and.bubble.right"
        )
    }
}

extension OnboardingOutcome {
    /// The one the last screen actually shows.
    ///
    /// Here rather than inside the view so that the step from "what the user did" to "what
    /// the screen claims" is code a test can run. The grants are passed in rather than read
    /// here because the screen polls them — and because `hasAccessibility` alone is not
    /// enough to know whether the key armed.
    @MainActor
    static func live(
        assistantName: String,
        hasMicrophone: Bool,
        hasAccessibility: Bool,
        isTypingBlocked: Bool,
        hasCalendar: Bool,
        model: OnboardingModel,
        settings: Settings = .shared,
        folders: IndexedFoldersStore = .shared
    ) -> OnboardingOutcome {
        OnboardingOutcome(
            hasMicrophone: hasMicrophone,
            hasAccessibility: hasAccessibility,
            isTypingBlocked: isTypingBlocked,
            skippedMeetings: model.wasSkipped(.meetings),
            skippedFiles: model.wasSkipped(.files),
            hasCalendar: hasCalendar,
            indexesFiles: folders.isEnabled && !folders.folders.isEmpty,
            assistantName: assistantName,
            holdKeyName: settings.pushToTalkKey.spokenName,
            handsFreeName: settings.agentShortcutEnabled ? settings.agentShortcut.displayName : nil
        )
    }
}

/// One row on the last screen: what to try, or what is still missing.
struct OnboardingTip: Equatable, Sendable, Identifiable {
    var title: String
    var detail: String
    var symbol: String
    /// Something the user still has to do, rather than something they can now do. Drawn in
    /// the warning tint rather than the accent one.
    var isOutstanding = false

    var id: String { title }
}
