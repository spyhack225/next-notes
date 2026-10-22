import SwiftUI

/// The follow-through shape, shown once during first run.
///
/// One clearly labelled example of ask → approve → done: the assistant drafts,
/// the person sees exactly what would go out, and nothing moves until they say
/// so. Static on purpose — no button here acts, nothing here is the owner's
/// data, and no meeting, attendee or result is named. The `EXAMPLE` eyebrow is
/// what keeps it from ever reading as something that already happened.
struct OnboardingExampleCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("EXAMPLE")
                .font(DS.Theme.Typography.sans(DS.Theme.Typography.microSize, weight: .medium))
                .tracking(DS.Theme.Typography.captionTracking(for: DS.Theme.Typography.microSize))
                .foregroundStyle(DS.Theme.Palette.mutedForeground)
                .accessibilityHidden(true)
            Text("Nothing sends without you")
                .font(DS.Font.subheadline.weight(.semibold))
            Text("Say \u{201c}send the notes to the team\u{201d}. Your assistant writes the draft, "
                + "shows it to you, and waits. Approve, edit, or cancel \u{2014} nothing goes out "
                + "until you say so.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Theme.Palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            // The approval card's three answers as plain words, not controls: the
            // pill shapes read as tappable buttons, and nothing here acts. The real
            // card lives at the irreversible boundary.
            Text("Approve · Edit · Cancel")
                .font(DS.Font.caption.weight(.semibold))
                .foregroundStyle(DS.Theme.Palette.mutedForeground)
                .padding(.top, DS.Space.xxs)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .themeGlass(cornerRadius: DS.Theme.Layout.radiusInnerCard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Example. Nothing sends without you. Your assistant writes a draft, shows it "
                + "to you, and waits for approve, edit, or cancel."
        )
    }
}
