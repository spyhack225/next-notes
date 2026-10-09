import SwiftUI

/// The one quiet line that says an answer is text-only because the voice is not ready.
///
/// The words come from `AgentVoiceAvailability.message`, the same sentence the speech owner
/// publishes, so the conversation, the notch card and Settings can never disagree. The line
/// follows the live state: the moment the voice is ready it disappears, and it is shown once
/// rather than under every answer.
///
/// - `pane`: under the newest answer that went out as text only, with a way to Open voice settings.
/// - `island`: inside the notch reply card, once per state, in the card's own ink.
///
/// Nothing here animates, so it adds nothing to the one orb a screen is allowed.
struct VoiceTextOnlyNote: View {
    enum Style {
        case pane(messageID: UUID)
        case island(ink: Color)
    }

    let style: Style

    @State private var voice = AgentSpeechSynthesizer.shared
    @State private var session = AgentSession.shared
    @State private var islandShows = false

    var body: some View {
        content
            .onChange(of: voice.availability, initial: true) { _, now in
                VoiceTextOnlyNoteLedger.observe(now)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let line = voice.availability.message {
            switch style {
            case .pane(let messageID):
                if isNewestTextOnlyAnswer(messageID) { paneLine(line) }
            case .island(let ink):
                VoiceTextOnlyIslandLine(availability: voice.availability, ink: ink)
                    .opacity(islandShows ? 1 : 0)
                    .frame(maxHeight: islandShows ? nil : 0)
                    .accessibilityHidden(!islandShows)
                    .onChange(of: line, initial: true) { _, now in
                        islandShows = VoiceTextOnlyNoteLedger.claimIsland(now)
                    }
            }
        }
    }

    private func isNewestTextOnlyAnswer(_ id: UUID) -> Bool {
        session.messages.last { $0.speechDelivery?.availabilityMessage != nil }?.id == id
    }

    private func paneLine(_ line: String) -> some View {
        VoiceTextOnlyPaneLine(text: line)
    }
}

/// The pane's version of the line: the sentence and a plain way to Open voice settings.
struct VoiceTextOnlyPaneLine: View {
    let text: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Label(sentence, systemImage: "text.bubble")
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle) {
                NavigationState.shared.selectedSettingsTab = .models
                openSettings()
            }
            .buttonStyle(.link)
            .foregroundStyle(DS.Color.accent)
            .accessibilityHint("Opens the voice settings")
        }
        .font(DS.Font.callout)
        .foregroundStyle(DS.Color.textSecondary)
    }

    // Render the destination as a real button, once, rather than duplicate its name.
    private var sentence: String {
        let destination = text.hasSuffix("Try again in voice settings.")
            ? " Try again in voice settings." : " Open voice settings."
        return text.hasSuffix(destination) ? String(text.dropLast(destination.count)) : text
    }

    private var buttonTitle: String {
        text.hasSuffix("Try again in voice settings.") ? "Try again in voice settings" : "Open voice settings"
    }
}

/// The real notch line and its offscreen preview share the same compact, wrapping layout.
struct VoiceTextOnlyIslandLine: View {
    let availability: AgentVoiceAvailability
    let ink: Color
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(sentence)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open voice settings") {
                NavigationState.shared.selectedSettingsTab = .models
                openSettings()
            }
            .buttonStyle(.link)
            .foregroundStyle(DS.Color.accent)
        }
        .font(DS.Font.caption)
        .foregroundStyle(ink)
    }

    private var sentence: String {
        switch availability {
        case .ready: ""
        case .preparing: "Voice is getting ready. Answer is here."
        case .failed: "Voice couldn't start. Answer is here."
        case .needsDownload: "Your voice isn't on this Mac yet. Answer is here."
        }
    }
}

/// Remembers which sentence the notch card already showed, so a second reply in the same
/// situation stays quiet. It forgets when the voice is ready again, and a new situation
/// (a different sentence) is shown once more.
@MainActor
enum VoiceTextOnlyNoteLedger {
    private(set) static var lastIslandLine: String?

    static func claimIsland(_ line: String) -> Bool {
        if lastIslandLine == line { return false }
        lastIslandLine = line
        return true
    }

    static func observe(_ availability: AgentVoiceAvailability) {
        if availability == .ready { reset() }
    }

    /// Called when the voice is ready, so the next trouble is told again.
    static func reset() { lastIslandLine = nil }
}
