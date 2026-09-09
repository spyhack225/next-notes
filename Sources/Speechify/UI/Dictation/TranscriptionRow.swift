import SpeechifyDictionary
import SwiftUI

/// One past dictation in the list.
///
/// The Copy button appears on hover only. A visible button on every row turns a list of
/// sentences into a list of controls, and the same command is on the context menu for
/// anyone who never hovers.
struct TranscriptionRow: View {
    let run: DictationRun

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                StatusChip(text: run.engine)
                Text(run.date, style: .time)
                    .font(DS.Font.timestamp)
                    .foregroundStyle(DS.Color.textSecondary)
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(DS.Font.timestamp)
                    .foregroundStyle(DS.Color.textTertiary)
                Spacer()
                CopyButton(text: run.text, title: "Copy")
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .opacity(isHovering ? 1 : 0)
            }

            Text(run.text)
                .font(DS.Font.transcript)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let corrections = run.corrections, !corrections.isEmpty {
                CorrectionBadges(corrections: corrections)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

/// Shows that the dictionary fired, and on what. Without this the dictionary is invisible
/// and you can't tell a rule that works from one that never matches.
struct CorrectionBadges: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        HStack(spacing: DS.Space.s) {
            StatusChip(
                text: "Corrected",
                color: DS.Color.accent,
                systemImage: "character.book.closed"
            )
            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: DS.Space.xs) {
                    Text(correction.from)
                        .strikethrough()
                        .foregroundStyle(DS.Color.textTertiary)
                    Image(systemName: "arrow.right")
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Color.textTertiary)
                    Text(correction.to)
                        .foregroundStyle(DS.Color.textSecondary)
                    if correction.count > 1 {
                        Text("×\(correction.count)")
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                }
                .font(DS.Font.caption)
            }
            Spacer()
        }
    }
}
