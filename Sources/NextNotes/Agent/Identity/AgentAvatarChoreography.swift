import CoreGraphics
import Foundation

/// How the character moves while it is in a state.
///
/// This file is the animation *specification*, not the drawing: every pose is a pure
/// function of (`state`, `time`), the way `OrbGeometry` is a pure function of (`state`,
/// `size`). The view adds nothing but pixels, which is what lets `--selftest-avatar` hold
/// the whole vocabulary still and read it: that two states never produce the same pose,
/// that no tuning runs away, and that Reduce Motion has one representative frame to draw.
///
/// The picture is a portrait, so the verbs are small and human — a breath, a blink, a
/// glance, the head following the eyes. Amplitudes are fractions of the avatar's side
/// except `tilt`, which is degrees. Restraint is the design: at 24 points a two-degree
/// tilt is visible and a six-degree one is a cartoon.
enum AgentAvatarChoreography {
    /// One frozen pose of the character: everything the view is allowed to move.
    struct Pose: Equatable, Sendable {
        /// Head roll in degrees. Positive tilts towards the trailing edge.
        var tilt: Double = 0
        /// Head travel, as a fraction of the avatar's side.
        var drift: CGSize = .zero
        /// 0 open … 1 shut. The eyes layer is compressed about the canvas centre.
        var blink: Double = 0
        /// Eye travel inside the head, as a fraction of the side.
        var gaze: CGSize = .zero
        /// Brows lifted, as a fraction of the side. Positive is interest, negative is
        /// concentration.
        var brow: Double = 0
        /// 0…1 through the state's own loop — what a prop's motion is phase-locked to.
        var phase: Double = 0
    }

    /// The tuning behind one state. Bounds are asserted by the self-test rather than
    /// trusted; see `AgentAvatarSelfTest`.
    struct Motion: Equatable, Sendable {
        /// Head-roll amplitude, in degrees, and its rate in cycles per second.
        var tilt: Double = 0
        var tiltRate: Double = 0
        /// Head-travel amplitude (fraction of the side) and its rate.
        var drift: Double = 0
        var driftRate: Double = 0
        /// Eye-travel amplitudes and rate. Zero means the eyes hold still.
        var gazeX: Double = 0
        var gazeY: Double = 0
        var gazeRate: Double = 0
        /// A held brow position for the whole state, not an oscillation.
        var brow: Double = 0
        /// Seconds between blinks, and whether the eyes are simply shut all the way through
        /// (sleep is not a long blink).
        var blinkPeriod: Double = 4.4
        var eyesClosed = false
        /// Rate of the prop's own loop, in cycles per second. Unused without a prop.
        var phaseRate: Double = 0.2
        /// One damped dip of the head, for the state that ends a run.
        var nods = false
    }

    /// The gadget the state works with — the laptop in the reference's lap, reduced to a
    /// badge. Drawn by the view; named here so the state and its picture cannot drift, and
    /// so `--selftest-avatar` can prove each symbol still resolves.
    enum Prop: String, CaseIterable, Sendable {
        /// Rings leaving the portrait's rim: it is hearing something. Drawn on the
        /// portrait's canvas rather than in the badge, so it has a symbol only as a
        /// fallback.
        case rings
        /// The little computer, typing at the bottom of the frame.
        case keyboard
        /// Looking something up — a page that scans as it reads.
        case globe
        /// A card of code lines, still being typed.
        case code
        /// A wrench, turning.
        case wrench
        /// A paper plane on its arc, leaving the frame.
        case plane
        /// An hourglass, turned when it runs out.
        case hourglass
        /// Z's rising off a sleeping head.
        case zzz
        /// A check that draws itself once.
        case check

        /// The SF Symbol that draws this prop. A name, not a measurement: the view sizes
        /// and animates it.
        var symbolName: String {
            switch self {
            case .rings: "waveform"
            case .keyboard: "laptopcomputer"
            case .globe: "globe"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .wrench: "wrench.adjustable"
            case .plane: "paperplane.fill"
            case .hourglass: "hourglass"
            case .zzz: "zzz"
            case .check: "checkmark"
            }
        }

        /// Whether the view draws this one on the portrait's own canvas.
        var isDrawnOnCanvas: Bool { self == .rings }
    }

    /// The frame Reduce Motion freezes on, shared with the orbs: not zero, because every
    /// state's cycle should read as a diagram rather than as motion caught mid-frame.
    static let stillFrame: Double = 1.7

    /// How long the eyes stay shut, in seconds. Short enough to read as a blink at any
    /// period, long enough to be drawn at all on a 20 Hz clock.
    static let blinkDuration: Double = 0.12

    // MARK: - Poses

    /// The pose of `state` at `time`, in seconds since the avatar's own epoch.
    ///
    /// Each state gets a fixed phase offset of its own, so two avatars working side by side
    /// are never in lockstep — and a state's signature stays its own at any sampled instant.
    static func pose(_ state: AgentAvatarState, at time: Double) -> Pose {
        let motion = motion(state)
        let offset = phaseOffset(state)

        var pose = Pose()
        pose.tilt = motion.tilt * sin(2 * .pi * motion.tiltRate * time + offset)
        pose.drift = CGSize(
            width: motion.drift * 0.6 * sin(2 * .pi * motion.driftRate * time + offset * 1.3),
            height: motion.drift * sin(2 * .pi * motion.driftRate * 0.8 * time + offset)
        )
        pose.gaze = CGSize(
            width: motion.gazeX * sin(2 * .pi * motion.gazeRate * time + offset),
            height: motion.gazeY * sin(2 * .pi * motion.gazeRate * 0.7 * time + offset * 1.7)
        )
        pose.blink = motion.eyesClosed
            ? 1
            : blink(at: time, period: motion.blinkPeriod, offset: offset)
        pose.brow = motion.brow
        pose.phase = phase(at: time, rate: motion.phaseRate)
        if motion.nods {
            pose.drift.height += nod(at: time)
        }
        return pose
    }

    /// The tuning for a state. A table rather than a formula, so it can be read as one.
    static func motion(_ state: AgentAvatarState) -> Motion {
        switch state {
        case .idle:
            // Barely there: a breath at about one every nine seconds, and a glance that
            // wanders. The pose a portrait is in when nothing is being asked of it.
            return Motion(tilt: 0.8, tiltRate: 0.11, drift: 0.005, driftRate: 0.07,
                          gazeX: 0.006, gazeY: 0.002, gazeRate: 0.05,
                          blinkPeriod: 4.4, phaseRate: 0.18)

        case .listening:
            // Attention: a faster, larger sway, brows up a little, and no glance at all —
            // the eyes hold on the person. The rings prop carries the hearing itself.
            return Motion(tilt: 2.0, tiltRate: 0.26, drift: 0.006, driftRate: 0.30,
                          brow: 0.012, blinkPeriod: 5.0, phaseRate: 0.55)

        case .thinking:
            // Looking up and to the side, the way a person does mid-sentence, with a slow
            // sway underneath. Brows a hair down: this is concentration, not surprise.
            return Motion(tilt: 1.6, tiltRate: 0.15, drift: 0.006, driftRate: 0.11,
                          gazeX: 0.012, gazeY: -0.014, gazeRate: 0.08, brow: -0.004,
                          blinkPeriod: 3.6, phaseRate: 0.30)

        case .browsing:
            // The eyes sweep left and right across something being read, and the head
            // follows a little. Faster than idle, smaller than listening.
            return Motion(tilt: 1.8, tiltRate: 0.22, drift: 0.006, driftRate: 0.16,
                          gazeX: 0.020, gazeRate: 0.16, blinkPeriod: 4.0, phaseRate: 0.45)

        case .writing:
            // Head down, eyes down, and a small quick bob — the rhythm of the keyboard,
            // which the `code` prop is drawing lines to.
            return Motion(tilt: 0.6, tiltRate: 0.9, drift: 0.003, driftRate: 1.1,
                          gazeY: 0.010, blinkPeriod: 5.0, phaseRate: 1.3)

        case .tool:
            // Working with its hands: a busier bob than thinking and a fixed slight lean,
            // with the gaze on what is being changed.
            return Motion(tilt: 1.1, tiltRate: 0.5, drift: 0.004, driftRate: 0.5,
                          gazeX: 0.004, gazeY: 0.004, gazeRate: 0.1,
                          blinkPeriod: 4.6, phaseRate: 0.9)

        case .sending:
            // The one state that looks outward: head up a fraction, gaze out and up, brows
            // slightly raised. The plane leaves the frame above it.
            return Motion(tilt: 1.3, tiltRate: 0.13, drift: 0.006, driftRate: 0.10,
                          gazeX: 0.014, gazeY: -0.010, gazeRate: 0.06, brow: 0.005,
                          blinkPeriod: 5.6, phaseRate: 0.28)

        case .waiting:
            // Held, not working: the slowest breath in the table, no glance, no brow. If
            // there is a difference between patience and sleep, this is it — and the eyes
            // are still open.
            return Motion(tilt: 0.7, tiltRate: 0.07, drift: 0.004, driftRate: 0.06,
                          blinkPeriod: 4.2, phaseRate: 0.10)

        case .sleeping:
            // Eyes shut, brows down, and a head that spends most of a half-minute cycle
            // tilted over. The Z's carry the rest.
            return Motion(tilt: 3.2, tiltRate: 0.035, drift: 0.003, driftRate: 0.03,
                          brow: -0.010, blinkPeriod: 0, eyesClosed: true, phaseRate: 0.12)

        case .done:
            // One damped nod, then it stands still — a loop here would celebrate forever,
            // and the run is over. The slow phase is what makes the check draw itself
            // rather than pulse: at a working rate a checkmark blinking on and off is a
            // spinner wearing a tick.
            return Motion(tilt: 1.0, tiltRate: 0.14, drift: 0.004, driftRate: 0.10,
                          brow: 0.006, blinkPeriod: 4.8, phaseRate: 0.05, nods: true)
        }
    }

    /// The gadget a state works with, or none for the states that are between things.
    static func prop(_ state: AgentAvatarState) -> Prop? {
        switch state {
        case .idle: nil
        case .listening: .rings
        case .thinking: .keyboard
        case .browsing: .globe
        case .writing: .code
        case .tool: .wrench
        case .sending: .plane
        case .waiting: .hourglass
        case .sleeping: .zzz
        case .done: .check
        }
    }

    // MARK: - The pieces

    /// 0 open, 1 shut. A raised-cosine over `blinkDuration`, repeated every `period` —
    /// smooth at both ends, so the eyes never snap.
    static func blink(at time: Double, period: Double, offset: Double = 0) -> Double {
        guard period > 0 else { return 0 }
        let position = (time + offset * period).truncatingRemainder(dividingBy: period)
        guard position < blinkDuration else { return 0 }
        return sin(position / blinkDuration * .pi)
    }

    /// 0…1, wrapping. The phase a prop draws itself against.
    static func phase(at time: Double, rate: Double) -> Double {
        let value = (rate * time).truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }

    /// The finished run's single nod: a dip in the first half-second that damps out before
    /// two seconds are up, so a reply that sits on screen for eight does not keep bowing.
    static func nod(at time: Double) -> Double {
        guard time >= 0, time < 2 else { return 0 }
        return -0.024 * sin(2 * .pi * 1.1 * time) * exp(-1.6 * time)
    }

    /// A fixed per-state offset, from the declaration order — stable across launches, so
    /// the self-test's sampled signatures mean the same thing every run.
    static func phaseOffset(_ state: AgentAvatarState) -> Double {
        let index = AgentAvatarState.allCases.firstIndex(of: state) ?? 0
        return Double(index) * 0.37
    }
}
