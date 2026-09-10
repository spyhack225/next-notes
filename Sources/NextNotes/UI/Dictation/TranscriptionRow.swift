import NextNotesDictionary
import SwiftUI

/// One past dictation in the list.
///
/// The Copy button appears on hover only. A visible button on every row turns a list of
/// sentences into a list of controls, and the same command is on the context menu for
/// anyone who never hovers.
///
/// **No orb lives here.** Every orb is a `Canvas` in a `TimelineView`, and a mark on each
/// row is one per visible row — a scattering of small ones is exactly what the vocabulary
/// forbids, and a list scrolls. The row speaks the same language through its type instead:
/// the engine is set as the landing page sets a card label, and everything above the
/// sentence is quieted so the sentence is what the eye lands on.
struct TranscriptionRow: View {
    let run: DictationRun

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                // An eyebrow rather than a chip. A filled badge on every row turned a list
                // of sentences into a list of badges, and the engine is context for the
                // transcript rather than a status about it.
                Text(run.engine)
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.eyebrowTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Color.textSecondary)
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

            // Deliberately NOT `.textSelection(.enabled)`. In a selectable `List` the two
            // compete for the same mouse-down: selectable text takes the click to place a
            // caret, so clicking the body of a row would not select the row — and the body
            // is most of the row's area. Selecting a fragment is the rarer want; Copy is on
            // hover and in the context menu, for one row or for many. If free selection is
            // ever wanted back, it belongs in a detail view, not in the list.
            //
            // Capped at a comfortable measure rather than at the window's. A detail pane on
            // a wide display is far wider than a readable line, and nothing about the
            // window's width is an argument for a 1400pt one. The row itself still runs the
            // full width — the `Spacer()` above and `.contentShape` below see to that — so
            // clicking beside the text still selects the row.
            Text(run.text)
                .font(DS.Font.transcript)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)

            if let corrections = run.corrections, !corrections.isEmpty {
                CorrectionBadges(corrections: corrections)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DS.Space.s)
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
