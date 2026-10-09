import SwiftUI

/// The one quiet line that says an answer is text-only because the voice is not ready.
///
/// The words come from `AgentVoiceAvailability.message`, the same sentence the speech owner
/// publishes, so the conversation, the notch card and Settings can never disagree. The line
/// follows the live state: the moment the voice is ready it disappears, and it is shown once
/// rather than under every answer.
///
/// - `pane`: under the newest answer that went out as text only, with a way to Voice settings.
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
                if now == .ready { VoiceTextOnlyNoteLedger.reset() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let line = voice.availability.message {
            switch style {
            case .pane(let messageID):
                if isNewestTextOnlyAnswer(messageID) { paneLine(line) }
            case .island(let ink):
                Text(line)
                    .font(DS.Font.caption)
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .opacity(islandShows ? 1 : 0)
                    .frame(maxHeight: islandShows ? nil : 0)
                    .accessibilityHidden(!islandShows)
                    .onAppear { islandShows = VoiceTextOnlyNoteLedger.claimIsland(line) }
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

/// The pane's version of the line: the sentence and a plain way to Voice settings.
struct VoiceTextOnlyPaneLine: View {
    let text: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "text.bubble")
                .accessibilityHidden(true)
            Text(text)
            Button("Voice settings") {
                NavigationState.shared.selectedSettingsTab = .models
                openSettings()
            }
            .buttonStyle(.link)
            .accessibilityHint("Opens the voice settings")
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.textSecondary)
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

    /// Called when the voice is ready, so the next trouble is told again.
    static func reset() { lastIslandLine = nil }
}
