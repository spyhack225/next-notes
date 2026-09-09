import SwiftUI

/// A finished or running transcript: who spoke, when, and what they said.
///
/// The timestamp column is a fixed width so the speaker labels line up down the page — a
/// transcript is read by scanning that column, and ragged offsets make it unreadable.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    var speakerNames: [String: String] = [:]

    var body: some View {
        List(segments) { segment in
            SegmentRow(segment: segment, name: name(for: segment), color: color(for: segment))
                .id(segment.id)
                .listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        .textSelection(.enabled)
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
        }
        .padding(.vertical, DS.Space.xs)
    }
}

extension Array where Element == TranscriptSegment {
    /// The transcript as plain text, for the clipboard and for the export file.
    func plainText(speakerNames: [String: String] = [:]) -> String {
        map { segment in
            let name = speakerNames[segment.displaySpeaker] ?? segment.displaySpeaker
            return "[\(segment.start.counterText)] \(name): \(segment.text)"
        }
        .joined(separator: "\n")
    }
}
