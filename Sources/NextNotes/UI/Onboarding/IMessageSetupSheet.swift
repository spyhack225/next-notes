import SwiftUI

/// The Messages setup sheet: four steps, one pure state machine, no view state
/// that matters.
///
/// The decision lives in `IMessageConsentState` — this view renders it and feeds
/// it events. Step 2 reuses `MessagesAccessSection` so the glyph, the words and
/// the advice are the same object the Settings tab shows, not a second spelling.
/// Step 3 pairs through `IMessagePairNow` (the same code the flag runs) and step
/// 4's test message is a real send the button press approves, verified by
/// `IMessageActionVerifier` before the switch turns on.
///
/// Nothing here polls on a timer from the wall: access is re-read when the app
/// becomes active (the person just came back from System Settings) and every two
/// seconds while the sheet is open (on a second display they never "come back").
/// The two-second loop is Task-scoped, so dismissing the sheet ends it.
struct IMessageSetupSheet: View {
    /// Reports a refusal to the hosting section, which owns the under-switch line.
    var onDecline: (IMessageDeclineReason) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var consent: IMessageConsentState = .explaining
    @State private var accessVerdict: MessagesAccessVerdict = .notGranted
    @State private var isCheckingMessage = false
    @State private var checkHint: String?
    @State private var isSendingTest = false
    @State private var finished = false

    var body: some View {
        OnboardingScreen(
            symbol: "message.fill",
            headline: IMessageConsentCopy.sheetTitle,
            subhead: "",
            primaryTitle: primaryTitle,
            isPrimaryEnabled: isPrimaryEnabled,
            primary: primaryPressed
        ) {
            switch consent {
            case .explaining:
                explainingCard
            case .askingForFullDiskAccess:
                MessagesAccessSection()
            case .waitingForTheMessage:
                waitingCard
            case .confirming:
                confirmingCard
            case .connected:
                connectedCard
            case .declined:
                declinedCard
            case .off:
                // The sheet never shows `off`: declining dismisses, connecting
                // completes. Reaching it here is a state the sheet cannot be in.
                EmptyView()
            }
        }
        .padding()
        .task { await watchAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAccess() }
        }
        .onDisappear {
            // ✕, Escape or a swipe: abandoning a live step reports a dismissal
            // so the section owns the refusal line. Terminal states report
            // nothing — connecting or declining already spoke.
            guard !finished else { return }
            switch consent {
            case .explaining, .askingForFullDiskAccess, .waitingForTheMessage, .confirming:
                onDecline(.dismissed)
            case .connected, .declined, .off:
                break
            }
        }
    }

    // MARK: - Steps

    private var explainingCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(IMessageConsentCopy.step1Headline)
                    .font(DS.Font.headline)
                Text(IMessageConsentCopy.step1Body)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                OnboardingRowDivider()
                consentRow(IMessageConsentCopy.step1Conversation)
                OnboardingRowDivider()
                consentRow(IMessageConsentCopy.step1WhatIsUsed)
                OnboardingRowDivider()
                consentRow(IMessageConsentCopy.step1WhoAnswers)
            }
        }
    }

    private func consentRow(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.callout)
            .foregroundStyle(DS.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var waitingCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(IMessageConsentCopy.step3Headline)
                    .font(DS.Font.headline)
                Text(step3Body)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                HStack(spacing: DS.Space.xs) {
                    if isCheckingMessage {
                        ThinkingOrb(state: .listening, size: DS.Size.orbBadge)
                            .accessibilityHidden(true)
                    }
                    Text(IMessageConsentCopy.step3Waiting)
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                if let checkHint {
                    Text(checkHint)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                }
                HStack(spacing: DS.Space.s) {
                    Button("Check for my message") { checkMessage() }
                        .disabled(isCheckingMessage)
                    Button(IMessageConsentCopy.doLaterButton) { fire(.doLater) }
                        .buttonStyle(.link)
                        .font(DS.Font.caption)
                }
            }
        }
    }

    /// The trigger phrase, referenced — the pairing filter matches the constant.
    private var step3Body: String {
        "Open Messages on your phone, start a conversation with yourself, and send: \(SelfChannel.triggerPhrase)"
    }

    private var confirmingCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Your message arrived.")
                    .font(DS.Font.headline)
                Text("Send one test message back to make sure replies reach your phone.")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                HStack(spacing: DS.Space.xs) {
                    if isSendingTest {
                        ThinkingOrb(state: .composing, size: DS.Size.orbBadge)
                            .accessibilityHidden(true)
                    }
                    Button("Send test message") { sendTestMessage() }
                        .disabled(isSendingTest)
                }
            }
        }
    }

    private var connectedCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(IMessageConsentCopy.step4Headline)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Color.success)
                Text(IMessageConsentCopy.step4Body(agentName: AgentGroundingFacts.assistantName()))
                    .font(DS.Font.callout)
            }
        }
    }

    private var declinedCard: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(IMessageConsentCopy.refusal)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Primary button

    private var primaryTitle: String {
        switch consent {
        case .explaining: IMessageConsentCopy.continueButton
        case .connected, .declined: IMessageConsentCopy.doneButton
        default: IMessageConsentCopy.continueButton
        }
    }

    private var isPrimaryEnabled: Bool {
        switch consent {
        case .explaining, .connected, .declined: true
        default: false
        }
    }

    private func primaryPressed() {
        switch consent {
        case .explaining:
            fire(.continuePressed)
        case .connected, .declined:
            finished = true
            dismiss()
        default:
            break
        }
    }

    // MARK: - Events

    private func fire(_ event: IMessageConsentEvent) {
        if let next = IMessageConsentTransition.next(from: consent, event: event) {
            consent = next
            if case .declined(let reason) = next {
                onDecline(reason)
            }
        }
    }

    private func watchAccess() async {
        while !Task.isCancelled {
            await refreshAccess()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refreshAccess() async {
        let state = await MessagesDatabaseHealth.probeNow()
        accessVerdict = MessagesAccessVerdict.verdict(for: state)
        // ○ → ✓ needs no click: a readable verdict advances step 2 by itself.
        if accessVerdict.isGranted,
           case .askingForFullDiskAccess = consent {
            fire(.accessReadable)
        }
    }

    /// Step 3's check: pairs on the message the person just sent, using the same
    /// code the flag runs. Pairing proves the command arrived, so success moves
    /// to confirming; anything else stays waiting with a plain hint.
    private func checkMessage() {
        isCheckingMessage = true
        checkHint = nil
        Task { @MainActor in
            let lines = await IMessagePairNow.run()
            isCheckingMessage = false
            if lines.last?.hasPrefix("IMESSAGE_PAIR_NOW_OK") == true {
                fire(.commandArrived)
            } else {
                checkHint = "No message found yet — send \(SelfChannel.triggerPhrase) from your phone, then check again."
            }
        }
    }

    /// The test message: a real send this button press approves, verified before
    /// the switch turns on. Anything unverified returns to waiting.
    private func sendTestMessage() {
        isSendingTest = true
        Task { @MainActor in
            let store = RemoteIdentityStore(directory: AppIdentity.applicationSupportDirectory)
            let body = AgentMessageFormat.prefixed(
                "Paired — ask me anything from here.",
                name: AgentGroundingFacts.assistantName())
            var verified = false
            if let handle = store.configuration.chatHandleCache,
               let chatGUID = store.configuration.pairedChatGUID {
                let sender = MessagesSender(ledger: .shared, store: store)
                if case .sent = await sender.sendText(body, toHandle: handle) {
                    verified = await watchForConfirmation(chatGUID: chatGUID, digest: OutboundDigest.text(body))
                }
            }
            isSendingTest = false
            if verified {
                settings.imessageEnabled = true
                fire(.confirmationVerified)
            } else {
                fire(.confirmationTimedOut)
            }
        }
    }

    private func watchForConfirmation(chatGUID: String, digest: Data) async -> Bool {
        guard let database = try? MessagesDatabase() else { return false }
        defer { Task { await database.close() } }
        guard let latest = try? await database.latestRowID() else { return false }
        for _ in 0..<30 {
            if let rows = try? await database.messages(after: latest, chatGUID: chatGUID),
               rows.contains(where: { $0.isFromMe && $0.text.map(OutboundDigest.text) == digest }) {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
}
