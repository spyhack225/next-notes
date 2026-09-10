import SwiftUI

/// The floating capsule shown while you hold the key.
///
/// It has one job: prove the app heard you. A red dot says recording, a bar says the level
/// is real, and the transcript says what it got — nothing else earns the space, because
/// this thing sits on top of whatever you were actually doing.
struct HUDView: View {
    @Bindable var controller: DictationController

    private var isRecording: Bool { controller.state == .listening }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            // The orb says *what* is happening, the dot says it is being recorded, and the
            // bar says the microphone is actually receiving something. They are three
            // different questions, which is why the orb is added beside these rather than
            // in place of them: an orb animates on a clock, so it would keep dancing over a
            // muted input and answer "is it hearing me?" with a confident yes.
            ThinkingOrb(state: orb, isAnimated: isRecording)

            VStack(alignment: .leading, spacing: DS.Space.s) {
                RecordingIndicator(compact: true, label: nil)
                    .opacity(isRecording ? 1 : DS.Opacity.recordIdle)
                LevelBar(level: controller.level, isActive: isRecording)
                    .frame(width: DS.Size.hudBarWidth)
            }

            Text(label)
                .font(DS.Font.callout)
                .foregroundStyle(isError ? DS.Color.warning : DS.Color.text)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(DS.Motion.standard, value: controller.transcript)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .frame(width: DS.Size.hud.width, height: DS.Size.hud.height)
        .glassEffect(DS.Material.hudGlass, in: .rect(cornerRadius: DS.Radius.hud))
    }

    /// Which orb the capsule shows. Parakeet resolves on release rather than while you
    /// speak, so the wait after letting go is real work and says so with `working`.
    private var orb: OrbGeometry.State {
        controller.state == .listening ? .listening : .working
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    private var label: String {
        switch controller.state {
        // Not "Listening…": the microphone is not open yet in `.starting`, and on a cold
        // Parakeet that is eleven seconds of the HUD claiming to hear you.
        case .starting: "Getting ready…"
        case .listening: controller.transcript.isEmpty ? "Listening…" : controller.transcript
        // Parakeet transcribes in one pass on release, so there's nothing to show until
        // it lands — say what's happening instead of leaving an empty pill.
        case .finishing: controller.transcript.isEmpty ? "Transcribing…" : controller.transcript
        case .error(let message): message
        case .idle: ""
        }
    }
}
