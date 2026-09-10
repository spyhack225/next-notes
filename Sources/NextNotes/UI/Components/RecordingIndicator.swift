import SwiftUI

/// The pulsing red dot, optionally with an elapsed-time counter beside it.
///
/// This is the one place red appears as chrome. Everywhere the app says "recording", it
/// says it with this view, so the meaning of the colour never drifts.
struct RecordingIndicator: View {
    var elapsed: TimeInterval?
    var compact = false
    var label: String?

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: compact ? DS.Space.xs : DS.Space.s) {
            Circle()
                .fill(DS.Color.record)
                .frame(width: dotSize, height: dotSize)
                .opacity(isPulsing ? DS.Opacity.recordPulseLow : 1)
                .onAppear {
                    withAnimation(DS.Motion.recordPulse) { isPulsing = true }
                }

            if let label {
                Text(label)
                    .font(compact ? DS.Font.caption : DS.Font.subheadline)
                    .foregroundStyle(DS.Color.textSecondary)
            }

            if let elapsed {
                Text(elapsed.counterText)
                    .font(compact ? DS.Font.counterSmall : DS.Font.counter)
                    .foregroundStyle(DS.Color.text)
                    // The digits roll rather than cut. This counter is often the only thing
                    // moving on screen — in the sidebar, the menu bar and the island — and a
                    // number that snaps between values reads as a redraw rather than a clock.
                    .contentTransition(.numericText())
                    .animation(DS.Motion.standard, value: elapsed)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var dotSize: CGFloat { compact ? DS.Size.recordDotCompact : DS.Size.recordDot }

    private var accessibilityText: String {
        var parts = ["Recording"]
        if let label { parts.append(label) }
        if let elapsed { parts.append(elapsed.counterText) }
        return parts.joined(separator: ", ")
    }
}

extension TimeInterval {
    /// `mm:ss`, or `h:mm:ss` past an hour — the way a counter reads.
    var counterText: String {
        let total = Int(max(0, self))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
