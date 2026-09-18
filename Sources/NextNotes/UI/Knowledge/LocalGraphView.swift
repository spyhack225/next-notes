import SwiftUI

/// One focus node and its immediate neighbours (Part 4, Phase F).
///
/// Node count on screen is bounded by one node's degree, so the picture reads the same at
/// 12 meetings and at 180. Hover isolates the neighbourhood; everything else fades. Click
/// a neighbour to re-centre — that is how you walk the graph, one hop at a time.
struct LocalGraphView: View {
    let expansion: KnowledgeGraphExpansion
    let focusID: String
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
                    draw(context: &context, layout: layout, size: size)
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

                ForEach(expansion.nodes, id: \.id) { node in
                    if let point = layout.placements[node.id] {
                        Text(node.label)
                            .font(node.id == focusID ? DS.Font.caption.weight(.semibold) : DS.Font.caption2)
                            .foregroundStyle(labelInk(for: node.id))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: DS.Size.graphLabelMaxWidth)
                            .position(
                                x: point.x,
                                y: point.y + DS.Size.graphLabelOffset
                                    + (node.id == focusID ? DS.Size.graphNodeDotFocus : DS.Size.graphNodeDot) / 2
                            )
                            .allowsHitTesting(false)
                            .animation(DS.Motion.standard, value: hoverID)
                    }
                }
            }
        }
        .frame(minHeight: DS.Size.graphCanvasMinHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local graph centred on \(focusLabel)")
    }

    private var focusLabel: String {
        expansion.nodes.first { $0.id == focusID }?.label ?? focusID
    }

    private var neighbourIDs: Set<String> {
        guard let hover = hoverID else { return Set(expansion.nodes.map(\.id)) }
        var ids: Set<String> = [hover]
        for edge in expansion.edges {
            if edge.from == hover { ids.insert(edge.to) }
            if edge.to == hover { ids.insert(edge.from) }
        }
        return ids
    }

    private func labelInk(for id: String) -> Color {
        let active = hoverID == nil || neighbourIDs.contains(id)
        if id == focusID {
            return DS.Color.text.opacity(active ? 1 : DS.Opacity.graphDimmed)
        }
        return DS.Color.textSecondary.opacity(active ? 1 : DS.Opacity.graphDimmed)
    }

    private func draw(context: inout GraphicsContext, layout: ForceLayout, size: CGSize) {
        let neighbours = neighbourIDs
        let hovering = hoverID != nil

        for edge in expansion.edges {
            guard let a = layout.placements[edge.from], let b = layout.placements[edge.to] else { continue }
            let touchesHover = !hovering || edge.from == hoverID || edge.to == hoverID
            let touchesFocus = edge.from == focusID || edge.to == focusID
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            let opacity = touchesHover
                ? (touchesFocus ? DS.Opacity.graphEdgeActive : DS.Opacity.secondaryFill)
                : DS.Opacity.graphEdgeDimmed
            let width = touchesHover ? DS.Border.graphEdgeActive : DS.Border.graphEdgeQuiet
            context.stroke(
                path,
                with: .color(DS.Color.textTertiary.opacity(opacity)),
                lineWidth: width
            )
        }

        for node in expansion.nodes {
            guard let point = layout.placements[node.id] else { continue }
            let active = !hovering || neighbours.contains(node.id)
            let isFocus = node.id == focusID
            let isHover = node.id == hoverID
            let diameter: CGFloat = isFocus
                ? DS.Size.graphNodeDotFocus
                : (isHover ? DS.Size.graphNodeDotPrimary : DS.Size.graphNodeDot)
            let fill = ink(for: node).opacity(active ? 1 : DS.Opacity.graphDimmed)

            if isFocus {
                let halo = DS.Size.graphNodeHalo
                let haloRect = CGRect(
                    x: point.x - halo / 2,
                    y: point.y - halo / 2,
                    width: halo,
                    height: halo
                )
                context.fill(
                    Path(ellipseIn: haloRect),
                    with: .color(DS.Color.accent.opacity(DS.Opacity.graphNodeHalo))
                )
            }

            let rect = CGRect(
                x: point.x - diameter / 2,
                y: point.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(Path(ellipseIn: rect), with: .color(fill))

            if isFocus || isHover {
                let ringPad = DS.Size.graphNodeRingPad
                let ring = diameter + ringPad * 2
                let ringRect = CGRect(
                    x: point.x - ring / 2,
                    y: point.y - ring / 2,
                    width: ring,
                    height: ring
                )
                let ringInk = isFocus
                    ? DS.Color.accent.opacity(DS.Opacity.graphFocusRing)
                    : DS.Color.text.opacity(DS.Opacity.graphHoverRing)
                context.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(ringInk),
                    lineWidth: DS.Border.graphRing
                )
            }
        }
        _ = size
    }

    private func ink(for node: KnowledgeGraphNode) -> Color {
        if node.id == focusID { return DS.Color.accent }
        return DS.Color.graphNode(node.type)
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
