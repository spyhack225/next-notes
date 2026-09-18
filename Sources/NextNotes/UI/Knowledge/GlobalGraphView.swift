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

    private static let primaryTypes: Set<String> = [
        "Person", "Meeting", "Project", "Organization", "Activity",
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let layout = ForceLayout(
                ids: expansion.nodes.map(\.id),
                edges: expansion.edges.map { ($0.from, $0.to) },
                size: size
            )
            let hoverNeighbours = neighbourIDs(of: hoverID)
            ZStack {
                Canvas { context, _ in
                    let hovering = hoverID != nil
                    for edge in expansion.edges {
                        guard let a = layout.placements[edge.from],
                              let b = layout.placements[edge.to] else { continue }
                        let touchesHover = !hovering
                            || edge.from == hoverID
                            || edge.to == hoverID
                        var path = Path()
                        path.move(to: a)
                        path.addLine(to: b)
                        context.stroke(
                            path,
                            with: .color(DS.Color.textTertiary.opacity(
                                touchesHover ? DS.Opacity.graphEdgeActive : DS.Opacity.graphEdgeDimmed
                            )),
                            lineWidth: touchesHover ? DS.Border.graphEdgeQuiet : DS.Border.graphEdgeFaint
                        )
                    }
                    for node in expansion.nodes {
                        guard let point = layout.placements[node.id] else { continue }
                        let isHover = hoverID == node.id
                        let inNeighbourhood = !hovering || hoverNeighbours.contains(node.id)
                        let diameter = nodeDiameter(for: node, highlighted: isHover)
                        let fill = ink(for: node).opacity(inNeighbourhood ? 1 : DS.Opacity.graphDimmed)

                        if isHover {
                            let halo = DS.Size.graphNodeHalo
                            let haloRect = CGRect(
                                x: point.x - halo / 2,
                                y: point.y - halo / 2,
                                width: halo,
                                height: halo
                            )
                            context.fill(
                                Path(ellipseIn: haloRect),
                                with: .color(ink(for: node).opacity(DS.Opacity.graphNodeHalo))
                            )
                        }

                        let rect = CGRect(
                            x: point.x - diameter / 2,
                            y: point.y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(fill))

                        if isHover {
                            let ring = diameter + DS.Size.graphNodeRingPad * 2
                            let ringRect = CGRect(
                                x: point.x - ring / 2,
                                y: point.y - ring / 2,
                                width: ring,
                                height: ring
                            )
                            context.stroke(
                                Path(ellipseIn: ringRect),
                                with: .color(DS.Color.text.opacity(DS.Opacity.graphHoverRing)),
                                lineWidth: DS.Border.graphRing
                            )
                        }
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    if let hit = nearest(value.location, in: layout) {
                        onFocus(hit)
                    }
                })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        withAnimation(DS.Motion.standard) { hoverID = nearest(point, in: layout) }
                    case .ended:
                        withAnimation(DS.Motion.standard) { hoverID = nil }
                    }
                }

                if let hoverID,
                   let node = expansion.nodes.first(where: { $0.id == hoverID }),
                   let point = layout.placements[hoverID]
                {
                    hoverChip(for: node)
                        .position(
                            x: point.x,
                            y: max(
                                DS.Size.graphCanvasInset,
                                point.y - DS.Size.graphNodeDotPrimary - DS.Space.m
                            )
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(DS.Motion.standard, value: hoverID)
        }
        .frame(minHeight: DS.Size.graphCanvasMinHeight)
        .accessibilityLabel("Library graph. Click a node to open its local neighbourhood.")
    }

    private func hoverChip(for node: KnowledgeGraphNode) -> some View {
        HStack(spacing: DS.Space.xs) {
            Circle()
                .fill(ink(for: node))
                .frame(width: DS.Size.graphRailSwatch, height: DS.Size.graphRailSwatch)
            Text(node.label)
                .font(DS.Font.caption.weight(.medium))
                .foregroundStyle(DS.Color.text)
                .lineLimit(2)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .frame(maxWidth: DS.Size.graphHoverLabelMaxWidth)
        .glassSurface(cornerRadius: DS.Radius.graphHoverChip)
    }

    private func nodeDiameter(for node: KnowledgeGraphNode, highlighted: Bool) -> CGFloat {
        if highlighted { return DS.Size.graphNodeDotPrimary }
        return Self.primaryTypes.contains(node.type)
            ? DS.Size.graphNodeDotPrimary
            : DS.Size.graphNodeDotSecondary
    }

    private func neighbourIDs(of hover: String?) -> Set<String> {
        guard let hover else { return Set(expansion.nodes.map(\.id)) }
        var ids: Set<String> = [hover]
        for edge in expansion.edges {
            if edge.from == hover { ids.insert(edge.to) }
            if edge.to == hover { ids.insert(edge.from) }
        }
        return ids
    }

    private func ink(for node: KnowledgeGraphNode) -> Color {
        DS.Color.graphNode(node.type)
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
