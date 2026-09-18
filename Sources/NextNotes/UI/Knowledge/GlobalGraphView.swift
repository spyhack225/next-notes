import SwiftUI

/// Every recent node on one canvas (Part 4, Phase G) — only as a way into the local graph.
///
/// Click a node to re-centre on it in `LocalGraphView`. Without that hand-off this is a
/// picture beside search; with it, it is how you pick where to start walking. Cap is the
/// same 700-node budget `GraphStore.visualization` already uses.
struct GlobalGraphView: View {
    let expansion: KnowledgeGraphExpansion
    var onFocus: (String) -> Void

    @State private var hoverID: String?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let layout = ForceLayout(
                ids: expansion.nodes.map(\.id),
                edges: expansion.edges.map { ($0.from, $0.to) },
                size: size
            )
            ZStack {
                Canvas { context, _ in
                    for edge in expansion.edges {
                        guard let a = layout.placements[edge.from], let b = layout.placements[edge.to] else { continue }
                        var path = Path()
                        path.move(to: a)
                        path.addLine(to: b)
                        context.stroke(
                            path,
                            with: .color(DS.Color.textTertiary.opacity(DS.Opacity.graphEdgeDimmed)),
                            lineWidth: DS.Border.hairline
                        )
                    }
                    for node in expansion.nodes {
                        guard let point = layout.placements[node.id] else { continue }
                        let highlighted = hoverID == nil || hoverID == node.id
                        let radius = DS.Size.graphNodeDot * (node.type == "Person" || node.type == "Meeting" ? 1.15 : 0.85)
                        let rect = CGRect(x: point.x - radius / 2, y: point.y - radius / 2,
                                          width: radius, height: radius)
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(ink(for: node).opacity(highlighted ? 1 : DS.Opacity.graphDimmed))
                        )
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    if let hit = nearest(value.location, in: layout) {
                        onFocus(hit)
                    }
                })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverID = nearest(point, in: layout)
                    case .ended: hoverID = nil
                    }
                }

                if let hoverID, let node = expansion.nodes.first(where: { $0.id == hoverID }),
                   let point = layout.placements[hoverID] {
                    Text(node.label)
                        .font(DS.Font.caption)
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.vertical, DS.Space.xxs)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                        .position(x: point.x, y: max(DS.Size.graphCanvasInset, point.y - DS.Size.graphNodeDot - DS.Space.s))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minHeight: DS.Size.graphCanvasMinHeight)
        .accessibilityLabel("Library graph. Click a node to open its local neighbourhood.")
    }

    private func ink(for node: KnowledgeGraphNode) -> Color {
        switch node.type {
        case "Person": return DS.Color.accent
        case "Meeting": return DS.Color.text
        case "Decision", "ActionItem": return DS.Color.success
        default: return DS.Color.textTertiary
        }
    }

    private func nearest(_ point: CGPoint, in layout: ForceLayout) -> String? {
        let hitRadius = DS.Size.graphNodeHitRadius
        var best: (String, CGFloat)?
        for (id, placed) in layout.placements {
            let distance = hypot(placed.x - point.x, placed.y - point.y)
            guard distance <= hitRadius else { continue }
            if best == nil || distance < best!.1 { best = (id, distance) }
        }
        return best?.0
    }
}
