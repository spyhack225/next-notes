import CoreGraphics
import Foundation

/// The dot geometry behind `ThinkingOrb`, ported from **thinking-orbs**.
///
/// Original: https://github.com/Jakubantalik/thinking-orbs — MIT © 2026 Jakub Antalik.
/// That project ships a TypeScript engine and a React Native port; the SwiftUI port its
/// README promises does not exist in the repository, so all nine of its modes are re-derived
/// here from `src/engine/` under the same licence. The maths is deliberately the original's,
/// down to the tuned constants, so an orb here looks like an orb there.
///
/// Each mode is a pure function of `(size, time)` returning finished draw instructions —
/// position, radius and opacity, already sorted back to front. Nothing is re-derived at
/// paint time, which is what lets `ThinkingOrb` draw the list in a `Canvas` without
/// touching a single number, and what lets `--selftest-orb` check the geometry without a
/// screen. Nothing is random either: the one mode that scatters (`solving`'s scramble) and
/// the one that re-picks pairs (`connecting`'s packets) both read a deterministic hash of an
/// index, so the same instant always yields the same frame.
///
/// The tuning tables below are literals on purpose. They are vendored data — the upstream
/// presets resolved through its own count/radius multipliers — not view constants, in the
/// same way `MeetingScheduler.tickInterval` is not a `DS` token. What a *view* chooses is
/// only which preset and how large to draw it, and both of those are `DS` tokens.
enum OrbGeometry {

    /// What an agent is doing, in the orb's vocabulary.
    enum State: String, CaseIterable, Sendable {
        /// A waveform rolls through the rings.
        case listening
        /// Particles run tilted orbits.
        case working
        /// An undulating multi-band sash.
        case composing
        /// A scan meridian sweeps a dotted globe.
        case searching
        /// Bands scramble in quarter turns, then click back.
        case solving
        /// A constellation wires itself, packets running the edges.
        case connecting
        /// Three strands plait around the sphere.
        case weaving
        /// A face-on ring, slowly morphing.
        case breathing
        /// A dotted outline works its way from circle to triangle to square.
        case shaping

        /// What a screen reader is told, when the caller has nothing better to say.
        var accessibilityLabel: String {
            switch self {
            case .listening: "Listening"
            case .working: "Working"
            case .composing: "Writing"
            case .searching: "Searching"
            case .solving: "Solving"
            case .connecting: "Connecting"
            case .weaving: "Weaving"
            case .breathing: "Thinking"
            case .shaping: "Shaping"
            }
        }
    }

    /// One finished mark: where, how big, how heavily inked.
    struct Dot: Sendable {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        /// 0…1 against the caller's ink colour. Depth is carried by this and by `radius`
        /// alone — there are no filters, no gradients and no second colour anywhere.
        let opacity: Double
    }

    /// One finished edge: a straight stroke between two projected points.
    ///
    /// Only `connecting` draws these — a constellation whose nodes are not joined up is
    /// just a sphere of dots, and the joining is the whole state. Every edge in a frame
    /// carries the same `width`, and the same one ink as the dots.
    struct Segment: Sendable {
        let x1: CGFloat
        let y1: CGFloat
        let x2: CGFloat
        let y2: CGFloat
        let width: CGFloat
        /// 0…1 against the caller's ink colour, exactly as `Dot.opacity`.
        let opacity: Double
    }

    /// One instant, complete: the edges to stroke first, then the dots to fill over them.
    struct Frame: Sendable {
        /// In draw order, far to near.
        let dots: [Dot]
        /// Empty for every state but `connecting`.
        let segments: [Segment]
    }

    /// A frame of dots in draw order, far to near.
    ///
    /// The dots are the entire picture for eight of the nine states, so this stays the
    /// short way to ask. A caller that also wants `connecting`'s edges asks `fullFrame`.
    static func frame(for state: State, size: CGFloat, time: Double, inline: Bool) -> [Dot] {
        fullFrame(for: state, size: size, time: time, inline: inline).dots
    }

    /// Everything one instant draws: edges and dots, both finished.
    static func fullFrame(for state: State, size: CGFloat, time: Double, inline: Bool) -> Frame {
        let preset = preset(for: state, inline: inline)
        let t = time * preset.speed
        let raw: [Raw]
        var lines: [RawLine] = []
        switch state {
        case .working: raw = orbits(size: Double(size), t: t, o: preset)
        case .searching: raw = globe(size: Double(size), t: t, o: preset)
        case .listening: raw = wave(size: Double(size), t: t, o: preset)
        // `breathing` is `composing`'s geometry seen face on — see `ribbon`.
        case .composing, .breathing: raw = ribbon(size: Double(size), t: t, o: preset)
        case .solving: raw = rubik(size: Double(size), t: t, o: preset)
        case .weaving: raw = braid(size: Double(size), t: t, o: preset)
        case .shaping: raw = morph(size: Double(size), t: t, o: preset)
        case .connecting:
            let built = web(size: Double(size), t: t, o: preset)
            raw = built.dots
            lines = built.lines
        }
        return Frame(dots: finalize(raw, rMin: preset.rMin), segments: finalize(lines))
    }

    // MARK: - Tuning

    /// One resolved (state, size) tuning: the upstream base profile with its preset's
    /// count and radius multipliers already applied.
    struct Preset: Sendable {
        var speed: Double
        var rsPow: Double = 0.6
        var rMin: Double = 0.3

        // orbits
        var orbitN = 12
        var ghostN = 40
        var ghostR = 0.9
        var ghostA = 0.5
        var particles = 3
        var partR = 1.2
        var partRDepth = 1.6

        // sphere lattices (globe, wave, rubik)
        var latRings = 17
        var lonDensity = 44
        var rBase = 0.6
        var rDepth = 1.7
        var rBoost = 1.0
        var inkFar = 0.62
        var inkSpan = 0.54
        var scanMul = 1.0
        var dimBase = 1.0
        var moveCount = 14
        var rActive = 0.3

        // ribbon (and ring, which is the same band seen face on)
        var lanes = 5
        var segs = 88
        var bandMul = 1.0
        var wobMul = 1.0
        var spin = 1.0
        var faceOn = false

        // web
        var nodeN = 30
        var thr = 0.72
        var signals = 5
        var nodeR = 1.4
        var nodeRDepth = 1.8
        var lineW = 0.8
        /// How far the figure spreads inside its box. Read by `web` and by `morph`.
        var spread = 1.0

        // braid
        var strandN = 52
        var turns = 3.0

        // morph
        var rDot = 0.021
        var iconD = 1.0
    }

    /// The two shipped sizes are separate designs rather than one scaled: the inline orb
    /// carries a tenth of the dots at twice the radius, because a 20pt copy of the 64pt
    /// tuning is a grey smudge.
    static func preset(for state: State, inline: Bool) -> Preset {
        switch (state, inline) {
        case (.working, false):
            Preset(speed: 1.885)
        case (.working, true):
            Preset(speed: 3.9, orbitN: 3, ghostN: 10, ghostR: 2.16, partR: 2.88, partRDepth: 3.84)
        case (.searching, false):
            Preset(
                speed: 2.015, latRings: 11, lonDensity: 29, rBase: 0.69, rDepth: 1.955,
                rBoost: 1.15, scanMul: 4.08, dimBase: 0.45
            )
        case (.searching, true):
            Preset(
                speed: 2.665, latRings: 6, lonDensity: 14, rBase: 1.05, rDepth: 2.975,
                rBoost: 1.75, scanMul: 4.335, dimBase: 0.45
            )
        case (.listening, false):
            Preset(speed: 4.388, latRings: 9, lonDensity: 23)
        case (.listening, true):
            Preset(speed: 3.998, latRings: 5, lonDensity: 13, rBase: 0.96, rDepth: 2.72)
        case (.composing, false):
            Preset(
                speed: 2.34, ghostN: 38, rBase: 0.935, rDepth: 1.445,
                lanes: 3, segs: 44, bandMul: 3.9, spin: 0
            )
        case (.composing, true):
            Preset(
                speed: 3.12, ghostN: 8, rBase: 1.1803, rDepth: 1.8241,
                lanes: 2, segs: 20, bandMul: 4.94, spin: 0
            )
        case (.solving, false):
            Preset(
                speed: 1.82, latRings: 9, lonDensity: 24, rBase: 0.63, rDepth: 1.785,
                moveCount: 14, rActive: 0.315
            )
        case (.solving, true):
            Preset(
                speed: 1.95, latRings: 4, lonDensity: 12, rBase: 1.14, rDepth: 3.23,
                moveCount: 14, rActive: 0.57
            )
        case (.connecting, false):
            Preset(speed: 3.315, nodeN: 41, signals: 7, nodeR: 1.33, nodeRDepth: 1.71)
        case (.connecting, true):
            Preset(speed: 6.63, nodeN: 8, signals: 1, nodeR: 2.128, nodeRDepth: 2.736)
        case (.weaving, false):
            Preset(speed: 1.625, ghostN: 75, rBase: 1.2, rDepth: 1.8, strandN: 26)
        case (.weaving, true):
            Preset(speed: 2.75, ghostN: 17, rBase: 1.632, rDepth: 2.448, strandN: 6)
        case (.breathing, false):
            Preset(
                speed: 3.24, ghostN: 0, rBase: 1.0516, rDepth: 1.6252,
                lanes: 3, segs: 44, bandMul: 3.627, wobMul: 0.368, spin: 0, faceOn: true
            )
        case (.breathing, true):
            Preset(
                speed: 3.78, ghostN: 0, rBase: 1.7842, rDepth: 2.7574,
                lanes: 2, segs: 15, bandMul: 3.968, wobMul: 0.565, spin: 0, faceOn: true
            )
        case (.shaping, false):
            Preset(speed: 2.405, rMin: 0.25, spread: 1.45, rDot: 0.008295, iconD: 0.702)
        case (.shaping, true):
            Preset(speed: 2.08, rMin: 0.25, spread: 1.45, rDot: 0.021231, iconD: 0.53)
        }
    }

    // MARK: - Modes

    /// Position, depth, radius and ink before the frame is finished.
    private struct Raw {
        var x: Double
        var y: Double
        var z: Double
        var r: Double
        /// The upstream ink convention: 0 is the darkest mark. Inverted on the way out, so
        /// the caller's semantic ink colour reads correctly in either appearance.
        var white: Double
        var alpha: Double = 1
    }

    /// An edge before the frame is finished. Same ink convention as `Raw`.
    private struct RawLine {
        var x1: Double
        var y1: Double
        var x2: Double
        var y2: Double
        var white: Double
        var alpha: Double = 1
        var width: Double
    }

    /// Particles on tilted orbits — `working`. No nucleus: the tuned preset runs coreless,
    /// so what you see is ghost paths and the particles doing the work.
    private static func orbits(size: Double, t: Double, o: Preset) -> [Raw] {
        let centre = size / 2
        let radius = (size / 2) * 0.82
        let project = Projection(yaw: t * 0.12, tilt: 0.3, cx: centre, cy: centre, scale: 1)
        let rs = radiusScale(size, o.rsPow)

        var dots: [Raw] = []
        dots.reserveCapacity(o.orbitN * (o.ghostN + o.particles))

        for orb in 0..<o.orbitN {
            let h1 = hash(Double(orb), 1.7)
            let h2 = hash(Double(orb), 5.2)
            let h3 = hash(Double(orb), 8.9)
            let ro = radius * (0.45 + 0.52 * h1)
            let theta = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)

            // The orbit plane, as two perpendicular unit vectors in it.
            let nx = sin(phi) * cos(theta)
            let ny = cos(phi)
            let nz = sin(phi) * sin(theta)
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let ul = max(1e-6, (ux * ux + uy * uy).squareRoot())
            ux /= ul
            uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            for k in 0..<o.ghostN {
                let a = (Double(k) / Double(o.ghostN)) * 2 * .pi
                let p = project(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro
                )
                let depth = (p.z / ro + 1) / 2
                dots.append(Raw(
                    x: p.x, y: p.y, z: p.z,
                    r: o.ghostR * rs,
                    white: 0.72,
                    alpha: o.ghostA * (0.4 + 0.6 * depth)
                ))
            }

            for m in 0..<o.particles {
                let a = t * speed + (Double(m) / Double(o.particles)) * 2 * .pi + h2 * 6
                let p = project(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro
                )
                let depth = (p.z / ro + 1) / 2
                dots.append(Raw(
                    x: p.x, y: p.y, z: p.z,
                    r: (o.partR + o.partRDepth * depth) * rs,
                    white: 0.3 - 0.22 * depth
                ))
            }
        }
        return dots
    }

    /// A lat/long field with a scan meridian sweeping through it — `searching`. The scan is
    /// read as a size ripple rather than a highlight, because there is only one ink.
    private static func globe(size: Double, t: Double, o: Preset) -> [Raw] {
        let spin = 0.5
        let centre = size / 2
        let radius = (size / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let project = Projection(yaw: t * spin, tilt: tilt, cx: centre, cy: centre, scale: radius)
        let scan = t * (spin + (1.7 - spin) * o.scanMul)
        let rs = radiusScale(size, o.rsPow)

        var dots: [Raw] = []
        for li in 0...o.latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(o.latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * Double(o.lonDensity)).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let p = project(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let depth = (p.z + 1) / 2
                let d = angleDelta(lon + t * spin, scan)
                let boost = exp(-(d * d) / 0.18) * max(0, p.z)
                dots.append(Raw(
                    x: p.x, y: p.y, z: p.z,
                    r: (o.rBase + o.rDepth * depth + o.rBoost * boost) * rs,
                    white: o.inkFar - o.inkSpan * depth,
                    alpha: o.dimBase + (1 - o.dimBase) * min(1, boost)
                ))
            }
        }
        return dots
    }

    /// A waveform rolling through the rings — `listening`. Two waves at different tempi, so
    /// it never quite repeats.
    private static func wave(size: Double, t: Double, o: Preset) -> [Raw] {
        let centre = size / 2
        // 0.76 × 1.15: the undulation pulls the sphere inward, so this mode reads smaller
        // than the other lattices unless it is scaled back up to match them.
        let radius = (size / 2) * 0.874
        let project = Projection(yaw: t * 0.18, tilt: 0.38, cx: centre, cy: centre, scale: 1)
        let rs = radiusScale(size, o.rsPow)

        var dots: [Raw] = []
        for ri in 0...o.latRings {
            let lat = -Double.pi / 2 + (Double(ri) / Double(o.latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let w = 0.62 * sin(t * 2.1 - Double(ri) * 0.52) + 0.38 * sin(t * 1.27 + Double(ri) * 0.83)
            let rr = radius * (0.88 + 0.105 * w)
            let lonCount = max(1, Int((abs(cosLat) * Double(o.lonDensity)).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let p = project(cosLat * cos(lon) * rr, sinLat * rr, cosLat * sin(lon) * rr)
                let depth = (p.z / radius + 1) / 2
                let crest = max(0, w)
                dots.append(Raw(
                    x: p.x, y: p.y, z: p.z,
                    r: (o.rBase + o.rDepth * depth) * (1 + 0.4 * crest) * rs,
                    white: 0.66 - 0.56 * depth - 0.1 * crest
                ))
            }
        }
        return dots
    }

    /// An undulating sash of parallel strands riding a great circle — `composing`. The
    /// tuned preset freezes the tumble (`spin == 0`), leaving the travelling wave.
    ///
    /// The same geometry is also `breathing`, through `faceOn`: the band's plane is tilted
    /// back by exactly the camera's own tilt so the great circle projects as a true circle
    /// rather than an ellipse, and the undulation moves onto the in-plane *radius*. That
    /// second move is the one that matters. A wobble along the plane normal is undone by the
    /// re-normalisation below — the point lands back on the sphere, so the silhouette is
    /// pinned at `radius` and the deformation can only ever pull dots inward. Modulating the
    /// radius instead lets the lobes genuinely swell out and pinch in, which is what makes a
    /// ring read as breathing rather than as a sash in orbit.
    private static func ribbon(size: Double, t: Double, o: Preset) -> [Raw] {
        let centre = size / 2
        let radius = (size / 2) * 0.78
        let camTilt = 0.3
        let project = Projection(
            yaw: t * 0.1 * o.spin, tilt: camTilt, cx: centre, cy: centre, scale: 1
        )
        let rs = radiusScale(size, o.rsPow)

        var dots: [Raw] = []
        for i in 0..<o.ghostN {
            let d = fibonacciDirection(i, o.ghostN)
            let p = project(d.0 * radius, d.1 * radius, d.2 * radius)
            let depth = (p.z / radius + 1) / 2
            dots.append(Raw(
                x: p.x, y: p.y, z: p.z, r: 0.8 * rs, white: 0.78, alpha: 0.1 + 0.22 * depth
            ))
        }

        let ya = t * 0.24 * o.spin
        let ta = o.faceOn ? -camTilt : 0.55 + 0.3 * sin(t * 0.18) * o.spin
        let ux = cos(ya)
        let uy = 0.0
        let uz = sin(ya)
        let vx = -uz * sin(ta)
        let vy = cos(ta)
        let vz = ux * sin(ta)
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx

        // Radial lobes swell past `radius`, so a face-on band pulls its base radius in by
        // most of the wobble amplitude: the silhouette then stays inside the frame however
        // far the deformation is pushed.
        let wobAmp = 0.23 * o.wobMul
        let baseR = o.faceOn ? radius / (1 + 0.85 * wobAmp) : radius

        let lanes = max(1, Int((Double(o.lanes) * o.bandMul).rounded()))
        for w in 0..<lanes {
            let laneOff = (Double(w) - Double(lanes - 1) / 2) * 0.075
            let edge = abs(Double(w) - Double(lanes - 1) / 2) / max(1, Double(lanes - 1) / 2)
            for k in 0..<o.segs {
                let a = (Double(k) / Double(o.segs)) * 2 * .pi
                let wob = (0.16 * sin(a * 3 - t * 1.7 + Double(w) * 0.22)
                    + 0.07 * sin(a * 5 + t * 1.1)) * o.wobMul
                let radial = o.faceOn ? 1 + wob : 1
                let off = o.faceOn ? laneOff : laneOff + wob
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = (x * x + y * y + z * z).squareRoot()
                let rr = baseR * radial
                let p = project((x / l) * rr, (y / l) * rr, (z / l) * rr)
                let depth = (p.z / radius + 1) / 2
                dots.append(Raw(
                    x: p.x, y: p.y, z: p.z,
                    r: (o.rBase + o.rDepth * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    alpha: 0.4 + 0.6 * depth
                ))
            }
        }
        return dots
    }

    /// A lattice whose bands twist in quarter turns — `solving`. Rapid eased moves scramble
    /// the sphere, then replay in reverse, so it always clicks back to solved before it
    /// rests and starts again. The band under the hand inks a touch darker.
    private static func rubik(size: Double, t: Double, o: Preset) -> [Raw] {
        let centre = size / 2
        let radius = (size / 2) * 0.82
        let project = Projection(
            yaw: t * 0.55, tilt: 0.35 + 0.1 * sin(t * 0.9), cx: centre, cy: centre, scale: radius
        )
        let rs = radiusScale(size, o.rsPow)
        let moves = twists(o.moveCount)
        let cycle = solveCycle(t, count: o.moveCount, slot: 0.42, rest: 1.2)

        var dots: [Raw] = []
        for li in 0...o.latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(o.latRings)) * .pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int((abs(cosLat) * Double(o.lonDensity)).rounded()))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let turned = applyTwists(
                    (cosLat * cos(lon), sinLat, cosLat * sin(lon)), moves, cycle
                )
                let p = project(turned.x, turned.y, turned.z)
                let depth = (p.z + 1) / 2
                dots.append(Raw(
                    x: p.x, y: p.y, z: p.z,
                    r: (o.rBase + o.rDepth * depth + (turned.inHand ? o.rActive : 0)) * rs,
                    white: o.inkFar - o.inkSpan * depth - (turned.inHand ? 0.14 : 0)
                ))
            }
        }
        return dots
    }

    /// A constellation wiring itself — `connecting`. Nodes drift over the sphere under slow
    /// value noise, any pair closer than `thr` grows an edge, and bright packets run between
    /// pairs the clock re-picks every couple of seconds.
    ///
    /// The only mode that returns edges as well as dots. A dots-only reading was tried and
    /// is a different picture entirely: without the wires it is a sphere of drifting points,
    /// which is `working` with the orbits taken away. The wires are the state.
    private static func web(size: Double, t: Double, o: Preset) -> (dots: [Raw], lines: [RawLine]) {
        let centre = size / 2
        let radius = (size / 2) * 0.8 * o.spread
        // The projection carries the radius as its scale, so the node vectors stay unit
        // length and the proximity test below is in unit-sphere space.
        let project = Projection(yaw: t * 0.12, tilt: 0.32, cx: centre, cy: centre, scale: radius)
        let rs = radiusScale(size, o.rsPow)

        var nodes: [(x: Double, y: Double, z: Double)] = []
        nodes.reserveCapacity(o.nodeN)
        for i in 0..<o.nodeN {
            let d = fibonacciDirection(i, o.nodeN)
            let x = d.0 + 0.3 * (valueNoise(Double(i) * 0.31 + 9, t * 0.24) - 0.5) * 2
            let y = d.1 + 0.3 * (valueNoise(Double(i) * 0.53 + 27, t * 0.21) - 0.5) * 2
            let z = d.2 + 0.3 * (valueNoise(Double(i) * 0.77 + 55, t * 0.27) - 0.5) * 2
            let l = max(1e-6, (x * x + y * y + z * z).squareRoot())
            nodes.append((x / l, y / l, z / l))
        }

        var lines: [RawLine] = []
        let width = max(0.6, o.lineW * rs)
        for i in 0..<o.nodeN {
            for j in (i + 1)..<o.nodeN {
                let dx = nodes[i].x - nodes[j].x
                let dy = nodes[i].y - nodes[j].y
                let dz = nodes[i].z - nodes[j].z
                let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
                guard dist < o.thr else { continue }
                let a = project(nodes[i].x, nodes[i].y, nodes[i].z)
                let b = project(nodes[j].x, nodes[j].y, nodes[j].z)
                let depth = ((a.z + b.z) / 2 + 1) / 2
                lines.append(RawLine(
                    x1: a.x, y1: a.y, x2: b.x, y2: b.y,
                    white: 0.42,
                    alpha: (1 - dist / o.thr) * (0.3 + 0.55 * depth),
                    width: width
                ))
            }
        }

        var dots: [Raw] = []
        dots.reserveCapacity(o.nodeN + o.signals)
        for i in 0..<o.nodeN {
            let p = project(nodes[i].x, nodes[i].y, nodes[i].z)
            let depth = (p.z + 1) / 2
            let pulse = 1 + 0.25 * sin(t * 1.4 + Double(i) * 2.7)
            dots.append(Raw(
                x: p.x, y: p.y, z: p.z,
                r: (o.nodeR + o.nodeRDepth * depth) * pulse * rs,
                white: 0.55 - 0.45 * depth
            ))
        }

        // The packets. Which pair each one runs between is a hash of the segment index, so
        // the sequence is fixed rather than random — the same instant always wires the same
        // two nodes, which is what `--selftest-orb` relies on.
        for s in 0..<o.signals {
            let travel = t * 0.55 + Double(s) * 7.31
            let leg = travel.rounded(.down)
            let a = min(o.nodeN - 1, Int(hash(leg, Double(s) * 3.1 + 1.7) * Double(o.nodeN)))
            let b = min(o.nodeN - 1, Int(hash(leg, Double(s) * 5.7 + 4.2) * Double(o.nodeN)))
            if a == b { continue }
            let f = travel - leg
            let x = nodes[a].x + (nodes[b].x - nodes[a].x) * f
            let y = nodes[a].y + (nodes[b].y - nodes[a].y) * f
            let z = nodes[a].z + (nodes[b].z - nodes[a].z) * f
            let l = max(1e-6, (x * x + y * y + z * z).squareRoot())
            let p = project(x / l, y / l, z / l)
            let depth = (p.z + 1) / 2
            dots.append(Raw(
                x: p.x, y: p.y, z: p.z,
                r: (o.nodeR * 1.5 + o.nodeRDepth * depth) * rs,
                white: 0.05,
                alpha: 0.5 + 0.5 * depth
            ))
        }

        return (dots, lines)
    }

    /// Three strands plaiting around the sphere — `weaving`. Each runs pole to pole on a
    /// helix; a radial breathing term makes them trade places, and that trade is what reads
    /// as the over and under of a plait.
    private static func braid(size: Double, t: Double, o: Preset) -> [Raw] {
        let centre = size / 2
        let radius = (size / 2) * 0.76
        let project = Projection(yaw: t * 0.4, tilt: 0.3, cx: centre, cy: centre, scale: 1)
        let rs = radiusScale(size, o.rsPow)

        var dots: [Raw] = []
        dots.reserveCapacity(o.ghostN + 3 * o.strandN)
        for i in 0..<o.ghostN {
            let d = fibonacciDirection(i, o.ghostN)
            let p = project(d.0 * radius, d.1 * radius, d.2 * radius)
            let depth = (p.z / radius + 1) / 2
            dots.append(Raw(
                x: p.x, y: p.y, z: p.z, r: 0.8 * rs, white: 0.78, alpha: 0.1 + 0.22 * depth
            ))
        }

        for s in 0..<3 {
            let phase = (Double(s) / 3) * 2 * .pi
            for i in 0..<o.strandN {
                // `u` walks pole to pole; the fractional drift slides the whole strand along.
                let u = (fract(Double(i) / Double(o.strandN) + t * 0.045) * 2 - 1) * 0.96
                let surf = max(0, 1 - u * u).squareRoot()
                let endFade = min(1, (1 - abs(u)) / 0.1)
                let a = u * .pi * o.turns + phase
                let weave = 1 + 0.075 * sin(u * .pi * o.turns * 2 + phase * 2 + t * 0.8)
                let rr = surf * radius * weave
                let p = project(cos(a) * rr, u * radius * weave, sin(a) * rr)
                let depth = (p.z / radius + 1) / 2
                dots.append(Raw(
                    x: p.x, y: p.y, z: p.z,
                    r: (o.rBase + o.rDepth * depth) * rs,
                    white: 0.55 - 0.45 * depth,
                    alpha: endFade * (0.45 + 0.55 * depth)
                ))
            }
        }
        return dots
    }

    /// A dotted outline cycling circle → triangle → square → circle — `shaping`. The only
    /// flat mode: every dot sits at `z == 0` and depth plays no part.
    ///
    /// Each shape is a closed path parameterised by arc length, starting at top centre and
    /// running clockwise. Every frame blends the two neighbouring paths, measures the result,
    /// and lays the dots *evenly* along it — so the spacing stays uniform at every instant of
    /// the morph, holds and transitions alike, rather than bunching at the corners.
    ///
    /// Upstream paints this through a blur-and-threshold "goo" filter, which gives a hard
    /// edge where a plain fill has an antialiased one; these dots read a touch softer as a
    /// result. Don't compensate by shrinking the radius — that makes the mark genuinely
    /// smaller than the tuning, and this app has no filters anywhere by design.
    private static func morph(size: Double, t: Double, o: Preset) -> [Raw] {
        let shapes = 3
        let hold = 1.4
        let travel = 0.9
        let leg = hold + travel
        let tc = t.truncatingRemainder(dividingBy: leg * Double(shapes))
        let k = min(shapes - 1, Int(tc / leg))
        let local = tc - Double(k) * leg
        // Smoothstep, so a shape leaves and arrives at rest rather than snapping.
        var m = 0.0
        if local > hold {
            let x = (local - hold) / travel
            m = x * x * (3 - 2 * x)
        }

        // Blend the two shape paths, then measure the blended outline.
        let samples = 160
        var pts: [(x: Double, y: Double)] = []
        pts.reserveCapacity(samples)
        for i in 0..<samples {
            let f = Double(i) / Double(samples)
            let a = morphShape(k, f)
            let b = morphShape((k + 1) % shapes, f)
            pts.append((
                (a.x + (b.x - a.x) * m) * o.spread,
                (a.y + (b.y - a.y) * m) * o.spread
            ))
        }
        var lengths: [Double] = []
        lengths.reserveCapacity(samples)
        var total = 0.0
        for i in 0..<samples {
            let a = pts[i]
            let b = pts[(i + 1) % samples]
            let l = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            lengths.append(l)
            total += l
        }

        // The radius depends only on `rDot`; the count is what sets the gaps. A formed shape
        // breathes a little on the spot.
        let n = max(6, Int((34 * o.iconD).rounded()))
        let re = o.rDot * 1.35 * o.spread
        let pulse = 1 + 0.02 * sin(local * 3.1)

        var dots: [Raw] = []
        dots.reserveCapacity(n)
        let centre = size / 2
        var seg = 0
        var acc = 0.0
        for step in 0..<n {
            let target = (Double(step) / Double(n)) * total
            while acc + lengths[seg] < target && seg < samples - 1 {
                acc += lengths[seg]
                seg += 1
            }
            let a = pts[seg]
            let b = pts[(seg + 1) % samples]
            let f = lengths[seg] != 0 ? min(1, (target - acc) / lengths[seg]) : 0
            let x = (a.x + (b.x - a.x) * f) * pulse
            let y = (a.y + (b.y - a.y) * f) * pulse
            dots.append(Raw(
                x: centre + x * size,
                y: centre + y * size,
                z: 0,
                r: max(0.35, re * size),
                white: 0.1
            ))
        }
        return dots
    }

    // MARK: - Shared primitives

    /// Spin, tilt and an orthographic projection, precomputed once per frame.
    private struct Projection {
        private let cosYaw: Double
        private let sinYaw: Double
        private let cosTilt: Double
        private let sinTilt: Double
        private let cx: Double
        private let cy: Double
        private let scale: Double

        init(yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double) {
            cosYaw = cos(yaw)
            sinYaw = sin(yaw)
            cosTilt = cos(tilt)
            sinTilt = sin(tilt)
            self.cx = cx
            self.cy = cy
            self.scale = scale
        }

        func callAsFunction(_ x: Double, _ y: Double, _ z: Double) -> (x: Double, y: Double, z: Double) {
            let x1 = x * cosYaw + z * sinYaw
            let z1 = -x * sinYaw + z * cosYaw
            let y1 = y * cosTilt - z1 * sinTilt
            let z2 = y * sinTilt + z1 * cosTilt
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    /// Drop invisible marks, clamp radii to the mode's floor, sort far to near.
    private static func finalize(_ raw: [Raw], rMin: Double) -> [Dot] {
        raw
            .filter { $0.alpha >= 0.02 }
            .sorted { $0.z < $1.z }
            .map {
                // The upstream ink value mirrors on a dark substrate. Against a semantic
                // label colour there is nothing to mirror: one minus the ink is the weight
                // of the mark, and the appearance decides what colour that weight is.
                let weight = 1 - min(1, max(0, $0.white))
                return Dot(
                    x: CGFloat($0.x),
                    y: CGFloat($0.y),
                    radius: CGFloat(max(rMin, $0.r)),
                    opacity: min(1, max(0, weight * $0.alpha))
                )
            }
    }

    /// Drop invisible edges and invert the ink, exactly as `finalize(_:rMin:)` does for
    /// dots. Edges carry no depth of their own: they are stroked before every dot.
    private static func finalize(_ raw: [RawLine]) -> [Segment] {
        raw
            .filter { $0.alpha >= 0.02 }
            .map {
                let weight = 1 - min(1, max(0, $0.white))
                return Segment(
                    x1: CGFloat($0.x1),
                    y1: CGFloat($0.y1),
                    x2: CGFloat($0.x2),
                    y2: CGFloat($0.y2),
                    width: CGFloat($0.width),
                    opacity: min(1, max(0, weight * $0.alpha))
                )
            }
    }

    /// Deterministic hash in 0..<1.
    private static func hash(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - h.rounded(.down)
    }

    /// The fractional part, matching the original's `frac`.
    private static func fract(_ x: Double) -> Double {
        x - x.rounded(.down)
    }

    /// Value noise on a 2D lattice — smooth, deterministic, cheap. What makes `connecting`'s
    /// nodes wander rather than jitter, without a single call to a random generator.
    private static func valueNoise(_ x: Double, _ y: Double) -> Double {
        let xi = x.rounded(.down)
        let yi = y.rounded(.down)
        var fx = x - xi
        var fy = y - yi
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi)
        let b = hash(xi + 1, yi)
        let c = hash(xi, yi + 1)
        let d = hash(xi + 1, yi + 1)
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }

    // MARK: - The solver (`solving`)

    /// One quarter turn of a slab of the sphere.
    private struct Twist {
        let axis: Int
        let lo: Double
        let hi: Double
        let angle: Double
    }

    /// How far through each move the solver has got, and which one its hand is on.
    private struct SolveCycle {
        let amount: [Double]
        let hand: Int
    }

    /// The scramble. Drawn from the deterministic hash rather than a generator, so every run
    /// scrambles the same sphere the same way.
    private static func twists(_ count: Int) -> [Twist] {
        (0..<count).map { i in
            let axis = min(2, Int((hash(Double(i), 2.3) * 3).rounded(.down)))
            let slab = min(3, Int((hash(Double(i), 5.9) * 4).rounded(.down)))
            let lo = -1.0 + 0.5 * Double(slab)
            let direction: Double = hash(Double(i), 7.7) < 0.5 ? 1 : -1
            return Twist(axis: axis, lo: lo, hi: lo + 0.5, angle: direction * .pi / 2)
        }
    }

    /// Moves land one after another on a machine ease-out, then play back in reverse — a
    /// palindrome, so the sphere is always solved again before it rests.
    private static func solveCycle(
        _ t: Double, count: Int, slot: Double, rest: Double
    ) -> SolveCycle {
        let span = 2 * Double(count) * slot
        let tc = t.truncatingRemainder(dividingBy: span + rest)
        var amount = [Double](repeating: 0, count: count)
        var hand = -1
        if tc < span {
            let index = min(2 * count - 1, Int(tc / slot))
            let p = (tc - Double(index) * slot) / slot
            let eased = 1 - pow(1 - min(1, p / 0.7), 3)
            if index < count {
                for i in 0..<index { amount[i] = 1 }
                amount[index] = eased
                hand = index
            } else {
                let undo = 2 * count - 1 - index
                for i in 0..<undo { amount[i] = 1 }
                amount[undo] = 1 - eased
                hand = undo
            }
        }
        return SolveCycle(amount: amount, hand: hand)
    }

    /// Turn one point by whichever moves currently have it in their slab.
    private static func applyTwists(
        _ point: (Double, Double, Double), _ moves: [Twist], _ cycle: SolveCycle
    ) -> (x: Double, y: Double, z: Double, inHand: Bool) {
        var (x, y, z) = point
        var inHand = false
        for (i, move) in moves.enumerated() {
            let amount = cycle.amount[i]
            if amount <= 0 { continue }
            let coord = move.axis == 0 ? x : (move.axis == 1 ? y : z)
            if coord < move.lo || coord >= move.hi { continue }
            if i == cycle.hand { inHand = true }
            let a = move.angle * amount
            let ca = cos(a)
            let sa = sin(a)
            switch move.axis {
            case 0:
                let y2 = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            case 1:
                let x2 = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            default:
                let x2 = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return (x, y, z, inHand)
    }

    // MARK: - The outline (`shaping`)

    /// One of the three morph targets, sampled by arc-length fraction. All three start at
    /// top centre and run clockwise, which is what lets two of them be blended point by
    /// point without the outline turning itself inside out.
    private static func morphShape(_ index: Int, _ f: Double) -> (x: Double, y: Double) {
        switch index {
        case 0:
            let a = -Double.pi / 2 + f * 2 * .pi
            return (cos(a) * 0.24, sin(a) * 0.24)
        case 1:
            return polygonPoint([(0, -0.26), (0.24, 0.16), (-0.24, 0.16)], f)
        default:
            // Five vertices rather than four, so the walk starts at top centre like the
            // other two rather than at a corner.
            return polygonPoint(
                [(0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)], f
            )
        }
    }

    /// A closed polygon sampled by arc-length fraction.
    private static func polygonPoint(
        _ verts: [(x: Double, y: Double)], _ f: Double
    ) -> (x: Double, y: Double) {
        let count = verts.count
        var lengths: [Double] = []
        lengths.reserveCapacity(count)
        var total = 0.0
        for i in 0..<count {
            let a = verts[i]
            let b = verts[(i + 1) % count]
            let l = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            lengths.append(l)
            total += l
        }
        var target = f * total
        var i = 0
        while target > lengths[i] && i < count - 1 {
            target -= lengths[i]
            i += 1
        }
        let a = verts[i]
        let b = verts[(i + 1) % count]
        let ff = lengths[i] != 0 ? min(1, target / lengths[i]) : 0
        return (a.x + (b.x - a.x) * ff, a.y + (b.y - a.y) * ff)
    }

    /// Stable directions on a unit sphere.
    private static func fibonacciDirection(_ i: Int, _ n: Int) -> (Double, Double, Double) {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let y = 1 - (2 * (Double(i) + 0.5)) / Double(n)
        let rad = (1 - y * y).squareRoot()
        let a = Double(i) * golden
        return (rad * cos(a), y, rad * sin(a))
    }

    /// Shortest signed angular distance, wrapped to (-π, π].
    private static func angleDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    /// Radii were tuned for a 300pt frame; the sub-linear falloff is what keeps a 20pt orb
    /// legible instead of dissolving into dust.
    private static func radiusScale(_ size: Double, _ exponent: Double) -> Double {
        pow(size / 300, exponent)
    }
}
