import SwiftUI

/// "Speaking back": which voice the agent talks with, whether it is ready, and a sample.
///
/// The app speaks with Pocket or Kokoro only, so there is no third tile and no system-voice
/// picker. Whether the chosen voice can speak right now is not decided here: it is read from
/// `AgentSpeechSynthesizer.availability`, the same answer the conversation uses to decide
/// between speaking and showing text. This view only describes that answer in plain words and
/// offers the one move that fits it (download, try again, or hear a sample).
///
/// The sample itself stays in the Models tab, next to the scheduler call it already makes;
/// this view is handed a pair of closures and never speaks on its own.
struct VoiceSettingsSection<Details: View>: View {
    @State private var settings = Settings.shared
    @State private var voice = AgentSpeechSynthesizer.shared
    @State private var pocket = PocketAgentVoice.shared
    @State private var kokoro = KokoroAgentVoice.shared

    /// The chosen voice's state, read by the caller from `AgentSpeechSynthesizer` so this
    /// view draws a value rather than owning the answer.
    let availability: AgentVoiceAvailability
    var kokoroSupported = KokoroAgentVoice.isSupportedOS
    let isPreviewing: Bool
    let togglePreview: () -> Void
    let stopPreview: () -> Void
    /// The model's name, licence and card, folded away. Handed in by the Models tab, which
    /// owns that disclosure for every model; a preview passes nothing.
    let details: Details

    /// The two voices the app can speak with. Order is the order on screen.
    enum Engine: String, CaseIterable, Identifiable {
        case pocket, kokoro
        var id: String { rawValue }
        var name: String { self == .pocket ? "Pocket" : "Kokoro" }
        var icon: String { self == .pocket ? "waveform" : "waveform.path" }
    }

    // MARK: Body

    var body: some View {
        Section {
            HStack(spacing: DS.Space.s) {
                ForEach(Engine.allCases) { engine in
                    engineChoice(engine)
                }
            }

            statusBlock

            if selected == .pocket {
                pocketVoices
            } else {
                LabeledContent("Voice", value: KokoroAgentVoice.voiceName)
            }

            sampleRow

            details
        } header: {
            Text("Speaking back")
        } footer: {
            SettingsNote(text: footerText)
        }
    }

    // MARK: Which voice

    private var selected: Engine { settings.agentVoiceEngine == "kokoro" ? .kokoro : .pocket }

    private func isReady(_ engine: Engine) -> Bool {
        engine == .pocket ? pocket.isReady : kokoro.isReady
    }

    private func isPreparing(_ engine: Engine) -> Bool {
        engine == .pocket ? pocket.isPreparing : kokoro.isPreparing
    }

    private func isAvailableOnThisMac(_ engine: Engine) -> Bool {
        engine == .kokoro ? kokoroSupported : true
    }

    private func engineChoice(_ engine: Engine) -> some View {
        let isSelected = selected == engine
        let status = engineStatus(engine)
        return Button {
            select(engine)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Label(engine.name, systemImage: engine.icon)
                    .font(DS.Font.callout)
                Text(status)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.s)
            .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(isSelected ? DS.Color.accent : DS.Color.separator,
                                  lineWidth: DS.Size.voiceChoiceBorder)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailableOnThisMac(engine) || isPreparing(engine))
        .help(isAvailableOnThisMac(engine) ? "Speak with \(engine.name)" : Self.kokoroUnavailableLine)
        .accessibilityLabel("\(engine.name) voice, \(status)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The chosen voice reports the speech owner's own answer, so a voice that failed while
    /// speaking never still reads "ready" here. The other voice reports what is on disk.
    private func engineStatus(_ engine: Engine) -> String {
        guard isAvailableOnThisMac(engine) else { return "Needs macOS 26.6 or later" }
        let base = engine == .pocket ? "4 voices" : KokoroAgentVoice.voiceName
        if engine == selected {
            switch availability {
            case .ready: return "\(base) · ready"
            case .preparing: return "Getting ready…"
            case .needsDownload: return "\(base) · tap to download"
            case .failed: return "Couldn't start · tap to try again"
            }
        }
        if isPreparing(engine) { return "Getting ready…" }
        return isReady(engine) ? "\(base) · ready" : "\(base) · tap to download"
    }

    /// Choosing a voice saves the choice at once, so what this screen shows is always the voice
    /// the app will really use. If it cannot speak yet it is fetched (or restarted after a
    /// failure) through the speech owner's own entry, and the state below follows it.
    private func select(_ engine: Engine) {
        stopPreview()
        guard isAvailableOnThisMac(engine) else { return }
        settings.agentVoiceEngine = engine.rawValue
        if voice.availability != .ready {
            Task { await voice.prepareSelectedVoice() }
        }
    }

    // MARK: State of the chosen voice

    @ViewBuilder
    private var statusBlock: some View {
        switch availability {
        case .ready:
            Label("Your voice is ready", systemImage: "checkmark.circle.fill")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.success)
        case .preparing(let progress):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                // `shaping` — something being fetched and assembled. The one animating orb
                // on this section; it freezes by itself under Reduce Motion.
                LabeledOrb(
                    state: .shaping,
                    title: "Getting your voice ready…",
                    detail: "The first time takes a few minutes. You can keep using Next Notes."
                )
                if let progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("Voice download")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                }
            }
        case .needsDownload:
            actionRow(
                title: "Your voice isn't on this Mac yet",
                detail: "\(downloadSize) Until then, answers show as text.",
                button: "Download voice"
            )
        case .failed:
            if isAvailableOnThisMac(selected) {
                actionRow(
                    title: "Your voice couldn't start",
                    detail: "Answers show as text for now.",
                    button: "Try again"
                )
            } else {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Label("Kokoro isn't available here", systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.warning)
                    Text(Self.kokoroUnavailableLine + " Choose Pocket to hear replies.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
        }
    }

    private func actionRow(title: String, detail: String, button: String) -> some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title).font(DS.Font.callout)
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: DS.Space.s)
            Button(button) {
                stopPreview()
                Task { await voice.prepareSelectedVoice() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Gets your voice ready so replies can be spoken")
        }
        .accessibilityElement(children: .contain)
    }

    private var downloadSize: String {
        selected == .pocket ? "About 550 MB." : "A small download."
    }

    // MARK: Pocket's four voices and the sample

    private var pocketVoices: some View {
        HStack(spacing: DS.Space.s) {
            Text("Voice")
            Spacer()
            ForEach(["alba", "azelma", "cosette", "javert"], id: \.self) { name in
                let isChosen = settings.agentPocketVoice == name
                Button {
                    stopPreview()
                    settings.agentPocketVoice = name
                } label: {
                    Label(name.capitalized,
                          systemImage: isChosen ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Voice \(name.capitalized)")
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
    }

    private var canHearSample: Bool { availability == .ready }

    private var sampleRow: some View {
        HStack(spacing: DS.Space.s) {
            Button(action: togglePreview) {
                Label(isPreviewing ? "Stop sample" : "Hear a sample",
                      systemImage: isPreviewing ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            // A running sample can always be stopped; a new one needs a voice that is ready.
            .disabled(!isPreviewing && !canHearSample)
            .accessibilityHint(canHearSample || isPreviewing ? "" : sampleBlockedReason)
            Text(canHearSample ? currentVoiceName : sampleBlockedReason)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    private var currentVoiceName: String {
        selected == .pocket ? settings.agentPocketVoice.capitalized : "Kokoro · \(KokoroAgentVoice.voiceName)"
    }

    /// Why the sample button is dimmed, in the words a person would use.
    private var sampleBlockedReason: String {
        switch availability {
        case .ready: ""
        case .preparing: "You can hear a sample once your voice is ready."
        case .needsDownload: "Download your voice to hear a sample."
        case .failed: isAvailableOnThisMac(selected)
            ? "Your voice needs to start before you can hear a sample."
            : "Choose Pocket to hear a sample."
        }
    }

    private var footerText: String {
        if !kokoroSupported {
            return "Pocket works on this Mac. " + Self.kokoroUnavailableLine
        }
        return "Pick a voice, then hear a sample. Pocket downloads once, about 550 MB. "
            + "Until a voice is ready, answers show as text."
    }

    /// Computed, not stored: a generic type cannot hold a static stored property.
    static var kokoroUnavailableLine: String {
        "Kokoro doesn't work on macOS 26.4 or 26.5. It needs macOS 26.6 or later."
    }
}
