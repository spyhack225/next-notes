import SwiftUI

/// The strip above the transcription list that answers, from across the desk, whether this
/// thing is recording.
///
/// Two questions get two separate answers: the orb says which kind of work is running, and
/// the red dot says it is being recorded.
///
/// It used to answer a third — a VU needle saying the microphone was actually receiving
/// something — and that was a real signal, because an orb runs on a clock rather than on the
/// input and will keep dancing over a muted mic. The needle went because it was the last of
/// the old instrument-panel design left on this screen and read as borrowed from a different
/// app. The HUD still sets level beside the orb for anyone who needs it while dictating.
///
/// The dotted field behind it is the landing page's texture, faded from the top so the band
/// settles into the list rather than sitting on it as a panel. It is drawn once and never
/// animates; only the real work orb and recording dot move here.
struct DictationStatusBand: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: DictationController.State
    /// The pre-roll can already be recording while the speech engine is still starting.
    /// `state == .starting` alone cannot answer whether the microphone is open.
    let isCapturingAudio: Bool
    /// Seconds since the hold began. Owned by the view above, because the key works from
    /// every section and a recording can therefore already be running when this appears.
    let elapsed: TimeInterval
    /// What to hold, spelled out, so an idle band is an instruction rather than a label.
    let holdKey: String
    /// Whether this band carries the screen's one animating orb.
    ///
    /// With no rows the empty state's orb is the screen's, and it is already saying
    /// `listening` in the same words — a second canvas here would be a duplicate of the
    /// sentence and a second `TimelineView` on a laptop.
    var showsOrb = true

    var body: some View {
        HStack(spacing: DS.Space.l) {
            if showsOrb, isError {
                Image(systemName: "exclamationmark.triangle")
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Color.warning)
                    .accessibilityHidden(true)
            } else if showsOrb {
                ThinkingOrb(state: orb, size: DS.Size.orbSmall, isAnimated: state.isActive)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                headline
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(isError ? DS.Color.warning : DS.Color.textSecondary)
                    .lineLimit(isError ? 3 : 1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: DS.Space.m)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .frame(minHeight: DS.Size.statusBandMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dottedField(opacity: DS.Opacity.fieldFaint, fade: .top)
        // Only the words cross-fade. The orb and the dot each run their own clock, and a
        // transition laid over both would fight them.
        .animation(reduceMotion ? nil : DS.Motion.reveal, value: state)
    }

    private var isRecording: Bool { state == .listening || isCapturingAudio }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    /// The counter replaces the title while the microphone is open, because at that moment
    /// the elapsed time *is* the status and it is the thing being read from a distance.
    @ViewBuilder
    private var headline: some View {
        if isRecording {
            RecordingIndicator(elapsed: elapsed)
        } else {
            Text(title)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Color.text)
        }
    }

    /// From the vocabulary table in `AGENTS.md`, and matching what the HUD shows for the
    /// same controller state — the two are looking at one state machine, so a screen that
    /// named it differently would make the orb mean two things.
    ///
    /// Startup uses `listening` once pre-roll is actually capturing, even before the
    /// speech engine leaves `.starting`. Both this band and the HUD read the same bit.
    private var orb: OrbGeometry.State {
        switch state {
        case .listening: .listening
        case .starting: isCapturingAudio ? .listening : .working
        case .finishing: .working
        case .idle, .error: .breathing
        }
    }

    private var title: String {
        switch state {
        case .idle: "Ready"
        // The pre-roll can open the microphone before the engine leaves `.starting`.
        // Name the capture that is actually happening, not just the engine stage.
        case .starting: isCapturingAudio ? "Recording" : "Getting ready…"
        case .listening: "Recording"
        case .finishing: "Finishing your words…"
        case .error: "Dictation failed"
        }
    }

    private var detail: String {
        switch state {
        case .idle: "Hold \(holdKey), or press Record."
        case .starting: isCapturingAudio
            ? "Release \(holdKey), or press Stop."
            : "Opening the microphone."
        case .listening: "Release \(holdKey), or press Stop."
        // `.finishing` also covers cleanup and insertion. There is no public substage
        // event here, so this line must not claim that transcription is still underway.
        case .finishing: "Preparing the text for your app."
        case .error(let message): message
        }
    }
}
