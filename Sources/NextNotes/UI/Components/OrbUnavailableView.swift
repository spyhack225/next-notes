import SwiftUI

/// An empty state whose illustration is the orb.
///
/// `ContentUnavailableView` is still right for a state the system has a symbol for — a
/// failed search, a missing file. It is wrong for the states this app spends most of its
/// empty screens in, which are not absences but *stages*: nothing recorded **yet**, no
/// account connected **yet**, a model not downloaded **yet**. A grey SF Symbol says the
/// screen is broken; the orb for that stage says which move comes next, in the same
/// vocabulary the app uses when it is working.
///
/// Pick the state by cause, not by mood — the table in `AGENTS.md` is the whole list, and
/// the same orb has to mean the same thing in an empty state as it does in a status line.
///
/// The orb here is decoration in the sense that it repeats what the title says, so it is
/// hidden from accessibility; the title, the message and any buttons are read normally.
struct OrbUnavailableView<Actions: View>: View {
    let state: OrbGeometry.State
    let title: String
    var message: String?
    /// The dotted field behind it. On by default: an empty state is the one place with room
    /// for the texture, and a bare centred column in a large empty pane is exactly the
    /// screen this redesign exists to stop shipping.
    var hasField = true
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: DS.Space.l) {
            ThinkingOrb(
                state: state,
                size: DS.Size.orbFeature,
                timeScale: DS.Motion.orbAmbientScale,
                frameInterval: DS.Motion.orbAmbientFrameInterval
            )
            .opacity(DS.Opacity.emptyStateOrb)
            .accessibilityHidden(true)

            VStack(spacing: DS.Space.s) {
                Text(title)
                    .font(DS.Font.emptyStateTitle)
                    .foregroundStyle(DS.Color.text)
                if let message {
                    Text(message)
                        .font(DS.Font.emptyStateMessage)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: DS.Size.emptyStateWidth)

            actions()
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: DS.Size.emptyStateMinHeight)
        // Off is drawn as a transparent field rather than as no field, so that turning it
        // off does not change the view's identity — an empty state that gains an action
        // button should not re-enter with a fade. `DottedField` draws nothing at zero.
        .dottedField(opacity: hasField ? DS.Opacity.fieldFaint : 0)
    }
}

extension OrbUnavailableView where Actions == EmptyView {
    init(_ state: OrbGeometry.State, title: String, message: String? = nil, hasField: Bool = true) {
        self.init(state: state, title: title, message: message, hasField: hasField) { EmptyView() }
    }
}

extension OrbUnavailableView {
    init(
        _ state: OrbGeometry.State,
        title: String,
        message: String? = nil,
        hasField: Bool = true,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.init(state: state, title: title, message: message, hasField: hasField, actions: actions)
    }
}
