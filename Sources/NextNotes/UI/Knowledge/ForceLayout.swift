import CoreGraphics

/// Fruchterman–Reingold force layout, shared by the local and global graph views.
///
/// The ideal separation `k = sqrt(area / n)` normalises to the frame, so one implementation
/// fills a 700pt canvas at 40 nodes and at 700 nodes with no per-view tuning. Repulsion is
/// skipped beyond `6k`, where the force is under 1/36 of nominal, and the iteration count
/// scales down as nodes go up — roughly 240 under 150 nodes, 80 over 400 — which is what
/// makes a full-library run affordable.
///
/// Pure function: `positions` in, positions out, no state. `Canvas` calls it when its size
/// changes; nothing here animates (the roadmap's rAF-style caveat, adapted: a layout that
/// redraws behind a hidden pane is a cost nobody sees).
struct ForceLayout {
    /// The outcome per node, aligned with the ids passed in.
    struct Placement: Equatable {
        var id: String
        var point: CGPoint
    }

    let placements: [String: CGPoint]

    /// `positions` are seeds. Seeded identically, the same graph produces the same layout;
    /// the views pass a stable per-node seed (a hash of the id) so a relaunch does not
    /// reshuffle the picture.
    init(ids: [String], edges: [(String, String)], size: CGSize) {
        guard !ids.isEmpty, size.width > 1, size.height > 1 else {
            placements = [:]
            return
        }
        let count = CGFloat(ids.count)
        let area = size.width * size.height
        let k2 = area / (count * 1.6)
        let k = k2.squareRoot()
        let radius = min(size.width, size.height) * 0.5 * 0.86
        var point = [String: CGPoint]()
        for (index, id) in ids.enumerated() {
            let angle = CGFloat(index) / count * 2 * .pi
            let jitter = Self.rng(id) - 0.5
            let distance = radius * (0.72 + CGFloat(jitter) * 0.16)
            point[id] = CGPoint(x: size.width / 2 + cos(angle) * distance,
                                y: size.height / 2 + sin(angle) * distance)
        }
        let repulsionCut = 6 * k
        var displacement = [String: CGPoint]()
        displacement.reserveCapacity(ids.count)

        func simulate(iterations: Int, temperature: CGFloat) {
            for _ in 0..<iterations {
                displacement.removeAll(keepingCapacity: true)
                for id in ids {
                    displacement[id] = .zero
                }
                for (aIndex, a) in ids.enumerated() {
                    let pa = point[a]!
                    guard aIndex + 1 < ids.count else { continue }
                    for b in ids[(aIndex + 1)...] {
                        let pb = point[b]!
                        let delta = CGPoint(x: pa.x - pb.x, y: pa.y - pb.y)
                        let distance = max(hypot(delta.x, delta.y), 0.01)
                        guard distance < repulsionCut else { continue }
                        let force = k2 / distance
                        displacement[a]!.x += delta.x / distance * force
                        displacement[a]!.y += delta.y / distance * force
                        displacement[b]!.x -= delta.x / distance * force
                        displacement[b]!.y -= delta.y / distance * force
                    }
                }
                for (a, b) in edges where point[a] != nil && point[b] != nil {
                    let pa = point[a]!, pb = point[b]!
                    let delta = CGPoint(x: pa.x - pb.x, y: pa.y - pb.y)
                    let distance = max(sqrt(delta.x * delta.x + delta.y * delta.y), 0.01)
                    let force = distance * distance / k
                    displacement[a]!.x -= delta.x / distance * force
                    displacement[a]!.y -= delta.y / distance * force
                    displacement[b]!.x += delta.x / distance * force
                    displacement[b]!.y += delta.y / distance * force
                }
                let limit = max(temperature, 0.01)
                for id in ids {
                    let moved = displacement[id]!
                    let magnitude = max(hypot(moved.x, moved.y), 0.01)
                    let capped = min(magnitude, limit)
                    var next = point[id]!
                    next.x += moved.x / magnitude * capped
                    next.y += moved.y / magnitude * capped
                    // The frame, with a margin, is the boundary. Not the canvas centre:
                    // nodes pushed to the exact centre collapse into a blob — the prototype's
                    // first pass did exactly that with a charge-and-centre model.
                    let inset = DS.Size.graphCanvasInset
                    next.x = min(max(next.x, inset), size.width - inset)
                    next.y = min(max(next.y, inset), size.height - inset)
                    point[id] = next
                    displacement[id] = .zero
                }
            }
        }

        let iterations = ids.count < 150 ? 240 : (ids.count < 400 ? 120 : 80)
        if ids.count <= 400 {
            simulate(iterations: iterations, temperature: k * 0.32)
        } else {
            // Two cooling phases instead of one long run: the big case gets its shape
            // quickly, then refines, so a 2000-node limit is still bounded work.
            simulate(iterations: iterations / 2, temperature: k * 0.5)
            simulate(iterations: iterations / 2, temperature: k * 0.22)
        }
        placements = point
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
}
