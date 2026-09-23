import AppKit
import SwiftUI

/// The agent's character, alive: a Notion-style face whose head, eyes and brows follow
/// `AgentAvatarState`, with the state's gadget drawn as a badge at its shoulder.
///
/// The pose comes from `AgentAvatarChoreography` and nothing here invents motion — this
/// view is pixels, and the specification is that file, which is what makes the vocabulary
/// testable without a screen. The face is drawn as it was composited: one `Canvas`, four
/// cached layer bitmaps, no filters.
///
/// House rules, the same ones the orbs live under:
/// - **Reduce Motion freezes it**, and gets no `TimelineView` at all rather than a paused
///   one. The frame it freezes on is the shared `stillFrame`, so a still avatar reads as a
///   portrait rather than as motion caught mid-blink.
/// - **Never `scaleEffect` the portrait.** The size is asked for, not magnified — a scaled
///   face magnifies the line work and the blink anchor with it. Props are a symbol in a
///   badge, which is the one place a transform is honest.
/// - **A compact row does not animate**: a `List` row draws the still `NotionAvatarView`,
///   and the props are hidden below `DS.Size.avatarPropMinimum`, where they would be a
///   smudge.
struct AgentAvatarView: View {
    var config: NotionAvatarConfig
    var state: AgentAvatarState = .idle
    /// When the agent last did anything. With it, an otherwise-idle portrait falls asleep
    /// on its own after `DS.Motion.avatarSleepAfter` — decided inside the clock rather than
    /// by whoever set the state, because a pane that only re-renders when something happens
    /// would show an awake avatar hours after the last thing did.
    var restingSince: Date?
    /// The frame side. Pass a `DS.Size` token rather than a hand-picked number.
    var size: CGFloat = DS.Size.agentAvatar
    /// What the rings and prop badges are drawn in. The island passes its own ink, because
    /// its substrate is the bezel and `.primary` resolves to black on it in light mode.
    var ink: Color = DS.Color.text
    var showsProp = true
    /// Draws this exact instant rather than following the clock. For diagnostics and
    /// snapshots (`--avatar-sheet`): production surfaces always follow time, and the still
    /// product is what Reduce Motion already gets.
    var frozenAt: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let layers = NotionAvatarRenderer.layers(for: config, side: size * 2) {
                clock(layers)
            } else {
                // No assets — a bare binary without Resources. The still orb stands in,
                // exactly as it does behind `NotionAvatarView`.
                NotionAvatarView(config: config, size: size, fallbackOrb: state.fallbackOrb)
            }
        }
        .frame(width: size, height: size)
        // Always decorative: every surface it appears on already says the same thing in
        // words — a card title, a step row, a name — and a portrait that repeats them is
        // noise in the rotor.
        .accessibilityHidden(true)
    }

    /// Three ways to drive the same portrait, cheapest first — the orbs' arrangement.
    @ViewBuilder
    private func clock(_ layers: NotionAvatarLayers) -> some View {
        if let frozenAt {
            portrait(layers, at: frozenAt, date: nil)
        } else if reduceMotion {
            portrait(layers, at: AgentAvatarChoreography.stillFrame, date: nil)
        } else if state.isAmbient {
            // Nothing is being waited on: a fifth of the display's frames is plenty for a
            // breath, and this is the avatar a window can leave up all afternoon.
            TimelineView(.periodic(from: .now, by: DS.Motion.avatarAmbientFrameInterval)) { timeline in
                portrait(layers, at: elapsed(to: timeline.date), date: timeline.date)
            }
        } else {
            TimelineView(.animation) { timeline in
                portrait(layers, at: elapsed(to: timeline.date), date: timeline.date)
            }
        }
    }

    /// Seconds since the first avatar was drawn, on the avatars' shared clock — the same
    /// construction the orbs use, so two of them are in phase and the trigonometry stays in
    /// a range where a `Double` has precision to spare.
    private func elapsed(to date: Date) -> Double {
        date.timeIntervalSinceReferenceDate - Self.epoch
    }

    private static let epoch = Date().timeIntervalSinceReferenceDate

    /// The state the portrait is actually in. Sleep is the only thing a clock decides: at
    /// the representative still frame there is no clock to decide it with, so a frozen
    /// avatar is whatever state it was *put* in.
    private func effectiveState(at date: Date?) -> AgentAvatarState {
        guard let restingSince, let date else { return state }
        return .resting(
            quietFor: date.timeIntervalSince(restingSince),
            asleepAfter: DS.Motion.avatarSleepAfter
        )
    }

    // MARK: - The portrait

    private func portrait(_ layers: NotionAvatarLayers, at time: Double, date: Date?) -> some View {
        let state = effectiveState(at: date)
        let pose = AgentAvatarChoreography.pose(state, at: time)
        return ZStack {
            // Only the face is clipped to the portrait's circle. The gadget sits on the
            // rim and reaches past it — a plane leaving the frame, a laptop in the lap —
            // and clipping the whole stack cut the wing off at the circle and left a
            // wedge, which is what `--avatar-sheet` caught.
            Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
                draw(layers, state: state, pose: pose, in: &context, size: canvasSize)
            }
            .clipShape(Circle())
            .background(Circle().fill(DS.Color.groupedFill))

            if showsProp, size >= DS.Size.avatarPropMinimum,
               let prop = AgentAvatarChoreography.prop(state), !prop.isDrawnOnCanvas {
                AvatarPropBadge(prop: prop, side: size, phase: pose.phase, ink: ink)
            }
        }
    }

    private func draw(
        _ layers: NotionAvatarLayers,
        state: AgentAvatarState,
        pose: AgentAvatarChoreography.Pose,
        in context: inout GraphicsContext,
        size canvas: CGSize
    ) {
        let side = min(canvas.width, canvas.height)
        let centre = CGPoint(x: side / 2, y: side / 2)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)

        // The head carries every layer, so the tilt and the drift are applied once, here,
        // and the eyes move inside it.
        context.drawLayer { head in
            head.translateBy(
                x: centre.x + pose.drift.width * side,
                y: centre.y + pose.drift.height * side
            )
            head.rotate(by: .degrees(pose.tilt))
            head.translateBy(x: -centre.x, y: -centre.y)

            head.draw(Image(nsImage: layers.under), in: rect)

            // A blink is a compression about the canvas centre, which is where every
            // vendored eye part centres its ink — see `NotionAvatarLayers.eyeAnchor`.
            head.drawLayer { eyes in
                eyes.translateBy(
                    x: centre.x + pose.gaze.width * side,
                    y: centre.y + pose.gaze.height * side
                )
                eyes.scaleBy(x: 1, y: max(0.02, 1 - pose.blink))
                eyes.translateBy(x: -centre.x, y: -centre.y)
                eyes.draw(Image(nsImage: layers.eyes), in: rect)
            }

            head.drawLayer { brows in
                brows.translateBy(x: 0, y: -pose.brow * side)
                brows.draw(Image(nsImage: layers.brows), in: rect)
            }

            head.draw(Image(nsImage: layers.over), in: rect)
        }

        if state == .listening {
            drawListeningRings(in: &context, side: side, phase: pose.phase)
        }
    }

    /// Two rings arriving inward from the rim, half a loop apart. Inward rather than
    /// outward because the portrait is a circle and outward rings would be clipped — and
    /// because waves *arriving* is the truer picture of a microphone that is open.
    private func drawListeningRings(in context: inout GraphicsContext, side: CGFloat, phase: Double) {
        for index in 0..<2 {
            let progress = (phase + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
            let radius = side * (0.50 - 0.14 * progress)
            let opacity = DS.Opacity.avatarRing * (1 - progress)
            guard opacity > 0.01 else { continue }
            context.stroke(
                Path(ellipseIn: CGRect(
                    x: side / 2 - radius,
                    y: side / 2 - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(ink.opacity(opacity)),
                lineWidth: DS.Size.avatarRingWidth
            )
        }
    }
}

extension AgentAvatarState {
    /// What the still orb says when the assets are missing — the nearest state in the nine,
    /// never a tenth invented for a fallback.
    var fallbackOrb: OrbGeometry.State {
        switch self {
        case .idle, .waiting, .sleeping, .done: .breathing
        case .listening: .listening
        case .thinking, .browsing: .searching
        case .writing: .composing
        case .tool: .working
        case .sending: .connecting
        }
    }

    /// The states whose clock is a slow metronome rather than the display: nothing is being
    /// waited on, so a fifth of the frames loses nothing and saves the window the rest.
    var isAmbient: Bool {
        switch self {
        case .idle, .waiting, .sleeping: true
        case .listening, .thinking, .browsing, .writing, .tool, .sending, .done: false
        }
    }
}

/// The state's gadget: an SF Symbol in a small tinted badge on the portrait's shoulder.
///
/// Every prop has one motion and it is the motion of the thing it is a picture of — a
/// wrench turns, Z's rise, a plane leaves. Nothing loops a *position* it cannot justify;
/// the phases are the state's own, so a prop cannot be busy while its state is asleep.
private struct AvatarPropBadge: View {
    let prop: AgentAvatarChoreography.Prop
    let side: CGFloat
    let phase: Double
    let ink: Color

    var body: some View {
        ZStack {
            Circle().fill(ink.opacity(DS.Opacity.avatarPropFill))
            symbol
                .font(.system(size: diameter * DS.Size.avatarPropGlyphFraction, weight: .semibold))
                .foregroundStyle(ink)
        }
        .frame(width: diameter, height: diameter)
        .offset(x: side * DS.Size.avatarPropOffsetFraction, y: side * DS.Size.avatarPropOffsetFraction)
        .accessibilityHidden(true)
    }

    private var diameter: CGFloat { side * DS.Size.avatarPropFraction }

    @ViewBuilder
    private var symbol: some View {
        switch prop {
        case .rings:
            // Drawn on the portrait's own canvas, not in the badge.
            EmptyView()

        case .keyboard:
            // The little computer, tapping: a small bob at typing speed.
            glyph
                .offset(y: -diameter * 0.05 * (0.5 + 0.5 * sin(2 * .pi * 3 * phase)))

        case .globe:
            // Looking something up: a page that scans left and right as it reads.
            glyph
                .rotationEffect(.degrees(10 * sin(2 * .pi * phase)))

        case .code:
            glyph
                .scaleEffect(0.94 + 0.08 * (0.5 + 0.5 * sin(2 * .pi * 2 * phase)))

        case .wrench:
            glyph
                .rotationEffect(.degrees(16 * sin(2 * .pi * phase)))

        case .plane:
            // Leaves the frame above the shoulder and starts again — a launch, not a loop
            // that flies backwards.
            glyph
                .offset(x: diameter * 0.7 * phase, y: -diameter * 1.1 * phase)
                .opacity(1 - phase)

        case .hourglass:
            glyph
                .scaleEffect(y: phase < 0.5 ? 1 : -1, anchor: .center)

        case .zzz:
            glyph
                .offset(y: -diameter * 0.6 * phase)
                .opacity(1 - phase)

        case .check:
            // Draws itself once at a rate slow enough that it does not pulse: `done` is the
            // one state a run ends on, not a spinner.
            glyph
                .scaleEffect(phase < 0.2 ? phase / 0.2 : 1)
        }
    }

    private var glyph: some View {
        Image(systemName: prop.symbolName)
    }
}
