import CoreGraphics

/// Fruchterman–Reingold force layout with cluster gravity, shared by the map and the
/// neighbourhood view.
///
/// The ideal separation `k = sqrt(area / n)` normalises to the frame, so one implementation
/// fills a 700pt canvas at 40 nodes and at 700 nodes with no per-view tuning. Repulsion is
/// skipped beyond `6k`, where the force is under 1/36 of nominal, and the iteration count
/// scales down as nodes go up — roughly 240 under 150 nodes, 80 over 400 — which is what
/// makes a full-library run affordable.
///
/// **Why there is gravity, and why the frame is no longer the boundary.** Plain
/// Fruchterman–Reingold has nothing holding two unconnected groups together: repulsion
/// pushes them apart forever and attraction, which only runs along edges, never pulls them
/// back. Clamping each step to the frame turned that runaway into the artefact this view
/// shipped with — a rigid row of folders along the top edge and a column of files down the
/// right, which is what "pushed until it hit the wall" looks like. Gravity fixes the cause:
/// every node is pulled toward its own cluster's anchor, hard for a lone node and gently for
/// a large group, so a component settles at a size of its own instead of expanding into the
/// wall. The clamp during simulation is now a loose safety net at 1.5× the frame, and the
/// frame is imposed once at the end by fitting the finished picture into it — which is also
/// what centres a lopsided map instead of leaving it hugging one corner.
///
/// Pure function: ids and edges in, positions out, no state, no clock. Seeded from a hash of
/// each id, so the same graph draws the same picture on every launch — the property
/// `--selftest-graph-layout` checks, along with every point landing inside the frame.
///
/// It is **not** cheap: repulsion is O(n²) per iteration. Call it off the main actor.
/// `GraphLayoutModel` is the thing that does that, and every view here goes through it.
struct ForceLayout: Sendable, Equatable {
    /// Where each node landed, in the coordinate space of the `size` passed in.
    let placements: [String: CGPoint]
    /// How many edges touch each node. Views size a dot by it — the map's only claim about
    /// importance, and one it can actually back up.
    let degree: [String: Int]
    /// Which connected group each node belongs to, largest group first (`0`). Views use it
    /// to keep a folder and its files reading as one thing.
    let clusters: [String: Int]

    /// `ids` may repeat; the first occurrence wins and the rest are ignored, so a node drawn
    /// twice by a merge of two sources is still one dot.
    init(ids: [String], edges: [(String, String)], size: CGSize) {
        var seen = Set<String>()
        let nodes = ids.filter { seen.insert($0).inserted }
        guard !nodes.isEmpty, size.width > 1, size.height > 1 else {
            placements = [:]
            degree = [:]
            clusters = [:]
            return
        }

        let count = nodes.count
        var index = [String: Int](minimumCapacity: count)
        for (offset, id) in nodes.enumerated() { index[id] = offset }

        // MARK: Edges, degrees and connected groups

        var links: [(Int, Int)] = []
        links.reserveCapacity(edges.count)
        var degrees = [Int](repeating: 0, count: count)
        var parent = Array(0..<count)

        func root(_ start: Int) -> Int {
            var node = start
            while parent[node] != node {
                parent[node] = parent[parent[node]]
                node = parent[node]
            }
            return node
        }

        for (from, to) in edges {
            guard let a = index[from], let b = index[to], a != b else { continue }
            links.append((a, b))
            degrees[a] += 1
            degrees[b] += 1
            let (ra, rb) = (root(a), root(b))
            // Lowest index always wins, so the grouping does not depend on edge order.
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        var members = [Int: [Int]]()
        for node in 0..<count { members[root(node), default: []].append(node) }
        // Biggest group first, ties broken by the lowest member — deterministic either way.
        let groups = members.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : ($0.first ?? 0) < ($1.first ?? 0)
        }

        // MARK: Anchors — one gravity well per group

        let inset = DS.Size.graphCanvasInset
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let reachX = max(size.width / 2 - inset, 1)
        let reachY = max(size.height / 2 - inset, 1)
        var anchor = [CGPoint](repeating: centre, count: count)
        var cluster = [Int](repeating: 0, count: count)

        for (rank, group) in groups.enumerated() {
            let point: CGPoint
            if rank == 0 {
                // The main graph owns the middle. Everything else orbits it.
                point = centre
            } else {
                // A golden-angle spiral: evenly spread without ever lining two groups up
                // into the row-and-column artefact this replaced.
                let angle = Double(rank) * Self.goldenAngle
                let spread = groups.count > 2
                    ? (Double(rank - 1) / Double(groups.count - 2)).squareRoot()
                    : 0.5
                let fraction = 0.46 + 0.46 * CGFloat(spread)
                point = CGPoint(x: centre.x + CGFloat(cos(angle)) * reachX * fraction,
                                y: centre.y + CGFloat(sin(angle)) * reachY * fraction)
            }
            for node in group {
                anchor[node] = point
                cluster[node] = rank
            }
        }

        // MARK: Seeds

        let area = size.width * size.height
        let k2 = area / (CGFloat(count) * 1.6)
        let k = k2.squareRoot()
        var point = [CGPoint](repeating: .zero, count: count)
        for group in groups {
            let size = CGFloat(group.count)
            let spread = k * size.squareRoot() * 0.6
            for (offset, node) in group.enumerated() {
                let angle = CGFloat(offset) / size * 2 * .pi
                let jitter = CGFloat(Self.rng(nodes[node])) - 0.5
                let distance = spread * (0.34 + 0.66 * ((CGFloat(offset) + 0.5) / size).squareRoot())
                    + spread * jitter * 0.18
                point[node] = CGPoint(x: anchor[node].x + cos(angle) * distance,
                                      y: anchor[node].y + sin(angle) * distance)
            }
        }

        // MARK: Simulate

        let repulsionCut = 6 * k
        // How hard a node is held to its anchor. A lone node is held tightly — it has no
        // edges to give it a place, so without this it is pure repulsion and ends up at the
        // wall. A large group barely feels it and keeps its own shape.
        var pull = [CGFloat](repeating: 0, count: count)
        for group in groups {
            let strength = 0.08 + 0.26 / CGFloat(group.count).squareRoot()
            for node in group { pull[node] = strength }
        }
        var displacement = [CGPoint](repeating: .zero, count: count)
        // A loose net, not a frame: it exists so a pathological graph cannot run to
        // infinity, and it is far enough out that nothing settles against it.
        let slack = CGPoint(x: size.width * 0.5, y: size.height * 0.5)

        func simulate(iterations: Int, temperature: CGFloat) {
            for _ in 0..<iterations {
                for node in 0..<count { displacement[node] = .zero }

                for a in 0..<count {
                    let pa = point[a]
                    guard a + 1 < count else { continue }
                    for b in (a + 1)..<count {
                        let pb = point[b]
                        let delta = CGPoint(x: pa.x - pb.x, y: pa.y - pb.y)
                        let distance = max(hypot(delta.x, delta.y), 0.01)
                        guard distance < repulsionCut else { continue }
                        let force = k2 / distance
                        displacement[a].x += delta.x / distance * force
                        displacement[a].y += delta.y / distance * force
                        displacement[b].x -= delta.x / distance * force
                        displacement[b].y -= delta.y / distance * force
                    }
                }

                for (a, b) in links {
                    let pa = point[a], pb = point[b]
                    let delta = CGPoint(x: pa.x - pb.x, y: pa.y - pb.y)
                    let distance = max(hypot(delta.x, delta.y), 0.01)
                    let force = distance * distance / k
                    displacement[a].x -= delta.x / distance * force
                    displacement[a].y -= delta.y / distance * force
                    displacement[b].x += delta.x / distance * force
                    displacement[b].y += delta.y / distance * force
                }

                for node in 0..<count {
                    let home = anchor[node]
                    displacement[node].x -= (point[node].x - home.x) * pull[node]
                    displacement[node].y -= (point[node].y - home.y) * pull[node]
                }

                let limit = max(temperature, 0.01)
                for node in 0..<count {
                    let moved = displacement[node]
                    let magnitude = max(hypot(moved.x, moved.y), 0.01)
                    let capped = min(magnitude, limit)
                    var next = point[node]
                    next.x += moved.x / magnitude * capped
                    next.y += moved.y / magnitude * capped
                    next.x = min(max(next.x, -slack.x), size.width + slack.x)
                    next.y = min(max(next.y, -slack.y), size.height + slack.y)
                    point[node] = next
                }
            }
        }

        let iterations = count < 150 ? 240 : (count < 400 ? 120 : 80)
        if count <= 400 {
            simulate(iterations: iterations, temperature: k * 0.32)
        } else {
            // Two cooling phases instead of one long run: the big case gets its shape
            // quickly, then refines, so a 2000-node limit is still bounded work.
            simulate(iterations: iterations / 2, temperature: k * 0.5)
            simulate(iterations: iterations / 2, temperature: k * 0.22)
        }

        // MARK: Fit

        // The finished picture is scaled and centred into the frame rather than clipped to
        // it. This is what guarantees every point is inside the inset — the property the
        // self-test checks — without any node having been shoved against an edge to get
        // there, and it is also what stops a map that happened to settle to one side from
        // being drawn to one side.
        var low = point[0], high = point[0]
        for node in point {
            low.x = min(low.x, node.x); low.y = min(low.y, node.y)
            high.x = max(high.x, node.x); high.y = max(high.y, node.y)
        }
        let target = CGRect(x: inset, y: inset,
                            width: max(size.width - inset * 2, 1),
                            height: max(size.height - inset * 2, 1))
        let spanX = max(high.x - low.x, 1)
        let spanY = max(high.y - low.y, 1)
        // Only ever shrink much, and never blow a two-node graph up to fill a wall.
        let scale = min(min(target.width / spanX, target.height / spanY), Self.maximumUpscale)
        let middle = CGPoint(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2)
        let fitted = CGPoint(x: target.midX, y: target.midY)

        var placed = [String: CGPoint](minimumCapacity: count)
        var placedDegree = [String: Int](minimumCapacity: count)
        var placedCluster = [String: Int](minimumCapacity: count)
        for (offset, id) in nodes.enumerated() {
            var next = CGPoint(x: fitted.x + (point[offset].x - middle.x) * scale,
                               y: fitted.y + (point[offset].y - middle.y) * scale)
            // Belt and braces. The fit above already lands inside; this is what makes
            // "inside the frame" a fact rather than an argument about rounding.
            next.x = min(max(next.x, target.minX), target.maxX)
            next.y = min(max(next.y, target.minY), target.maxY)
            placed[id] = next
            placedDegree[id] = degrees[offset]
            placedCluster[id] = cluster[offset]
        }
        placements = placed
        degree = placedDegree
        clusters = placedCluster
    }

    /// Stable per-node jitter, from the id, so a relaunch draws the same picture.
    static func rng(_ id: String) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Double(hash % 10_000) / 10_000
    }

    /// The angle that never repeats a direction — the same one sunflower seeds use, and the
    /// reason the clusters around the main graph never line up into a row.
    private static let goldenAngle = Double.pi * (3 - 5.0.squareRoot())

    /// How far a small graph is allowed to be blown up to fill the frame. Past this a
    /// three-node picture becomes three dots in three corners, which is not a map.
    private static let maximumUpscale: CGFloat = 1.3
}
