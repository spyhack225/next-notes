import Foundation

/// IM-17a — the consent decision, as a pure value.
///
/// One pure value, and the view holds no state of its own: the sheet renders
/// this, the switch renders this, and the self-test holds this. A `@State`
/// inside a view renders the right glyph and cannot be held by a self-test —
/// the same reason `OnboardingDictationStep` keeps `microphoneState` outside
/// the view.
///
/// Every sentence here is `IMessageConsentCopy.§1.2`, verbatim from the design:
/// the sheet, the pane and the test cannot drift because there is only one
/// place the words exist. The trigger phrase is referenced, never spelled —
/// `SelfChannel.triggerPhrase` is the constant the pairing filter matches, and
/// a literal here would be a second copy to drift (and a literal agent name,
/// which the persona rules fail).
enum IMessageConsentState: Equatable, Sendable {
    case off
    case explaining
    case askingForFullDiskAccess(hasOpenedPane: Bool)
    case waitingForTheMessage
    case confirming
    case connected
    case declined(reason: IMessageDeclineReason)
}

/// Why consent is off after a refusal. A reason, not a timestamp: a refusal is
/// a count in one usage row (IM-17d) and nothing else — no `declinedAt` in any
/// store.
enum IMessageDeclineReason: String, Sendable {
    /// "Not now" on step 2.
    case notNow
    /// "I'll do this later" on step 3.
    case later
    /// ✕, Escape, or the window closed.
    case dismissed
}

/// What can happen to the graph.
enum IMessageConsentEvent: Equatable, Sendable {
    case switchOn
    case continuePressed
    case openedSettingsPane
    /// The access verdict turned readable: step 2 completes with no click.
    case accessReadable
    /// The verdict was already granted on entry: the returning person's skip.
    case accessGranted
    case notNow
    /// A command arrived in the self-conversation.
    case commandArrived
    /// The confirmation send verified (IM-10).
    case confirmationVerified
    /// The confirmation watch timed out: back to waiting, the wait continues.
    case confirmationTimedOut
    case doLater
    case dismissed
    /// The switch off, or Stop. Immediate.
    case switchOff
}

/// The transition, as a pure function of state, event and origin.
///
/// `nil` is the refusal: unlisted events default to nothing, and **no transition
/// in this graph can be driven from the phone** — any origin that is remote
/// refuses every event. That is IM-12's "a remote turn must not widen its own
/// authority" applied to consent itself: turning the feature on or off,
/// re-pairing and un-suspending are local acts or they do not happen.
///
/// `connected → off` is immediate — no confirmation, no drain. Turning off is
/// the safe direction and the person already decided; turning back on walks the
/// sheet again, which is what "re-enabling needs local confirmation" means.
enum IMessageConsentTransition {
    static func next(from state: IMessageConsentState,
                     event: IMessageConsentEvent,
                     origin: ActionOriginContext? = nil) -> IMessageConsentState? {
        if origin?.isRemote == true { return nil }
        switch (state, event) {
        case (.off, .switchOn):
            return .explaining
        case (.declined, .switchOn):
            // Any time later, from the beginning, same copy, no variant.
            return .explaining
        case (.explaining, .continuePressed):
            return .askingForFullDiskAccess(hasOpenedPane: false)
        case (.askingForFullDiskAccess, .openedSettingsPane):
            return .askingForFullDiskAccess(hasOpenedPane: true)
        case (.askingForFullDiskAccess, .accessReadable),
             (.askingForFullDiskAccess, .accessGranted):
            return .waitingForTheMessage
        case (.askingForFullDiskAccess, .notNow):
            return .declined(reason: .notNow)
        case (.waitingForTheMessage, .commandArrived):
            return .confirming
        case (.confirming, .confirmationVerified):
            return .connected
        case (.confirming, .confirmationTimedOut):
            return .waitingForTheMessage
        case (.waitingForTheMessage, .doLater):
            return .declined(reason: .later)
        case (.connected, .switchOff):
            return .off
        case (_, .dismissed):
            return .declined(reason: .dismissed)
        case (_, .switchOff):
            // The safe direction from anywhere the sheet can be open.
            return .off
        default:
            return nil
        }
    }
}

/// Every sentence the consent flow shows, in one place. §1.2 and §1.4 verbatim.
enum IMessageConsentCopy {
    static let switchTitle = "Ask me from Messages"
    static let switchDetail =
        "Message yourself from your phone and your assistant answers you there. It needs one thing from macOS first."
    static let sheetTitle = "Set up Messages"
    static let step1Headline = "One conversation, and only the words you sent"
    static let step1Body =
        "Next Notes reads the conversation you have with yourself. It uses the words you sent it, and nothing else."
    static let step1Conversation = "The one where both sides are you. No other conversation is read."
    static let step1WhatIsUsed =
        "Just the words you sent. Anything that arrived with a message — a picture, a link, an offer from someone else — is left alone."
    static let step1WhoAnswers = "The same assistant you already talk to by voice."
    static let continueButton = "Continue"
    static let step2Headline = "One switch in macOS"
    static let step2Body =
        "macOS will only open your messages for an app you have chosen, and this is where you choose Next Notes."
    static let openSettingsButton = "Open Full Disk Access settings…"
    static let notNowButton = "Not now"
    static let step3Headline = "Say hello from your phone"
    /// The trigger phrase, referenced — spelling it here would be a second copy
    /// beside `SelfChannel.triggerPhrase`, and the pairing filter matches the
    /// constant, not this sentence.
    static var step3Body: String {
        "Open Messages on your phone, start a conversation with yourself, and send: \(SelfChannel.triggerPhrase)"
    }
    static let step3Waiting = "Waiting for your message…"
    static let sendTestButton = "Send test message"
    static let doLaterButton = "I'll do this later"
    static let step4Headline = "✓ Connected"
    /// The runtime name, interpolated — never spelled out. `--selftest-persona`
    /// fails a literal agent name, and this suite holds the same line.
    static func step4Body(agentName: String) -> String {
        "\(agentName) is ready. Ask me anything from here."
    }
    static let doneButton = "Done"
    static let stopButton = "Stop"
    static let refusal =
        "That's fine. Dictation, meetings and your assistant all keep working — only talking to me from your phone is off."
}
