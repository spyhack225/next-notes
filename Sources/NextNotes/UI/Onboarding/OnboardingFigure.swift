import SwiftUI

/// The companion on an onboarding screen: one complete Open Peeps sitting
/// template per scene, used exactly as drawn — each template's own integrated
/// head, never covered or composited. The person's own
/// Notion face lives where identity lives (the welcome face row, island, chat,
/// About) — never drawn onto this figure.
///
/// Ambient motion only — a slow vertical bob on the ambient cadence, frozen under
/// Reduce Motion (a still figure, never a stopped one). Hidden from accessibility
/// trees; the screen's own headline already says what the figure decorates.
struct OnboardingFigure: View {
    let scene: PeepScene
    /// Sitting templates are tall and narrow; 200pt keeps the
    /// figure legible without owning the screen.
    var height: CGFloat = 200

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                figure(offsetY: 0)
            } else {
                TimelineView(.periodic(from: .now, by: DS.Motion.orbAmbientFrameInterval)) { timeline in
                    figure(offsetY: Self.bob(at: timeline.date))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func figure(offsetY: CGFloat) -> some View {
        Group {
            if let image = PeepFigure.image(scene: scene, height: height) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
                    .offset(y: offsetY)
            }
        }
    }

    /// Slow breathing bob, ±5pt on a ~6s loop. Placement, not progress: it says
    /// somebody is here, never that work is running.
    private static func bob(at date: Date) -> CGFloat {
        5 * CGFloat(sin(date.timeIntervalSinceReferenceDate * .pi * 2 / 6.2))
    }
}
