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

/// How an avatar surface offers its pencil.
enum AgentAvatarEditAffordance {
    /// The pencil sits on the lower trailing rim all the time — for a compact surface that
    /// has no other way into the editor.
    case always
    /// The pencil fades in on pointer hover or keyboard focus and the character is
    /// unobstructed otherwise. The default, because the About hero is the one place the
    /// character is the subject rather than a badge.
    case onHoverOrFocus
}

/// Circular avatar with the reference-style pencil affordance on the lower trailing edge.
///
/// At rest nothing covers the face: the pencil is revealed by pointer hover or keyboard
/// focus, and it lives on the rim, mostly outside the portrait's circle. The reveal is an
/// opacity change — the button is always in the layout, so nothing shifts — and the room it
/// reaches into is reserved by padding, which also keeps it inside the hover region that
/// reveals it.
///
/// Hover is not the only way in, because a keyboard or VoiceOver user cannot hover: the
/// button stays in the focus chain and the accessibility tree while it is invisible, and
/// the whole avatar carries a context menu with the same action.
struct AgentAvatarBadge: View {
    var config: NotionAvatarConfig
    var size: CGFloat = DS.Size.agentAvatarHero
    /// The hero is the one avatar in a settings pane, so it is the one that idles and
    /// eventually sleeps — `restingSince` is when the agent last did anything.
    var state: AgentAvatarState = .idle
    var restingSince: Date?
    var editAffordance: AgentAvatarEditAffordance = .onHoverOrFocus
    var onEdit: () -> Void

    @State private var isHovering = false
    @FocusState private var isEditFocused: Bool

    private var showsEdit: Bool {
        switch editAffordance {
        case .always: true
        case .onHoverOrFocus: isHovering || isEditFocused
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AgentAvatarView(
                config: config,
                state: state,
                restingSince: restingSince,
                size: size
            )
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(DS.Color.text)
                    .frame(width: DS.Size.agentAvatarEdit, height: DS.Size.agentAvatarEdit)
                    .glassSurface(in: Circle())
            }
            .buttonStyle(.plain)
            .focused($isEditFocused)
            .offset(x: DS.Space.s, y: DS.Space.s)
            .opacity(showsEdit ? 1 : 0)
            .accessibilityLabel("Edit avatar")
            .help("Edit avatar")
        }
        .frame(width: size, height: size)
        // The pencil reaches past the portrait's corner; this is the room reserved for it,
        // so showing it never moves the character and the part that overhangs stays inside
        // the hover region above.
        .padding(DS.Space.s)
        .animation(DS.Motion.standard, value: showsEdit)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Edit avatar…", action: onEdit)
        }
    }
}
