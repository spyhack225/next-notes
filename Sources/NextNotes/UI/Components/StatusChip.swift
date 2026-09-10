import SwiftUI

/// A small tinted capsule: an engine name, a speaker, "Corrected", a meeting status.
struct StatusChip: View {
    let text: String
    var color: Color = DS.Color.info
    var systemImage: String?

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(DS.Font.caption2)
            }
            Text(text)
                .font(DS.Font.chip)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xxs)
        .background(color.opacity(DS.Opacity.chipFill), in: Capsule())
        .foregroundStyle(color)
        .lineLimit(1)
    }
}

/// A speaker's name with its colour dot, for transcripts.
struct SpeakerLabel: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Circle()
                .fill(color)
                .frame(width: DS.Size.speakerDot, height: DS.Size.speakerDot)
            Text(name)
                .font(DS.Font.chip)
                .foregroundStyle(color)
        }
        .lineLimit(1)
    }
}
