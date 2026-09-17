import SwiftUI

/// A finished or running transcript: who spoke, when, and what they said.
///
/// The timestamp column is a fixed width so the speaker labels line up down the page — a
/// transcript is read by scanning that column, and ragged offsets make it unreadable.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    var speakerNames: [String: String] = [:]
    /// A second a search result jumped to: scrolled into view and marked.
    var focus: NavigationState.TranscriptFocus? = nil
    /// Called once the jump has scrolled, so the owner can clear the focus and a later visit
    /// to the meeting does not jump again.
    var onFocusHandled: (() -> Void)? = nil
    /// The row the jump marked. Kept here so it stays marked after the focus is cleared.
    @State private var highlightedID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            List(segments) { segment in
                SegmentRow(segment: segment, name: name(for: segment), color: color(for: segment))
                    .id(segment.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(segment.id == highlightedID
                                       ? DS.Color.accent.opacity(0.12) : Color.clear)
            }
            .listStyle(.inset)
            .textSelection(.enabled)
            .onChange(of: focus, initial: true) { _, _ in
                guard let id = focusedSegmentID else { return }
                highlightedID = id
                // After the list has laid out, or the scroll lands on rows that do not exist yet.
                Task { @MainActor in
                    withAnimation(DS.Motion.standard) { proxy.scrollTo(id, anchor: .top) }
                    onFocusHandled?()
                }
            }
        }
    }

    /// The segment that holds the focused second, or the first one after it.
    private var focusedSegmentID: UUID? {
        guard let time = focus?.time else { return nil }
        return (segments.first { $0.start <= time && time < max($0.end, $0.start + 0.001) }
            ?? segments.first { $0.start >= time }
            ?? segments.last)?.id
    }

    private func name(for segment: TranscriptSegment) -> String {
        let raw = segment.displaySpeaker
        return speakerNames[raw] ?? raw
    }

    /// "You" is the accent colour by convention; anyone else gets a colour from the speaker
    /// palette, chosen by the *generated* label rather than the display name so that renaming
    /// "Speaker 2" to "Ana" doesn't also change her colour halfway down the page.
    private func color(for segment: TranscriptSegment) -> Color {
        guard segment.source != .mic else { return DS.Color.accent }
        return DS.Color.speaker(named: segment.displaySpeaker)
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let name: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Text(segment.start.counterText)
                .font(DS.Font.timestamp)
                .foregroundStyle(DS.Color.textTertiary)
                .frame(width: DS.Size.chipColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                SpeakerLabel(name: name, color: color)
                Text(segment.text)
                    .font(DS.Font.transcript)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A transcript is prose, and a detail pane on a wide display is several times
            // wider than a line the eye can track back from. Only a ceiling — a narrow pane
            // is unaffected.
            .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
        }
        .padding(.vertical, DS.Space.xs)
    }
}

extension Array where Element == TranscriptSegment {
    /// The transcript as plain text, for the clipboard and for the export file.
    func plainText(speakerNames: [String: String] = [:]) -> String {
        filter(\.includeInMeetingNotes)
            .map { segment in
                let name = speakerNames[segment.displaySpeaker] ?? segment.displaySpeaker
                return "[\(segment.start.counterText)] \(name): \(segment.text)"
            }
            .joined(separator: "\n")
    }
}
