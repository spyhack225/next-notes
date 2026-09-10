import SwiftUI

/// The meeting that is recording right now.
///
/// Two meters stacked rather than one: the whole design rests on keeping your microphone
/// and the room's audio apart, and seeing both move is the only way to notice that the tap
/// never started — a single mixed meter would look perfectly healthy while half the
/// conversation went missing.
struct MeetingLiveView: View {
    @Bindable var session: MeetingSession

    @State private var controller = MeetingController.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.l) {
                // `weaving` rather than `listening`: a meeting arrives on two channels, and
                // three strands plaiting is what the app is actually doing with them — your
                // microphone and the room's output braided into one ordered transcript.
                // Dictation, which has one voice, gets `listening` instead.
                ThinkingOrb(state: .weaving, isInline: false, isAnimated: session.isRecording)

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(session.meeting.title)
                        .font(DS.Font.title3)
                    RecordingIndicator(elapsed: session.elapsed)
                }
                Spacer()
                Button {
                    Task { await controller.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.record)
            }

            VStack(spacing: DS.Space.s) {
                track(label: "You", level: session.micLevel, isActive: session.isRecording)
                track(
                    label: "Others",
                    level: session.systemLevel,
                    isActive: session.isRecording && session.systemAudioProblem == nil
                )
            }

            if let problem = session.systemAudioProblem {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "speaker.slash")
                        .foregroundStyle(DS.Color.warning)
                    Text(problem)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Settings…") { Permissions.openSystemAudioSettings() }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Texture, not a second animation. The `weaving` orb above is the one canvas this
        // pane is allowed to turn, and it has to keep turning for as long as the meeting
        // runs; a field is drawn once and then free, which is the only kind of decoration
        // a screen that is also transcribing two audio tracks can afford.
        .dottedField(opacity: DS.Opacity.fieldFaint, fade: .top)
    }

    private func track(label: String, level: Float, isActive: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Size.trackLabelWidth, alignment: .leading)
            LevelBar(level: level, isActive: isActive)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if session.segments.isEmpty {
            waiting
        } else {
            // Follows the newest line, which is what you want while the meeting runs; the
            // finished transcript in `MeetingDetailView` doesn't scroll itself.
            ScrollViewReader { proxy in
                TranscriptView(segments: session.segments, speakerNames: session.meeting.speakerNames)
                    .onChange(of: session.segments.count) { _, _ in
                        guard let last = session.segments.last else { return }
                        withAnimation(DS.Motion.standard) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
            }
        }
    }

    /// The first half-minute, before any window of audio has come back.
    ///
    /// Set in the empty state's own type on the empty state's own field, but deliberately
    /// **without an orb**. `OrbUnavailableView` would put a 96pt `weaving` orb here while
    /// the header is already turning a 64pt one four inches above it: the same word said
    /// twice, on a second canvas, on the one screen in the app that is simultaneously
    /// recording two audio streams and running Parakeet over them.
    private var waiting: some View {
        VStack(spacing: DS.Space.s) {
            Text("Listening")
                .font(DS.Font.emptyStateTitle)
                .foregroundStyle(DS.Color.text)
            Text("Speech is transcribed in windows of about half a minute, so the first "
                 + "lines take a moment to appear.")
                .font(DS.Font.emptyStateMessage)
                .foregroundStyle(DS.Color.textSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: DS.Size.emptyStateWidth)
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dottedField(opacity: DS.Opacity.fieldFaint)
    }
}
