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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRecording: Bool { controller.state == .listening || controller.isCapturingAudio }

    var body: some View {
        capsule.tint(DS.Color.accent)
            .font(DS.Font.body)
    }

    @ViewBuilder
    private var capsule: some View {
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

            // The stage, then the words so far: two lines, newest kept, their height
            // reserved from the start so the first partial does not shove the label up.
            // After key-up the words stay as heard while the label says what is left.
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(status)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.text)
                    .lineLimit(1)
                Text(LiveDictationText.tail(controller.transcript, limit: DS.LiveText.hudTailCharacters))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(DS.LiveText.lines, reservesSpace: true)
                    .truncationMode(.head)
                    .animation(reduceMotion ? nil : DS.Motion.liveText, value: controller.transcript)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Named once, never announced per word: VoiceOver reads it when visited.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status)
            .accessibilityValue(LiveDictationText.hasWords(controller.transcript)
                ? controller.transcript : "")
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
        stage?.orb ?? .working
    }

    /// One mapping shared with the island. "Getting ready…" only while the pre-roll has not
    /// opened the mic yet (D-02); after key-up the controller now says which half of its
    /// tail it is in, so the wait reads "Writing it out…" and then "Tidying up…" rather
    /// than one "Finishing…" over words that were already heard.
    private var stage: LiveDictationStage? {
        LiveDictationStage.of(
            controller.state,
            isCapturing: controller.isCapturingAudio,
            finishing: controller.finishingStage
        )
    }

    private var status: String { stage?.label ?? "" }
}
