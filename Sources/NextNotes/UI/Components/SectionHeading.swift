import SwiftUI

/// A heading in the landing page's shape: a small capitalised label, then the heading, then
/// the sentence that qualifies it.
///
/// The page uses this everywhere and it is the reason its sections read as chapters rather
/// than as a stack of boxes. The eyebrow does the work a bold heading would otherwise have
/// to: it names the category, so the heading itself is free to be about the content.
///
/// The orb is optional and, by default, **still**. A mark beside a heading is a mark, not a
/// status — it says which part of the app you are in, and one that animated forever would
/// be four canvases running on a screen where nothing is happening. Pass `isOrbAnimated`
/// only while the work that orb names is genuinely running.
struct SectionHeading: View {
    let title: String
    var eyebrow: String?
    var subtitle: String?
    /// From the vocabulary in `AGENTS.md` — what this section of the app is *about*.
    var orb: OrbGeometry.State?
    var orbSize: CGFloat = DS.Size.orbSmall
    var isOrbAnimated = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.orbGap) {
            if let orb {
                ThinkingOrb(
                    state: orb,
                    size: orbSize,
                    isAnimated: isOrbAnimated,
                    timeScale: DS.Motion.orbAmbientScale
                )
                .accessibilityHidden(true)
                // A canvas has no text in it, so it has no baseline of its own to align on.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(DS.Font.eyebrow)
                        .tracking(DS.Font.eyebrowTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Text(title)
                    .font(DS.Font.title3)
                    .foregroundStyle(DS.Color.text)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
