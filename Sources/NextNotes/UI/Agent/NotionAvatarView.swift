import AppKit
import SwiftUI

/// A Notion-style avatar composed from vendored SVG parts. Falls back to a still orb when
/// assets are missing (bare binary without Resources, or a broken install).
struct NotionAvatarView: View {
    var config: NotionAvatarConfig
    var size: CGFloat = DS.Size.agentAvatar
    var fallbackOrb: OrbGeometry.State = .breathing

    var body: some View {
        Group {
            if let image = NotionAvatarRenderer.image(for: config, side: size * 2) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                ThinkingOrb(
                    state: fallbackOrb,
                    size: size * 0.72,
                    ink: DS.Color.accent,
                    isAnimated: false
                )
                .frame(width: size, height: size)
            }
        }
        .clipShape(Circle())
        .background(Circle().fill(DS.Color.groupedFill))
        .accessibilityHidden(true)
    }
}

/// Circular avatar with the reference-style pencil affordance on the lower trailing edge.
struct AgentAvatarBadge: View {
    var config: NotionAvatarConfig
    var size: CGFloat = DS.Size.agentAvatarHero
    var onEdit: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            NotionAvatarView(config: config, size: size)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(DS.Color.text)
                    .frame(width: DS.Size.agentAvatarEdit, height: DS.Size.agentAvatarEdit)
                    .glassSurface(in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: DS.Space.xs, y: DS.Space.xs)
            .accessibilityLabel("Edit avatar")
        }
        .frame(width: size, height: size)
    }
}
