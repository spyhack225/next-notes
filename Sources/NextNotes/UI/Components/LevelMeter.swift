import SwiftUI

/// A VU meter with a real needle, drawn flat.
///
/// The needle is damped rather than driven directly from the signal: a physical VU movement
/// takes ~300ms to reach a step and overshoots slightly before settling, and that lag is the
/// instrument's character. Tracking the level exactly would produce a twitching line that
/// reads as a progress bar with a stick on it.
struct LevelMeter: View {
    /// Current input level, 0...1.
    let level: Float
    var isActive: Bool

    /// The needle's physical state lives in a plain reference type, deliberately *not* in
    /// `@State`. The movement has to advance once per drawn frame, and SwiftUI state mutated
    /// inside a `Canvas` draw closure is a mutation during view update — which SwiftUI logs
    /// as undefined behavior and which, at 120fps, floods the process. A reference the view
    /// merely holds is invisible to the state graph, so stepping it is safe.
    @State private var movement = NeedleMovement()

    /// The schedule's `paused:` argument is read only when the body re-evaluates, and
    /// `movement` is invisible to SwiftUI — so asking the movement whether it has come to
    /// rest would keep the timeline running forever after the first recording, redrawing at
    /// display rate on an idle window. This flag is ordinary observed state: it stays true
    /// for as long as the needle needs to fall back to zero, and clearing it re-evaluates
    /// the body once and parks the schedule.
    @State private var isSettling = false

    private final class NeedleMovement {
        var position: Double = 0
        var velocity: Double = 0
    }

    var body: some View {
        TimelineView(.animation(paused: !isActive && !isSettling)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, at: timeline.date)
            }
        }
        .task(id: isActive) {
            if isActive {
                isSettling = true
                return
            }
            try? await Task.sleep(for: .seconds(DS.Motion.needleSettle))
            isSettling = false
        }
        .background(DS.Color.content)
        .overlay(
            Rectangle()
                .fill(DS.Color.accent)
                .opacity(isActive ? DS.Opacity.meterActiveTint : 0)
                .animation(DS.Motion.standard, value: isActive)
        )
        .clipShape(.rect(cornerRadius: DS.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.separator, lineWidth: DS.Border.hairline)
        )
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, at date: Date) {
        advanceNeedle()

        let pivot = CGPoint(x: size.width / 2, y: size.height * 1.05)
        let radius = min(size.width * 0.46, size.height * 0.92)
        let sweep = DS.Meter.needleSweep.radians

        // Scale arc, with the over zone past 0 VU.
        for tick in stride(from: 0.0, through: 1.0, by: 0.1) {
            let angle = -sweep / 2 + sweep * tick
            let isOver = tick >= DS.Meter.zeroPoint
            let isMajor = tick.truncatingRemainder(dividingBy: 0.2) < 0.01
            let inner = radius * (isMajor ? DS.Meter.tickMajorInset : DS.Meter.tickMinorInset)
            var path = Path()
            path.move(to: point(from: pivot, angle: angle, distance: inner))
            path.addLine(to: point(from: pivot, angle: angle, distance: radius))
            context.stroke(
                path,
                with: .color(isOver ? DS.Color.meterPeak : DS.Color.meterTrack),
                lineWidth: DS.Border.hairline
            )
        }

        // Needle.
        let angle = -sweep / 2 + sweep * movement.position
        var needlePath = Path()
        needlePath.move(to: pivot)
        needlePath.addLine(to: point(from: pivot, angle: angle, distance: radius * DS.Meter.needleLength))
        context.stroke(
            needlePath,
            with: .color(DS.Color.meterNeedle),
            lineWidth: DS.Border.needle
        )
    }

    /// Critically-damped-ish spring toward the target, tuned to VU ballistics.
    private func advanceNeedle() {
        let target = isActive ? Double(min(max(level, 0), 1)) : 0
        let rising = target > movement.position
        let time = rising ? DS.Motion.needleAttack : DS.Motion.needleRelease
        // Frame-rate independent enough at 60–120Hz, and a meter is forgiving of the rest.
        let stiffness = 1 / time
        let delta = target - movement.position
        movement.velocity += delta * stiffness * 0.16
        movement.velocity *= 0.72
        movement.position += movement.velocity
        movement.position = min(max(movement.position, 0), 1 + DS.Motion.needleOvershoot)
    }

    private func point(from origin: CGPoint, angle: Double, distance: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x + sin(angle) * distance,
            y: origin.y - cos(angle) * distance
        )
    }
}

/// A horizontal bar meter with a peak-hold tick.
///
/// For places a needle doesn't fit: the HUD, and the stacked You / Others meters in a live
/// meeting. Green, yellow and red segments are the one place those colours appear as
/// chrome — they're instrumentation, which is the exception the design system allows.
struct LevelBar: View {
    let level: Float
    var isActive: Bool = true

    /// Same reasoning as `LevelMeter.movement`: stepped per frame, invisible to SwiftUI.
    @State private var movement = BarMovement()

    /// Same reason as `LevelMeter.isSettling`: `paused:` is captured at body evaluation, so
    /// the fall to rest is timed by observed state rather than read off the movement.
    @State private var isSettling = false

    private final class BarMovement {
        var position: Double = 0
        var peak: Double = 0
        var peakSetAt: TimeInterval = 0
    }

    var body: some View {
        TimelineView(.animation(paused: !isActive && !isSettling)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, at: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .task(id: isActive) {
            if isActive {
                isSettling = true
                return
            }
            try? await Task.sleep(for: .seconds(DS.Motion.barSettle))
            isSettling = false
        }
        .frame(height: DS.Size.levelBarHeight)
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, at now: TimeInterval) {
        advance(at: now)

        let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
        context.fill(track, with: .color(DS.Color.meterTrack))

        let position = movement.position
        fill(&context, from: 0, to: min(position, DS.Meter.hotPoint), size: size, color: DS.Color.meterNominal)
        if position > DS.Meter.hotPoint {
            fill(&context, from: DS.Meter.hotPoint, to: min(position, DS.Meter.peakPoint), size: size, color: DS.Color.meterHot)
        }
        if position > DS.Meter.peakPoint {
            fill(&context, from: DS.Meter.peakPoint, to: position, size: size, color: DS.Color.meterPeak)
        }

        if movement.peak > 0.01 {
            let x = size.width * movement.peak - DS.Size.levelBarPeakWidth
            let tick = Path(CGRect(x: max(0, x), y: 0, width: DS.Size.levelBarPeakWidth, height: size.height))
            let color = movement.peak > DS.Meter.peakPoint ? DS.Color.meterPeak
                : movement.peak > DS.Meter.hotPoint ? DS.Color.meterHot
                : DS.Color.meterNominal
            context.fill(tick, with: .color(color))
        }
    }

    private func fill(_ context: inout GraphicsContext, from: Double, to: Double, size: CGSize, color: Color) {
        guard to > from else { return }
        let rect = CGRect(x: size.width * from, y: 0, width: size.width * (to - from), height: size.height)
        context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
        context.fill(Path(rect), with: .color(color))
    }

    private func advance(at now: TimeInterval) {
        let target = isActive ? Double(min(max(level, 0), 1)) : 0
        let rising = target > movement.position
        let time = rising ? DS.Motion.barAttack : DS.Motion.barRelease
        let alpha = min(1, 0.016 / time)
        movement.position += (target - movement.position) * alpha

        if movement.position >= movement.peak {
            movement.peak = movement.position
            movement.peakSetAt = now
        } else if now - movement.peakSetAt > DS.Motion.peakHold {
            movement.peak = max(movement.position, movement.peak - 0.02)
        }
    }
}
