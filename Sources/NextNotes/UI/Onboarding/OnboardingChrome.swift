import SwiftUI

/// The furniture every first-run screen is made of.
///
/// One shape, repeated seven times: a tinted symbol, a headline that asks a question or
/// names a benefit, one grey sentence of why, one card, one primary button, and — only when
/// the screen is optional — a quiet Skip under it. Nothing here knows what any particular
/// screen is about, which is what keeps the seven of them looking like one window rather
/// than seven.
struct OnboardingScreen<Content: View>: View {
    let symbol: String
    let headline: String
    let subhead: String
    /// The primary button's words. Named for what happens, not for the mechanism —
    /// "Continue", "Done", never "Next step 3 of 7".
    var primaryTitle: String = "Continue"
    var isPrimaryEnabled: Bool = true
    let primary: () -> Void
    /// Present only on a screen the user is allowed to pass over.
    var skip: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: DS.Onboarding.blockSpacing) {
            VStack(spacing: DS.Onboarding.headerSpacing) {
                Image(systemName: symbol)
                    .font(.system(size: DS.Onboarding.icon, weight: .regular))
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityHidden(true)

                Text(headline)
                    .font(DS.Font.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subhead)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            content()

            VStack(spacing: DS.Space.m) {
                Button(action: primary) {
                    Text(primaryTitle)
                        .frame(width: DS.Onboarding.pillWidth, height: DS.Onboarding.pillHeight)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isPrimaryEnabled)
                .keyboardShortcut(.defaultAction)

                if let skip {
                    Button("Skip", action: skip)
                        .buttonStyle(.plain)
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .accessibilityHint("Passes over this step. You can set it up later in Settings.")
                }
            }
        }
        .frame(width: DS.Onboarding.contentWidth)
    }
}

/// The rounded card a screen's rows live in.
///
/// Material rather than glass: this window has no wallpaper behind it to refract, and a
/// glass pane over a flat window background reads as a smudge.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.vertical, DS.Space.xs)
        .background(DS.Color.groupedFill, in: .rect(cornerRadius: DS.Radius.glass))
    }
}

/// What a row can be waiting on. The screens never say "TCC", "authorization status" or
/// "not determined" — they say one of these.
enum OnboardingGrantState: Equatable {
    /// Granted, and we can prove it.
    case done
    /// Not granted yet, and pressing the button is what asks.
    case ask
    /// The button has been pressed and we are waiting for an answer, here or in System
    /// Settings.
    case waiting
    /// macOS will not tell us either way — the system-audio case. The row can ask, but it
    /// can never tick, and claiming a tick would be inventing one.
    case unknowable
}

/// One line inside a card: a symbol, what it is for in plain words, and one control.
///
/// The Muse shape — an "Allow" pill that becomes a green check — with two additions macOS
/// forces: a row that can be *asked* but never *read* (`unknowable`), and a row still
/// waiting on an answer that is being given in another application.
struct OnboardingGrantRow: View {
    let title: String
    let detail: String
    let symbol: String
    let state: OnboardingGrantState
    var actionTitle: String = "Allow"
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Size.iconLarge)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.subheadline.weight(.semibold))
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.s)

            control
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(minHeight: DS.Onboarding.rowMinHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(state == .done ? [] : .isButton)
        .accessibilityAction { if state != .done { action() } }
        .animation(DS.Motion.standard, value: state)
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(DS.Font.title3)
                .foregroundStyle(DS.Color.success)
                .accessibilityHidden(true)
        case .waiting:
            HStack(spacing: DS.Space.s) {
                ThinkingOrb(state: .breathing, size: DS.Size.orbBadge)
                    .accessibilityHidden(true)
                pill(actionTitle)
            }
        case .ask, .unknowable:
            pill(actionTitle)
        }
    }

    private func pill(_ label: String) -> some View {
        Button(action: action) {
            Text(label)
                .font(DS.Font.caption.weight(.semibold))
                .frame(minWidth: DS.Onboarding.allowPillWidth, minHeight: DS.Onboarding.allowPillHeight)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        switch state {
        case .done: "Allowed"
        case .waiting: "Waiting for your answer"
        case .ask: "Not allowed yet"
        case .unknowable: "macOS decides this the first time it is used"
        }
    }
}

/// One setting inside a card: a label, a line of explanation, and a pop-up menu — the shape
/// the shortcuts screen uses.
struct OnboardingChoiceRow<Menu: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var menu: () -> Menu

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.subheadline.weight(.semibold))
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            menu()
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(minHeight: DS.Onboarding.rowMinHeight)
    }
}

/// One toggle inside a card — the folders screen.
struct OnboardingToggleRow: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Size.iconLarge)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.subheadline.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(minHeight: DS.Onboarding.rowMinHeight)
    }
}

/// The hairline between two rows in a card. Inset past the symbol column so the rows read
/// as a list rather than as a table.
struct OnboardingRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, DS.Space.m)
    }
}

/// A short, quiet explanation under a card — the sentence that appears when something has
/// not gone the way it should.
struct OnboardingHint: View {
    let text: String
    var symbol: String = "info.circle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: symbol)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The progress dots under the primary button.
///
/// Dots rather than "Step 3 of 7": the count is reassurance about how much is left, not a
/// number anybody needs to act on, and a figure invites the question "what were the other
/// four?".
struct OnboardingDots: View {
    let index: Int
    let total: Int

    var body: some View {
        HStack(spacing: DS.Onboarding.dotSpacing) {
            ForEach(0..<total, id: \.self) { position in
                Circle()
                    .fill(position == index ? DS.Color.text : DS.Color.textTertiary)
                    .frame(width: DS.Onboarding.dot, height: DS.Onboarding.dot)
            }
        }
        .animation(DS.Motion.standard, value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(total)")
    }
}

/// The back / forward chevrons in the top corner.
struct OnboardingChevrons: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            chevron("chevron.left", label: "Go back", enabled: canGoBack, action: back)
            chevron("chevron.right", label: "Go forward", enabled: canGoForward, action: forward)
        }
    }

    private func chevron(
        _ symbol: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DS.Font.caption.weight(.semibold))
                .frame(width: DS.Onboarding.chevron, height: DS.Onboarding.chevron)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? DS.Color.textSecondary : DS.Color.textTertiary)
        .background(DS.Color.groupedFill, in: .circle)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
