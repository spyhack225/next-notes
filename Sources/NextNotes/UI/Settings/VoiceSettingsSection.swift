import SwiftUI

/// "Speaking back": which voice the agent talks with, whether it is ready, and a sample.
///
/// The app speaks with Pocket or Kokoro only, so there is no third tile and no system-voice
/// picker. Whether the chosen voice can speak right now is not decided here: it is read from
/// `AgentSpeechSynthesizer.availability`, the same answer the conversation uses to decide
/// between speaking and showing text. This view only describes that answer in plain words and
/// offers the one move that fits it (download, retry, or hear a sample).
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
    /// Offscreen diagnostic only; normal Settings follows the stored selection.
    var engineForPreview: Engine? = nil
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
            } else if isAvailableOnThisMac(selected) {
                LabeledContent("Voice", value: KokoroAgentVoice.voiceName)
            }

            sampleRow

            details
        } header: {
            Text("Speaking back")
        } footer: {
            if let footerText { SettingsNote(text: footerText) }
        }
    }

    // MARK: Which voice

    private var selected: Engine { engineForPreview ?? (settings.agentVoiceEngine == "kokoro" ? .kokoro : .pocket) }

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
        let isSelected = selected == engine && isAvailableOnThisMac(engine)
        let status = engineStatus(engine)
        return Button {
            select(engine)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack {
                    Label(engine.name, systemImage: engine.icon)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : engine.icon)
                        .opacity(isSelected ? 1 : 0)
                        .accessibilityHidden(true)
                }
                    .font(DS.Font.callout)
                Text(status)
                    .font(DS.Font.callout)
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
        guard isAvailableOnThisMac(engine) else { return "Needs a newer macOS" }
        let base = engine == .pocket ? "4 voices to choose from" : "One voice: \(KokoroAgentVoice.voiceName)"
        if engine == selected {
            switch availability {
            case .ready: return "\(base) · ready"
            case .preparing: return base
            case .needsDownload: return base
            case .failed: return "Couldn't start · tap Retry"
            }
        }
        if isPreparing(engine) { return "Getting ready…" }
        return isReady(engine) ? "\(base) · ready" : base
    }

    /// Choosing a voice saves the choice at once, so what this screen shows is always the voice
    /// the app will really use. If it cannot speak yet it is fetched (or restarted after a
    /// failure) through the speech owner's own entry, and the state below follows it.
    @discardableResult
    func select(_ engine: Engine) -> Task<Void, Never>? {
        guard isAvailableOnThisMac(engine) else { return nil }
        stopPreview()
        // Settings owns the persisted choice and advances its selection epoch.
        settings.agentVoiceEngine = engine.rawValue
        return prepareVoice(request: voice.selectedVoiceRequest)
    }

    @discardableResult
    func retry() -> Task<Void, Never> {
        stopPreview()
        return prepareVoice(request: voice.selectedVoiceRequest)
    }

    private func prepareVoice(request: AgentSpeechSynthesizer.VoiceRequest) -> Task<Void, Never> {
        Task { @MainActor in
            // A click that has since been replaced must not clear the new voice's
            // failure or prepare it. This check has no await before owner entry.
            guard voice.selectedVoiceRequest == request else { return }
            await voice.prepareSelectedVoice()
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
                HStack(spacing: DS.Space.s) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Getting your voice ready")
                    Text("Getting your voice ready…")
                        .font(DS.Font.callout)
                }
                Text("The first time takes a few minutes. You can keep using Next Notes.")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                if let progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("Voice download")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                }
            }
        case .needsDownload:
            actionRow(
                title: "Your voice isn't on this Mac yet",
                detail: "Answers show as text until your voice is ready.",
                button: "Download voice"
            )
        case .failed:
            if isAvailableOnThisMac(selected) {
                actionRow(
                    title: "Your voice couldn't start",
                    detail: "Answers show as text for now.",
                    button: "Retry",
                    warning: true
                )
            } else {
                Label(Self.kokoroUnavailableLine, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actionRow(title: String, detail: String, button: String, warning: Bool = false) -> some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                if warning {
                    Label(title, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.Color.warning)
                        .font(DS.Font.callout)
                } else {
                    Text(title).font(DS.Font.callout)
                }
                Text(detail)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: DS.Space.s)
            Button(button) {
                retry()
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Color.accent)
            .accessibilityHint("Gets your voice ready so replies can be spoken")
        }
        .accessibilityElement(children: .contain)
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
                .font(DS.Font.callout)
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

    private var footerText: String? {
        availability == .ready && isAvailableOnThisMac(selected)
            ? "Pick a voice, then hear a sample." : nil
    }

    /// Computed, not stored: a generic type cannot hold a static stored property.
    static var kokoroUnavailableLine: String {
        "Kokoro needs a newer version of macOS. Choose Pocket to hear replies."
    }
}
