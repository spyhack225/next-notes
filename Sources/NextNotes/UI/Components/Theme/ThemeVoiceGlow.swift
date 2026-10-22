import SwiftUI

/// A per-frame level feed for the voice glow that never re-renders its view.
///
/// The site drives its voice glow per-frame without re-rendering; this box is the
/// native equivalent of that contract, and it copies the VU meter's shape from
/// AGENTS.md on purpose — a plain reference type the view merely holds. The caller
/// writes `value` at audio rate from whatever thread already owns the level; the
/// glow's `TimelineView` repaints on the token cadence and reads the latest value
/// during the draw. Racy by design, like a meter needle: a torn read costs one
/// frame of glow, never correctness — which is why there is deliberately no lock
/// here rather than a missing one. Ephemeral per-composer state, never persisted:
/// this is a drawing aid, not a store, ledger, queue or gate.
final class VoiceGlowLevel {
    /// Instantaneous voice level, 0…1. Clamped at draw time.
    var value: Double

    init(_ value: Double = 0) {
        self.value = value
    }
}

/// The site's voice glow as a native composer-bottom-edge treatment (spec §6 +
/// §10, UX-11 treatment 4). Reimplements the `voice-glow` npm package with a
/// native canvas — the package itself is never installed.
///
/// The site runs a sound-reactive glow along its composer box's bottom edge:
/// shimmer while the demo "speaks", a gathered travelling beam while it "works",
/// idle otherwise. This view is that bottom edge, sized to the composer's width by
/// its parent (pin it with `.overlay(alignment: .bottom)` at adoption):
/// - `idle`: a quiet edge at `idleOpacity` — placement without a claim.
/// - `speaking`: the edge shimmers with the live `level` box (band and core line
///   brighten with level; no layout moves, opacity only).
/// - `working`: a soft beam of `beamFraction` width sweeps the edge on `workPeriod`
///   (the site's `processing` flag maps to this mode).
///
/// Spec → token map (all values owned by the parallel theme-tokens worker):
/// - `type "default"` → one soft band plus a hairline core in a single theme ink.
/// - `strength 0.7` → `DS.Theme.Voice.strength` (master opacity class).
/// - Per-frame level, no re-renders → the `VoiceGlowLevel` box above.
/// - Shimmer / travelling beam / idle → `Mode`; sweep timing → `workPeriod`,
///   repaint cadence → `frameInterval`, beam width → `beamFraction`.
/// - Band thickness → `edgeHeight`; idle presence → `idleOpacity`;
///   level-to-shimmer gain → `shimmerGain`; glow ink → `ink`.
///
/// Cheapest first, like `ThinkingOrb.clock`: Reduce Motion, `isAnimated: false`,
/// and the idle edge all render one constant canvas with no `TimelineView`. Under
/// Reduce Motion a speaking glow rests at its idle edge — frozen placement that
/// claims no activity — and a working beam parks at `stillPhase`. Pass
/// `isAnimated: false` when the composer is off-screen or the turn is over.
///
/// Meaning rules, unchanged: single theme ink on the composer's bottom edge, never
/// a status dot, never beside `RecordingIndicator` as a second opinion about the
/// microphone. Hidden from accessibility and hit testing; the composer's own label
/// already says what this edge decorates.
struct ThemeVoiceGlow: View {
    /// Which half of the site's behaviour this edge is showing.
    enum Mode {
        /// At rest. A quiet edge, always safe to show.
        case idle
        /// Sound-reactive shimmer driven by `level`.
        case speaking
        /// Gathered travelling beam (the site's `processing` state).
        case working
    }

    var mode: Mode = .idle
    /// Live level feed for `speaking`. The caller holds this box and writes to it;
    /// the default is a private silent box, which is only correct for idle use.
    var level: VoiceGlowLevel = VoiceGlowLevel()
    /// False when off-screen or the turn is over. Reduce Motion freezes regardless.
    var isAnimated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        clock
            .frame(height: DS.Theme.Voice.edgeHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var clock: some View {
        if reduceMotion || !isAnimated || mode == .idle {
            canvas(phase: DS.Theme.Voice.stillPhase, level: Self.restingLevel)
        } else {
            TimelineView(.periodic(from: .now, by: DS.Theme.Voice.frameInterval)) { timeline in
                canvas(phase: Self.phase(at: timeline.date), level: level.value)
            }
        }
    }

    private func canvas(phase: Double, level: Double) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            Self.draw(in: &context, size: size, mode: mode, phase: phase, level: level)
        }
    }

    private static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        mode: Mode,
        phase: Double,
        level: Double
    ) {
        guard size.width > 0, size.height > 0 else { return }
        // Mathematical bounds on the incoming level, not a design value.
        let clamped = min(max(level, 0), 1)
        let ink = DS.Theme.Voice.ink

        // The soft band: full-width, fading in toward the bottom lip.
        let bandOpacity: Double = {
            switch mode {
            case .idle:
                DS.Theme.Voice.idleOpacity
            case .speaking:
                min(
                    DS.Theme.Voice.idleOpacity + clamped * DS.Theme.Voice.shimmerGain,
                    Self.fullOpacity
                )
            case .working:
                DS.Theme.Voice.strength
            }
        }()
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: [
                    Gradient.Stop(color: .clear, location: 0),
                    Gradient.Stop(color: ink.opacity(bandOpacity), location: Self.fullTurn),
                ]),
                startPoint: CGPoint(x: size.width / Self.halfDivisor, y: 0),
                endPoint: CGPoint(x: size.width / Self.halfDivisor, y: size.height)
            )
        )

        // The hairline core sitting on the bottom lip.
        let coreOpacity: Double = {
            switch mode {
            case .idle:
                DS.Theme.Voice.idleOpacity
            case .speaking:
                clamped * DS.Theme.Voice.strength
            case .working:
                DS.Theme.Voice.strength
            }
        }()
        context.fill(
            Path(CGRect(
                x: 0,
                y: size.height - DS.Border.hairline,
                width: size.width,
                height: DS.Border.hairline
            )),
            with: .color(ink.opacity(coreOpacity))
        )

        // The gathered beam, working mode only: a soft pill sweeping the edge.
        if mode == .working {
            let sweep = Self.wrap(phase)
            let beamWidth = DS.Theme.Voice.beamFraction * size.width
            let beam = CGRect(
                x: sweep * size.width - beamWidth / Self.halfDivisor,
                y: 0,
                width: beamWidth,
                height: size.height
            )
            context.fill(
                Path(roundedRect: beam, cornerRadius: size.height / Self.halfDivisor),
                with: .linearGradient(
                    Gradient(stops: [
                        Gradient.Stop(color: .clear, location: 0),
                        Gradient.Stop(
                            color: ink.opacity(DS.Theme.Voice.strength),
                            location: Self.fullTurn / Self.halfDivisor
                        ),
                        Gradient.Stop(color: .clear, location: Self.fullTurn),
                    ]),
                    startPoint: CGPoint(x: beam.minX, y: size.height / Self.halfDivisor),
                    endPoint: CGPoint(x: beam.maxX, y: size.height / Self.halfDivisor)
                )
            )
        }
    }

    /// Sweep position in turns, from the same shared-epoch shape as the border beam.
    private static func phase(at date: Date) -> Double {
        wrap((date.timeIntervalSinceReferenceDate - epoch) / DS.Theme.Voice.workPeriod)
    }

    /// Normalises any phase into one turn (`rounded(.down)` keeps the fractional
    /// part without literal bounds — the arithmetic is the cycle).
    private static func wrap(_ phase: Double) -> Double {
        phase - phase.rounded(.down)
    }

    private static let epoch = Date().timeIntervalSinceReferenceDate
    /// The frozen level: silence. A still speaking glow rests at its idle edge.
    private static let restingLevel = 0.0
    /// Gradient domain ends and full opacity: bounds of the 0…1 shading math.
    private static let fullTurn = 1.0
    private static let fullOpacity = 1.0
    /// Centring and pill-radius divisor: half of a span — pure geometry.
    private static let halfDivisor = 2.0
}

extension View {
    /// Pins the voice glow to this composer's bottom edge. The caller owns the
    /// animation budget: at most one live treatment per screen, paused off-screen.
    func themeVoiceGlow(
        mode: ThemeVoiceGlow.Mode = .idle,
        level: VoiceGlowLevel = VoiceGlowLevel(),
        isAnimated: Bool = true
    ) -> some View {
        overlay(alignment: .bottom) {
            ThemeVoiceGlow(mode: mode, level: level, isAnimated: isAnimated)
        }
    }
}
