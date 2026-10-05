import SwiftUI

/// "Your catch-ups": the short updates the Agent prepared, newest first, at the top of the
/// Reminders pane — the place the person's set-up lives, so the thing and its switch sit
/// together.
///
/// Each row says when it was made in the person's words, how long it is, plays on a press and
/// never before, and shows the two to four things it is about. The newest one also carries its
/// closing question as a real button, because that is the next step the Agent suggests.
struct CatchUpPaneSection: View {
    @State private var library = CatchUpLibrary.shared
    @State private var store = ScheduleStore.shared
    @State private var showEarlier = false

    private let visibleCount = 3

    var body: some View {
        AgentPaneSection(title: "Your catch-ups", count: library.entries.isEmpty ? nil : library.entries.count) {
            if library.entries.isEmpty {
                emptyRow
            } else {
                let entries = showEarlier ? library.entries : Array(library.entries.prefix(visibleCount))
                AgentCardGrid(minimum: DS.Size.agentCardMinWidth) {
                    ForEach(entries) { entry in
                        CatchUpCard(entry: entry)
                    }
                }
                if library.entries.count > visibleCount {
                    Button(showEarlier ? "Show fewer" : "Show earlier ones") {
                        withAnimation(DS.Motion.standard) { showEarlier.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(DS.Font.caption)
                }
            }
        }
    }

    /// Nothing made yet. If one is switched on, say when the first will come; if not, say
    /// what it is and where to turn it on.
    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(emptyMessage)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if nextOne == nil {
                Button("Set up catch-ups") {
                    NavigationState.shared.selectedSettingsTab = .agent
                    NavigationState.shared.show(.settings)
                }
                .buttonStyle(.link)
                .font(DS.Font.caption)
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private var nextOne: Date? {
        store.schedules.filter { $0.isCatchUp && $0.enabled }.compactMap(\.nextRunAt).min()
    }

    private var emptyMessage: String {
        if let nextOne {
            return "Your first one will be ready "
                + CatchUpText.whenPhrase(nextOne, now: Date()).lowercasedFirst + "."
        }
        return "A catch-up is a short update on your day — what needs you, what happened and "
            + "what\u{2019}s coming — ready to read or listen to."
    }
}

private extension String {
    /// "This morning, 6:00 AM" reads after "ready" as "this morning, 6:00 AM"; a weekday or a
    /// month keeps its capital because it is a proper word.
    var lowercasedFirst: String {
        guard hasPrefix("This ") || hasPrefix("Yesterday") else { return self }
        return prefix(1).lowercased() + dropFirst()
    }
}

/// One catch-up.
struct CatchUpCard: View {
    let entry: CatchUpEntry

    @State private var library = CatchUpLibrary.shared
    @State private var player = CatchUpPlayer.shared
    @State private var reading = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            if player.isCurrent(entry) { progress }
            if !entry.headlines.isEmpty { headlines }
            if let offer = library.openOffer(for: entry) { offerRow(offer) }
            if let problem = player.problem, player.playingID == nil, entry.audioURL != nil {
                Text(problem)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
            readButton
            if reading {
                Text(entry.text)
                    .font(DS.Font.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.glass)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            leadingMark
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(entry.title)
                    .font(DS.Font.briefingTitle)
                    .tracking(DS.Font.wordTracking)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Play when there is audio; the orb that means "the model is writing" while the audio is
    /// still being made, because that is the one piece of work on this screen that is running;
    /// nothing when the catch-up is words only.
    @ViewBuilder
    private var leadingMark: some View {
        if entry.audioURL != nil {
            Button {
                player.toggle(entry)
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: DS.Size.iconLarge, height: DS.Size.iconLarge)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel(playing ? "Pause" : "Play")
            .help(playing ? "Pause" : "Play")
        } else if entry.isPreparingAudio(now: Date()) {
            ThinkingOrb(state: .composing, size: DS.Size.orbSmall)
                .accessibilityHidden(true)
        }
    }

    private var playing: Bool { player.isCurrent(entry) && player.isPlaying }

    private var subtitle: String {
        var parts = [CatchUpText.whenPhrase(entry.madeAt, now: Date())]
        if let duration = entry.duration, entry.audioURL != nil {
            parts.append(CatchUpText.lengthPhrase(duration))
        } else if entry.isPreparingAudio(now: Date()) {
            parts.append("Getting the audio ready\u{2026}")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var progress: some View {
        HStack(spacing: DS.Space.s) {
            ProgressView(value: player.progress)
                .progressViewStyle(.linear)
            Text("\(CatchUpText.clock(player.elapsed)) / \(CatchUpText.clock(player.duration))")
                .font(DS.Font.timestamp)
                .monospacedDigit()
                .foregroundStyle(DS.Color.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Played \(CatchUpText.clock(player.elapsed)) of \(CatchUpText.clock(player.duration))")
    }

    private var headlines: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(Array(entry.headlines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text("\u{2022}").foregroundStyle(DS.Color.textTertiary)
                    Text(line)
                        .font(DS.Font.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The Agent's closing question as one action and a way out. Yes starts an ordinary turn,
    /// where anything that writes or sends still waits for its own approval card.
    private func offerRow(_ offer: CatchUpOffer) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Divider()
            Text(offer.question)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                Button(offer.actionLabel) { library.acceptOffer(entry) }
                    .buttonStyle(.borderedProminent)
                Button("Not now") { library.closeOffer(entry) }
            }
            .controlSize(.small)
        }
    }

    private var readButton: some View {
        Button {
            withAnimation(DS.Motion.standard) { reading.toggle() }
        } label: {
            Text(reading ? "Hide the words" : "Read it")
        }
        .buttonStyle(.link)
        .font(DS.Font.caption)
    }
}
