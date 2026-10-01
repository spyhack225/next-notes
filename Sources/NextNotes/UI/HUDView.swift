import SwiftUI

/// The floating capsule shown through a hold, its finishing work, or a brief error.
///
/// It has one job: prove the app heard you. A red dot says recording, a bar says the level
/// is real, and the transcript says what it got — nothing else earns the space, because
/// this thing sits on top of whatever you were actually doing.
///
/// Command Mode borrows the same window and draws something else in it. It is a different
/// question — not "did it hear me" but "what is this and what does it act on" — and the
/// panel is shown for it whatever the heads-up placement setting says, because it is the
/// only surface in the app that can answer that in words.
struct HUDView: View {
    @Bindable var controller: DictationController

    private var isRecording: Bool { controller.state == .listening || controller.isCapturingAudio }

    var body: some View {
        // Both conditions, not just the status: a Command Mode message outlives its hold on
        // purpose, and while it lingers an ordinary dictation started underneath it must
        // still get the dictation capsule. `commandModeOwnsHUD` is where that is decided.
        if controller.commandModeOwnsHUD, let command = controller.commandMode {
            CommandModeCard(
                status: command,
                key: Settings.shared.commandModeKey,
                level: controller.level,
                transcript: controller.transcript
            )
        } else if case .error(let message) = controller.state {
            errorCapsule(message)
        } else {
            dictationCapsule
        }
    }

    /// A stopped hold needs its explanation, not a still work orb and an empty meter.
    /// In particular the clipboard rescue sentence must fit before the error clears.
    private func errorCapsule(_ message: String) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(DS.Font.title3)
                .foregroundStyle(DS.Color.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .frame(width: DS.Size.hud.width, height: DS.Size.hud.height)
        .glassSurface(cornerRadius: DS.Radius.hud, glass: DS.Material.hudGlass)
    }

    private var dictationCapsule: some View {
        HStack(spacing: DS.Space.m) {
            // The orb says *what* is happening, the dot says it is being recorded, and the
            // bar says the microphone is actually receiving something. They are three
            // different questions, which is why the orb is added beside these rather than
            // in place of them: an orb animates on a clock, so it would keep dancing over a
            // muted input and answer "is it hearing me?" with a confident yes.
            ThinkingOrb(state: orb, isAnimated: controller.state.isActive)

            VStack(alignment: .leading, spacing: DS.Space.s) {
                if isRecording {
                    RecordingIndicator(compact: true, label: nil)
                }
                LevelBar(level: controller.level, isActive: isRecording)
                    .frame(width: DS.Size.hudBarWidth)
            }

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(status)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.text)
                    .lineLimit(1)
                if !controller.transcript.isEmpty {
                    Text(controller.transcript)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .frame(width: DS.Size.hud.width, height: DS.Size.hud.height)
        .glassSurface(cornerRadius: DS.Radius.hud, glass: DS.Material.hudGlass)
    }

    /// Which orb the capsule shows. While listening the orb stays `listening` even when
    /// Parakeet is already painting partials into the label; after release the wait is
    /// real work (finalize + cleanup) and says so with `working`. A hold still `.starting`
    /// with the pre-roll running is capturing too (D-02).
    private var orb: OrbGeometry.State {
        controller.state == .listening || controller.isCapturingAudio ? .listening : .working
    }

    private var status: String {
        switch controller.state {
        // "Getting ready…" only while the pre-roll has not opened the mic yet. Once it
        // runs (D-02) the hold is capturing, so it reads as listening instead of setup.
        case .starting: controller.isCapturingAudio ? "Listening…" : "Getting ready…"
        case .listening: "Listening…"
        // The controller's `.finishing` includes transcription, cleanup and insertion.
        // A narrower label would claim a substage that the HUD cannot observe.
        case .finishing: "Finishing…"
        case .error: ""
        case .idle: ""
        }
    }
}
